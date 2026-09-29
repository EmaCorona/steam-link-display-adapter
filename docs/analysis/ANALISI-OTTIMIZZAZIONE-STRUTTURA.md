# Analisi funzionale — Ottimizzazione della struttura del progetto

## 1. Obiettivo

Ottimizzare ulteriormente la struttura del repository `steam-link-display-adapter` partendo dal branch `feature/project-structure-refactor`.

L'intervento deve essere **esclusivamente strutturale e organizzativo**.

Non devono essere modificati:

* comportamento runtime;
* funzionalità esistenti;
* CLI pubblica;
* parametri e loro semantica;
* configurazione utente;
* algoritmo di selezione della modalità;
* gestione DRM/Gamescope;
* gestione Xwayland;
* detection della sessione Steam Link;
* meccanismi di recovery e cleanup;
* logica dei test;
* compatibilità con l'attuale installazione, salvo i soli path interni necessari al refactor.

Il risultato deve essere un repository più leggibile, modulare e scalabile, mantenendo invariato il comportamento osservabile.

---

# 2. Stato architetturale di partenza

Il branch attuale ha già introdotto una prima separazione corretta:

```text
steam-link-display-adapter/
├── bin/
├── lib/
├── config/
├── tests/
├── docs/
├── README.md
└── install.sh
```

La separazione concettuale attuale è:

```text
bin/
    entrypoint e comandi pubblici

lib/
    implementazione interna

config/
    template/configurazione

tests/
    test e stub

docs/
    documentazione
```

Questa struttura deve essere mantenuta.

Il principale punto da ottimizzare ulteriormente è `lib/`, che contiene ancora una quantità elevata di responsabilità differenti all'interno dello stesso modulo principale.

---

# 3. Obiettivo architetturale

Portare `lib/` da un modello:

```text
lib/
└── steam-link-display-adapter-hook.sh
```

a un modello modulare nel quale ogni file rappresenti una responsabilità tecnica ben definita.

La struttura desiderata deve seguire il principio:

```text
entrypoint
    ↓
orchestrazione
    ↓
moduli specializzati
    ↓
primitive di sistema
```

Esempio concettuale:

```text
bin/
├── steam-link-display-adapter.sh
├── steam-link-display-adapter-restore.sh
└── steam-link-display-adapter-verify-environment.sh

lib/
├── core/
├── detection/
├── display/
├── xwayland/
├── resolution/
├── state/
├── system/
└── logging/
```

La suddivisione concreta deve essere determinata dal contenuto effettivo del codice, non applicata artificialmente.

---

# 4. Regola fondamentale: organizzare per responsabilità, non per funzione arbitraria

Non creare directory o file soltanto per rendere l'albero più profondo.

Ogni nuovo modulo deve avere una responsabilità riconoscibile.

Esempio corretto:

```text
lib/
├── display/
│   ├── connector.sh
│   └── mode.sh
│
├── xwayland/
│   └── mode.sh
│
├── detection/
│   ├── steam-link.sh
│   └── gamescope.sh
│
└── state/
    ├── snapshot.sh
    └── lock.sh
```

Esempio da evitare:

```text
lib/
├── helpers/
├── utils/
├── common/
├── misc/
└── stuff/
```

Non creare contenitori generici nei quali confluiscano funzioni non correlate.

---

# 5. Separazione delle responsabilità

Durante l'analisi del file monolitico, classificare ogni funzione/responsabilità in una delle seguenti aree.

## 5.1 Core / orchestration

Responsabilità:

* coordinamento del workflow;
* ordine delle operazioni;
* gestione delle precondizioni;
* gestione del risultato delle varie fasi;
* gestione del lifecycle.

Questo modulo non deve contenere direttamente dettagli implementativi di DRM, Xwayland o parsing dei log.

Concettualmente:

```text
prepare
  ↓
detect
  ↓
resolve
  ↓
apply
  ↓
verify
  ↓
run
  ↓
restore
```

---

## 5.2 Detection

Contiene esclusivamente ciò che serve a determinare lo stato dell'ambiente.

Esempi:

```text
Steam Link active?
Gamescope active?
PipeWire stream active?
connector disponibile?
Xwayland server presente?
```

Il codice di detection deve restituire informazioni utili al resto del sistema senza modificare lo stato dell'ambiente.

Principio:

```text
detect = read-only
```

salvo eventuali operazioni strettamente necessarie già previste dal comportamento attuale.

---

## 5.3 Display

Responsabilità relativa al display/DRM:

* identificazione connector;
* lettura del mode corrente;
* lettura dei mode disponibili;
* selezione/applicazione del mode;
* verifica del mode;
* gestione dello stato precedente.

