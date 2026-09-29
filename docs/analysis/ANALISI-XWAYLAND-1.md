# Analisi funzionale — Sincronizzazione Xwayland #1 per Steam Link Display Adapter

## 1. Obiettivo

Correggere il meccanismo `steam-link-display-adapter` su Bazzite Game Mode affinché una sessione Steam Link verso Legion Go S utilizzi una geometria coerente durante tutta la fase di avvio del gioco.

Configurazione target:

* Host: Bazzite Game Mode
* GPU: AMD
* Output fisico: `DP-3`
* Modalità locale: `3440x1440@165`
* Modalità streaming target: `1920x1200@60`
* Aspect ratio streaming: `16:10`
* Client: Legion Go S
* Streaming: Steam Link / Steam Remote Play
* Gamescope: con due server Xwayland:

  * Xwayland #0: shell/UI
  * Xwayland #1: server utilizzato dal gioco

L'obiettivo non è semplicemente cambiare la modalità DRM dell'output. È garantire che **anche Xwayland #1 venga portato a `1920x1200` prima che il gioco inizi effettivamente a renderizzare/catturare**, eliminando il mismatch tra geometria dell'output e geometria del server Xwayland del gioco.

---

# 2. Stato attuale verificato

L'implementazione attuale esegue sostanzialmente questa sequenza:

```text
Steam Link
   ↓
Steam avvia il gioco
   ↓
Gamescope handshake
   ↓
Xwayland #1 acquisisce la modalità output corrente
   ↓
wrapper
   ↓
cambio output DP-3 → 1920x1200@60
   ↓
Xwayland #0 si aggiorna
   ↓
Xwayland #1 NON viene aggiornato
   ↓
Steam Remote Play vede geometrie incoerenti
   ↓
PipeWire / NV12 / DMABUF
   ↓
Failed to mmap / import failure
   ↓
FFmpeg imgutils assertion
   ↓
Steam crash
```

La modifica dell'output tramite DRM/Gamescope non è sufficiente a modificare automaticamente Xwayland #1.

La sorgente Gamescope verificata mostra infatti che `GAMESCOPE_XWAYLAND_MODE_CONTROL` è un meccanismo dedicato per impostare la modalità di uno specifico Xwayland server:

```text
[server_idx, width, height, allowSuperRes]
```

e che, quando la property viene elaborata, Gamescope chiama:

```text
wlserver_set_xwayland_server_mode(
    server_idx,
    width,
    height,
    g_nOutputRefresh
)
```

Questa è la primitive corretta da utilizzare per sincronizzare esplicitamente Xwayland #1.

---

# 3. Root cause funzionale

Il problema principale è una **race temporale tra il launch handshake di Steam e la modifica successiva dell'output effettuata dal wrapper**.

Sequenza osservata:

```text
T0
Steam Link avvia il processo di launch
        ↓
T1
Gamescope aggiorna Xwayland #1
        ↓
Xwayland #1 = modalità output corrente
        ↓
se output locale:
3440x1440@165
        ↓
T2
wrapper entra in esecuzione
        ↓
T3
wrapper modifica DP-3
3440x1440@165
        →
1920x1200@60
        ↓
T4
output = 1920x1200@60
Xwayland #0 aggiornato
Xwayland #1 ancora:
3440x1440
        ↓
T5
Steam cattura/renderizza usando una combinazione
di geometrie incoerenti
        ↓
crash
```

Il dato fondamentale è quindi:

> **Il cambio di modalità DRM dell'output non risolve il problema se Xwayland #1 rimane sulla geometria precedente.**

La correzione deve quindi essere applicata a entrambi i livelli:

```text
DRM / output
+
Xwayland #1
```

e la seconda operazione deve avvenire **prima dell'avvio effettivo del gioco**.

---

# 4. Evidenza sperimentale

I cinque run riportati mostrano una relazione fortemente consistente tra la modalità presente durante l'handshake e l'esito:

```text
3440x1440 durante handshake
    →
Xwayland #1 = 3440x1440
    →
output successivamente = 1920x1200
    →
mismatch
    →
Steam crash

1920x1200 durante handshake
    →
Xwayland #1 = 1920x1200
    →
output = 1920x1200
    →
geometria coerente
    →
stream OK
```

Pattern osservato:

```text
A  3440x1440 → crash
B  1920x1200 → OK
C  3440x1440 → crash
D  1920x1200 → OK
E  3440x1440 → crash
```

