# Analisi funzionale — Rimozione override FPS dalle Steam Launch Options

## 1. Obiettivo

Modificare l’implementazione attuale della branch:

```text
feature/dinamic-client-resolution
```

del progetto:

```text
steam-link-display-adapter
```

in modo che l’override per-gioco tramite Steam Launch Options possa specificare **solamente la risoluzione**.

La possibilità di specificare esplicitamente il refresh/FPS tramite:

```text
--mode WxH@FPS
```

deve essere completamente rimossa.

La funzionalità dinamica basata sul client Steam Link deve rimanere invariata.

---

# 2. Comportamento finale desiderato

Le sole forme valide devono essere:

```text
steam-link-display-adapter %command%
```

```text
steam-link-display-adapter --mode auto %command%
```

```text
steam-link-display-adapter --mode 1920x1200 %command%
```

Deve essere invece rifiutato qualsiasi formato contenente `@FPS`:

```text
steam-link-display-adapter --mode 1920x1200@60 %command%
steam-link-display-adapter --mode 2560x1440@120 %command%
steam-link-display-adapter --mode 1280x800@75 %command%
```

Questi valori devono essere considerati **invalidi**.

---

# 3. Regola fondamentale

L’override CLI deve controllare esclusivamente la:

```text
WIDTH
HEIGHT
```

Il refresh non deve più essere specificabile dall’utente tramite Launch Options.

Quindi:

```text
--mode 1920x1200
```

significa:

```text
WIDTH  = 1920
HEIGHT = 1200
REFRESH = scelto automaticamente dal resolver esistente
```

Non deve significare:

```text
1920x1200@60
```

in modo implicito.

Il refresh deve continuare a essere determinato dal meccanismo già esistente.

---

# 4. Distinzione importante: FPS interno ≠ override FPS CLI

Non rimuovere indiscriminatamente tutte le variabili relative a FPS presenti nel progetto.

Il progetto utilizza internamente informazioni come:

```text
CLIENT_FPS
TARGET_FPS
STREAM_FPS
```

e il log Steam contiene ancora:

```text
Maximum capture: WxH FPS
```

Questi dati fanno parte del funzionamento interno della risoluzione dinamica e **non devono essere eliminati**.

La modifica riguarda esclusivamente la possibilità per l’utente di specificare:

```text
@FPS
```

nella Launch Option.

In particolare, il formato:

```text
--mode WxH
```

deve continuare a utilizzare il resolver esistente per determinare il refresh.

---

# 5. Parser CLI

Il parser attuale accetta concettualmente:

```text
--mode auto
--mode WxH
--mode WxH@FPS
```

Deve essere modificato in:

```text
--mode auto
--mode WxH
```

Il formato supportato deve quindi essere:

```regex
^([1-9][0-9]*)x([1-9][0-9]*)$
```

Il formato:

```regex
^([1-9][0-9]*)x([1-9][0-9]*)@([1-9][0-9]*)$
```

deve essere eliminato.

---

# 6. Stato interno del parser

Il parser non deve più avere bisogno di rappresentare un refresh esplicitamente richiesto dalla CLI.

Attualmente esistono concetti come:

```text
CLI_WIDTH
CLI_HEIGHT
CLI_REFRESH
CLI_REFRESH_FIXED
```

La parte relativa al refresh fisso CLI deve essere rimossa o resa inutilizzata e successivamente eliminata se non più necessaria.

Il caso:

```text
--mode 1920x1200
```

deve produrre concettualmente:

```text
MODE_SOURCE=cli
MODE_SPEC=1920x1200

CLI_WIDTH=1920
CLI_HEIGHT=1200

CLI_REFRESH=unset
CLI_REFRESH_FIXED=0
```

oppure un'equivalente rappresentazione interna più semplice.

Non deve esistere un percorso CLI capace di impostare:

```text
CLI_REFRESH_FIXED=1
```

---

# 7. Risoluzione target CLI

La funzione attualmente responsabile della risoluzione del target CLI deve essere semplificata.

Il comportamento desiderato è esclusivamente:

```text
CLI:
    width  = richiesto
    height = richiesto
    refresh = resolver esistente
```

