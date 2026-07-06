#!/usr/bin/env bash
# controlla_mp4_video.sh
# ISPEZIONE PACCHETTI: Calcola l'offset iniziale e finale reale tra Audio e Video
#
# Requisiti: ffmpeg/ffprobe (sudo apt install ffmpeg), bash >= 4
#
# Uso:
#   ./controlla_mp4_video.sh [-d CARTELLA] [-s SOGLIA_INIZIO] [-e SOGLIA_FINE] [-p N_PACCHETTI] [-k SEC_DA_EOF]
#
# Esempio:
#   ./controlla_mp4_video.sh -d /mnt/video -s 0.15 -e 0.40

set -u

# Forza il locale C per tutti i calcoli numerici (awk, printf, sort):
# evita errori quando il sistema usa la virgola come separatore decimale.
export LC_ALL=C

DIR="."
OUT_DIR=""
START_THRESHOLD="0.15"
END_THRESHOLD="0.40"
PROBE_PACKETS=15
EOF_SEEK="5.0"

usage() {
    echo "Uso: $0 [-d CARTELLA] [-o CARTELLA_OUTPUT] [-s SOGLIA_INIZIO_SEC] [-e SOGLIA_FINE_SEC] [-p N_PACCHETTI] [-k SEC_DA_EOF]"
    exit 1
}

while getopts "d:o:s:e:p:k:h" opt; do
    case "$opt" in
        d) DIR="$OPTARG" ;;
        o) OUT_DIR="$OPTARG" ;;
        s) START_THRESHOLD="$OPTARG" ;;
        e) END_THRESHOLD="$OPTARG" ;;
        p) PROBE_PACKETS="$OPTARG" ;;
        k) EOF_SEEK="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if ! command -v ffprobe >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Errore: ffmpeg/ffprobe non trovati. Installa con: sudo apt install ffmpeg" >&2
    exit 1
fi

if [ ! -d "$DIR" ]; then
    echo "Cartella non trovata: $DIR" >&2
    exit 1
fi

ABS_DIR="$(cd "$DIR" && pwd)"

# Determina dove salvare il report:
# - se specificato con -o, usa quella cartella
# - altrimenti prova a scrivere nella cartella scansionata
# - se non e' scrivibile (es. mount di sola lettura per l'utente), usa $HOME
if [ -n "$OUT_DIR" ]; then
    if [ ! -d "$OUT_DIR" ] || [ ! -w "$OUT_DIR" ]; then
        echo "Errore: cartella di output non valida o non scrivibile: $OUT_DIR" >&2
        exit 1
    fi
    OUT_CSV="$(cd "$OUT_DIR" && pwd)/report_video_linux.csv"
elif [ -w "$ABS_DIR" ]; then
    OUT_CSV="$ABS_DIR/report_video_linux.csv"
else
    OUT_CSV="$HOME/report_video_linux.csv"
    echo "Attenzione: nessun permesso di scrittura in $ABS_DIR, il report verra' salvato in $OUT_CSV" >&2
fi

echo "file;stato;dettagli" > "$OUT_CSV"

# --- Funzione: scrive una riga CSV con escaping minimo (quoting se contiene ; o ") ---
csv_escape() {
    local field="$1"
    if [[ "$field" == *";"* || "$field" == *'"'* ]]; then
        field="${field//\"/\"\"}"
        printf '"%s"' "$field"
    else
        printf '%s' "$field"
    fi
}

write_csv_line() {
    local filepath="$1" stato="$2" dettagli="$3"
    local f1 f2 f3
    f1="$(csv_escape "$filepath")"
    f2="$(csv_escape "$stato")"
    f3="$(csv_escape "$dettagli")"
    printf '%s;%s;%s\n' "$f1" "$f2" "$f3" >> "$OUT_CSV"
}

# --- Funzione: stream presente? ---
stream_present() {
    local path="$1" spec="$2"
    local out
    out="$(ffprobe -v error -select_streams "$spec" -show_entries stream=index -of csv=p=0 "$path" 2>/dev/null)"
    [ -n "$out" ]
}

# --- Funzione: primo pts (minimo tra i primi N pacchetti, tollerante al riordino B-frame) ---
get_first_pts() {
    local path="$1" spec="$2" count="$3"
    local out
    out="$(ffprobe -v error -select_streams "$spec" -show_entries packet=pts_time \
        -read_intervals "%+#${count}" -of csv=p=0 "$path" 2>/dev/null)"
    [ -z "$out" ] && return 1
    echo "$out" | grep -E '^[0-9.]+$' | sort -g | head -n1
}

