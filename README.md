# Steam Link Display Adapter

> Dynamic display adaptation for Steam Remote Play on Bazzite Game Mode and KDE Plasma Desktop Mode.

Steam Link can request a different resolution and aspect ratio than the host's physical display.
This can cause the host and the stream to use different capture geometries, especially when streaming
from an ultrawide or another display with a different aspect ratio.

The adapter solves this by temporarily adapting the host **only while a Steam Link session is active**.
It detects the client capture resolution automatically, selects the appropriate host target, prepares
the display for streaming and removes the physical display from the local presentation path so Steam
can capture the correct geometry.

In **Game Mode**, Gamescope is switched to the resolved client-compatible mode, the game's Xwayland #1
server is synchronized to the same geometry and the physical monitor is put to sleep for the duration
of the stream. In **Desktop Mode**, the adapter creates a dedicated KWin virtual output at the exact
client geometry, makes it the streaming output and temporarily disables the physical output instead.
This avoids changing the user's physical monitor to a mode that may not match the client.

When the game/stream ends, the adapter restores the original host state — including the physical display,
its mode and layout, and the Game Mode Xwayland #1 geometry when applicable. When no Steam Link session
is detected, the adapter leaves the display untouched and launches the game normally.

The entire process is automatic: the client resolution is discovered from Steam Remote Play, the host
capabilities are discovered at runtime from Gamescope/DRM or KDE/KScreen, and the original state is saved
before any modification.

**No root, no changes to Steam, Proton, Wine or DXVK/VKD3D: it is a per-game Launch Option.**

## 20-second guide

### 1. Install

From a terminal:

```bash
git clone https://github.com/EmaCorona/steam-link-display-adapter.git
cd steam-link-display-adapter
./install.sh
```

The installer places the adapter and its internal modules under `~/.local/bin` and `~/.local/lib/steam-link-display-adapter/`, creates the user configuration when it does not already exist, and does not require root.

### 2. Verify the environment

Run:

```bash
steam-link-display-adapter-verify-environment
```

The command checks the display backend and the runtime tools required by the current session. On Bazzite, the normal platform components are provided by the OS; the installer does not replace the system package manager or install unrelated desktop components.

### 3. Add one Launch Option

In Steam → the game → **Properties → Launch Options**:

```text
steam-link-display-adapter %command%
```

That's it.

### What happens when you stream

Without Steam Link, the game starts normally and the display is untouched.

With Steam Link, the adapter detects the active client capture geometry and temporarily prepares the host display for it:

```text
Steam Link client
      ↓
detect client resolution / FPS
      ↓
resolve a host-compatible target
      ↓
prepare display
      ↓
launch game
      ↓
Steam capture
      ↓
stream ends
      ↓
restore original display state
```

**Game Mode:** Gamescope switches to the resolved geometry, Xwayland #1 is synchronized to the same game geometry, and the physical display is put to sleep for the stream.

**Desktop Mode:** a dedicated KWin virtual output is created at the exact client geometry, selected as the streaming output, and the physical output is disabled for the session. The virtual display is isolated from the host network through a user systemd namespace; when that isolation cannot be established, the stream path is refused instead of exposing the VNC listener.

After the session ends, the adapter restores the original display configuration automatically. If the process is interrupted, stale-state recovery restores the saved state on the next launch.

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
    detect client resolution automatically
    adapt the streaming geometry
    remove the physical display from the local path

        ↓

Steam capture
    matches the client geometry

        ↓

session ends
    physical display and original host state restored
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
discovered at runtime, saved in the run state and used for the restore. In Desktop Mode the complete
KScreen layout is also captured for the physical outputs, including mode, position, scale, rotation,
enabled state and primary output. The same installation therefore works on different machines and
between Game Mode and Desktop Mode without configuration edits.


### Dynamic client resolution

The target is not hard-coded; it follows what the Steam Link client declares it can capture:

```text
Maximum capture: WxH FPS
        ↓
mode resolver
        ↓
host-compatible target
```

For physical outputs, the resolver weighs aspect ratio, resolution, refresh rate, pixel difference and
the client framerate against the modes advertised by the active display backend. Desktop sessions use
a virtual output created at the requested client geometry, so the target resolution does not need to
exist in the physical monitor's mode list.


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
no physical display change
no game launch
```

The priority is to never leave the system in a partially modified state.

### Crash / stale-state recovery

```text
previous run interrupted
        ↓
stale state detected
        ↓
conservative recovery (saved host profile / Desktop layout)
        ↓
virtual display unit stopped and removed
        ↓
