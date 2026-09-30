> **NOTA (2026-09-30) — SUPERATA.** L'intera modalita' CLI `--mode` descritta qui e' stata **rimossa**:
> l'unica Launch Option pubblica e' `steam-link-display-adapter %command%` e il target di streaming
> viene sempre risolto automaticamente. Specifica vigente:
> [`ANALISI-RIMOZIONE-MODALITA-CLI.md`](ANALISI-RIMOZIONE-MODALITA-CLI.md). Documento conservato come
> riferimento storico.
>
> **NOTA (2026-09-29) — superata in parte.** La sintassi `--mode WxH@FPS` descritta qui e' stata
> rimossa: le Steam Launch Options accettano solo `auto` e `WxH`, il refresh e' sempre scelto dal resolver.
> Vedi [`ANALISI-RIMOZIONE-FPS-CLI.md`](ANALISI-RIMOZIONE-FPS-CLI.md). Il resto del documento resta valido.

# Analisi funzionale

## Steam Launch Options: override risoluzione e FPS per singolo gioco

## 1. Obiettivo

Estendere l'attuale implementazione di `steam-link-display-adapter` aggiungendo la possibilità di specificare, direttamente nelle Steam Launch Options del singolo gioco, una modalità di streaming esplicita composta da:

* risoluzione;
* risoluzione + FPS/refresh richiesto;
* modalità automatica.

La nuova funzionalità deve essere un'estensione non invasiva della branch:

```text
feature/dinamic-client-resolution
```

Il comportamento dinamico già implementato deve rimanere il comportamento predefinito quando non viene specificato alcun override.

L'obiettivo è permettere configurazioni per-gioco come:

```text
steam-link-display-adapter %command%
```

```text
steam-link-display-adapter --mode auto %command%
```

```text
steam-link-display-adapter --mode 1920x1200 %command%
```

```text
steam-link-display-adapter --mode 1920x1200@60 %command%
```

senza modificare permanentemente la configurazione globale.

---

# 2. Comportamento desiderato

Il sistema deve supportare tre modalità operative.

### Modalità AUTO

```text
steam-link-display-adapter %command%
```

oppure:

```text
steam-link-display-adapter --mode auto %command%
```

Comportamento:

```text
Steam Link
    ↓
rileva client
    ↓
legge Maximum capture
    ↓
mode resolver esistente
    ↓
TARGET_* dinamico
```

Questo deve essere esattamente il comportamento dinamico già funzionante.

---

### Modalità FIXED — sola risoluzione

Esempio:

```text
steam-link-display-adapter --mode 1920x1200 %command%
```

Significato:

> forza la geometria `1920x1200`, ma non forza un refresh specifico.

Quindi:

```text
WIDTH  = 1920
HEIGHT = 1200
REFRESH = AUTO
```

Il refresh viene determinato utilizzando i mode disponibili sull'host e le regole di selezione già presenti nell'implementazione.

L'override deve quindi bloccare solamente:

```text
TARGET_WIDTH
TARGET_HEIGHT
```

lasciando il refresh risolvibile.

---

### Modalità FIXED — risoluzione + FPS

Esempio:

```text
steam-link-display-adapter --mode 1920x1200@60 %command%
```

Significato:

> forza `1920x1200` e forza `60 FPS/Hz` come parametro di refresh richiesto.

Il target runtime deve diventare:

```text
TARGET_WIDTH   = 1920
TARGET_HEIGHT  = 1200
TARGET_REFRESH = 60
```

In questo caso il refresh non deve essere sostituito dal resolver dinamico.

---

# 3. Priorità delle configurazioni

Il valore proveniente dalla Launch Option deve avere precedenza sulla configurazione globale.

Ordine:

```text
1. --mode dalla Launch Option
2. STREAM_MODE / configurazione globale esistente
3. comportamento AUTO predefinito
```

Quindi:

```text
CLI override
    ↓
global config
    ↓
auto
```

Esempio:

```text
STREAM_MODE=auto
```

e:

