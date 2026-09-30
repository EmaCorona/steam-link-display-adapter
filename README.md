# Steam Link Display Adapter

> Dynamic display adaptation for Steam Remote Play on Bazzite Game Mode and KDE Plasma Desktop Mode.

Steam Link can request a different resolution and aspect ratio than the host's physical display.

The adapter is **host-agnostic**: the active display backend, its connector, current mode and
available modes are discovered **at runtime**. Game Mode uses Gamescope; Desktop Mode uses KDE/KScreen.
The host display does not need to be configured. The client resolution comes from Steam Remote Play;
the host capabilities come from the backend that is active at runtime.

This wrapper temporarily adapts the active display backend to the Steam Link client's resolution and
restores the original host state when the session ends. In Game Mode it also synchronizes Xwayland #1
and can sleep the physical display; Desktop Mode changes the KDE output mode through KScreen without
Gamescope or Xwayland changes.

**No root, no changes to Steam, Proton, Wine or DXVK/VKD3D: it is a per-game Launch Option.**

## What it solves

A host whose display geometry differs from the client's is the typical case:

```text
Host display (any)
    whatever the display advertises

        ↓

Steam Link client
    requested resolution / aspect

        ↓

without adaptation
    wrong capture geometry

        ↓

steam-link-display-adapter

        ↓

temporary host adaptation
    client geometry at a host-compatible mode

        ↓

Steam capture
    matches client

        ↓

session ends
    original host state restored
```

The same flow works with any supported host display — for example a `3440×1440` ultrawide, a
`2560×1440` or a `3840×2160` panel — without editing the configuration: the active connector,
current mode and available modes are discovered at runtime from Gamescope/DRM or KDE/KScreen.

You do not need to know what Gamescope, Xwayland, DRM or PipeWire are to use it: those details live in
[`docs/`](docs/).

## Highlights

### Host-agnostic display

The active display backend is discovered at runtime and is never hard-coded:

```text
Gamescope / DRM              KDE / KScreen
    connector                   output
    current mode                current mode
    display description         display output
    available modes             available modes
             \                 /
              \               /
               host capabilities
                     ↓
               runtime target
```

Gamescope is selected when a Gamescope session is available; otherwise the KDE/KScreen backend is used
in Desktop Mode. Connector, original mode and (in Game Mode) the original Xwayland #1 geometry are
discovered at runtime, saved in the run state and used for the restore: the same installation works on
different machines and between Game Mode and Desktop Mode without configuration edits.


### Dynamic client resolution

The target is not hard-coded; it follows what the Steam Link client declares it can capture:

```text
Maximum capture: WxH FPS
        ↓
mode resolver
        ↓
host-compatible target
```

The resolver weighs aspect ratio, resolution, refresh rate, pixel difference and the client framerate
against the modes advertised by the active display backend.


### Race-condition handling

The project does **not** assume the Steam Link session is already up when the game is launched, in
either Game Mode or Desktop Mode.

```text
launch game
    ↓
Steam Link session appears shortly after
    ↓
event-driven detection
    ↓
display preparation
```

Detection is event-driven with a bounded window and a real state re-check, so a session that appears
just after the launch is still caught.

### State machine

The workflow is an explicit sequence, which is what makes preparation, launch, cleanup and recovery
predictable:

```text
RECOVER
   ↓
DETECT
   ↓
VALIDATE
   ↓
HOST PROFILE
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

### Xwayland synchronization

Game Mode keeps the display output and the game's Xwayland #1 server as **two distinct states**:

```text
Gamescope output
       +
Xwayland #1
       ↓
same target geometry
```

The game is launched only after the Xwayland synchronization is confirmed.

Desktop Mode has no Gamescope Xwayland control contract, so the backend changes the KDE output mode
through KScreen and launches the game without an Xwayland mode synchronization step.


### Fail-closed design

Deliberately conservative:

```text
target not verified
        ↓
no display sleep
no game launch
```

The priority is to never leave the system in a partially modified state.

### Crash / stale-state recovery

```text
previous run interrupted
        ↓
stale state detected
        ↓
conservative recovery (saved host profile)
        ↓
normal execution
```

### Hardware-free testing

```bash
bash tests/run-tests.sh
```

The suite does not require:

```text
- a real monitor
- a real Gamescope session
- a real KDE/KScreen session
- a real Steam installation
- a real game
```

## Quick start

```bash
git clone https://github.com/EmaCorona/steam-link-display-adapter.git
cd steam-link-display-adapter
./install.sh
```

Then, in Steam → the game → **Properties → Launch Options**:

```text
/home/USER/.local/bin/steam-link-display-adapter %command%
```

Advanced configuration is optional (see [Configuration](#configuration)).

## Requirements

### Platform

```text
Bazzite
Gaming Mode (Gamescope) or Desktop Mode (KDE Plasma)
Steam Remote Play / Steam Link
```

### System tools

```text
gamescopectl (Game Mode)
xprop / xdpyinfo (Game Mode)
kscreen-doctor (Desktop Mode)
journalctl (Game Mode)
pactl / pw-cli
flock
```

The target mode must exist in the mode set advertised by the active display backend: in Game Mode,
the candidates come from Gamescope/DRM; in Desktop Mode the active KDE output and its advertised modes
come from `kscreen-doctor`. Read-only check for a DRM connector — replace `HDMI-A-1` with the
connector reported by `steam-link-display-adapter-verify-environment`:

```bash
cat /sys/class/drm/card*-HDMI-A-1/modes
```

## How it works

```text
Steam Link client
        │
        ▼
