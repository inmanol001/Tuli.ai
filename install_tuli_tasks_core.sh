#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/inma/Documents/Vroid"
APP_SUPPORT="$HOME/Library/Application Support/VroidOverlay"
SOURCE="$PROJECT/local_agent"
RUNTIME="$APP_SUPPORT/local_agent_runtime"
TASKS_FILE="$APP_SUPPORT/tuli_tasks.json"
BACKUP="$PROJECT/backups_tuli_tasks_core_$(date +%Y%m%d_%H%M%S)"

echo "== Install Tuli Tasks Core =="
echo "Project: $PROJECT"
echo "App Support: $APP_SUPPORT"
echo "Tasks file: $TASKS_FILE"
echo "Backup: $BACKUP"

mkdir -p "$BACKUP"
mkdir -p "$SOURCE"
mkdir -p "$RUNTIME"
mkdir -p "$APP_SUPPORT"

echo ""
echo "== 1. Backup existing task files =="
for f in \
  "$TASKS_FILE" \
  "$SOURCE/tasks_store.py" \
  "$SOURCE/tuli_tasks.py" \
  "$RUNTIME/tasks_store.py" \
  "$RUNTIME/tuli_tasks.py"
do
  if [ -f "$f" ]; then
    cp "$f" "$BACKUP/$(basename "$f").backup"
    echo "backup: $f"
  fi
done

echo ""
echo "== 2. Create tasks_store.py =="
cat > "$SOURCE/tasks_store.py" <<'PY'
from __future__ import annotations

import argparse
import json
import os
import tempfile
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "VroidOverlay"
TASKS_PATH = APP_SUPPORT / "tuli_tasks.json"

VALID_STATUSES = {"todo", "doing", "blocked", "done"}
VALID_PRIORITIES = {"low", "normal", "high", "urgent"}


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def ensure_parent() -> None:
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)


def atomic_write_json(path: Path, data: Any) -> None:
    ensure_parent()
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def default_store() -> Dict[str, Any]:
    return {
        "version": 1,
        "updated_at": now_iso(),
        "tasks": []
    }


