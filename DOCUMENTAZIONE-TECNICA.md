# steamlink-display-wrapper

Wrapper di lancio Steam per **Bazzite Game Mode**: durante il gioco la sessione Gamescope rende
**1920×1200 @ 60 Hz (16:10, target 60 FPS)** — il formato del client Steam Link — con monitor fisico
spento, e al termine ripristina **3440×1440 @ 165** e monitor ON.

Implementazione dell'analisi funzionale [`ANALISI-FUNZIONALE.md`](ANALISI-FUNZIONALE.md) (copia identica
del documento fornito, sha256 `bb198ce2cf45267a8da3c4bce27af9f210b42c93111e8e801cab6aca6273b3e2`), con
gli adattamenti d'ambiente richiesti dall'handoff (H2/H3/H7) e correzioni minime, tutte documentate sotto.

Dal 2026-09-29 implementa anche [`ANALISI-XWAYLAND-1.md`](ANALISI-XWAYLAND-1.md) (copia identica della
seconda analisi fornita, sha256 `8557c083162ed279e109368d96041c85f710e93e7c06288dcbbb123fb449994a`):
**sincronizzazione esplicita di Xwayland #1** con l'output prima dell'avvio del gioco.

Dal 2026-09-29 implementa inoltre
[`ANALISI-FUNZIONALE-PRIMA-CONNESSIONE.md`](ANALISI-FUNZIONALE-PRIMA-CONNESSIONE.md) (copia identica della
terza analisi fornita, sha256 `fb263ac439e20dd2f4fa9e4fa0987609d4b1d30d41991bc5660807f0c0ebe9b7`):
**correzione della prima connessione Steam Link** — il rilevamento non dipende più da un marker storico,
quindi la prima connessione segue lo stesso percorso delle successive (spec §5-§7, §14-§16).

## Installazione e uso (utente, senza root)

```bash
./install.sh
```

Installa in `~/.local/bin/` (`steam-link-virtual-display`, `steamlink-display-hook.sh`,
`steamlink-display-verify-environment`, `steamlink-display-restore`) e crea
`~/.config/steamlink-display/config` se assente.

Launch Option Steam del gioco:

```text
/home/USER/.local/bin/steam-link-virtual-display %command%
```

Comandi diretti:

- `steamlink-display-verify-environment` — diagnostica read-only dell'ambiente;
- `steamlink-display-restore` — recovery manuale conservativo (mai streaming mode);
- `bash tests/run-tests.sh` — suite hardware-free (sandbox + stub; nessun display reale toccato).

## Comportamento (gating su Steam Link, spec utente 2026-09-28)

- **Steam Link non attivo** (Desktop Mode o Gaming Mode senza streaming): nessuna modifica al display e
  nessun requisito Gamescope/gamescopectl/xprop/xdpyinfo — il wrapper lancia il comando del gioco
  direttamente (passthrough).
- **Steam Link attivo** (rilevato da `steam_link_streaming_active()` nell'hook, via sink/nodi PipeWire
  `steam-streaming-playback`): parte la pipeline — Gamescope/connettore → 1920×1200@60 → verifica →
  **sync Xwayland #1 → verifica root** → sleep monitor → gioco → ripristino completo (3440×1440@165 +
  Xwayland #1 riportato alla geometria locale).
- **Steam Link in avvio** (sink non ancora presente): il rilevamento apre una **finestra bounded
  event-driven** (`pactl subscribe`, con ri-verifica reale dello stato a ogni evento e a ogni scadenza di
  poll, `STREAM_DETECT_WAIT_SECONDS` default 5s) e aggancia la **creazione** del sink. Nessun marker
  storico richiesto: la prima connessione è trattata come tutte le altre (spec 2026-09-29).
- **Fail-closed**: solo quando lo streaming è attivo; se la preparazione output **o** la sincronizzazione
  di Xwayland #1 fallisce, il gioco non parte (nessuno screen sleep).