```text
--mode 1920x1080@60
```

Risultato:

```text
1920x1080@60
```

Non deve essere utilizzato il client hint per determinare la geometria.

---

# 4. Retrocompatibilità

Un'installazione esistente non deve richiedere modifiche.

Questa Launch Option:

```text
steam-link-display-adapter %command%
```

deve continuare a produrre esattamente il comportamento dinamico già implementato.

Non modificare:

* rilevamento Steam Link;
* rilevamento della prima connessione;
* `pactl subscribe`;
* parsing `Maximum capture`;
* resolver automatico;
* sincronizzazione Xwayland #1;
* cleanup;
* stale-state recovery;
* restore della modalità locale.

La nuova funzionalità deve intervenire solamente nella scelta del `TARGET_*`.

---

# 5. Contratto del nuovo parametro

Implementare il parametro:

```text
--mode VALUE
```

Valori validi:

```text
auto
WxH
WxH@FPS
```

dove:

```text
W = width
H = height
FPS = refresh/FPS richiesto
```

Esempi validi:

```text
--mode auto
--mode 1920x1200
--mode 1920x1200@60
--mode 1920x1080
--mode 2560x1440@120
```

---

# 6. Sintassi non valida

Devono essere rifiutati:

```text
--mode
--mode 1920
--mode x1200
--mode 1920x
--mode 1920x1200@
--mode @60
--mode 1920x1200@abc
--mode -1920x1200
--mode 0x1200
--mode 1920x0
```

In presenza di parametro non valido:

```text
exit non-zero
```

prima di modificare il display.

Non deve essere effettuata alcuna modifica a:

* output;
* modes.cfg;
* Xwayland;
* monitor;
* stato persistente.

---

# 7. Parsing delle Steam Launch Options

La Launch Option deve essere strutturata:

```text
steam-link-display-adapter [wrapper options] %command%
```

Il wrapper deve consumare esclusivamente i propri parametri presenti prima del comando del gioco.

Esempio:

```text
steam-link-display-adapter --mode 1920x1200@60 %command%
```

Il wrapper deve interpretare:

```text
--mode
1920x1200@60
```

e passare integralmente al gioco:

```text
%command%
```

senza inoltrare:

```text
--mode
1920x1200@60
```

al processo del gioco.

---

# 8. Separazione wrapper command / game command

Il parser deve produrre concettualmente:

```text
WRAPPER_OPTIONS
GAME_COMMAND
```

Esempio:

```text
input:

--mode 1920x1200@60
/usr/bin/game
--some-game-option
foo
```

output parser:

```text
MODE_OVERRIDE=1920x1200@60

GAME_COMMAND:
/usr/bin/game
--some-game-option
foo
```

Il gioco deve quindi essere avviato esattamente come senza il parametro.

Non modificare:

* ordine degli argomenti del gioco;
* quoting;
* variabili ambientali;
* Proton arguments;
* eventuali parametri già presenti dopo `%command%`.

---

# 9. Parsing robusto

Il parser deve essere implementato esplicitamente e non tramite una semplice sostituzione testuale.

Preferire una struttura equivalente a:

```text
parse wrapper options
        ↓
determine game command boundary
        ↓
preserve remaining argv verbatim
```

Supportare eventualmente anche:

```text
--mode 1920x1200@60 -- %command%
```

ma la sintassi principale deve rimanere:

```text
--mode ... %command%
```

Non rendere `--` obbligatorio.

---

# 10. Variabili runtime

Non sovrascrivere permanentemente le variabili di configurazione.

Utilizzare variabili runtime separate:

```text
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
TARGET_SOURCE
```

Aggiungere eventualmente:

```text
TARGET_MODE_SPEC
```

per conservare il valore originale:

```text
auto
1920x1200
1920x1200@60
```

Esempio:

```text
--mode 1920x1200@60
```

deve produrre:

```text
TARGET_WIDTH=1920
TARGET_HEIGHT=1200
TARGET_REFRESH=60
TARGET_SOURCE=cli
TARGET_MODE_SPEC=1920x1200@60
```

