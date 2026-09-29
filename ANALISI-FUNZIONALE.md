# ANALISI FUNZIONALE + IMPLEMENTAZIONE PARZIALE — steam-link-display-adapter
## steam-link-display-adapter — Steam Launch Wrapper per Virtual Display 1920×1200 @ 60 FPS
### Bazzite Gaming Mode + Gamescope + Steam Link

> **Stato del documento:** base operativa per l'implementazione.
>
> **Obiettivo:** fornire un wrapper per-game richiamabile con `%command%`, mantenendo il monitor host ultrawide per l'uso locale e predisponendo, durante il gioco avviato con il wrapper, un output di streaming **1920×1200, 16:10, 60 Hz e target 60 FPS**.
>
> **Handoff:** la parte environment-specific di Gamescope è volutamente isolata in `steam-link-display-adapter-hook.sh`. L'altro agent deve completare e validare esclusivamente i punti indicati nella sezione **Handoff per l'altro agent**.

---

# 1. OBIETTIVO

Realizzare in **Bazzite Game Mode** uno script Bash utilizzabile come wrapper del comando di avvio del gioco Steam.

Launch Option prevista:

```text
~/.local/bin/steam-link-display-adapter %command%
```

Il comportamento desiderato è:

```text
Steam
  ↓
Wrapper
  ↓
PRECHECK
  ↓
acquisizione lock
  ↓
salvataggio stato
  ↓
preparazione display streaming
  ↓
Gamescope → 1920×1200 @ 60 Hz
  ↓
verifica reale
  ↓
monitor fisico SLEEP/OFF
  ↓
avvio gioco
  ↓
Steam Link / Remote Play
  ↓
game termina
  ↓
monitor ON
  ↓
ripristino 3440×1440
  ↓
verifica reale
  ↓
cleanup
  ↓
exit code originale
```

Il target della modalità streaming è obbligatoriamente:

```text
Risoluzione:   1920×1200
Aspect ratio:  16:10
Refresh:       60 Hz
Stream FPS:    60 FPS target
```

Il monitor locale host rimane invece:

```text
3440×1440
21:9
165 Hz
```

Il wrapper deve funzionare senza configurazione per-gioco oltre alla singola Launch Option necessaria per quel gioco.

---

# 2. PROBLEMA TECNICO

Il monitor fisico host è ultrawide:

```text
3440×1440
21:9
```

mentre il client Steam Link di riferimento usa:

```text
1920×1200
16:10
```

La sorgente di capture di Steam Remote Play è legata alla superficie/output della sessione Gamescope; partire da un output 21:9 può quindi produrre un frame non coincidente con il formato del client.

L'obiettivo non è correggere l'immagine successivamente con crop o stretch, ma portare l'output Gamescope effettivo al formato del client:

```text
ERRATO
3440×1440
    ↓
capture
    ↓
resize/crop
    ↓
1920×1200
```

```text
CORRETTO
Gamescope output
1920×1200 @ 60 Hz
    ↓
PipeWire capture
1920×1200
    ↓
Steam Remote Play
1920×1200
    ↓
client
1920×1200
```

---

# 3. VINCOLI INDEROGABILI

| Vincolo | Requisito |
|---|---|
| Sistema operativo | Bazzite |
| Sessione | **Gaming Mode** |
| Compositor | Gamescope standalone |
| Streaming | Steam Remote Play / Steam Link |
| Client target | 1920×1200 |
| Aspect ratio | **16:10** |
| Refresh display streaming | **60 Hz** |
| Streaming target | **60 FPS** |
| Monitor host | 3440×1440 ultrawide |
| Monitor fisico durante stream | SLEEP/OFF |
| Ripristino | Automatico |
| Configurazione durante lo stream | Nessuna |
| KWin | Non utilizzato |
| KScreen | Non utilizzato |
| xrandr | Non utilizzato |
| Desktop Mode | Non utilizzata |
| Configurazione per-gioco grafica | Non richiesta |
| Proton | Indipendente |

---

# 4. DEFINIZIONE DEL VIRTUAL DISPLAY

In questa implementazione il termine **virtual display** indica il profilo di output utilizzato dalla sessione Gamescope durante il gioco avviato con il wrapper.

Profilo locale:

```text
DP-3
3440×1440 @ 165 Hz
monitor ON
```

Profilo streaming:

```text
DP-3
1920×1200 @ 60 Hz
16:10
monitor SLEEP/OFF
stream target 60 FPS
```

Il primo obiettivo non è creare un secondo connector DRM indipendente, ma verificare se l'attuale backend Gamescope consente il mode switching del connector reale tramite i meccanismi disponibili.

Il `VirtualConnector` interno di Gamescope non deve essere considerato automaticamente equivalente a un secondo monitor DRM fisico/virtuale con un proprio scanout indipendente.

---

# 5. ARCHITETTURA DELLA SOLUZIONE

```text
┌────────────────────────────────────────────────────────────┐
│                     BAZZITE GAME MODE                      │
│                                                            │
│ Steam                                                        │
│  │                                                         │
│  ▼                                                         │
│ steam-link-display-adapter %command%                        │
│  │                                                         │
│  ├── PRECHECK                                              │
│  ├── LOCK                                                  │
│  ├── SAVE STATE                                            │
│  ├── PREPARE STREAM MODE                                   │
│  ├── VERIFY 1920×1200@60                                   │
│  ├── SCREEN SLEEP                                          │
│  ├── RUN GAME                                              │
│  └── CLEANUP                                               │
│                                                            │
│                  Gamescope / DRM                           │
│                         │                                  │
│                         ▼                                  │
│                        DP-3                                │
│                         │                                  │
│             ┌───────────┴───────────┐                      │
│             │                       │                      │
│          LOCAL                 STREAMING                   │
│       3440×1440               1920×1200                    │
│          ON                    SLEEP                       │
│                                   │                        │
│                                   ▼                        │
│                             PipeWire / Steam                │
└────────────────────────────────────────────────────────────┘
```

---

# 6. COMPONENTI IMPLEMENTATI ORA

La prima implementazione contiene i seguenti componenti.

```text
steam-link-display-adapter.sh
steam-link-display-adapter-hook.sh
steam-link-display-adapter-verify-environment.sh
steam-link-display-adapter-restore.sh
steam-link-display-adapter.conf.example
install.sh
```

