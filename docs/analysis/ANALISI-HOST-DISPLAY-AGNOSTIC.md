# Analisi funzionale — Host Display Agnostic

## 1. Obiettivo

Estendere `steam-link-display-adapter` affinché sia **agnostico rispetto al display fisico dell'host**.

L'utente finale non deve dover configurare manualmente:

* risoluzione del monitor host;
* refresh rate del monitor host;
* nome del connettore (`DP-3`, `HDMI-A-1`, ecc.);
* modello del monitor;
* altri parametri che descrivono lo stato locale dell'host.

Il progetto deve funzionare determinando questi dati **a runtime**, utilizzando Gamescope/DRM come source of truth.

La funzionalità deve partire dallo stato attuale del repository `main`.

---

# 2. Obiettivo architetturale

Il sistema deve distinguere due concetti completamente separati:

```text
HOST DISPLAY
    │
    ├── connector
    ├── physical/current mode
    ├── refresh
    ├── display description
    └── advertised modes
          │
          ▼
      capabilities
```

e:

```text
STEAM LINK CLIENT
    │
    ├── requested/maximum capture width
    ├── requested/maximum capture height
    └── client FPS
          │
          ▼
      client profile
```

Il resolver deve quindi continuare a fare:

```text
client profile
      +
host capabilities
      ↓
runtime target
```

mentre il profilo locale deve essere scoperto dinamicamente:

```text
current Gamescope/DRM state
      ↓
host profile
```

---

# 3. Problema attuale

La versione attuale contiene ancora diversi parametri che rappresentano implicitamente il computer dell'autore.

I principali sono:

```text
CONNECTOR='DP-3'

LOCAL_WIDTH=3440
LOCAL_HEIGHT=1440
LOCAL_REFRESH=165

STREAM_ALT_REFRESHES='164'
```

Questi valori non devono più rappresentare il setup dell'autore.

In particolare:

```text
DP-3
3440x1440
165 Hz
164 Hz
```

non devono comparire come presupposti dell'installazione standard.

---

# 4. Distinzione fondamentale: host vs client

Non confondere i parametri del client con quelli dell'host.

## Host-specifici

Devono diventare runtime:

```text
CONNECTOR
LOCAL_WIDTH
LOCAL_HEIGHT
LOCAL_REFRESH
LOCAL display description
LOCAL Xwayland geometry
host accepted refreshes
host advertised modes
```

## Client-specifici

Possono invece continuare ad esistere:

```text
STREAM_WIDTH
STREAM_HEIGHT
STREAM_REFRESH
STREAM_FPS
STREAM_ASPECT
```

perché rappresentano il target/fallback del client o la configurazione fixed.

Questi parametri non devono essere utilizzati per ricostruire lo stato originale dell'host.

---

# 5. Principio fondamentale

Il progetto deve passare da:

```text
CONFIGURATION
    ↓
"il mio monitor è 3440x1440@165"
```

a:

```text
RUNTIME DISCOVERY
    ↓
"il monitor attualmente gestito da Gamescope è 2560x1440@144"
```

Il valore scoperto deve diventare lo stato autorevole per tutta la sessione.

---

# 6. Host Profile runtime

Introdurre concettualmente un `Host Display Profile` runtime.

Esempio:

```text
HOST_CONNECTOR=HDMI-A-1
HOST_DESCRIPTION=ASUS VG27AQ
HOST_ORIGINAL_MODE=2560x1440@165
HOST_ORIGINAL_WIDTH=2560
HOST_ORIGINAL_HEIGHT=1440
HOST_ORIGINAL_REFRESH=165
HOST_ORIGINAL_XWAYLAND_MODE=2560x1440
```

Questi valori devono essere acquisiti all'inizio della sessione prima di modificare il display.

Non devono essere presi dalla configurazione.

---

# 7. Source of truth del connettore

Il connettore attivo deve essere determinato tramite Gamescope.

La logica attuale già dispone di:

```text
get_connector_name
```