---

# 11. Modalità AUTO

Con:

```text
--mode auto
```

il comportamento deve essere identico all'attuale modalità dinamica.

Deve quindi eseguire:

```text
client hint
    ↓
Maximum capture
    ↓
mode resolver
    ↓
TARGET_*
```

Il parametro `--mode auto` serve quindi solamente come override esplicito che forza la modalità automatica, utile anche per sovrascrivere eventuali configurazioni globali fixed.

---

# 12. Modalità solo risoluzione

Con:

```text
--mode 1920x1200
```

il resolver client non deve poter cambiare:

```text
TARGET_WIDTH
TARGET_HEIGHT
```

Deve però poter essere utilizzato il meccanismo esistente per determinare un refresh compatibile.

Quindi:

```text
WIDTH/HEIGHT = fixed
REFRESH      = auto
```

Esempio:

```text
host modes:

1920x1200@60
1920x1200@90
1920x1200@120

CLI:

--mode 1920x1200
```

La selezione del refresh deve essere effettuata dal resolver esistente secondo le sue regole.

Non duplicare l'algoritmo nel parser CLI.

---

# 13. Modalità risoluzione + refresh

Con:

```text
--mode 1920x1200@60
```

tutti i tre valori sono vincolati:

```text
WIDTH   = 1920
HEIGHT  = 1200
REFRESH = 60
```

Il resolver dinamico non deve modificare nessuno di questi valori.

Deve solamente verificare se il mode richiesto è disponibile e applicabile.

---

# 14. Gestione mode non disponibile

Caso:

```text
--mode 1920x1200@75
```

ma Gamescope non dispone di:

```text
1920x1200@75
```

Il comportamento deve essere fail-closed durante uno stream attivo.

Non sostituire automaticamente:

```text
75
```

con:

```text
60
```

perché il refresh è stato esplicitamente richiesto dall'utente.

Log:

```text
CLI_TARGET_MODE=1920x1200@75
TARGET_MODE_UNAVAILABLE
```

e:

```text
game NOT launched
```

---

# 15. Differenza tra risoluzione fixed e refresh fixed

Questo comportamento deve essere mantenuto esplicitamente:

```text
--mode 1920x1200
```

non equivale a:

```text
--mode 1920x1200@60
```

Il primo:

```text
WIDTH/HEIGHT fixed
REFRESH automatico
```

Il secondo:

```text
WIDTH/HEIGHT fixed
REFRESH fixed
```

Questo consente di sfruttare automaticamente eventuali varianti disponibili sull'host senza rinunciare all'override geometrico.

---

# 16. Integrazione con il resolver esistente

Non creare un secondo mode resolver.

La pipeline deve diventare:

```text
                    MODE SOURCE
                         │
              ┌──────────┼──────────┐
              │          │          │
              ▼          ▼          ▼
             CLI       CONFIG      AUTO
              │          │          │
              └──────────┼──────────┘
                         ▼
                   TARGET RESOLUTION
                         │
                         ▼
                    TARGET_* vars
                         │
             ┌───────────┴───────────┐
             ▼                       ▼
         Gamescope               Xwayland #1
             │                       │
             └───────────┬───────────┘
                         ▼
                     GAME
```

Il parser CLI deve solamente stabilire la sorgente del target.

---

# 17. Modelizzazione consigliata

Internamente il target dovrebbe essere concettualmente modellato come:

```text
ModeRequest:
    source
    width
    height
    refresh
    refresh_fixed
```

Esempi:

```text
--mode auto

source=auto
width=unset
height=unset
refresh=unset
refresh_fixed=false
```

```text
--mode 1920x1200

source=cli
width=1920
height=1200
refresh=unset
refresh_fixed=false
```

```text
--mode 1920x1200@60

source=cli
width=1920
height=1200
refresh=60
refresh_fixed=true
```

L'implementazione concreta può usare semplici variabili Bash invece di una struttura formale, purché il comportamento sia equivalente.

