# Local Agent

This folder is the source of truth for Tuli's agent code.

## Official Paths

- Source code: `/Users/inma/Documents/Vroid/local_agent`
- Brain lab: `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab`
- App launcher: `/Users/inma/Documents/Vroid/launch_tuli.command`
- Live app support: `~/Library/Application Support/VroidOverlay`
- Live runtime copy: `~/Library/Application Support/VroidOverlay/local_agent_runtime`
- Live LaunchAgent label: `com.inma.vroid.localagent`

## Canonical Flow

1. Edit source files in this repo.
2. Sync source to the live runtime copy.
3. Restart or reinstall the LaunchAgent if needed.
4. Launch the app through `launch_tuli.command`.

## Commands

Sync the runtime copy:

```bash
bash local_agent/sync_runtime.sh
```

Install or refresh the background agent:

```bash
bash local_agent/install_launch_agent.sh
```

Remove the background agent:

```bash
bash local_agent/uninstall_launch_agent.sh
```

Inspect the current live setup:

```bash
bash local_agent/status.sh
```

Run one test event from source:

```bash
python3 local_agent/run_once_test.py morning_greeting
```

Run the source daemon in the foreground:

```bash
python3 local_agent/vroid_agent_daemon.py
```

## Notes

- The live app should use `~/Library/Application Support/VroidOverlay/local_agent_runtime`, not `Documents/Vroid/local_agent` directly.
- `openclaw_vroid_bridge.py` is synced both to app support root and to the runtime copy.
- `agent_state.json` and runtime logs stay out of source control and are not overwritten during sync.
