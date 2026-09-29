# steam-link-display-adapter

> Dynamic display adaptation for Steam Remote Play on Bazzite/Game Mode.

Steam Link can request a different resolution and aspect ratio than the host's physical display.

This wrapper temporarily adapts Gamescope to the Steam Link client's resolution, synchronizes Xwayland
and restores the original state when the session ends.

**No root, no changes to Steam, Proton, Wine or DXVK/VKD3D: it is a per-game Launch Option.**

## What it solves

A host with an ultrawide monitor serving a handheld is the typical case:

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

        ↓

session ends
    original state restored
```

You do not need to know what Gamescope, Xwayland, DRM or PipeWire are to use it: those details live in
[`docs/`](docs/).

## Highlights

### Dynamic client resolution

The target is not hard-coded; it follows what the Steam Link client declares it can capture:

```text
Maximum capture: WxH FPS
        ↓
mode resolver
        ↓
host-compatible target
```

The resolver weighs aspect ratio, resolution, refresh rate, pixel difference and the client framerate.

Details: [`docs/analysis/ANALISI-RISOLUZIONE-DINAMICA.md`](docs/analysis/ANALISI-RISOLUZIONE-DINAMICA.md).

### Race-condition handling

The project does **not** assume the Steam Link session is already up when the game is launched.

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

The display output and the game's Xwayland server are **not** treated as the same entity:

```text
Gamescope output
       +
Xwayland #1
       ↓
same target geometry
```

The game is launched only after the synchronization is confirmed.

Details: [`docs/analysis/ANALISI-XWAYLAND-1.md`](docs/analysis/ANALISI-XWAYLAND-1.md).

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
conservative recovery
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
~/.local/bin/steam-link-display-adapter %command%
```

Advanced configuration is optional (see [Configuration](#configuration)).

## Requirements

### Platform

```text
Bazzite
Gaming Mode
Gamescope
Steam Remote Play / Steam Link
```

### System tools

```text
gamescopectl
xprop
xdpyinfo
journalctl
pactl / pw-cli
flock
```

The target mode must exist in the kernel ModeDB of the connector (for example `video=DP-3:1920x1200@60`
on the kernel command line). Read-only check:

```bash
cat /sys/class/drm/card*-DP-3/modes
```

## How it works

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

### Without an active Steam Link session

```text
Steam Link active
    → display pipeline enabled

Steam Link inactive
    → game launched normally
```

In Desktop Mode, or in Game Mode with no stream running, the display is left untouched.

## Modes

### Auto

```text
steam-link-display-adapter %command%
```

The target is resolved dynamically from the Steam Link client.

### Explicit auto

```text
steam-link-display-adapter --mode auto %command%
```

### Fixed resolution

```text
steam-link-display-adapter --mode 1920x1200 %command%
```

`--mode WxH` fixes the geometry; the refresh rate is selected automatically.

Details: [`docs/analysis/ANALISI-CLI-MODE.md`](docs/analysis/ANALISI-CLI-MODE.md).

## Dynamic resolution

The target is recomputed for every session:

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

Details: [`docs/analysis/ANALISI-RISOLUZIONE-DINAMICA.md`](docs/analysis/ANALISI-RISOLUZIONE-DINAMICA.md).

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

The fundamental rule:

```text
No verified target
→ no display modification
→ no game launch
```

And for an interrupted session:

```text
Interrupted session
→ stale-state recovery
→ restore original configuration
```

## Configuration

```bash
STREAM_MODE='auto'

STREAM_WIDTH=1920
STREAM_HEIGHT=1200
STREAM_REFRESH=60
STREAM_FPS=60
```

`STREAM_*` values are used as fallback / fixed mode configuration.

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

The same directory also holds the transient run state, the lock and the `modes.cfg` snapshot.

## Project structure

```text
bin/       entrypoints (public commands): paths, module loading, invocation
lib/       internal library, one area per responsibility
  core/        orchestration (workflow, CLI, configuration, loader)
  detection/   environment state (Steam Link session, Gamescope)
  display/     connector/display identity and DRM modes
  resolution/  which mode to use (resolver)
  xwayland/    Xwayland #1 server
  state/       run state, modes.cfg snapshot, lock
  system/      system primitives
  logging/     log and events
config/    configuration template
tests/     test suite and stubs
docs/      documentation (analysis/, technical/)
```

Dependency direction: `bin → core → domain modules → system primitives`. Files under `lib/` are not
executable: they are loaded with `source` through the single loader in `lib/core/bootstrap.sh`.

## Documentation

```text
docs/analysis/     the functional analyses the implementation follows
docs/technical/    implementation details, measurements and deviations
```

The analyses are kept byte-identical to the supplied documents.

### Migrating from an older installation

Earlier versions used a different namespace. These paths belong to the **old** installation and are
neither used nor created by this one:

```text
~/.config/steamlink-display/             <!-- intentional-legacy -->
~/.local/state/steamlink-display/        <!-- intentional-legacy -->
~/.local/bin/steam-link-virtual-display  <!-- intentional-legacy -->
```

The installer never deletes them automatically. Remove them manually once you are sure no old session is
still running, then reinstall with `./install.sh`.

## Limitations

- Detection is bounded (default 5 s window). In Desktop Mode the launch stays immediate; in Game Mode
  with no stream the launch waits at most for that window.
- The client hint is read once, before preparing the session, and only if it is recent (default 10 s):
  the target does not change while a stream is already running.
- If the client mode does not exist on the host, the resolver picks an aspect-compatible mode (or the
  configured fallback), never an arbitrary one.
- No cleanup after `SIGKILL`, panic or power loss: the leftover state is recovered at the next launch.
- The UI stream alone (Big Picture before the game starts) is not switched; the wrapper acts from the
  game launch.