Non deve conoscere i dettagli della detection Steam Link.

---

## 5.4 Xwayland

Responsabilità esclusiva della gestione dei server Xwayland.

Esempi:

```text
discover Xwayland
select server #1
read current mode
apply mode
verify mode
```

L'accesso a Xwayland deve essere incapsulato in questo modulo.

L'orchestratore dovrebbe poter ragionare in termini di:

```text
xwayland.apply_mode(...)
xwayland.verify(...)
```

senza conoscere i dettagli di `xprop`, `xrandr`, display socket o altre primitive utilizzate.

---

## 5.5 Resolution / Mode Resolver

Separare chiaramente la logica decisionale dalla logica che applica fisicamente una modalità.

Il resolver deve occuparsi di:

```text
client target
        ↓
available host modes
        ↓
compatible candidates
        ↓
selected mode
```

Mentre `display/` deve occuparsi di applicare quel mode.

Questo permette di mantenere distinta:

```text
"Quale mode devo scegliere?"
```

da:

```text
"Come imposto quel mode?"
```

È una separazione importante per testabilità e futura evoluzione.

---

## 5.6 State

Raccogliere in un modulo dedicato tutto ciò che riguarda lo stato transitorio.

Esempi:

```text
state directory
snapshot
backup
lock
stale-state
restore metadata
```

Il modulo deve offrire primitive chiare:

```text
state.create
state.save
state.load
state.is_stale
state.restore
state.cleanup
```

senza conoscere il workflow completo del progetto.

---

## 5.7 System / Environment

Raccogliere le primitive di sistema condivise.

Esempi:

```text
command detection
process lookup
filesystem checks
directory creation
permission checks
environment validation
```

Evitare però di trasformarlo in un generico `utils.sh`.

Ogni helper deve essere collocato nel modulo che ne rappresenta realmente la responsabilità.

---

## 5.8 Logging

Se nel modulo principale esistono diverse funzioni di logging/tracing, valutarne l'estrazione in un componente comune.

Il logging deve essere trasparente per i moduli:

```text
log_info
log_warn
log_error
debug
```

senza replicare meccanismi differenti nei vari file.

---

# 6. Entry point e librerie

Mantenere una distinzione rigorosa:

```text
bin/
    codice eseguibile direttamente dall'utente

lib/
    codice interno riutilizzabile
```

I file sotto `lib/` non devono essere esposti come comandi pubblici.

Gli entrypoint sotto `bin/` devono avere il minimo possibile di logica propria.

Idealmente:

```text
bin/command
    ↓
load core
    ↓
invoke orchestration
```

anziché:

```text
bin/command
    ↓
duplicazione di detection
    ↓
duplicazione di state management
    ↓
duplicazione di display logic
```

---

# 7. Gestione del caricamento dei moduli

Implementare un meccanismo coerente per il caricamento delle librerie.

Evitare riferimenti fragili del tipo:

```bash
source "../../qualcosa.sh"
```

I moduli devono essere risolti a partire dalla root/runtime path del progetto.

Definire una convenzione unica per:

```text
SCRIPT_DIR
PROJECT_ROOT
LIB_DIR
CONFIG_DIR
```

e utilizzarla ovunque.

L'obiettivo è che il codice continui a funzionare indipendentemente dalla directory dalla quale viene invocato il comando.

---

# 8. Dipendenze tra moduli

Ridurre al minimo le dipendenze circolari.

La direzione desiderata deve essere simile a:

```text
bin
 ↓
core
 ↓
domain modules
 ↓
system primitives
```

e non:

```text
A → B → C → A
```

In particolare:

* detection non deve dipendere dall'orchestrator;
* resolver non deve modificare direttamente il display;
* display non deve avviare Steam Link;
* state non deve conoscere la logica applicativa;
* moduli bassi non devono richiamare entrypoint.

---

# 9. API interna

Per ogni modulo definire un piccolo insieme di funzioni pubbliche interne.

Esempio:

```bash
display_get_current_mode
display_get_available_modes
display_apply_mode
display_verify_mode
```

e mantenere eventuali helper interni non destinati ad essere richiamati da altri moduli realmente privati.

Lo scopo è evitare che ogni file inizi a dipendere da decine di funzioni implementative di altri moduli.

---

# 10. Preservazione assoluta della compatibilità

Il refactor deve essere verificato rispetto a questi invarianti.

## CLI

Devono rimanere invariati:

```text
comandi
argomenti
flag
exit code
output significativo
```

## Configurazione

Non modificare:

```text
nomi delle variabili
default
formato
path runtime
semantica
```

salvo i riferimenti ai nuovi path interni introdotti esclusivamente dal refactor.

## Runtime

Devono rimanere identici:

```text
detection Steam Link
mode resolution
DRM switching
Xwayland synchronization
recovery
cleanup
restore
locking
```

## Tests

La suite esistente deve continuare a passare integralmente.

Non modificare i test semplicemente per adattarli alla nuova struttura, salvo aggiornare i path dove necessario.

---

# 11. Installer

Adeguare l'installer alla nuova struttura senza alterarne il comportamento funzionale.

Il layout runtime deve rimanere coerente con:

```text
~/.local/bin/
~/.local/lib/steam-link-display-adapter/
~/.config/steam-link-display-adapter/
```

Verificare inoltre la migrazione dalle versioni precedenti.

In particolare:

```text
vecchio hook in ~/.local/bin
        ↓
rimozione del file stale
```

deve essere considerata solo come eventuale compatibilità di installazione, senza rimuovere altri file utente.

---

# 12. Permessi

Applicare permessi coerenti con il ruolo del file.

Indicazione:

```text
bin/*    → executable
lib/*    → non executable
config/* → non executable
```

Per esempio:

```text
0755 → entrypoint
0644 → library/config
```

Non lasciare permessi eseguibili a moduli che devono essere caricati con `source`.

---

# 13. Test strutturali

Mantenere e, dove necessario, ampliare il test che verifica la struttura del progetto.

Deve verificare almeno:

```text
✓ entrypoint presenti
✓ library presenti
✓ config presente
✓ docs presenti
✓ test presenti
✓ nessun file interno duplicato nella root
✓ nessun vecchio hook pubblico residuo nel repository
```

Non rendere però i test eccessivamente accoppiati ai nomi di ogni singolo file interno.

Testare gli invarianti strutturali importanti, non ogni dettaglio arbitrario dell'albero.

---

# 14. Strategia di refactoring

Procedere in modo incrementale.

### Fase 1 — Inventory

Analizzare `lib/steam-link-display-adapter-hook.sh`.

Mappare:

```text
funzione
→ responsabilità
→ dipendenze
→ chiamanti
→ side effects
```

Non modificare ancora il comportamento.

### Fase 2 — Boundary identification

Definire i confini dei moduli.

Creare prima le responsabilità:

```text
detection
display
xwayland
resolution
state
system
logging
core
```

solo dove esiste realmente codice appartenente a quella responsabilità.

### Fase 3 — Extraction

Spostare le funzioni nei moduli appropriati.

Dopo ogni estrazione:

```text
syntax check
unit test
integration simulation
```

### Fase 4 — Dependency cleanup

Eliminare:

```text
duplicate helpers
duplicate constants
duplicate path resolution
duplicate environment checks
```

centralizzando solamente ciò che è realmente condiviso.

### Fase 5 — Entrypoint cleanup

Ridurre gli script in `bin/` a veri entrypoint.

### Fase 6 — Test e verifica

Eseguire l'intera suite e confrontare:

```text
exit code
logs
state transitions
runtime paths
generated files
```

con il comportamento precedente.

---

# 15. Struttura target indicativa

La struttura finale potrebbe essere simile a questa:

```text
steam-link-display-adapter/
│
├── README.md
├── install.sh
│
├── bin/
│   ├── steam-link-display-adapter.sh
│   ├── steam-link-display-adapter-restore.sh
│   └── steam-link-display-adapter-verify-environment.sh
│
├── lib/
│   ├── core/
│   │   └── workflow.sh
│   │
│   ├── detection/
│   │   ├── steam-link.sh
│   │   ├── gamescope.sh
│   │   └── environment.sh
│   │
│   ├── display/
│   │   ├── connector.sh
│   │   └── mode.sh
│   │
│   ├── resolution/
│   │   └── resolver.sh
│   │
│   ├── xwayland/
│   │   └── mode.sh
│   │
│   ├── state/
│   │   ├── state.sh
│   │   ├── snapshot.sh
│   │   └── lock.sh
│   │
│   ├── system/
│   │   └── filesystem.sh
│   │
│   └── logging/
│       └── logging.sh
│
├── config/
│   └── steam-link-display-adapter.conf.example
│
├── tests/
│   ├── run-tests.sh
│   └── stubs/
│
└── docs/
    ├── analysis/
    └── technical/
```

Questa è una **struttura target indicativa**, non un requisito rigido.

L'agent deve preferire una struttura più semplice qualora il codice reale non giustifichi ulteriori suddivisioni.

---

# 16. Cosa
