# Analisi funzionale — Rimozione delle modalità CLI `--mode`

## 1. Obiettivo

Modificare il comportamento della CLI di `steam-link-display-adapter` in modo che esista una sola Launch Option pubblica:

```text
steam-link-display-adapter %command%
```

Devono essere rimosse esclusivamente le due modalità CLI attualmente disponibili:

```text
steam-link-display-adapter --mode auto %command%
steam-link-display-adapter --mode WxH %command%
```

La modifica deve essere una **semplificazione dell'interfaccia utente**, non una modifica al motore di streaming.

---

# 2. Motivazione

Le modalità CLI:

```text
--mode auto
--mode WxH
```

non offrono un reale vantaggio operativo perché la risoluzione desiderata del client può essere già determinata/configurata attraverso le impostazioni di Steam Remote Play / Steam Link.

La CLI deve quindi esporre un'unica modalità:

```text
steam-link-display-adapter %command%
```

che rappresenta il comportamento standard e completo del progetto.

Questo elimina configurazioni duplicate e riduce il numero di decisioni che l'utente deve prendere.

---

# 3. Comportamento pubblico desiderato

La CLI deve supportare esclusivamente:

```text
steam-link-display-adapter %command%
```

Esempi:

```text
steam-link-display-adapter %command%
```

```text
steam-link-display-adapter /path/to/game %arg1 %arg2
```

Il wrapper deve continuare a consumare il comando del gioco e inoltrarlo invariato.

---

# 4. Comportamenti da eliminare

Devono essere rimossi dalla CLI:

```text
--mode auto
```

e:

```text
--mode WxH
```

Di conseguenza non devono più essere supportati:

```text
steam-link-display-adapter --mode auto %command%

steam-link-display-adapter --mode 1920x1200 %command%

steam-link-display-adapter --mode 1920x1080 %command%

steam-link-display-adapter --mode=1920x1200 %command%
```

Il parametro `--mode` non deve più avere alcuna semantica nell'interfaccia pubblica.

---

# 5. Principio fondamentale

La rimozione della modalità CLI **NON deve rimuovere la modalità dinamica interna**.

Il comportamento corretto deve diventare:

```text
CLI
 │
 └── nessun override
        ↓
GLOBAL/DEFAULT BEHAVIOUR
        ↓
client hint
        ↓
resolver
        ↓
host-compatible target
```

In altre parole:

> L'utente non sceglie più il target dalla Launch Option; il sistema utilizza automaticamente il comportamento dinamico già esistente.

---

# 6. Non rimuovere il resolver

Il modulo:

```text
lib/resolution/resolver.sh
```

deve rimanere.

La funzione:

```text
resolve_target_mode
```

deve rimanere invariata nel comportamento.

Deve continuare a ricevere:

```text
client width
client height
client FPS
```

e confrontarli con:

```text
host advertised modes
```

per determinare:

```text
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
```

La feature riguarda la CLI, non la resolution engine.

---

# 7. Nuovo flusso di risoluzione

Il percorso standard deve essere unico:

```text
Steam Link detection
        ↓
Host profile discovery
        ↓
Client capture hint
        ↓
Dynamic resolver
        ↓
TARGET_*
        ↓
Gamescope mode
        ↓
Xwayland #1
        ↓
Game
```

Non devono più esistere biforcazioni del tipo:

```text
CLI auto
CLI fixed
dynamic
```

dal punto di vista dell'interfaccia pubblica.

---

# 8. Stato interno della configurazione

Le variabili esclusivamente legate al CLI override devono essere rimosse dal percorso runtime:

```text
MODE_SOURCE
MODE_SPEC
CLI_WIDTH
CLI_HEIGHT
```

se non sono utilizzate da altri meccanismi dopo la rimozione della CLI.

Allo stesso modo deve essere eliminata la logica dedicata a:

```text
resolve_cli_target
```

qualora non abbia più alcun chiamante.

