#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import random
import shutil
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


BASE_DIR = Path(__file__).resolve().parent
REPO_ROOT = BASE_DIR.parent
LOG_DIR = BASE_DIR / "logs"
STATE_PATH = BASE_DIR / "agent_state.json"
PERSONALITY_PATH = BASE_DIR / "personality.yaml"
SCHEDULES_PATH = BASE_DIR / "schedules.json"
TEMPLATES_PATH = BASE_DIR / "phrase_templates.json"
EVENT_BRIDGE_PATH = BASE_DIR.parent / "openclaw_vroid_bridge.py"
APP_SUPPORT_ENV = os.environ.get("VROID_APP_SUPPORT", "").strip() or os.environ.get("TULI_APP_SUPPORT_DIR", "").strip()
DEFAULT_STREAM_ROOT = Path(APP_SUPPORT_ENV).expanduser() if APP_SUPPORT_ENV else Path.home() / "Library" / "Application Support" / "VroidOverlay"
DEFAULT_STREAM_PATH = DEFAULT_STREAM_ROOT / "openclaw_stream.jsonl"
MODEL_URL = "http://localhost:11434/api/generate"
MEMORY_MODE_CONVERSATIONAL = "conversational"
MEMORY_MODE_PROGRAMMER = "programmer"
PROJECTMEM_CACHE_SECONDS = 600
PROJECTMEM_SRC_PATH = REPO_ROOT / "external" / "projectmem" / "src"
TULI_BRAIN_ROOT_CANDIDATES = [
    Path(os.environ.get("VROID_PROJECT_DIR", "").strip()).expanduser() / "local_agent" / "tuli_local_brain_lab",
    REPO_ROOT / "local_agent" / "tuli_local_brain_lab",
]

TULI_BRAIN_RESPOND = None
TULI_BRAIN_EMIT = None


def ensure_tuli_brain_imports() -> None:
    global TULI_BRAIN_RESPOND, TULI_BRAIN_EMIT
    if TULI_BRAIN_RESPOND is not None:
        return

    if APP_SUPPORT_ENV:
        os.environ.setdefault("TULI_APP_SUPPORT_DIR", APP_SUPPORT_ENV)

    for candidate in TULI_BRAIN_ROOT_CANDIDATES:
        if candidate.exists() and str(candidate) not in sys.path:
            sys.path.insert(0, str(candidate))

    try:
        from tuli_brain.actions.event_bridge import emit_response_events as _emit_response_events
        from tuli_brain.brain import respond as _respond
    except Exception as exc:  # noqa: BLE001 - continue with the legacy path if the new brain cannot be imported.
        log_line("tuli_brain_import_failed", error=str(exc))
        TULI_BRAIN_RESPOND = None
        TULI_BRAIN_EMIT = None
        return

    TULI_BRAIN_RESPOND = _respond
    TULI_BRAIN_EMIT = _emit_response_events


def ensure_dirs() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)


def now() -> dt.datetime:
    return dt.datetime.now().astimezone()


def iso(ts: Optional[dt.datetime] = None) -> str:
    return (ts or now()).isoformat(timespec="seconds")


def date_key(ts: Optional[dt.datetime] = None) -> str:
    return (ts or now()).date().isoformat()


def load_jsonish(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return default
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        try:
            import yaml  # type: ignore

            return yaml.safe_load(text)
        except Exception:
            return default


def parse_iso_datetime(value: Any) -> Optional[dt.datetime]:
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(str(value))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=now().tzinfo)
    return parsed


def normalize_memory_mode(value: Any) -> str:
    mode = str(value or "").strip().lower()
    if mode in {"programmer", "programming", "programador", "codigo", "código", "code", "coding", "dev", "developer"}:
        return MEMORY_MODE_PROGRAMMER
    return MEMORY_MODE_CONVERSATIONAL


def save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)


def load_state() -> Dict[str, Any]:
    default = load_jsonish(STATE_PATH, {})
    if not isinstance(default, dict):
        default = {}
    template = {
        "started_at": None,
        "last_tick_at": None,
        "last_spoke_at": None,
        "last_gesture_at": None,
        "last_event_at": {},
        "last_greeting_date": None,
        "energy": 0.65,
        "curiosity": 0.55,
        "talkativeness": 0.35,
        "sleepiness": 0.20,
        "current_mood": "neutral",
        "focus_mode": False,
        "daily_event_counts": {},
        "recent_lines": [],
        "recent_actions": [],
        "memory_mode": MEMORY_MODE_CONVERSATIONAL,
        "projectmem_brief_cache": {},
    }
    for key, value in template.items():
        default.setdefault(key, value)
    default["memory_mode"] = normalize_memory_mode(default.get("memory_mode"))
    if not default.get("started_at"):
        default["started_at"] = iso()
    return default


