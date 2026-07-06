# Controlla Sync Audio/Video MP4

Script bash per individuare automaticamente file `.mp4` con **audio e video fuori sincrono**, analizzando i timestamp reali dei pacchetti (PTS) invece di affidarsi ai soli metadati del contenitore, spesso inaffidabili.

File: **`controlla_mp4_video.sh`** — testato su Debian, compatibile con qualsiasi distribuzione Linux con Bash ≥ 4.

---

## Come funziona

Per ogni file `.mp4` trovato (ricorsivamente, incluse le sottocartelle), lo script:

1. **Verifica che siano presenti sia una traccia video che una audio.** Se manca una delle due, il file viene marcato come `SALTATO` (il confronto non è applicabile).
2. **Calcola il PTS del primo pacchetto** di ciascuna traccia (leggendo i primi N pacchetti e prendendo il minimo, per tollerare il riordino dovuto ai B-frame) → rileva un **delay iniziale** tra audio e video.
3. **Calcola il PTS dell'ultimo pacchetto** di ciascuna traccia (leggendo solo la coda del file, vicino a EOF, per restare veloce anche su file molto grandi) → rileva un **disallineamento in coda** (una traccia che finisce prima/dopo l'altra).
4. Se i timestamp risultano coerenti, esegue un **controllo veloce sui primi 10 secondi** con `ffmpeg` per intercettare errori macroscopici di metadati/intestazione.
5. Scrive il risultato in un **report CSV**, una riga per file.

## Requisiti

- **`ffmpeg`** e **`ffprobe`** installati e disponibili nel `PATH`
  ```bash
  sudo apt update
  sudo apt install ffmpeg
  ```
- **Bash ≥ 4** (di serie su Debian e quasi tutte le distribuzioni)

## Uso

```bash
chmod +x controlla_mp4_video.sh
./controlla_mp4_video.sh -d /percorso/della/cartella
```

Opzioni disponibili:

| Opzione | Descrizione                                              | Default |
|---------|-----------------------------------------------------------|---------|
| `-d`    | Cartella da analizzare (ricorsiva)                         | `.`     |
| `-o`    | Cartella dove salvare il report (utile se la cartella scansionata è di sola lettura) | cartella scansionata, o `$HOME` se non scrivibile |
| `-s`    | Soglia disallineamento iniziale (secondi)                  | `0.15`  |
| `-e`    | Soglia disallineamento finale (secondi)                    | `0.40`  |
| `-p`    | Numero di pacchetti letti per stimare l'inizio traccia     | `15`    |
| `-k`    | Secondi da EOF da cui iniziare a leggere per la fine traccia | `5.0` |

Esempio con soglie personalizzate e report salvato altrove:

```bash
./controlla_mp4_video.sh -d /media/samuel/Film2TB -o ~/report -s 0.2 -e 0.5
```

Per analisi lunghe su grandi archivi, conviene lanciarlo in background:

```bash
nohup ./controlla_mp4_video.sh -d /media/samuel/Film2TB > log.txt 2>&1 &
tail -f log.txt
```

## Il report

Il file generato (`report_video_linux.csv`) ha 3 colonne separate da `;`:

```
file;stato;dettagli
```

**Stati possibili:**

| Stato                        | Significato                                                        |
|-------------------------------|---------------------------------------------------------------------|
| `OK`                          | Audio e video sincronizzati entro le soglie impostate                |
| `DISALLINEATO_AUDIO_VIDEO`    | Rilevato delay iniziale, disallineamento in coda, o errore metadati  |
| `SALTATO`                     | Manca una traccia (solo video o solo audio), o i timestamp non sono determinabili |

Esempi di lettura rapida del report da terminale:

```bash
# Solo i file problematici
grep -v ';OK;' report_video_linux.csv

# Solo i disallineati
grep 'DISALLINEATO' report_video_linux.csv

# Vista a colonne leggibile
column -t -s ';' report_video_linux.csv | less -S
```

## Note e limiti

- **Encoder delay AAC**: alcuni encoder audio (tipicamente AAC) inseriscono un piccolo "priming delay" del tutto normale nei primi campioni. Se noti troppi falsi positivi sul delay iniziale, prova ad alzare leggermente la soglia (`-s`) e verifica su file che sai già essere sincronizzati.
- **File molto corti**: se un file è più corto del valore di `-k`, lo script esegue automaticamente un fallback leggendo l'intero file per determinare l'ultimo pacchetto.
- **Prestazioni**: per ogni file vengono lanciati diversi processi `ffprobe` più un controllo `ffmpeg`. Su archivi molto grandi (migliaia di file) l'analisi completa può richiedere diverse ore.
- **Permessi**: se la cartella analizzata non è scrivibile dall'utente corrente (es. mount con proprietario `root`), lo script salva automaticamente il report in `$HOME` (oppure nella cartella indicata con `-o`) invece di interrompersi con un errore.
- Il controllo non decodifica l'intero file (tranne i primi 10 secondi per il check finale), quindi resta relativamente veloce anche su video di grandi dimensioni.

## Licenza

Nessuna licenza particolare — usa, modifica e condividi liberamente.