Non deve però essere rimosso alcun valore `TARGET_*` utilizzato dal resolver dinamico.

Devono continuare a esistere, ad esempio:

```text
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
TARGET_FPS
TARGET_SOURCE
TARGET_MODE_SPEC
```

se necessari al workflow corrente.

---

# 9. Nuova semantica di `TARGET_SOURCE`

Dopo la rimozione della CLI non deve più esistere:

```text
source=cli
```

nel percorso normale.

Le sorgenti devono rimanere quelle effettivamente supportate dal sistema, ad esempio:

```text
source=steam_capture_hint
source=host_original
source=fixed
source=fallback
```

in base al comportamento già presente.

Non cambiare la semantica di tali sorgenti.

---

# 10. `STREAM_MODE`

La variabile:

```text
STREAM_MODE
```

deve essere trattata separatamente dalla CLI.

Questa analisi riguarda la **rimozione delle modalità CLI**, non la rimozione automatica della configurazione interna.

Pertanto:

```text
STREAM_MODE=auto
```

deve continuare a produrre il comportamento dinamico.

Anche:

```text
STREAM_MODE=fixed
```

deve essere mantenuto, salvo una successiva decisione separata di rimuovere completamente il fixed mode dalla configurazione.

Questo evita di trasformare una semplificazione CLI in una modifica di configurazione con possibili regressioni.

---

# 11. Comportamento di default

Il comando:

```text
steam-link-display-adapter %command%
```

deve essere equivalente al comportamento oggi ottenuto senza specificare `--mode`.

Questa deve diventare la **sola modalità documentata e supportata**.

Il principio deve essere:

```text
No CLI override
    ↓
use standard project behaviour
```

---

# 12. Parser CLI

Il parser in:

```text
lib/core/cli.sh
```

deve essere semplificato.

Non deve più riconoscere:

```text
--mode
--mode=...
```

Il wrapper deve semplicemente individuare il comando del gioco e preservare gli argomenti.

L'unica eventuale opzione pubblica da mantenere è:

```text
--help
```

se si desidera conservare il meccanismo di help.

La Launch Option documentata rimane comunque:

```text
steam-link-display-adapter %command%
```

---

# 13. Gestione di `--mode`

Ogni utilizzo di:

```text
--mode
```

deve essere considerato un parametro non supportato.

Esempio:

```text
steam-link-display-adapter --mode auto %command%
```

deve terminare con errore.

Esempio:

```text
steam-link-display-adapter --mode 1920x1200 %command%
```

deve terminare con errore.

Esempio:

```text
steam-link-display-adapter --mode=1920x1200 %command%
```

deve terminare con errore.

---

# 14. Fail-fast

Un parametro CLI non supportato deve essere rilevato prima di qualsiasi mutazione.

Devono essere soddisfatte queste condizioni:

```text
invalid/unsupported CLI
        ↓
exit non-zero
        ↓
NO Steam detection pipeline mutation
NO modes.cfg modification
NO Xwayland modification
NO screen sleep
NO game launch
```

Questo mantiene il principio fail-closed già presente nel progetto.

---

# 15. `--help`

L'help deve essere aggiornato.

Non deve più mostrare:

```text
--mode auto
--mode WxH
```

Deve invece mostrare una sintassi minimale, ad esempio:

```text
Usage:
  steam-link-display-adapter %command%
```

Se viene mantenuto `--help`, il suo comportamento deve rimanere read-only e non modificare lo stato.

---

# 16. Rimozione delle variabili CLI

Devono essere rimossi, ove non più utilizzati:

```text
MODE_SOURCE
MODE_SPEC
CLI_WIDTH
CLI_HEIGHT
GAME_ARGS
```

Attenzione:

`GAME_ARGS` non deve essere rimosso se rimane necessario al normale forwarding del comando del gioco.

La rimozione riguarda soltanto le variabili specifiche dell'override `--mode`.

---

