from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tuli_brain.activity import ActivityWatcher
from tuli_brain.actions.event_bridge import emit_response_events_with_turn
from tuli_brain.commands import evaluate_permission, parse_command, route_user_text
from tuli_brain.brain import respond
from tuli_brain.config import TuliBrainConfig, load_config
from tuli_brain.layout import LayoutManager, LayoutStateStore
from tuli_brain.__main__ import _play_voice_from_response
from tuli_brain.debug import (
    build_inspector_snapshot,
    build_token_telemetry,
    estimate_messages_tokens,
    estimate_tokens_from_text,
    summarize_event_stream,
    telemetry_to_event,
)
from tuli_brain.intents import ActionPlanner, IntentResolver
from tuli_brain.providers.ollama_local import chat, chat_raw_messages
from tuli_brain.router import AIIntentRouter, RouterDecision
from tools.watch_token_context import parse_token_event
from tuli_brain.macos_control import MacOSControl, PermissionCheckResult, WindowBounds, WindowProbeResult, WindowRecord
from tuli_brain.macos_control.native_window_tiling import NativeTilingResult, NativeWindowTiling
from tuli_brain.macos_control.space_control import SpaceControlResult
from tuli_brain.tools import DEFAULT_TOOL_CATALOG, ToolCall, ToolCatalog, ToolExecutor, ToolResult, ToolSpec


def make_test_config(tmpdir: str) -> SimpleNamespace:
    base = Path(tmpdir)
    return SimpleNamespace(
        ollama_url="http://127.0.0.1:11434/api/chat",
        ollama_model="qwen3:1.7b",
        chat_num_ctx=32768,
        chat_num_predict=600,
        router_url="http://127.0.0.1:11434/api/chat",
        router_model="qwen3-0.6b-ud-q8-k-xl-local:latest",
        router_num_ctx=8192,
        router_num_predict=500,
        ollama_keep_alive="10m",
        kokoro_url="http://127.0.0.1:8880/v1/audio/speech",
        kokoro_voice="af_bella",
        speech_output_dir=str(base / "speech"),
        event_stream_path=str(base / "events.jsonl"),
        request_stream_path=str(base / "requests.jsonl"),
        response_stream_path=str(base / "responses.jsonl"),
        memory_db_path=str(base / "memory.sqlite3"),
        memory_jsonl_path=str(base / "memory.jsonl"),
        debug_store_path=str(base / "debug.jsonl"),
        activity_store_path=str(base / "activity.jsonl"),
    )


class CommandParserSmokeTest(unittest.TestCase):
    def test_parses_help_slash_command(self) -> None:
        parsed = parse_command("/help")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "help")
        self.assertEqual(parsed.command_kind, "info")
        self.assertGreaterEqual(parsed.confidence, 0.9)

    def test_parses_macos_phrase_command(self) -> None:
        parsed = parse_command("Tuli observa macos")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "macos")
        self.assertEqual(parsed.command_kind, "system")

    def test_parses_apps_list_command(self) -> None:
        parsed = parse_command("qué aplicaciones puedes abrir")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "apps")
        self.assertEqual(parsed.command_kind, "system")

    def test_parses_permissions_slash_command(self) -> None:
        parsed = parse_command("/permissions")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "permissions")
        self.assertEqual(parsed.command_kind, "system")

    def test_parses_windows_slash_command(self) -> None:
        parsed = parse_command("/windows")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "windows")
        self.assertEqual(parsed.command_kind, "system")

    def test_parses_layout_status_command(self) -> None:
        parsed = parse_command("/layout status")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "layout")
        self.assertEqual(parsed.command_args, ("status",))

    def test_parses_layout_split_command(self) -> None:
        parsed = parse_command("/layout split")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "layout")
        self.assertEqual(parsed.command_args, ("split",))

    def test_parses_layout_preview_command(self) -> None:
        parsed = parse_command("/layout preview")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "layout")
        self.assertEqual(parsed.command_args, ("preview",))

    def test_parses_layout_clear_command(self) -> None:
        parsed = parse_command("/layout clear")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "layout")
        self.assertEqual(parsed.command_args, ("clear",))

    def test_parses_window_native_commands(self) -> None:
        for text, action in (
            ("/window native left", "left"),
            ("/window native right", "right"),
            ("/window native fill", "fill"),
            ("/window native center", "center"),
            ("/window native top", "top"),
            ("/window native bottom", "bottom"),
            ("/window native top-left", "top-left"),
            ("/window native top-right", "top-right"),
            ("/window native bottom-left", "bottom-left"),
            ("/window native bottom-right", "bottom-right"),
        ):
            with self.subTest(text=text):
                parsed = parse_command(text)
                self.assertTrue(parsed.is_command)
                self.assertEqual(parsed.command_name, "window")
                self.assertEqual(parsed.command_args, ("native", action))
                self.assertEqual(parsed.command_kind, "system")

    def test_parses_layout_native_aliases(self) -> None:
        for text, action in (
            ("/layout native left", "left"),
            ("/layout native right", "right"),
            ("/layout native fill", "fill"),
            ("/layout native quarters", "quarters"),
        ):
            with self.subTest(text=text):
                parsed = parse_command(text)
                self.assertTrue(parsed.is_command)
                self.assertEqual(parsed.command_name, "layout")
                self.assertEqual(parsed.command_args, ("native", action))

    def test_parses_space_slash_commands(self) -> None:
        for text, args in (
            ("/space next", ("next",)),
            ("/space previous", ("previous",)),
            ("/space mission-control", ("mission-control",)),
            ("/space status", ("status",)),
            ("/space 1", ("1",)),
            ("/space 2", ("2",)),
            ("/desktop next", ("next",)),
            ("/desktop 2", ("2",)),
        ):
            with self.subTest(text=text):
                parsed = parse_command(text)
                self.assertTrue(parsed.is_command)
                self.assertEqual(parsed.command_name, "space")
                self.assertEqual(parsed.command_args, args)
                self.assertEqual(parsed.command_kind, "system")

    def test_parses_space_phrases(self) -> None:
        for text, args in (
            ("Tuli ve al escritorio siguiente", ("next",)),
            ("Tuli cambia al escritorio anterior", ("previous",)),
            ("Tuli abre Mission Control", ("mission-control",)),
            ("Tuli ve al escritorio 2", ("2",)),
        ):
            with self.subTest(text=text):
                parsed = parse_command(text)
                self.assertTrue(parsed.is_command)
                self.assertEqual(parsed.command_name, "space")
                self.assertEqual(parsed.command_args, args)

    def test_parses_native_window_phrases(self) -> None:
        for text, action in (
            ("Tuli pon esta ventana a la izquierda", "left"),
            ("Tuli pon esta ventana a la derecha", "right"),
            ("Tuli llena esta ventana", "fill"),
            ("Tuli centra esta ventana", "center"),
            ("Tuli ponla arriba a la izquierda", "top-left"),
            ("Tuli organiza las ventanas en cuartos", "quarters"),
            ("reorganiza las ventanas", "quarters"),
        ):
            with self.subTest(text=text):
                parsed = parse_command(text)
                self.assertTrue(parsed.is_command)
                self.assertEqual(parsed.command_name, "window")
                self.assertEqual(parsed.command_args, ("native", action))
                self.assertEqual(parsed.command_kind, "system")

    def test_parses_open_app_phrase_command(self) -> None:
        parsed = parse_command("abre Safari")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "open")
        self.assertEqual(parsed.command_kind, "system")
        self.assertEqual(parsed.command_args, ("Safari",))

    def test_parses_open_app_reference_command(self) -> None:
        parsed = parse_command("ábrela")
        self.assertTrue(parsed.is_command)
        self.assertEqual(parsed.command_name, "open")
        self.assertEqual(parsed.command_kind, "system")
        self.assertEqual(parsed.command_args, ())


class PermissionSmokeTest(unittest.TestCase):
    def test_safe_help_is_allowed(self) -> None:
        parsed = parse_command("/help")
        decision = evaluate_permission(parsed)
        self.assertEqual(decision.status, "allow")

    def test_forget_requires_confirmation(self) -> None:
        parsed = parse_command("/forget memoria vieja")
        decision = evaluate_permission(parsed)
        self.assertEqual(decision.status, "confirm")
        self.assertTrue(decision.requires_confirmation)


class ConfigSmokeTest(unittest.TestCase):
    def test_router_model_default_is_configured(self) -> None:
        self.assertEqual(TuliBrainConfig().router_model, "qwen3-0.6b-ud-q8-k-xl-local:latest")

    @patch.dict("os.environ", {"TULI_ROUTER_MODEL": "router-test-model"}, clear=False)
    def test_router_model_can_be_overridden(self) -> None:
        self.assertEqual(load_config().router_model, "router-test-model")

    def test_context_budget_defaults_are_configured(self) -> None:
        config = TuliBrainConfig()

        self.assertEqual(config.chat_num_ctx, 32768)
        self.assertEqual(config.chat_num_predict, 600)
        self.assertEqual(config.router_num_ctx, 8192)
        self.assertEqual(config.router_num_predict, 500)
        self.assertEqual(config.ollama_keep_alive, "10m")

    @patch.dict(
        "os.environ",
        {
            "TULI_CHAT_NUM_CTX": "12000",
            "TULI_CHAT_NUM_PREDICT": "700",
            "TULI_ROUTER_NUM_CTX": "9000",
            "TULI_ROUTER_NUM_PREDICT": "550",
            "TULI_OLLAMA_KEEP_ALIVE": "15m",
        },
        clear=False,
    )
    def test_context_budget_env_overrides_are_applied(self) -> None:
        config = load_config()

        self.assertEqual(config.chat_num_ctx, 12000)
        self.assertEqual(config.chat_num_predict, 700)
        self.assertEqual(config.router_num_ctx, 9000)
        self.assertEqual(config.router_num_predict, 550)
        self.assertEqual(config.ollama_keep_alive, "15m")

    @patch.dict(
        "os.environ",
        {
            "TULI_CHAT_NUM_CTX": "oops",
            "TULI_CHAT_NUM_PREDICT": "100",
            "TULI_ROUTER_NUM_CTX": "70000",
            "TULI_ROUTER_NUM_PREDICT": "-4",
        },
        clear=False,
    )
    def test_context_budget_invalid_values_fall_back_or_clamp_safely(self) -> None:
        config = load_config()

        self.assertEqual(config.chat_num_ctx, 32768)
        self.assertEqual(config.chat_num_predict, 600)
        self.assertEqual(config.router_num_ctx, 40960)
        self.assertEqual(config.router_num_predict, 500)