e questa deve diventare la source of truth del runtime.

Non effettuare una scansione arbitraria di tutti i monitor per decidere quale utilizzare.

La logica deve essere:

```text
Gamescope current connector
        ↓
ACTIVE_CONNECTOR
        ↓
host mode discovery
```

Questo evita di selezionare accidentalmente un'altra uscita presente nel sistema.

---

# 8. Modalità `CONNECTOR=auto`

Il valore predefinito della configurazione deve diventare concettualmente:

```bash
CONNECTOR='auto'
```

oppure equivalente.

Semantica:

```text
CONNECTOR=auto
    ↓
usa il connector attualmente selezionato da Gamescope
```

Deve essere comunque possibile mantenere un override manuale:

```bash
CONNECTOR='HDMI-A-1'
```

per utenti con esigenze particolari.

La priorità deve essere:

```text
CONNECTOR=manuale
    ↓
verifica che il connector Gamescope coincida

CONNECTOR=auto
    ↓
usa quello rilevato da Gamescope
```

Se viene richiesto esplicitamente un connector diverso da quello attivo:

```text
FAIL-CLOSED
```

senza modificare il display.

---

# 9. Discovery della modalità originale

Prima di:

```text
write_saved_mode_for_description
set_dynamic_modes_allowed
nudge_mode
screen_sleep
```

deve essere rilevata la modalità attualmente attiva.

Usare la funzione già presente:

```text
get_current_mode
```

come source of truth del current DRM mode sul build Gamescope supportato.

Esempio:

```text
current mode = 2560x1440@165
```

deve diventare:

```text
ORIGINAL_MODE=2560x1440@165
```

Non deve essere più usato:

```text
LOCAL_WIDTH
LOCAL_HEIGHT
LOCAL_REFRESH
```

come riferimento per il restore.

---

# 10. Discovery obbligatoria prima della modifica

La sequenza deve diventare:

```text
STEAM LINK DETECTION
        ↓
HOST PROFILE DISCOVERY
        ↓
CLIENT PROFILE DISCOVERY
        ↓
TARGET RESOLUTION
        ↓
PRECHECK
        ↓
DISPLAY PREPARATION
        ↓
XWAYLAND SYNC
        ↓
GAME
```

Il `HOST PROFILE` deve essere catturato prima di qualsiasi mutazione.

Se non è possibile determinare la modalità originale:

```text
FAIL-CLOSED
```

e non devono essere eseguite:

```text
screen_sleep
mode switch
Xwayland modification
game launch
```

Questo è particolarmente importante perché non sarebbe sicuro procedere senza sapere cosa ripristinare.

---

# 11. Display description

La descrizione del display è già determinata dinamicamente attraverso:

```text
get_display_make
get_display_model
get_display_description
```

Questa logica deve essere mantenuta.

Quindi:

```text
DP-3 + ASUS + model
```

non devono essere valori configurati.

La descrizione deve continuare ad essere utilizzata come identificatore per la gestione di `modes.cfg`.

Questo è coerente con il comportamento di Gamescope: la persistenza del mode è associata alla descrizione del display.

---

# 12. Rimozione del concetto di `LOCAL_*`

Le variabili:

```text
LOCAL_WIDTH
LOCAL_HEIGHT
LOCAL_REFRESH
```

devono essere eliminate dal ruolo di configurazione host.

Non devono più comparire come:

```text
"local mode configurato dall'utente"
```

Il concetto corretto diventa:

```text
ORIGINAL_MODE
```

acquisito per ogni sessione.

Per chiarezza è preferibile utilizzare una rappresentazione unica:

```text
ORIGINAL_MODE=2560x1440@165
```

e derivare width/height/refresh quando necessario.

In alternativa possono essere mantenuti internamente:

```text
ORIGINAL_WIDTH
ORIGINAL_HEIGHT
ORIGINAL_REFRESH
```

ma devono essere sempre valorizzati dalla discovery runtime.

---

# 13. Restore dinamico