def save_state(state: Dict[str, Any]) -> None:
    save_json(STATE_PATH, state)


def load_personality() -> Dict[str, Any]:
    data = load_jsonish(PERSONALITY_PATH, {})
    return data if isinstance(data, dict) else {}


def load_schedules() -> List[Dict[str, Any]]:
    data = load_jsonish(SCHEDULES_PATH, [])
    return data if isinstance(data, list) else []


def load_templates() -> Dict[str, List[str]]:
    data = load_jsonish(TEMPLATES_PATH, {})
    return data if isinstance(data, dict) else {}


def log_line(message: str, **fields: Any) -> None:
    ensure_dirs()
    payload = {"ts": iso(), "message": message}
    payload.update({k: v for k, v in fields.items() if v is not None})
    with (LOG_DIR / "agent.log").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


def projectmem_command_candidates() -> List[Tuple[List[str], Dict[str, str]]]:
    pjm_path = shutil.which("pjm")
    if pjm_path:
        return [([pjm_path, "brief"], {})]

    env = {
        "PYTHONPATH": str(PROJECTMEM_SRC_PATH),
        "PROJECTMEM_ROOT": str(REPO_ROOT),
    }
    return [([sys.executable, "-m", "projectmem.cli", "brief"], env)]


def run_projectmem_brief() -> str:
    last_error = ""
    for command, extra_env in projectmem_command_candidates():
        env = os.environ.copy()
        env.update(extra_env)
        try:
            completed = subprocess.run(
                command,
                cwd=str(REPO_ROOT),
                env=env,
                check=False,
                capture_output=True,
                text=True,
                timeout=8,
            )
        except Exception as exc:
            last_error = str(exc)
            log_line("[PROJECTMEM] brief_command_error", command=" ".join(command), error=last_error)
            continue

        stdout = (completed.stdout or "").strip()
        stderr = (completed.stderr or "").strip()
        if completed.returncode == 0 and stdout:
            log_line("[PROJECTMEM] brief_loaded", command=" ".join(command), chars=len(stdout))
            return stdout

        last_error = stderr or stdout or f"exit={completed.returncode}"
        log_line(
            "[PROJECTMEM] brief_unavailable",
            command=" ".join(command),
            exit_code=completed.returncode,
            error=last_error[:500],
        )
    return ""


def maybe_load_projectmem_brief(state: Dict[str, Any]) -> str:
    mode = normalize_memory_mode(state.get("memory_mode"))
    if mode != MEMORY_MODE_PROGRAMMER:
        return ""

    cache = state.get("projectmem_brief_cache")
    if not isinstance(cache, dict):
        cache = {}
        state["projectmem_brief_cache"] = cache

    current = now()
    cached_text = cache.get("text")
    expires_at = parse_iso_datetime(cache.get("expires_at"))
    if isinstance(cached_text, str) and cached_text.strip() and expires_at and current < expires_at:
        return cached_text.strip()

    brief = run_projectmem_brief()
    cache["cached_at"] = iso(current)
    cache["expires_at"] = iso(current + dt.timedelta(seconds=PROJECTMEM_CACHE_SECONDS))
    cache["text"] = brief
    cache["status"] = "ok" if brief else "unavailable"
    return brief


def log_memory_mode_if_changed(state: Dict[str, Any]) -> None:
    mode = normalize_memory_mode(state.get("memory_mode"))
    previous = state.get("_last_logged_memory_mode")
    if previous != mode:
        log_line("[MODE] memory_mode", mode=mode)
        state["_last_logged_memory_mode"] = mode


def parse_hhmm(value: str) -> Tuple[int, int]:
    hour, minute = value.split(":", 1)
    return int(hour), int(minute)


def window_active(window: Any, current: dt.datetime) -> bool:
    if window == "all_day" or window is None:
        return True
    if isinstance(window, dict):
        start_s = window.get("start", "00:00")
        end_s = window.get("end", "23:59")
    else:
        return True
    start_h, start_m = parse_hhmm(str(start_s))
    end_h, end_m = parse_hhmm(str(end_s))
    start = current.replace(hour=start_h, minute=start_m, second=0, microsecond=0)
    end = current.replace(hour=end_h, minute=end_m, second=59, microsecond=999999)
    if end >= start:
        return start <= current <= end
    return current >= start or current <= end


