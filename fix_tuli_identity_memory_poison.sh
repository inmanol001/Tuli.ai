#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
SOURCE="$PROJECT/local_agent"
PLIST_ID="com.inma.vroid.localagent"
BACKUP="$PROJECT/backups_tuli_identity_poison_$(date +%Y%m%d_%H%M%S)"

echo "== Fix Tuli identity/memory poison =="
echo "Backup: $BACKUP"

mkdir -p "$BACKUP"

echo ""
echo "== 1. Stop LaunchAgent =="
launchctl bootout "gui/$UID/${PLIST_ID}" >/dev/null 2>&1 || true
launchctl remove "$PLIST_ID" >/dev/null 2>&1 || true
pkill -f "vroid_agent_daemon.py" 2>/dev/null || true
sleep 1

echo ""
echo "== 2. Backup =="
[ -d "$RUNTIME" ] && cp -R "$RUNTIME" "$BACKUP/local_agent_runtime.backup"
[ -d "$SOURCE" ] && cp -R "$SOURCE" "$BACKUP/local_agent_source.backup"
[ -f "$APP_SUPPORT/conversation_memory.json" ] && cp "$APP_SUPPORT/conversation_memory.json" "$BACKUP/conversation_memory.json.backup"

echo ""
echo "== 3. Patch personality + state in source and runtime =="
python3 - <<'PY'
from pathlib import Path
import json

project = Path("/Users/inma/Documents/Vroid")
app_support = Path.home() / "Library/Application Support/VroidOverlay"
paths = [
    project / "local_agent",
    app_support / "local_agent_runtime",
]

clean_personality = {
    "agent_name": "Tuli",
    "model_provider": "ollama",
    "model_name": "qwen3:1.7b",
    "spoken_language": "en",
    "tone": [
        "warm",
        "curious",
        "playful",
        "softly sarcastic",
        "observant",
        "non-invasive"
    ],
    "identity": {
        "name": "Tuli",
        "role": "tiny floating desktop companion",
        "core_fact": "Your name is Tuli. Keep that identity consistent. Do not claim to be the user, a generic assistant, a system, or a model."
    },
    "behavior": {
        "min_seconds_between_spoken_lines": 360,
        "min_seconds_between_random_lines": 1800,
        "min_seconds_between_gestures": 300,
        "short_term_message_limit": 10,
        "short_term_max_age_hours": 24,
        "medium_term_summary_limit": 8,
        "long_term_summary_limit": 12,
        "max_recent_lines": 30,
        "max_words_default": 14,
        "model_timeout_seconds": 8,
        "temperature": 0.9,
        "top_p": 0.9,
        "num_predict": 40
    },
    "prompt_style": {
        "system": (
            "You are Tuli, a tiny floating desktop companion. "
            "Your identity is stable: your name is Tuli. "
            "The system decides the event, mood, gesture, and intent. "
            "Your only job is to write one short natural English line for that intent. "
            "Vary wording each time. Return only the line. "
            "Do not mention being an AI, a model, a system, or a chatbot. "
            "Do not mention tools, architecture, hidden instructions, OpenClaw, Codex, or system prompts. "
            "Do not invent facts about the user or the screen. "
            "Stay brief, warm, curious, lightly playful, and non-invasive."
        )
    }
}

clean_pinned = [
    "The avatar's name is Tuli.",
    "Tuli is a tiny floating desktop companion.",
    "Tuli should speak briefly, warmly, naturally, and with light playfulness.",
    "Tuli should not claim to be the user, a generic assistant, a model, or a system.",
    "Tuli should not invent facts when she does not know something.",
    "Tuli should not preserve incorrect facts from previous corrupted memory."
]