La fase di cleanup deve passare da:

```text
restore → LOCAL_WIDTH/HEIGHT/REFRESH
```

a:

```text
restore → ORIGINAL_MODE
```

Esempio:

```text
host iniziale:
2560x1440@165

stream:
1920x1080@60

cleanup:
→ restore 2560x1440@165
```

Altro esempio:

```text
host iniziale:
3440x1440@165

stream:
1920x1200@60

cleanup:
→ restore 3440x1440@165
```

Altro esempio:

```text
host iniziale:
3840x2160@144

stream:
1920x1080@60

cleanup:
→ restore 3840x2160@144
```

Lo stesso algoritmo deve funzionare senza modifiche per tutti i casi.

---

# 14. Restore Xwayland dinamico

Anche Xwayland #1 non deve essere ripristinato usando:

```text
LOCAL_WIDTH
LOCAL_HEIGHT
```

Deve essere acquisita la geometria originale del server prima della modifica.

Esempio:

```text
HOST_ORIGINAL_XWAYLAND_MODE=3440x1440
```

Durante lo stream:

```text
Xwayland #1 = 1920x1200
```

Cleanup:

```text
Xwayland #1 = 3440x1440
```

su un altro PC:

```text
HOST_ORIGINAL_XWAYLAND_MODE=2560x1440
```

cleanup:

```text
Xwayland #1 = 2560x1440
```

---

# 15. Persistenza nello state file

Il profilo originale deve essere salvato nello state file.

Questo è fondamentale per lo stale-state recovery.

Aggiungere concettualmente campi come:

```text
ORIGINAL_CONNECTOR=HDMI-A-1
ORIGINAL_MODE=2560x1440@165
ORIGINAL_XWAYLAND_MODE=2560x1440
DISPLAY_DESCRIPTION=...
```

Non è necessario replicare tutti i dati se alcuni possono essere derivati, ma lo stato deve contenere abbastanza informazioni da consentire un restore indipendente dalla configurazione corrente.

---

# 16. Stale-state recovery

Questa parte è critica.

Non deve più essere possibile avere:

```text
stale state
    ↓
config attuale
    ↓
"il monitor è 3440x1440@165"
```

Il recovery deve usare i dati del run interrotto:

```text
STATE_FILE
    ↓
ORIGINAL_MODE
ORIGINAL_XWAYLAND_MODE
ORIGINAL_CONNECTOR
    ↓
restore
```

Questo rende il recovery veramente portabile.

---

# 17. Compatibilità con vecchi state file

Per gli state file prodotti da versioni precedenti che non possiedono:

```text
ORIGINAL_MODE
```

deve essere prevista una gestione compatibile.

Non deve essere inventata una nuova modalità arbitraria.

La strategia preferibile è:

```text
state moderno
    ↓
restore con ORIGINAL_MODE

state legacy
    ↓
fallback legacy compatibile
```

Il fallback legacy può continuare temporaneamente ad utilizzare la configurazione preesistente.

Questo serve solamente per evitare che un aggiornamento del programma renda impossibile recuperare una sessione lasciata da una versione precedente.

---

# 18. Resolver: non riscriverlo inutilmente

Il resolver attuale è già concettualmente corretto:

```text
client hint
    ↓
host advertised modes
    ↓
compatible target
```

Non deve essere riscritto solamente per rendere il progetto host-agnostic.

Il cambiamento necessario è fare in modo che:

```text
get_host_mode_list
mode_list_contains
```

lavorino sempre con il connector rilevato runtime.

Il resolver deve continuare a ricevere:

```text
host capabilities
```

e non informazioni hardcoded sull'host.

---

# 19. Host mode discovery

La funzione:

```text
get_host_mode_list
```

deve utilizzare:

```text
ACTIVE_CONNECTOR
```

e non un:

```text
CONNECTOR='DP-3'
```

hardcoded.

Le sorgenti attuali devono rimanere invariate:

```text
Gamescope X atom
        ↓
modes.cfg
        ↓
kernel ModeDB
```

Cambiare solamente il connector utilizzato dalla query.

---

# 20. `DRM_MODES_GLOB`

Il fallback:

```text
/sys/class/drm/card*-$CONNECTOR/modes
```

deve essere risolto tramite il connector runtime.

Concettualmente:

```text
ACTIVE_CONNECTOR=HDMI-A-1

→ /sys/class/drm/card*-HDMI-A-1/modes
```

oppure:

```text
ACTIVE_CONNECTOR=DP-2

→ /sys/class/drm/card*-DP-2/modes
```

Non devono essere presenti assunzioni su `DP-3`.

---

# 21. Refresh rate: eliminare l'ultimo hardcode dell'host

Il parametro:

```text
STREAM_ALT_REFRESHES='164'
```

è ancora legato all'hardware specifico utilizzato durante lo sviluppo.

Questo valore non deve essere richiesto ad altri utenti.

Non sostituirlo semplicemente con un altro numero.

La soluzione deve essere dinamica.

Dopo lo switch:

```text
target = 1920x1200@60
```

se Gamescope seleziona:

```text
1920x1200@164
```

deve essere possibile riconoscere che:

```text
geometry = target
```

anche se:

```text
refresh != requested refresh
```

La verifica deve quindi poter determinare dinamicamente i refresh validi per quella risoluzione dai mode realmente disponibili.

---

# 22. Principio di verifica del target

La proprietà fondamentale è:

```text
TARGET WIDTH
TARGET HEIGHT
```

non il valore hardcoded del monitor host.

Per esempio:

```text
requested:
1920x1200@60

actual:
1920x1200@164
```

deve essere accettabile quando il refresh viene legittimamente ripickato da Gamescope.

Non deve invece essere accettato:

```text
actual:
2560x1440@164
```

perché la geometria è diversa.

Quindi:

```text
same width
+
same height
=
same stream geometry
```

---

# 23. Fixed mode

Il comportamento di:

```text
STREAM_MODE=fixed
```

deve essere mantenuto.

In questo caso è l'utente a scegliere esplicitamente:

```text
STREAM_WIDTH
STREAM_HEIGHT
STREAM_REFRESH
```

La differenza è che anche il fixed mode deve verificare dinamicamente le capacità dell'host.

Esempio:

```text
STREAM_MODE=fixed
STREAM_WIDTH=1920
STREAM_HEIGHT=1080
```

su:

```text
host A = 3440x1440
```

deve funzionare se:

```text
1920x1080
```

è disponibile.

Su:

```text
host B = 2560x1440
```

deve funzionare se:

```text
1920x1080
```

è disponibile.

Su un host che non espone quel mode:

```text
FAIL-CLOSED
```

---

# 24. `--mode WxH`

Il comportamento CLI già esistente deve rimanere.

Esempio:

```text
steam-link-display-adapter --mode 1920x1080 %command%
```

deve significare:

```text
client target geometry = 1920x1080
```

indipendentemente dal display host corrente.

Il resolver deve però continuare a verificare che l'host supporti tale geometria.

---

# 25. Auto mode

Il percorso principale deve diventare:

```text
Steam Link active
        ↓
discover host
        ↓
read client Maximum capture
        ↓
resolve target against host modes
        ↓
switch Gamescope
        ↓
sync Xwayland #1
        ↓
launch
```

Nessun valore del monitor host deve essere necessario nella configurazione dell'utente.

---

# 26. Fallback quando il client hint non è disponibile

Questo punto deve essere ripensato perché l'attuale fallback:

```text
1920x1200
```

è legato al dispositivo utilizzato durante lo sviluppo.

Nel percorso:

```text
STREAM_MODE=auto
```

se il client hint è stale/non disponibile, il fallback predefinito dovrebbe essere **host-safe**, cioè basato sul mode originale dell'host:

```text
CLIENT HINT unavailable
        ↓
ORIGINAL_MODE
```

