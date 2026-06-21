# Final AIRI to Tuli Local Brain Design

Date: 2026-06-21
Workspace: `/Users/inma/Documents/Vroid`

## Scope

This document compares the inspected AIRI architecture reports with the current Tuli local system and designs the local brain module to build later.

No implementation was performed. No production files, visual app files, `main.m`, dependencies, LaunchAgents, or runtime state were modified.

Expected AIRI input note: `external/airi_lab/AIRI_ARCHITECTURE_OVERVIEW.md` was not present. The comparison below uses the five available AIRI reports plus the existing local Tuli plans in `external/airi_lab/`.

## Current Tuli Baseline

Tuli already has a useful first-generation local stack:

- `openclaw_vroid_bridge.py`: append-only JSONL event bridge for speech, bubble, text deltas, emotion hints, and silent events.
- `local_agent/vroid_agent_daemon.py`: scheduler, mood state, autonomous line generation, direct chat path, Ollama `/api/generate` caller, and event sender.
- `local_agent/personality.yaml`: current persona/model/tone config. Active model is `qwen3:1.7b`.
- `local_agent/send_event.py`: small CLI/event writer for local avatar stream.
- `local_agent/tasks_store.py` and `tuli_tasks.py`: local task JSON store.
- Runtime files under `/Users/inma/Library/Application Support/VroidOverlay/`: conversation memory JSON, task JSON, JSONL stream, logs, and copied local agent runtime.

Main gap: the current logic is useful but scattered. Model, persona, memory, action routing, and voice policy are not yet unified behind one local brain contract.

## AIRI -> Tuli Map

| Area | AIRI pattern | Current Tuli equivalent | Recommendation |
| --- | --- | --- | --- |
| LLM provider | Registry + active provider/model settings; OpenAI-compatible transport; Ollama as `/v1/` compatible provider | `vroid_agent_daemon.py` calls Ollama native `/api/generate`; model in `personality.yaml` | Adapt the separation, keep native Ollama local transport |
| Memory | IndexedDB chat sessions, runtime context buckets, timestamped message shaping; no confirmed vector/RAG path | `conversation_memory.json`, `agent_state.json`, recent lines, tasks JSON; projectmem optional programmer mode | Adapt as deterministic SQLite + JSONL export; no embeddings first |
| Persona/soul | Character cards with system/personality/greetings fields; distributed prompt composer | `personality.yaml`, pinned facts in state/memory | Collapse into local `persona/soul.yaml` plus context builder |
| Context builder | Time prefixes + runtime context appended to latest user message | `build_prompt` and `build_chat_prompt` in daemon | Adapt into dedicated `persona/context_builder.py` |
| Action router | Chat stream event handlers, hooks, tool events, speech intent bus | JSONL events through `openclaw_vroid_bridge.py` and `send_event.py` | Adapt as `actions/action_router.py` plus `event_bridge.py` |
| Voice/TTS | Speech provider registry; Kokoro local exists; no `say` in inspected path | Kokoro endpoint exists; visual app currently may have fallback logic, but brain should not depend on it | Keep Kokoro-only brain provider; no cloud and no `say` |
| Event bridge | Speech intent lifecycle over event bus/BroadcastChannel | Append-only `openclaw_stream.jsonl` | Keep local JSONL bridge as first-class API |
| Settings/config | Local storage-backed provider/model/speech settings | `personality.yaml`, `agent_state.json`, env vars | Add `config.py` with explicit paths/env overrides |
| Plugin/tool system | Provider registry, card agents, LLM tools; no classic generic plugin runtime found | Scripts/CLIs: tasks, bridge, daemon; no tool contract | Start with explicit local action registry, not a plugin loader |

## Area-by-Area Decision Table