Session detection
        │
        ▼
Host profile discovery
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
        ├── Game Mode
        │     ├── Gamescope output
        │     └── Xwayland #1
        │
        └── Desktop Mode
              └── KDE/KScreen output
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

### Without an active Steam Link session

```text
Steam Link active
    → display pipeline enabled

Steam Link inactive
    → game launched normally
```

In both Desktop Mode and Game Mode, when no stream is active after the bounded detection window, the
display is left untouched and the game is launched normally.

## Launch Option

Steam → Game → **Properties → Launch Options**:

```text
steam-link-display-adapter %command%
```

The Launch Option only activates the adapter: the target is resolved dynamically from the Steam Link
client against the modes the host really advertises. The display target is never chosen from the
command line.


## Dynamic resolution

The target is recomputed for every session against the modes the host really advertises:

```text
Client A (16:10) on a 3440×1440 host
   ↓
1920×1200 target

Client B (16:9) on a 2560×1440 host
   ↓
1920×1080 target

Client C (16:10) on a 3840×2160 host
   ↓
best compatible 16:10 host mode

No client hint available
   ↓
original host mode (host-safe fallback)
```


## Safety & recovery

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

The fundamental rules:

```text
No original host profile captured
→ no display modification

No verified target
→ no display modification
→ no game launch

Game Mode
→ synchronize Xwayland #1
→ sleep the physical display only after the target is verified
→ restore the display on cleanup

Desktop Mode
→ change only the KDE output mode
→ leave the physical display powered
→ restore the original mode on cleanup
```

And for an interrupted session:

```text
Interrupted session
→ stale-state recovery
→ restore original configuration
```

## Configuration

```bash
CONNECTOR='auto'
STREAM_MODE='auto'
```

The host display does not need to be configured: connector and current mode are detected at runtime.
In Game Mode, `CONNECTOR='auto'` follows the connector selected by Gamescope; in Desktop Mode it
follows the active KDE/KScreen output. A manual override (for example `'HDMI-A-1'`) is verified against
the active output/connector, otherwise the wrapper fails closed without touching the display. In Game
Mode the original Xwayland #1 geometry is also captured at runtime. `STREAM_*` values (fallback /
fixed) are optional preferences.

The complete list of options is in
[`config/steam-link-display-adapter.conf.example`](config/steam-link-display-adapter.conf.example).
An existing user configuration is never overwritten by the installer.

## Diagnostics

```bash
steam-link-display-adapter-verify-environment
steam-link-display-adapter-restore
```

```text
Logs:
~/.local/state/steam-link-display-adapter/
```

The same directory also holds the transient run state, the lock and (when applicable) the `modes.cfg`
snapshot.

## Project structure

```text
bin/       entrypoints (public commands): paths, module loading, invocation
lib/       internal library, one area per responsibility
  core/        orchestration (workflow, CLI, configuration, loader)
  detection/   environment state (Steam Link session, Gamescope)
  display/     backend selection, Gamescope/KMS and KDE/KScreen output control,
               connector identity, host profile and modes
  resolution/  which mode to use (resolver)
  xwayland/    Xwayland #1 server
  state/       run state, modes.cfg snapshot, lock
  system/      system primitives
  logging/     log and events
config/    configuration template
tests/     test suite and stubs
docs/      documentation (technical/)
```

Dependency direction: `bin → core → domain modules → system primitives`. Files under `lib/` are not
executable: they are loaded with `source` through the single loader in `lib/core/bootstrap.sh`.

## Documentation

```text
docs/technical/    implementation details, measurements and deviations
```


## Limitations

- Detection is bounded (default 5 s window). When no stream is currently active, launching the game can
  wait up to that window in both Game Mode and Desktop Mode so a newly established Steam Link session
  can be detected.
- The client hint is read once, before preparing the session, and only if it is recent (default 10 s):
  the target does not change while a stream is already running.
- If the client mode does not exist on the host, the resolver picks an aspect-compatible mode (or the
  configured fallback), never an arbitrary one: the target resolution must be supported by the active
  display backend's mode set, or a compatible host mode must exist.
- Without a usable client hint, `auto` targets the original host mode (host-safe fallback) instead of a
  configured value.
- No cleanup after `SIGKILL`, panic or power loss: the leftover state is recovered at the next launch.
- The UI stream alone (Big Picture before the game starts) is not switched; the wrapper acts from the
  game launch.