- **Recovery**: uno stato stantio viene recuperato **prima** della decisione, anche se Steam Link non è
  attivo, per non lasciare il display modificato dopo un'interruzione; il recupero ripristina anche la
  geometria di Xwayland #1 se la sessione precedente l'aveva sincronizzata.

## Sincronizzazione Xwayland #1 (spec 2026-09-29)

Gamescope tiene separati la modalità **output** (DP-3) e la modalità del **server Xwayland del gioco**
(#1): il cambio DRM non aggiorna #1, e Steam cattura una geometria incoerente (bug Valve
[steam-for-linux#13618](https://github.com/ValveSoftware/steam-for-linux/issues/13618) → assert
`libavutil/imgutils.c:350`). Da qui la sequenza obbligatoria: output → verifica → **sync Xwayland #1** →
verifica → avvio.

Meccanismo **misurato il 2026-09-29** su gamescope `3.16.28-ogc3+` (istanza annidata, `--xwayland-count 2`):

- ogni root Xwayland porta `GAMESCOPE_XWAYLAND_SERVER_ID` = il suo indice Gamescope; il mapping
  `DISPLAY ↔ indice` è **scoperto a runtime** e mai assunto (probe: `:1`→0, `:2`→1): il numero di
  `DISPLAY` non è l'indice.
- scrivere la property root
  `GAMESCOPE_XWAYLAND_MODE_CONTROL = [server_idx, width, height, allowSuperRes]`
  (`xprop -f ... 32c -set "1, 1024, 768, 0"`) fa chiamare a gamescope
  `wlserver_set_xwayland_server_mode(server_idx, w, h, g_nOutputRefresh)`; la root di #1 cambia davvero
  dimensione (journal: `wlserver: Updating mode for xwayland server #1: 1024x768@60`).
- gamescope **cancella la property** dopo averla gestita → la conferma non è il readback della property,
  ma la **geometria della root** di #1 (`xdpyinfo` dimensions).

Funzioni hook: `set_xwayland_server_mode()`, `set_stream_xwayland_mode()`, `get_xwayland_server_mode()`,
`verify_stream_xwayland_mode()`, `wait_for_stream_xwayland_mode()`, `restore_stream_xwayland_mode()`
(più `xwayland_display_for_server()` per il mapping).

Eventi nel `wrapper.log` (timestamp monotono relativo, formato `T<ms>ms <EVENTO> [dettaglio]`):
`STREAM_DETECTED`, `OUTPUT_PREPARE_START`, `OUTPUT_TARGET_REACHED`, `XWAYLAND1_SYNC_REQUESTED`,
`XWAYLAND1_SYNC_CONFIRMED`, `GAME_LAUNCH`, `XWAYLAND1_RESTORE`. Invariante applicata:
`XWAYLAND1_SYNC_CONFIRMED < GAME_LAUNCH` (`run_game` rifiuta l'avvio se violata).

Prova live (agente, 2026-09-29, gamescope annidato): `mapping server0 -> :1, server1 -> :2`;
`before: xwl1=1280x800` → `set ok` → `CONFIRMED` → `after: xwl1=1024x768` → `restore ok` →
`restored: xwl1=1280x800`, con le tre righe `wlserver: Updating mode for xwayland server #…` nel log di
gamescope.

### Prova live in **Gaming Mode reale** (2026-09-29 00:33)

Sessione Gaming Mode attiva (gamescope PID 447948, `--xwayland-count 2`):

- mapping reale `:0`→server 0, `:1`→server 1 (qui il numero di `DISPLAY` **coincide** con l'indice,
  a differenza del nested `:1`→0 / `:2`→1) → la scoperta a runtime di `GAMESCOPE_XWAYLAND_SERVER_ID`
  è necessaria.
- hook live: `set_xwayland_server_mode 1 1920 1080 0` → journal `Updating mode for xwayland server #1:
  1920x1080@60` e root di #1 a 1920x1080; `set_stream_xwayland_mode` (1920x1200) →
  `wait_for_stream_xwayland_mode` **CONFIRMED**.
- **misurato**: riportando l'output a 3440x1440@165, gamescope aggiorna **solo #0** — #1 resta alla
  geometria di streaming (la premessa della spec è confermata dal vivo).
- **gap trovato e corretto**: `steamlink-display-restore` ripristinava l'output ma lasciava #1 a
  1920x1200, perché il ripristino era gated sul campo `XWAYLAND_SYNCED` — assente in uno stato scritto
  da una build precedente. Ora cleanup/recovery/restore helper ripristinano #1 **ogni volta che lo stato
  del display è di proprietà del run** (snapshot proprio o stato stantio recuperato), indipendentemente
  dal campo; se il server #1 non esiste, l'operazione viene saltata e loggata come tale. Test dedicato
  sullo stato senza campo.

## Stato delle verifiche (Definition of Done §38)

| Voce | Stato | Prova |
|---|---|---|
| P1A — 1920×1200@60 nel DRM | fatto | `video=DP-3:1920x1200@60` nel cmdline; `1920x1200` in `/sys/class/drm/card1-DP-3/modes` (2026-09-28) |
| H2 — accesso Gamescope | fatto | `gamescopectl` verificato live (Connector DP-3, Make/Model corretti), in-session e da fuori sessione |
| H3 — mode list | fatto | atom assente su questa build; fallback kernel ModeDB usato in tutti i run reali (loggato) |
| H4 — description/modes.cfg | fatto | entry scritta/ripristinata correttamente in ogni run (backup = riga originale) |
| H5 — runtime mode switch | fatto | switch verificato live; ri-pick `@60→@164` accettato (fix); journal `selecting mode` come prova |
| H6 — screen sleep/wake | fatto | `dpms Off` letto durante i run; wake al cleanup (T1 e run reali) |
| R1–R5 — acceptance | parziale | run reali: gioco streamato e giocato (23:03, 23:06), uscita pulita + ripristino; resta il pattern di crash sugli avvii "puliti" (vedi sotto) |
| Sync Xwayland #1 (spec 2026-09-29) | fatto (meccanismo) | probe live 2026-09-29: mapping via `GAMESCOPE_XWAYLAND_SERVER_ID`, `GAMESCOPE_XWAYLAND_MODE_CONTROL` applicata e ripristinata; da confermare in sessione Gaming Mode col client |
| Unit test | fatto | `tests/run-tests.sh`: **31 test / 170 assert, tutti PASS** (sandbox + stub); comprende `first_stream_no_previous_marker`, `first_stream_after_crash_leftover`, `stream_sequence` (§16-19) |

## Test live (2026-09-28 sera, Gaming Mode)

- **T1** (gioco finto, nessuno stream): ciclo completo verificato — switch, sleep (`dpms Off`), wake,
  ripristino, stato pulito.
- **Run reali (Ghost of Tsushima, client Legion)**: 7 lanci — 2 completati (23:03, 23:06: gioco giocato,
  uscita 0, ripristino pulito) e 5 caduti con crash di **Steam/gamescope** nella pipeline di cattura
  (`libavutil/imgutils.c:350`, `pipes.cpp:682/900`), sempre pochi secondi dopo il lancio; tutti gli
  avvii "puliti" sono caduti, tutti i run preceduti da **recupero stato** sono sopravvissuti.
- I crash non sono mai nel wrapper: sempre nella pipeline streaming di Steam; il wrapper non lascia mai
  stato parziale permanente (il run successivo recupera; cleanup verificati).
- **Gating Steam Link (spec utente, 23:20)**: in Desktop Mode il wrapper passa in bypass e lancia il
  comando direttamente (verificato live: `rc=0`, nessuna modifica a modes.cfg/dpms); con stream rilevato
  ma Gamescope non disponibile il gioco **non** viene avviato (fail-closed, verificato live).
- **Race al lancio (23:25-23:29)**: misurato che la sessione viene (ri)stabilita 1-2s dopo l'avvio del
  gioco; fix con attesa bounded (Scostamento 11).
- **Causa dei crash = bug noto di Steam** ([steam-for-linux#13618](https://github.com/ValveSoftware/steam-for-linux/issues/13618)):
  aspect diverso tra cattura host e stream richiesto → VAAPI/DMA-BUF rifiutato → assert FFmpeg → riavvio
  di Steam (stessa firma e build `1788652215`). Rimedio: **display host matchato al client prima della
  cattura** (= lo switch del wrapper); osservato un crash anche in passthrough puro → conferma lato Steam.
- **Validazione simulata in Gaming Mode reale (agente, 23:42-23:44)**: con un sink PipeWire
  `steam-streaming-playback` simulato → pipeline completa verificata (switch `@60→@164`, `dpms Off`,
  ripristino); con marker iniettato + sink a +1,5s → l'attesa anti-race aggancia la sessione; `SIGTERM`
  durante lo streaming → cleanup e ripristino corretti (rc 143 conservato).

## Scostamenti dal documento (motivati)

1. **Hook — re-poll mode (H2/H5).** Da `xprop GAMESCOPE_DISPLAY_MODE_NUDGE` a
   `gamescopectl backend_set_dirty`: l'atomo non esiste su questa build (probe 2026-09-28);
   `backend_set_dirty` è il comando di re-poll del backend nel catalogo di gamescope.
2. **Hook — lettura mode corrente (H7).** Da `xdpyinfo` + atomo refresh al journal:
   `journalctl --user -b -g 'selecting mode \[0-9\]'` → ultima riga `drm: selecting mode WxH@RHz`.
   Geometria X e atomo refresh non rappresentano il DRM mode della sessione.
3. **Hook — mode list (H3).** Atom quando presente; fallback sul kernel ModeDB del connettore
   (`DRM_MODES_GLOB`, default `/sys/class/drm/card*-DP-3/modes`). Il refresh esatto resta garantito dalla
   verifica post-switch, comunque prima di ogni screen sleep.
4. **Wrapper — cleanup (sicurezza dati).** `modes.cfg` viene ripristinato solo se esiste uno snapshot di
   *questo* run o di uno stato stantio recuperato (`BACKUP_TAKEN`/`STALE_STATE_LOADED`): prima, un precheck
   fallito poteva cancellare `~/.config/gamescope/modes.cfg` (bug riprodotto nei test).
5. **Wrapper — sleep fail-closed.** `SCREEN_SLEEP_REQUESTED=1` impostato *prima* della chiamata: un
   fallimento di `drm_sleep_external_screen` aborta il lancio e il cleanup tenta comunque il wake
   (invariante "cleanup ⇒ monitor ON"). Re-poll fallito loggato esplicitamente.
6. **Wrapper — precheck.** Aggiunto `require_cmd journalctl` (dipendenza introdotta dall'adattamento H7).
7. **Restore helper — robustezza.** Default per `MODES_FILE`, `MODE_TIMEOUT_SECONDS`,
   `POLL_INTERVAL_SECONDS`: senza config installata il helper usciva a metà (unbound variable) senza
   pulire stato né disabilitare i dynamic modes (bug riprodotto nei test).
8. **Test.** Aggiunta `tests/` (23 test / 103 assert). Stub: `gamescopectl`, `xprop`, `xdpyinfo`,
   `journalctl`, `pactl`, `pw-cli`; tutto in sandbox `$TMPDIR`, HOME/XDG redirezionati.
9. **Wrapper — warm-up re-poll (candidata, in validazione).** Prima dello switch, un re-poll extra al
   mode locale (`set_dynamic 1` + nudge + breve attesa) per riprodurre il ciclo di recovery che il
   2026-09-28 ha preceduto **3/3 lanci sopravvissuti**, mentre gli avvii "puliti" diretti sono caduti
   **5/5** nella pipeline di cattura Steam (assert `libavutil/imgutils.c:350` / `pipes.cpp`). Da
   validare al prossimo avvio pulito; rimovibile togliendo il blocco in `prepare_stream_mode`.
10. **Wrapper — gating su Steam Link (spec utente 2026-09-28).** La pipeline display parte solo con una
    sessione di streaming attiva (`steam_link_streaming_active()` nell'hook); altrimenti passthrough
    diretto del comando del gioco. Fail-closed solo ad streaming attivo; recovery con priorità sul bypass.
11. **Hook — finestra di rilevamento anti-race, ora event-driven e senza marker (spec 2026-09-28,
    riscritta dalla spec 2026-09-29).** Misurato: nei lanci verso il client l'host (ri)stabilisce la
    sessione di stream ~1-2s **dopo** l'avvio del gioco → il check al lancio la vedeva "inattiva". La
    vecchia attesa era però **condizionata a un marker storico** (`_sl_stream_cycle_recent`): alla prima
    connessione, senza marker, si finiva in `return 1` → bypass → stream a 21:9. Ora la finestra si apre
    quando il sink è assente, usa `pactl subscribe` (evento reale di creazione) con ri-verifica dello
    stato a ogni evento e a ogni scadenza di poll, e dura al più `STREAM_DETECT_WAIT_SECONDS` (default 5s).
    Il marker (journal + log Steam) resta **solo diagnostico** (`marker=` nell'evento `STREAM_WAIT_START`).
12. **Hook/wrapper — sincronizzazione Xwayland #1 (spec 2026-09-29).** Aggiunti `set_xwayland_server_mode()`
    e le funzioni derivate; `prepare_stream_mode()` non completa più con la sola verifica DRM, ma richiede
    `OUTPUT VERIFIED AND XWAYLAND #1 VERIFIED`; `run_game` è gated dall'invariante temporale. Nuove chiavi
    di config `STREAM_XWAYLAND_SERVER_INDEX=1`, `STREAM_XWAYLAND_ALLOW_SUPERRES=0`, `XWAYLAND_SCAN_MAX`,
    `XWAYLAND_EXTRA_DISPLAYS`; il file di stato porta `XWAYLAND_SYNCED` per il recovery.
13. **Cleanup/recovery/restore helper — Xwayland #1.** Il cleanup e il recovery riportano #1 a
    `LOCAL_WIDTHxLOCAL_HEIGHT` (best-effort, con attesa bounded) per non lasciare la geometria di streaming
    in sessione locale; il restore helper manuale legge `XWAYLAND_SYNCED` dallo stato.
    *Nota (non implementato, non richiesto dal documento):* la modalità locale resta `LOCAL_*` di config
    (3440×1440@165), non rilevata dinamicamente — §12 la indica come "idealmente", con 3440×1440@165 come
    default atteso.
14. **Ripristino di Xwayland #1 non legato al flag (fix dal test live in Gaming Mode, 2026-09-29).**
    Misurato: riportando l'output a 3440x1440@165 gamescope aggiorna solo il server #0, e uno stato scritto
    dalla build precedente non porta `XWAYLAND_SYNCED` → il restore helper lasciava #1 a 1920x1200. Ora il
    ripristino avviene ogni volta che il run possiede lo stato del display (snapshot proprio o stato
    stantio recuperato), con skip esplicito se il server #1 non esiste. Il campo `XWAYLAND_SYNCED` resta
    nel file di stato come informazione diagnostica.
15. **Hook — prima connessione senza marker (spec 2026-09-29).** `_sl_wait_for_stream_signal()` sostituisce
    l'attesa condizionata: se il sink è assente si osserva la sua **creazione** (`pactl subscribe`),
    ri-verificando sempre lo stato reale del sink; fallback a polling bounded se `pactl` manca; nessuno
    strumento di query → nessuna attesa. Eventi nuovi: `STREAM_SIGNAL_CURRENT`, `STREAM_WAIT_START`,
    `STREAM_SIGNAL_EVENT`, `STREAM_SIGNAL_CONFIRMED`.
16. **Hook — gate Gamescope per la finestra (spec §17).** In Desktop Mode (nessuna sessione Gamescope
    raggiungibile via `gamescopectl`) la finestra **non** viene aperta: il lancio locale resta immediato.
    La presenza di gamescope/gamescopectl **non** è mai letta come prova di una sessione Steam Link (§8);
    il gate agisce solo quando il sink è assente e serve a soddisfare §17 (Desktop Mode → avvio immediato).
17. **Wrapper — fasi di stato (spec §12).** Aggiunte `PREPARED` (output + Xwayland #1 verificati, prima di
    `GAME_LAUNCH`) e `RESTORING` (inizio cleanup); il recovery continua a funzionare su qualunque fase. 
## Valutazione watcher `systemd --user` (spec §9/§10/§24 terza correzione)

La spec chiede di **valutare** un watcher persistente event-driven per eliminare ogni attesa nel gioco
locale. Esito della valutazione (stato attuale: **non implementato**):

- il watcher è l'unico modo di soddisfare insieme §9 ("Steam Link chiaramente non attivo → bypass") e §5
  — senza di esso la finestra del wrapper è inevitabilmente aperta anche per un lancio locale, perché a
  runtime non esiste, prima della creazione del sink, un segnale PipeWire che distingua "in avvio" da
  "non attivo". L'unico segnale *live* pre-sink sarebbe la connessione del client Remote Play (il client
  precede lo stream di ~20s), non ancora verificato su questa build;
- un watcher che cambia la modalità del display va validato **in Gaming Mode con un client reale** prima
  di essere abilitato; in questa finestra non c'è un client disponibile, quindi abilitarlo ora
  significherebbe spedire non validato un servizio che tocca l'output;
- vincoli già noti dalla skill `steam-remote-play` (`references/host-mode-watcher.md`): unit **session-bound**
  (`WantedBy=gamescope-session-plus@<client>.service`), **mai** `graphical-session.target` (che Desktop Mode
  raggiunge); `Restart=always`; guardia `pgrep -f '^/usr/bin/gamescope'`; stato condiviso con il wrapper
  (stesso `STATE_DIR`/lock) e idempotenza "already prepared → verify only"; il cambio di mode va fatto
  **prima** dell'inizio della cattura, mai mid-stream (altrimenti abort di Steam).

Il wrapper implementa già il proprio lato dell'architettura §10: controllo finale, verifica di output e
Xwayland #1, invariante `XWAYLAND1_SYNC_CONFIRMED < GAME_LAUNCH`, fail-closed. Un watcher, quando costruito,
si innesterà su `STATE_DIR`/`lock` senza modificare questa logica (il wrapper non si fida ciecamente dello
stato prodotto dal watcher, come richiesto da §24 quarta correzione).

## Verifica in sessione (Game Mode) — da completare

Richiede una finestra in Gaming Mode con l'utente presente:

1. `~/.local/bin/steamlink-display-verify-environment` → raccolta ambiente (connector, gamescopectl, atomi);
2. lanciare un gioco con la Launch Option → attesi: monitor OFF, mode `1920x1200@60` (journal:
   `drm: selecting mode 1920x1200@60Hz`), `wrapper.log` con "Verified target mode";
3. lato Steam: `~/.local/share/Steam/logs/streaming_log.txt` → `setting capture size 1920x1200` e
   `CLIENT: Video rect: 1920x1200 at 0,0`;
4. uscire dal gioco → monitor ON, `3440x1440@165`, `wrapper.log` con "Verified local mode", stato pulito;
5. ripetere per R3 (SIGTERM/SIGINT/SIGHUP) e stale-state sul campo.

## Note operative

- Non toccati di proposito: `~/.config/gamescope/{bootstrap.cfg,edid.bin,modes.cfg}` (preesistenti).
- Fail-closed: nessuno screen sleep senza verifica reale del mode target.
- Log: `~/.local/state/steamlink-display/wrapper.log`; stato: `state`; lock: `lock`; snapshot:
  `modes.cfg.backup`.