# --- Funzione: ultimo pts (seek vicino a EOF, con fallback se il file e' troppo corto) ---
get_last_pts() {
    local path="$1" spec="$2" eofsec="$3"
    local out
    out="$(ffprobe -v error -sseof "-${eofsec}" -select_streams "$spec" \
        -show_entries packet=pts_time -of csv=p=0 "$path" 2>/dev/null)"
    if [ -z "$out" ]; then
        out="$(ffprobe -v error -select_streams "$spec" \
            -show_entries packet=pts_time -of csv=p=0 "$path" 2>/dev/null)"
    fi
    [ -z "$out" ] && return 1
    echo "$out" | grep -E '^[0-9.]+$' | sort -g | tail -n1
}

echo "Ricerca file mp4 in corso in: $ABS_DIR..."

# Popola l'array con i file trovati (gestisce spazi/caratteri speciali nei nomi)
mapfile -d '' -t FILES < <(find "$ABS_DIR" -type f -iname "*.mp4" -print0)
TOTAL=${#FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "Nessun file .mp4 trovato in $ABS_DIR"
    exit 0
fi

echo "Trovati $TOTAL file. Avvio ispezione dei pacchetti..."
echo

COUNT_OK=0
COUNT_ERR=0
COUNT_SKIP=0
DONE=0
START_TIME=$(date +%s)

for path in "${FILES[@]}"; do
    DONE=$((DONE + 1))
    printf "\r[%d/%d] Analisi: %-50s" "$DONE" "$TOTAL" "$(basename "$path" | cut -c1-50)"

    if ! stream_present "$path" "v:0" || ! stream_present "$path" "a:0"; then
        if ! stream_present "$path" "v:0"; then
            missing="traccia video assente"
        else
            missing="traccia audio assente"
        fi
        write_csv_line "$path" "SALTATO" "Confronto non applicabile: $missing"
        COUNT_SKIP=$((COUNT_SKIP + 1))
        continue
    fi

    v_start="$(get_first_pts "$path" "v:0" "$PROBE_PACKETS")"
    a_start="$(get_first_pts "$path" "a:0" "$PROBE_PACKETS")"
    v_end="$(get_last_pts "$path" "v:0" "$EOF_SEEK")"
    a_end="$(get_last_pts "$path" "a:0" "$EOF_SEEK")"

    if [ -z "${v_start:-}" ] || [ -z "${a_start:-}" ] || [ -z "${v_end:-}" ] || [ -z "${a_end:-}" ]; then
        write_csv_line "$path" "SALTATO" "Impossibile determinare i timestamp dei pacchetti (file corrotto o non standard)"
        COUNT_SKIP=$((COUNT_SKIP + 1))
        continue
    fi

    start_diff=$(awk -v a="$v_start" -v b="$a_start" 'BEGIN{d=a-b; if(d<0)d=-d; print d}')
    end_diff=$(awk -v a="$v_end" -v b="$a_end" 'BEGIN{d=a-b; if(d<0)d=-d; print d}')

    is_desync=0
    details=""

    if awk -v d="$start_diff" -v t="$START_THRESHOLD" 'BEGIN{exit !(d>t)}'; then
        is_desync=1
        details=$(printf "DELAY INIZIALE RILEVATO: L'audio parte sfasato di %.3fs rispetto al video (Vid: %.3fs, Aud: %.3fs)" \
            "$start_diff" "$v_start" "$a_start")
    elif awk -v d="$end_diff" -v t="$END_THRESHOLD" 'BEGIN{exit !(d>t)}'; then
        is_desync=1
        details=$(printf "DISALLINEAMENTO IN CODA: Le tracce terminano con un divario di %.2fs (Vid: %.2fs, Aud: %.2fs)" \
            "$end_diff" "$v_end" "$a_end")
    fi

    if [ "$is_desync" -eq 0 ]; then
        err_check="$(ffmpeg -nostdin -v error -i "$path" -map 0:v:0? -map 0:a:0? -t 10 -f null - 2>&1)"
        if [ -n "$err_check" ]; then
            is_desync=1
            details="ERRORE METADATI/INTESTAZIONE: $(echo "$err_check" | tr ';' ',')"
        fi
    fi

    if [ "$is_desync" -eq 1 ]; then
        write_csv_line "$path" "DISALLINEATO_AUDIO_VIDEO" "$details"
        COUNT_ERR=$((COUNT_ERR + 1))
    else
        write_csv_line "$path" "OK" "-"
        COUNT_OK=$((COUNT_OK + 1))
    fi
done

echo
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

printf "\n=== Riepilogo Ispezione Analitica ===\n"
printf "OK:                         %d\n" "$COUNT_OK"
printf "Fuori Sincrono / Sfasati:   %d\n" "$COUNT_ERR"
printf "Saltati:                    %d\n" "$COUNT_SKIP"
printf "\nTempo totale di calcolo: %02d:%02d:%02d\n" $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60))
printf "Report generato in: %s\n" "$OUT_CSV"
