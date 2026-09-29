# Analisi funzionale — Ottimizzazione `README.md`

## 1. Obiettivo

Ottimizzare completamente il `README.md` del progetto `steam-link-display-adapter` a partire dal branch:

```text
feature/project-structure-refactor
```

L'obiettivo non è modificare codice o funzionalità, ma trasformare il README nel **punto di ingresso principale del repository**.

Il README deve essere:

* più rapido da leggere;
* più chiaro per chi scopre il progetto per la prima volta;
* più elegante e moderno;
* orientato al risultato;
* privo di dettagli implementativi non necessari;
* capace di evidenziare chiaramente i punti di forza tecnici del progetto;
* coerente con la nuova struttura `bin/`, `lib/`, `config/`, `tests/`, `docs/`.

Il documento deve soprattutto rispondere rapidamente a quattro domande:

```text
Cos'è?
Perché serve?
Come funziona?
Come si usa?
```

I dettagli tecnici devono essere rimandati alla documentazione contenuta in `docs/`.

---

# 2. Principio generale

Il README deve seguire questa gerarchia:

```text
PRODUCT
  ↓
VALUE
  ↓
FEATURES
  ↓
QUICK START
  ↓
HOW IT WORKS
  ↓
USAGE
  ↓
DIAGNOSTICS
  ↓
PROJECT STRUCTURE
  ↓
DOCUMENTATION
  ↓
LIMITATIONS
```

Non deve seguire invece il modello attuale:

```text
descrizione
→ dettagli tecnici
→ installazione
→ configurazione
→ dettagli CLI
→ struttura completa
→ dettagli interni
→ limitazioni tecniche
```

---

# 3. Header

La parte iniziale deve essere molto più compatta.

Struttura desiderata:

```markdown
# steam-link-display-adapter

> Dynamic display adaptation for Steam Remote Play on Bazzite/Game Mode.

[breve descrizione]
```

Subito dopo il titolo inserire una spiegazione in 2-3 righe:

```text
Steam Link può richiedere una risoluzione/aspect ratio differente
rispetto al display fisico dell'host.

Questo wrapper adatta temporaneamente Gamescope alla risoluzione
del client Steam Link, sincronizza Xwayland e ripristina lo stato
originale al termine della sessione.
```

Evitare una lunga introduzione descrittiva.

---

# 4. Value proposition

Inserire una sezione immediatamente successiva:

```markdown
## What it solves
```

Il concetto da comunicare è:

```text
Host display
    3440×1440 / 21:9

        ↓

Steam Link client
    1920×1200 / 16:10

        ↓

without adaptation
    wrong capture geometry

        ↓

steam-link-display-adapter

        ↓

temporary host adaptation
    1920×1200 / 16:10

        ↓

Steam capture
    matches client
```

La spiegazione deve essere comprensibile anche a chi non conosce:

* Gamescope;
* Xwayland;
* DRM;
* PipeWire.

I dettagli di implementazione devono essere lasciati ai documenti tecnici.

---

# 5. Punti di forza

Questa deve diventare una delle sezioni principali del README.

Titolo:

```markdown
## Highlights
```

Presentare i punti di forza in forma molto compatta.

### Dynamic client resolution

Il target viene determinato in base alla capacità di cattura dichiarata dal client Steam Link:

```text
Maximum capture: WxH FPS
        ↓
mode resolver
        ↓
host-compatible target
```

Il resolver valuta:

* aspect ratio;
* risoluzione;
* refresh rate;
* pixel difference;
* compatibilità con il framerate del client.

Non entrare nel dettaglio dell'algoritmo: linkare `docs/analysis/ANALISI-RISOLUZIONE-DINAMICA.md`.

---

### Race-condition handling

Evidenziare esplicitamente che il progetto non presume che la sessione Steam Link sia già pronta al momento del lancio.

Il progetto gestisce la race:

```text
launch game
    ↓
Steam Link session appears shortly after
    ↓
event-driven detection
    ↓
display preparation
```

La rilevazione utilizza un meccanismo event-driven con finestra bounded e verifica reale dello stato.

Questo è un vero punto di forza e deve essere visibile nel README.

---

### State machine

Evidenziare l'architettura del workflow:

```text
RECOVER
   ↓
DETECT
   ↓
VALIDATE
   ↓
RESOLVE
   ↓
PRECHECK
   ↓
PREPARE
   ↓
RUN
   ↓
CLEANUP
```

La state machine deve essere descritta come meccanismo che rende prevedibili:

* preparazione;
* launch;
* cleanup;
* recovery.

Non riportare nel README tutte le singole implementazioni.

---

### Xwayland synchronization

Questo è un altro punto distintivo e deve essere esplicitato.

Il display output e il server Xwayland del gioco non sono trattati come la stessa entità.

Il progetto verifica quindi:

```text
Gamescope output
       +
Xwayland #1
       ↓
same target geometry
```

Il gioco viene lanciato solo dopo la conferma dello stato corretto.

Link:

```text
docs/analysis/ANALISI-XWAYLAND-1.md
```

---

### Fail-closed design

Il progetto deve essere presentato come deliberatamente conservativo.

Esempio:

```text
target not verified
        ↓
no display sleep
no game launch
```

La priorità è evitare di lasciare il sistema in uno stato parzialmente modificato.

Questa è una caratteristica importante e merita una posizione privilegiata.

---