---

# 18. Logging

Aggiungere log diagnostici senza modificare il formato degli eventi esistenti.

Caso AUTO:

```text
MODE_SOURCE=auto
```

Caso fixed resolution:

```text
MODE_SOURCE=cli
CLI_MODE=1920x1200
TARGET_MODE=1920x1200@<resolved-refresh>
```

Caso fixed resolution + refresh:

```text
MODE_SOURCE=cli
CLI_MODE=1920x1200@60
TARGET_MODE=1920x1200@60
```

Caso fallback:

```text
MODE_SOURCE=fallback
TARGET_MODE=1920x1200@60
```

Il log deve rendere immediatamente distinguibile:

```text
client dynamic
CLI fixed
global config
fallback
```

---

# 19. Persistenza nello stato

Lo stato del run deve registrare il target effettivamente utilizzato.

Aggiungere, se non già presenti:

```text
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
TARGET_SOURCE
TARGET_MODE_SPEC
```

Esempio:

```text
PHASE=STREAMING
TARGET_WIDTH=1920
TARGET_HEIGHT=1200
TARGET_REFRESH=60
TARGET_SOURCE=cli
TARGET_MODE_SPEC=1920x1200@60
```

Questo è utile per:

* recovery;
* logging;
* diagnosi;
* verifica di eventuali stale state.

---

# 20. Cleanup

Il cleanup deve rimanere indipendente dalla sorgente del target.

Non deve importare se il target era:

```text
auto
cli
config
fallback
```

Il restore deve sempre tornare alla modalità locale precedente.

Nel tuo ambiente il target locale noto è:

```text
3440x1440@165
```

ma il cleanup deve continuare a utilizzare il meccanismo di restore già esistente, senza trasformare il valore client in modalità permanente.

---

# 21. Xwayland #1

La modifica deve essere propagata al meccanismo già implementato per Xwayland #1.

Il valore deve sempre provenire da:

```text
TARGET_WIDTH
TARGET_HEIGHT
```

e non direttamente dal parser CLI.

Esempio:

```text
--mode 1920x1080@60
```

deve produrre:

```text
Gamescope:
1920x1080@60

Xwayland #1:
1920x1080
```

La sincronizzazione tramite `GAMESCOPE_XWAYLAND_MODE_CONTROL` deve rimanere invariata nel meccanismo e cambiare solamente il valore runtime usato dal target. Il sorgente Gamescope utilizza il `server_idx` per applicare la modalità al server Xwayland specificato.

---

# 22. Ordinamento

Il lifecycle deve rimanere:

```text
Steam Link detection
        ↓
resolve mode source
        ↓
resolve TARGET_*
        ↓
prepare modes.cfg
        ↓
Gamescope output target
        ↓
verify output
        ↓
Xwayland #1 synchronization
        ↓
verify Xwayland #1
        ↓
GAME_LAUNCH
```

Il gioco non deve mai essere avviato prima che:

```text
TARGET_WIDTH/TARGET_HEIGHT
```

siano definitivi.

---

# 23. Nessuna modifica dinamica durante lo stream

Una volta che:

```text
GAME_LAUNCH
```

è stato eseguito, il target deve essere immutabile.

Per una sessione:

```text
--mode 1920x1200@60
```

non devono essere applicati nuovi client hint per trasformarlo in:

```text
1280x800
```

o:

```text
1920x1080
```

durante lo stesso stream.

Il client hint può essere utilizzato solamente quando la modalità AUTO è selezionata.

---

# 24. Precedenza in dettaglio

## Caso A

```text
nessun --mode
STREAM_MODE=auto
```

Risultato:

```text
client dynamic
```

## Caso B

```text
--mode auto
STREAM_MODE=fixed
```

Risultato:

```text
client dynamic
```

Il CLI override vince.

## Caso C

```text
--mode 1920x1080
STREAM_MODE=auto
```

Risultato:

```text
1920x1080
```

## Caso D

