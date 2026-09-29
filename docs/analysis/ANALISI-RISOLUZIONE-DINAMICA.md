# Analisi funzionale — Risoluzione Gamescope dinamica in base al client Steam Link

## 1. Obiettivo

Estendere `steam-link-display-adapter` affinché la risoluzione utilizzata da Gamescope durante una sessione Steam Link venga determinata dinamicamente in base alla risoluzione e al frame rate dichiarati dal client.

L'implementazione deve mantenere integralmente il comportamento attualmente funzionante:

```text
Steam Link attivo
    ↓
rilevamento sessione
    ↓
preparazione output Gamescope
    ↓
sincronizzazione Xwayland #1
    ↓
monitor fisico OFF
    ↓
gioco
    ↓
restore
```

La modifica deve sostituire soltanto il valore fisso:

```text
1920x1200@60
```

con un valore risolto dinamicamente.

La modalità attuale deve rimanere disponibile come fallback.

---

# 2. Risultato desiderato

Attualmente il progetto utilizza:

```text
client → qualsiasi
host Gamescope → 1920x1200
```

Il comportamento desiderato diventa:

```text
client
   ↓
Steam Maximum capture
   ↓
client hint
   ↓
mode resolver
   ↓
host mode compatibile
   ↓
Gamescope output
   ↓
Xwayland #1
   ↓
Steam capture
```

Esempi:

```text
Legion Go S
1920x1200 @ 60
        ↓
Gamescope
1920x1200

Steam Deck
1280x800 @ 89
        ↓
Gamescope
1280x800
oppure mode compatibile 16:10

Client 1920x1080 @ 60
        ↓
Gamescope
1920x1080
```

Il valore effettivo dipende sempre dai mode realmente disponibili sull'host.

---

# 3. Fonte del dato del client

Steam, lato host, scrive nel proprio `streaming_log.txt` una riga del tipo:

```text
[2026-09-29 01:00:00][...] Maximum capture: 1920x1200 60.00 FPS
```

La stessa tecnica è utilizzata dal progetto `remoteplay-display`, che interpreta la riga come limite di cattura dichiarato dal client. Quel progetto utilizza un parser equivalente a:

```regex
^
\[(timestamp)\]
\[...\]
Maximum capture: (\d+)x(\d+) ([\d.]+) FPS
$
```

e restituisce:

```text
width
height
fps
```

con un controllo di freschezza dell'hint.

Questo dato deve essere interpretato come:

> **client capture capability / client capture ceiling**

e non come prova assoluta dell'EDID fisico del monitor del client.

Per lo scopo del progetto è comunque il dato corretto da utilizzare per decidere la geometria della cattura Steam.

---

# 4. Requisito fondamentale: hint appartenente alla sessione corrente

Non deve essere utilizzata indiscriminatamente l'ultima riga `Maximum capture` del file.

Esempio da evitare:

```text
sessione precedente:
Maximum capture: 1920x1200 60 FPS

nuova sessione:
client = 1280x800 89 FPS

resolver:
legge ancora 1920x1200
```

Questo produrrebbe una configurazione errata.

L'hint deve essere considerato valido soltanto se è sufficientemente recente rispetto alla sessione appena rilevata.

Il progetto di riferimento usa un limite temporale configurabile per la freschezza dell'hint.

Per questo progetto introdurre:

```text
STREAM_CAPTURE_HINT_MAX_AGE_SECONDS
```

con default iniziale:

```text
10 secondi
```

Il valore deve essere configurabile.

Non utilizzare i precedenti `STREAM_DETECT_WINDOW_SECONDS=180` come criterio di validità del capture hint.

I 180 secondi appartengono al rilevamento storico della sessione, non alla validità della risoluzione client.

---

# 5. Integrazione con l'attuale rilevamento della sessione

Il rilevamento event-driven già implementato deve essere mantenuto.

L'attuale comportamento:

```text
sink assente
    ↓
pactl subscribe
    ↓
steam-streaming-playback compare
    ↓
sessione confermata
```

è il meccanismo corretto.

La nuova sequenza diventa:

```text
steam-streaming-playback assente
        ↓
STREAM_WAIT_START
        ↓
pactl subscribe
        ↓
evento sink
        ↓
verifica sink realmente presente
        ↓
STREAM_SIGNAL_CONFIRMED
        ↓
leggi Maximum capture recente
```