Esempio:

```text
host:
2560x1440@165

client hint:
unavailable

target:
2560x1440@165
```

Questo evita che un nuovo utente con un host diverso erediti implicitamente:

```text
1920x1200
```

come requisito.

---

# 27. Semantica del fallback

La priorità consigliata diventa:

```text
CLI --mode WxH
        ↓
global STREAM_MODE=fixed
        ↓
valid Steam client hint
        ↓
host-original-mode fallback
```

Nel caso di `--mode auto`:

```text
valid hint
    → dynamic client resolution

hint unavailable
    → safe host fallback
```

Questo rende `auto` realmente utilizzabile senza conoscere nulla dell'hardware locale.

---

# 28. Attenzione al significato di "host-agnostic"

Il progetto deve essere descritto correttamente.

Non significa:

```text
qualsiasi risoluzione Steam Link
→ sempre creata sull'host
```

Significa:

```text
qualsiasi host
+
mode compatibili esposti da quell'host
→ runtime resolution selection
```

Il progetto non deve inventare arbitrariamente un mode DRM che il connector non supporta.

Quindi continuano ad esistere vincoli come:

```text
mode presente nel ModeDB
```

e:

```text
aspect ratio compatibile
```

quando richiesto dal resolver.

---

# 29. Esempio di comportamento desiderato

## Host A

```text
Monitor:
3440x1440@165

Steam Link:
1920x1200@60
```

Risultato:

```text
original:
3440x1440@165

target:
1920x1200

restore:
3440x1440@165
```

## Host B

```text
Monitor:
2560x1440@144

Steam Link:
1920x1080@60
```

Risultato:

```text
original:
2560x1440@144

target:
1920x1080

restore:
2560x1440@144
```

## Host C

```text
Monitor:
3840x2160@120

Steam Link:
1280x800@60
```

Se l'host espone una geometria 16:10 compatibile:

```text
target:
best compatible 16:10 host mode
```

altrimenti:

```text
FAIL-CLOSED
```

senza modificare il display.

---

# 30. Multi-monitor

Non è necessario trasformare il progetto in un monitor manager completo.

Il comportamento desiderato è:

```text
Gamescope current connector
        ↓
connector target
```

Non:

```text
scan all monitors
choose one based on resolution
```

Questo mantiene il progetto semplice e coerente con l'architettura attuale.

L'override manuale:

```text
CONNECTOR='HDMI-A-1'
```

rimane disponibile per casi particolari.

---

# 31. Report diagnostico

`steam-link-display-adapter-verify-environment` deve diventare utile anche su macchine sconosciute.

Invece di:

```text
Connector requested: DP-3
Fallback mode: ...
Local mode: 3440x1440@165
```

deve poter mostrare:

```text
--- Host display ---
Connector: HDMI-A-1
Description: ASUS VG27AQ
Current mode: 2560x1440@165
Xwayland #1: 2560x1440

--- Host modes ---
...
```

e:

```text
--- Client capture hint ---
Maximum capture: 1920x1080 60 FPS
```

Questo permette di diagnosticare rapidamente qualsiasi hardware.

---

# 32. Configurazione

Il file:

```text
config/steam-link-display-adapter.conf.example
```

non deve più presentarsi come una descrizione dell'hardware dell'autore.

Rimuovere o trasformare in automatico:

```text
CONNECTOR='DP-3'
LOCAL_WIDTH=3440
LOCAL_HEIGHT=1440
LOCAL_REFRESH=165
STREAM_ALT_REFRESHES='164'
```

Il commento deve chiarire:

```text
Host display geometry is detected automatically.
```

---

# 33. Configurazione minima desiderata

Un'installazione standard deve poter funzionare con una configurazione concettualmente simile a:

```text
CONNECTOR='auto'
STREAM_MODE='auto'
```

senza:

```text
LOCAL_WIDTH
LOCAL_HEIGHT
LOCAL_REFRESH
```

obbligatori.