original host state restored
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
- a real KWin virtual display
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
krfb-virtualmonitor (Desktop Mode)
systemd-run / systemctl (Desktop Mode)
journalctl (Game Mode)
pactl / pw-cli
flock
```

For physical-output sessions, the target mode must exist in the mode set advertised by the active
display backend: in Game Mode, the candidates come from Gamescope/DRM. In Desktop Mode the virtual
stream output is created at the resolved client geometry, so that geometry is not required to be
present in the physical output's mode list; the active KDE output and its advertised modes are read
from `kscreen-doctor` for profiling and restore.

Read-only check for a DRM connector — replace `HDMI-A-1` with the
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
              └── KWin virtual stream output
                    (physical output disabled)
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
display is left untouched and the game is launched normally. The display pipeline is activated only
after the Steam Link session is confirmed, and Desktop Mode is not considered ready until
the virtual KWin output has been created and exposed through KScreen.

## Launch Option

Steam → Game → **Properties → Launch Options**:

```text
steam-link-display-adapter %command%
```

The Launch Option only activates the adapter: the target is resolved dynamically from the Steam Link
client against the modes the host really advertises. The display target is never chosen from the
command line.

The monitor behaviour is not configurable: every game uses the same display policy.

```text
Game Mode    → sleep the physical display
Desktop Mode → create a dedicated KWin virtual output at the resolved stream geometry, make it the
               primary output for the session and disable the physical output
```

Outside an active Steam Link session the monitor and display layout are never touched. The removed
`--monitor on|off` forms are rejected before any display or state change.


## Dynamic resolution

The target is recomputed for every session against the modes the host really advertises:

```text
Client A (16:10) on a 3440×1440 host
   ↓
Desktop Mode → 1920×1200 virtual output
Game Mode    → best compatible host mode

Client B (16:9) on a 2560×1440 host
   ↓
Desktop Mode → 1920×1080 virtual output
Game Mode    → best compatible host mode

Client C (16:10) on a 3840×2160 host
   ↓
Desktop Mode → requested client geometry
Game Mode    → best compatible host mode

No client hint available
   ↓
original host mode / geometry (host-safe fallback)
```


## Safety & recovery

```text
Detect
 ↓
Resolve
 ↓
Verify target
 ↓
Prepare backend
 ├─ Game Mode → sync Xwayland #1 → sleep physical display
 └─ Desktop Mode
       └─ create isolated virtual output → make primary → disable physical output
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
→ create an isolated KWin virtual stream output
→ select it for the streaming session
→ disable the physical output only after the virtual output is ready
→ restore the complete saved physical layout and remove the virtual output on cleanup
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

Desktop Mode's virtual stream path requires `krfb-virtualmonitor` and a user systemd environment
capable of running it with `PrivateNetwork=yes`. The virtual display gets a random per-run VNC password and a
free local port; neither is persisted in the run state or written to the log. The adapter verifies that
the virtual KWin output appears before making it primary or disabling the physical output, and it fails
closed when the required network isolation cannot be established. It never falls back to an exposed VNC listener, to DPMS or to a physical-mode change.

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
snapshot. Desktop virtual-display sessions additionally persist the identity of the user-systemd unit
that owns the temporary KWin output, so stale-state recovery can stop exactly the display instance it
created.

## Project structure

```text
bin/       entrypoints (public commands): paths, module loading, invocation
lib/       internal library, one area per responsibility
  core/        orchestration (workflow, CLI, configuration, loader)
  detection/   environment state (Steam Link session, Gamescope)
  display/     backend selection, Gamescope/KMS and KDE/KScreen output control,
               connector identity, host profile, modes, virtual output and layout snapshot
               (desktop-layout.sh and desktop-virtual.sh)
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
- In Game Mode, if the client mode does not exist on the host, the resolver picks an
  aspect-compatible mode (or the configured fallback), never an arbitrary one. Desktop Mode is
  different: the virtual output is created at the resolved client geometry and is not constrained by
  the physical monitor's advertised modes.
- Without a usable client hint, `auto` targets the original host mode/geometry (host-safe fallback)
  instead of a configured value.
- Desktop Mode depends on `krfb-virtualmonitor` and user-systemd network isolation;
  when either requirement is unavailable, the adapter refuses the Desktop stream path rather than
  exposing its VNC listener or silently falling back to another power-control mechanism. The virtual
  output must be created and visible in KScreen before the physical output is disabled.
- No cleanup after `SIGKILL`, panic or power loss: the leftover state is recovered at the next launch.
  Desktop virtual-display sessions also save the physical KScreen layout so mode, position, scale,
  rotation, enabled state and primary output can be restored after interruption.
- The UI stream alone (Big Picture before the game starts) is not switched; the wrapper acts from the
  game launch.
