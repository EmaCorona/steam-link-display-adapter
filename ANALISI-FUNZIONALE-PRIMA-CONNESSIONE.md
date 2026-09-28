# Analisi funzionale — Correzione prima connessione Steam Link senza regressioni

## 1. Obiettivo

Correggere il comportamento residuo di `steam-link-virtual-display` affinché la prima connessione Steam Link venga gestita esattamente come le connessioni successive.

Il comportamento attuale è:

```text
Prima connessione Steam Link
→ stream al client ancora a 3440x1440 21:9

Connessioni successive
→ 1920x1200 16:10
→ Xwayland #1 sincronizzato
→ funzionamento corretto
```

Obiettivo:

```text
Prima connessione
→ 1920x1200 16:10

Seconda connessione
→ 1920x1200 16:10

N-esima connessione
→ 1920x1200 16:10
```

Senza introdurre regressioni nel gioco locale:

```text
Desktop Mode + gioco locale
→ gioco avviato normalmente

Gaming Mode + gioco locale
→ gioco avviato normalmente

Gaming Mode + Steam Link
→ pipeline virtual display attiva
```

---

# 2. Root cause verificata nel repository

L'implementazione attuale di `steam_link_streaming_active()` utilizza due livelli di rilevamento:

1. stato corrente del sink PipeWire `steam-streaming-playback`;
2. presenza di un marker storico Steam recente.

Il flusso attuale è:

```bash
if _sl_streaming_signals_present; then
    return 0
fi

if ! _sl_stream_cycle_recent; then
    return 1
fi

wait for STREAM_DETECT_WAIT_SECONDS
```

Questo crea un errore logico.

L'attesa della race viene effettuata soltanto quando esiste già un marker precedente.

Nella prima connessione non esiste necessariamente un marker storico valido:

```text
Steam Link prima connessione
        ↓
nessun sink ancora presente
        ↓
nessun marker precedente
        ↓
_sl_stream_cycle_recent = false
        ↓
return 1
```

Il wrapper passa quindi in:

```bash
exec "$@"
```

e non esegue alcuna modifica del display.

Il risultato è che Steam può iniziare la cattura con:

```text
3440x1440
21:9
```

prima che qualsiasi modifica del wrapper venga eseguita.

---

# 3. Evidenza nel comportamento dei test

Il test attuale:

```text
test_stream_wait_catches_race
```

crea manualmente un marker Steam precedente prima dell'avvio del wrapper.

Di conseguenza verifica solamente:

```text
marker precedente
→ attesa
→ sink successivo
→ streaming
```

Non verifica:

```text
nessun marker precedente
→ nuova sessione Steam Link
→ sink successivo
→ streaming
```

Questo è il caso che deve essere aggiunto.

Il fatto che tutte le connessioni successive funzionino è coerente con la presenza del marker della sessione precedente entro:

```text
STREAM_DETECT_WINDOW_SECONDS=180
```

---

# 4. Requisito fondamentale

Il rilevamento della sessione Steam Link non deve dipendere dalla presenza di un evento storico.

Il marker storico può essere mantenuto come informazione diagnostica o fallback, ma non deve essere una precondizione per l'attesa.

La logica deve distinguere:

```text
STREAM ATTIVO
STREAM IN AVVIO
NESSUNO STREAM
```

e non:

```text
STREAM ATTIVO
STREAM NON ATTIVO + marker storico
NESSUNO
```

---

# 5. Soluzione minima richiesta

Modificare il rilevamento in modo che, quando il sink non è ancora presente, il wrapper sia in grado di osservare anche un evento futuro di creazione della sessione.

Il comportamento concettuale deve diventare:

```text
1. Controlla sink attuale

   se presente:
       STREAM ACTIVE

   altrimenti:
       continua

2. Osserva l'avvio di una nuova sessione

   se compare steam-streaming-playback:
       STREAM ACTIVE

   se timeout:
       STREAM INACTIVE
```

La presenza di un marker storico non deve più essere necessaria.

---

# 6. Meccanismo preferenziale: event-driven PipeWire/PulseAudio

Utilizzare come meccanismo principale:

```bash
pactl subscribe
```

e osservare la creazione/modifica del sink:

```text
steam-streaming-playback
```

Questo è preferibile rispetto al semplice polling temporizzato perché consente di reagire quasi immediatamente alla creazione del sink.