| Area | AIRI relevant file/module | What AIRI does | Tuli local equivalent | Copy/adapt/ignore | Risk | Dependencies | Priority |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LLM provider | `/private/tmp/registry.ts`, `/private/tmp/providers-store.ts`, `/private/tmp/ollama-provider.ts`, `/private/tmp/chat-store.ts`, `/private/tmp/llm-store.ts` | Registers providers, stores active provider/model, builds chat requests, streams events | `local_agent/vroid_agent_daemon.py`, `local_agent/personality.yaml` | Adapt architecture, not code | Medium: provider abstraction can become overbuilt | Python stdlib HTTP first; Ollama local | High |
| Ollama transport | `/private/tmp/ollama-provider.ts`, `/private/tmp/openai-compatible-builder.ts` | Treats Ollama as OpenAI-compatible `/v1/` provider | Current Tuli uses Ollama native `/api/generate` | Adapt concept, keep native `/api/chat` or `/api/generate` | Low: native endpoint is simpler locally | Ollama running locally | High |
| Memory | `chat-sessions.repo.ts`, `session-store.ts`, `context-store.ts`, `context-prompt.ts`, `datetime-prefix.ts` | Persists chat sessions, maintains runtime context, formats context blocks | `conversation_memory.json`, `agent_state.json`, `tuli_tasks.json`, recent lines | Adapt strongly | Medium: bad memory can poison prompts | SQLite stdlib, JSONL | High |
| Persona/soul | `airi-card.ts`, `character.ts`, `system-v2.ts`, `emotions.ts` | Persona comes from character card fields and emotion mappings | `personality.yaml`, pinned facts, current prompt strings | Adapt into one `soul.yaml` | Medium: personality drift if too many sources survive | YAML parser optional; JSON-compatible YAML subset acceptable | High |
| Context builder | `chat.ts`, `context-prompt.ts`, `datetime-prefix.ts` | Builds deterministic prompt and appends context to latest user turn | `build_prompt`, `build_chat_prompt` | Adapt into separate module | Medium: too much context hurts small model | Python only | High |
| Action router | `chat.ts` stream handlers and hooks | Routes `text-delta`, reasoning, tools, finish, errors | `openclaw_vroid_bridge.py`, `send_event.py` | Adapt as simple action router | Medium: duplicate/old stream events can cause repeated speech | JSON schema validation by code | High |
| Speech intent bus | `speech/bus.ts`, `pipeline-runtime.ts`, `character/index.ts` | Separates text generation from speech intent lifecycle | JSONL event stream with `speech_start`, `text_delta`, `speech_end` | Adapt lifecycle idea | Low: JSONL is already working | Local file append | High |
| Voice/TTS | `speech.ts`, `providers.ts` Kokoro local provider | Provider-based TTS; Kokoro local returns binary audio | Kokoro local service at `127.0.0.1:8880`; app consumes speech actions | Adapt only Kokoro local | Medium: endpoint availability and audio format differences | Kokoro server local | Medium |
| Settings/config | `consciousness-store.ts`, `settings-consciousness.vue`, `speech.ts` | Persists active provider/model/voice in UI state | `personality.yaml`, `agent_state.json`, env vars | Adapt into `config.py` | Low | Python stdlib | High |
| Plugin/tool system | Provider registry, card `agents`, LLM tools | Extensibility through registries and tools, not a classic plugin loader | No formal plugin system; CLIs for tasks/events | Ignore full plugin system; add explicit local actions | Medium if tools execute arbitrary commands | None initially | Medium |
| Cloud providers | Many provider definitions | Supports OpenAI, Azure, ElevenLabs, etc. | Desired system is local-first | Ignore by default | High if copied | API keys/cloud | Do not implement |
| UI web | AIRI stage UI/settings pages | Provider/model/voice configuration UI | Existing native overlay app | Ignore for now | High if it disturbs avatar render | Web stack | Do not implement |

## Final Local Module Design

Target layout:

```text
/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/
  brain.py
  config.py
  schemas.py
  providers/
    ollama_local.py
    kokoro_local.py
  memory/
    sqlite_memory.py
    memory_retriever.py
  persona/
    soul.yaml
    context_builder.py
    persona_guard.py
  actions/
    action_router.py
    event_bridge.py
```

### `brain.py`

Owns the public API. It should coordinate config, persona, memory retrieval, Ollama response generation, action construction, optional speech, and memory writeback.

Core responsibility:

1. Receive user text.
2. Load config and soul.
3. Retrieve relevant memory.
4. Build prompt/messages.
5. Call Ollama local provider.
6. Normalize response text/emotion.
7. Build local actions.
8. Optionally route speech actions to JSONL.
9. Store the turn in local memory.

### `config.py`

Single source for local paths and defaults.

Defaults:

- Ollama URL: `http://127.0.0.1:11434/api/chat`
- Ollama model: `qwen3:1.7b`
- Kokoro URL: `http://127.0.0.1:8880/v1/audio/speech`
- Kokoro voice: `af_bella`
- Event stream: `/Users/inma/Library/Application Support/VroidOverlay/openclaw_stream.jsonl`
- Memory DB: `/Users/inma/Library/Application Support/VroidOverlay/tuli_brain.sqlite3`
- JSONL memory export: `/Users/inma/Library/Application Support/VroidOverlay/tuli_memory.jsonl`

Allowed env overrides:

- `TULI_OLLAMA_URL`
- `TULI_OLLAMA_MODEL`
- `TULI_KOKORO_URL`
- `TULI_KOKORO_VOICE`
- `TULI_EVENT_STREAM_PATH`
- `TULI_MEMORY_DB_PATH`

### `schemas.py`

Defines plain Python dataclasses or typed dictionaries for:

- `BrainResponse`
- `Action`
- `MemoryItem`
- `ProviderResult`
- `Emotion`
- `TurnContext`

No external schema library in phase 1. Validate with explicit functions.

### `providers/ollama_local.py`

Local-only model adapter.

Responsibilities:

- Resolve URL/model from config.
- Build Ollama messages.
- POST to native Ollama endpoint.
- Parse response text.
- Normalize errors.
- Optional streaming later.

Use native Ollama by default. Do not copy AIRI's OpenAI-compatible transport unless there is a specific future reason.

### `providers/kokoro_local.py`

Local-only voice adapter.

Responsibilities:

- Build Kokoro request:
  - `model: "kokoro"`
  - `voice: "af_bella"`
  - `input: text`
  - `response_format: "mp3"` or configured local format
- Return audio bytes or local temp path if used by a CLI.
- Never call cloud.
- Never call macOS `say`.
- On failure, return a local error object rather than silently falling back.

Important: the first brain version can emit speech actions without directly playing audio. Direct Kokoro audio generation can be used by CLI tests or a future voice executor.

### `memory/sqlite_memory.py`

SQLite-backed memory store using Python stdlib `sqlite3`.

Suggested table:

```sql
CREATE TABLE memories (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  text TEXT NOT NULL,
  source TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  importance REAL DEFAULT 0.5,
  confidence REAL DEFAULT 0.8,
  tags_json TEXT DEFAULT '[]',
  project TEXT,
  session_id TEXT,
  ttl TEXT,
  archived INTEGER DEFAULT 0
);
```

Memory kinds:

- `core`
- `preference`
- `project_rule`
- `technical_warning`
- `episodic`
- `task_context`

### `memory/memory_retriever.py`

Deterministic retrieval first, no embeddings.

Retrieval order:

1. `core`
2. active `project_rule`
3. active `technical_warning`
4. matching `preference`
5. recent/important `episodic`
6. active `task_context`

Scoring should be explainable:

- exact keyword match
- recency
- importance
- project match
- kind priority

### `persona/soul.yaml`

Canonical Tuli identity and rules.

Recommended sections:

```yaml
core:
  name: Tuli
  role: local floating desktop companion
  language_priority: Spanish first, mirror the user when useful
style:
  tone: warm, concise, curious, lightly playful
  max_sentences_default: 2
constraints:
  local_first: true
  no_cloud_default: true
  no_api_keys_default: true
  no_macos_say: true
  do_not_invent_facts: true
voice:
  provider: kokoro
  voice: af_bella
model:
  provider: ollama
  model: qwen3:1.7b
memory_policy:
  keep_short_term_turns: true
  summarize_old_context: true
  never_preserve_known_false_facts: true
project_rules:
  - Do not touch main.m unless the user explicitly asks.
  - Do not modify visual app/render while working on brain internals.
```

### `persona/context_builder.py`

Builds the prompt/messages in one place.

Recommended prompt shape:

```text
[Soul]
...stable identity and local-first rules...

[Memory]
- core: ...
- preference: ...
- project_rule: ...
- technical_warning: ...
- episodic: ...
- task_context: ...

[Runtime]
time: ...
workspace: ...
model: qwen3:1.7b
voice: af_bella

[User]
...
```

For small local models, keep context short, explicit, and ranked.

### `persona/persona_guard.py`

Simple output guard for Tuli's identity and response quality.

Responsibilities:

- Strip accidental markdown fences.
- Reject empty responses.
- Prevent claims like "I am OpenAI", "I am a model", or wrong identity.
- Enforce max length when needed.
- Normalize emotion to one of:
  - `happy`
  - `thinking`
  - `worried`
  - `focused`
  - `neutral`

### `actions/action_router.py`

Turns a brain result into actions.

Rules:

- Always include `bubble_show` for visible replies.
- Include `emotion_hint` when emotion is known.
- Include `speech_start` only when `speak=True`.
- Optionally include `speech_end` when writing directly to the avatar stream.
- Do not execute arbitrary shell commands.

### `actions/event_bridge.py`

Local JSONL writer.

Responsibilities:

- Append one JSON object per line to `openclaw_stream.jsonl`.
- Include stable `id`, `turn_id`, `source`, `ts`.
- Validate action type and payload.
- Avoid replaying old events.
- Never mutate visual app files.

## `brain.respond` Contract

Function:

```python
brain.respond(user_text: str, speak: bool = False) -> dict
```

Required return shape:

```json
{
  "text": "respuesta de Tuli",
  "emotion": "happy|thinking|worried|focused|neutral",
  "speak": true,
  "voice": "af_bella",
  "actions": [
    {"type": "bubble_show", "text": "..."},
    {"type": "emotion_hint", "emotion": "..."},
    {"type": "speech_start", "text": "..."}
  ]
}
```

Detailed behavior:

- `text`: final clean user-visible reply.
- `emotion`: normalized small set only.
- `speak`: mirrors the input argument unless policy disables speech.
- `voice`: defaults to `af_bella`.
- `actions`: validated local action list. These actions are declarative; writing to JSONL is a separate choice.

Recommended internal flow:

```text
respond(user_text, speak)
  -> validate input
  -> load config
  -> load soul.yaml
  -> retrieve memory
  -> build context/messages
  -> call Ollama local
  -> guard/clean persona output
  -> choose emotion
  -> build actions
  -> store memory
  -> return dict
```

## Example Response

```json
{
  "text": "Estoy aquí. Lo más limpio sería separar cerebro, memoria y voz antes de tocar la app visual.",
  "emotion": "focused",
  "speak": true,
  "voice": "af_bella",
  "actions": [
    {
      "type": "bubble_show",
      "text": "Estoy aquí. Lo más limpio sería separar cerebro, memoria y voz antes de tocar la app visual."
    },
    {
      "type": "emotion_hint",
      "emotion": "focused"
    },
    {
      "type": "speech_start",
      "text": "Estoy aquí. Lo más limpio sería separar cerebro, memoria y voz antes de tocar la app visual."
    }
  ]
}
```

## Implementation Plan by Phases

### Phase 1: config + schemas

- Create `tuli_brain/config.py`.
- Create `tuli_brain/schemas.py`.
- Define default paths, env overrides, emotion enum, action types, and response shape.
- Add no external dependencies.

Acceptance:

- `python -m tuli_brain.config` or a tiny local import can print resolved config.
- Invalid action/emotion fails validation clearly.

### Phase 2: Ollama local provider

- Create `providers/ollama_local.py`.
- Use local Ollama only.
- Default model: `qwen3:1.7b`.
- Use `/api/chat` for message-style calls, or keep `/api/generate` only if compatibility with the current daemon matters.

Acceptance:

- A local test prompt returns text.
- Empty Qwen thinking responses are logged and handled.
- No cloud fallback.

### Phase 3: SQLite memory

- Create `memory/sqlite_memory.py`.
- Create schema and CRUD helpers.
- Import or mirror current `conversation_memory.json` into `core`/`project_rule` rows only when explicitly run later.

Acceptance:

- Can insert/list/search deterministic memory rows.
- Corrupt DB handling is explicit and non-destructive.

### Phase 4: soul.yaml + context builder

- Create `persona/soul.yaml`.
- Create `persona/context_builder.py`.
- Create `persona/persona_guard.py`.

Acceptance:

- Context builder produces a short, deterministic prompt.
- Tuli identity is stable.
- Missing context causes "I don't know" style honesty rather than invention.

### Phase 5: action router + event bridge

- Create `actions/action_router.py`.
- Create `actions/event_bridge.py`.
- Keep event bridge compatible with existing `openclaw_stream.jsonl`.

Acceptance:

- `brain.respond(..., speak=False)` returns bubble/emotion actions only.
- `brain.respond(..., speak=True)` includes speech action.
- Optional writer appends valid JSONL without touching app UI.

### Phase 6: Kokoro-only provider

- Create `providers/kokoro_local.py`.
- Keep Kokoro local endpoint config.
- Do not add `say`.
- Do not add cloud TTS.

Acceptance:

- Provider can validate local endpoint or produce a clear local error.
- Brain still works if Kokoro is down; it returns text/actions and records voice error separately.

### Phase 7: CLI

- Add a small CLI entrypoint under lab only.
- Example:

```bash
python3 -m tuli_brain respond "hola tuli" --speak
```

Acceptance:

- Prints the `brain.respond` JSON.
- Optional `--emit` writes actions to JSONL.
- No daemon or app changes required.

### Phase 8: Optional integration with daemon

- Update daemon later, only after lab module is stable.
- Replace direct prompt/model/action logic with calls into `brain.respond`.
- Keep old daemon path as backup until verified.

Acceptance:

- Scheduled events still work.
- Direct chat uses the same brain path.
- Memory writeback is centralized.

### Phase 9: UI/avatar later, only if needed

- Do not touch `main.m` in brain phases.
- Only after local brain is stable, consider UI changes.
- Keep visual app as consumer of JSONL events.

Acceptance:

- Brain remains testable without launching avatar.
- UI changes are optional and isolated.

## Local-First Rules

- No cloud by default.
- No API keys by default.
- No OpenAI by default.
- No ElevenLabs by default.
- No Azure by default.
- No macOS `say`.
- Kokoro-only for voice.
- Ollama local for model.
- Memory local SQLite/JSONL.
- Events through local JSONL.
- All defaults must work offline once Ollama and Kokoro are already installed locally.

## What Not To Do

- Do not touch `main.m`.
- Do not modify the visual app.
- Do not change render/SceneKit/camera/model loading.
- Do not import AIRI wholesale.
- Do not copy AIRI's web UI.
- Do not use corrupt backups as source of truth.
- Do not install dependencies globally.
- Do not mix cloud providers into the default path.
- Do not add a generic plugin executor before actions are explicit and safe.
- Do not let memory grow into unreviewed prompt sludge.
- Do not let old JSONL stream history replay as new speech.

## Recommended Manual Implementation Checklist

Use this when deciding to build the module:

- [ ] Create `local_agent/tuli_local_brain_lab/tuli_brain/` package.
- [ ] Add `__init__.py` files only inside the lab module.
- [ ] Implement `config.py` with local defaults and env overrides.
- [ ] Implement `schemas.py` with action/response validators.
- [ ] Implement `providers/ollama_local.py` with local Ollama request and error handling.
- [ ] Add a minimal fake-provider test or dry-run function before using real Ollama.
- [ ] Implement `memory/sqlite_memory.py` with schema creation and CRUD.
- [ ] Implement `memory/memory_retriever.py` with deterministic retrieval.
- [ ] Write `persona/soul.yaml` as canonical Tuli identity.
- [ ] Implement `persona/context_builder.py`.
- [ ] Implement `persona/persona_guard.py`.
- [ ] Implement `actions/action_router.py`.
- [ ] Implement `actions/event_bridge.py`.
- [ ] Implement `brain.py` with `respond(user_text, speak=False)`.
- [ ] Add CLI for printing response JSON.
- [ ] Test CLI with `speak=False`.
- [ ] Test CLI with `speak=True` without writing to JSONL.
- [ ] Test optional `--emit` writes valid JSONL to a temp file.
- [ ] Only then test against real `openclaw_stream.jsonl`.
- [ ] Only after lab tests pass, consider daemon integration.
- [ ] Keep app visual and `main.m` untouched until brain behavior is stable.

## Final Recommendation

Do not rebuild AIRI inside Tuli. AIRI's useful ideas are separation of concerns, local persistence, provider abstraction, context shaping, and speech intent routing. Tuli should keep the local JSONL bridge and build a small Python brain around it.

The first serious win is not a bigger model or a UI rewrite. It is a clean local brain contract:

```text
user text -> local context -> Ollama -> guarded Tuli response -> validated actions -> local JSONL
```

That gives Tuli a stable center without disturbing the avatar renderer.