```text
--mode 1920x1080@60
STREAM_MODE=auto
```

Risultato:

```text
1920x1080@60
```

## Caso E

```text
nessun --mode
STREAM_MODE=fixed
```

Risultato:

```text
STREAM_WIDTH/HEIGHT/REFRESH
```

## Caso F

```text
nessun --mode
nessuna configurazione fixed
```

Risultato:

```text
AUTO
```

---

# 25. Compatibilità Desktop Mode

Il parser CLI non deve rendere obbligatorio Gamescope.

Quindi:

```text
Desktop Mode
    ↓
wrapper
    ↓
parse --mode
    ↓
Steam Link non attivo
    ↓
exec game
```

La Launch Option:

```text
steam-link-display-adapter --mode 1920x1200@60 %command%
```

deve comunque permettere il normale avvio del gioco locale.

L'override deve essere utilizzato solamente quando la pipeline Steam Link viene effettivamente attivata.

---

# 26. Compatibilità Gaming Mode locale

Stessa regola:

```text
Gaming Mode
Steam Link OFF
    ↓
nessuna display preparation
    ↓
exec game
```

Il parametro CLI non deve causare:

* switch di risoluzione;
* chiamate Gamescope non necessarie;
* sleep del monitor;
* modifica modes.cfg.

---

# 27. Fail-closed

La regola deve rimanere:

```text
Steam Link OFF
→ bypass

Steam Link ON
→ target non valido
→ fail-closed
```

Esempio:

```text
Steam Link ON
--mode 2560x1600@120
```

ma il mode non è disponibile:

```text
NON avviare il gioco
```

Non eseguire un fallback silenzioso a:

```text
1920x1200
```

quando l'utente ha esplicitamente richiesto un mode fixed.

---

# 28. Fallback

Il fallback deve applicarsi solo quando non esiste un override CLI valido e non è possibile ottenere un target AUTO valido.

Esempio:

```text
AUTO
   ↓
client hint assente/invalido
   ↓
fallback esistente
   ↓
1920x1200@60
```

Non deve invece accadere:

```text
--mode 1920x1200@120
   ↓
mode assente
   ↓
1920x1200@60
```

perché in questo caso il parametro è esplicito.

---

# 29. Help

Aggiungere:

```text
--help
```

con una descrizione minima:

```text
Usage:
  steam-link-display-adapter [OPTIONS] %command%

Options:
  --mode auto
      Use dynamic resolution based on the Steam Link client.

  --mode WxH
      Force resolution and choose a compatible refresh automatically.

  --mode WxH@FPS
      Force resolution and refresh.

Examples:
  steam-link-display-adapter --mode auto %command%
  steam-link-display-adapter --mode 1920x1200 %command%
  steam-link-display-adapter --mode 1920x1200@60 %command%
```

L'help non deve modificare nessuno stato.

---

# 30. Test del parser

Aggiungere test per:

```text
--mode auto
```

```text
--mode 1920x1200
```

```text
--mode 1920x1200@60
```

```text
--mode 2560x1440@120
```

Verificare:

```text
width
height
refresh
refresh_fixed
source
```

---

# 31. Test di argv preservation

Input:

```text
--mode 1920x1200@60
/usr/bin/game
--arg1
foo
--arg2
bar
```

Output atteso:

```text
TARGET_MODE=1920x1200@60
GAME_ARGV=(
    /usr/bin/game
    --arg1
    foo
    --arg2
    bar
)
```

Nessun parametro CLI del wrapper deve arrivare al gioco.

---

# 32. Test di precedenza

Test obbligatori:

```text
CLI auto + config fixed
→ AUTO
```

```text
CLI fixed + config auto
→ CLI fixed
```

```text
nessun CLI + config fixed
→ config fixed
```

```text
nessun CLI + config auto
→ AUTO
```

---

# 33. Test mode resolution-only

Caso:

```text
--mode 1920x1200
```

Host:

```text
1920x1200@60
1920x1200@90
```

Risultato:

```text
width=1920
height=1200
refresh=resolved
```

