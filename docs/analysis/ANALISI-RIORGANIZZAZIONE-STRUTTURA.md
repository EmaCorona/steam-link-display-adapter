# Analisi funzionale — Riorganizzazione struttura del progetto

## 1. Obiettivo

Riorganizzare il repository:

```text
steam-link-display-adapter
```

partendo dalla branch:

```text
feature/project-structure-refactor
```

con l'obiettivo di ottenere una struttura più ordinata, manutenibile e scalabile.

La modifica deve essere **esclusivamente organizzativa**.

Non devono essere modificati:

* comportamento runtime;
* funzionalità;
* lifecycle Steam Link;
* detection;
* dynamic resolution;
* resolver dei mode;
* gestione Gamescope;
* sincronizzazione Xwayland #1;
* parsing CLI;
* cleanup;
* stale-state recovery;
* logging;
* gestione configurazione;
* comportamento Desktop/Gaming Mode;
* test funzionali.

Non deve essere effettuato alcun refactoring interno delle funzioni o della logica degli script.

---

# 2. Principio architetturale

Il repository deve essere organizzato secondo la responsabilità dei file:

```text
bin/       → entrypoint eseguibili
lib/       → componenti interni condivisi
config/    → configurazione di esempio
tests/     → test automatici e stub
docs/      → documentazione
```

La root deve contenere solamente ciò che identifica il progetto e ne costituisce il punto d'ingresso principale.

La struttura deve essere leggibile immediatamente anche da chi apre il repository per la prima volta.

---

# 3. Struttura attuale

Attualmente la root contiene insieme:

```text
ANALISI-*.md
DOCUMENTAZIONE-TECNICA.md
README.md

install.sh

steam-link-display-adapter.sh
steam-link-display-adapter-hook.sh
steam-link-display-adapter-restore.sh
steam-link-display-adapter-verify-environment.sh

steam-link-display-adapter.conf.example

tests/
```

Il problema principale non è il numero di file, ma la **mancanza di separazione per responsabilità**.

In particolare:

```text
runtime
documentation
configuration
installation
tests
```

sono tutti allo stesso livello.

---

# 4. Struttura target

La struttura desiderata è:

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
│   └── steam-link-display-adapter-hook.sh
│
├── config/
│   └── steam-link-display-adapter.conf.example
│
├── tests/
│   ├── run-tests.sh
│   └── stubs/
│       ├── gamescopectl
│       ├── journalctl
│       ├── pactl
│       ├── pw-cli
│       ├── xdpyinfo
│       └── xprop
│
└── docs/
    ├── analysis/
    │   ├── ANALISI-FUNZIONALE.md
    │   ├── ANALISI-FUNZIONALE-PRIMA-CONNESSIONE.md
    │   ├── ANALISI-RISOLUZIONE-DINAMICA.md
    │   ├── ANALISI-XWAYLAND-1.md
    │   ├── ANALISI-CLI-MODE.md
    │   └── ANALISI-RIMOZIONE-FPS-CLI.md
    │
    └── technical/
        └── DOCUMENTAZIONE-TECNICA.md
```

---

# 5. `bin/`

La directory:

```text
bin/
```

deve contenere gli script che rappresentano veri **entrypoint eseguibili**.

Devono essere spostati qui:

```text
steam-link-display-adapter.sh
steam-link-display-adapter-restore.sh
steam-link-display-adapter-verify-environment.sh
```

Responsabilità:

```text
steam-link-display-adapter.sh
```

Entry point principale utilizzato nelle Steam Launch Options.

```text
steam-link-display-adapter-restore.sh
```

Entry point per il recovery manuale.

```text
steam-link-display-adapter-verify-environment.sh
```

Entry point diagnostico read-only.

Non modificare il contenuto logico di questi script.

---

# 6. `lib/`

La directory:

```text
lib/
```

deve contenere componenti interni che non rappresentano direttamente un comando utente.

Spostare:

```text
steam-link-display-adapter-hook.sh
```

in:

```text
lib/steam-link-display-adapter-hook.sh
```

Questo file è concettualmente una **libreria di integrazione**, perché viene caricata tramite:

```text
source "$HOOK"
```

e fornisce le funzioni utilizzate dagli entrypoint.

Il fatto che attualmente sia uno script Bash completo non deve cambiare la sua classificazione architetturale.

Non deve quindi più apparire come comando installabile principale.

---

# 7. Separazione runtime tra entrypoint e libreria

Il progetto deve distinguere chiaramente:

```text
PUBLIC ENTRYPOINTS
        │
        ▼
      bin/
        │
        ▼