La struttura installata sarà:

```text
~/.local/bin/
├── steam-link-display-adapter
├── steam-link-display-adapter-hook.sh
├── steam-link-display-adapter-verify-environment
└── steam-link-display-adapter-restore

~/.config/steam-link-display-adapter/
└── config

~/.local/state/steam-link-display-adapter/
├── lock
├── state
├── modes.cfg.backup
└── wrapper.log
```

---

# 7. WRAPPER PRINCIPALE

## Funzione

`steam-link-display-adapter.sh` è il componente che deve essere inserito nelle Launch Options di Steam.

Responsabilità:

```text
precheck
→ lock
→ recovery stato precedente
→ backup configurazione
→ preparazione modalità streaming
→ verifica
→ sleep monitor
→ esecuzione gioco
→ cleanup
→ restore
→ exit code originale
```

## Implementazione attuale

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Steam launch wrapper for Bazzite Game Mode / Gamescope.
# Target: 1920x1200 @ 60 Hz, 16:10, 60 FPS streaming.
# HANDOFF: environment-specific completion point is intentionally isolated in
# steam-link-display-adapter-hook.sh. Validate it on the real Bazzite Game Mode session
# before relying on this wrapper. In particular verify xprop/xdpyinfo display
# access and the exact Gamescope connector/mode behavior.
#
# IMPORTANT:
# - This wrapper is intentionally fail-closed.
# - It NEVER turns the physical display off unless the target Gamescope mode
#   was verified first.
# - The actual Gamescope integration lives in steam-link-display-adapter-hook.sh.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/steam-link-display-adapter-hook.sh"
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/steam-link-display-adapter/config"

CONNECTOR='DP-3'
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
STREAM_FPS=60
STREAM_ASPECT='16:10'
LOCAL_WIDTH=3440
LOCAL_HEIGHT=1440
LOCAL_REFRESH=165
MODE_TIMEOUT_SECONDS=5
POLL_INTERVAL_SECONDS=0.10
GAMESCOPE_DISPLAY="${DISPLAY:-}"
GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/steam-link-display-adapter"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steam-link-display-adapter"
LOG_FILE="$STATE_DIR/wrapper.log"
STATE_FILE="$STATE_DIR/state"
LOCK_FILE="$STATE_DIR/lock"
MODES_FILE="$HOME/.config/gamescope/modes.cfg"