def time_of_day(current: dt.datetime) -> str:
    hour = current.hour
    if 5 <= hour < 10:
        return "morning"
    if 10 <= hour < 13:
        return "late_morning"
    if 13 <= hour < 18:
        return "afternoon"
    if 18 <= hour < 21:
        return "evening"
    if 21 <= hour or hour < 2:
        return "night"
    return "late_night"


def mood_profile(current: dt.datetime) -> Dict[str, Any]:
    tod = time_of_day(current)
    profiles = {
        "morning": {"energy": 0.78, "curiosity": 0.56, "talkativeness": 0.42, "sleepiness": 0.18, "mood": "fresh", "focus_mode": False},
        "late_morning": {"energy": 0.72, "curiosity": 0.54, "talkativeness": 0.38, "sleepiness": 0.20, "mood": "neutral", "focus_mode": True},
        "afternoon": {"energy": 0.66, "curiosity": 0.50, "talkativeness": 0.34, "sleepiness": 0.25, "mood": "focused", "focus_mode": True},
        "evening": {"energy": 0.50, "curiosity": 0.46, "talkativeness": 0.28, "sleepiness": 0.38, "mood": "calm", "focus_mode": False},
        "night": {"energy": 0.36, "curiosity": 0.38, "talkativeness": 0.18, "sleepiness": 0.62, "mood": "sleepy", "focus_mode": False},
        "late_night": {"energy": 0.26, "curiosity": 0.32, "talkativeness": 0.10, "sleepiness": 0.80, "mood": "sleepy", "focus_mode": False},
    }
    return profiles.get(tod, profiles["afternoon"])


def smooth_update(state: Dict[str, Any], target: Dict[str, Any]) -> None:
    for key in ("energy", "curiosity", "talkativeness", "sleepiness"):
        current = float(state.get(key, target[key]))
        state[key] = round((current * 0.75) + (float(target[key]) * 0.25), 3)
    state["current_mood"] = target["mood"]
    state["focus_mode"] = bool(target["focus_mode"])


def behavior_value(personality: Dict[str, Any], key: str, default: Any) -> Any:
    behavior = personality.get("behavior", {})
    if not isinstance(behavior, dict):
        return default
    return behavior.get(key, default)


def last_event_date(state: Dict[str, Any], event_type: str) -> Optional[str]:
    mapping = state.get("last_event_at", {})
    value = mapping.get(event_type)
    if not value:
        return None
    return str(value)[:10]


def event_on_cooldown(state: Dict[str, Any], event: Dict[str, Any], current: dt.datetime) -> bool:
    last_event_map = state.get("last_event_at", {})
    last = last_event_map.get(event["event_type"])
    cooldown = int(event.get("cooldown_minutes", 0))
    if not last or cooldown <= 0:
        return False
    try:
        last_dt = dt.datetime.fromisoformat(str(last))
    except ValueError:
        return False
    return (current - last_dt).total_seconds() < cooldown * 60


def event_occured_today(state: Dict[str, Any], event: Dict[str, Any], current: dt.datetime) -> bool:
    if not event.get("once_per_day"):
        return False
    if event.get("event_type") == "morning_greeting":
        return state.get("last_greeting_date") == date_key(current)
    daily = state.get("daily_event_counts", {})
    today = daily.get(date_key(current), {})
    return int(today.get(event["event_type"], 0)) > 0


def recent_seconds(state: Dict[str, Any], key: str, default: int = 10**9) -> int:
    raw = state.get(key)
    if not raw:
        return default
    try:
        then = dt.datetime.fromisoformat(str(raw))
        return int((now() - then).total_seconds())
    except ValueError:
        return default


def normal_gesture_for_mood(mood: str) -> str:
    return {
        "fresh": "soft_nod",
        "focused": "soft_nod",
        "calm": "look_left",
        "sleepy": "slow_nod",
        "neutral": "blink",
    }.get(mood, "blink")


def choose_gesture(event: Dict[str, Any], state: Dict[str, Any]) -> str:
    gesture = event.get("gesture", "blink")
    if isinstance(gesture, list) and gesture:
        return random.choice([str(g) for g in gesture])
    if gesture == "based_on_mood":
        return normal_gesture_for_mood(str(state.get("current_mood", "neutral")))
    return str(gesture)