class OllamaPayloadSmokeTest(unittest.TestCase):
    @patch("tuli_brain.providers.ollama_local._post_json")
    def test_chat_payload_includes_num_ctx_and_keep_alive(self, mock_post_json) -> None:
        mock_post_json.return_value = {"message": {"content": "ok"}}
        config = TuliBrainConfig(chat_num_ctx=32768, chat_num_predict=600, ollama_keep_alive="10m")

        chat("hello", config=config)

        payload = mock_post_json.call_args.args[1]
        self.assertEqual(payload["options"]["num_ctx"], 32768)
        self.assertEqual(payload["options"]["num_predict"], 600)
        self.assertEqual(payload["keep_alive"], "10m")

    @patch("tuli_brain.providers.ollama_local._post_json")
    def test_chat_explicit_num_predict_overrides_config_default(self, mock_post_json) -> None:
        mock_post_json.return_value = {"message": {"content": "ok"}}
        config = TuliBrainConfig(chat_num_ctx=32768, chat_num_predict=600, ollama_keep_alive="10m")

        chat("hello", config=config, num_predict=42)

        payload = mock_post_json.call_args.args[1]
        self.assertEqual(payload["options"]["num_predict"], 42)

    @patch("tuli_brain.providers.ollama_local._post_json")
    def test_router_payload_includes_num_ctx_and_keep_alive(self, mock_post_json) -> None:
        mock_post_json.return_value = {"message": {"content": '{"route":"chat"}'}}
        config = TuliBrainConfig(router_num_ctx=8192, router_num_predict=500, ollama_keep_alive="10m")

        chat_raw_messages([{"role": "user", "content": "hello"}], config=config, model="router-model")

        payload = mock_post_json.call_args.args[1]
        self.assertEqual(payload["options"]["num_ctx"], 8192)
        self.assertEqual(payload["options"]["num_predict"], 500)
        self.assertEqual(payload["keep_alive"], "10m")

    @patch("tuli_brain.router.ai_intent_router.chat_raw_messages")
    def test_ai_router_passes_router_context_budget(self, mock_chat_raw_messages) -> None:
        mock_chat_raw_messages.return_value = SimpleNamespace(text='{"route":"chat"}')
        config = TuliBrainConfig(router_model="router-model", router_num_ctx=8192, router_num_predict=500, ollama_keep_alive="10m")

        AIIntentRouter().route("Tuli what can you do", config)

        self.assertEqual(mock_chat_raw_messages.call_args.kwargs["num_ctx"], 8192)
        self.assertEqual(mock_chat_raw_messages.call_args.kwargs["num_predict"], 500)
        self.assertEqual(mock_chat_raw_messages.call_args.kwargs["keep_alive"], "10m")

    def test_token_estimate_returns_positive_count(self) -> None:
        self.assertGreater(estimate_tokens_from_text("hello world"), 0)
        self.assertGreater(estimate_messages_tokens([{"role": "user", "content": "hello world"}]), 0)

    def test_token_telemetry_percent_is_calculated(self) -> None:
        telemetry = build_token_telemetry(
            model_role="chat",
            model="qwen3:1.7b",
            num_ctx=100,
            num_predict=20,
            keep_alive="10m",
            messages=[{"role": "user", "content": "a" * 80}],
            phase="before",
            actual_prompt_tokens=25,
        )

        self.assertGreater(telemetry.context_percent_estimated, 0.0)
        self.assertEqual(telemetry.context_percent_actual, 25.0)

    def test_telemetry_event_has_expected_type(self) -> None:
        telemetry = build_token_telemetry(
            model_role="router",
            model="router-model",
            num_ctx=8192,
            num_predict=500,
            keep_alive="10m",
            messages=[{"role": "user", "content": "hello"}],
            phase="before",
        )

        event = telemetry_to_event(telemetry)
        self.assertEqual(event["type"], "token_context_update")

    @patch("tuli_brain.providers.ollama_local.emit_token_context_update")
    @patch("tuli_brain.providers.ollama_local._post_json")
    def test_chat_provider_emits_before_and_after_telemetry(self, mock_post_json, mock_emit) -> None:
        mock_post_json.return_value = {
            "message": {"content": "ok"},
            "prompt_eval_count": 40,
            "eval_count": 10,
            "prompt_eval_duration": 100,
            "eval_duration": 200,
            "total_duration": 300,
        }
        config = TuliBrainConfig(chat_num_ctx=32768, chat_num_predict=600, ollama_keep_alive="10m")

        chat("hello", config=config)

        self.assertEqual(mock_emit.call_count, 2)
        before = mock_emit.call_args_list[0].args[1]
        after = mock_emit.call_args_list[1].args[1]
        self.assertEqual(before.model_role, "chat")
        self.assertEqual(before.phase, "before")
        self.assertEqual(after.phase, "after")
        self.assertEqual(after.actual_prompt_tokens, 40)

    @patch("tuli_brain.providers.ollama_local.emit_token_context_update")
    @patch("tuli_brain.providers.ollama_local._post_json")
    def test_router_provider_emits_router_telemetry(self, mock_post_json, mock_emit) -> None:
        mock_post_json.return_value = {"message": {"content": '{"route":"chat"}'}}
        config = TuliBrainConfig(router_num_ctx=8192, router_num_predict=500, ollama_keep_alive="10m")

        chat_raw_messages([{"role": "user", "content": "hello"}], config=config, model_role="router")

        before = mock_emit.call_args_list[0].args[1]
        self.assertEqual(before.model_role, "router")

    @patch("tuli_brain.events.token_events.append_jsonl_event", side_effect=OSError("nope"))
    @patch("tuli_brain.providers.ollama_local._post_json")
    def test_telemetry_write_failure_does_not_break_chat_response(self, mock_post_json, mock_append) -> None:
        mock_post_json.return_value = {"message": {"content": "ok"}}
        config = TuliBrainConfig()

        result = chat("hello", config=config)

        self.assertEqual(result.text, "ok")

    def test_watch_token_context_parses_token_events(self) -> None:
        event = parse_token_event('{"type":"token_context_update","model_role":"chat","model":"qwen3:1.7b"}')

        self.assertIsNotNone(event)
        self.assertEqual(event["model_role"], "chat")