Il resto deve essere discovery/runtime.

---

# 34. Modulo consigliato

Coerentemente con l'architettura attuale, è consigliabile introdurre un modulo dedicato al profilo del display host, ad esempio:

```text
lib/display/profile.sh
```

Responsabilità:

```text
discover host connector
discover current mode
discover display description
capture original host state
expose runtime host profile
```

Non deve contenere:

```text
Steam detection
client resolution resolver
Xwayland implementation
workflow orchestration
```

Il modulo `display/mode.sh` deve continuare a gestire:

```text
mode list
mode availability
mode switch
mode verification
```

mentre `display/profile.sh` gestisce:

```text
"what was the host state before we touched it?"
```

---

# 35. Cambiamenti principali per modulo

## `lib/core/config.sh`

Rimuovere la dipendenza dal profilo host statico.

Da:

```text
CONNECTOR=DP-3
LOCAL_*=...
```

a:

```text
CONNECTOR=auto
```

senza `LOCAL_*` come fonte di verità.

---

## `lib/display/connector.sh`

Mantenere:

```text
get_connector_name
get_display_make
get_display_model
get_display_description
```

e aggiungere, se necessario:

```text
resolve_active_connector
```

che gestisca:

```text
auto
manual override
```

---

## `lib/display/profile.sh`

Nuovo componente consigliato.

Gestisce:

```text
capture_host_profile
get_original_mode
get_original_xwayland_mode
```

---

## `lib/display/mode.sh`

Modificare solamente il modo in cui viene individuato il connector e rimuovere la dipendenza da:

```text
LOCAL_WIDTH
LOCAL_HEIGHT
LOCAL_REFRESH
STREAM_ALT_REFRESHES=164
```

---

## `lib/state/state.sh`

Persistenza:

```text
ORIGINAL_CONNECTOR
ORIGINAL_MODE
ORIGINAL_XWAYLAND_MODE
```

---

## `lib/xwayland/mode.sh`

Il restore deve ricevere la geometria originale runtime.

Da:

```text
restore → LOCAL_WIDTH/HEIGHT
```

a:

```text
restore → ORIGINAL_XWAYLAND_MODE
```

---

## `lib/core/workflow.sh`

Inserire la discovery del profilo host prima della prima mutazione:

```text
detect
↓
capture host profile
↓
resolve client target
↓
precheck
↓
prepare
```

Durante cleanup:

```text
restore original host profile
```

---

## `lib/core/restore.sh`

Usare il profilo salvato nello state file.

Non leggere la configurazione corrente per indovinare lo stato precedente.

---

## `lib/core/report.sh`

Mostrare il profilo host rilevato dinamicamente.

---

# 36. Logging

Aggiungere un evento/log esplicito all'inizio della pipeline:

```text
HOST_PROFILE_DETECTED
```

con informazioni del tipo:

```text
HOST_PROFILE_DETECTED connector=HDMI-A-1 mode=2560x1440@165 xwayland=2560x1440
```

Questo permette di correlare immediatamente:

```text
HOST
CLIENT
TARGET
RESTORE
```

nel log.

---

# 37. Logging del target

Continuare a mantenere la distinzione esistente:

```text
HOST_PROFILE
CLIENT_HINT
TARGET_MODE
```

Esempio:

```text
HOST_PROFILE_DETECTED connector=HDMI-A-1 mode=2560x1440@165
CLIENT_HINT 1920x1080@60
TARGET_MODE_RESOLVED 1920x1080@60 source=steam_capture_hint
```

Questo è preferibile a log generici perché rende il comportamento diagnosticabile su hardware sconosciuto.

---

# 38. Test automatici

La suite hardware-free deve diventare **parametrica rispetto all'host**.

Attualmente molti test assumono:

```text
3440x1440@165
DP-3
```

Queste assunzioni devono essere rimosse.

---

# 39. Host test matrix

Aggiungere almeno profili simulati come:

```text
Host A:
3440x1440@165
DP-3

Host B:
2560x1440@144
HDMI-A-1

Host C:
3840x2160@120
DP-1

Host D:
1920x1080@60
HDMI-1
```

I test devono poter cambiare host senza modificare il codice del wrapper.

---

# 40. Test di restore dinamico

Ogni profilo deve verificare:

```text
original host mode
        ↓
stream target
        ↓
cleanup
        ↓
original host mode
```

Esempio:

```text
2560x1440@144
→ 1920x1080
→ 2560x1440@144
```

Questo deve essere verificato esplicitamente.

---

# 41. Test connector dinamico

Verificare almeno:

```text
DP-3
HDMI-A-1
DP-1
```

senza modificare il codice.

Il test deve dimostrare che:

```text
CONNECTOR=auto
```

segue il connector esposto da Gamescope.

---

# 42. Test refresh dinamico

Simulare host con:

```text
60 Hz
120 Hz
144 Hz
165 Hz
240 Hz
```

e verificare che il restore usi sempre il valore realmente rilevato.

Non deve esistere alcuna assunzione:

```text
165
164
```

nel percorso runtime.

---

# 43. Test no-hint

Verificare:

```text
client hint presente
```

e:

```text
client hint assente
```

Nel secondo caso, in `STREAM_MODE=auto`, verificare il fallback host-safe:

```text
target = original host mode
```

senza dipendere da:

```text
3440x1440
1920x1200
165
```

---

# 44. Test fixed mode

Il test deve dimostrare che:

```text
STREAM_MODE=fixed
```

continua a funzionare su host diversi.

Esempio:

```text
Host:
3840x2160

Fixed:
1920x1080

→ target 1920x1080
→ restore 3840x2160
```

---

# 45. Test CLI

Mantenere invariati:

```text
--mode auto
--mode WxH
```

e verificare che il comportamento sia indipendente dal mode originale dell'host.

Esempio:

```text
Host:
3440x1440

--mode 1920x1080
```

e:

```text
Host:
2560x1440

--mode 1920x1080
```

devono produrre lo stesso target purché il mode sia supportato.

---

# 46. Test stale recovery

Creare state file simulati:

```text
ORIGINAL_MODE=3440x1440@165
```

e:

```text
ORIGINAL_MODE=2560x1440@144
```

e verificare che il recovery utilizzi esclusivamente lo stato salvato.

Questo è uno dei test più importanti dell'intera funzionalità.

---

# 47. Test regressivi da preservare

Devono continuare a passare tutti i test relativi a:

```text
Steam Link detection
first connection
launch race
dynamic client resolution
CLI --mode
Xwayland #1
fail-closed
cleanup
stale recovery
screen sleep/wake
argv preservation
Desktop Mode bypass
```

Questa feature non deve alterare tali comportamenti.

---

# 48. Documentazione

Aggiornare:

```text
README.md
config/steam-link-display-adapter.conf.example
docs/analysis/ANALISI-RISOLUZIONE-DINAMICA.md
docs/technical/DOCUMENTAZIONE-TECNICA.md
```

La documentazione deve mostrare esempi con host differenti.

Non usare più:

```text
3440x1440
DP-3
165 Hz
```

come valori universali.

Possono essere presenti solo come esempio storico, non come requisito.

---

# 49. README: nuovo messaggio concettuale

Il README deve comunicare chiaramente:

```text
The host display does not need to be configured manually.

The adapter discovers the active Gamescope display,
its current mode and its available modes at runtime.
```

e:

```text
The client resolution comes from Steam Remote Play.
The host resolution comes from Gamescope/DRM.
```

Questa distinzione deve diventare uno dei punti fondamentali del progetto.

---

# 50. Limiti da documentare

Il progetto non deve promettere:

```text
supporto assoluto di qualsiasi risoluzione
```

Deve invece dichiarare chiaramente:

```text
The target resolution must be supported by the host's
Gamescope/DRM mode set, or a compatible host mode must exist.
```

