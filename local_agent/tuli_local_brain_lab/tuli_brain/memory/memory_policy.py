from __future__ import annotations


TRIVIAL_INPUTS = frozenset(
    {
        "hola",
        "hola tuli",
        "hello",
        "hello tuli",
        "hey",
        "hey tuli",
        "hi",
        "hi tuli",
        "buenas",
        "buenos dias",
        "buenos días",
        "buenas tardes",
        "buenas noches",
    }
)


def _normalize(text: str) -> str:
    lowered = text.strip().lower()
    for char in ".,!?¿¡:;()[]{}\"'":
        lowered = lowered.replace(char, " ")
    return " ".join(lowered.split())


def should_store_episodic_turn(user_text: str, assistant_text: str) -> bool:
    user_norm = _normalize(user_text)
    assistant_norm = _normalize(assistant_text)

    if not user_norm or not assistant_norm:
        return False
    if user_norm in TRIVIAL_INPUTS:
        return False
    if user_norm.startswith(("hola", "hello", "hey", "hi", "buenas")) and user_norm.endswith(
        ("responde corto", "responde en una frase", "responde en una linea", "responde en una línea")
    ):
        return False
    if len(user_norm) < 12 and len(assistant_norm) < 80:
        return False
    return True
