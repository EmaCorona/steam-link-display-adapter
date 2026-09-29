# steam-link-display-adapter

Wrapper di lancio **Steam** per **Bazzite Game Mode** (sessione gamescope): durante lo streaming
**Steam Link / Remote Play** porta la sessione al formato del client — risolto **dinamicamente** dal client
(es. **1920×1200 @ 60 Hz, 16:10** per un handheld; 1920×1080 per un client 16:9) — con il monitor fisico
spento, e ripristina tutto alla fine del gioco.

Nasce per un host **ultrawide** (3440×1440, 21:9) che deve servire un client **16:10** (es. un handheld):
senza commutare l'output, Steam cattura il desktop in 21:9 e il client riceve barre nere.

## Come funziona (in breve)

- Si inserisce come **Launch Option** del gioco: non modifica Steam, Proton, Wine, DXVK/VKD3D.
- **Se una sessione Steam Link è attiva** (o **sta iniziando**): legge la geometria dichiarata dal client
  (`Maximum capture` nel log Steam, se recente), la risolve contro i mode realmente disponibili sull'host
  e commuta l'output Gamescope a quel target, **sincronizza il server Xwayland #1** (quello del gioco) alla
  stessa geometria, spegne il monitor fisico e avvia il gioco.
- **Senza hint client valido** (o con `STREAM_MODE=fixed`): usa la modalità configurata di fallback
  (`1920×1200@60`).
- **Con `--mode` nelle Launch Options** (es. `--mode 1920x1200`) l'override per-gioco ha la
  precedenza sulla config globale e su `auto` (vedi *Override per-gioco*).
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
git clone https://github.com/EmaCorona/steam-link-display-adapter.git
cd steam-link-display-adapter
./install.sh
```

Installa in `~/.local/bin/`:

- `steam-link-display-adapter` (il wrapper da usare come Launch Option)
- `steam-link-display-adapter-hook.sh`, `steam-link-display-adapter-verify-environment`, `steam-link-display-adapter-restore`

e crea `~/.config/steam-link-display-adapter/config` se assente. **Nessun root richiesto**; una configurazione
utente esistente non viene sovrascritta.

### Migrazione da un'installazione precedente

Le installazioni precedenti usavano un namespace diverso. Le directory e l'executable qui sotto
appartengono alla **vecchia** installazione e **non** sono usati né creati dalla nuova versione:

```text
~/.config/steamlink-display/             <!-- intentional-legacy -->
~/.local/state/steamlink-display/        <!-- intentional-legacy -->
~/.local/bin/steam-link-virtual-display  <!-- intentional-legacy -->
```

L'installer **non** cancella automaticamente questi dati (§35). Dopo aver verificato che non esista più
uno stato attivo della vecchia installazione, rimuovili manualmente e reinstalla con `./install.sh`.
Il nuovo namespace è `steam-link-display-adapter`; non esiste alcun alias o symlink di compatibilità.

Poi, nelle **Launch Options** del gioco su Steam:

```text
/home/USER/.local/bin/steam-link-display-adapter %command%
```

## Configurazione

`~/.config/steam-link-display-adapter/config` (creato dall'installer da `steam-link-display-adapter.conf.example`):
connettore, `STREAM_MODE` (`auto`/`fixed`), geometria di streaming (target in `fixed`, fallback in `auto`),
freschezza dell'hint client (`STREAM_CAPTURE_HINT_MAX_AGE_SECONDS`), policy `STREAM_NO_COMPATIBLE_FALLBACK`,
risoluzione/refresh locali, tempi di attesa, percorsi di stato e log.

## Override per-gioco (`--mode`)

Le Launch Options accettano un override esplicito del target, valido solo per quel gioco e senza toccare la
configurazione globale. Priorita': `--mode` (Launch Option) > `STREAM_MODE` globale > `auto`.

```text
steam-link-display-adapter %command%                     # AUTO (dinamico dal client)
steam-link-display-adapter --mode auto %command%         # AUTO esplicito
steam-link-display-adapter --mode 1920x1200 %command%    # geometria forzata, refresh automatico
```

- `--mode 1920x1200` blocca **solo** la geometria: il refresh viene scelto automaticamente dal resolver
  tra i mode disponibili sull'host (non coincide necessariamente con `1920x1200@60`).
- Il refresh **non** e' specificabile dalle Launch Options: `--mode 1920x1200@60` e' **invalido** e viene
  rifiutato prima di qualsiasi modifica. Se la risoluzione non e' disponibile la sessione e' **fail-closed**
  (nessuna sostituzione automatica, il gioco non parte).
- Gli argomenti del gioco dopo `%command%` sono inoltrati invariati; l'override non e' mai passato al gioco.
- `--help` stampa l'uso. In Desktop Mode / Gaming Mode senza stream l'override non tocca il display.

## Diagnostica e recupero

```bash
steam-link-display-adapter-verify-environment   # read-only: connettore, gamescopectl, atomi X, DRM
steam-link-display-adapter-restore              # recupero manuale conservativo (mai streaming mode)
```

Log: `~/.local/state/steam-link-display-adapter/wrapper.log`. Nella stessa directory: `state`, `lock`,
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
| `steam-link-display-adapter.sh` | wrapper di lancio: precheck, lock, stato, cleanup, exit code |
| `steam-link-display-adapter-hook.sh` | integrazione Gamescope/DRM, rilevamento Steam Link, sync Xwayland #1 |
| `steam-link-display-adapter-verify-environment.sh` | diagnostica read-only dell'ambiente |
| `steam-link-display-adapter-restore.sh` | recupero manuale conservativo |
| `steam-link-display-adapter.conf.example` | configurazione di esempio |
| `install.sh` | installazione utente |
| `tests/` | suite hardware-free |
| `DOCUMENTAZIONE-TECNICA.md` | dettagli implementativi, misure ed elenco degli scostamenti |
| `ANALISI-FUNZIONALE.md`, `ANALISI-XWAYLAND-1.md`, `ANALISI-FUNZIONALE-PRIMA-CONNESSIONE.md`, `ANALISI-RISOLUZIONE-DINAMICA.md`, `ANALISI-CLI-MODE.md`, `ANALISI-RIMOZIONE-FPS-CLI.md` | analisi funzionali di riferimento |

## Limiti noti

- Il rilevamento della sessione Steam Link è **event-driven**: se il sink non è ancora presente il wrapper
  apre una finestra bounded (default 5 s) e aggancia la **creazione** della sessione, quindi anche la
  **prima connessione** segue lo stesso percorso delle successive. In **Desktop Mode** (nessuna sessione
  gamescope) il lancio resta immediato; in Gaming Mode senza stream il lancio attende al più la finestra.
  Dettagli e misure in `DOCUMENTAZIONE-TECNICA.md`.
- La geometria dinamica dipende dalle righe `Maximum capture` del log Steam dell'host, **lette una sola
  volta** prima della preparazione e considerate valide solo se recenti (default 10 s): il target non cambia
  a stream avviato. Se il mode del client non esiste sull'host, il resolver sceglie il mode compatibile per
  aspect (o il fallback, secondo `STREAM_NO_COMPATIBLE_FALLBACK`), mai un mode arbitrario.
- Nessun cleanup dopo SIGKILL, panic o power loss; lo stato residuo viene recuperato al lancio successivo.
- Lo streaming della sola **UI** (Big Picture) prima dell'avvio del gioco non viene commutato: il wrapper
  agisce dal lancio del gioco.