def base_priority(event: Dict[str, Any]) -> str:
    if event.get("once_per_day"):
        return "high"
    if event.get("event_type") in {"random_curiosity", "idle_silent_gesture"}:
        return "low"
    return "normal"


def event_score(event: Dict[str, Any], state: Dict[str, Any], current: dt.datetime, personality: Dict[str, Any]) -> float:
    spoken_gap = int(behavior_value(personality, "min_seconds_between_spoken_lines", 240))
    gesture_gap = int(behavior_value(personality, "min_seconds_between_gestures", 480))
    random_gap = int(behavior_value(personality, "min_seconds_between_random_lines", 1200))
    score = float(event.get("base_chance", 0.0))
    if event.get("speak", True):
        score *= 1.0 if recent_seconds(state, "last_spoke_at") >= spoken_gap else 0.12
    else:
        score *= 1.0 if recent_seconds(state, "last_gesture_at") >= gesture_gap else 0.35
    score *= 1.0 if float(state.get("talkativeness", 0.35)) >= 0.30 else 0.72
    if float(state.get("sleepiness", 0.2)) > 0.65 and event.get("event_type") not in {"night_sleepy_mode", "late_night_warning", "idle_silent_gesture"}:
        score *= 0.72
    if state.get("focus_mode") and event.get("event_type") in {"afternoon_focus_check"}:
        score *= 1.2
    if event.get("once_per_day") and not event_occured_today(state, event, current):
        score *= 1.35
    if event.get("event_type") == "morning_greeting" and state.get("last_greeting_date") == date_key(current):
        score *= 0.0
    if event.get("event_type") in {"random_curiosity", "save_your_work_hint", "micro_mood_event"} and recent_seconds(state, "last_spoke_at") < random_gap:
        score *= 0.5
    jitter = random.uniform(0.88, 1.12)
    score *= jitter
    return max(0.0, min(1.0, score))


def eligible_events(schedules: List[Dict[str, Any]], state: Dict[str, Any], current: dt.datetime, personality: Dict[str, Any]) -> List[Tuple[Dict[str, Any], float]]:
    result: List[Tuple[Dict[str, Any], float]] = []
    for event in schedules:
        if not window_active(event.get("window"), current):
            continue
        if event_on_cooldown(state, event, current):
            continue
        if event_occured_today(state, event, current):
            continue
        score = event_score(event, state, current, personality)
        if score <= 0:
            continue
        if random.random() < score:
            result.append((event, score))
    return result


def weighted_choice(items: List[Tuple[Dict[str, Any], float]]) -> Optional[Dict[str, Any]]:
    if not items:
        return None
    population = [item[0] for item in items]
    weights = [max(0.001, float(item[1])) for item in items]
    return random.choices(population, weights=weights, k=1)[0]


def template_for_event(event_type: str, templates: Dict[str, List[str]]) -> str:
    pool = templates.get(event_type) or templates.get("generic") or [""]
    pool = [line for line in pool if isinstance(line, str)]
    if not pool:
        return ""
    return random.choice(pool)


def clean_line(text: str, max_words: int) -> str:
    if not text:
        return ""
    line = text.strip()
    if line.startswith("```"):
        line = line.strip("`")
    line = line.replace("\n", " ")
    for prefix in ("-", "*", "•"):
        line = line.lstrip(prefix).strip()
    for prefix in ("Tuli:", "Tuli -", "Tuli –", "Tuli:", "Tuli -", "Tuli –"):
        if line.lower().startswith(prefix.lower()):
            line = line[len(prefix):].strip()
    line = line.strip("\"'“”")
    line = " ".join(line.split())
    if not line:
        return ""
    lowered = line.lower()
    banned = [
        "as an ai",
        "language model",
        "i cannot help",
        "i can't help",
        "openai",
        "system prompt",
        "tool call",
    ]
    if any(b in lowered for b in banned):
        return ""
    words = line.split()
    if len(words) > max_words:
        line = " ".join(words[:max_words]).rstrip(",;:-")
        trailing_fragments = {"and", "or", "but", "with", "to", "for", "of", "in", "on", "at"}
        while line:
            tail = line.split()[-1].strip("\"'“”.,!?;:-").lower()
            if tail not in trailing_fragments:
                break
            pieces = line.split()
            if len(pieces) <= 1:
                break
            line = " ".join(pieces[:-1]).rstrip(",;:-")
    if line and line[-1] not in ".!?":
        line = line + "."
    if line.count(".") + line.count("!") + line.count("?") > 2:
        return ""
    return line