Questo è compatibile con il failure mode documentato da Valve per Steam Remote Play: geometrie discordanti nel percorso PipeWire/NV12/DMABUF possono portare al fallimento dell'import del frame e successivamente all'assert FFmpeg `libavutil/imgutils.c:350`.

Il report Valve specifica inoltre che la corrispondenza della risoluzione host/client ha impedito il particolare mismatch nei test controllati.

---

# 5. Soluzione funzionale richiesta

## 5.1 Principio

Non deve essere modificata la logica generale di `steam-link-display-adapter`.

Deve essere aggiunto un passaggio esplicito:

```text
Cambio output → verifica output → sincronizzazione Xwayland #1 → verifica Xwayland #1 → avvio gioco
```

La sincronizzazione di Xwayland #1 deve essere fatta tramite il meccanismo Gamescope:

```text
GAMESCOPE_XWAYLAND_MODE_CONTROL
```

con:

```text
server_idx = 1
width       = 1920
height      = 1200
allowSuperRes = 0
```

La chiamata viene elaborata da Gamescope e porta il server specificato a:

```text
1920x1200
```

utilizzando il refresh rate corrente dell'output Gamescope.

---

# 6. Nuova sequenza obbligatoria di avvio

La sequenza corretta deve essere:

```text
1. Rileva che Steam Link è attivo
        ↓
2. Backup configurazione
        ↓
3. Configura modes.cfg
        ↓
4. Abilita eventuali dynamic modes necessari
        ↓
5. Forza/richiedi re-poll Gamescope
        ↓
6. Porta DP-3 a 1920x1200@60
        ↓
7. Verifica realmente l'output:
      1920x1200
      60 Hz
        ↓
8. SCRIVE GAMESCOPE_XWAYLAND_MODE_CONTROL
      [1,1920,1200,0]
        ↓
9. Attende l'elaborazione della property
        ↓
10. Verifica che Xwayland #1 sia:
      1920x1200
        ↓
11. Solo dopo:
      avvia il processo del gioco
        ↓
12. Streaming
```

Il requisito fondamentale è:

> **Il gioco non deve essere eseguito finché Xwayland #1 non è stato verificato nella modalità target.**

---

# 7. Punto critico: il wrapper arriva dopo l'handshake

Non bisogna interpretare il fatto che il primo aggiornamento di Xwayland #1 avvenga prima dell'ingresso del wrapper come impossibilità di correggerlo.

La sorgente Gamescope dimostra che `GAMESCOPE_XWAYLAND_MODE_CONTROL` è un meccanismo runtime e può specificare esplicitamente quale Xwayland server modificare.

Quindi il comportamento desiderato è:

```text
Handshake iniziale
    ↓
Xwayland #1 può temporaneamente essere:
3440x1440
    ↓
wrapper prepara lo streaming
    ↓
output → 1920x1200
    ↓
wrapper forza esplicitamente:
Xwayland #1 → 1920x1200
    ↓
verifica
    ↓
avvio gioco
```

Il requisito non è impedire necessariamente il primo aggiornamento di #1.

Il requisito è **correggere #1 prima che il gioco inizi effettivamente a utilizzare il framebuffer di streaming**.

---

# 8. Implementazione del controllo Xwayland #1

Implementare nell'hook una funzione dedicata, separata dal cambio DRM:

```text
set_xwayland_server_mode(server_idx, width, height, allowSuperRes)
```

e una funzione specifica:

```text
set_stream_xwayland_mode()
```

con target:

```text
server_idx = 1
width      = 1920
height     = 1200
allowSuperRes = 0
```

La funzione deve scrivere correttamente la property X11:

```text
GAMESCOPE_XWAYLAND_MODE_CONTROL
```

sul root X corretto utilizzato da Gamescope.

Non assumere senza verifica che il display numerico Unix del server Xwayland coincida necessariamente con l'indice Gamescope. L'indice `1` nella property è il **server index Gamescope**, non deve essere confuso con `DISPLAY=:1`.

Il mapping tra:

```text
Gamescope server #0
Gamescope server #1
DISPLAY=:N
```

deve essere verificato nell'ambiente installato prima di rendere il codice definitivo.

La sorgente Gamescope espone inoltre `GAMESCOPE_XWAYLAND_SERVER_ID` sul root dei server Xwayland, che può essere utilizzato come supporto alla verifica del mapping.

---

# 9. Verifica obbligatoria dopo la scrittura