Il flusso deve rimanere:

```text
--mode 1920x1200
        ↓
TARGET_WIDTH=1920
TARGET_HEIGHT=1200
        ↓
resolver esistente
        ↓
TARGET_REFRESH=<refresh compatibile>
```

Il parser non deve scegliere direttamente il refresh.

---

# 8. Nessun fallback implicito a STREAM_REFRESH

Prestare attenzione a un punto importante.

Con:

```text
--mode 1920x1200
```

non bisogna introdurre una nuova regola del tipo:

```text
TARGET_REFRESH=$STREAM_REFRESH
```

solo perché il CLI non specifica un refresh.

Il comportamento deve continuare a essere quello già previsto dal resolver condiviso.

Esempio:

```text
Host modes:

1920x1200@60
1920x1200@90
1920x1200@120
```

Con:

```text
--mode 1920x1200
```

il resolver deve scegliere il refresh secondo le sue regole già esistenti.

L’override CLI deve bloccare soltanto:

```text
1920x1200
```

non:

```text
1920x1200@60
```

---

# 9. Formati CLI validi

Devono essere accettati almeno:

```text
--mode auto
--mode 1920x1200
--mode 1920x1080
--mode 1280x800
--mode 2560x1440
```

Deve continuare a essere possibile il formato equivalente già supportato dal parser:

```text
--mode=1920x1200
```

se attualmente previsto.

Non è richiesto alcun cambiamento a questa sintassi, salvo che sia necessario per mantenere coerenza con l’implementazione esistente.

---

# 10. Formati CLI invalidi

Devono essere rifiutati:

```text
--mode 1920x1200@60
--mode 1920x1200@90
--mode 2560x1440@120
--mode 1280x800@75
```

e anche varianti non valide come:

```text
--mode 1920x1200@0
--mode 1920x1200@-60
--mode 1920x1200@abc
--mode 1920x1200@60foo
```

Il risultato deve essere:

```text
invalid --mode value
```

exit non-zero.

---

# 11. Fail-fast del parser

Un valore `--mode` non valido deve essere rilevato prima di qualsiasi:

```text
display change
modes.cfg modification
screen sleep
Gamescope preparation
Xwayland synchronization
state mutation
game launch
```

Questa proprietà già presente deve essere mantenuta.

Esempio:

```text
steam-link-display-adapter --mode 1920x1200@60 %command%
```

deve terminare immediatamente con errore.

Non deve mai arrivare a:

```text
resolve_stream_target
prepare_stream_mode
GAME_LAUNCH
```

---

# 12. Comportamento di `--mode auto`

Deve rimanere invariato.

```text
steam-link-display-adapter --mode auto %command%
```

deve forzare:

```text
MODE_SOURCE=auto
```

e quindi utilizzare:

```text
Steam Link client hint
        ↓
dynamic resolver
        ↓
TARGET_*
```

Esattamente come nella versione attuale.

Il fatto di eliminare `@FPS` non deve avere alcun effetto sulla modalità AUTO.

---

# 13. Comportamento senza `--mode`

Deve rimanere invariato:

```text
steam-link-display-adapter %command%
```

Priorità:

```text
CLI --mode
      ↓
global STREAM_MODE
      ↓
AUTO/default
```

Quindi:

### Nessun CLI + `STREAM_MODE=auto`

```text
AUTO
→ client hint
→ dynamic resolver
```

### Nessun CLI + `STREAM_MODE=fixed`

```text
fixed
→ STREAM_WIDTH
→ STREAM_HEIGHT
→ STREAM_REFRESH
```

Questo comportamento non deve essere modificato.

---

# 14. Precedenza

La precedenza deve rimanere:

```text
CLI > global config > auto
```

Esempi:

```text
--mode auto
STREAM_MODE=fixed
```

→ AUTO

```text
--mode 1920x1200
STREAM_MODE=auto
```

→ risoluzione CLI `1920x1200`

```text
nessun --mode
STREAM_MODE=fixed
```

→ target configurato

```text
nessun --mode
STREAM_MODE=auto
```