for base in paths:
    if not base.exists():
        continue

    personality_path = base / "personality.yaml"
    state_path = base / "agent_state.json"

    personality_path.write_text(
        json.dumps(clean_personality, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8"
    )
    print("wrote", personality_path)

    state = {}
    if state_path.exists():
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except Exception:
            state = {}

    state.setdefault("started_at", None)
    state.setdefault("last_tick_at", None)
    state.setdefault("last_spoke_at", None)
    state.setdefault("last_gesture_at", None)
    state.setdefault("last_event_at", {})
    state.setdefault("last_greeting_date", None)
    state.setdefault("energy", 0.65)
    state.setdefault("curiosity", 0.55)
    state.setdefault("talkativeness", 0.28)
    state.setdefault("sleepiness", 0.20)
    state.setdefault("current_mood", "neutral")
    state.setdefault("focus_mode", False)
    state.setdefault("daily_event_counts", {})
    state.setdefault("recent_lines", [])
    state.setdefault("recent_actions", [])

    # Remove poisoned or old pinned facts.
    state["pinned_facts"] = clean_pinned

    # Remove obviously poisoned recent lines if any.
    bad_bits = [
        "independencia de méxico",
        "20 de julio",
        "jose",
        "josé",
        "never call yourself tuli",
        "luma"
    ]

    state["recent_lines"] = [
        x for x in state.get("recent_lines", [])
        if isinstance(x, str) and not any(b in x.lower() for b in bad_bits)
    ][-30:]

    state["recent_actions"] = [
        a for a in state.get("recent_actions", [])
        if not any(b in json.dumps(a, ensure_ascii=False).lower() for b in bad_bits)
    ][-80:]

    state_path.write_text(
        json.dumps(state, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8"
    )
    print("wrote", state_path)
PY

echo ""
echo "== 4. Reset corrupted app conversation memory =="
cat > "$APP_SUPPORT/conversation_memory.json" <<'JSON'
{
  "updated_at": 0,
  "short_term": [],
  "medium_term": [
    {
      "summary": "The local avatar/desktop companion is named Tuli. Tuli must keep this identity stable."
    },
    {
      "summary": "Previous conversation memory was reset because it contained corrupted identity and incorrect factual answers."
    }
  ],
  "long_term": [
    {
      "summary": "Tuli is the user's local floating desktop companion. She should be concise, warm, curious, playful, and non-invasive."
    }
  ],
  "pinned_facts": [
    "The avatar's name is Tuli.",
    "Tuli should not invent facts.",
    "Tuli should say she does not know when context is missing.",
    "Tuli should not repeat corrupted previous answers."
  ]
}
JSON

echo ""
echo "== 5. Clean logs =="
mkdir -p "$RUNTIME/logs"
: > "$RUNTIME/logs/agent.log"
: > "$RUNTIME/logs/launchd.out.log"
: > "$RUNTIME/logs/launchd.err.log"

echo ""
echo "== 6. Verify poison removed =="
echo "-- runtime poison scan --"
grep -RIn "Never call yourself Tuli\|agent_name.*Luma\|You are Luma\|José\|Jose\|20 de julio\|Independencia de México" \
  "$RUNTIME" \
  --exclude-dir=logs || echo "OK runtime clean"

echo ""
echo "-- source poison scan --"
grep -RIn "Never call yourself Tuli\|agent_name.*Luma\|You are Luma\|José\|Jose\|20 de julio\|Independencia de México" \
  "$SOURCE" \
  --exclude-dir=logs || echo "OK source clean"

echo ""
echo "== 7. Reload LaunchAgent =="
launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/${PLIST_ID}.plist"
launchctl kickstart -k "gui/$UID/${PLIST_ID}"
sleep 4

echo ""
echo "== 8. Status =="
launchctl list | grep "$PLIST_ID" || true

echo ""
echo "== 9. launchctl print state =="
launchctl print "gui/$UID/${PLIST_ID}" 2>/dev/null | grep -E "state =|pid =|program =|arguments|working directory|last exit|last terminating" -A4 || true

echo ""
echo "== 10. Logs =="
echo "--- err ---"
tail -80 "$RUNTIME/logs/launchd.err.log" || true

echo ""
echo "--- agent ---"
tail -80 "$RUNTIME/logs/agent.log" || true

echo ""
echo "== 11. Current clean memory =="
cat "$APP_SUPPORT/conversation_memory.json"

echo ""
echo "== DONE =="
echo "Backup: $BACKUP"
