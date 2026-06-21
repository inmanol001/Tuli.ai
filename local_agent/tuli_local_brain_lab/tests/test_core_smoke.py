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
from tuli_brain.__main__ import _play_voice_from_response
from tuli_brain.macos_control import MacOSControl


def make_test_config(tmpdir: str) -> SimpleNamespace:
    base = Path(tmpdir)
    return SimpleNamespace(
        ollama_url="http://127.0.0.1:11434/api/chat",
        ollama_model="qwen3:1.7b",
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
            SimpleNamespace(stdout="Safari||com.apple.Safari||Docs", stderr="", returncode=0),
        ]
        controller = MacOSControl(timeout_seconds=1)
        result = controller.open_application("Safari")

        self.assertTrue(result.ok)
        self.assertEqual(result.operation, "open_application")
        self.assertEqual(mock_run.call_args_list[0].args[0], ["/usr/bin/open", "-a", "Safari"])


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


if __name__ == "__main__":
    unittest.main()