La funzione di sincronizzazione non deve limitarsi a scrivere la property.

Deve verificare che Gamescope abbia effettivamente applicato il cambio.

Quindi:

```text
write property
   ↓
poll/readback
   ↓
Xwayland #1 root size
   ↓
1920x1200 ?
```

Se disponibile nell'ambiente, utilizzare una verifica diretta della root window di Xwayland #1.

La condizione di successo deve essere:

```text
Xwayland #1 width  = 1920
Xwayland #1 height = 1200
```

Il refresh non va necessariamente letto da Xwayland come proprietà separata se la primitive Gamescope utilizza `g_nOutputRefresh`; la verifica fondamentale per il crash corrente è la geometria.

Il wrapper deve inoltre verificare che l'output DRM rimanga:

```text
1920x1200@60
```

quindi entrambe le verifiche devono risultare vere:

```text
Output:
1920x1200@60

Xwayland #1:
1920x1200
```

Solo a questo punto può procedere con:

```text
run_game "$@"
```

---

# 10. Fail-closed

Il comportamento fail-closed deve essere mantenuto ma applicato correttamente.

## Steam Link attivo

Se:

```text
output preparation
```

oppure:

```text
Xwayland #1 synchronization
```

fallisce:

```text
NON avviare il gioco
```

perché lo streaming potrebbe partire con una configurazione incoerente.

## Steam Link non attivo

Il wrapper deve invece comportarsi da passthrough:

```text
exec "$@"
```

senza richiedere Gamescope, `gamescopectl`, `xprop`, ecc.

Questo preserva il requisito precedente:

```text
Desktop Mode + gioco locale → deve funzionare

Gaming Mode + gioco locale → deve funzionare

Gaming Mode + Steam Link → attiva virtual display
```

---

# 11. Rilevamento della sessione Steam Link

Non utilizzare:

```text
Gamescope presente
```

come criterio per attivare la pipeline.

Non utilizzare neppure:

```text
Steam in esecuzione
```

come criterio.

Il criterio deve essere:

```text
Steam Remote Play / Steam Link streaming effettivamente attivo
```

Il meccanismo di rilevamento già presente nel progetto deve essere mantenuto o migliorato.

Il risultato deve essere booleano:

```text
steam_link_streaming_active = true
```

oppure:

```text
false
```

Questo consente:

```text
false → bypass completo
true  → pipeline virtual display
```

---

# 12. Gestione della modalità locale

La modalità locale attuale del monitor è:

```text
3440x1440@165
```

e deve essere ripristinata dopo lo streaming.

Il ripristino deve rimanere basato sul valore effettivamente configurato per il sistema.

Non trasformare il valore di restore in una costante se può essere rilevato dinamicamente.

Idealmente:

```text
prima dello streaming:
    rileva modalità locale
    salva modalità

streaming:
    1920x1200@60

restore:
    utilizza ESATTAMENTE la modalità precedentemente salvata
```

Nel sistema attuale la modalità target locale conosciuta è:

```text
3440x1440@165
```

quindi questa rimane la configurazione attesa di default.

---

# 13. Cleanup

Il cleanup deve ripristinare:

```text
1. monitor ON
2. modes.cfg originale
3. output 3440x1440@165
4. dynamic modes disabilitati
5. stato persistente cancellato
```

In aggiunta, deve essere verificato che il ripristino dell'output non lasci Xwayland #1 in uno stato incoerente.

Poiché il problema dello streaming è legato alla geometria di Xwayland #1, il processo di restore deve essere pensato come:

```text
restore output
    ↓
restore Xwayland state necessaria
    ↓
verify local mode
```

La soluzione non deve comunque alterare la modalità Xwayland #1 durante una normale sessione locale più del necessario.

---

# 14. Recovery da crash

Il crash corrente è particolarmente importante perché Steam può terminare prima che il wrapper riceva la normale fase di cleanup.

Di conseguenza deve continuare ad esistere il meccanismo:

```text
stale state detected
        ↓
restore modes.cfg
        ↓
restore monitor
        ↓
restore local output
        ↓
clear state
```

Il recovery deve essere idempotente.

Un nuovo avvio deve essere in grado di recuperare da:

```text
PHASE=PREPARING
```

oppure:

```text
PHASE=STREAMING
```

senza lasciare permanentemente:

```text
1920x1200
```

come modalità del desktop locale.

---

# 15. Gestione del refresh 164/165 Hz