Il test deve verificare che il parser non imposti artificialmente:

```text
refresh=60
```

solo perché il fallback globale è 60.

---

# 34. Test fixed refresh

Caso:

```text
--mode 1920x1200@60
```

Host:

```text
1920x1200@60
1920x1200@90
```

Risultato:

```text
1920x1200@60
```

---

# 35. Test fixed refresh unavailable

Caso:

```text
--mode 1920x1200@75
```

Host:

```text
1920x1200@60
1920x1200@90
```

Risultato:

```text
TARGET_MODE_UNAVAILABLE
GAME_LAUNCH = false
```

Non effettuare una sostituzione automatica con 60 o 90.

---

# 36. Test dynamic mode

Caso:

```text
--mode auto
```

Client:

```text
Maximum capture: 1920x1200 60 FPS
```

Risultato:

```text
TARGET_WIDTH=1920
TARGET_HEIGHT=1200
```

Il comportamento deve essere uguale a quello già funzionante nella branch.

---

# 37. Test client diversi

Verificare almeno:

```text
Client A:
1920x1200

Client B:
1280x800

Client C:
1920x1080
```

con:

```text
--mode auto
```

Ogni sessione deve risolvere un target indipendente.

Successivamente verificare:

```text
--mode 1920x1200@60
```

con tutti e tre i client.

In questo caso il target deve rimanere fixed e non cambiare in base al client.

---

# 38. Test prima connessione

Il supporto alle Launch Options non deve reintrodurre il problema della prima connessione.

La sequenza deve continuare a funzionare:

```text
prima connessione
    ↓
steam-streaming-playback
    ↓
client detection
    ↓
CLI/config/auto resolution
    ↓
output target
    ↓
Xwayland #1 target
    ↓
GAME
```

Non introdurre dipendenza da marker storici.

---

# 39. Test recovery

Eseguire:

```text
--mode 1920x1200@60
```

interrompere il wrapper durante `PREPARING`.

Alla sessione successiva:

```text
stale-state recovery
```

deve ripristinare il sistema locale.

La presenza del CLI override non deve contaminare il target del restore.

---

# 40. Test anti-regressione streaming

Scenario:

```text
Steam Link ON
--mode 1920x1200@60
```

Verificare:

```text
Output:
1920x1200@60

Xwayland #1:
1920x1200

Steam capture:
1920x1200
```

Questo deve continuare a evitare il mismatch geometrico già corretto dal progetto.

---

# 41. Test anti-regressione gaming locale

## Desktop Mode

```text
steam-link-display-adapter --mode 1920x1200@60 %command%
```

Risultato:

```text
gioco avviato normalmente
display invariato
```

## Gaming Mode

Stessa Launch Option.

Risultato:

```text
gioco locale
display invariato
```

---

# 42. Test CLI multipli

Gestire in modo deterministico il caso:

```text
--mode 1920x1200 --mode 1280x800 %command%
```

Il comportamento deve essere definito e non ambiguo.

Preferenza consigliata:

```text
seconda definizione → errore
```

per evitare configurazioni accidentalmente contraddittorie.

Quindi:

```text
duplicate --mode
→ invalid invocation
```

senza modifiche al display.

---

# 43. Test argomenti sconosciuti

Gli argomenti sconosciuti prima del comando del gioco devono produrre un errore chiaro.

Esempio:

```text
--foo bar %command%
```

risultato:

```text
unknown wrapper option
```

senza modifiche al sistema.

Gli argomenti del gioco dopo il confine del game command devono invece essere lasciati intatti.

---

# 44. Test di quoting

Verificare che il parser funzioni con:

```text
--mode '1920x1200@60'
```

e che non alteri:

```text
GAME_ARGV
```

Il parametro `--mode` può essere trattato come singolo argv indipendentemente dal fatto che Steam lo presenti quotato.

---

# 45. Documentazione

Aggiornare:

```text
README
config example
usage/help
```

con una sezione dedicata:

```text
Per-game resolution override
```

