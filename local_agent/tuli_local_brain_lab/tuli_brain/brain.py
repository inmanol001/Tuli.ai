from __future__ import annotations

from typing import Any, Dict, List

from .config import load_config
from .memory.memory_policy import should_store_episodic_turn
from .memory.sqlite_memory import SQLiteMemoryStore
from .persona.context_builder import build_context
from .schemas import make_action, validate_brain_response
from .providers.kokoro_local import KokoroLocalError, synthesize_speech
from .providers.ollama_local import OllamaLocalError, chat as ollama_chat


READY_EMOTION = "focused"
FALLBACK_TEXT = "Estoy aquí, pero mi modelo local no respondió todavía."


def respond(user_text: str, speak: bool = False) -> dict:
    if not isinstance(user_text, str):
        raise TypeError("user_text must be a string")
    if not user_text.strip():
        raise ValueError("user_text must not be empty")

    config = load_config()
    memory_store = SQLiteMemoryStore(config.memory_db_path)
    memory_store.initialize()
    prompt_context = build_context(user_text, memory_store)
    error_message = ""
    try:
        text = ollama_chat(user_text, config, system_prompt=prompt_context.system_prompt).text
    except OllamaLocalError as exc:
        text = FALLBACK_TEXT
        error_message = str(exc)

    actions: List[Dict[str, Any]] = [
        make_action("bubble_show", text=text),
        make_action("emotion_hint", emotion=READY_EMOTION),
    ]
    if speak:
        try:
            speech = synthesize_speech(text, config)
            actions.append(
                make_action(
                    "speech_start",
                    text=text,
                    audio_path=speech.audio_path,
                    voice=speech.voice,
                    response_format=speech.response_format,
                    bytes_written=speech.bytes_written,
                )
            )
        except KokoroLocalError as exc:
            actions.append(make_action("error", message=str(exc)))
    if error_message:
        actions.append(make_action("error", message=error_message))

    response = validate_brain_response(
        {
            "text": text,
            "emotion": READY_EMOTION,
            "speak": bool(speak),
            "voice": config.kokoro_voice,
            "actions": actions,
        }
    )
    if not error_message and should_store_episodic_turn(user_text, text):
        memory_store.add_memory(
            kind="episodic",
            text=f"User: {user_text.strip()}\nTuli: {text}",
            source="brain.respond",
            importance=0.45,
            confidence=0.8,
            tags=["turn", "chat"],
        )
    return response