### Crash / stale-state recovery

Evidenziare che il progetto mantiene uno stato persistente e può effettuare recovery dopo:

* terminazione anomala;
* crash;
* interruzione del processo.

Il concetto da comunicare è:

```text
previous run interrupted
        ↓
stale state detected
        ↓
conservative recovery
        ↓
normal execution
```

Il dettaglio del formato dello state non è necessario nel README.

---

### Hardware-free testing

Evidenziare la presenza della suite:

```bash
bash tests/run-tests.sh
```

e soprattutto che i test:

```text
non richiedono:
- monitor reale;
- Gamescope reale;
- Steam reale;
- gioco reale;
```

Questo è particolarmente importante per la credibilità tecnica del repository.

---

# 6. Quick Start

La sezione di utilizzo deve arrivare molto presto.

Titolo:

```markdown
## Quick start
```

Contenuto minimale:

```bash
git clone https://github.com/EmaCorona/steam-link-display-adapter.git
cd steam-link-display-adapter
./install.sh
```

Poi:

```text
Steam → Game → Properties → Launch Options
```

e:

```text
~/.local/bin/steam-link-display-adapter %command%
```

Non inserire qui dettagli di configurazione avanzata.

---

# 7. Requisiti

Ridurre la sezione requisiti.

Separare:

### Platform

```text
Bazzite
Gaming Mode
Gamescope
Steam Remote Play / Steam Link
```

### System tools

Mostrare soltanto i componenti effettivamente richiesti:

```text
gamescopectl
xprop
xdpyinfo
journalctl
pactl / pw-cli
flock
```

Non descrivere ogni comando singolarmente.

---

# 8. How it works

Creare una sezione visiva:

```markdown
## How it works
```

Con una pipeline semplice:

```text
Steam Link client
        │
        ▼
Session detection
        │
        ▼
Client capture hint
        │
        ▼
Resolution resolver
        │
        ▼
Target display mode
        │
        ├── Gamescope output
        │
        └── Xwayland #1
                │
                ▼
             Game launch
                │
                ▼
             Steam capture
                │
                ▼
              Cleanup
                │
                ▼
          Original state
```

Questa deve sostituire gran parte della spiegazione testuale dispersa nell'attuale README.

---

# 9. Comportamento senza Steam Link

Esplicitare chiaramente il comportamento bypass:

```text
Steam Link active
    → display pipeline enabled

Steam Link inactive
    → game launched normally
```

Questo è importante perché evita l'interpretazione secondo cui il wrapper altera sempre il display.

---

# 10. Modalità disponibili

Creare una sezione compatta:

```markdown
## Modes
```

### Auto

```text
steam-link-display-adapter %command%
```

Descrizione:

```text
The target is resolved dynamically from the Steam Link client.
```

### Explicit auto

```text
steam-link-display-adapter --mode auto %command%
```

### Fixed resolution

```text
steam-link-display-adapter --mode 1920x1200 %command%
```

Spiegare soltanto:

```text
--mode WxH fixes the geometry;
the refresh rate is selected automatically.
```

Non riportare nel README tutte le regole del parser.

Link:

```text
docs/analysis/ANALISI-CLI-MODE.md
```

---

# 11. Dynamic resolution

Creare una sezione breve dedicata perché è una delle feature principali.

Esempio concettuale:

```text
Client A
1920×1200
   ↓
1920×1200 target

Client B
1920×1080
   ↓
1920×1080 target

Client C
1280×800
   ↓
best compatible host mode
```

La parte importante è evidenziare che il target viene **ricalcolato per ogni sessione**.

Dettagli su freshness, fallback e scoring devono rimanere nella documentazione tecnica.

Link:

```text
docs/analysis/ANALISI-RISOLUZIONE-DINAMICA.md
```

---

# 12. Safety model

Creare una piccola sezione:

```markdown
## Safety & recovery
```

Visualizzare:

```text
Detect
 ↓
Resolve
 ↓
Verify target
 ↓
Sync Xwayland
 ↓
Sleep display
 ↓
Launch game
```

Il punto fondamentale:

```text
No verified target
→ no display modification
→ no game launch
```

Aggiungere:

```text
Interrupted session
→ stale-state recovery
→ restore original configuration
```

Questa sezione rende immediatamente comprensibile perché l'architettura è più complessa di un semplice script di `gamescopectl`.

---

# 13. Configurazione

L'attuale sezione configurazione è troppo descrittiva.

Ridurre il README a un esempio minimale:

```bash
STREAM_MODE='auto'

STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
STREAM_FPS=60
```

e spiegare:

```text
STREAM_* values are used as fallback / fixed mode configuration.
```

Non elencare nel README ogni singola variabile.

Aggiungere link:

```text
config/steam-link-display-adapter.conf.example
```

per la configurazione completa.

---

# 14. Diagnostica

Sezione:

```markdown
## Diagnostics
```

Mostrare soltanto i comandi pubblici:

```bash
steam-link-display-adapter-verify-environment
steam-link-display-adapter-restore
```

e:

```text
Logs:
~/.local/state/steam-link-display-adapter/
```

Non descrivere singolarmente:

```text
state
lock
modes.cfg.backup
```

nel README principale, salvo una brevissima nota.

Il dettaglio deve stare nella documentazione tecnica.

---

# 15. Project structure

La nuova struttura refactorizzata è un punto di forza, ma la rappresenta