# 17. Rimozione di `resolve_cli_target`

La funzione:

```text
resolve_cli_target
```

non deve più essere utilizzata.

Poiché non esiste più un target CLI:

```text
resolve_stream_target
```

deve semplificarsi e seguire direttamente il comportamento standard esistente.

Concettualmente:

```text
resolve_stream_target()
        ↓
standard auto/fallback/fixed behaviour
```

senza:

```text
if MODE_SOURCE == cli
```

e senza:

```text
CLI_WIDTH
CLI_HEIGHT
CLI_MODE
```

---

# 18. Rimozione della precedenza CLI

Deve essere eliminata la precedenza:

```text
CLI
  >
global config
  >
auto
```

Non esistendo più una CLI override, la catena diventa semplicemente quella già prevista internamente:

```text
global configuration
        ↓
standard dynamic behaviour
```

Nel caso della configurazione standard:

```text
STREAM_MODE=auto
```

il client hint determina il target.

---

# 19. Dynamic resolution invariata

Questo comportamento deve rimanere esattamente disponibile:

```text
Client A
1920x1200
    ↓
target compatibile

Client B
1920x1080
    ↓
target compatibile

Client C
1280x800
    ↓
target compatibile
```

Il target viene quindi ancora calcolato separatamente per ogni sessione.

Non introdurre una risoluzione fissa al posto della CLI.

---

# 20. Steam settings come unica fonte utente

La semplificazione deve rendere evidente questa separazione:

```text
Steam settings
      ↓
client capture capabilities
      ↓
adapter
      ↓
automatic host adaptation
```

La Launch Option serve unicamente ad attivare il wrapper:

```text
steam-link-display-adapter %command%
```

e non deve più essere utilizzata per descrivere il display target.

---

# 21. Host-agnostic behavior

Questa modifica deve essere compatibile con il lavoro di host-agnostic display già presente nel repository.

Non reintrodurre:

```text
3440x1440
1920x1200
DP-3
165
```

come conseguenza della rimozione della CLI.

Il target deve continuare a dipendere da:

```text
client capabilities
+
host capabilities
```

e lo stato originale dell'host deve continuare a essere determinato a runtime.

---

# 22. Xwayland #1

Non modificare la sincronizzazione Xwayland #1.

Il flusso deve continuare a essere:

```text
TARGET_WIDTH/HEIGHT
        ↓
GAMESCOPE_XWAYLAND_MODE_CONTROL
        ↓
Xwayland #1
        ↓
verify
        ↓
GAME_LAUNCH
```

L'unico cambiamento è l'origine del target:

```text
prima:
CLI oppure dynamic

dopo:
standard dynamic/fixed configuration
```

---

# 23. Cleanup

Il cleanup deve rimanere invariato.

Dopo l'uscita del gioco devono essere eseguiti gli stessi passaggi:

```text
wake screen
restore modes.cfg
restore Gamescope mode
restore Xwayland #1
disable dynamic modes
clear state
```

Non introdurre alcuna modifica alla sequenza di cleanup.

---

# 24. Stale-state recovery

La stale-state recovery deve rimanere completamente invariata.

In particolare, non introdurre:

```text
CLI target
```

nello state recuperato.

La recovery deve continuare a utilizzare il profilo originale dell'host e gli altri dati già persistiti.

---

# 25. State file

I campi strettamente legati alla CLI devono essere rimossi solo se non hanno più valore diagnostico.

Non rimuovere:

```text
CLIENT_WIDTH
CLIENT_HEIGHT
CLIENT_FPS
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
TARGET_FPS
TARGET_SOURCE
TARGET_MODE_SPEC
```

se utilizzati per tracking/recovery/logging.

Un campo come:

```text
TARGET_MODE_SPEC
```

può continuare a essere utile per indicare:

```text
auto
fallback
fixed
```

anche in assenza di una CLI.

---

# 26. Logging

Eliminare i log specifici della CLI:

```text
MODE_SOURCE=cli
CLI_MODE=...
CLI_TARGET_MODE
TARGET_MODE_UNAVAILABLE
```

quando questi sono esclusivamente legati al parametro `--mode`.

Mantenere invece tutti i log relativi alla risoluzione standard:

```text
CLIENT_HINT
TARGET_MODE_RESOLVED
OUTPUT_TARGET_REACHED
XWAYLAND1_SYNC_REQUESTED
XWAYLAND1_SYNC_CONFIRMED
GAME_LAUNCH
```

---

# 27. Test CLI da rimuovere

Devono essere rimossi o trasformati i test che verificano esclusivamente:

```text
--mode auto
--mode WxH
--mode=WxH
duplicate --mode
CLI precedence
CLI fixed
CLI across hosts
CLI first connection
CLI argv handling
```

Questi test non rappresentano più una funzionalità supportata.

Non devono però essere semplicemente cancellati tutti i test senza sostituzione.

Bisogna preservare le proprietà che quei test proteggevano.

---

# 28. Test da aggiungere in sostituzione

Per evitare regressioni, verificare esplicitamente:

```text
steam-link-display-adapter %command%
```

come unico percorso.

Devono essere coperti almeno:

```text
default dynamic behaviour
```

```text
Steam Link detection
```

```text
first connection
```

```text
dynamic resolution
```

```text
host-agnostic behaviour
```

```text
Xwayland #1 synchronization
```

```text
cleanup
```

```text
stale-state recovery
```

```text
Desktop Mode bypass
```

```text
game argv preservation
```

---

# 29. Test di regressione CLI

Aggiungere test che dimostrino esplicitamente che i vecchi parametri non vengono più accettati.

Esempi:

```text
--mode auto
→ FAIL
```

```text
--mode 1920x1200
→ FAIL
```

```text
--mode=1920x1200
→ FAIL
```

e:

```text
no display mutation
no screen sleep
no GAME_LAUNCH
```

quando vengono utilizzati.

---

# 30. Test argv

Il normale percorso:

```text
steam-link-display-adapter %command%
```

deve continuare a passare gli argomenti del gioco inalterati.

Esempio:

```text
game
--arg1
foo
--arg2
bar
```

deve arrivare al gioco esattamente nello stesso ordine.

Questo test è particolarmente importante perché il parser viene semplificato.

---

# 31. Test `--help`

Verificare:

```text
--help
```

se mantenuto.

L'output non deve più contenere:

```text
--mode auto
--mode WxH
```

e deve mostrare solamente la sintassi pubblica corrente.

---

# 32. Documentazione

Aggiornare:

```text
README.md
```

e ogni documento che descrive `--mode`.

In particolare:

```text
docs/analysis/ANALISI-CLI-MODE.md
```

deve essere considerato superato dalla nuova specifica.

Non deve rimanere nel README una documentazione che suggerisce l'utilizzo di:

```text
--mode auto
--mode 1920x1200
```

---

# 33. README

La sezione relativa alle Steam Launch Options deve diventare estremamente semplice:

```text
Steam → Game → Properties → Launch Options

steam-link-display-adapter %command%
```

Non devono essere documentate varianti CLI del tipo:

```text
--mode ...
```

---

# 34. Configurazione

Il file:

```text
config/steam-link-display-adapter.conf.example
```

non deve introdurre nuovamente una corrispondenza tra CLI e configurazione.

Deve rimanere valida la configurazione interna già esistente.

La semplificazione riguarda la superficie CLI.

---

# 35. Comportamento normale senza Steam Link

Deve rimanere invariato:

```text
steam-link-display-adapter %command%
        ↓
nessuna sessione Steam Link
        ↓
bypass
        ↓
game launch diretto
```

Non deve essere introdotto alcun nuovo comportamento.

---

# 36. Desktop Mode

In Desktop Mode:

```text
steam-link-display-adapter %command%
```