→ dynamic client resolution

---

# 15. Refresh resolution-only

Il significato definitivo di:

```text
--mode WxH
```

deve essere:

```text
resolution = fixed
refresh    = automatic
```

Il resolver esistente rimane l’unico componente autorizzato a determinare:

```text
TARGET_REFRESH
```

Il parser CLI non deve avere conoscenza delle regole di selezione del refresh.

---

# 16. Nessun nuovo resolver

Non creare un nuovo algoritmo per scegliere il refresh.

La pipeline deve rimanere:

```text
CLI parser
    ↓
Mode source
    ↓
existing target resolver
    ↓
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
TARGET_FPS
```

Il parser deve solamente fornire:

```text
WIDTH
HEIGHT
```

e lasciare al resolver la responsabilità del resto.

---

# 17. Target runtime

Il modello runtime deve continuare a usare:

```text
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
TARGET_FPS
TARGET_SOURCE
TARGET_MODE_SPEC
```

ma con il seguente significato per CLI:

```text
TARGET_SOURCE=cli
TARGET_MODE_SPEC=1920x1200
TARGET_WIDTH=1920
TARGET_HEIGHT=1200
TARGET_REFRESH=<risolto>
```

Non deve più esistere:

```text
TARGET_MODE_SPEC=1920x1200@60
```

come risultato di un parametro CLI.

---

# 18. `TARGET_MODE_SPEC`

Per una Launch Option:

```text
--mode 1920x1200
```

deve essere:

```text
TARGET_MODE_SPEC=1920x1200
```

Non:

```text
TARGET_MODE_SPEC=1920x1200@60
```

Il refresh effettivamente utilizzato può continuare a essere registrato separatamente in:

```text
TARGET_REFRESH
```

Esempio:

```text
TARGET_MODE_SPEC=1920x1200
TARGET_WIDTH=1920
TARGET_HEIGHT=1200
TARGET_REFRESH=164
```

Questo permette di distinguere chiaramente:

```text
richiesta utente
```

da:

```text
modalità realmente selezionata
```

---

# 19. Logging

Aggiornare i log in modo coerente con il nuovo modello.

Per:

```text
--mode 1920x1200
```

può essere registrato:

```text
MODE_SOURCE=cli
CLI_MODE=1920x1200
TARGET_MODE=1920x1200@<resolved-refresh>
```

È importante distinguere:

```text
CLI_MODE
```

dalla modalità effettivamente applicata:

```text
TARGET_MODE
```

Il secondo può continuare a contenere il refresh perché rappresenta il mode reale di Gamescope.

Non deve invece essere possibile avere:

```text
CLI_MODE=1920x1200@60
```

---

# 20. Help

Aggiornare completamente l’help.

La sezione deve diventare concettualmente:

```text
Usage:
  steam-link-display-adapter [OPTIONS] %command%

Options:
  --mode auto
      Use dynamic resolution based on the Steam Link client.

  --mode WxH
      Force the resolution and choose a compatible refresh automatically.

  --help
      Show this help.

Examples:
  steam-link-display-adapter --mode auto %command%
  steam-link-display-adapter --mode 1920x1200 %command%
```

Deve essere completamente eliminato ogni riferimento a:

```text
WxH@FPS
```

e:

```text
Force resolution and refresh
```

---

# 21. README

Aggiornare la documentazione del progetto.

La sezione:

```text
Override per-gioco (`--mode`)
```

deve documentare esclusivamente:

```text
steam-link-display-adapter %command%
steam-link-display-adapter --mode auto %command%
steam-link-display-adapter --mode 1920x1200 %command%
```

Descrizione:

```text
--mode 1920x1200
```

= geometria forzata, refresh scelto automaticamente dal resolver.

Rimuovere completamente gli esempi:

```text
--mode 1920x1200@60
--mode 2560x1440@120
```

e qualsiasi spiegazione relativa al blocco esplicito del refresh tramite CLI.

---

# 22. Configurazione globale

Non modificare inutilmente la configurazione globale.

Le variabili:

```text
STREAM_REFRESH
STREAM_FPS
STREAM_MODE
STREAM_ALT_REFRESHES
```