class InspectorSnapshotSmokeTest(unittest.TestCase):
    def test_summarize_event_stream_extracts_latest_router_chat_and_route(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            stream_path = Path(tmpdir) / "events.jsonl"
            stream_path.write_text(
                "\n".join(
                    [
                        '{"type":"token_context_update","model_role":"router","model":"router-model","num_ctx":8192,"num_predict":500,"phase":"after"}',
                        "not-json",
                        '{"type":"ai_router_tool","tool_name":"window.native_tiling"}',
                        '{"type":"token_context_update","model_role":"chat","model":"chat-model","num_ctx":32768,"num_predict":600,"phase":"after","error":"timeout"}',
                    ]
                ),
                encoding="utf-8",
            )

            summary = summarize_event_stream(stream_path, recent_lines=5)

            self.assertTrue(summary["exists"])
            self.assertEqual(summary["latest_router"]["model"], "router-model")
            self.assertEqual(summary["latest_chat"]["model"], "chat-model")
            self.assertEqual(summary["last_route"], "ai_router_tool")
            self.assertEqual(len(summary["recent_errors"]), 1)

    def test_summarize_event_stream_missing_file_returns_safe_empty_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            summary = summarize_event_stream(Path(tmpdir) / "missing.jsonl")

            self.assertFalse(summary["exists"])
            self.assertIsNone(summary["latest_router"])
            self.assertIsNone(summary["latest_chat"])
            self.assertEqual(summary["recent_events"], [])

    @patch("tuli_brain.debug.inspector_snapshot.SpaceControl")
    @patch("tuli_brain.debug.inspector_snapshot.LayoutManager")
    @patch("tuli_brain.debug.inspector_snapshot.list_known_applications")
    @patch("tuli_brain.debug.inspector_snapshot.probe_visible_windows")
    @patch("tuli_brain.debug.inspector_snapshot.check_macos_permissions")
    @patch("tuli_brain.debug.inspector_snapshot.MacOSControl")
    def test_build_inspector_snapshot_returns_required_sections_without_live_services(
        self,
        mock_macos_control,
        mock_permissions,
        mock_probe_windows,
        mock_list_apps,
        mock_layout_manager,
        mock_space_control,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            config = make_test_config(tmpdir)
            Path(config.event_stream_path).write_text(
                '{"type":"token_context_update","model_role":"router","model":"router-model","num_ctx":8192,"num_predict":500,"phase":"after"}\n'
                '{"type":"chat_reply"}\n',
                encoding="utf-8",
            )
            Path(config.debug_store_path).write_text(
                json.dumps(
                    {
                        "command": "tool_chain",
                        "mode": "tool",
                        "user_text": "Tuli what windows do you see",
                        "raw_response": json.dumps({"command": {"type": "tool_chain"}}),
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            permissions = PermissionCheckResult(
                source="macos_permissions",
                accessibility="granted",
                screen_recording="granted",
                automation_system_events="available",
            )
            mock_permissions.return_value = permissions
            mock_macos_control.return_value.snapshot.return_value = SimpleNamespace(
                to_dict=lambda: {
                    "ok": True,
                    "observation": {
                        "app_name": "Safari",
                        "window_title": "Docs",
                    },
                }
            )
            mock_probe_windows.return_value = WindowProbeResult(
                ok=True,
                source="quartz",
                permissions=permissions,
                windows=(
                    WindowRecord(
                        app_name="Finder",
                        window_title="Docs",
                        bounds=WindowBounds(x=10, y=20, width=800, height=600),
                        is_frontmost=True,
                        source="quartz",
                    ),
                ),
            )
            mock_list_apps.return_value = ["Safari", "Notes"]
            mock_layout_manager.return_value.status.return_value = SimpleNamespace(to_dict=lambda: {"layout": "none"})
            mock_layout_manager.return_value.format_status.return_value = "No saved layout."
            mock_space_control.return_value.status.return_value = SimpleNamespace(
                to_dict=lambda: {
                    "success": True,
                    "current_space_managed_id": 620,
                    "available_spaces_detected": 4,
                }
            )

            snapshot = build_inspector_snapshot(config, recent_lines=6, include_raw_paths=True)

            for key in ("agent", "permissions", "frontmost", "windows", "apps", "layout", "spaces", "llm", "recent", "raw"):
                self.assertIn(key, snapshot)
            self.assertEqual(snapshot["agent"]["active_model"], "qwen3:1.7b")
            self.assertEqual(snapshot["frontmost"]["observation"]["app_name"], "Safari")
            self.assertEqual(snapshot["windows"]["count"], 1)
            self.assertEqual(snapshot["apps"]["count"], 2)
            self.assertEqual(snapshot["layout"]["summary"], "No saved layout.")
            self.assertEqual(snapshot["spaces"]["current_space_managed_id"], 620)
            self.assertEqual(snapshot["llm"]["router"]["model"], "router-model")
            self.assertEqual(snapshot["recent"]["last_route"], "chat_reply")
            self.assertIn("event_stream", snapshot["raw"]["paths"])

    @patch("tuli_brain.__main__.build_inspector_snapshot")
    @patch("tuli_brain.__main__.load_config")
    def test_inspect_cli_prints_structured_json_snapshot(self, mock_load_config, mock_build_snapshot) -> None:
        from contextlib import redirect_stdout
        from io import StringIO

        from tuli_brain.__main__ import main

        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_build_snapshot.return_value = {
                "agent": {},
                "permissions": {},
                "frontmost": {},
                "windows": {},
                "apps": {},
                "layout": {},
                "spaces": {},
                "llm": {},
                "recent": {},
                "raw": {},
            }
            stdout = StringIO()
            argv = ["tuli_brain", "inspect", "--json"]

            with patch.object(sys, "argv", argv), redirect_stdout(stdout):
                exit_code = main()

            self.assertEqual(exit_code, 0)
            payload = json.loads(stdout.getvalue())
            self.assertIn("agent", payload)
            self.assertIn("llm", payload)


class ToolCatalogSmokeTest(unittest.TestCase):
    def test_default_tool_catalog_contains_foundation_tools(self) -> None:
        self.assertTrue(DEFAULT_TOOL_CATALOG.has("window.native_tiling"))
        self.assertTrue(DEFAULT_TOOL_CATALOG.has("space.next"))
        self.assertTrue(DEFAULT_TOOL_CATALOG.has("macos.open_app"))
        self.assertTrue(DEFAULT_TOOL_CATALOG.has("memory.remember"))
        self.assertTrue(DEFAULT_TOOL_CATALOG.has("avatar.bubble_show"))

    def test_tool_spec_to_dict(self) -> None:
        spec = ToolSpec(
            name="window.native_tiling",
            category="window_layout",
            description="Run native tiling.",
            aliases=("window.native",),
            input_schema={"action": "string"},
            risk_level="safe",
            requires_confirmation=False,
            executor_ref="command:window.native",
            enabled=True,
            debug_command="/window native left",
        )

        payload = spec.to_dict()

        self.assertEqual(payload["name"], "window.native_tiling")
        self.assertEqual(payload["aliases"], ("window.native",))
        self.assertEqual(payload["input_schema"]["action"], "string")

    def test_tool_call_to_dict(self) -> None:
        call = ToolCall(
            tool_name="space.next",
            arguments={"speed": "normal"},
            source_text="go to the next desktop",
            confidence=0.9,
            requires_confirmation=False,
            response_text="Switching spaces.",
            bubble_text="Next desktop.",
            console_text="space.next",
        )

        payload = call.to_dict()

        self.assertEqual(payload["tool_name"], "space.next")
        self.assertEqual(payload["arguments"]["speed"], "normal")
        self.assertAlmostEqual(payload["confidence"], 0.9)

    def test_tool_result_to_dict(self) -> None:
        result = ToolResult(
            success=True,
            tool_name="space.status",
            arguments={"verbose": False},
            result_text="Space status ready.",
            bubble_text="Space status ready.",
            console_text="space.status",
            event_payload={"type": "space_status"},
            error=None,
        )

        payload = result.to_dict()

        self.assertTrue(payload["success"])
        self.assertEqual(payload["arguments"]["verbose"], False)
        self.assertEqual(payload["event_payload"]["type"], "space_status")

    def test_tool_catalog_get_and_find_by_alias(self) -> None:
        catalog = ToolCatalog()
        spec = ToolSpec(
            name="macos.open_app",
            category="macos_action",
            description="Open an app.",
            aliases=("open", "launch"),
            input_schema={"app_name": "string"},
            risk_level="safe",
            requires_confirmation=False,
            executor_ref="command:open",
            enabled=True,
        )
        catalog.register(spec)

        self.assertEqual(catalog.get("macos.open_app"), spec)
        self.assertEqual(catalog.find_by_alias("launch"), "macos.open_app")

    def test_tool_executor_fails_safely_for_unknown_tool(self) -> None:
        executor = ToolExecutor()
        result = executor.execute(ToolCall(tool_name="missing.tool", arguments={}, source_text="missing"))

        self.assertFalse(result.success)
        self.assertEqual(result.tool_name, "missing.tool")
        self.assertIn("unknown tool", result.error or "")

    @patch("tuli_brain.tools.tool_executor.check_macos_permissions")
    def test_tool_executor_runs_macos_permissions_check(self, mock_check) -> None:
        permissions = PermissionCheckResult(
            source="macos_permissions",
            accessibility="granted",
            screen_recording="granted",
            automation_system_events="available",
        )
        mock_check.return_value = permissions

        result = ToolExecutor().execute(ToolCall(tool_name="macos.permissions_check"))

        self.assertTrue(result.success)
        self.assertIn("macOS permissions", result.console_text)
        self.assertEqual(result.bubble_text, "Checking macOS permissions.")

    @patch("tuli_brain.tools.tool_executor.probe_visible_windows")
    def test_tool_executor_runs_macos_visible_windows(self, mock_probe) -> None:
        permissions = PermissionCheckResult(
            source="macos_permissions",
            accessibility="granted",
            screen_recording="granted",
            automation_system_events="available",
        )
        mock_probe.return_value = WindowProbeResult(
            ok=True,
            source="quartz",
            permissions=permissions,
            windows=(
                WindowRecord(
                    app_name="Finder",
                    window_title="Docs",
                    bounds=WindowBounds(x=10, y=20, width=800, height=600),
                    is_frontmost=True,
                    source="quartz",
                ),
            ),
        )

        result = ToolExecutor().execute(ToolCall(tool_name="macos.visible_windows"))

        self.assertTrue(result.success)
        self.assertIn("Finder", result.console_text)
        self.assertEqual(result.bubble_text, "Checking visible windows.")

    @patch("tuli_brain.tools.tool_executor.MacOSControl")
    def test_tool_executor_runs_macos_observe_frontmost(self, mock_control) -> None:
        mock_control.return_value.snapshot.return_value = SimpleNamespace(
            ok=True,
            observation=SimpleNamespace(app_name="Safari", window_title="Docs", to_dict=lambda: {"app_name": "Safari", "window_title": "Docs"}),
            error=None,
        )

        result = ToolExecutor().execute(ToolCall(tool_name="macos.observe_frontmost"))

        self.assertTrue(result.success)
        self.assertIn("Safari", result.console_text)
        self.assertEqual(result.bubble_text, "Checking the active app.")

    @patch("tuli_brain.tools.tool_executor.list_known_applications")
    def test_tool_executor_runs_macos_list_apps(self, mock_apps) -> None:
        mock_apps.return_value = ["Safari", "Notes"]

        result = ToolExecutor().execute(ToolCall(tool_name="macos.list_apps"))

        self.assertTrue(result.success)
        self.assertIn("Safari", result.console_text)
        self.assertEqual(result.bubble_text, "Checking available apps.")

    def test_tool_executor_window_native_tiling_invalid_action_fails_safely(self) -> None:
        result = ToolExecutor().execute(
            ToolCall(tool_name="window.native_tiling", arguments={"action": "bad-action"}, source_text="test")
        )

        self.assertFalse(result.success)
        self.assertIn("Unsupported native tiling action", result.error or "")
        self.assertNotEqual(result.bubble_text, result.console_text)

    @patch("tuli_brain.tools.tool_executor.SpaceControl")
    def test_tool_executor_runs_space_status(self, mock_space_control) -> None:
        mock_space_control.return_value.status.return_value = SimpleNamespace(
            success=True,
            method="defaults_read_com_apple_spaces",
            monitors=2,
            current_space_managed_id=620,
            available_spaces_detected=5,
            note="macOS uses internal ManagedSpaceID values, not simple Desktop numbers.",
            reason=None,
            to_dict=lambda: {
                "success": True,
                "method": "defaults_read_com_apple_spaces",
                "monitors": 2,
                "current_space_managed_id": 620,
                "available_spaces_detected": 5,
                "note": "macOS uses internal ManagedSpaceID values, not simple Desktop numbers.",
                "reason": None,
            },
        )

        result = ToolExecutor().execute(ToolCall(tool_name="space.status"))

        self.assertTrue(result.success)
        self.assertIn("current_space_managed_id", result.console_text)
        self.assertEqual(result.bubble_text, "Checking desktop spaces.")

    @patch("tuli_brain.tools.tool_executor.SpaceControl")
    def test_tool_executor_runs_space_next(self, mock_space_control) -> None:
        mock_space_control.return_value.next_space.return_value = SpaceControlResult(action="next", success=True, key_code=124)

        result = ToolExecutor().execute(ToolCall(tool_name="space.next"))

        self.assertTrue(result.success)
        self.assertIn("Space control", result.console_text)
        self.assertEqual(result.bubble_text, "Switching to the next desktop.")

    @patch("tuli_brain.tools.tool_executor.SpaceControl")
    def test_tool_executor_runs_space_previous(self, mock_space_control) -> None:
        mock_space_control.return_value.previous_space.return_value = SpaceControlResult(action="previous", success=True, key_code=123)

        result = ToolExecutor().execute(ToolCall(tool_name="space.previous"))

        self.assertTrue(result.success)
        self.assertEqual(result.bubble_text, "Returning to the previous desktop.")

    @patch("tuli_brain.tools.tool_executor.SpaceControl")
    def test_tool_executor_runs_space_mission_control(self, mock_space_control) -> None:
        mock_space_control.return_value.mission_control.return_value = SpaceControlResult(action="mission-control", success=True, key_code=126)

        result = ToolExecutor().execute(ToolCall(tool_name="space.mission_control"))

        self.assertTrue(result.success)
        self.assertEqual(result.bubble_text, "Opening Mission Control.")

    def test_tool_executor_open_app_missing_argument_fails_safely(self) -> None:
        result = ToolExecutor().execute(ToolCall(tool_name="macos.open_app", arguments={}))

        self.assertFalse(result.success)
        self.assertIn("missing argument", result.error or "")

    @patch("tuli_brain.tools.tool_executor.load_config")
    def test_tool_executor_memory_inspect(self, mock_load_config) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)

            result = ToolExecutor().execute(ToolCall(tool_name="memory.inspect"))

            self.assertTrue(result.success)
            self.assertIn("count:", result.console_text)
            self.assertEqual(result.bubble_text, "Checking memory.")

    def test_memory_forget_requires_confirmation(self) -> None:
        result = ToolExecutor().execute(
            ToolCall(
                tool_name="memory.forget",
                arguments={"query": "algo"},
                requires_confirmation=False,
            )
        )

        self.assertFalse(result.success)
        self.assertIn("confirmation required", result.error or "")


class IntentResolverSmokeTest(unittest.TestCase):
    def test_intent_resolver_bypasses_slash_commands(self) -> None:
        result = IntentResolver().resolve("/window native right")

        self.assertEqual(result.intent_name, "none")
        self.assertEqual(result.tool_name, "")
        self.assertEqual(result.metadata["bypass"], "slash_command")

    def test_intent_resolver_bypasses_slash_open_command(self) -> None:
        result = IntentResolver().resolve("/open Chrome")

        self.assertEqual(result.intent_name, "none")
        self.assertEqual(result.tool_name, "")
        self.assertEqual(result.metadata["bypass"], "slash_command")

    @patch("tuli_brain.intents.app_resolver.list_known_applications")
    def test_intent_resolver_open_browser(self, mock_apps) -> None:
        mock_apps.return_value = ["Google Chrome", "Safari", "Terminal"]

        result = IntentResolver().resolve("Tuli open browser")

        self.assertEqual(result.tool_name, "macos.open_app")
        self.assertEqual(result.arguments["app_name"], "Google Chrome")
        self.assertEqual(result.bubble_text, "Opening Google Chrome.")

    @patch("tuli_brain.intents.app_resolver.list_known_applications")
    def test_intent_resolver_open_editor(self, mock_apps) -> None:
        mock_apps.return_value = ["Visual Studio Code", "Safari", "Terminal"]

        result = IntentResolver().resolve("Tuli open editor")

        self.assertEqual(result.tool_name, "macos.open_app")
        self.assertEqual(result.arguments["app_name"], "Visual Studio Code")

    def test_intent_resolver_visible_windows(self) -> None:
        result = IntentResolver().resolve("Tuli what windows do you see")

        self.assertEqual(result.tool_name, "macos.visible_windows")

    def test_intent_resolver_observe_frontmost(self) -> None:
        result = IntentResolver().resolve("Tuli what app is active")

        self.assertEqual(result.tool_name, "macos.observe_frontmost")

    def test_intent_resolver_permissions(self) -> None:
        result = IntentResolver().resolve("Tuli check permissions")

        self.assertEqual(result.tool_name, "macos.permissions_check")

    def test_intent_resolver_window_right(self) -> None:
        result = IntentResolver().resolve("Tuli move this window to the right")

        self.assertEqual(result.tool_name, "window.native_tiling")
        self.assertEqual(result.arguments["action"], "right")
        self.assertEqual(result.bubble_text, "Preparing window action.")

    def test_intent_resolver_window_fill(self) -> None:
        result = IntentResolver().resolve("Tuli fill this window")

        self.assertEqual(result.tool_name, "window.native_tiling")
        self.assertEqual(result.arguments["action"], "fill")

    def test_intent_resolver_space_previous(self) -> None:
        result = IntentResolver().resolve("Tuli switch to the previous desktop")

        self.assertEqual(result.tool_name, "space.previous")
        self.assertEqual(result.bubble_text, "Preparing desktop action.")

    def test_intent_resolver_space_mission_control(self) -> None:
        result = IntentResolver().resolve("Tuli open Mission Control")

        self.assertEqual(result.tool_name, "space.mission_control")

    def test_intent_resolver_memory_remember(self) -> None:
        result = IntentResolver().resolve("Tuli remember that this project is called Inma")

        self.assertEqual(result.tool_name, "memory.remember")
        self.assertEqual(result.arguments["text"], "this project is called inma")

    def test_intent_resolver_memory_forget_requires_confirmation(self) -> None:
        result = IntentResolver().resolve("Tuli forget this")

        self.assertEqual(result.tool_name, "memory.forget")
        self.assertTrue(result.requires_confirmation)

    def test_intent_resolver_spanish_aliases_still_work(self) -> None:
        windows = IntentResolver().resolve("Tuli pon esta ventana a la derecha")
        browser = IntentResolver().resolve("Tuli abre navegador")

        self.assertEqual(windows.tool_name, "window.native_tiling")
        self.assertEqual(browser.tool_name, "macos.open_app")


class AIRouterSmokeTest(unittest.TestCase):
    def test_router_valid_tool_json_parses(self) -> None:
        decision = AIIntentRouter().parse_response(
            "Tuli move it left",
            '{"route":"tool","tool_name":"window.native_tiling","arguments":{"action":"left"},"confidence":0.92,"clarification":"","reason":"window left"}',
        )

        self.assertEqual(decision.route, "tool")
        self.assertEqual(decision.tool_name, "window.native_tiling")

    def test_router_valid_chat_json_parses(self) -> None:
        decision = AIIntentRouter().parse_response(
            "Tuli tell me about sales",
            '{"route":"chat","tool_name":"","arguments":{},"confidence":0.9,"clarification":"","reason":"general question"}',
        )

        self.assertEqual(decision.route, "chat")

    def test_router_valid_clarify_json_parses(self) -> None:
        decision = AIIntentRouter().parse_response(
            "Tuli open it",
            '{"route":"clarify","tool_name":"macos.open_app","arguments":{},"confidence":0.72,"clarification":"Which app do you want me to open?","reason":"missing app"}',
        )

        self.assertEqual(decision.route, "clarify")
        self.assertEqual(decision.clarification, "Which app do you want me to open?")

    def test_router_markdown_fenced_json_parses(self) -> None:
        decision = AIIntentRouter().parse_response(
            "Tuli move it left",
            '```json\n{"route":"tool","tool_name":"window.native_tiling","arguments":{"action":"left"},"confidence":0.92}\n```',
        )

        self.assertEqual(decision.route, "tool")
        self.assertEqual(decision.arguments["action"], "left")

    def test_router_invalid_json_returns_safe_error(self) -> None:
        decision = AIIntentRouter().parse_response("Tuli tell me about sales", "not json")

        self.assertEqual(decision.route, "chat")
        self.assertEqual(decision.error, "invalid_router_json")

    def test_router_invalid_json_action_like_prefers_clarify(self) -> None:
        decision = AIIntentRouter().parse_response("Tuli move it left", "not json")

        self.assertEqual(decision.route, "clarify")
        self.assertEqual(decision.error, "invalid_router_json")

    def test_router_unknown_tool_is_rejected_by_validation(self) -> None:
        decision = AIIntentRouter().validate_decision(
            RouterDecision(route="tool", tool_name="made.up.tool", arguments={}, confidence=0.8, raw_text="test", raw_response="{}")
        )

        self.assertEqual(decision.route, "clarify")
        self.assertEqual(decision.error, "unknown_tool")

    def test_router_unknown_route_is_rejected(self) -> None:
        decision = AIIntentRouter().validate_decision(
            RouterDecision(route="banana", confidence=0.8, raw_text="test", raw_response="{}")
        )

        self.assertEqual(decision.route, "chat")
        self.assertEqual(decision.error, "unknown_route")

    def test_router_confidence_is_clamped(self) -> None:
        decision = AIIntentRouter().parse_response(
            "Tuli tell me about sales",
            '{"route":"chat","confidence":9.0}',
        )

        self.assertEqual(decision.confidence, 1.0)

    def test_router_missing_required_args_produces_clarification(self) -> None:
        decision = AIIntentRouter().validate_decision(
            RouterDecision(route="tool", tool_name="macos.open_app", arguments={}, confidence=0.8, raw_text="open it", raw_response="{}")
        )

        self.assertEqual(decision.route, "clarify")
        self.assertIn("Which app", decision.clarification)

    def test_router_disabled_tool_is_not_executable(self) -> None:
        decision = AIIntentRouter().validate_decision(
            RouterDecision(route="tool", tool_name="macos.focus_app", arguments={"app_name": "Safari"}, confidence=0.8, raw_text="focus safari", raw_response="{}")
        )

        self.assertEqual(decision.route, "clarify")
        self.assertEqual(decision.error, "disabled_tool")

    def test_router_partial_tool_json_is_repaired_for_move_left(self) -> None:
        decision = AIIntentRouter().validate_decision(
            RouterDecision(route="tool", tool_name="", arguments={}, confidence=0.0, raw_text="Tuli move it left", raw_response='{"route":"tool"}')
        )

        self.assertEqual(decision.route, "tool")
        self.assertEqual(decision.tool_name, "window.native_tiling")
        self.assertEqual(decision.arguments["action"], "left")

    def test_router_partial_tool_json_is_repaired_for_switch_back(self) -> None:
        decision = AIIntentRouter().validate_decision(
            RouterDecision(route="tool", tool_name="", arguments={}, confidence=0.0, raw_text="Tuli switch back", raw_response='{"route":"tool"}')
        )

        self.assertEqual(decision.route, "tool")
        self.assertEqual(decision.tool_name, "space.previous")

    def test_router_partial_tool_json_clarifies_open_it(self) -> None:
        decision = AIIntentRouter().validate_decision(
            RouterDecision(route="tool", tool_name="", arguments={}, confidence=0.0, raw_text="Tuli open it", raw_response='{"route":"tool"}')
        )

        self.assertEqual(decision.route, "clarify")
        self.assertIn("Which app", decision.clarification)

    def test_router_greeting_like_text_stays_chat(self) -> None:
        decision = AIIntentRouter().validate_decision(
            RouterDecision(route="tool", tool_name="macos.list_apps", arguments={}, confidence=0.91, raw_text="hola Tuli", raw_response='{"route":"tool","tool_name":"macos.list_apps"}')
        )

        self.assertEqual(decision.route, "chat")

    def test_router_switch_back_overrides_wrong_tool_guess(self) -> None:
        decision = AIIntentRouter().validate_decision(
            RouterDecision(route="tool", tool_name="macos.open_app", arguments={}, confidence=0.72, raw_text="Tuli switch back", raw_response='{"route":"tool","tool_name":"macos.open_app"}')
        )

        self.assertEqual(decision.route, "tool")
        self.assertEqual(decision.tool_name, "space.previous")

    def test_action_planner_low_confidence_does_not_execute(self) -> None:
        intent = IntentResolver().resolve("algo dificil de entender")
        plan = ActionPlanner().plan(intent)

        self.assertFalse(plan.should_execute)
        self.assertEqual(plan.reason, "low_confidence")

    def test_action_planner_tool_not_found_does_not_execute(self) -> None:
        from tuli_brain.intents.intent_types import IntentResult

        intent = IntentResult(
            intent_name="missing",
            tool_name="missing.tool",
            confidence=0.9,
            source_text="test",
        )
        plan = ActionPlanner().plan(intent)

        self.assertFalse(plan.should_execute)
        self.assertEqual(plan.reason, "tool_not_found")


class BrainToolChainSmokeTest(unittest.TestCase):
    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.ToolExecutor.execute")
    @patch("tuli_brain.brain.load_config")
    def test_natural_windows_uses_tool_chain(self, mock_load_config, mock_execute, mock_router_route) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(route="chat", confidence=0.0)
            mock_execute.return_value = ToolResult(
                success=True,
                tool_name="macos.visible_windows",
                arguments={},
                result_text="Window report",
                bubble_text="Checking visible windows.",
                console_text="Visible windows:\n- Finder",
                event_payload={"ok": True},
                error=None,
            )

            response = respond("Tuli what windows do you see")

            self.assertEqual(response["command"]["type"], "tool_chain")
            self.assertEqual(response["command"]["params"]["tool_name"], "macos.visible_windows")
            self.assertEqual(response["text"], "Visible windows:\n- Finder")
            self.assertEqual(response["actions"][0]["type"], "bubble_show")
            self.assertEqual(response["actions"][0]["text"], "Checking visible windows.")
            self.assertEqual(mock_execute.call_args.args[0].tool_name, "macos.visible_windows")
            mock_router_route.assert_not_called()

    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.ToolExecutor.execute")
    @patch("tuli_brain.brain.load_config")
    def test_natural_frontmost_uses_tool_chain(self, mock_load_config, mock_execute, mock_router_route) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(route="chat", confidence=0.0)
            mock_execute.return_value = ToolResult(
                success=True,
                tool_name="macos.observe_frontmost",
                arguments={},
                result_text="Observed macOS:\n- app_name: Safari",
                bubble_text="Checking the active app.",
                console_text="Observed macOS:\n- app_name: Safari",
            )

            response = respond("Tuli what app is active")

            self.assertEqual(response["command"]["params"]["tool_name"], "macos.observe_frontmost")
            self.assertEqual(mock_execute.call_args.args[0].tool_name, "macos.observe_frontmost")
            mock_router_route.assert_not_called()

    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.ToolExecutor.execute")
    @patch("tuli_brain.brain.load_config")
    def test_natural_window_right_uses_tool_chain(self, mock_load_config, mock_execute, mock_router_route) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(route="chat", confidence=0.0)
            mock_execute.return_value = ToolResult(
                success=True,
                tool_name="window.native_tiling",
                arguments={"action": "right"},
                result_text="Native window tiling:\n- action: right",
                bubble_text="Moving this window to the right.",
                console_text="Native window tiling:\n- action: right\n- method: system_events_window_menu\n- success: true",
            )

            response = respond("Tuli move this window to the right")

            self.assertEqual(response["command"]["params"]["tool_name"], "window.native_tiling")
            self.assertEqual(response["command"]["params"]["arguments"]["action"], "right")
            self.assertEqual(response["actions"][0]["text"], "Moving this window to the right.")
            self.assertNotEqual(response["actions"][0]["text"], response["text"])
            mock_router_route.assert_not_called()

    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.ToolExecutor.execute")
    @patch("tuli_brain.brain.load_config")
    def test_natural_space_previous_uses_tool_chain(self, mock_load_config, mock_execute, mock_router_route) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(route="chat", confidence=0.0)
            mock_execute.return_value = ToolResult(
                success=True,
                tool_name="space.previous",
                arguments={},
                result_text="Space control:\n- action: previous",
                bubble_text="Returning to the previous desktop.",
                console_text="Space control:\n- action: previous\n- method: system_events_keyboard_shortcut\n- success: true",
            )

            response = respond("Tuli switch to the previous desktop")

            self.assertEqual(response["command"]["params"]["tool_name"], "space.previous")
            self.assertEqual(mock_execute.call_args.args[0].tool_name, "space.previous")
            mock_router_route.assert_not_called()

    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.ToolExecutor.execute")
    @patch("tuli_brain.brain.load_config")
    def test_natural_space_mission_control_uses_tool_chain(self, mock_load_config, mock_execute, mock_router_route) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(route="chat", confidence=0.0)
            mock_execute.return_value = ToolResult(
                success=True,
                tool_name="space.mission_control",
                arguments={},
                result_text="Space control:\n- action: mission-control",
                bubble_text="Opening Mission Control.",
                console_text="Space control:\n- action: mission-control\n- method: system_events_keyboard_shortcut\n- success: true",
            )

            response = respond("Tuli abre Mission Control")

            self.assertEqual(response["command"]["params"]["tool_name"], "space.mission_control")
            mock_router_route.assert_not_called()

    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.ToolExecutor.execute")
    @patch("tuli_brain.brain.load_config")
    def test_natural_open_browser_uses_tool_chain(self, mock_load_config, mock_execute, mock_router_route) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(route="chat", confidence=0.0)
            mock_execute.return_value = ToolResult(
                success=True,
                tool_name="macos.open_app",
                arguments={"app_name": "Google Chrome"},
                result_text="Open app:\n- app_name: Google Chrome",
                bubble_text="Opening Google Chrome.",
                console_text="Open app:\n- app_name: Google Chrome\n- status: ok",
            )

            response = respond("Tuli open browser")

            self.assertEqual(response["command"]["params"]["tool_name"], "macos.open_app")
            self.assertEqual(response["command"]["params"]["arguments"]["app_name"], "Google Chrome")
            mock_router_route.assert_not_called()

    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.ollama_chat")
    @patch("tuli_brain.brain.load_config")
    def test_unknown_natural_text_falls_back_to_chat_model(self, mock_load_config, mock_ollama_chat, mock_router_route) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(route="chat", confidence=0.91, raw_text="x")
            mock_ollama_chat.return_value = SimpleNamespace(text="Respuesta del modelo.")

            response = respond("Tuli tell me something odd that you do not understand")

            self.assertEqual(response["command"]["type"], "chat_reply")
            self.assertIn("Respuesta del modelo.", response["text"])
            mock_ollama_chat.assert_called_once()

    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.load_config")
    def test_requires_confirmation_does_not_execute(self, mock_load_config, mock_router_route) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(route="chat", confidence=0.0)

            response = respond("Tuli olvida esto")

            self.assertEqual(response["command"]["type"], "tool_chain_confirmation_required")
            self.assertFalse(response["command"]["params"]["success"])
            self.assertIn("confirmation", response["actions"][0]["text"].lower())
            mock_router_route.assert_not_called()

    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.load_config")
    def test_slash_commands_still_use_legacy_path(self, mock_load_config, mock_router_route) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(route="chat", confidence=0.0)
            permissions = PermissionCheckResult(
                source="macos_permissions",
                accessibility="granted",
                screen_recording="granted",
                automation_system_events="available",
            )
            probe = WindowProbeResult(
                ok=True,
                source="quartz",
                permissions=permissions,
                windows=(
                    WindowRecord(
                        app_name="Finder",
                        window_title="Docs",
                        bounds=WindowBounds(x=10, y=20, width=800, height=600),
                        is_frontmost=True,
                        source="quartz",
                    ),
                ),
            )
            with patch("tuli_brain.brain.probe_visible_windows", return_value=probe):
                response = respond("/windows")

            self.assertEqual(response["command"]["type"], "windows")
            mock_router_route.assert_not_called()

    @patch("tuli_brain.brain.ToolExecutor.execute")
    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.load_config")
    def test_router_tool_executes_when_deterministic_misses(self, mock_load_config, mock_router_route, mock_execute) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(
                route="tool",
                tool_name="window.native_tiling",
                arguments={"action": "left"},
                confidence=0.92,
                reason="window left",
            )
            mock_execute.return_value = ToolResult(
                success=True,
                tool_name="window.native_tiling",
                arguments={"action": "left"},
                bubble_text="Moving this window to the left.",
                console_text="Native window tiling:\n- action: left",
            )

            response = respond("Tuli move it left")

            self.assertEqual(response["command"]["type"], "tool_chain")
            self.assertEqual(response["command"]["params"]["route_source"], "ai_router")
            self.assertEqual(mock_execute.call_args.args[0].tool_name, "window.native_tiling")
            self.assertEqual(mock_execute.call_args.args[0].arguments["action"], "left")

    @patch("tuli_brain.brain.ollama_chat")
    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.load_config")
    def test_router_chat_runs_normal_chat_model(self, mock_load_config, mock_router_route, mock_ollama_chat) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(route="chat", confidence=0.9, reason="general question")
            mock_ollama_chat.return_value = SimpleNamespace(text="Sales is about understanding demand.")

            response = respond("Tuli tell me about sales")

            self.assertEqual(response["command"]["type"], "chat_reply")
            mock_ollama_chat.assert_called_once()

    @patch("tuli_brain.brain.ollama_chat")
    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.load_config")
    def test_router_clarify_does_not_run_chat_model(self, mock_load_config, mock_router_route, mock_ollama_chat) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(
                route="clarify",
                tool_name="macos.open_app",
                confidence=0.72,
                clarification="Which app do you want me to open?",
                reason="missing app name",
            )

            response = respond("Tuli open it")

            self.assertEqual(response["command"]["type"], "ai_router_clarify")
            self.assertEqual(response["actions"][0]["text"], "Which app do you want me to open?")
            mock_ollama_chat.assert_not_called()

    @patch("tuli_brain.brain.ToolExecutor.execute")
    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.load_config")
    def test_router_disabled_tool_is_not_executed(self, mock_load_config, mock_router_route, mock_execute) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(
                route="tool",
                tool_name="macos.focus_app",
                arguments={"app_name": "Safari"},
                confidence=0.82,
            )

            response = respond("Tuli focus Safari")

            self.assertEqual(response["command"]["type"], "ai_router_clarify")
            mock_execute.assert_not_called()

    @patch("tuli_brain.brain.ToolExecutor.execute")
    @patch("tuli_brain.brain.AIIntentRouter.route")
    @patch("tuli_brain.brain.load_config")
    def test_router_missing_args_produce_clarification(self, mock_load_config, mock_router_route, mock_execute) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_router_route.return_value = RouterDecision(
                route="tool",
                tool_name="macos.open_app",
                arguments={},
                confidence=0.75,
            )

            response = respond("Tuli open it")

            self.assertEqual(response["command"]["type"], "ai_router_clarify")
            self.assertIn("Which app", response["text"])
            mock_execute.assert_not_called()


class LegacySlashBubbleSmokeTest(unittest.TestCase):
    @patch("tuli_brain.brain.NativeWindowTiling")
    @patch("tuli_brain.brain.load_config")
    def test_window_native_right_uses_short_bubble_but_keeps_technical_cli(self, mock_load_config, mock_native_tiling) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_native_tiling.return_value.apply.return_value = NativeTilingResult(
                action="right",
                method="system_events_window_menu",
                success=True,
                menu_path="Window > Move & Resize > Right",
                frontmost_app="Finder",
            )

            response = respond("/window native right")

            self.assertEqual(response["text"].splitlines()[0], "Native window tiling:")
            self.assertEqual(response["actions"][0]["type"], "bubble_show")
            self.assertEqual(response["actions"][0]["text"], "Moving this window to the right.")
            self.assertNotIn("Native window tiling:", response["actions"][0]["text"])
            self.assertNotIn("menu_path:", response["actions"][0]["text"])

    @patch("tuli_brain.brain.SpaceControl")
    @patch("tuli_brain.brain.load_config")
    def test_space_previous_uses_short_bubble_but_keeps_technical_cli(self, mock_load_config, mock_space_control) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_space_control.return_value.previous_space.return_value = SpaceControlResult(
                action="previous",
                success=True,
                key_code=123,
            )

            response = respond("/space previous")

            self.assertEqual(response["text"].splitlines()[0], "Space control:")
            self.assertEqual(response["actions"][0]["text"], "Returning to the previous desktop.")

    @patch("tuli_brain.brain.load_config")
    def test_windows_uses_short_bubble_but_keeps_technical_cli(self, mock_load_config) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            permissions = PermissionCheckResult(
                source="macos_permissions",
                accessibility="granted",
                screen_recording="granted",
                automation_system_events="available",
            )
            probe = WindowProbeResult(
                ok=True,
                source="quartz",
                permissions=permissions,
                windows=(
                    WindowRecord(
                        app_name="Finder",
                        window_title="Docs",
                        bounds=WindowBounds(x=10, y=20, width=800, height=600),
                        is_frontmost=True,
                        source="quartz",
                    ),
                ),
            )
            with patch("tuli_brain.brain.probe_visible_windows", return_value=probe):
                response = respond("/windows")

            self.assertIn("Finder", response["text"])
            self.assertEqual(response["actions"][0]["text"], "Checking visible windows.")

    @patch("tuli_brain.brain.load_config")
    def test_permissions_uses_short_bubble_but_keeps_technical_cli(self, mock_load_config) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            permissions = PermissionCheckResult(
                source="macos_permissions",
                accessibility="granted",
                screen_recording="missing",
                automation_system_events="available",
            )
            with patch("tuli_brain.brain.check_macos_permissions", return_value=permissions):
                response = respond("/permissions")

            self.assertIn("macOS permissions:", response["text"])
            self.assertEqual(response["actions"][0]["text"], "Checking macOS permissions.")


class ActivityWatcherSmokeTest(unittest.TestCase):
    def test_writes_and_summarizes_activity(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "activity.jsonl"
            watcher = ActivityWatcher(path)
            watcher.record_note("mirando el escritorio", metadata={"kind": "note"})
            watcher.record_app_focus("Safari", window_title="Docs")

            self.assertEqual(watcher.count(), 2)
            summary = watcher.summarize_recent(lines=10)

            self.assertTrue(summary.text)
            self.assertEqual(summary.session_id, "local_session")
            self.assertIn("app_focus", summary.recent_kinds)


class MacOSControlSmokeTest(unittest.TestCase):
    @patch("tuli_brain.macos_control.macos_control.subprocess.run")
    def test_observe_frontmost_state(self, mock_run) -> None:
        mock_run.return_value = SimpleNamespace(stdout="Safari||com.apple.Safari||Docs", stderr="", returncode=0)
        controller = MacOSControl(timeout_seconds=1)
        result = controller.snapshot()

        self.assertTrue(result.ok)
        self.assertIsNotNone(result.observation)
        self.assertEqual(result.observation.app_name, "Safari")
        self.assertEqual(result.observation.bundle_id, "com.apple.Safari")
        self.assertEqual(result.observation.window_title, "Docs")

    @patch("tuli_brain.macos_control.macos_control.subprocess.run")
    def test_open_application_uses_open_command(self, mock_run) -> None:
        mock_run.side_effect = [
            SimpleNamespace(stdout="", stderr="", returncode=0),
            SimpleNamespace(stdout='{"x":0,"y":23,"width":1440,"height":900}', stderr="", returncode=0),
            SimpleNamespace(stdout="adjusted", stderr="", returncode=0),
            SimpleNamespace(stdout="Safari||com.apple.Safari||Docs", stderr="", returncode=0),
        ]
        controller = MacOSControl(timeout_seconds=1)
        result = controller.open_application("Safari")

        self.assertTrue(result.ok)
        self.assertEqual(result.operation, "open_application")
        self.assertEqual(mock_run.call_args_list[0].args[0], ["/usr/bin/open", "-a", "Safari"])
        self.assertEqual(mock_run.call_args_list[1].args[0][0], "/usr/bin/swift")


class SpaceControlSmokeTest(unittest.TestCase):
    @patch("tuli_brain.macos_control.space_control.subprocess.run")
    def test_space_next_uses_control_right_shortcut(self, mock_run) -> None:
        from tuli_brain.macos_control.space_control import SpaceControl

        mock_run.return_value = SimpleNamespace(stdout="", stderr="", returncode=0)
        result = SpaceControl(timeout_seconds=1).next_space()

        self.assertTrue(result.success)
        self.assertEqual(result.action, "next")
        self.assertEqual(result.method, "system_events_keyboard_shortcut")
        self.assertIn("key code 124 using control down", mock_run.call_args.args[0][2])

    @patch("tuli_brain.macos_control.space_control.subprocess.run")
    def test_space_desktop_2_includes_shortcut_note(self, mock_run) -> None:
        from tuli_brain.macos_control.space_control import DIRECT_DESKTOP_NOTE, SpaceControl, format_space_control_result

        mock_run.return_value = SimpleNamespace(stdout="", stderr="", returncode=0)
        result = SpaceControl(timeout_seconds=1).switch_to_desktop(2)
        text = format_space_control_result(result)

        self.assertTrue(result.success)
        self.assertEqual(result.action, "desktop 2")
        self.assertEqual(result.key_code, 19)
        self.assertIn(DIRECT_DESKTOP_NOTE, text)

    @patch("tuli_brain.macos_control.space_control.subprocess.run")
    def test_space_shortcut_failure_is_safe(self, mock_run) -> None:
        from subprocess import CalledProcessError
        from tuli_brain.macos_control.space_control import SpaceControl, format_space_control_result

        mock_run.side_effect = CalledProcessError(1, ["/usr/bin/osascript"], stderr="not authorized")
        result = SpaceControl(timeout_seconds=1).previous_space()
        text = format_space_control_result(result)

        self.assertFalse(result.success)
        self.assertIn("Automation or Accessibility permission", text)

    @patch("tuli_brain.macos_control.space_control.subprocess.run")
    def test_space_status_parses_defaults_output(self, mock_run) -> None:
        from tuli_brain.macos_control.space_control import SpaceControl

        mock_run.return_value = SimpleNamespace(
            stdout='''
{
    "SpacesDisplayConfiguration" =     {
        "Management Data" =         {
            Monitors =             (
                                {
                    "Display Identifier" = Main;
                    Spaces =                     (
                                                {
                            ManagedSpaceID = 620;
                        },
                                                {
                            ManagedSpaceID = 621;
                        }
                    );
                    "Current Space" =                     {
                        ManagedSpaceID = 620;
                    };
                }
            );
        };
    };
}
''',
            stderr="",
            returncode=0,
        )

        status = SpaceControl(timeout_seconds=1).status()

        self.assertTrue(status.success)
        self.assertEqual(status.monitors, 1)
        self.assertEqual(status.current_space_managed_id, 620)
        self.assertEqual(status.available_spaces_detected, 2)


class NativeWindowTilingSmokeTest(unittest.TestCase):
    def test_native_tiling_module_does_not_use_manual_bounds(self) -> None:
        source = (ROOT / "tuli_brain" / "macos_control" / "native_window_tiling.py").read_text(encoding="utf-8")

        self.assertNotIn("set position of", source)
        self.assertNotIn("set size of", source)
        self.assertNotIn("visibleFrame", source)

    @patch("tuli_brain.macos_control.native_window_tiling.subprocess.run")
    def test_native_tiling_clicks_window_menu_submenu_item(self, mock_run) -> None:
        mock_run.return_value = SimpleNamespace(stdout="Finder||Window > Move & Resize > Top Left", stderr="", returncode=0)
        controller = NativeWindowTiling(timeout_seconds=1)

        result = controller.apply("top-left")

        self.assertTrue(result.success)
        self.assertEqual(result.method, "system_events_window_menu")
        self.assertEqual(result.frontmost_app, "Finder")
        self.assertEqual(result.menu_path, "Window > Move & Resize > Top Left")
        script = mock_run.call_args.args[0][2]
        self.assertIn('menu item "Move & Resize"', script)
        self.assertIn('menu item "Top Left"', script)

    @patch("tuli_brain.macos_control.native_window_tiling.subprocess.run")
    def test_native_tiling_clicks_direct_window_menu_item(self, mock_run) -> None:
        mock_run.return_value = SimpleNamespace(stdout="Finder||Window > Fill", stderr="", returncode=0)
        controller = NativeWindowTiling(timeout_seconds=1)

        result = controller.apply("fill")

        self.assertTrue(result.success)
        self.assertEqual(result.method, "system_events_window_menu")
        self.assertEqual(result.menu_path, "Window > Fill")
        script = mock_run.call_args.args[0][2]
        self.assertIn('menu item "Fill"', script)

    def test_native_tiling_unknown_action_fails_safely(self) -> None:
        result = NativeWindowTiling(timeout_seconds=1).apply("fullscreen")

        self.assertFalse(result.success)
        self.assertEqual(result.method, "unsupported")
        self.assertIn("Unsupported native tiling action", result.reason or "")


class WindowProbeSmokeTest(unittest.TestCase):
    @patch("tuli_brain.macos_control.mac_window_probe._quartz_windows")
    @patch("tuli_brain.macos_control.mac_window_probe.check_macos_permissions")
    def test_probe_visible_windows_uses_quartz(self, mock_permissions, mock_quartz) -> None:
        from tuli_brain.macos_control.mac_window_probe import probe_visible_windows

        permissions = PermissionCheckResult(
            source="macos_permissions",
            accessibility="granted",
            screen_recording="granted",
            automation_system_events="available",
        )
        mock_permissions.return_value = permissions
        mock_quartz.return_value = (
            [
                WindowRecord(
                    app_name="Google Chrome",
                    window_title="YouTube",
                    bounds=WindowBounds(x=10, y=20, width=800, height=600),
                    is_frontmost=True,
                    source="quartz",
                    window_id=42,
                    bundle_id="com.google.Chrome",
                )
            ],
            permissions,
        )

        result = probe_visible_windows()

        self.assertTrue(result.ok)
        self.assertEqual(result.source, "quartz")
        self.assertEqual(result.windows[0].app_name, "Google Chrome")
        self.assertEqual(result.windows[0].bounds.width, 800)

    @patch("tuli_brain.macos_control.mac_window_probe._system_events_windows")
    @patch("tuli_brain.macos_control.mac_window_probe._quartz_windows")
    @patch("tuli_brain.macos_control.mac_window_probe.check_macos_permissions")
    def test_probe_visible_windows_falls_back_to_system_events(self, mock_permissions, mock_quartz, mock_system) -> None:
        from tuli_brain.macos_control.mac_window_probe import probe_visible_windows

        permissions = PermissionCheckResult(
            source="macos_permissions",
            accessibility="granted",
            screen_recording="missing",
            automation_system_events="available",
        )
        mock_permissions.return_value = permissions
        mock_quartz.return_value = ([], permissions)
        mock_system.return_value = (
            [
                WindowRecord(
                    app_name="Google Chrome",
                    window_title="YouTube",
                    bounds=WindowBounds(x=10, y=20, width=800, height=600),
                    is_frontmost=True,
                    source="system_events",
                )
            ],
            permissions,
        )

        result = probe_visible_windows()

        self.assertTrue(result.ok)
        self.assertEqual(result.source, "system_events")
        self.assertEqual(result.windows[0].window_title, "YouTube")
        self.assertEqual(result.windows[0].source, "system_events")


class LayoutManagerSmokeTest(unittest.TestCase):
    @patch("tuli_brain.layout.manager.probe_visible_windows")
    def test_status_creates_normal_state(self, mock_probe) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            store = LayoutStateStore(Path(tmpdir) / "layout.json")
            manager = LayoutManager(state_store=store)

            state = manager.status()

            self.assertEqual(state.mode, "normal")
            self.assertFalse(state.slots["left"].occupied)
            self.assertTrue(store.path.exists())
            self.assertEqual(mock_probe.call_count, 0)

    @patch("tuli_brain.layout.manager.probe_visible_windows")
    def test_split_assigns_first_visible_window_to_left(self, mock_probe) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            store = LayoutStateStore(Path(tmpdir) / "layout.json")
            manager = LayoutManager(state_store=store)
            permissions = PermissionCheckResult(
                source="macos_permissions",
                accessibility="granted",
                screen_recording="granted",
                automation_system_events="available",
            )
            mock_probe.return_value = WindowProbeResult(
                ok=True,
                source="system_events",
                permissions=permissions,
                windows=(
                    WindowRecord(
                        app_name="Finder",
                        window_title="TULI_STUDY_REPORTS",
                        bounds=WindowBounds(x=10, y=20, width=800, height=600),
                        is_frontmost=False,
                        source="system_events",
                    ),
                    WindowRecord(
                        app_name="Google Chrome",
                        window_title="YouTube",
                        bounds=WindowBounds(x=20, y=30, width=900, height=700),
                        is_frontmost=False,
                        source="system_events",
                    ),
                ),
            )

            plan = manager.split()
            saved = manager.get_state()

            self.assertEqual(plan.mode, "split")
            self.assertTrue(plan.dry_run)
            self.assertEqual(plan.visible_windows_count, 2)
            self.assertEqual(plan.assignments[1].slot_id, "left")
            self.assertTrue(plan.assignments[1].occupied)
            self.assertEqual(plan.assignments[1].app_name, "Finder")
            self.assertFalse(plan.assignments[2].occupied)
            self.assertEqual(saved.mode, "split")
            self.assertTrue(saved.slots["left"].occupied)
            self.assertFalse(saved.slots["right"].occupied)

    @patch("tuli_brain.layout.manager.probe_visible_windows")
    def test_split_with_no_visible_windows_stays_empty(self, mock_probe) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            store = LayoutStateStore(Path(tmpdir) / "layout.json")
            manager = LayoutManager(state_store=store)
            mock_probe.return_value = WindowProbeResult(
                ok=False,
                source="fallback",
                permissions=PermissionCheckResult(
                    source="macos_permissions",
                    accessibility="granted",
                    screen_recording="granted",
                    automation_system_events="available",
                ),
                windows=(),
                error={"message": "no windows"},
            )

            plan = manager.split()

            self.assertEqual(plan.visible_windows_count, 0)
            self.assertFalse(plan.assignments[1].occupied)
            self.assertFalse(plan.assignments[2].occupied)
            self.assertEqual(plan.mode, "split")

    @patch("tuli_brain.layout.manager.probe_visible_windows")
    def test_clear_returns_to_normal(self, mock_probe) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            store = LayoutStateStore(Path(tmpdir) / "layout.json")
            manager = LayoutManager(state_store=store)
            mock_probe.return_value = WindowProbeResult(
                ok=True,
                source="system_events",
                permissions=PermissionCheckResult(
                    source="macos_permissions",
                    accessibility="granted",
                    screen_recording="granted",
                    automation_system_events="available",
                ),
                windows=(
                    WindowRecord(
                        app_name="Finder",
                        window_title="Docs",
                        bounds=WindowBounds(x=10, y=20, width=800, height=600),
                        is_frontmost=True,
                        source="system_events",
                    ),
                ),
            )
            manager.split()

            cleared = manager.clear()

            self.assertEqual(cleared.mode, "normal")
            self.assertFalse(cleared.slots["left"].occupied)
            self.assertFalse(cleared.slots["right"].occupied)

    @patch("tuli_brain.layout.manager.probe_visible_windows")
    def test_preview_warns_on_system_events_source(self, mock_probe) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            store = LayoutStateStore(Path(tmpdir) / "layout.json")
            manager = LayoutManager(state_store=store)
            permissions = PermissionCheckResult(
                source="macos_permissions",
                accessibility="granted",
                screen_recording="granted",
                automation_system_events="available",
            )
            mock_probe.return_value = WindowProbeResult(
                ok=True,
                source="system_events",
                permissions=permissions,
                windows=(
                    WindowRecord(
                        app_name="Finder",
                        window_title="Docs",
                        bounds=WindowBounds(x=10, y=20, width=800, height=600),
                        is_frontmost=True,
                        source="system_events",
                    ),
                ),
            )

            preview = manager.preview()

            self.assertTrue(preview.dry_run)
            self.assertIn("Inventory source is system_events", preview.warnings[0])


class LayoutBrainSmokeTest(unittest.TestCase):
    @patch("tuli_brain.brain.LayoutManager")
    @patch("tuli_brain.brain.load_config")
    def test_layout_status_uses_layout_manager(self, mock_load_config, mock_layout_manager) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            manager = mock_layout_manager.return_value
            manager.status.return_value = SimpleNamespace(to_dict=lambda: {"mode": "normal"})
            manager.format_status.return_value = "Layout mode: normal\nSlots:\n- main: free"

            response = respond("/layout status")

            self.assertEqual(response["command"]["type"], "layout")
            self.assertEqual(response["command"]["params"]["subcommand"], "status")
            self.assertIn("Layout mode: normal", response["text"])
            manager.status.assert_called_once()

    @patch("tuli_brain.brain.LayoutManager")
    @patch("tuli_brain.brain.load_config")
    def test_layout_split_uses_layout_manager(self, mock_load_config, mock_layout_manager) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            manager = mock_layout_manager.return_value
            manager.split.return_value = SimpleNamespace(to_dict=lambda: {"mode": "split", "dry_run": True})
            manager.format_plan.return_value = "Layout mode: split\nDry-run: true"

            response = respond("/layout split")

            self.assertEqual(response["command"]["type"], "layout")
            self.assertEqual(response["command"]["params"]["subcommand"], "split")
            self.assertIn("Dry-run: true", response["text"])
            manager.split.assert_called_once()


class NativeWindowBrainSmokeTest(unittest.TestCase):
    @patch("tuli_brain.brain.NativeWindowTiling")
    @patch("tuli_brain.brain.load_config")
    def test_window_native_left_uses_native_tiling(self, mock_load_config, mock_native_tiling) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            controller = mock_native_tiling.return_value
            controller.apply.return_value = NativeTilingResult(
                action="left",
                method="system_events_window_menu",
                success=True,
                menu_path="Window > Move & Resize > Left",
                frontmost_app="Finder",
            )

            response = respond("/window native left")

            self.assertEqual(response["command"]["type"], "native_tiling_result")
            self.assertIn("Native window tiling", response["text"])
            self.assertEqual(response["command"]["params"]["action"], "left")
            self.assertEqual(response["command"]["params"]["result"]["method"], "system_events_window_menu")
            self.assertEqual(response["command"]["params"]["result"]["menu_path"], "Window > Move & Resize > Left")
            controller.apply.assert_called_once_with("left")

    @patch("tuli_brain.brain.NativeWindowTiling")
    @patch("tuli_brain.brain.MacOSControl")
    @patch("tuli_brain.brain.load_config")
    def test_layout_native_alias_does_not_use_manual_macos_control(self, mock_load_config, mock_macos_control, mock_native_tiling) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            controller = mock_native_tiling.return_value
            controller.apply.return_value = NativeTilingResult(
                action="right",
                method="system_events_window_menu",
                success=True,
                menu_path="Window > Move & Resize > Right",
                frontmost_app="Finder",
            )

            response = respond("/layout native right")

            self.assertEqual(response["command"]["type"], "native_tiling_result")
            self.assertEqual(response["command"]["params"]["command"], "layout")
            controller.apply.assert_called_once_with("right")
            mock_macos_control.return_value._fit_frontmost_window_to_visible_frame.assert_not_called()

    @patch("tuli_brain.brain.NativeWindowTiling")
    @patch("tuli_brain.brain.load_config")
    def test_window_native_failure_responds_safely(self, mock_load_config, mock_native_tiling) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            controller = mock_native_tiling.return_value
            controller.apply.return_value = NativeTilingResult(
                action="fill",
                method="system_events_window_menu",
                success=False,
                menu_path="Window > Fill",
                reason="menu item not found or System Events denied access",
            )

            response = respond("/window native fill")

            self.assertEqual(response["command"]["type"], "native_tiling_failed")
            self.assertIn("Native window tiling failed", response["text"])
            self.assertIn("menu item not found or System Events denied access", response["text"])
            self.assertEqual(response["emotion"], "worried")


class SpaceBrainSmokeTest(unittest.TestCase):
    @patch("tuli_brain.brain.SpaceControl")
    @patch("tuli_brain.brain.load_config")
    def test_space_2_includes_direct_shortcut_note(self, mock_load_config, mock_space_control) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            controller = mock_space_control.return_value
            controller.switch_to_desktop.return_value = SpaceControlResult(
                action="desktop 2",
                success=True,
                key_code=19,
                note="direct desktop shortcuts require Mission Control shortcuts enabled.",
            )

            response = respond("/space 2")

            self.assertEqual(response["command"]["type"], "space_control_result")
            self.assertIn("direct desktop shortcuts require Mission Control shortcuts enabled", response["text"])
            controller.switch_to_desktop.assert_called_once_with(2)

    @patch("tuli_brain.brain.SpaceControl")
    @patch("tuli_brain.brain.load_config")
    def test_space_failure_responds_safely(self, mock_load_config, mock_space_control) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            controller = mock_space_control.return_value
            controller.next_space.return_value = SpaceControlResult(
                action="next",
                success=False,
                key_code=124,
                reason="System Events could not send the Spaces keyboard shortcut.",
            )

            response = respond("/space next")

            self.assertEqual(response["command"]["type"], "space_control_failed")
            self.assertIn("Space control failed", response["text"])
            self.assertEqual(response["emotion"], "worried")


class RouteSmokeTest(unittest.TestCase):
    def test_route_user_text_detects_help(self) -> None:
        result = route_user_text("/help")
        self.assertTrue(result.is_command)
        self.assertEqual(result.command_name, "help")
        self.assertEqual(result.permission.status, "allow")
        self.assertEqual(result.mode.resolved_mode, "instant")


class ModePrefixBrainSmokeTest(unittest.TestCase):
    @patch("tuli_brain.brain.ollama_chat")
    @patch("tuli_brain.brain.load_config")
    def test_instant_prefix_processes_followup_text(self, mock_load_config, mock_ollama_chat) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_ollama_chat.return_value = SimpleNamespace(text="Hola! ¿Cómo te puedo ayudar hoy?")

            response = respond("/instant hola Tuli")

            self.assertIn("Hola!", response["text"])
            self.assertEqual(response["meta"]["mode"], "instant")
            self.assertEqual(response["command"]["type"], "chat_reply")
            self.assertEqual(response["command"]["params"]["mode_prefix"], "instant")
            mock_ollama_chat.assert_called_once()
            self.assertEqual(mock_ollama_chat.call_args.args[0], "hola Tuli")

    @patch("tuli_brain.brain.ollama_chat")
    @patch("tuli_brain.brain.load_config")
    def test_thinking_prefix_processes_followup_text(self, mock_load_config, mock_ollama_chat) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_ollama_chat.return_value = SimpleNamespace(text="Tu memoria local está lista y tu actividad también.")

            response = respond("/thinking revisa el estado de tu memoria y actividad")

            self.assertIn("memoria local", response["text"])
            self.assertEqual(response["meta"]["mode"], "thinking")
            self.assertEqual(response["command"]["type"], "chat_reply")
            self.assertEqual(response["command"]["params"]["mode_prefix"], "thinking")
            mock_ollama_chat.assert_called_once()
            self.assertEqual(mock_ollama_chat.call_args.args[0], "revisa el estado de tu memoria y actividad")

    @patch("tuli_brain.brain.synthesize_speech")
    @patch("tuli_brain.brain.ollama_chat")
    @patch("tuli_brain.brain.load_config")
    def test_speak_turn_emits_voice_actions(self, mock_load_config, mock_ollama_chat, mock_synthesize_speech) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_ollama_chat.return_value = SimpleNamespace(text="Listo, ya te hablo con voz local.")
            mock_synthesize_speech.return_value = SimpleNamespace(
                text="Listo, ya te hablo con voz local.",
                voice="af_bella",
                audio_path=str(Path(tmpdir) / "speech" / "turn.mp3"),
                response_format="mp3",
                bytes_written=1024,
            )

            response = respond("hola Tuli", speak=True)

            action_types = [action["type"] for action in response["actions"]]
            self.assertIn("speech_start", action_types)
            self.assertIn("speech_end", action_types)
            self.assertTrue(response["speak"])
            mock_synthesize_speech.assert_called_once()
            self.assertEqual(mock_synthesize_speech.call_args.args[0], "Listo, ya te hablo con voz local.")

    @patch("tuli_brain.__main__.subprocess.run")
    def test_voice_response_helper_plays_audio_path(self, mock_run) -> None:
        response = {
            "actions": [
                {"type": "bubble_show", "text": "hola"},
                {"type": "speech_start", "text": "hola", "voice": "af_bella", "audio_path": "/tmp/tuli.mp3"},
                {"type": "speech_end", "voice": "af_bella", "audio_path": "/tmp/tuli.mp3"},
            ]
        }

        played = _play_voice_from_response(response)

        self.assertTrue(played)
        mock_run.assert_called_once_with(["/usr/bin/afplay", "/tmp/tuli.mp3"], check=True)

    def test_event_bridge_writes_avatar_compatible_jsonl(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            stream_path = Path(tmpdir) / "openclaw_stream.jsonl"
            response = {
                "text": "Hola!",
                "emotion": "happy",
                "speak": True,
                "voice": "af_bella",
                "actions": [
                    {"type": "bubble_show", "text": "Hola!"},
                    {"type": "emotion_hint", "emotion": "happy"},
                    {"type": "speech_start", "text": "Hola!", "voice": "af_bella"},
                    {"type": "speech_end", "voice": "af_bella"},
                ],
                "command": {"type": "chat_reply", "confidence": 1.0, "params": {}},
                "meta": {"session_id": "local_session", "turn_id": "turn_test", "model_used": "qwen3:1.7b", "provider": "ollama_local"},
                "error": None,
            }

            result = emit_response_events_with_turn(response, stream_path, turn_id="turn_test")
            lines = stream_path.read_text(encoding="utf-8").strip().splitlines()
            payloads = [json.loads(line) for line in lines]

            self.assertEqual(result.emitted_count, 4)
            self.assertTrue(all(payload["id"] == payloads[0]["id"] for payload in payloads))
            self.assertEqual([payload["type"] for payload in payloads], ["bubble_show", "emotion_hint", "speech_start", "speech_end"])
            self.assertEqual(payloads[0]["text"], "Hola!")
            self.assertEqual(payloads[1]["emotion"], "happy")
            self.assertEqual(payloads[2]["text"], "Hola!")

    @patch("tuli_brain.brain.MacOSControl")
    @patch("tuli_brain.brain.ActivityWatcher")
    @patch("tuli_brain.brain.load_config")
    def test_open_phrase_uses_macos_control(self, mock_load_config, mock_activity_watcher, mock_macos_control) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_activity = mock_activity_watcher.return_value
            mock_activity.last_opened_app.return_value = None
            controller = mock_macos_control.return_value
            controller.open_application.return_value = SimpleNamespace(
                ok=True,
                operation="open_application",
                observation=SimpleNamespace(app_name="Safari", to_dict=lambda: {"app_name": "Safari"}),
                status="ok",
                error=None,
            )

            response = respond("abre Safari")

            self.assertIn("Opening", response["text"])
            self.assertEqual(response["command"]["type"], "open")
            self.assertEqual(response["command"]["params"]["app_name"], "Safari")
            controller.open_application.assert_called_once_with("Safari")

    @patch("tuli_brain.brain.MacOSControl")
    @patch("tuli_brain.brain.ActivityWatcher")
    @patch("tuli_brain.brain.load_config")
    def test_open_pronoun_uses_last_opened_app(self, mock_load_config, mock_activity_watcher, mock_macos_control) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_load_config.return_value = make_test_config(tmpdir)
            mock_activity = mock_activity_watcher.return_value
            mock_activity.last_opened_app.return_value = "Safari"
            controller = mock_macos_control.return_value
            controller.open_application.return_value = SimpleNamespace(
                ok=True,
                operation="open_application",
                observation=SimpleNamespace(app_name="Safari", to_dict=lambda: {"app_name": "Safari"}),
                status="ok",
                error=None,
            )

            response = respond("ábrela")

            self.assertIn("Opening", response["text"])
            self.assertEqual(response["command"]["type"], "open")
            self.assertEqual(response["command"]["params"]["app_name"], "Safari")
            self.assertTrue(response["command"]["params"]["resolved_from_reference"])
            controller.open_application.assert_called_once_with("Safari")

    def test_apps_command_lists_known_apps(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            config = make_test_config(tmpdir)
            with patch("tuli_brain.brain.load_config", return_value=config):
                response = respond("/apps")

        self.assertEqual(response["command"]["type"], "apps")
        self.assertIn("Known apps", response["text"])
        self.assertTrue(response["command"]["params"]["open_any_installed_app"])

    def test_permissions_command_reports_statuses(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            config = make_test_config(tmpdir)
            permissions = PermissionCheckResult(
                source="macos_permissions",
                accessibility="missing",
                screen_recording="granted",
                automation_system_events="available",
            )
            with patch("tuli_brain.brain.load_config", return_value=config), patch("tuli_brain.brain.check_macos_permissions", return_value=permissions):
                response = respond("/permissions")

        self.assertEqual(response["command"]["type"], "permissions")
        self.assertIn("Accessibility: missing", response["text"])
        self.assertEqual(response["command"]["params"]["accessibility"], "missing")

    def test_windows_command_reports_visible_windows(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            config = make_test_config(tmpdir)
            permissions = PermissionCheckResult(
                source="macos_permissions",
                accessibility="granted",
                screen_recording="granted",
                automation_system_events="available",
            )
            probe = WindowProbeResult(
                ok=True,
                source="quartz",
                permissions=permissions,
                windows=(
                    WindowRecord(
                        app_name="Google Chrome",
                        window_title="YouTube",
                        bounds=WindowBounds(x=10, y=20, width=800, height=600),
                        is_frontmost=True,
                        source="quartz",
                    ),
                ),
            )
            with patch("tuli_brain.brain.load_config", return_value=config), patch("tuli_brain.brain.probe_visible_windows", return_value=probe):
                response = respond("/windows")

        self.assertEqual(response["command"]["type"], "windows")
        self.assertIn("Google Chrome", response["text"])
        self.assertEqual(response["command"]["params"]["source"], "quartz")
        self.assertEqual(response["command"]["params"]["windows"][0]["window_title"], "YouTube")


if __name__ == "__main__":
    unittest.main()
