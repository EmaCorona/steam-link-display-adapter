# Steam Link Display Adapter

> Dynamic display adaptation for Steam Remote Play on Bazzite/Game Mode.

Steam Link can request a different resolution and aspect ratio than the host's physical display.

The adapter is **host-agnostic**: the active Gamescope display, its current mode and its available
modes are discovered **at runtime**. The host display does not need to be configured. The client
resolution comes from Steam Remote Play; the host resolution comes from Gamescope/DRM.

This wrapper temporarily adapts Gamescope to the Steam Link client's resolution, synchronizes Xwayland
and restores the original host state when the session ends.

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

The same flow works with any host — for example a `3440×1440` ultrawide, a `2560×1440` or a `3840×2160`
panel — without editing the configuration: connector, current mode and available modes are discovered
at runtime.

You do not need to know what Gamescope, Xwayland, DRM or PipeWire are to use it: those details live in
[`docs/`](docs/).

## Highlights

### Host-agnostic display

The host display is never configured manually and never assumed:

```text
Gamescope / DRM
    connector
    current mode
    display description
    available modes
        ↓
host capabilities
        ↓
runtime target
```

Connector, original mode and the original Xwayland geometry are discovered at runtime, saved in the run
state and used for the restore: the same installation works on different machines with no configuration
edits.


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

The display output and the game's Xwayland server are **not** treated as the same entity:

```text
Gamescope output
       +
Xwayland #1
       ↓
same target geometry
```

The game is launched only after the synchronization is confirmed.


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

The target mode must exist in the mode set of the active connector (for example `video=DP-1:1920x1080@60`
on the kernel command line). Read-only check — replace the connector with the one reported by
`steam-link-display-adapter-verify-environment`:

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

The host display does not need to be configured: connector, current mode and the original Xwayland
geometry are detected at runtime. `CONNECTOR='auto'` follows the connector selected by Gamescope; a
manual override (for example `'HDMI-A-1'`) is verified against the active connector, otherwise the
wrapper fails closed without touching the display. `STREAM_*` values (fallback / fixed) are optional
preferences.

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
  display/     connector identity, host profile and DRM modes
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

- Detection is bounded (default 5 s window). In Desktop Mode the launch stays immediate; in Game Mode
  with no stream the launch waits at most for that window.
- The client hint is read once, before preparing the session, and only if it is recent (default 10 s):
  the target does not change while a stream is already running.
- If the client mode does not exist on the host, the resolver picks an aspect-compatible mode (or the
  configured fallback), never an arbitrary one: the target resolution must be supported by the host's
  Gamescope/DRM mode set, or a compatible host mode must exist.
- Without a usable client hint, `auto` targets the original host mode (host-safe fallback) instead of a
  configured value.
- No cleanup after `SIGKILL`, panic or power loss: the leftover state is recovered at the next launch.
- The UI stream alone (Big Picture before the game starts) is not switched; the wrapper acts from the
  game launch.
