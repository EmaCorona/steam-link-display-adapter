# steam-link-virtual-display-bazzite

Wrapper di lancio **Steam** per **Bazzite Game Mode** (sessione gamescope): durante lo streaming
**Steam Link / Remote Play** porta la sessione al formato del client — **1920×1200 @ 60 Hz (16:10)** — con
il monitor fisico spento, e ripristina tutto alla fine del gioco.

Nasce per un host **ultrawide** (3440×1440, 21:9) che deve servire un client **16:10** (es. un handheld):
senza commutare l'output, Steam cattura il desktop in 21:9 e il client riceve barre nere.

## Come funziona (in breve)

- Si inserisce come **Launch Option** del gioco: non modifica Steam, Proton, Wine, DXVK/VKD3D.
- **Se una sessione Steam Link è attiva** (o **sta iniziando**): commuta l'output Gamescope a 1920×1200@60, **sincronizza il
  server Xwayland #1** (quello del gioco) alla stessa geometria, spegne il monitor fisico e avvia il gioco.
- **Alla fine** (uscita normale o SIGTERM/SIGINT/SIGHUP): riaccende il monitor, ripristina la modalità
  locale e la geometria di Xwayland #1.
- **Fail-closed**: il monitor non viene mai spento se la modalità target non è stata verificata; se la
  preparazione fallisce il gioco non parte.
- **Nessuna sessione Steam Link attiva** (Desktop Mode o Gaming Mode senza stream): il comando del gioco
  viene eseguito direttamente, senza toccare il display.

## Requisiti

- Bazzite in **Gaming Mode** (gamescope standalone) e Steam Link / Remote Play.
- La modalità target deve esistere nel ModeDB del kernel del connettore, es. `video=DP-3:1920x1200@60`
  nel cmdline; verifica read-only: `cat /sys/class/drm/card*-DP-3/modes`.
- Comandi richiesti: `gamescopectl`, `xprop`, `xdpyinfo`, `flock`, `journalctl`, `pactl`/`pw-cli`.

## Installazione

```bash
git clone https://github.com/EmaCorona/steam-link-virtual-display-bazzite.git
cd steam-link-virtual-display-bazzite
./install.sh
```

Installa in `~/.local/bin/`:

- `steam-link-virtual-display` (il wrapper da usare come Launch Option)
- `steamlink-display-hook.sh`, `steamlink-display-verify-environment`, `steamlink-display-restore`

e crea `~/.config/steamlink-display/config` se assente. **Nessun root richiesto**; una configurazione
utente esistente non viene sovrascritta.

Poi, nelle **Launch Options** del gioco su Steam:

```text
/home/USER/.local/bin/steam-link-virtual-display %command%
```

## Configurazione

`~/.config/steamlink-display/config` (creato dall'installer da `steamlink-display.conf.example`):
connettore, risoluzione/refresh di streaming e locali, tempi di attesa, percorsi di stato e log.

## Diagnostica e recupero

```bash
steamlink-display-verify-environment   # read-only: connettore, gamescopectl, atomi X, DRM
steamlink-display-restore              # recupero manuale conservativo (mai streaming mode)
```

Log: `~/.local/state/steamlink-display/wrapper.log`. Nella stessa directory: `state`, `lock`,
`modes.cfg.backup`.

## Test

```bash
bash tests/run-tests.sh
```

Suite *hardware-free* (sandbox + stub di `gamescopectl`/`xprop`/`xdpyinfo`/`journalctl`/PipeWire): nessun
display, sessione gamescope o gioco reale viene toccato.

## File

| File | Ruolo |
|---|---|
| `steamlink-display-wrapper.sh` | wrapper di lancio: precheck, lock, stato, cleanup, exit code |
| `steamlink-display-hook.sh` | integrazione Gamescope/DRM, rilevamento Steam Link, sync Xwayland #1 |
| `steamlink-display-verify-environment.sh` | diagnostica read-only dell'ambiente |
| `steamlink-display-restore.sh` | recupero manuale conservativo |
| `steamlink-display.conf.example` | configurazione di esempio |
| `install.sh` | installazione utente |
| `tests/` | suite hardware-free |
| `DOCUMENTAZIONE-TECNICA.md` | dettagli implementativi, misure ed elenco degli scostamenti |
| `ANALISI-FUNZIONALE.md`, `ANALISI-XWAYLAND-1.md`, `ANALISI-FUNZIONALE-PRIMA-CONNESSIONE.md` | analisi funzionali di riferimento |

## Limiti noti

- Il rilevamento della sessione Steam Link è **event-driven**: se il sink non è ancora presente il wrapper
  apre una finestra bounded (default 5 s) e aggancia la **creazione** della sessione, quindi anche la
  **prima connessione** segue lo stesso percorso delle successive. In **Desktop Mode** (nessuna sessione
  gamescope) il lancio resta immediato; in Gaming Mode senza stream il lancio attende al più la finestra.
  Dettagli e misure in `DOCUMENTAZIONE-TECNICA.md`.
- Nessun cleanup dopo SIGKILL, panic o power loss; lo stato residuo viene recuperato al lancio successivo.
- Lo streaming della sola **UI** (Big Picture) prima dell'avvio del gioco non viene commutato: il wrapper
  agisce dal lancio del gioco.