INTERNAL COMPONENTS
        │
        ▼
      lib/
```

Concettualmente:

```text
Steam
  │
  ▼
bin/steam-link-display-adapter.sh
  │
  └── source → lib/steam-link-display-adapter-hook.sh
```

e:

```text
bin/steam-link-display-adapter-restore.sh
  │
  └── source → lib/steam-link-display-adapter-hook.sh
```

Questo rende evidente che il hook non è una utility standalone per l'utente.

---

# 8. `config/`

Creare:

```text
config/
```

e spostarvi:

```text
steam-link-display-adapter.conf.example
```

in:

```text
config/steam-link-display-adapter.conf.example
```

La distinzione deve essere:

```text
config/
    repository defaults/example

~/.config/steam-link-display-adapter/
    configurazione runtime dell'utente
```

Il file presente nel repository rimane quindi un template, non una configurazione runtime.

---

# 9. `tests/`

La struttura attuale di test è già concettualmente corretta:

```text
tests/
├── run-tests.sh
└── stubs/
```

Deve essere mantenuta.

Non è necessario suddividere `run-tests.sh` in più file.

Questa analisi non deve introdurre un refactoring del test runner.

L'obiettivo è solamente rendere più chiara la posizione del sistema di test.

---

# 10. `tests/stubs/`

Mantenere gli stub nella directory:

```text
tests/stubs/
```

con la struttura attuale:

```text
gamescopectl
journalctl
pactl
pw-cli
xdpyinfo
xprop
```

Non è necessario creare sottodirectory come:

```text
tests/stubs/gamescope/
tests/stubs/x11/
tests/stubs/pipewire/
```

al momento.

Il numero di stub è ancora sufficientemente ridotto da rendere preferibile una struttura piatta.

Un'ulteriore suddivisione introdurrebbe complessità senza un beneficio reale.

---

# 11. `docs/`

Tutta la documentazione tecnica e progettuale deve essere eliminata dalla root e raccolta in:

```text
docs/
```

Questo permette alla root di rappresentare il progetto e non la sua storia di sviluppo.

La documentazione rimane comunque versionata e accessibile.

---

# 12. `docs/analysis/`

Le analisi funzionali già presenti devono essere raggruppate in:

```text
docs/analysis/
```

Devono essere spostati:

```text
ANALISI-FUNZIONALE.md
ANALISI-FUNZIONALE-PRIMA-CONNESSIONE.md
ANALISI-RISOLUZIONE-DINAMICA.md
ANALISI-XWAYLAND-1.md
ANALISI-CLI-MODE.md
ANALISI-RIMOZIONE-FPS-CLI.md
```

Non modificarne il contenuto.

Questi documenti rappresentano decisioni, problemi analizzati e specifiche storiche del progetto.

---

# 13. `docs/technical/`

Il documento:

```text
DOCUMENTAZIONE-TECNICA.md
```

deve essere spostato in:

```text
docs/technical/DOCUMENTAZIONE-TECNICA.md
```

La separazione permette di distinguere:

```text
docs/analysis/
    perché il sistema è stato progettato così

docs/technical/
    come funziona tecnicamente il sistema
```

---

# 14. Root minimale

Al termine del refactoring, la root dovrebbe contenere principalmente:

```text
README.md
install.sh
bin/
lib/
config/
tests/
docs/
```

Questo deve essere considerato il principio di organizzazione principale.

La root non deve diventare un deposito di:

```text
script
config
test
analisi
note tecniche
```

---

# 15. `README.md`

Il README deve rimanere nella root.

È l'unico documento che deve essere immediatamente visibile senza entrare in:

```text
docs/
```

Il README non deve essere spostato.

Può continuare a spiegare:

* scopo del progetto;
* installazione;
* uso;
* configurazione;
* Launch Options;
* diagnostica;
* test;
* struttura generale.

Non modificare il contenuto funzionale durante questo refactoring, salvo aggiornare i riferimenti ai path repository che cambiano.

---

# 16. `install.sh`

Anche:

```text
install.sh
```

deve rimanere nella root.

Motivazione:

```text
git clone
    ↓