Questo deve funzionare anche alla prima connessione, senza dipendere da marker storici.

---

# 6. Cattura dell'hint

Implementare nell'hook una funzione dedicata, ad esempio:

```text
get_latest_stream_capture_hint()
```

che restituisca:

```text
CLIENT_WIDTH
CLIENT_HEIGHT
CLIENT_FPS
```

oppure un codice di errore / nessun risultato.

Percorsi configurabili:

```text
STEAM_STREAM_LOG
STEAM_STREAM_LOG_PREV
```

con default coerenti con l'attuale installazione Steam.

La ricerca deve essere effettuata preferibilmente sulla parte finale del log e non sull'intero file.

Il comportamento può seguire l'approccio già utilizzato dal progetto `remoteplay-display`: lettura di una porzione finale del file e scansione delle righe in ordine inverso, fino al primo `Maximum capture` valido.

---

# 7. Correlazione temporale

La correlazione ideale è:

```text
Maximum capture
        ↓
steam-streaming-playback
```

Il progetto di riferimento osserva che Steam scrive `Maximum capture` pochi millisecondi prima della creazione del sink.

Perciò, una volta confermato il sink:

```text
STREAM_SIGNAL_CONFIRMED
        ↓
get_latest_stream_capture_hint()
```

deve essere in grado di trovare l'hint appena prodotto.

Loggare sempre:

```text
CLIENT_HINT 1920x1200@60
```

oppure:

```text
CLIENT_HINT unavailable
```

oppure:

```text
CLIENT_HINT stale
```

---

# 8. Fallback

Il comportamento fallback è fondamentale per evitare regressioni.

Se il client hint non esiste, non è parsabile o è troppo vecchio:

```text
client hint unavailable
        ↓
usa modalità configurata
```

La configurazione attuale rimane:

```text
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
```

Questa configurazione deve quindi diventare **fallback**, non essere rimossa.

Comportamento:

```text
hint valido
    → AUTO

hint non valido
    → FALLBACK 1920x1200@60
```

Il fallback deve essere esplicitamente visibile nei log:

```text
CLIENT_MODE_SOURCE=fallback
TARGET_MODE=1920x1200@60
```

---

# 9. Modalità configurabile

Introdurre una configurazione:

```text
STREAM_MODE='auto'
```

Valori ammessi:

```text
auto
fixed
```

### `auto`

Utilizza il client hint.

### `fixed`

Mantiene esattamente il comportamento precedente:

```text
STREAM_WIDTH
STREAM_HEIGHT
STREAM_REFRESH
```

Questo permette di disattivare immediatamente la funzionalità dinamica in caso di incompatibilità.

Default:

```text
STREAM_MODE='auto'
```

---

# 10. Separazione tra configurazione e target runtime

Non sovrascrivere permanentemente:

```text
STREAM_WIDTH
STREAM_HEIGHT
STREAM_REFRESH
```

con i valori del client.

Utilizzare invece un livello runtime:

```text
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
TARGET_FPS
TARGET_SOURCE
```

Esempio:

```text
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60

CLIENT:
1920x1080@60

TARGET:
1920x1080@60
```

Questo mantiene il fallback originale sempre disponibile.

---

# 11. Stato runtime

Il target risolto deve essere scritto nello stato persistente per poter ricostruire correttamente cosa stava facendo il run.

Aggiungere almeno:

```text
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
TARGET_FPS
TARGET_SOURCE
CLIENT_WIDTH
CLIENT_HEIGHT
CLIENT_FPS
```

Esempio:

```text
PHASE=PREPARING
CLIENT_WIDTH=1280
CLIENT_HEIGHT=800
CLIENT_FPS=89
TARGET_WIDTH=1280
TARGET_HEIGHT=800
TARGET_REFRESH=90
TARGET_FPS=89
TARGET_SOURCE=steam_capture_hint
```

Questo migliora anche la recovery dopo crash.

---

# 12. Resolver dei mode Gamescope

Il resolver deve confrontare il client hint con i mode realmente disponibili sull'host.

Fonti da utilizzare in ordine:

```text
1. GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL
2. modes.cfg
3. Kernel ModeDB del connector
```

L'attuale progetto utilizza già `GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL` quando disponibile e il kernel ModeDB come fallback. Questa struttura deve essere mantenuta.

---

# 13. Rappresentazione dei candidate mode

Ogni candidate deve essere normalizzato in:

```text
WIDTH
HEIGHT
REFRESH
ASPECT
PIXELS
```

Esempio:

```text
1920x1200@60
→ width=1920
→ height=1200
→ refresh=60
→ aspect=1.6
→ pixels=2304000
```

Sono preferibili valori numerici rispetto al confronto testuale puro.

---

# 14. Regola primaria: exact match

La prima scelta deve essere:

```text
client:
1920x1200

host:
1920x1200@60
1920x1200@164
3440x1440@165
```

Risultato:

```text
1920x1200
```

e fra i refresh disponibili deve essere scelto quello più appropriato secondo il criterio di refresh definito.

L'aspect ratio deve essere preservato.

---

# 15. Scelta del refresh

Il client hint comprende anche:

```text
FPS
```

Per esempio:

```text
Maximum capture: 1280x800 89 FPS
```

Non è obbligatorio che il refresh Gamescope sia identico.

Il resolver deve preferire un refresh che:

```text
1. sia sufficiente per il frame rate del client;
2. se possibile sia uguale o superiore al client FPS;
3. abbia una buona cadenza rispetto al client FPS;
4. eviti di penalizzare il caso 60 FPS già funzionante.
```

Il progetto `remoteplay-display` utilizza anch'esso il client FPS nel suo algoritmo, includendo una metrica di cadenza tra refresh host e FPS client.

Per il progetto attuale non è necessario replicarne integralmente l'algoritmo, ma è importante non ignorare completamente `FPS`.

---

# 16. Resolver consigliato

Utilizzare una valutazione deterministica secondo questa priorità:

```text
1. Aspect ratio compatibile
2. Risoluzione esatta
3. Risoluzione sufficientemente vicina
4. Refresh compatibile con client FPS
5. Migliore cadenza refresh/FPS
6. Minore differenza di pixel
7. Refresh più alto
```

In caso di exact match:

```text
client 1920x1200
host   1920x1200
```

questo deve prevalere su qualsiasi mode con più pixel o refresh maggiore.

---

# 17. Gestione della risoluzione non disponibile

Scenario:

```text
client:
1280x800

host:
3440x1440
1920x1200
1920x1080
```

Il resolver deve preferire:

```text
1920x1200
```

perché mantiene:

```text
16:10
```

piuttosto che:

```text
1920x1080
```

che introduce:

```text
16:9
```

Questa regola è particolarmente importante per il progetto perché l'intero meccanismo è nato per evitare mismatch geometrici durante la cattura.

Il problema Steam documentato in #13618 mostra infatti che una differenza di aspect ratio tra display catturato e stream richiesto può contribuire a un mismatch dei DMA-BUF/NV12 e al successivo assert FFmpeg.

---

# 18. Nessun mode compatibile

Se il client richiede:

```text
2560x1440
```

ma sull'host non esiste nessun mode 16:9 compatibile:

```text
3440x1440
1920x1200
```

non scegliere automaticamente:

```text
3440x1440
```

solo perché ha più pixel.

Questo potrebbe reintrodurre un mismatch geometrico.

La modalità deve essere:

```text
1. compatibile
2. oppure fallback configurato
3. oppure fail-closed
```

Modalità consigliata:

```text
hint valido + nessun mode compatibile
→ fallback esplicito solo se compatibile con l'aspect del client

altrimenti
→ fail-closed
```

Questo comportamento deve essere configurabile, ma il default deve privilegiare la sicurezza dello stream rispetto a una modalità arbitraria.

---

# 19. Aggiornamento di `modes.cfg`

La funzione attualmente utilizzata:

```text
write_saved_mode_for_description()
```

deve ricevere il target risolto:

```text
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
```

e non più:

```text
STREAM_WIDTH
STREAM_HEIGHT
STREAM_REFRESH
```

Esempio:

```text
client:
1920x1080

resolver:
TARGET=1920x1080@60

modes.cfg:
DisplayName:1920x1080@60
```

---

# 20. Verifica output Gamescope

