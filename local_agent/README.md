# Local Agent

This folder contains the first local autonomy layer for VroidOverlay.

## Files

- `personality.yaml`: voice, tone, and model settings.
- `schedules.json`: event windows and cooldowns.
- `phrase_templates.json`: fallback lines when the model is unavailable.
- `agent_state.json`: persisted runtime state.
- `vroid_agent_daemon.py`: the scheduler and decision loop.
- `send_event.py`: pushes spoken or silent events to the avatar stream.
- `run_once_test.py`: runs one scheduled event and exits.
- `install_launch_agent.sh`: installs the daemon as a macOS LaunchAgent.
- `uninstall_launch_agent.sh`: removes the LaunchAgent.

## Quick Start

Run one test event:

```bash
python3 local_agent/run_once_test.py morning_greeting
```

Run the daemon in the foreground:

```bash
python3 local_agent/vroid_agent_daemon.py
```

Install the background agent:

```bash
bash local_agent/install_launch_agent.sh
```

Remove it:

```bash
bash local_agent/uninstall_launch_agent.sh
```

## Notes

- Conversation memory is layered into short-term messages, medium-term summaries, and long-term summaries.
- Older context is compacted automatically as it ages.
- Spoken lines go through `openclaw_vroid_bridge.py`.
- Silent gesture events are written directly to the JSONL event stream.
- Logs are written to `local_agent/logs/agent.log`.