cd steam-link-display-adapter
    ↓
./install.sh
```

è il percorso principale di installazione e mantenerlo nella root rende il progetto immediatamente utilizzabile.

L'installer deve però essere aggiornato esclusivamente per puntare ai nuovi path.

Esempio concettuale:

```text
$SCRIPT_DIR/bin/steam-link-display-adapter.sh
$SCRIPT_DIR/bin/steam-link-display-adapter-restore.sh
$SCRIPT_DIR/bin/steam-link-display-adapter-verify-environment.sh
$SCRIPT_DIR/lib/steam-link-display-adapter-hook.sh
$SCRIPT_DIR/config/steam-link-display-adapter.conf.example
```

---

# 17. Layout di installazione runtime

Il refactoring deve distinguere anche:

```text
repository structure
```

da:

```text
installed structure
```

Nel repository:

```text
bin/
lib/
config/
```

Nell'ambiente utente:

```text
~/.local/bin/
    steam-link-display-adapter
    steam-link-display-adapter-restore
    steam-link-display-adapter-verify-environment

~/.local/lib/steam-link-display-adapter/
    steam-link-display-adapter-hook.sh

~/.config/steam-link-display-adapter/
    config

~/.local/state/steam-link-display-adapter/
    state
    lock
    wrapper.log
    modes.cfg.backup
```

Questa è la separazione preferibile.

Gli strumenti realmente eseguiti dall'utente restano nel `PATH`, mentre il componente interno non viene esposto come comando pubblico.

---

# 18. Path resolution

Poiché il hook viene spostato da:

```text
bin/
```

a:

```text
lib/
```

gli entrypoint devono poterlo trovare correttamente.

Questa è l'unica modifica tecnica obbligatoria derivante dalla riorganizzazione.

Il comportamento deve essere equivalente a quello attuale.

Non introdurre nuove modalità di discovery dinamico complesse.

La relazione deve essere deterministica:

```text
repository/bin/
       │
       └── ../lib/steam-link-display-adapter-hook.sh
```

Analogamente, dopo l'installazione:

```text
~/.local/bin/
       │
       └── ../lib/steam-link-display-adapter/