possono continuare a esistere perché appartengono al funzionamento globale del wrapper e del resolver.

La richiesta riguarda la semplicità delle Launch Options per-gioco, non la rimozione della gestione interna del refresh.

In particolare:

```text
STREAM_MODE=fixed
```

deve continuare a poter rappresentare il comportamento legacy con:

```text
STREAM_WIDTH
STREAM_HEIGHT
STREAM_REFRESH
```

---

# 23. Xwayland #1

Nessuna modifica architetturale.

Xwayland #1 deve continuare a ricevere:

```text
TARGET_WIDTH
TARGET_HEIGHT
```

e il meccanismo:

```text
GAMESCOPE_XWAYLAND_MODE_CONTROL
```

deve rimanere invariato.

Con:

```text
--mode 1920x1200
```

il risultato deve essere:

```text
Gamescope:
1920x1200@<resolved-refresh>

Xwayland #1:
1920x1200
```

Il parser CLI non deve comunicare direttamente con Xwayland.

---

# 24. Lifecycle

Non modificare il lifecycle Steam Link già funzionante.

Deve restare:

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
        ↓
STREAM
        ↓
RESTORE
```

La modifica deve essere limitata alla definizione dei valori accettabili per `--mode`.

---

# 25. Prima connessione

Non modificare in alcun modo il meccanismo event-driven già implementato.

La rimozione di `@FPS` non deve reintrodurre dipendenze da:

```text
previous stream marker
historical session
old client hint
```

La prima connessione deve continuare a funzionare esattamente come le successive.

---

# 26. Client diversi

Con:

```text
--mode auto
```

deve continuare a funzionare:

```text
Client A → 1920x1200
Client B → 1280x800
Client C → 1920x1080
```

Con:

```text
--mode 1920x1200
```

il target geometrico deve invece rimanere:

```text
1920x1200
```

indipendentemente dal client connesso.

Il refresh può continuare a essere determinato dal resolver/host modes.

---

# 27. Immuntabilità del target durante lo stream

La regola attuale deve rimanere invariata.

Dopo:

```text
GAME_LAUNCH
```

non devono essere applicati nuovi client hint per modificare:

```text
TARGET_WIDTH
TARGET_HEIGHT
TARGET_REFRESH
```

durante la stessa sessione.

Con:

```text
--mode 1920x1200
```

il target geometrico deve quindi rimanere:

```text
1920x1200
```

per tutta la sessione.

---

# 28. Desktop Mode e Gaming Mode locale

Con Steam Link non attivo:

```text
steam-link-display-adapter --mode 1920x1200 %command%
```

deve continuare a eseguire direttamente:

```text
exec GAME_ARGS
```

senza:

```text
display switch
modes.cfg change
screen sleep
Xwayland sync
Gamescope preparation
```

La Launch Option è un override applicabile soltanto quando la pipeline Steam Link viene effettivamente attivata.

---

# 29. Fail-closed

Il comportamento fail-closed deve distinguere:

### Errore di sintassi CLI

Esempio:

```text
--mode 1920x1200@60
```

→ errore immediato

→ nessuna modifica di stato

### Risoluzione CLI non disponibile

Esempio:

```text
--mode 2560x1600
```

quando il resolver non trova un mode applicabile.

→ fail-closed

→ nessun avvio del gioco

La seconda situazione deve continuare a utilizzare il comportamento già presente.

---

# 30. Test parser

Aggiornare i test esistenti.

Devono risultare validi:

```text
--mode auto
--mode 1920x1200
--mode 1920x1080
--mode 1280x800
```

Devono risultare invalidi:

```text
--mode 1920x1200@60
--mode 1920x1200@90
--mode 2560x1440@120
```

Verificare inoltre:

```text
--mode=
--mode 0x1200
--mode 1920x0
--mode x1200
--mode 1920x
--mode 1920x1200@abc
--mode 1920x1200@0
```

---

# 31. Test `--mode=`

Se il parser attuale supporta:

```text
--mode=1920x1200
```

mantenere il supporto.

Deve essere invece rifiutato:

```text
--mode=1920x1200@60
```

---

# 32. Test argv preservation

Verificare che:

```text
--mode 1920x1200
/usr/bin/game
--arg1
foo
--arg2
bar
```

produca:

```text
TARGET_WIDTH=1920
TARGET_HEIGHT=1200
```

e:

```text
GAME_ARGV=(
    /usr/bin/game
    --arg1
    foo
    --arg2
    bar
)
```

Il parametro:

```text
--mode
```

non deve essere passato al gioco.

---

# 33. Test refresh resolution

Questo test è fondamentale.

Input:

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
TARGET_WIDTH=1920
TARGET_HEIGHT=1200
TARGET_REFRESH=<refresh scelto dal resolver>
```