def load_store() -> Dict[str, Any]:
    ensure_parent()

    if not TASKS_PATH.exists():
        store = default_store()
        atomic_write_json(TASKS_PATH, store)
        return store

    try:
        data = json.loads(TASKS_PATH.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("root is not object")
        if "tasks" not in data or not isinstance(data["tasks"], list):
            data["tasks"] = []
        data.setdefault("version", 1)
        data.setdefault("updated_at", now_iso())
        return data
    except Exception:
        backup = TASKS_PATH.with_suffix(".json.corrupt." + datetime.now().strftime("%Y%m%d_%H%M%S"))
        TASKS_PATH.rename(backup)
        store = default_store()
        atomic_write_json(TASKS_PATH, store)
        return store


def save_store(store: Dict[str, Any]) -> None:
    store["updated_at"] = now_iso()
    atomic_write_json(TASKS_PATH, store)


def normalize_status(status: Optional[str]) -> Optional[str]:
    if status is None:
        return None
    status = status.strip().lower()
    if status not in VALID_STATUSES:
        raise ValueError(f"Invalid status: {status}. Valid: {sorted(VALID_STATUSES)}")
    return status


def normalize_priority(priority: Optional[str]) -> Optional[str]:
    if priority is None:
        return None
    priority = priority.strip().lower()
    if priority not in VALID_PRIORITIES:
        raise ValueError(f"Invalid priority: {priority}. Valid: {sorted(VALID_PRIORITIES)}")
    return priority


def make_id() -> str:
    return "task_" + uuid.uuid4().hex[:8]


def add_task(
    title: str,
    project: Optional[str] = None,
    priority: str = "normal",
    notes: str = "",
    status: str = "todo",
) -> Dict[str, Any]:
    title = title.strip()
    if not title:
        raise ValueError("title is required")

    status = normalize_status(status) or "todo"
    priority = normalize_priority(priority) or "normal"

    store = load_store()
    ts = now_iso()

    task = {
        "id": make_id(),
        "title": title,
        "project": project.strip() if isinstance(project, str) and project.strip() else None,
        "status": status,
        "priority": priority,
        "notes": notes.strip() if isinstance(notes, str) else "",
        "created_at": ts,
        "updated_at": ts,
    }

    store["tasks"].append(task)
    save_store(store)
    return task


def list_tasks(status: Optional[str] = None, project: Optional[str] = None, include_done: bool = True) -> List[Dict[str, Any]]:
    status = normalize_status(status)
    store = load_store()
    tasks = list(store.get("tasks", []))

    if status:
        tasks = [t for t in tasks if t.get("status") == status]

    if project:
        project_norm = project.strip().lower()
        tasks = [t for t in tasks if str(t.get("project") or "").lower() == project_norm]

    if not include_done:
        tasks = [t for t in tasks if t.get("status") != "done"]

    order = {"doing": 0, "blocked": 1, "todo": 2, "done": 3}
    priority_order = {"urgent": 0, "high": 1, "normal": 2, "low": 3}
    tasks.sort(key=lambda t: (
        order.get(t.get("status"), 9),
        priority_order.get(t.get("priority"), 9),
        str(t.get("updated_at", "")),
    ))
    return tasks


def find_task(store: Dict[str, Any], task_id_or_text: str) -> Dict[str, Any]:
    q = task_id_or_text.strip().lower()
    tasks = store.get("tasks", [])

    for t in tasks:
        if str(t.get("id", "")).lower() == q:
            return t

    matches = [t for t in tasks if q in str(t.get("title", "")).lower()]
    if len(matches) == 1:
        return matches[0]

    if len(matches) > 1:
        raise ValueError("Multiple tasks match. Use task id: " + ", ".join(t["id"] for t in matches[:8]))

    raise ValueError(f"No task found for: {task_id_or_text}")


def update_task(
    task_id_or_text: str,
    status: Optional[str] = None,
    title: Optional[str] = None,
    project: Optional[str] = None,
    priority: Optional[str] = None,
    notes: Optional[str] = None,
) -> Dict[str, Any]:
    status = normalize_status(status)
    priority = normalize_priority(priority)

    store = load_store()
    task = find_task(store, task_id_or_text)

    if status is not None:
        task["status"] = status
    if title is not None and title.strip():
        task["title"] = title.strip()
    if project is not None:
        task["project"] = project.strip() if project.strip() else None
    if priority is not None:
        task["priority"] = priority
    if notes is not None:
        task["notes"] = notes.strip()

    task["updated_at"] = now_iso()
    save_store(store)
    return task


def complete_task(task_id_or_text: str) -> Dict[str, Any]:
    return update_task(task_id_or_text, status="done")


def delete_task(task_id_or_text: str) -> Dict[str, Any]:
    store = load_store()
    task = find_task(store, task_id_or_text)
    store["tasks"] = [t for t in store.get("tasks", []) if t.get("id") != task.get("id")]
    save_store(store)
    return task


def task_summary(max_items: int = 8) -> str:
    tasks = list_tasks(include_done=False)[:max_items]
    if not tasks:
        return "Current tasks: none."

    lines = ["Current tasks:"]
    for t in tasks:
        project = f" ({t['project']})" if t.get("project") else ""
        priority = f" !{t['priority']}" if t.get("priority") in {"high", "urgent"} else ""
        lines.append(f"- [{t.get('status', 'todo')}] {t.get('title', '')}{project}{priority}")
    return "\n".join(lines)


def format_tasks(tasks: List[Dict[str, Any]]) -> str:
    if not tasks:
        return "No tasks."

    lines = []
    for t in tasks:
        project = f" | project={t['project']}" if t.get("project") else ""
        notes = f" | notes={t['notes']}" if t.get("notes") else ""
        lines.append(
            f"{t['id']} | [{t['status']}] {t['title']} | priority={t['priority']}{project}{notes}"
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Tuli task store CLI")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_add = sub.add_parser("add")
    p_add.add_argument("title")
    p_add.add_argument("--project")
    p_add.add_argument("--priority", default="normal")
    p_add.add_argument("--status", default="todo")
    p_add.add_argument("--notes", default="")

    p_list = sub.add_parser("list")
    p_list.add_argument("--status")
    p_list.add_argument("--project")
    p_list.add_argument("--no-done", action="store_true")

    p_update = sub.add_parser("update")
    p_update.add_argument("task")
    p_update.add_argument("--status")
    p_update.add_argument("--title")
    p_update.add_argument("--project")
    p_update.add_argument("--priority")
    p_update.add_argument("--notes")

    p_done = sub.add_parser("done")
    p_done.add_argument("task")

    p_delete = sub.add_parser("delete")
    p_delete.add_argument("task")

    p_summary = sub.add_parser("summary")
    p_summary.add_argument("--max", type=int, default=8)

    args = parser.parse_args()

    if args.cmd == "add":
        task = add_task(
            title=args.title,
            project=args.project,
            priority=args.priority,
            status=args.status,
            notes=args.notes,
        )
        print(json.dumps(task, ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "list":
        tasks = list_tasks(status=args.status, project=args.project, include_done=not args.no_done)
        print(format_tasks(tasks))
        return 0

    if args.cmd == "update":
        task = update_task(
            args.task,
            status=args.status,
            title=args.title,
            project=args.project,
            priority=args.priority,
            notes=args.notes,
        )
        print(json.dumps(task, ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "done":
        task = complete_task(args.task)
        print(json.dumps(task, ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "delete":
        task = delete_task(args.task)
        print(json.dumps({"deleted": task}, ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "summary":
        print(task_summary(max_items=args.max))
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
PY

echo ""
echo "== 3. Create tuli_tasks.py CLI wrapper =="
cat > "$SOURCE/tuli_tasks.py" <<'PY'
#!/usr/bin/env python3
from tasks_store import main

if __name__ == "__main__":
    raise SystemExit(main())
PY

chmod +x "$SOURCE/tuli_tasks.py"

echo ""
echo "== 4. Copy to runtime =="
cp "$SOURCE/tasks_store.py" "$RUNTIME/tasks_store.py"
cp "$SOURCE/tuli_tasks.py" "$RUNTIME/tuli_tasks.py"
chmod +x "$RUNTIME/tuli_tasks.py"

echo ""
echo "== 5. Initialize tasks file =="
python3 "$SOURCE/tuli_tasks.py" list >/dev/null

echo ""
echo "== 6. Add starter tasks =="
python3 "$SOURCE/tuli_tasks.py" add "Conectar Kokoro al avatar" --project Tuli --priority high --status doing --notes "Kokoro está descargando/reparando el modelo."
python3 "$SOURCE/tuli_tasks.py" add "Agregar todo list al dashboard de Tuli" --project Tuli --priority high --status todo --notes "Primero probar JSON/CLI, luego UI."
python3 "$SOURCE/tuli_tasks.py" add "Parchear memoria real con pinned facts" --project Tuli --priority high --status todo --notes "El app debe conservar pinned_facts y el daemon debe leerlos."

echo ""
echo "== 7. Current task list =="
python3 "$SOURCE/tuli_tasks.py" list

echo ""
echo "== 8. Summary for daemon/dashboard =="
python3 "$SOURCE/tuli_tasks.py" summary

echo ""
echo "== 9. Verify files =="
ls -lh "$TASKS_FILE" "$SOURCE/tasks_store.py" "$SOURCE/tuli_tasks.py" "$RUNTIME/tasks_store.py" "$RUNTIME/tuli_tasks.py"

echo ""
echo "DONE"
echo "Tasks file: $TASKS_FILE"
echo "Backup: $BACKUP"