```

oppure tramite un path esplicito deterministico scelto dall'installer.

L'importante è che non venga effettuato alcun cambiamento alla logica fornita dal hook.

---

# 19. Installazione del componente interno

L'installer deve continuare a installare il hook perché è necessario al runtime.

La differenza è solamente la destinazione.

Da:

```text
~/.local/bin/steam-link-display-adapter-hook.sh
```

a:

```text
~/.local/lib/steam-link-display-adapter/steam-link-display-adapter-hook.sh
```

Il hook non deve più essere trattato come public CLI.

---

# 20. Permessi

Mantenere i permessi attuali per i tre entrypoint:

```text
0755
```

Il hook interno può essere mantenuto eseguibile se ciò è compatibile con l'implementazione attuale, ma non deve essere necessario per il suo ruolo di libreria.

Il file:

```text
config/steam-link-display-adapter.conf.example
```

deve continuare a essere installato con:

```text
0644
```

---

# 21. Modifiche consentite ai file

Sono consentite esclusivamente modifiche dovute al trasferimento dei file.

Esempi:

```text
SCRIPT_DIR
HOOK
PATH del config template
PATH degli script nei test
PATH usati dall'installer
```

Queste modifiche devono essere puramente meccaniche.

Non devono modificare:

```text
if
case
while
resolver
state machine
Steam detection
mode selection
Xwayland logic
cleanup
```

---

# 22. Modifiche non consentite

Durante questo task non effettuare:

```text
refactoring delle funzioni
```

```text
rinomina delle funzioni
```

```text
splitting del wrapper
```

```text
splitting del hook
```

```text
nuova astrazione di configurazione
```

```text
nuovo parser
```

```text
nuovo resolver
```

```text
nuovo sistema di logging
```

```text
modifica della state machine
```

```text
modifica dei test funzionali
```

```text
modifica della semantica dei test
```

Il task deve rimanere un **filesystem/project layout refactor**, non un code refactor.

---

# 23. Riferimenti interni da aggiornare

Dopo gli spostamenti eseguire una ricerca globale dei riferimenti ai vecchi path:

```text
steam-link-display-adapter.sh
steam-link-display-adapter-hook.sh
steam-link-display-adapter-restore.sh
steam-link-display-adapter-verify-environment.sh
steam-link-display-adapter.conf.example
ANALISI-FUNZIONALE.md
DOCUMENTAZIONE-TECNICA.md
```

Aggiornare esclusivamente:

```text
path
link
source
installer reference
test reference
```

Il contenuto funzionale associato ai file deve rimanere invariato.

---

# 24. README path references

Nel README aggiornare i riferimenti che oggi presuppongono file nella root.

Ad esempio:

```text
steam-link-display-adapter.sh
```

deve essere inteso come:

```text
bin/steam-link-display-adapter.sh
```

e analogamente per gli altri file.

Le istruzioni utente relative al comando installato devono però continuare a utilizzare il nome pubblico:

```text
steam-link-display-adapter
```

e non il path interno del repository.

---

# 25. Documentazione cross-reference

Aggiornare eventuali riferimenti tra documenti:

```text
ANALISI-...
DOCUMENTAZIONE-TECNICA.md
README.md
```

per riflettere la nuova posizione.

Esempio:

```text
ANALISI-CLI-MODE.md
```

diventa:

```text
docs/analysis/ANALISI-CLI-MODE.md
```

Non rinominare i documenti durante questo task.

Lo scopo è soltanto spostarli.

---

# 26. Test dopo la riorganizzazione

La suite:

```text
bash tests/run-tests.sh
```

deve continuare a essere il punto di ingresso.

La suite deve continuare a:

```text
creare sandbox
stubbare i comandi
eseguire wrapper
verificare cleanup
verificare Steam detection
verificare target
verificare Xwayland
```

L'unico cambiamento necessario è la nuova localizzazione degli script.

---

# 27. Test strutturale aggiuntivo

Aggiungere solamente verifiche strutturali, non nuovi test funzionali complessi.

Devono essere verificati almeno:

```text
[✓] bin/steam-link-display-adapter.sh esiste
[✓] bin/steam-link-display-adapter-restore.sh esiste
[✓] bin/steam-link-display-adapter-verify-environment.sh esiste
[✓] lib/steam-link-display-adapter-hook.sh esiste
[✓] config/steam-link-display-adapter.conf.example esiste
[✓] docs/analysis/* esistono
[✓] docs/technical/DOCUMENTAZIONE-TECNICA.md esiste
[✓] vecchi file root non esistono
```

La presenza di questi controlli serve a impedire regressioni della struttura in futuro.

---

# 28. Verifica duplicati

Dopo lo spostamento non devono rimanere copie duplicate nella root.

Ad esempio non deve esistere contemporaneamente:

```text
steam-link-display-adapter.sh
bin/steam-link-display-adapter.sh
```

oppure:

```text
DOCUMENTAZIONE-TECNICA.md
docs/technical/DOCUMENTAZIONE-TECNICA.md
```

Il repository deve avere una sola copia autorevole di ogni file.

---

# 29. Verifica comportamento

Dopo la riorganizzazione eseguire la suite completa.

Devono rimanere invariati:

```text
exit code
log
state
modes.cfg
Steam Link detection
target resolution
refresh resolution
Xwayland geometry
screen sleep/wake
cleanup
restore
argv preservation
Desktop Mode bypass
Gaming Mode bypass
```

Il refactoring deve produrre:

```text
same input
      ↓
same output
```

L'unica differenza osservabile deve essere la nuova posizione dei file installati/repository.

---

# 30. Compatibilità con l'installazione esistente

Prestare attenzione al fatto che utenti che hanno già eseguito l'installer possono avere:

```text
~/.local/bin/steam-link-display-adapter
~/.local/bin/steam-link-display-adapter-hook.sh
```

La nuova struttura non deve rompere l'installazione.

L'installer deve essere in grado di installare il nuovo layout.

Non è richiesto in questo task un sistema complesso di migrazione automatica della vecchia installazione, a meno che sia già presente.

Se si decide di gestirla, la migrazione deve essere esclusivamente relativa ai path e non deve alterare configurazione o stato.

---

# 31. Naming

Mantenere i nomi attuali dei file.

Non è questo il momento per effettuare una nuova operazione di naming.

Il progetto ha già compiuto il passaggio a:

```text
steam-link-display-adapter
```

e questo deve essere considerato il namespace attuale.

Il refactoring deve quindi occuparsi di:

```text
location
```

e non di:

```text
naming
```

---

# 32. Gestione della documentazione storica

Le analisi precedenti non devono essere eliminate solamente perché alcune descrivono evoluzioni passate.

Sono utili per ricostruire:

```text
decisioni
problemi
misure
vincoli
correzioni
```

Devono quindi essere archiviate ordinatamente in:

```text
docs/analysis/
```

senza alterarne il contenuto.

In questo modo la root rimane pulita senza perdere la storia tecnica del progetto.

---

# 33. Struttura concettuale finale

L'organizzazione deve comunicare immediatamente questa architettura:

```text
steam-link-display-adapter
│
├── bin
│     └── comandi pubblici
│
├── lib
│     └── integrazione interna
│
├── config
│     └── template di configurazione
│
├── tests
│     └── verifica automatica
│
└── docs
      ├── analysis
      └── technical
```

Questa struttura separa chiaramente:

```text
WHAT USERS RUN
```

da:

```text
WHAT THE PROJECT USES INTERNALLY
```

e da:

```text
WHAT EXPLAINS THE PROJECT
```

---

# 34. Piano di migrazione

Procedere nel seguente ordine.

### Step 1 — Creazione directory

Creare:

```text
bin/
lib/
config/
docs/
docs/analysis/
docs/technical/
```

### Step 2 — Spostamento entrypoint

Spostare:

```text
steam-link-display-adapter.sh
steam-link-display-adapter-restore.sh
steam-link-display-adapter-verify-environment.sh
```

in:

```text
bin/
```

### Step 3 — Spostamento libreria

Spostare:

```text
steam-link-display-adapter-hook.sh
```

in:

```text
lib/
```

### Step 4 — Spostamento configurazione

Spostare:

```text
steam-link-display-adapter.conf.example
```

in:

```text
config/
```

### Step 5 — Spostamento documentazione

Spostare le analisi in:

```text
docs/analysis/
```

e:

```text
DOCUMENTAZIONE-TECNICA.md
```

in:

```text
docs/technical/
```

### Step 6 — Aggiornamento path

Aggiornare solo i path necessari in:

```text
install.sh
bin/*
tests/run-tests.sh
README.md
docs/*
```

### Step 7 — Verifica repository

Controllare che nessun vecchio file rimanga nella root.

### Step 8 — Test

Eseguire:

```text
bash tests/run-tests.sh
```

e verificare che la suite completa rimanga PASS.

---

# 35. Definition of Done

Il task è completato quando:

```text
[✓] bin/ contiene tutti gli entrypoint pubblici

[✓] lib/ contiene il hook interno

[✓] config/ contiene il template

[✓] tests/ mantiene la suite esistente

[✓] docs/analysis/ contiene tutte le analisi

[✓] docs/technical/ contiene la documentazione tecnica

[✓] README.md rimane nella root

[✓] install.sh rimane nella root

[✓] nessun file funzionale è duplicato

[✓] nessun vecchio file resta nella root

[✓] installer aggiornato ai nuovi path

[✓] wrapper trova correttamente il hook

[✓] restore trova correttamente il hook

[✓] test runner trova correttamente gli script

[✓] README e documentazione hanno path aggiornati

[✓] suite completa PASS

[✓] nessuna modifica alla logica runtime

[✓] nessuna modifica alle funzionalità

[✓] nessuna modifica al lifecycle Steam Link

[✓] nessuna modifica al resolver

[✓] nessuna modifica a Xwayland #1

[✓] nessuna modifica al cleanup/recovery
```

---

# 36. Criterio finale

Il risultato deve essere percepibile come:

```text
PROJECT REORGANIZATION
```

e non come:

```text
CODE REFACTOR
```

Il contenuto degli script deve rimanere sostanzialmente quello attuale.

L'agent deve considerare come modifiche legittime:

```text
move
path update
reference update
installer path update
documentation link update
```

e come modifiche fuori scope:

```text
logic refactor
function refactor
architecture refactor
feature change
behavior change
```

Il principio fondamentale è:

> **Cambiare dove vivono i componenti, non come funzionano.**

La struttura finale deve rendere immediatamente evidente la distinzione tra:

```text
entrypoint
internal library
configuration
tests
documentation
```

senza alterare in alcun modo il comportamento già funzionante della branch `feature/project-structure-refactor`.