È già noto che Gamescope può selezionare `164 Hz` come variante del mode durante determinate operazioni.

Questo non deve essere confuso con il problema principale.

Il sistema deve continuare ad accettare:

```text
1920x1200@60
```

come target primario e, dove già previsto dal progetto, le varianti di refresh necessarie al riconoscimento del mode.

Il restore locale rimane:

```text
3440x1440@165
```

---

# 16. Gestione dell'anomalia `Gamescope connector is ''`

L'anomalia:

```text
Gamescope connector is ''
```

è separata dal problema Xwayland #1.

Non deve essere utilizzata per giustificare un avvio Steam Link con configurazione sconosciuta.

Il comportamento consigliato è:

```text
connector non disponibile
    ↓
se Steam Link NON attivo
    → bypass, avvia gioco

se Steam Link ATTIVO
    → fail-closed
```

In questo modo il sistema non rompe il gaming locale ma resta sicuro durante lo streaming.

---

# 17. Verifica dell'ordine temporale

Aggiungere logging monotonicamente temporizzato per almeno questi eventi:

```text
STREAM_DETECTED
OUTPUT_PREPARE_START
OUTPUT_TARGET_REACHED
XWAYLAND1_SYNC_REQUESTED
XWAYLAND1_SYNC_CONFIRMED
GAME_LAUNCH
```

Formato concettuale:

```text
T0 STREAM_DETECTED
T1 OUTPUT_TARGET_REACHED 1920x1200@60
T2 XWAYLAND1_SYNC_REQUESTED 1/1920/1200/0
T3 XWAYLAND1_SYNC_CONFIRMED 1920x1200
T4 GAME_LAUNCH
```

Il vincolo temporale obbligatorio è:

```text
XWAYLAND1_SYNC_CONFIRMED < GAME_LAUNCH
```

Se:

```text
GAME_LAUNCH <= XWAYLAND1_SYNC_CONFIRMED
```

la preparazione deve essere considerata fallita.

---

# 18. Verifica del launch wrapper

Il doppio timestamp già osservato:

```text
Steam chdir
```

e:

```text
Launching game:
```

deve essere mantenuto nei log diagnostici.

Serve a distinguere:

```text
Steam launch handshake
```

da:

```text
effettiva esecuzione del gioco
```

Non assumere che il primo evento equivalga all'effettivo rendering del gioco.

L'obiettivo funzionale è dimostrare che il gioco non viene avviato/renderizzato prima della sincronizzazione Xwayland #1.

---

# 19. Test di accettazione

## Test 1 — Gaming Mode locale

Condizione:

```text
Steam Link OFF
Gamescope ON
Output 3440x1440@165
```

Azione:

```text
avviare normalmente un gioco
```

Risultato atteso:

```text
gioco avviato
nessun cambio a 1920x1200
monitor ON
nessun errore del wrapper
```

---

## Test 2 — Desktop Mode

Condizione:

```text
Steam Link OFF
Gamescope non disponibile
```

Azione:

```text
avviare il gioco tramite wrapper
```

Risultato atteso:

```text
exec diretto del gioco
nessun controllo Gamescope
nessun errore
```

---

## Test 3 — Steam Link, stato locale pulito

Condizione:

```text
output = 3440x1440@165
modes.cfg locale
```

Azione:

```text
avviare Steam Link
avviare il gioco
```

Risultato atteso:

```text
output = 1920x1200@60
Xwayland #1 = 1920x1200
stream stabile
nessun crash Steam
```

Questo è il test principale.

---

## Test 4 — Steam Link dopo precedente crash

Condizione:

```text
modes.cfg = eventuale stato leftover
state file presente
```

Azione:

```text
nuovo avvio
```

Risultato atteso:

```text
stale-state recovery
restore
nuova preparazione
Xwayland #1 sincronizzato
stream OK
```

---

## Test 5 — Interruzione durante PREPARING

Terminare forzatamente il wrapper durante:

```text
PREPARING
```

Risultato:

```text
successivo avvio
→ stale-state recovery
→ monitor ON
→ modes.cfg ripristinato
→ local mode ripristinato
```

---

## Test 6 — Simulazione fallimento Xwayland #1

Forzare un caso in cui:

```text
output = 1920x1200
Xwayland #1 != 1920x1200
```

Risultato atteso:

```text
wrapper NON deve avviare il gioco
```

---

# 20. Criterio di successo finale