L'attuale:

```text
wait_for_target_mode()
```

deve diventare runtime-aware.

Deve verificare:

```text
TARGET_WIDTH
TARGET_HEIGHT
```

e il refresh selezionato o una sua variante ammessa.

Esempio:

```text
TARGET=1280x800@90
current=1280x800@90
→ PASS
```

oppure:

```text
TARGET=1920x1200@60
current=1920x1200@164
```

→ PASS se la logica già prevista per i refresh ripescati considera 164 compatibile.

Il controllo geometrico deve comunque essere sempre:

```text
current width  == TARGET_WIDTH
current height == TARGET_HEIGHT
```

---

# 21. Sincronizzazione Xwayland #1

La parte già implementata deve rimanere.

L'attuale:

```text
set_stream_xwayland_mode()
```

deve utilizzare:

```text
TARGET_WIDTH
TARGET_HEIGHT
```

anziché i valori fissi.

Quindi:

```text
client:
1920x1080

output:
1920x1080

Xwayland #1:
1920x1080
```

oppure:

```text
client:
1280x800

output:
1280x800

Xwayland #1:
1280x800
```

Il meccanismo `GAMESCOPE_XWAYLAND_MODE_CONTROL` è quello corretto per modificare esplicitamente il server Xwayland indicizzato. La sorgente Gamescope mostra che `server_idx`, width e height vengono utilizzati per chiamare `wlserver_set_xwayland_server_mode()`.

Il vincolo resta:

```text
OUTPUT_TARGET_REACHED
        ↓
XWAYLAND1_SYNC_REQUESTED
        ↓
XWAYLAND1_SYNC_CONFIRMED
        ↓
GAME_LAUNCH
```

---

# 22. Invariante fondamentale

Il target dinamico deve essere identico in tutti e tre i livelli:

```text
CLIENT
   ↓
TARGET
   ↓
OUTPUT
   ↓
XWAYLAND #1
   ↓
STEAM CAPTURE
```

In particolare:

```text
OUTPUT_WIDTH  == XWAYLAND1_WIDTH
OUTPUT_HEIGHT == XWAYLAND1_HEIGHT
```

e:

```text
OUTPUT_ASPECT ≈ CLIENT_ASPECT
```

---

# 23. Game launch

`run_game()` non deve cambiare semantica.

Deve continuare a richiedere:

```text
XWAYLAND1_SYNC_CONFIRMED
```

prima di:

```text
GAME_LAUNCH
```

La modifica dinamica deve avvenire interamente prima di questa fase.

---

# 24. Restore

Il restore non deve utilizzare il target client.

Deve continuare a utilizzare la modalità locale salvata:

```text
3440x1440@165
```

Il target dinamico:

```text
1280x800
1920x1080
1920x1200
...
```

è esclusivamente temporaneo.

Alla fine:

```text
game end
    ↓
restore output locale
    ↓
restore Xwayland #1 locale
    ↓
3440x1440@165
```

---

# 25. Recovery

In caso di crash:

```text
TARGET_WIDTH
TARGET_HEIGHT
```

devono essere disponibili nello stato persistente.

Tuttavia il recovery non deve dipendere dal target client per il restore.

Deve fare:

```text
stale state
    ↓
wake monitor
    ↓
restore modes.cfg
    ↓
restore local output
    ↓
restore Xwayland #1 local
    ↓
clear state
```

Il target dinamico viene quindi considerato sempre uno stato temporaneo della sessione.

---

# 26. Prima connessione

Il nuovo sistema deve funzionare anche quando:

```text
nessun precedente stream
nessun marker storico
```

La sequenza deve essere:

```text
pactl subscribe
      ↓
steam-streaming-playback
      ↓
Maximum capture recente
      ↓
resolve client mode
      ↓
switch Gamescope
      ↓
sync Xwayland #1
      ↓
game
```

La soluzione non deve utilizzare:

```text
STREAM_DETECT_WINDOW_SECONDS
```

per determinare la validità dell'hint.

---

# 27. Più client differenti

Il sistema deve essere progettato per sessioni consecutive con client diversi.

Esempio:

```text
Sessione 1
Legion Go S
1920x1200@60
        ↓
TARGET 1920x1200

Sessione 2
Steam Deck
1280x800@89
        ↓
TARGET 1280x800

Sessione 3
client 1080p
1920x1080@60
        ↓
TARGET 1920x1080
```

Ogni nuova sessione deve ricalcolare completamente il target.

Non riutilizzare:

```text
TARGET_WIDTH
TARGET_HEIGHT
```

della sessione precedente.

---

# 28. Cache dell'hint

Non conservare globalmente il client hint per più sessioni.

È consentita solamente una cache temporanea:

```text
hint
    ↓
current stream detection
    ↓
current preparation
```

A fine sessione:

```text
clear client hint
```

Questo evita:

```text
client A:
1920x1200

client B:
1280x800

client B senza hint
→ erroneamente usa 1920x1200 di A
```

In assenza di hint corrente deve essere usato il fallback configurato.

---

# 29. Compatibilità con il comportamento attuale

Tutti i seguenti casi devono continuare a funzionare:

```text
Desktop Mode
    → bypass

Gaming Mode senza Steam Link
    → bypass

Gaming Mode + Steam Link
    → auto resolution

Steam Link + hint assente
    → fallback 1920x1200@60

Steam Link + hint invalido
    → fallback

Steam Link + Gamescope unavailable
    → fail-closed come già previsto durante streaming
```

---

# 30. Modalità fixed

Il comportamento `fixed` deve essere equivalente al comportamento attuale.

Con:

```text
STREAM_MODE=fixed
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
```

il resolver non deve leggere il client hint per selezionare la geometria.

Il percorso diventa:

```text
Steam Link
    ↓
fixed target
    ↓
1920x1200@60
```

Questo costituisce anche un importante meccanismo di rollback.

---

# 31. Logging

Aggiungere eventi diagnostici specifici.

### Sessione

```text
STREAM_SIGNAL_CONFIRMED
```

### Client hint

```text
CLIENT_HINT 1920x1200@60
```

oppure:

```text
CLIENT_HINT unavailable
```

### Risoluzione

```text
TARGET_MODE_RESOLVED 1920x1200@60 source=steam_capture_hint
```

### Fallback

```text
TARGET_MODE_RESOLVED 1920x1200@60 source=fallback
```

### Mode incompatibile

```text
TARGET_MODE_NO_COMPATIBLE_HOST_MODE
```

### Output

```text
OUTPUT_TARGET_REACHED 1920x1200@60
```

### Xwayland

```text
XWAYLAND1_SYNC_REQUESTED 1/1920/1200/0
XWAYLAND1_SYNC_CONFIRMED 1920x1200
```

### Launch

```text
GAME_LAUNCH
```

---

# 32. Test unitari

Estendere `tests/run-tests.sh`.

## Test parsing

```text
Maximum capture: 1920x1200 60 FPS
→ 1920 / 1200 / 60
```

```text
Maximum capture: 1280x800 89.00 FPS
→ 1280 / 800 / 89
```

---

## Test hint invalido

```text
Maximum capture: invalid
→ nessun hint
```

---

## Test hint stale

```text
hint > STREAM_CAPTURE_HINT_MAX_AGE_SECONDS
→ ignorato
```

---

## Test exact mode

```text
client = 1920x1200
modes = 1920x1200@60, 3440x1440@165
→ 1920x1200
```

---

## Test aspect

```text
client = 1280x800
modes = 1920x1200, 1920x1080
→ 1920x1200
```

---

## Test client 16:9

```text
client = 1920x1080
modes = 1920x1200, 1920x1080
→ 1920x1080
```

---

## Test fallback

```text
hint assente
→ 1920x1200@60
```

---

## Test fixed

```text
STREAM_MODE=fixed
hint = 1920x1080
→ 1920x1200
```

---

## Test client FPS

```text
client = 1280x800@89
host = 1280x800@60
host = 1280x800@90
→ preferire @90
```

---

## Test sequence

```text
Sessione A:
1920x1200

cleanup

Sessione B:
1280x800

cleanup

Sessione C:
1920x1080
```

Verificare che ogni sessione utilizzi il proprio target.

---

# 33. Test di prima connessione

Integrare il comportamento già corretto per la prima connessione con il nuovo resolver.

Scenario:

```text
nessun marker storico
nessun sink
Maximum capture: 1920x1200 60 FPS
```

Poi:

```text
creazione steam-streaming-playback
```

Risultato atteso:

```text
STREAM_SIGNAL_CONFIRMED
CLIENT_HINT 1920x1200@60
TARGET_MODE_RESOLVED 1920x1200
XWAYLAND1_SYNC_CONFIRMED
GAME_LAUNCH
```

Questo test deve essere considerato obbligatorio.

---

# 34. Test anti-regressione crash

Simulare:

```text
host local = 3440x1440
client = 1920x1080
```

Verificare:

```text
output = 1920x1080
Xwayland #1 = 1920x1080
```

e non:

```text
output = 1920x1080
Xwayland #1 = 3440x1440
```

Questo è importante perché il problema originario di Steam Remote Play era proprio legato alla discordanza della geometria tra cattura e descriptor della superficie.

---

# 35. Test client reale

Con il Legion Go S devono essere verificati almeno:

```text
Maximum capture = 1920x1200
```

e:

```text
TARGET_WIDTH=1920
TARGET_HEIGHT=1200
```

Il comportamento atteso deve rimanere identico a quello già funzionante:

```text
monitor OFF

Gamescope:
1920x1200

Xwayland #1:
1920x1200

Steam capture:
1920x1200

stream:
16:10
```

---

# 36. Verifica Steam

Dopo una connessione reale verificare:

```text
~/.local/share/Steam/logs/streaming_log.txt
```

e controllare almeno:

```text
Maximum capture: WxH FPS
```

e successivamente:

```text
setting capture size WxH
```

La geometria deve risultare coerente con il target scelto dal resolver.

Se il client hint è:

```text
1920x1200
```

ma Steam effettua una cattura:

```text
3440x1440
```

la sessione deve essere considerata non conforme e deve essere diagnosticata prima di concludere il test come positivo.

---

# 37. Failure handling

### Hint assente

```text
→ fallback
```

### Hint invalido

```text
→ fallback
```

### Host mode non disponibile

```text
→ compatibile mode resolver
```

### Nessun mode compatibile

```text
→ fallback compatibile
```

oppure:

```text
→ fail-closed
```

in funzione della configurazione.

### Gamescope non raggiungibile

```text
→ fail-closed durante streaming
```

### Xwayland #1 non sincronizzabile

```text
→ fail-closed
```

### Steam Link non attivo

```text
→ bypass completo
```

---

# 38. Non modificare dinamicamente il target durante uno stream attivo

Una volta avviato il gioco:

```text
TARGET_MODE
```

deve essere considerato immutabile.

Non reagire a nuove righe:

```text
Maximum capture
```

durante lo stream.

Il target viene calcolato una sola volta:

```text
STREAM START
      ↓
resolve
      ↓
prepare
      ↓
GAME
```

e rimane invariato fino al cleanup.

Questo evita un cambio di geometria a metà cattura, che potrebbe introdurre nuovamente incompatibilità nella pipeline Steam.

---

# 39. Non basarsi sulla risoluzione del gioco

Il resolver riguarda:

```text
Steam client capture
```

e:

```text
Gamescope output
```

Non deve leggere:

```text
game settings
Proton
DXVK
Wine
resolution saved by game
```

La risoluzione del gioco è un livello distinto.

Il progetto di riferimento segnala anch'esso che alcuni giochi possono mantenere una propria risoluzione di rendering anche quando cambia il display.

---

# 40. Compatibilità con giochi esistenti

Non devono essere richieste modifiche ai giochi.

La Launch Option rimane:

```text
steam-link-display-adapter %command%
```

Il gioco deve continuare a funzionare sia:

```text
local
```

sia:

```text
Steam Link
```

La modalità locale continua a utilizzare:

```text
3440x1440@165
```

mentre lo stream utilizza il target risolto.

---

# 41. Configurazione proposta

La configurazione dovrebbe evolvere indicativamente verso:

```bash
STREAM_MODE='auto'

# Fallback / fixed mode
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
STREAM_FPS=60

# Client capture hint
STEAM_STREAM_LOG="$HOME/.local/share/Steam/logs/streaming_log.txt"
STREAM_CAPTURE_HINT_MAX_AGE_SECONDS=10

# Xwayland
STREAM_XWAYLAND_SERVER_INDEX=1
STREAM_XWAYLAND_ALLOW_SUPERRES=0
```