Esempi:

```text
Default / automatic:
steam-link-display-adapter %command%

Force dynamic:
steam-link-display-adapter --mode auto %command%

Force resolution:
steam-link-display-adapter --mode 1920x1200 %command%

Force resolution + refresh:
steam-link-display-adapter --mode 1920x1200@60 %command%
```

Spiegare chiaramente che:

```text
--mode 1920x1200
```

blocca la geometria ma non necessariamente il refresh.

Mentre:

```text
--mode 1920x1200@60
```

blocca entrambi.

---

# 46. Vincoli di implementazione

Non:

* duplicare il mode resolver;
* duplicare il rilevamento Steam Link;
* duplicare il codice di sincronizzazione Xwayland;
* modificare il lifecycle del watcher;
* modificare il comportamento della prima connessione;
* modificare il cleanup;
* modificare la gestione stale-state;
* rendere il parametro CLI obbligatorio;
* alterare la modalità locale del monitor;
* modificare permanentemente `modes.cfg`;
* inoltrare `--mode` al gioco.

La modifica deve essere localizzata principalmente nel layer di input/configurazione del target.

---

# 47. Architettura finale

L'architettura desiderata è:

```text
                   Steam Launch Options
                           │
                           ▼
                    wrapper parser
                           │
                    --mode presente?
                     /           \
                   YES             NO
                    │               │
                    ▼               ▼
                 CLI source     config source
                    │               │
                    └───────┬───────┘
                            │
                     AUTO selected?
                       /         \
                     YES          NO
                      │            │
                      ▼            ▼
               client resolver   fixed target
                      │            │
                      └─────┬──────┘
                            ▼
                         TARGET_*
                            │
                            ▼
                     Gamescope output
                            │
                            ▼
                    Xwayland #1 sync
                            │
                            ▼
                        GAME LAUNCH
                            │
                            ▼
                         STREAM
                            │
                            ▼
                          RESTORE
```

---

# 48. Definition of Done

La funzionalità è completa quando sono vere tutte le seguenti condizioni:

```text
[✓] --mode auto funzionante

[✓] --mode WxH funzionante

[✓] --mode WxH@FPS funzionante

[✓] AUTO rimane il comportamento predefinito

[✓] CLI override ha precedenza sulla configurazione globale

[✓] WxH forza solo la geometria

[✓] WxH@FPS forza geometria + refresh

[✓] refresh fixed non viene sostituito silenziosamente

[✓] mode inesistente → fail-closed durante streaming

[✓] --mode non viene passato al gioco

[✓] game argv preservati integralmente

[✓] Desktop Mode non viene alterato

[✓] Gaming Mode locale non viene alterato

[✓] prima connessione non viene alterata

[✓] dynamic client resolution esistente continua a funzionare

[✓] Xwayland #1 riceve il target corretto

[✓] cleanup invariato

[✓] stale-state recovery invariato

[✓] target runtime registrato nello state

[✓] logging della source del target

[✓] test parser

[✓] test precedence

[✓] test fixed resolution

[✓] test fixed refresh

[✓] test unavailable mode

[✓] test dynamic mode

[✓] test local gaming

[✓] test streaming
```

---

# 49. Criterio finale

Il comportamento finale deve essere completamente deterministico:

```text
NO CLI
    ↓
AUTO / CONFIG
```

```text
--mode auto
    ↓
AUTO
```

```text
--mode 1920x1200
    ↓
1920x1200 + refresh risolto
```

```text
--mode 1920x1200@60
    ↓
1920x1200@60
```

La modalità scelta deve diventare un semplice:

```text
TARGET_*
```

per la pipeline già esistente.

Il principio fondamentale è:

> **Le Launch Options devono controllare la scelta del target, non il lifecycle della sessione Steam Link.**

Il rilevamento dello streaming, la preparazione di Gamescope, la sincronizzazione di Xwayland #1, il launch del gioco, il cleanup e il restore devono continuare a funzionare esattamente come nella versione attuale.