def strip_symbol_emoji(text: str) -> str:
    return "".join(char for char in text if unicodedata.category(char) != "So")


def recent_line_match(line: str, recent_lines: List[str]) -> bool:
    normalized = " ".join(line.lower().split())
    recent = {" ".join(str(item).lower().split()) for item in recent_lines[-10:]}
    return normalized in recent


def build_prompt(event: Dict[str, Any], state: Dict[str, Any], personality: Dict[str, Any], max_words: int) -> str:
    memory_mode = normalize_memory_mode(state.get("memory_mode"))
    system = personality.get("prompt_style", {}).get("system") or (
        "You are Tuli, a tiny floating desktop companion. The system decides the event. "
        "Your only job is to write one short natural line for the intent."
    )
    if memory_mode == MEMORY_MODE_PROGRAMMER:
        system = (
            f"{system}\n"
            "Programmer mode is active. Use the local project briefing only as quiet background context. "
            "Still write a single short natural line for the current intent."
        )
    recent = state.get("recent_lines", [])[-8:]
    avoid = "\n".join(f"- {line}" for line in recent if line)
    context = {
        "memory_mode": memory_mode,
        "time_of_day": time_of_day(now()),
        "current_mood": state.get("current_mood", "neutral"),
        "energy": state.get("energy", 0.65),
        "curiosity": state.get("curiosity", 0.55),
        "talkativeness": state.get("talkativeness", 0.35),
        "sleepiness": state.get("sleepiness", 0.2),
        "event_type": event.get("event_type"),
        "intent": event.get("intent", ""),
        "emotion": event.get("emotion", "neutral"),
        "gesture": choose_gesture(event, state),
        "max_words": max_words,
    }
    parts = [system, "", "Context:"]
    for key, value in context.items():
        parts.append(f"{key}: {value}")
    parts.append("")
    parts.append("Recent lines to avoid repeating:")
    parts.append(avoid or "- none")
    if memory_mode == MEMORY_MODE_PROGRAMMER:
        brief = maybe_load_projectmem_brief(state)
        if brief:
            parts.append("")
            parts.append("Local projectmem brief:")
            parts.append(brief)
    parts.append("")
    parts.append(f"Write one line in English. Keep it under {max_words} words.")
    return "\n".join(parts)


def build_chat_prompt(user_text: str, state: Dict[str, Any], personality: Dict[str, Any]) -> str:
    memory_mode = normalize_memory_mode(state.get("memory_mode"))
    system = personality.get("chat_style", {}).get("system") or (
        "You are Tuli, a tiny floating desktop companion talking directly with the user. "
        "Stay in character. Be brief, warm, curious, lightly playful, and non-invasive. "
        "Answer in the same language as the user when possible. Return only the reply text."
    )
    if memory_mode == MEMORY_MODE_PROGRAMMER:
        system = (
            f"{system}\n"
            "Programmer mode is active. Use the local project briefing as quiet background context when it helps. "
            "Keep the answer concise and practical."
        )
    recent = state.get("recent_lines", [])[-8:]
    avoid = "\n".join(f"- {line}" for line in recent if line)
    parts = [system, "", "Context:"]
    parts.append(f"memory_mode: {memory_mode}")
    parts.append(f"time_of_day: {time_of_day(now())}")
    parts.append(f"current_mood: {state.get('current_mood', 'neutral')}")
    parts.append(f"energy: {state.get('energy', 0.65)}")
    parts.append(f"curiosity: {state.get('curiosity', 0.55)}")
    parts.append(f"talkativeness: {state.get('talkativeness', 0.35)}")
    parts.append(f"sleepiness: {state.get('sleepiness', 0.2)}")
    parts.append("")
    parts.append("Recent lines to avoid repeating:")
    parts.append(avoid or "- none")
    if memory_mode == MEMORY_MODE_PROGRAMMER:
        brief = maybe_load_projectmem_brief(state)
        if brief:
            parts.append("")
            parts.append("Local projectmem brief:")
            parts.append(brief)
    parts.append("")
    parts.append("User message:")
    parts.append(user_text.strip())
    parts.append("")
    parts.append("Reply in 1-2 short sentences. Keep it natural.")
    return "\n".join(parts)


