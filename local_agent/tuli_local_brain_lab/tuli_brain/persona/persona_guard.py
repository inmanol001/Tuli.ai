from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List


SOUL_PATH = Path(__file__).with_name("soul.yaml")


def _parse_scalar(value: str) -> Any:
    value = value.strip()
    if value.lower() == "true":
        return True
    if value.lower() == "false":
        return False
    try:
        return int(value)
    except ValueError:
        return value


def load_soul(path: Path | None = None) -> Dict[str, Any]:
    soul_path = path or SOUL_PATH
    current_key = ""
    data: Dict[str, Any] = {}

    for raw_line in soul_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        if not line.startswith(" ") and ":" in stripped:
            key, value = stripped.split(":", 1)
            current_key = key.strip()
            value = value.strip()
            data[current_key] = _parse_scalar(value) if value else []
            continue

        if stripped.startswith("- ") and current_key:
            value = stripped[2:].strip()
            if not isinstance(data.get(current_key), list):
                data[current_key] = []
            data[current_key].append(value)
            continue

        if line.startswith("  ") and ":" in stripped and current_key:
            child_key, child_value = stripped.split(":", 1)
            if not isinstance(data.get(current_key), dict):
                data[current_key] = {}
            data[current_key][child_key.strip()] = _parse_scalar(child_value)

    return data


def soul_to_system_lines(soul: Dict[str, Any]) -> List[str]:
    lines = [
        f"You are {soul.get('name', 'Tuli')}, the user's {soul.get('role', 'local companion')}.",
        str(soul.get("language_policy", "reply in the same language as the user when possible")),
    ]

    for label in ("tone", "boundaries", "local_first"):
        values = soul.get(label, [])
        if isinstance(values, list) and values:
            pretty_label = label.replace("_", " ").title()
            lines.append(f"{pretty_label}: " + "; ".join(str(value) for value in values))

    style = soul.get("response_style", {})
    if isinstance(style, dict) and style:
        max_sentences = style.get("max_sentences")
        if max_sentences:
            lines.append(f"Keep most replies within {max_sentences} sentences unless the user asks for detail.")
        if style.get("prefer_direct_answers"):
            lines.append("Prefer direct answers over long explanations.")
        if style.get("ask_one_question_only_when_needed"):
            lines.append("Ask at most one clarifying question, and only when it is needed.")

    return lines