I nomi definitivi possono essere adattati alle convenzioni già presenti nel progetto.

Non rendere obbligatoria una modifica manuale della configurazione per passare ad `auto`.

---

# 42. Backward compatibility

Una configurazione esistente che contiene:

```bash
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
```

deve continuare a essere valida.

Se la chiave:

```text
STREAM_MODE
```

non esiste:

```text
default = auto
```

oppure, per una strategia inizialmente più conservativa:

```text
default = fixed
```

La scelta deve essere documentata chiaramente.

Dato che l'obiettivo della modifica è rendere il comportamento dinamico, la configurazione distribuita dal progetto dovrebbe comunque utilizzare:

```text
STREAM_MODE=auto
```

con fallback identico al comportamento precedente.

---

# 43. Definition of Done

La modifica è completata quando:

```text
[✓] Steam Link rilevato event-driven

[✓] Client hint letto dal log Steam

[✓] Hint validato temporalmente

[✓] Risoluzione client trasformata in target runtime

[✓] Host mode verificato contro i mode disponibili

[✓] Exact match preferito

[✓] Aspect ratio preservato quando exact match non esiste

[✓] Refresh valutato anche in base al client FPS

[✓] Fallback 1920x1200@60 disponibile

[✓] Modalità fixed disponibile

[✓] Output Gamescope usa TARGET_WIDTH/TARGET_HEIGHT

[✓] Xwayland #1 usa TARGET_WIDTH/TARGET_HEIGHT

[✓] GAME_LAUNCH avviene dopo XWAYLAND1_SYNC_CONFIRMED

[✓] Target immutabile durante lo stream

[✓] Restore locale 3440x1440@165 invariato

[✓] Prima connessione continua a funzionare

[✓] Connessioni successive con client diversi vengono ricalcolate

[✓] Gaming Mode locale non viene modificato

[✓] Desktop Mode non viene modificato

[✓] Stale-state recovery non viene compromesso

[✓] Test unitari aggiornati

[✓] Test live Legion Go S superato
```

---

# 44. Sequenza finale desiderata

Il sistema completo deve comportarsi così:

```text
                     Steam Link client
                            │
                            ▼
                  stream session starts
                            │
                            ▼
                 Maximum capture: WxH FPS
                            │
                            ▼
                steam-streaming-playback
                            │
                            ▼
                 STREAM DETECTION OK
                            │
                            ▼
                    READ CLIENT HINT
                            │
                            ▼
                    MODE RESOLVER
                            │
             ┌──────────────┴──────────────┐
             │                             │
       exact host mode              compatible mode
             │                             │
             └──────────────┬──────────────┘
                            ▼
                     TARGET WxH@R
                            │
                            ▼
                  Gamescope output
                            │
                            ▼
                   VERIFY OUTPUT
                            │
                            ▼
                  Xwayland #1 sync
                            │
                            ▼
                 VERIFY Xwayland #1
                            │
                            ▼
                       GAME LAUNCH
                            │
                            ▼
                     STEAM CAPTURE
                            │
                            ▼
                         STREAM
                            │
                            ▼
                       GAME END
                            │
                            ▼
                  RESTORE LOCAL MODE
                            │
                            ▼
                       3440x1440@165
```

---

# 45. Principio architetturale da rispettare

La risoluzione dinamica non deve diventare una nuova pipeline separata.

Deve essere soltanto una nuova sorgente del target:

```text
                ┌── Steam client hint ──┐
                │                       │
fixed config ───┤      MODE RESOLVER     ├──→ TARGET MODE
                │                       │
fallback ───────┘                       │
                                        ▼
                                  Gamescope output
                                        │
                                        ▼
                                  Xwayland #1
```

La parte già risolta del progetto — rilevamento event-driven, fail-closed, sincronizzazione Xwayland #1, cleanup, recovery — deve rimanere invariata nel comportamento.

La nuova funzionalità deve quindi limitarsi a rendere **dinamico il valore di `TARGET_WIDTH/TARGET_HEIGHT/TARGET_REFRESH`**, lasciando invariato il lifecycle della sessione.