La soluzione è considerata corretta soltanto quando il seguente stato viene osservato prima dell'avvio effettivo del gioco:

```text
                STEAM LINK ACTIVE
                        │
                        ▼
              DP-3 = 1920x1200@60
                        │
                        ▼
             Xwayland #1 = 1920x1200
                        │
                        ▼
                    GAME
                        │
                        ▼
             STREAM = 1920x1200
```

e alla terminazione:

```text
GAME END
   ↓
monitor ON
   ↓
DP-3 = 3440x1440@165
   ↓
modes.cfg originale
   ↓
stato pulito
```

---

# 21. Modifiche richieste all'implementazione

L'agent deve intervenire almeno sui seguenti punti:

### A. Hook Gamescope

Aggiungere:

```text
set_xwayland_server_mode()
set_stream_xwayland_mode()
get_xwayland_server_mode()
verify_stream_xwayland_mode()
```

o equivalenti coerenti con il codice esistente.

### B. Wrapper

Modificare:

```text
prepare_stream_mode()
```

in modo che non termini dopo la sola verifica DRM.

La nuova precondizione di completamento deve essere:

```text
OUTPUT VERIFIED
AND
XWAYLAND #1 VERIFIED
```

### C. Launch ordering

`run_game "$@"` deve essere raggiungibile soltanto dopo:

```text
output target reached
Xwayland #1 target reached
```

### D. Bypass locale

Preservare il comportamento:

```bash
exec "$@"
```

quando Steam Link non è attivo.

### E. Logging

Aggiungere log espliciti degli eventi:

```text
Steam Link detection
output transition
Xwayland #1 request
Xwayland #1 confirmation
game launch
restore
```

---

# 22. Vincoli

Non introdurre:

* una seconda istanza di Gamescope;
* un secondo display virtuale indipendente;
* un cambio permanente della risoluzione del sistema;
* modifiche permanenti alla configurazione Steam;
* patch del gioco;
* dipendenze specifiche da un singolo gioco.

La soluzione deve operare sulla sessione Gamescope esistente e sul suo Xwayland #1.

Non sostituire il problema con una semplice scalatura lato Steam Link: la causa da correggere è la coerenza della geometria della pipeline host.

---

# 23. Nota sulla documentazione Gamescope

La documentazione ufficiale di Gamescope conferma che Gamescope gestisce separatamente la risoluzione del gioco e quella dell'output e dispone di meccanismi specifici per le sessioni Xwayland. La documentazione/sorgente upstream mostra inoltre esplicitamente la possibilità di utilizzare più server Xwayland tramite `--xwayland-count`.

La sorgente attuale è la fonte tecnica primaria per `GAMESCOPE_XWAYLAND_MODE_CONTROL`; il codice mostra espressamente che il parametro `server_idx` viene usato per selezionare lo specifico server Xwayland e quindi chiamare `wlserver_set_xwayland_server_mode()`.

---

# 24. Punto da non dare per già dimostrato

Non considerare già dimostrato che:

```text
Steam scriva direttamente la property
```

La correlazione temporale osservata è forte ma non identifica ancora definitivamente il writer.

L'agent deve quindi evitare di basare l'implementazione sull'assunzione:

```text
Steam → property
```

e concentrarsi invece sul comportamento necessario:

```text
prima del gioco:
Xwayland #1 deve essere 1920x1200
```

La proprietà può essere aggiornata esplicitamente dal wrapper attraverso il meccanismo Gamescope verificato nel sorgente.

---

# 25. Risultato atteso

Il comportamento finale deve essere:

```text
                 ┌───────────────────────┐
                 │ Avvio gioco da Steam  │
                 └───────────┬───────────┘
                             │
                    Steam Link attivo?
                       /             \
                     NO               SI
                     │                 │
                     ▼                 ▼
                exec gioco       prepara output
                                      │
                                      ▼
                               1920x1200@60
                                      │
                                      ▼
                            sincronizza Xwayland #1
                                      │
                                      ▼
                              verifica 1920x1200
                                      │
                                      ▼
                                 avvia gioco
                                      │
                                      ▼
                               streaming OK
                                      │
                                      ▼
                                  fine gioco
                                      │
                                      ▼
                            restore 3440x1440@165
```

Il requisito fondamentale della correzione è quindi:

> **La modalità dell'output e la modalità del server Xwayland #1 devono essere trattate come due stati distinti che devono essere sincronizzati esplicitamente prima dell'avvio del gioco.**