Il test deve dimostrare che il CLI **non forza 60**.

Questo punto è importante perché la rimozione di `@FPS` non deve trasformare accidentalmente `WxH` in:

```text
WxH@STREAM_REFRESH
```

---

# 34. Test regressione AUTO

Input:

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

e il resolver dinamico deve continuare a determinare il refresh come prima.

---

# 35. Test regressione default

Input:

```text
steam-link-display-adapter %command%
```

Con:

```text
STREAM_MODE=auto
```

deve continuare a usare la risoluzione dinamica.

Nessuna modifica rispetto alla branch funzionante.

---

# 36. Test configurazione fixed

Con:

```text
STREAM_MODE=fixed
```

e:

```text
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
```

senza CLI:

```text
TARGET=1920x1200@60
```

Questo comportamento deve rimanere invariato.

---

# 37. Test invalid `@FPS`

Aggiungere un test esplicito che dimostri:

```text
steam-link-display-adapter --mode 1920x1200@60 %command%
```

→ exit non-zero

e contemporaneamente:

```text
GAME_LAUNCH=false
```

```text
modes.cfg unchanged
```

```text
state unchanged
```

```text
display unchanged
```

Questo deve essere verificato nella suite hardware-free.

---

# 38. Test anti-regressione streaming

Con:

```text
Steam Link ON
--mode 1920x1200
```

verificare che il risultato rimanga:

```text
Output:
1920x1200@<resolved-refresh>

Xwayland #1:
1920x1200

Steam capture:
1920x1200
```

Il fix già presente per il mismatch geometrico non deve essere modificato.

---

# 39. Test anti-regressione locale

Con:

```text
Steam Link OFF
--mode 1920x1200
```

verificare:

```text
game launched
display unchanged
```

sia in:

```text
Desktop Mode
```

sia in:

```text
Gaming Mode
```

---

# 40. Test duplicate `--mode`

Mantenere il comportamento attuale.

Esempio:

```text
--mode 1920x1200 --mode 1280x800 %command%
```

→ errore

→ nessuna modifica al sistema.

---

# 41. Test unknown options

Mantenere il comportamento esistente:

```text
--foo bar %command%
```

→ errore

mentre gli argomenti successivi al game command devono essere lasciati invariati.

---

# 42. Documentazione tecnica interna

Aggiornare anche eventuali riferimenti che descrivono l’architettura precedente.

In particolare cercare e rimuovere/aggiornare ogni riferimento a:

```text
WxH@FPS
CLI_REFRESH_FIXED
Force resolution + refresh
fixed refresh CLI
TARGET_MODE_SPEC=<WxH@FPS>
```

La documentazione deve riflettere il comportamento reale implementato.

---

# 43. Analisi CLI esistente

Il file:

```text
ANALISI-CLI-MODE.md
```

attualmente descrive esplicitamente il supporto a:

```text
WxH@FPS
```

Questa analisi non deve più essere considerata corretta nella sua forma attuale.

Aggiornarla o sostituirla in modo che documenti esclusivamente:

```text
auto
WxH
```

Il documento deve essere coerente con il nuovo comportamento del codice.

---

# 44. README e help devono essere coerenti

Non deve esistere una situazione in cui:

```text
README → WxH
help → WxH@FPS
parser → WxH
```

La sintassi documentata e quella realmente accettata devono essere identiche.

Cercare quindi globalmente nel repository:

```text
@FPS
WxH@FPS
1920x1200@60
CLI_REFRESH
CLI_REFRESH_FIXED
resolution + refresh
```

e verificare ogni occorrenza.

Le occorrenze che appartengono al funzionamento interno del resolver possono essere mantenute, ma devono essere distinte chiaramente dal formato delle Launch Options.

---

# 45. Vincoli di implementazione

Non:

* modificare il rilevamento Steam Link;
* modificare la gestione della prima connessione;
* modificare il resolver dinamico del client;
* modificare la sincronizzazione Xwayland #1;
* modificare il lifecycle;
* modificare cleanup o stale-state recovery;
* eliminare la gestione interna del refresh;
* eliminare `CLIENT_FPS` se ancora necessario al resolver;
* eliminare `TARGET_FPS` se ancora necessario al pipeline;
* modificare il comportamento `STREAM_MODE=fixed`;
* rendere obbligatorio `--mode`;
* modificare il comportamento senza CLI.

La modifica deve essere strettamente limitata alla rimozione del **refresh esplicito dalla sintassi CLI**.

---

# 46. Architettura finale

La pipeline deve diventare:

```text
Steam Launch Options
        │
        ▼
   wrapper parser
        │
        ├── nessun --mode ──────────┐
        │                           │
        ├── --mode auto ────────────┤
        │                           │
        └── --mode WxH ─────────────┘
                                    │
                                    ▼
                           mode source resolver
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
                    ▼                               ▼
                  AUTO                            CLI WxH
                    │                               │
             client hint                    fixed geometry
                    │                               │
                    └───────────────┬───────────────┘
                                    ▼
                            existing resolver
                                    │
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

Il refresh appartiene al:

```text
target resolution stage
```

e non più alla sintassi CLI.

---

# 47. Comportamento finale deterministico

```text
steam-link-display-adapter %command%
```

→ comportamento configurato/default, normalmente AUTO.

```text
steam-link-display-adapter --mode auto %command%
```

→ AUTO dinamico dal client Steam Link.

```text
steam-link-display-adapter --mode 1920x1200 %command%
```

→ risoluzione fissata a `1920x1200`, refresh scelto dal resolver.

```text
steam-link-display-adapter --mode 1920x1200@60 %command%
```

→ INVALID.

```text
steam-link-display-adapter --mode 1920x1200@120 %command%
```

→ INVALID.

---

# 48. Definition of Done

La modifica è completata quando:

```text
[✓] --mode auto continua a funzionare
[✓] --mode WxH continua a funzionare
[✓] --mode WxH@FPS non è più accettato
[✓] il parser non gestisce più un refresh CLI
[✓] WxH forza solo width/height
[✓] il refresh viene scelto dal resolver esistente
[✓] AUTO rimane invariato
[✓] STREAM_MODE=fixed rimane invariato
[✓] CLI > config > auto rimane invariato
[✓] --mode non viene passato al gioco
[✓] invalid @FPS fallisce prima di qualunque modifica
[✓] Desktop Mode invariato
[✓] Gaming Mode locale invariato
[✓] prima connessione invariata
[✓] Xwayland #1 invariato
[✓] cleanup invariato
[✓] stale-state recovery invariato
[✓] dynamic client resolution invariata
[✓] README aggiornato
[✓] help aggiornato
[✓] ANALISI-CLI-MODE.md aggiornato
[✓] config/documentazione coerenti
[✓] test parser aggiornati
[✓] test refresh resolution-only presente
[✓] test invalid @FPS presente
[✓] suite completa PASS
```

---

# 49. Principio progettuale finale

La semplificazione richiesta è intenzionale:

```text
Launch Options
    ↓
scegliere AUTO oppure una RISOLUZIONE
    ↓
resolver interno
    ↓
determinare automaticamente il refresh
```

Non:

```text
Launch Options
    ↓
scegliere RISOLUZIONE + REFRESH
```

Il principio da mantenere è:

> **L’utente specifica la geometria; il sistema decide il refresh.**

Tutto il resto del comportamento già funzionante della branch `feature/dinamic-client-resolution` deve rimanere invariato.