Questa limitazione è tecnica e deve rimanere esplicita.

---

# 51. Sequenza finale desiderata

La pipeline completa deve diventare:

```text
GAME LAUNCH
    │
    ▼
STEAM LINK DETECTION
    │
    ▼
HOST PROFILE DISCOVERY
    │
    ├── connector
    ├── current mode
    ├── display description
    └── original Xwayland mode
    │
    ▼
CLIENT PROFILE DISCOVERY
    │
    └── Maximum capture: WxH FPS
    │
    ▼
TARGET RESOLUTION
    │
    └── resolve against HOST MODES
    │
    ▼
PRECHECK
    │
    ▼
MODIFY GAMESCOPE
    │
    ▼
SYNC XWAYLAND #1
    │
    ▼
SLEEP PHYSICAL DISPLAY
    │
    ▼
GAME LAUNCH
    │
    ▼
GAME EXIT
    │
    ▼
RESTORE USING SAVED HOST PROFILE
```

---

# 52. Invarianti da mantenere

Devono rimanere invariati questi principi:

```text
NO VERIFIED TARGET
    → NO DISPLAY SLEEP
    → NO GAME LAUNCH
```

e:

```text
NO ORIGINAL HOST PROFILE
    → NO DISPLAY MODIFICATION
```

e:

```text
CLIENT TARGET
    ≠
HOST ORIGINAL MODE
```

Il primo è ciò che il client vuole.

Il secondo è ciò che l'host aveva prima della modifica.

---

# 53. Definition of Done

La feature è completata quando:

```text
[✓] nessun host deve configurare la propria risoluzione

[✓] nessun host deve configurare il proprio refresh

[✓] DP-3 non è più assunto come connector predefinito

[✓] il connector viene rilevato da Gamescope

[✓] il mode originale viene rilevato a runtime

[✓] il mode originale viene salvato nello state file

[✓] cleanup ripristina il mode rilevato

[✓] Xwayland #1 viene ripristinato usando la geometria originale rilevata

[✓] stale recovery usa il profilo salvato

[✓] 164 Hz non è più hardcoded

[✓] il resolver continua a usare i mode reali dell'host

[✓] STREAM_MODE=fixed continua a funzionare

[✓] --mode WxH continua a funzionare

[✓] --mode auto continua a funzionare

[✓] Steam Link detection resta invariata

[✓] first connection resta invariata

[✓] launch race resta invariata

[✓] Desktop Mode bypass resta invariato

[✓] fail-closed resta invariato

[✓] test suite completamente parametrizzata rispetto all'host

[✓] testato almeno con più risoluzioni

[✓] testato con più connector

[✓] testato con più refresh rate

[✓] README e config non presentano più l'hardware dell'autore come requisito
```

---

# 54. Regola progettuale finale

Il progetto deve rispettare questa separazione:

```text
┌──────────────────────────────┐
│ HOST                         │
│                              │
│ Gamescope / DRM              │
│ connector                    │
│ original mode                │
│ available modes              │
└──────────────┬───────────────┘
               │
               ▼
       HOST CAPABILITIES
               │
               │
               ▼
┌──────────────────────────────┐
│ STEAM LINK CLIENT            │
│                              │
│ Maximum capture              │
│ client FPS                   │
└──────────────┬───────────────┘
               │
               ▼
        TARGET RESOLUTION
               │
               ▼
       GAMESCOPE + XWAYLAND
```

La regola principale da applicare durante l'implementazione è:

> **La configurazione descrive preferenze e comportamento; non deve descrivere l'hardware fisico dell'host.**

L'hardware dell'host deve essere scoperto a runtime, salvato come stato della sessione e utilizzato esclusivamente come riferimento per capability, preparazione e restore.

Il risultato finale deve permettere di installare lo stesso progetto su macchine con, ad esempio:

```text
1920x1080
2560x1440
3440x1440
3840x2160
```

e con connector differenti, senza modificare il wrapper o configurare manualmente il profilo del monitor.