deve continuare a bypassare la pipeline quando non esiste una Gamescope session applicabile.

Nessuna regressione del comportamento immediato.

---

# 37. First connection

La rimozione della CLI non deve avere alcun impatto sulla detection event-driven.

Deve continuare a funzionare:

```text
game launch
    ↓
Steam Link session appears
    ↓
pactl subscribe
    ↓
stream confirmed
    ↓
display pipeline
```

senza richiedere un precedente stream.

---

# 38. Dynamic client resolution

Deve rimanere invariata la possibilità di supportare client differenti consecutivamente.

Esempio:

```text
session 1
1920x1200
    ↓
target A

session 2
1920x1080
    ↓
target B

session 3
1280x800
    ↓
target C
```

La rimozione della CLI non deve trasformare il target in una costante.

---

# 39. Regression guard principale

Il test più importante della modifica deve essere:

```text
BEFORE
steam-link-display-adapter %command%
→ comportamento dinamico corretto

AFTER
steam-link-display-adapter %command%
→ stesso comportamento dinamico corretto
```

La differenza deve essere soltanto:

```text
--mode non più supportato
```

---

# 40. Modifiche consentite

L'agent può modificare:

```text
CLI parser
help text
CLI-specific runtime variables
CLI-specific resolver path
CLI logging
CLI tests
README
CLI documentation
```

e qualsiasi riferimento direttamente legato a `--mode`.

---

# 41. Modifiche fuori scope

Non modificare:

```text
Steam Link detection
```

```text
PipeWire detection
```

```text
client hint parsing
```

```text
dynamic resolver
```

```text
host display discovery
```

```text
host mode discovery
```

```text
Gamescope mode switching
```

```text
Xwayland synchronization
```

```text
state machine
```

```text
cleanup
```

```text
stale recovery
```

```text
screen sleep/wake
```

```text
Steam/Proton/game launch semantics
```

Questa è una semplificazione della superficie di comando, non una nuova revisione dell'architettura runtime.

---

# 42. Definition of Done

La modifica è completata quando:

```text
[✓] unica Launch Option documentata:
    steam-link-display-adapter %command%

[✓] --mode auto non supportato

[✓] --mode WxH non supportato

[✓] --mode=WxH non supportato

[✓] parser CLI semplificato

[✓] nessun percorso runtime source=cli

[✓] nessuna dipendenza da CLI_WIDTH/HEIGHT

[✓] nessuna dipendenza da resolve_cli_target

[✓] dynamic resolution invariata

[✓] client hint invariato

[✓] host-agnostic behaviour invariato

[✓] Xwayland #1 invariato

[✓] first connection invariata

[✓] Steam Link detection invariata

[✓] Desktop Mode bypass invariato

[✓] cleanup invariato

[✓] stale-state recovery invariata

[✓] game argv preservation invariato

[✓] --help aggiornato

[✓] README aggiornato

[✓] documentazione CLI aggiornata

[✓] test CLI obsolete rimossi/sostituiti

[✓] test regressivi completi PASS
```

---

# 43. Criterio finale

Il progetto deve avere una sola superficie d'utilizzo pubblica:

```text
steam-link-display-adapter %command%
```

e il comportamento interno deve essere:

```text
          Steam Link
               │
               ▼
        Client capabilities
               │
               ▼
         Dynamic resolver
               │
               ▼
        Host capabilities
               │
               ▼
        Target display mode
               │
         ┌─────┴─────┐
         ▼           ▼
     Gamescope    Xwayland #1
         │           │
         └─────┬─────┘
               ▼
          Game launch
               │
               ▼
            Cleanup
               │
               ▼
       Original host state
```

Il principio progettuale da mantenere è:

> **La Launch Option attiva l'adapter; non decide più la modalità di streaming.**

La modalità di streaming viene determinata automaticamente dal sistema sulla base del client Steam Link e delle capacità reali dell'host.