if [[ -f "$USER_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$USER_CONFIG"
fi

mkdir -p "$STATE_DIR" "$CONFIG_DIR"

# shellcheck disable=SC1091
source "$HOOK"

if [[ $# -eq 0 ]]; then
    printf 'Usage: %s <game-command> [args...]\n' "$0" >&2
    exit 64
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    printf 'steam-link-display-adapter: another instance is already active\n' >&2
    exit 73
fi

log_file() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

log() {
    log_file "$*"
}

fail() {
    log "ERROR: $*"
    printf 'steam-link-display-adapter: ERROR: %s\n' "$*" >&2
    return 1
}

state_write() {
    local phase=$1
    local tmp
    tmp=$(mktemp --tmpdir="$STATE_DIR" '.state.XXXXXX')
    {
        printf 'VERSION=1\n'
        printf 'PHASE=%s\n' "$phase"
        printf 'MODES_BACKUP=%s\n' "$MODES_BACKUP"
        printf 'MODES_EXISTED=%s\n' "$MODES_EXISTED"
        printf 'SCREEN_SLEEP_REQUESTED=%s\n' "$SCREEN_SLEEP_REQUESTED"
    } >"$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

state_phase() {
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n 's/^PHASE=//p' "$STATE_FILE" | head -n1
}

state_clear() {
    rm -f -- "$STATE_FILE"
}

MODES_BACKUP="$STATE_DIR/modes.cfg.backup"
MODES_EXISTED=0
SETUP_DONE=0
SCREEN_SLEEP_REQUESTED=0
CLEANUP_DONE=0
GAME_EXIT_CODE=0

backup_modes_file() {
    rm -f -- "$MODES_BACKUP"
    if [[ -f "$MODES_FILE" ]]; then
        cp --reflink=auto -- "$MODES_FILE" "$MODES_BACKUP"
        MODES_EXISTED=1
    else
        : >"$MODES_BACKUP"
        MODES_EXISTED=0
    fi
    log "Backed up modes.cfg to $MODES_BACKUP (existed=$MODES_EXISTED)"
}

restore_modes_file() {
    [[ -n "$MODES_BACKUP" ]] || return 0
    if (( MODES_EXISTED )); then
        mkdir -p "$(dirname -- "$MODES_FILE")"
        local tmp
        tmp=$(mktemp --tmpdir="$(dirname -- "$MODES_FILE")" '.modes.cfg.restore.XXXXXX')
        cp --reflink=auto -- "$MODES_BACKUP" "$tmp"
        mv -f -- "$tmp" "$MODES_FILE"
    else
        rm -f -- "$MODES_FILE"
    fi
    log "Restored modes.cfg"
}

write_saved_mode_for_description() {
    local description=$1
    local width=$2
    local height=$3
    local refresh=$4
    local tmp dir

    dir=$(dirname -- "$MODES_FILE")
    mkdir -p "$dir"
    tmp=$(mktemp --tmpdir="$dir" '.modes.cfg.stream.XXXXXX')

    if [[ -f "$MODES_FILE" ]]; then
        awk -v d="$description" -v w="$width" -v h="$height" -v r="$refresh" '
            BEGIN { replaced=0 }
            {
                line=$0
                split(line, a, ":")
                if (index(line, ":") > 0 && a[1] == d) {
                    if (!replaced) {
                        printf "%s:%dx%d@%d\n", d, w, h, r
                        replaced=1
                    }
                    next
                }
                print line
            }
            END {
                if (!replaced)
                    printf "%s:%dx%d@%d\n", d, w, h, r
            }
        ' "$MODES_FILE" >"$tmp"
    else
        printf '%s:%dx%d@%d\n' "$description" "$width" "$height" "$refresh" >"$tmp"
    fi

    mv -f -- "$tmp" "$MODES_FILE"
    log "Configured saved mode: ${description}:${width}x${height}@${refresh}"
}

cleanup() {
    local rc=$?

    if (( CLEANUP_DONE )); then
        return "$rc"
    fi
    CLEANUP_DONE=1

    log "Cleanup started (state=$(state_phase || true))"

    # Safety priority: wake the monitor first.
    if (( SCREEN_SLEEP_REQUESTED )); then
        if screen_wake; then
            log "External screen wake requested"
        else
            log "CRITICAL: failed to wake external screen"
        fi
        SCREEN_SLEEP_REQUESTED=0
    fi

    if [[ -n "$MODES_BACKUP" ]]; then
        if restore_modes_file; then
            log "modes.cfg restored from backup"
        else
            log "CRITICAL: failed to restore modes.cfg"
        fi
    fi

    if command -v xprop >/dev/null 2>&1 && [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]]; then
        if nudge_mode; then
            log "Gamescope local-mode nudge sent"
            if wait_for_local_mode; then
                log "Verified local mode: ${LOCAL_WIDTH}x${LOCAL_HEIGHT}@${LOCAL_REFRESH}"
            else
                log "CRITICAL: local mode verification timed out"
            fi
        else
            log "CRITICAL: failed to nudge Gamescope during restore"
        fi
    fi

    if command -v gamescopectl >/dev/null 2>&1; then
        if set_dynamic_modes_allowed 0; then
            log "Dynamic external display modes disabled"
        else
            log "WARNING: failed to disable dynamic external display modes"
        fi
    fi

    rm -f -- "$MODES_BACKUP" 2>/dev/null || true
    state_clear
    log "Cleanup finished"

    return "$rc"
}

recover_stale_state() {
    local previous stale_backup stale_existed
    previous=$(state_phase || true)
    [[ -n "$previous" ]] || return 0

    log "Stale state detected: $previous"
    log "Running conservative recovery before starting new game"

    stale_backup=$(sed -n 's/^MODES_BACKUP=//p' "$STATE_FILE" | head -n1 || true)
    stale_existed=$(sed -n 's/^MODES_EXISTED=//p' "$STATE_FILE" | head -n1 || true)
    [[ -n "$stale_backup" ]] && MODES_BACKUP=$stale_backup
    MODES_EXISTED=${stale_existed:-0}

    if ! screen_wake; then
        log "ERROR: stale-state recovery could not wake external screen"
        return 1
    fi

    if [[ -f "$MODES_BACKUP" ]]; then
        if ! restore_modes_file; then
            log "ERROR: stale-state recovery could not restore modes.cfg"
            return 1
        fi
    else
        log "ERROR: stale state exists but backup is missing"
        return 1
    fi

    if [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]]; then
        if ! nudge_mode; then
            log "ERROR: stale-state recovery could not nudge Gamescope"
            return 1
        fi
        if ! wait_for_local_mode; then
            log "ERROR: stale-state recovery could not verify local mode"
            return 1
        fi
    fi

    if ! set_dynamic_modes_allowed 0; then
        log "ERROR: stale-state recovery could not disable dynamic modes"
        return 1
    fi

    rm -f -- "$MODES_BACKUP" 2>/dev/null || true
    state_clear
    log "Stale-state recovery complete"
}

validate_config() {
    [[ "$STREAM_WIDTH" -eq 1920 && "$STREAM_HEIGHT" -eq 1200 ]] || fail "stream resolution must be 1920x1200"
    [[ "$STREAM_REFRESH" -eq 60 ]] || fail "stream refresh must be 60 Hz"
    [[ "$STREAM_FPS" -eq 60 ]] || fail "stream FPS target must be 60"
    [[ "$STREAM_ASPECT" == '16:10' ]] || fail "stream aspect must be 16:10"
    [[ -n "$CONNECTOR" ]] || fail "CONNECTOR is empty"
    [[ "$MODE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "MODE_TIMEOUT_SECONDS invalid"
}

precheck() {
    require_cmd gamescopectl
    require_cmd xprop
    require_cmd xdpyinfo
    require_cmd flock

    [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]] || fail "DISPLAY/GAMESCOPE_DISPLAY is not set"

    local actual_connector
    actual_connector=$(get_connector_name || true)
    [[ "$actual_connector" == "$CONNECTOR" ]] || {
        fail "Gamescope connector is '$actual_connector', expected '$CONNECTOR'"
        return 1
    }

    log "Gamescope connector verified: $actual_connector"

    mode_list_contains "${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_REFRESH}" || {
        fail "Gamescope does not currently advertise ${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_REFRESH}"
        return 1
    }

    log "Target mode is advertised by Gamescope"
}

prepare_stream_mode() {
    local description current
    description=$(get_display_description || true)
    [[ -n "$description" ]] || {
        fail "unable to determine Gamescope display description"
        return 1
    }

    log "Gamescope display description: $description"

    backup_modes_file
    state_write 'PREPARING'
    write_saved_mode_for_description "$description" "$STREAM_WIDTH" "$STREAM_HEIGHT" "$STREAM_REFRESH"

    set_dynamic_modes_allowed 1
    log "Dynamic external display modes enabled"

    nudge_mode
    log "Gamescope display-mode nudge sent"

    if ! wait_for_target_mode; then
        current=$(get_current_mode 2>/dev/null || printf 'unknown')
        fail "target mode not reached within ${MODE_TIMEOUT_SECONDS}s (current=$current)"
        return 1
    fi

    log "Verified target mode: ${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_REFRESH} (${STREAM_ASPECT})"

    screen_sleep
    SCREEN_SLEEP_REQUESTED=1
    log "External screen sleep requested"

    state_write 'STREAMING'
    SETUP_DONE=1
}

run_game() {
    log "Launching game: $(printf '%q ' "$@")"

    "$@" &
    GAME_PID=$!
    log "Game PID: $GAME_PID"

    wait "$GAME_PID" || GAME_EXIT_CODE=$?
    log "Game exited with code $GAME_EXIT_CODE"
    return 0
}

trap 'rc=$?; cleanup; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

validate_config
recover_stale_state
precheck
prepare_stream_mode
run_game "$@"
exit "$GAME_EXIT_CODE"
```

---

# 8. GAMESCOPE / DRM HOOK

## Funzione

`steam-link-display-adapter-hook.sh` contiene esclusivamente la parte dipendente dall'ambiente Gamescope/DRM.

Questa separazione è intenzionale: l'altro agent può correggere o sostituire il metodo di interrogazione/cambio mode senza riscrivere il lifecycle del wrapper.

Responsabilità:

```text
Gamescope discovery
connector discovery
mode list
current mode
mode verification
dynamic mode permission
screen sleep/wake
mode nudge
polling target/local
```

## Implementazione attuale

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Gamescope/DRM integration layer.
# The main wrapper deliberately calls only these functions. The other agent can
# refine the environment-specific probing here without rewriting lifecycle logic.

set -Eeuo pipefail

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "ERROR: required command not found: $1"
        return 1
    }
}

xprop_root_get() {
    local atom=$1
    [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]] || return 1
    DISPLAY="${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" xprop -root "$atom" 2>/dev/null
}

get_gamescope_info() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl 2>/dev/null
}

get_connector_name() {
    get_gamescope_info | awk -F': ' '/Connector Name:/ {print $2; exit}'
}

get_display_make() {
    get_gamescope_info | awk -F': ' '/Display Make:/ {print $2; exit}'
}

get_display_model() {
    get_gamescope_info | awk -F': ' '/Display Model:/ {print $2; exit}'
}

get_display_description() {
    local make model
    make=$(get_display_make || true)
    model=$(get_display_model || true)
    [[ -n "$make" && -n "$model" ]] || return 1
    printf '%s %s' "$make" "$model"
}

get_gamescope_mode_list() {
    local raw
    raw=$(xprop_root_get GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL) || return 1
    # Example: GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL(STRING) = "3440x1440@165 1920x1200@60"
    sed -n 's/.*= *"\(.*\)"/\1/p' <<<"$raw"
}

mode_list_contains() {
    local wanted=$1 list
    list=$(get_gamescope_mode_list) || return 1
    tr ' ' '\n' <<<"$list" | grep -Fxq "$wanted"
}

get_x_screen_size() {
    require_cmd xdpyinfo
    local line
    line=$(DISPLAY="${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
    [[ "$line" =~ ^[0-9]+x[0-9]+$ ]] || return 1
    printf '%s\n' "$line"
}

get_gamescope_refresh() {
    local raw value
    raw=$(xprop_root_get GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK) || return 1
    value=$(sed -n 's/.*= *\([0-9][0-9]*\).*/\1/p' <<<"$raw")
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

get_current_mode() {
    local size refresh
    size=$(get_x_screen_size) || return 1
    refresh=$(get_gamescope_refresh) || return 1
    printf '%s@%s\n' "$size" "$refresh"
}

is_target_mode_active() {
    local expected="${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_REFRESH}"
    [[ "$(get_current_mode 2>/dev/null || true)" == "$expected" ]]
}

is_local_mode_active() {
    local expected="${LOCAL_WIDTH}x${LOCAL_HEIGHT}@${LOCAL_REFRESH}"
    [[ "$(get_current_mode 2>/dev/null || true)" == "$expected" ]]
}

set_dynamic_modes_allowed() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl drm_allow_dynamic_modes_for_external_display "$1" >/dev/null
}

screen_sleep() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl drm_sleep_external_screen 1 >/dev/null
}

screen_wake() {
    require_cmd gamescopectl
    GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        gamescopectl drm_sleep_external_screen 0 >/dev/null
}

nudge_mode() {
    require_cmd xprop
    [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]] || {
        log "ERROR: DISPLAY/GAMESCOPE_DISPLAY is not set; cannot nudge Gamescope"
        return 1
    }
    DISPLAY="${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" \
        xprop -root -f GAMESCOPE_DISPLAY_MODE_NUDGE 32c \
        -set GAMESCOPE_DISPLAY_MODE_NUDGE 1 >/dev/null
}

wait_for_target_mode() {
    local deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if is_target_mode_active; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

wait_for_local_mode() {
    local deadline=$((SECONDS + MODE_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        if is_local_mode_active; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}
```

> **Nota di implementazione:** le funzioni `get_current_mode()`, `nudge_mode()`, `wait_for_target_mode()` e `wait_for_local_mode()` sono il principale punto da validare sulla Bazzite reale. Il wrapper non deve essere considerato operativo finché queste funzioni non dimostrano sul sistema reale che il mode effettivo è realmente cambiato.

---

# 9. ENVIRONMENT VERIFICATION / DIAGNOSTICA

## Funzione

`steam-link-display-adapter-verify-environment.sh` è volutamente **read-only**.

Serve all'altro agent per raccogliere:

```text
DISPLAY
GAMESCOPE_WAYLAND_DISPLAY
gamescopectl
gamescope X atoms
X screen size
DRM connector status
DRM modes
```

Non deve cambiare:

```text
resolution
screen state
modes.cfg
systemd
kernel args
```

## Implementazione attuale

```bash
#!/usr/bin/env bash
# Read-only diagnostic script for the other agent.
# It does not modify display state or files.
set -Eeuo pipefail

CONNECTOR=${CONNECTOR:-DP-3}
STREAM_MODE=${STREAM_MODE:-1920x1200@60}
GAMESCOPE_WAYLAND_DISPLAY=${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}

printf '%s\n' '=== Steam Link Display Environment ==='
printf 'DATE: %s\n' "$(date -Is)"
printf 'USER: %s\n' "${USER:-unknown}"
printf 'DISPLAY: %s\n' "${DISPLAY:-<unset>}"
printf 'GAMESCOPE_WAYLAND_DISPLAY: %s\n' "$GAMESCOPE_WAYLAND_DISPLAY"
printf 'Connector requested: %s\n' "$CONNECTOR"
printf 'Target mode: %s\n' "$STREAM_MODE"
printf '\n--- Commands ---\n'
for c in gamescopectl xprop xdpyinfo drm_info; do
    if command -v "$c" >/dev/null 2>&1; then
        printf '%-15s %s\n' "$c" "$(command -v "$c")"
    else
        printf '%-15s MISSING\n' "$c"
    fi
done

printf '\n--- Gamescope info ---\n'
gamescopectl 2>&1 || true

printf '\n--- Gamescope X atoms ---\n'
if [[ -n "${DISPLAY:-}" ]]; then
    xprop -root GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL 2>&1 || true
    xprop -root GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK 2>&1 || true
    xprop -root GAMESCOPE_DISPLAY_IS_EXTERNAL 2>&1 || true
    xprop -root GAMESCOPE_DISPLAY_MODE_NUDGE 2>&1 || true
else
    printf '%s\n' 'DISPLAY unset: X atom inspection skipped.'
fi

printf '\n--- X screen size ---\n'
if command -v xdpyinfo >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    xdpyinfo 2>&1 | awk '/dimensions:/ {print; exit}' || true
fi

printf '\n--- DRM connectors ---\n'
for p in /sys/class/drm/card*-*; do
    [[ -f "$p/status" ]] || continue
    printf '%s: status=%s\n' "$(basename "$p")" "$(cat "$p/status")"
    if [[ "$(basename "$p")" == *"-$CONNECTOR" ]]; then
        printf 'modes:\n'
        cat "$p/modes" 2>/dev/null || true
    fi
done

printf '\n=== END ===\n'
```

---

# 10. MANUAL RESTORE / RECOVERY HELPER

## Funzione

`steam-link-display-adapter-restore.sh` è un helper conservativo per recuperare uno stato rimasto da una precedente esecuzione.

Principio:

```text
NON entra in streaming mode
NON cambia il monitor a 1920×1200
NON avvia giochi
```

Tenta esclusivamente:

```text
screen wake
restore modes.cfg backup
nudge
verify local mode
disable dynamic modes
clear state
```

## Implementazione attuale

```bash
#!/usr/bin/env bash
# Conservative manual recovery helper.
# Never enters streaming mode. Intended for stale-state recovery.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/steam-link-display-adapter/config"
HOOK="$SCRIPT_DIR/steam-link-display-adapter-hook.sh"

LOCAL_WIDTH=3440
LOCAL_HEIGHT=1440
LOCAL_REFRESH=165
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/steam-link-display-adapter"
STATE_FILE="$STATE_DIR/state"
GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}"
GAMESCOPE_DISPLAY="${DISPLAY:-}"
MODES_BACKUP="$STATE_DIR/modes.cfg.backup"
MODES_EXISTED=0

if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
fi
# shellcheck disable=SC1091
source "$HOOK"

mkdir -p "$STATE_DIR"

printf '[%s] restore: starting\n' "$(date '+%Y-%m-%d %H:%M:%S')"

if [[ -f "$STATE_FILE" ]]; then
    state_backup=$(sed -n 's/^MODES_BACKUP=//p' "$STATE_FILE" | head -n1 || true)
    [[ -n "$state_backup" ]] && MODES_BACKUP=$state_backup
    MODES_EXISTED=$(sed -n 's/^MODES_EXISTED=//p' "$STATE_FILE" | head -n1 || printf '0')
fi

screen_wake || true
printf '[%s] restore: screen wake requested\n' "$(date '+%Y-%m-%d %H:%M:%S')"

if [[ -n "$MODES_BACKUP" && -f "$MODES_BACKUP" ]]; then
    if (( MODES_EXISTED )); then
        mkdir -p "$(dirname -- "$MODES_FILE")"
        tmp=$(mktemp --tmpdir="$(dirname -- "$MODES_FILE")" '.modes.cfg.restore.XXXXXX')
        cp --reflink=auto -- "$MODES_BACKUP" "$tmp"
        mv -f -- "$tmp" "$MODES_FILE"
    else
        rm -f -- "$MODES_FILE"
    fi
    printf '[%s] restore: stale modes.cfg snapshot restored\n' "$(date '+%Y-%m-%d %H:%M:%S')"
fi

if [[ -n "${GAMESCOPE_DISPLAY:-${DISPLAY:-}}" ]]; then
    if nudge_mode; then
        printf '[%s] restore: Gamescope nudge sent\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        wait_for_local_mode || true
    fi
fi

set_dynamic_modes_allowed 0 || true
rm -f -- "$MODES_BACKUP" 2>/dev/null || true
rm -f -- "$STATE_FILE"

printf '[%s] restore: finished\n' "$(date '+%Y-%m-%d %H:%M:%S')"
```

---

# 11. CONFIGURAZIONE

Il file di configurazione è:

```text
~/.config/steam-link-display-adapter/config
```

Template:

```bash
# Steam Link Display Wrapper configuration
# Copy to: ~/.config/steam-link-display-adapter/config

CONNECTOR='DP-3'

# Streaming target: Legion Go S
STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
STREAM_FPS=60
STREAM_ASPECT='16:10'

# Local Gamescope mode
LOCAL_WIDTH=3440
LOCAL_HEIGHT=1440
LOCAL_REFRESH=165

# Timing
MODE_TIMEOUT_SECONDS=5
POLL_INTERVAL_SECONDS=0.10

# X/Gamescope
GAMESCOPE_DISPLAY="${DISPLAY:-}"
GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}"

# State/log locations
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/steam-link-display-adapter"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steam-link-display-adapter"
LOG_FILE="$STATE_DIR/wrapper.log"
STATE_FILE="$STATE_DIR/state"
LOCK_FILE="$STATE_DIR/lock"
MODES_FILE="$HOME/.config/gamescope/modes.cfg"
```

Il target di streaming **non deve essere modificato** nella prima implementazione:

```text
1920×1200
16:10
60 Hz
60 FPS target
```

---

# 12. INSTALLER

## Funzione

`install.sh` installa gli script nella configurazione utente senza richiedere root.

Non sovrascrive una configurazione utente già presente.

## Implementazione attuale

```bash
#!/usr/bin/env bash
# Installs the currently implementable wrapper components for the current user.
# No sudo/root required. Does not overwrite an existing user config.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steam-link-display-adapter"

mkdir -p "$BIN_DIR" "$CONFIG_DIR"

install -m 0755 "$SCRIPT_DIR/steam-link-display-adapter.sh" "$BIN_DIR/steam-link-display-adapter"
install -m 0755 "$SCRIPT_DIR/steam-link-display-adapter-hook.sh" "$BIN_DIR/steam-link-display-adapter-hook.sh"
install -m 0755 "$SCRIPT_DIR/steam-link-display-adapter-verify-environment.sh" "$BIN_DIR/steam-link-display-adapter-verify-environment"
install -m 0755 "$SCRIPT_DIR/steam-link-display-adapter-restore.sh" "$BIN_DIR/steam-link-display-adapter-restore"

if [[ ! -e "$CONFIG_DIR/config" ]]; then
    install -m 0644 "$SCRIPT_DIR/steam-link-display-adapter.conf.example" "$CONFIG_DIR/config"
    echo "Installed new config: $CONFIG_DIR/config"
else
    echo "Existing config preserved: $CONFIG_DIR/config"
fi

printf '\nLaunch option:\n%s\n' "$BIN_DIR/steam-link-display-adapter %command%"
printf '\nInstalled files in: %s\n' "$BIN_DIR"
```

---

# 13. INSTALLAZIONE UTENTE

Dalla directory degli script:

```bash
chmod +x install.sh
./install.sh
```

L'installer non richiede `sudo`.

Dopo l'installazione, nelle Launch Options del gioco Steam inserire:

```text
/home/USER/.local/bin/steam-link-display-adapter %command%
```

La configurazione deve essere controllata prima del primo test:

```bash
nano ~/.config/steam-link-display-adapter/config
```

---

# 14. PRECONDIZIONE DRM — P1A

Il wrapper presuppone che Gamescope/DRM esponga realmente la modalità:

```text
1920×1200@60
```

Se il kernel non espone questa modalità sul connector `DP-3`, il wrapper deve fermarsi in fail-safe.

La soluzione prevista a monte è rendere disponibile la modalità tramite ModeDB/kernel argument, ad esempio:

```text
video=DP-3:1920x1200@60
```

Questa fase richiede **root + reboot** e viene eseguita separatamente dall'utente.

Dopo il reboot, prima di eseguire il wrapper, verificare:

```bash
cat /sys/class/drm/card*-DP-3/modes
```

e accertarsi che compaia:

```text
1920x1200
```

Il diagnostico fornito effettua questa stessa verifica in forma read-only.

---

# 15. PRECHECK DEL WRAPPER

La funzione `precheck()` deve verificare:

```text
1. gamescopectl presente
2. xprop presente
3. xdpyinfo presente
4. flock presente
5. Gamescope raggiungibile
6. DISPLAY/GAMESCOPE_DISPLAY disponibile
7. connector = DP-3
8. Gamescope pubblica 1920×1200@60
```

Se uno dei punti fallisce:

```text
NO SCREEN OFF
NO GAME START
NO PARTIAL STATE
```

---

# 16. STATE / LOCK

Il wrapper usa:

```text
~/.local/state/steam-link-display-adapter/lock
```

con `flock`.

Questo impedisce:

```text
Game A → wrapper
Game B → wrapper
```

di modificare contemporaneamente:

```text
modes.cfg
screen state
Gamescope mode
state file
```

Lo stato persistente utilizza:

```text
~/.local/state/steam-link-display-adapter/state
```

L'obiettivo è poter riconoscere uno stato precedente rimasto incompleto.

---

# 17. BACKUP DI `modes.cfg`

Prima di qualsiasi modifica:

```text
modes.cfg originale
        ↓
backup
        ↓
modifica temporanea
```

Il backup viene salvato in:

```text
~/.local/state/steam-link-display-adapter/modes.cfg.backup
```

Il file originale viene ripristinato a fine gioco.

La scrittura della configurazione temporanea avviene tramite file temporaneo + `mv`, evitando di lasciare un file troncato durante la scrittura.

---

# 18. MODE DESCRIPTION

Gamescope associa i saved mode alla descrizione del display.

La funzione:

```text
get_display_description()
```

recupera make/model tramite `gamescopectl`.

L'altro agent deve verificare che la stringa prodotta corrisponda esattamente alla description utilizzata da Gamescope nel contesto di `modes.cfg`.

Non deve essere hard-coded arbitrariamente.

---

# 19. PREPARAZIONE DELLO STREAM MODE

La funzione principale è:

```text
prepare_stream_mode()
```

Sequenza:

```text
backup modes.cfg
        ↓
state = PREPARING
        ↓
scrivi 1920×1200@60
        ↓
abilita dynamic modes
        ↓
nudge Gamescope
        ↓
poll mode corrente
        ↓
VERIFY 1920×1200@60
        ↓
SCREEN SLEEP
        ↓
state = STREAMING
```

Il punto di sicurezza fondamentale è:

```text
MODE VERIFY
    ↓
SCREEN SLEEP
```

mai il contrario.

---

# 20. GAMESCOPE NUDGE

L'attuale implementazione del hook utilizza:

```bash
xprop -root -f GAMESCOPE_DISPLAY_MODE_NUDGE 32c \
      -set GAMESCOPE_DISPLAY_MODE_NUDGE 1
```

Il nudge è un meccanismo di rivalutazione della configurazione del display.

Non deve essere considerato sufficiente da solo.

Dopo il nudge deve sempre avvenire:

```text
poll
→ read current mode
→ compare
```

---

# 21. VERIFICA DEL MODE

Target:

```text
1920x1200@60
```

Locale:

```text
3440x1440@165
```

Il wrapper attende fino a:

```text
MODE_TIMEOUT_SECONDS=5
```

con polling:

```text
POLL_INTERVAL_SECONDS=0.10
```

Se il target non viene raggiunto:

```text
FAIL
↓
NON spegnere monitor
↓
NON avviare gioco
↓
restore
↓
exit != 0
```

---

# 22. SCREEN SLEEP

Solo dopo il successo della verifica:

```text
1920×1200@60 verified
```

viene chiamato:

```bash
gamescopectl drm_sleep_external_screen 1
```

Lo stato viene poi marcato:

```text
SCREEN_SLEEP_REQUESTED=1
```

Questo flag autorizza il cleanup a eseguire il wake.

---

# 23. AVVIO DEL GIOCO

Il wrapper esegue il comando ricevuto da Steam:

```bash
"$@"
```

La chiamata è eseguita in background per permettere al wrapper di:

```text
attendere il processo
preservare exit code
mantenere il cleanup
```

Il gioco viene avviato solamente quando la fase display è completata.

---

# 24. EXIT CODE

Se il gioco restituisce:

```text
0
```

il wrapper restituisce:

```text
0
```

Se il gioco restituisce:

```text
42
```

il wrapper deve restituire:

```text
42
```

Il cleanup non deve nascondere l'exit code originale del gioco.

---

# 25. CLEANUP

Il cleanup è centralizzato nella funzione:

```text
cleanup()
```

Sequenza attuale:

```text
1. wake monitor
2. restore modes.cfg
3. nudge Gamescope
4. wait local mode
5. disable dynamic modes
6. remove temporary backup
7. clear state
```

La scelta di riaccendere prima il monitor rispetto al restore mode privilegia il requisito di sicurezza:

```text
monitor ON
```

anche se il restore della modalità dovesse fallire.

---

# 26. SIGNAL HANDLING

Il wrapper installa:

```text
EXIT
INT
TERM
HUP
```

con:

```bash
trap 'rc=$?; cleanup; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
```

Tutti i percorsi normali passano quindi da `cleanup()`.

---

# 27. STALE STATE RECOVERY

Se una precedente esecuzione lascia:

```text
STATE=STREAMING
```

o altro stato intermedio, la nuova esecuzione tenta per prima cosa:

```text
screen wake
restore modes.cfg
nudge
verify local mode
disable dynamic modes
clear state
```

Se lo snapshot necessario è assente, il comportamento è fail-safe e il nuovo gioco non viene avviato.

---

# 28. LIMITI INTRINSECI DEL WRAPPER

Il wrapper non può garantire cleanup dopo eventi come:

```text
SIGKILL
kernel panic
power loss
hard reset
crash completo della sessione
```

Per mitigare gli stati persistenti viene quindi mantenuto il file di stato.

Non viene introdotto un servizio systemd globale perché l'obiettivo di questa versione è mantenere l'implementazione per-game e semplice.

---

# 29. RAPPORTO CON STEAM LINK

Il wrapper non rileva la connessione Steam Link tramite PipeWire.

Questo è intenzionale.

Il presupposto della Launch Option è:

```text
questo gioco viene avviato con il wrapper
        ⇒
l'utente intende utilizzare la modalità streaming 1920×1200
```

Quindi il trigger è:

```text
GAME START
```

non:

```text
STEAM LINK CONNECT EVENT
```

Questo elimina watcher globali, parsing continuo del log Steam e servizi persistenti.

---

# 30. CLIENT TARGET

La prima implementazione usa un solo profilo:

```text
CLIENT TARGET
─────────────
1920×1200
16:10
```

Il profile di output è:

```text
1920×1200 @ 60 Hz
```

Lo streaming target è:

```text
60 FPS
```

La modalità dinamica multi-client rimane fuori scope.

---

# 31. PROTON / GIOCHI

Il wrapper non modifica:

```text
Proton
Wine
DXVK
VKD3D
Steam launch arguments interni del gioco
```

Si limita a eseguire gli argomenti ricevuti dopo l'espansione di `%command%`.

Di conseguenza il sistema è progettato per essere indipendente dalla versione di Proton.

---

# 32. TEST FUNZIONALI DA ESEGUIRE

## Test 1 — normale

```text
Play
→ 1920×1200@60
→ 16:10
→ monitor OFF
→ game
→ exit
→ monitor ON
→ 3440×1440@165
```

## Test 2 — mode switch failure

```text
1920×1200 non applicata
```

Atteso:

```text
monitor ON
game NOT started
local mode restored
exit != 0
```

## Test 3 — SIGTERM

Durante il gioco:

```bash
kill -TERM <wrapper-pid>
```

Atteso:

```text
monitor ON
local mode
config restored
```

## Test 4 — SIGINT

Stesso risultato.

## Test 5 — SIGHUP

Stesso risultato.

## Test 6 — exit code

Gioco con exit 42:

```text
wrapper exit = 42
```

## Test 7 — double invocation

```text
wrapper A → lock
wrapper B → fail safe
```

## Test 8 — stale state

Stato artificiale:

```text
PHASE=STREAMING
```

Atteso:

```text
recovery
→ screen ON
→ local mode
→ state cleared
```

## Test 9 — Steam Link reale

Verificare nei log Steam:

```text
setting capture size 1920x1200
CLIENT: Video rect: 1920x1200 at 0,0
```

e verificare separatamente:

```text
DRM/Gamescope = 1920×1200@60
Stream = 60 FPS target/effective
```

---

# 33. TEST UNITARI DA DEFINIRE

La struttura deve permettere test senza hardware reale.

Componenti da testare:

```text
Steam log parser (future)
configuration parser
mode controller
screen controller
state machine
cleanup
recovery
watchdog logic
```

Test minimi:

```text
config valida
config invalida
1920×1200 valida
1920×1080 rifiutata
mode disponibile
mode non disponibile
nudge failure
mode verification timeout
screen sleep failure
restore success
restore failure
SIGTERM
SIGINT
SIGHUP
stale state
lock contention
exit code preservation
cleanup idempotente
```

Per la versione corrente i test dell'hardware Gamescope devono rimanere test di integrazione/acceptance, perché `get_current_mode()` e `nudge_mode()` dipendono dall'ambiente reale.

---

# 34. CRITERI DI ACCETTAZIONE

Il sistema è PASS solamente se:

### R1 — stream

Durante il gioco avviato con wrapper:

```text
capture = 1920×1200
video rect = 1920×1200 at 0,0
```

### R2 — monitor

Durante la sessione:

```text
monitor fisico = OFF
```

Al termine:

```text
monitor fisico = ON
```

### R3 — recovery

Il restore deve essere verificato dopo:

```text
normal exit
SIGTERM
SIGINT
SIGHUP
stale state
service/session interruption compatibile con il wrapper
```

### R4 — utilizzo

Nessun intervento manuale durante il gioco.

Una sola Launch Option iniziale.

### R5 — sicurezza

Non deve mai essere raggiunto uno stato stabile:

```text
SCREEN OFF
+
STREAM NOT ACTIVE/VALID
```

---

# 35. HANDOFF PER L'ALTRO AGENT

La parte già scritta non va riscritta inutilmente.

Il lavoro da completare deve concentrarsi principalmente su:

## H1 — Verifica ambiente reale

Eseguire:

```bash
~/.local/bin/steam-link-display-adapter-verify-environment
```

Raccogliere e verificare:

```text
Gamescope info
Connector Name
Display Make
Display Model
GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL
GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK
GAMESCOPE_DISPLAY_MODE_NUDGE
X dimensions
DRM /sys/class/drm/card*-*
DP-3 modes
```

## H2 — Verificare l'accesso X/Gamescope

Determinare in Game Mode reale:

```text
DISPLAY
GAMESCOPE_DISPLAY
GAMESCOPE_WAYLAND_DISPLAY
```

e verificare che:

```bash
xprop -root
xdpyinfo
```

funzionino sul display Gamescope corretto.

Se `xprop`/`xdpyinfo` non sono il metodo corretto sulla build reale, **sostituire solo le funzioni del hook** senza cambiare il wrapper.

## H3 — Verificare il mode list

Confermare che:

```text
GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL
```

contenga realmente:

```text
1920x1200@60
```

## H4 — Verificare `modes.cfg`

Determinare la description esatta richiesta da Gamescope e verificare che il formato:

```text
<description>:1920x1200@60
```

venga effettivamente applicato.

## H5 — Verificare nudge

Verificare empiricamente:

```text
write modes.cfg
→ nudge
→ current mode
```

Il test deve dimostrare un vero cambio:

```text
3440x1440@165
        ↓
1920x1200@60
```

non solo la modifica del file di configurazione.

## H6 — Verificare screen sleep

Testare separatamente:

```bash
gamescopectl drm_sleep_external_screen 1
```

poi:

```bash
gamescopectl drm_sleep_external_screen 0
```

Confermare l'effetto sul monitor reale.

## H7 — Correggere il metodo di verifica mode se necessario

L'attuale implementazione utilizza:

```text
xdpyinfo dimensions
+
GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK
```

Se questi valori non rappresentano realmente il DRM mode corrente sulla Bazzite in uso, sostituire:

```text
get_current_mode()
is_target_mode_active()
is_local_mode_active()
```

con un metodo realmente affidabile.

## H8 — Non spegnere il monitor senza verifica

Non modificare questa regola:

```text
TARGET MODE VERIFIED
        ↓
SCREEN SLEEP
```

## H9 — Conservare fail-safe

Se H5 non funziona in modo affidabile, il wrapper deve rimanere fail-closed.

Non trasformarlo in:

```text
nudge
→ sleep
→ hope
```

---

# 36. REGOLA OPERATIVA PER IL MODE SWITCH

La sequenza obbligatoria rimane:

```text
1. verifica target mode disponibile
2. backup modes.cfg
3. aggiorna modalità temporanea
4. abilita dynamic modes
5. nudge Gamescope
6. polling
7. verifica 1920×1200@60
8. solo ora screen sleep
9. avvia gioco
```

Per il restore:

```text
1. wake monitor
2. restore modes.cfg
3. nudge Gamescope
4. polling
5. verifica 3440×1440@165
6. disable dynamic modes
7. clear state
8. return exit code
```

---

# 37. REGOLA DI SICUREZZA ASSOLUTA

Invariant:

```text
screen_off == true
        ⇒
stream_mode_verified == true
```

e dopo il cleanup:

```text
cleanup_finished
        ⇒
monitor_on == true
```

Il wrapper non deve mai sacrificare la sicurezza del display pur di avviare il gioco.

---

# 38. DEFINITION OF DONE

La prima versione è completata quando:

```text
[ ] P1A — 1920×1200@60 esiste nel DRM
[ ] H2 — Gamescope X/control access verified
[ ] H4 — modes.cfg description verified
[ ] H5 — runtime mode switch verified
[ ] H6 — screen sleep/wake verified
[ ] R1 — Steam capture 1920×1200
[ ] R1 — Video rect 1920×1200 at 0,0
[ ] R2 — monitor OFF during game
[ ] R2 — monitor ON after exit
[ ] R3 — cleanup after signals
[ ] R4 — one Launch Option, no manual interaction
[ ] R5 — never leave screen OFF without valid streaming state
[ ] unit tests added
[ ] integration tests passed
[ ] acceptance test passed
```

---

# 39. FILE OPERATIVI GENERATI

Il pacchetto iniziale contiene:

```text
steam-link-display-adapter/steam-link-display-adapter.sh
steam-link-display-adapter/steam-link-display-adapter-hook.sh
steam-link-display-adapter/steam-link-display-adapter-verify-environment.sh
steam-link-display-adapter/steam-link-display-adapter-restore.sh
steam-link-display-adapter/steam-link-display-adapter.conf.example
steam-link-display-adapter/install.sh
```

## Launch Option

```text
/home/USER/.local/bin/steam-link-display-adapter %command%
```

## Diagnostica

```bash
~/.local/bin/steam-link-display-adapter-verify-environment
```

## Recovery manuale

```bash
~/.local/bin/steam-link-display-adapter-restore
```

---

# 40. STATO DELL'IMPLEMENTAZIONE

La parte implementabile in modo indipendente dall'ambiente reale è già isolata:

```text
✓ wrapper lifecycle
✓ launch option integration
✓ configuration
✓ flock
✓ persistent state
✓ stale recovery framework
✓ modes.cfg backup/restore
✓ signal cleanup
✓ exit code preservation
✓ logging
✓ read-only environment diagnostic
✓ manual restore helper
✓ installer
```

Rimane da completare/verificare sulla Bazzite reale:

```text
→ exact Gamescope display access
→ exact connector description
→ actual current-mode probing
→ actual runtime mode switch
→ actual screen sleep effect
```

Questi punti sono deliberatamente isolati in `steam-link-display-adapter-hook.sh`.

---

# 41. PRINCIPIO FINALE

L'implementazione deve rimanere semplice e per-game:

```text
STEAM GAME
   │
   ▼
WRAPPER
   │
   ├── 1920×1200
   ├── 16:10
   ├── 60 Hz
   ├── target 60 FPS
   └── monitor OFF
          │
          ▼
        GAME
          │
          ▼
       CLEANUP
          │
          ├── monitor ON
          ├── 3440×1440
          └── restore configuration
```

Il wrapper deve restare **fail-safe, idempotente e verificabile**, mentre la sola parte da adattare all'ambiente concreto rimane l'integrazione Gamescope/DRM.