def call_ollama(
    prompt: str,
    personality: Dict[str, Any],
    num_predict: Optional[int] = None,
    timeout_seconds: Optional[int] = None,
) -> str:
    behavior = personality.get("behavior", {})
    if not isinstance(behavior, dict):
        behavior = {}
    payload = {
        "model": personality.get("model_name", "qwen2.5:1.5b"),
        "prompt": prompt,
        "stream": False,
        "options": {
            "temperature": float(behavior.get("temperature", 0.9)),
            "top_p": float(behavior.get("top_p", 0.9)),
            "num_predict": int(num_predict if num_predict is not None else behavior.get("num_predict", 40)),
        },
    }
    req = urllib.request.Request(
        MODEL_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    timeout = int(timeout_seconds if timeout_seconds is not None else behavior.get("model_timeout_seconds", 8))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8", errors="replace"))
    response = str(data.get("response", "")).strip()
    if not response:
        log_line(
            "model_empty_response",
            model=payload["model"],
            done_reason=data.get("done_reason"),
            thinking_chars=len(str(data.get("thinking", ""))),
            num_predict=payload["options"]["num_predict"],
        )
    return response


def build_brain_event_prompt(event: Dict[str, Any], state: Dict[str, Any], max_words: int) -> str:
    recent = [str(line).strip() for line in state.get("recent_lines", [])[-5:] if str(line).strip()]
    gesture = choose_gesture(event, state)
    parts = [
        "You are preparing one short autonomous line for the user's local desktop companion.",
        f"Event type: {event.get('event_type', 'unknown')}",
        f"Intent: {event.get('intent', '') or 'gentle companion check-in'}",
        f"Emotion hint: {event.get('emotion', state.get('current_mood', 'neutral'))}",
        f"Gesture hint: {gesture}",
        f"Time of day: {time_of_day(now())}",
        f"Keep it under {max_words} words.",
        "Write one natural English line only.",
    ]
    if recent:
        parts.append("Avoid repeating these recent lines:")
        parts.extend(f"- {line}" for line in recent)
    return "\n".join(parts)


def maybe_generate_line_with_tuli_brain(
    event: Dict[str, Any],
    state: Dict[str, Any],
    personality: Dict[str, Any],
    templates: Dict[str, List[str]],
) -> Tuple[str, str]:
    ensure_tuli_brain_imports()
    if TULI_BRAIN_RESPOND is None:
        return template_for_event(event["event_type"], templates), "tuli_brain_unavailable"

    max_words = int(event.get("max_words") or personality.get("behavior", {}).get("max_words_default", 14))
    recent = state.get("recent_lines", [])
    prompt = build_brain_event_prompt(event, state, max_words)
    repeated_candidate = ""

    for attempt in range(3):
        try:
            response = TULI_BRAIN_RESPOND(prompt, speak=False)
        except Exception as exc:  # noqa: BLE001 - preserve daemon resilience.
            log_line("tuli_brain_event_error", event_type=event.get("event_type"), error=str(exc))
            if repeated_candidate:
                return repeated_candidate, "tuli_brain_repeated_fallback"
            return template_for_event(event["event_type"], templates), "tuli_brain_error"

        raw_text = strip_symbol_emoji(str(response.get("text", "")).strip())
        clean = clean_line(raw_text, max_words)
        if clean and not recent_line_match(clean, recent):
            return clean, "tuli_brain_ok"
        if clean:
            repeated_candidate = clean
        if attempt < 2:
            prompt += (
                "\nAvoid reusing the same phrasing as the recent lines. "
                "Be fresher, slightly shorter, and do not echo earlier greetings."
            )

    if repeated_candidate:
        return repeated_candidate, "tuli_brain_repeated_fallback"
    return template_for_event(event["event_type"], templates), "tuli_brain_fallback"


def maybe_generate_line(event: Dict[str, Any], state: Dict[str, Any], personality: Dict[str, Any], templates: Dict[str, List[str]]) -> Tuple[str, str]:
    provider = str(personality.get("model_provider", "ollama")).lower()
    if provider in {"tuli_brain", "ollama"}:
        return maybe_generate_line_with_tuli_brain(event, state, personality, templates)
    if provider != "tuli_brain":
        return template_for_event(event["event_type"], templates), "template_provider"
    return maybe_generate_line_with_tuli_brain(event, state, personality, templates)


def chat_with_model(user_text: str, state: Dict[str, Any], personality: Dict[str, Any]) -> str:
    ensure_tuli_brain_imports()
    if TULI_BRAIN_RESPOND is not None:
        try:
            response = TULI_BRAIN_RESPOND(user_text, speak=False)
        except Exception as exc:  # noqa: BLE001 - keep the legacy Ollama path available.
            log_line("tuli_brain_chat_error", error=str(exc))
        else:
            text = str(response.get("text", "")).strip()
            if text:
                log_line("tuli_brain_chat_ok", chars=len(text))
                return text
            log_line("tuli_brain_chat_empty", response=str(response)[:500])

    provider = str(personality.get("model_provider", "ollama")).lower()
    if provider != "ollama":
        return ""

    prompt = build_chat_prompt(user_text, state, personality)
    try:
        raw = call_ollama(prompt, personality, num_predict=220, timeout_seconds=30)
    except Exception as exc:
        log_line("chat_model_error", error=str(exc))
        return ""
    cleaned = raw.strip()
    if not cleaned:
        return ""
    if cleaned.startswith("```"):
        cleaned = cleaned.strip("`")
    return cleaned.strip()


def send_to_head(event: Dict[str, Any], text: str = "") -> None:
    args = [sys.executable, str(BASE_DIR / "send_event.py")]
    if text:
        args.extend(["--text", text])
        if event.get("emotion"):
            args.extend(["--emotion", str(event["emotion"])])
        if event.get("bubble", True):
            args.append("--bubble")
    else:
        args.extend(["--event-type", str(event.get("type") or event.get("event_type"))])
        if event.get("gesture"):
            gesture = event["gesture"]
            if isinstance(gesture, list):
                gesture = random.choice(gesture)
            args.extend(["--gesture", str(gesture)])
        if event.get("emotion"):
            args.extend(["--emotion", str(event["emotion"])])
        if event.get("priority"):
            args.extend(["--priority", str(event["priority"])])
        if event.get("intent"):
            args.extend(["--intent", str(event["intent"])])
        if event.get("source"):
            args.extend(["--source", str(event["source"])])
    subprocess.run(args, check=False)


def record_fire(state: Dict[str, Any], event: Dict[str, Any], spoken_text: str = "", gesture_only: bool = False, personality: Optional[Dict[str, Any]] = None) -> None:
    current_ts = iso()
    state["last_tick_at"] = current_ts
    state.setdefault("last_event_at", {})[event["event_type"]] = current_ts
    daily = state.setdefault("daily_event_counts", {})
    day = date_key()
    day_map = daily.setdefault(day, {})
    day_map[event["event_type"]] = int(day_map.get(event["event_type"], 0)) + 1
    if event["event_type"] == "morning_greeting":
        state["last_greeting_date"] = day
    if event.get("speak", True) and spoken_text:
        state["last_spoke_at"] = current_ts
        state.setdefault("recent_lines", []).append(spoken_text)
        recent_limit = int(behavior_value(personality or {}, "max_recent_lines", 30))
        state["recent_lines"] = state["recent_lines"][-recent_limit:]
    else:
        state["last_gesture_at"] = current_ts
    action = {
        "ts": current_ts,
        "event_type": event["event_type"],
        "gesture_only": bool(gesture_only),
        "spoken": bool(spoken_text),
        "text": spoken_text,
        "emotion": event.get("emotion"),
        "gesture": event.get("gesture"),
    }
    state.setdefault("recent_actions", []).append(action)
    state["recent_actions"] = state["recent_actions"][-30:]


def normalize_event(event: Dict[str, Any], state: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(event)
    out.setdefault("source", "schedule")
    out.setdefault("priority", base_priority(event))
    if out.get("event_type") == "idle_silent_gesture":
        out["speak"] = False
        out["gesture_only"] = True
    if out.get("event_type") == "micro_mood_event":
        out["emotion"] = state.get("current_mood", out.get("emotion", "neutral"))
    return out


def run_event(event: Dict[str, Any], state: Dict[str, Any], personality: Dict[str, Any], templates: Dict[str, List[str]], force_text: Optional[str] = None) -> Dict[str, Any]:
    event = normalize_event(event, state)
    if not event.get("speak", True) or event.get("gesture_only"):
        gesture = choose_gesture(event, state)
        send_to_head(
            {
                "type": event.get("event_type"),
                "event_type": event.get("event_type"),
                "intent": event.get("intent", ""),
                "priority": event.get("priority", "low"),
                "emotion": event.get("emotion", "neutral"),
                "gesture": gesture,
                "speak": False,
                "bubble": False,
                "source": event.get("source", "schedule"),
                "max_words": int(event.get("max_words", 0) or 0),
            }
        )
        record_fire(state, event, spoken_text="", gesture_only=True, personality=personality)
        result = {**event, "mode": "gesture_only", "gesture": gesture}
        return result

    if force_text is not None:
        text = force_text
        fallback_reason = "forced"
    else:
        text, fallback_reason = maybe_generate_line(event, state, personality, templates)
    text = clean_line(text, int(event.get("max_words") or personality.get("behavior", {}).get("max_words_default", 14)))
    if not text:
        text = template_for_event(event["event_type"], templates)
        fallback_reason = "template"
    send_to_head(event, text=text)
    record_fire(state, event, spoken_text=text, gesture_only=False, personality=personality)
    result = {**event, "mode": "speak", "text": text, "fallback_reason": fallback_reason}
    return result


def evaluate_tick(state: Dict[str, Any], personality: Dict[str, Any], schedules: List[Dict[str, Any]], templates: Dict[str, List[str]]) -> Optional[Dict[str, Any]]:
    current = now()
    state["last_tick_at"] = iso(current)
    smooth_update(state, mood_profile(current))
    candidates = eligible_events(schedules, state, current, personality)
    if not candidates:
        log_line(
            "tick_no_event",
            mood=state.get("current_mood"),
            energy=state.get("energy"),
            sleepiness=state.get("sleepiness"),
            talkativeness=state.get("talkativeness"),
            candidates=0,
        )
        return None
    chosen = weighted_choice(candidates)
    if chosen is None:
        log_line("tick_no_choice", candidates=len(candidates))
        return None
    result = run_event(chosen, state, personality, templates)
    log_line(
        "tick_event",
        event_type=result.get("event_type"),
        mode=result.get("mode"),
        fallback_reason=result.get("fallback_reason"),
        mood=state.get("current_mood"),
        energy=state.get("energy"),
        sleepiness=state.get("sleepiness"),
        talkativeness=state.get("talkativeness"),
        candidates=len(candidates),
    )
    return result


def sleep_with_jitter() -> None:
    time.sleep(random.randint(35, 95))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Tuli local autonomy daemon.")
    parser.add_argument("--once", dest="once", default="", help="Force a single event type and exit.")
    parser.add_argument("--force-text", dest="force_text", default="", help="Force a spoken text for the once event.")
    parser.add_argument("--chat", dest="chat", default="", help="Send a direct chat prompt to the model and print the reply.")
    parser.add_argument("--no-sleep", action="store_true", help="Do not sleep between ticks; useful for debugging.")
    return parser.parse_args()


def forced_event_lookup(event_type: str, schedules: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    for event in schedules:
        if event.get("event_type") == event_type:
            return event
    return None


def main() -> int:
    ensure_dirs()
    args = parse_args()
    personality = load_personality()
    schedules = load_schedules()
    templates = load_templates()
    state = load_state()
    log_memory_mode_if_changed(state)
    save_state(state)
    log_line(
        "daemon_start",
        model_provider=personality.get("model_provider"),
        model_name=personality.get("model_name"),
        memory_mode=normalize_memory_mode(state.get("memory_mode")),
    )

    if args.chat:
        state = load_state()
        log_memory_mode_if_changed(state)
        reply = chat_with_model(args.chat, state, personality)
        if reply:
            print(reply, flush=True)
            log_line("chat_done", memory_mode=normalize_memory_mode(state.get("memory_mode")), chars=len(reply))
            return 0
        log_line("chat_failed", reason="empty_reply")
        return 1

    if args.once:
        state = load_state()
        log_memory_mode_if_changed(state)
        event = forced_event_lookup(args.once, schedules)
        if event is None:
            log_line("forced_event_missing", event_type=args.once)
            return 2
        result = run_event(event, state, personality, templates, force_text=args.force_text or None)
        save_state(state)
        log_line("forced_event_done", event_type=result.get("event_type"), mode=result.get("mode"))
        return 0

    while True:
        try:
            state = load_state()
            log_memory_mode_if_changed(state)
            evaluate_tick(state, personality, schedules, templates)
            save_state(state)
        except KeyboardInterrupt:
            log_line("daemon_stop", reason="keyboard_interrupt")
            save_state(state)
            return 0
        except Exception as exc:
            log_line("daemon_error", error=str(exc))
            save_state(state)
        if args.no_sleep:
            return 0
        sleep_with_jitter()


if __name__ == "__main__":
    raise SystemExit(main())