Un'implementazione esterna analoga utilizza esattamente `pactl subscribe`, mantenendo anche una verifica periodica dello stato per recuperare da eventi persi o processi terminati.

La logica deve essere:

```text
pactl list short sinks
        ↓
sink presente?
   ├── YES → stream attivo
   └── NO
        ↓
pactl subscribe
        ↓
evento sink/server
        ↓
ricontrolla:
pactl list short sinks
        ↓
steam-streaming-playback presente?
        ├── YES → stream attivo
        └── NO → continua attesa
```

Non considerare sufficiente la semplice ricezione dell'evento PulseAudio: dopo l'evento deve essere verificato lo stato reale del sink.

---

# 7. Timeout

Mantenere un timeout bounded.

Il timeout attuale:

```text
STREAM_DETECT_WAIT_SECONDS=5
```

può essere mantenuto come valore iniziale.

Tuttavia deve rappresentare:

```text
finestra di rilevamento di una nuova sessione
```

e non:

```text
attesa condizionata dalla presenza di un marker storico
```

Quindi il valore deve funzionare anche nella prima connessione.

---

# 8. Requisito anti-regressione per il gaming locale

Non introdurre una modifica permanente del display quando Steam Link non è attivo.

Il comportamento desiderato è:

```text
Gaming Mode
Steam Link OFF
        ↓
wrapper
        ↓
nessun display change
        ↓
gioco
```

e:

```text
Desktop Mode
Steam Link OFF
        ↓
wrapper
        ↓
nessun Gamescope requirement
        ↓
gioco
```

La presenza di:

```text
gamescope
gamescopectl
xprop
xdpyinfo
```

non deve essere interpretata come prova di una sessione Steam Link.

---

# 9. Evitare un ritardo permanente nel gioco locale

Non trasformare il wrapper in:

```text
ogni avvio gioco
→ aspetta 5 secondi
→ poi avvia
```

senza valutare l'impatto.

Il comportamento ideale è:

```text
Steam Link già attivo
→ avvio immediato pipeline

Steam Link non attivo ma in fase di avvio
→ attesa bounded

Steam Link chiaramente non attivo
→ bypass
```

Per raggiungere questo obiettivo senza introdurre artificialmente un ritardo ad ogni gioco locale, valutare due livelli:

### Livello A — wrapper

Il wrapper deve mantenere il controllo finale e la verifica.

### Livello B — watcher persistente

Valutare l'introduzione di un piccolo servizio `systemd --user` che osserva continuamente:

```text
steam-streaming-playback
```

Quando compare:

```text
stream start
```

il servizio prepara preventivamente il display.

Quando scompare:

```text
stream end
```

il servizio esegue il restore.

Questo approccio elimina alla radice la dipendenza dal momento in cui Steam invoca il launch wrapper.

Il wrapper rimane comunque indispensabile come secondo livello di sicurezza:

```text
watcher:
    prepara

wrapper:
    verifica
    completa eventuali operazioni mancanti
    avvia il gioco
```

---

# 10. Architettura consigliata

La soluzione più robusta è:

```text
                     Steam Link client
                            │
                            ▼
                 Steam Remote Play session
                            │
                            ▼
                steam-streaming-playback
                            │
                     pactl subscribe
                            │
                            ▼
                 ┌────────────────────┐
                 │ Stream Watcher     │
                 │ systemd --user    │
                 └─────────┬──────────┘
                           │
                           ▼
                 prepare virtual display
                           │
              ┌────────────┴─────────────┐
              │                          │
              ▼                          ▼
        DP-3 1920x1200@60      Xwayland #1 1920x1200
              │                          │
              └────────────┬─────────────┘
                           ▼
                       Steam game
                           │
                           ▼
                      Steam capture
```

Il wrapper deve quindi diventare il secondo livello:

```text
Steam game launch
       ↓
wrapper
       ↓
stream state?
       ↓
already prepared?
   ├── YES → verify
   └── NO  → prepare/fail safely
       ↓
Xwayland #1 verified
       ↓
GAME
```

Questo evita la situazione nella quale il wrapper arriva dopo una parte critica del lifecycle Steam.

---

# 11. Ownership e idempotenza

Watcher e wrapper non devono combattere tra loro.

Utilizzare lo stesso meccanismo di lock/state oppure estendere quello esistente.

Il comportamento deve essere idempotente:

```text
watcher prepara
wrapper prepara
```

non deve produrre:

```text
switch 1
switch 2
sleep 1
sleep 2
```

ma:

```text
already prepared
→ verify only
```

Il secondo componente deve poter riconoscere:

```text
STREAM_PREPARED
```

e utilizzare la preparazione esistente.

---

# 12. Stato persistente

Estendere lo stato, se necessario, distinguendo almeno:

```text
IDLE
PREPARING
PREPARED
STREAMING
RESTORING
```

Esempio:

```text
IDLE
  ↓
STREAM_DETECTED
  ↓
PREPARING
  ↓
OUTPUT_READY
  ↓
XWAYLAND_READY
  ↓
PREPARED
  ↓
GAME_LAUNCH
  ↓
STREAMING
  ↓
RESTORING
  ↓
IDLE
```

---

# 13. Ordinamento critico

Il requisito Xwayland #1 già implementato deve rimanere invariato.

Prima del gioco:

```text
OUTPUT_TARGET_REACHED
        ↓
XWAYLAND1_SYNC_REQUESTED
        ↓
XWAYLAND1_SYNC_CONFIRMED
        ↓
GAME_LAUNCH
```

Il vincolo:

```text
XWAYLAND1_SYNC_CONFIRMED < GAME_LAUNCH
```

deve continuare a essere obbligatorio.

Gamescope espone `GAMESCOPE_XWAYLAND_MODE_CONTROL` come controllo specifico per il server Xwayland indicizzato, quindi questa parte deve essere mantenuta e non sostituita con un ulteriore nudge DRM.

---

# 14. Prima connessione — comportamento richiesto

Scenario:

```text
Steam appena avviato
nessuna precedente sessione Remote Play
monitor = 3440x1440@165
```

Il client Legion Go S avvia Steam Link.

Comportamento obbligatorio:

```text
Steam Link connection detected
        ↓
prepare 1920x1200
        ↓
verify output
        ↓
sync Xwayland #1
        ↓
verify Xwayland #1
        ↓
launch game
```

Il risultato non deve dipendere dalla presenza di:

```text
Streaming started to
```

proveniente da una sessione precedente.

---

# 15. Seconda e successive connessioni

Devono utilizzare lo stesso percorso logico.

Non devono più esistere due comportamenti differenti:

```text
prima connessione → percorso A
connessioni successive → percorso B
```

Deve esistere un solo percorso:

```text
Steam Link session detection
→ prepare
→ verify
→ game
```

La presenza di uno stato precedente deve servire solamente a velocizzare/reconciliate, non a cambiare la correttezza funzionale.

---

# 16. Test obbligatori

Aggiungere un test specifico:

```text
test_first_stream_no_previous_marker
```

Scenario:

```text
nessun sink
nessun marker Steam precedente
wrapper avviato
```

Dopo un intervallo:

```text
creazione sink steam-streaming-playback
```

Risultato atteso:

```text
wrapper rileva la nuova sessione
→ pipeline display
→ gioco avviato
```

Non deve verificarsi:

```text
bypassing display pipeline
```

---

# 17. Test di regressione locale

Mantenere e rafforzare:

```text
Desktop Mode + no stream
→ immediate/direct launch

Gaming Mode + no stream
→ direct launch

stream inactive + gamescopectl assente
→ direct launch
```

Il watcher, se introdotto, deve rimanere inattivo quando:

```text
steam-streaming-playback
```

non esiste.

---

# 18. Test di sequenza

Aggiungere test per:

```text
first connection
second connection
third connection
```

tutti partendo dal sistema:

```text
3440x1440@165
```

e verificare che ogni ciclo produca:

```text
1920x1200
Xwayland #1 = 1920x1200
```

senza dipendenza da leftover.

---

# 19. Test crash

Scenario:

```text
first connection
→ display preparation
→ Xwayland sync
→ Steam crash
```

Successivo avvio:

```text
stale state recovery
→ restore
→ sistema locale 3440x1440@165
```

Poi:

```text
nuova connessione
→ deve funzionare come prima connessione
```

Non deve essere necessario che il crash precedente lasci:

```text
modes.cfg = 1920x1200
```

per rendere il successivo stream funzionante.

---

# 20. Logging diagnostico

Aggiungere/rafforzare eventi:

```text
STREAM_SIGNAL_CURRENT
STREAM_WAIT_START
STREAM_SIGNAL_EVENT
STREAM_SIGNAL_CONFIRMED
OUTPUT_PREPARE_START
OUTPUT_TARGET_REACHED
XWAYLAND1_SYNC_REQUESTED
XWAYLAND1_SYNC_CONFIRMED
GAME_LAUNCH
```

Per la prima connessione il log ideale è:

```text
T0 STREAM_WAIT_START
Txxx STREAM_SIGNAL_EVENT steam-streaming-playback
Txxx STREAM_SIGNAL_CONFIRMED
Txxx OUTPUT_TARGET_REACHED 1920x1200@60
Txxx XWAYLAND1_SYNC_CONFIRMED 1920x1200
Txxx GAME_LAUNCH
```

Il log non deve mostrare:

```text
bypassing display pipeline
```

quando la sessione Steam Link sta effettivamente partendo.

---

# 21. Verifica Steam capture

La verifica finale deve includere il log Steam:

```text
~/.local/share/Steam/logs/streaming_log.txt
```

e verificare che la sessione utilizzi:

```text
capture size 1920x1200
```

e non:

```text
capture size 3440x1440
```

Il report Valve #13618 mostra che la discordanza tra geometria della cattura e descriptor DMA-BUF può produrre esattamente il failure mode già osservato nel sistema.

---

# 22. Vincoli

Non:

* modificare permanentemente la risoluzione locale;
* lasciare il monitor a 1920x1200 dopo la sessione;
* eliminare la sincronizzazione Xwayland #1;
* introdurre dipendenze da uno specifico gioco;
* risolvere il problema tramite scaling lato client;
* richiedere un precedente stream per far funzionare il successivo;
* introdurre un delay fisso significativo per ogni gioco locale.

Non utilizzare il timestamp storico come condizione necessaria per determinare che una nuova sessione possa iniziare.

---

# 23. Definition of Done

La modifica è completa quando sono vere tutte le seguenti condizioni:

```text
[✓] Prima connessione Steam Link
    → 1920x1200

[✓] Seconda connessione
    → 1920x1200

[✓] N-esima connessione
    → 1920x1200

[✓] Xwayland #1
    → 1920x1200 prima del GAME_LAUNCH

[✓] Steam capture
    → 1920x1200

[✓] Gaming Mode locale
    → nessun cambio display

[✓] Desktop Mode
    → nessun errore Gamescope

[✓] Crash Steam
    → recovery al successivo avvio

[✓] Fine sessione
    → 3440x1440@165

[✓] Monitor
    → ON dopo restore

[✓] Nessuna dipendenza da marker storico
```

---

# 24. Priorità implementativa

### Prima correzione

Eliminare il requisito:

```text
_recent stream marker must exist
```

per entrare nella fase di attesa.

Implementare rilevamento di una sessione futura tramite evento reale del sink.

### Seconda correzione

Aggiungere il test:

```text
first stream with no historical marker
```

Questo test deve fallire con l'implementazione attuale e passare con quella corretta.

### Terza correzione

Valutare un watcher `systemd --user` event-driven se il requisito è evitare qualsiasi delay nel gaming locale e garantire che la preparazione del display inizi prima che il launch wrapper diventi attivo.

### Quarta correzione

Mantenere il wrapper come guardia finale:

```text
stream detected
→ output verified
→ Xwayland #1 verified
→ game
```

Il wrapper non deve fidarsi ciecamente dello stato prodotto dal watcher.

---

# 25. Risultato architetturale finale

Il sistema deve evolvere da:

```text
                 GAME LAUNCH
                     │
                     ▼
             wrapper detection
                     │
                     ▼
          "stream already visible?"
                /          \
              NO            YES
              │              │
           bypass         prepare
```

a:

```text
              Steam Link session
                      │
                      ▼
               live detection
                      │
               ┌──────┴──────┐
               │             │
            watcher        wrapper
               │             │
               └──────┬──────┘
                      ▼
              shared state/lock
                      │
                      ▼
             output 1920x1200
                      │
                      ▼
             Xwayland #1 1920x1200
                      │
                      ▼
                   GAME
```

Il principio fondamentale è:

> **La prima connessione non deve essere trattata come un caso speciale. La pipeline deve reagire alla comparsa della sessione Steam Link reale, non all'esistenza di una sessione Steam Link precedente.**
