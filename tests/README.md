# Test suite

The project uses two complementary test layers.

## Unit / contract tests

`tests/unit/run-tests.sh` sources the real production modules and isolates
external commands through the existing stubs. It protects module contracts for:

- display/DRM mode discovery and verification;
- runtime connector resolution;
- dynamic resolution selection and boundary cases;
- Steam Link capture-hint parsing and stream-signal detection;
- host-profile discovery and state persistence;
- Xwayland server mapping, synchronization and restore;
- `modes.cfg` snapshot/update/restore;
- configuration validation;
- system dependency checks, logging and locking.

Run:

```bash
bash tests/unit/run-tests.sh
```

## Integration / regression tests

`tests/run-tests.sh` remains the end-to-end hardware-free suite. It protects
the complete workflow and historically fragile behavior: first connection,
launch races, target resolution, Xwayland ordering, cleanup, stale recovery,
signals, failure paths, host-agnostic behavior, CLI contract, installer layout
and known regressions.

Run:

```bash
bash tests/run-tests.sh
```

## Full suite

Use this command locally and in CI:

```bash
bash tests/run-all-tests.sh
```

The suite does not require a real monitor, Gamescope session, Steam installation
or game. All external state is redirected into temporary sandboxes.
