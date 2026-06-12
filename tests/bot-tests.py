#!/usr/bin/env python3
"""fieldwork-bot daemon tests.

Importable, in-process tests for the bot helpers: HMAC round-trip, pending
dir scan, sidecar writes, callback dispatch. Telegram calls are stubbed; no
network I/O.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def _load_bot_module(tmp: Path):
    """Load lib/scripts/fieldwork-bot as a Python module with test paths."""
    os.environ["FIELDWORK_BOT_PENDING_DIR"] = str(tmp / "pending")
    os.environ["FIELDWORK_BOT_NOTIFICATIONS_DIR"] = str(tmp / "notifications")
    os.environ["FIELDWORK_BOT_APPROVE_SOCKET"] = str(tmp / "approve.sock")
    os.environ["FIELDWORK_BOT_CONFIG_PATH"] = str(tmp / "config.toml")
    os.environ["FIELDWORK_BOT_SECRET_PATH"] = str(tmp / "secret")
    os.environ["FIELDWORK_BOT_LOG_PATH"] = str(tmp / "bot.log")
    os.environ["FIELDWORK_BOT_HEALTH_PATH"] = str(tmp / "bot-health.json")
    os.environ["FIELDWORK_BOT_TELEGRAM_API"] = "http://localhost.invalid"

    from importlib.machinery import SourceFileLoader
    loader = SourceFileLoader("fieldwork_bot", str(ROOT / "lib/scripts/fieldwork-bot"))
    spec = importlib.util.spec_from_loader("fieldwork_bot", loader)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class BotHmacTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp(prefix="fieldwork-bot-tests."))
        (cls.tmp / "pending").mkdir()
        (cls.tmp / "notifications").mkdir()
        cls.bot = _load_bot_module(cls.tmp)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp)

    def test_sign_callback_under_64_bytes(self) -> None:
        rid = "deadbeef-dead-4dad-bdad-deadbeefdead"
        data = self.bot.sign_callback(b"k" * 32, "approve", rid)
        self.assertLessEqual(len(data.encode("utf-8")), 64)
        self.assertTrue(data.startswith("a:"))

    def test_verify_callback_round_trip(self) -> None:
        secret = b"super-secret-key"
        rid = "12345678-1234-4234-9234-123456789012"
        signed = self.bot.sign_callback(secret, "deny", rid)
        result = self.bot.verify_callback(secret, signed)
        self.assertEqual(result, ("deny", rid))

    def test_verify_callback_rejects_bad_signature(self) -> None:
        secret = b"correct-key"
        rid = "12345678-1234-4234-9234-123456789012"
        signed = self.bot.sign_callback(secret, "approve", rid)
        # Flip last hex char of the signature
        tampered = signed[:-1] + ("0" if signed[-1] != "0" else "1")
        self.assertIsNone(self.bot.verify_callback(secret, tampered))

    def test_verify_callback_rejects_wrong_secret(self) -> None:
        rid = "12345678-1234-4234-9234-123456789012"
        signed = self.bot.sign_callback(b"alice-secret", "approve", rid)
        self.assertIsNone(self.bot.verify_callback(b"mallory-secret", signed))

    def test_verify_callback_rejects_malformed(self) -> None:
        self.assertIsNone(self.bot.verify_callback(b"k", "not:enough"))
        self.assertIsNone(self.bot.verify_callback(b"k", "x:abc:def"))


class BotPendingScanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp(prefix="fieldwork-bot-scan."))
        (cls.tmp / "pending").mkdir()
        (cls.tmp / "notifications").mkdir()
        cls.bot = _load_bot_module(cls.tmp)
        cls.cfg = {"bot_token": "tok", "allowed_chat_ids": [111, 222]}
        cls.secret = b"k" * 32

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp)

    def setUp(self) -> None:
        for p in Path(self.bot.PENDING_DIR).glob("*"):
            p.unlink()
        for p in Path(self.bot.NOTIFICATIONS_DIR).glob("*"):
            p.unlink()

    def _write_pending(self, rid: str) -> None:
        record = {
            "request_id": rid,
            "queued_at": "2026-05-15T10:00:00Z",
            "expires_at": "2026-05-16T10:00:00Z",
            "repo": "owner/example",
            "branch": "fieldwork/test",
            "title": "Test PR",
            "body": "Hi",
        }
        Path(self.bot.PENDING_DIR, f"{rid}.json").write_text(json.dumps(record))

    def test_process_pending_dir_sends_one_message_per_chat(self) -> None:
        rid = "11111111-1111-4111-8111-111111111111"
        self._write_pending(rid)

        sends: list[tuple[int, dict]] = []

        def fake_telegram_call(token, method, payload, timeout=15):
            if method == "sendMessage":
                sends.append((payload["chat_id"], payload))
                return {"ok": True, "result": {"message_id": len(sends)}}
            return {"ok": True, "result": {}}

        with patch.object(self.bot, "telegram_call", side_effect=fake_telegram_call):
            sent = self.bot.process_pending_dir(self.cfg, self.secret)
        self.assertEqual(sent, 1)
        self.assertEqual([c for c, _ in sends], [111, 222])
        self.assertTrue((Path(self.bot.PENDING_DIR) / f"{rid}.json.notified").exists())
        health = json.loads(Path(self.bot.HEALTH_PATH).read_text())
        self.assertEqual(health["pending_count"], 1)
        self.assertGreaterEqual(health["oldest_pending_age_seconds"], 0)
        self.assertEqual(health["pending_requests"][0]["request_id"], rid)

        # Second pass: sidecar present → no resend.
        sends.clear()
        with patch.object(self.bot, "telegram_call", side_effect=fake_telegram_call):
            sent = self.bot.process_pending_dir(self.cfg, self.secret)
        self.assertEqual(sent, 0)
        self.assertEqual(sends, [])

    def test_pending_message_carries_signed_callbacks(self) -> None:
        rid = "22222222-2222-4222-8222-222222222222"
        self._write_pending(rid)

        captured: list[dict] = []

        def fake_telegram_call(token, method, payload, timeout=15):
            if method == "sendMessage":
                captured.append(payload)
                return {"ok": True, "result": {"message_id": 1}}
            return {"ok": True}

        with patch.object(self.bot, "telegram_call", side_effect=fake_telegram_call):
            self.bot.process_pending_dir(self.cfg, self.secret)

        self.assertGreaterEqual(len(captured), 1)
        buttons = captured[0]["reply_markup"]["inline_keyboard"][0]
        for btn in buttons:
            verified = self.bot.verify_callback(self.secret, btn["callback_data"])
            self.assertIsNotNone(verified)
            self.assertEqual(verified[1], rid)

    def test_process_notifications_dir_forwards_and_deletes(self) -> None:
        Path(self.bot.NOTIFICATIONS_DIR, "a.json").write_text('{"text":"hello mobile"}')

        calls: list[dict] = []

        def fake_telegram_call(token, method, payload, timeout=15):
            calls.append(payload)
            return {"ok": True}

        with patch.object(self.bot, "telegram_call", side_effect=fake_telegram_call):
            self.bot.process_notifications_dir(self.cfg)

        self.assertEqual([c["text"] for c in calls], ["hello mobile", "hello mobile"])
        self.assertEqual(list(Path(self.bot.NOTIFICATIONS_DIR).glob("*")), [])


class BotCallbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp(prefix="fieldwork-bot-cb."))
        (cls.tmp / "pending").mkdir()
        (cls.tmp / "notifications").mkdir()
        cls.bot = _load_bot_module(cls.tmp)
        cls.cfg = {"bot_token": "tok", "allowed_chat_ids": [42]}
        cls.secret = b"k" * 32

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp)

    def test_handle_callback_allowlisted_approve_posts_decision(self) -> None:
        rid = "33333333-3333-4333-8333-333333333333"
        data = self.bot.sign_callback(self.secret, "approve", rid)
        update = {
            "callback_query": {
                "id": "cb1",
                "data": data,
                "from": {"username": "alice"},
                "message": {"chat": {"id": 42}, "message_id": 100},
            }
        }

        posts: list[tuple[str, str, int]] = []

        def fake_post(request_id, decision, chat_id):
            posts.append((request_id, decision, chat_id))
            return 200, {"ok": True, "url": "https://github.com/owner/repo/pull/9"}

        tg_calls: list[tuple[str, dict]] = []

        def fake_tg(token, method, payload, timeout=15):
            tg_calls.append((method, payload))
            return {"ok": True}

        with patch.object(self.bot, "post_approve_decision", side_effect=fake_post), \
             patch.object(self.bot, "telegram_call", side_effect=fake_tg):
            self.bot.handle_callback(self.cfg, self.secret, update)

        self.assertEqual(posts, [(rid, "approve", 42)])
        edits = [p for m, p in tg_calls if m == "editMessageText"]
        self.assertEqual(len(edits), 1)
        self.assertIn("Approved by @alice", edits[0]["text"])
        self.assertIn("pull/9", edits[0]["text"])

    def test_handle_callback_non_allowlisted_chat_dropped(self) -> None:
        rid = "44444444-4444-4444-8444-444444444444"
        data = self.bot.sign_callback(self.secret, "approve", rid)
        update = {
            "callback_query": {
                "id": "cb2",
                "data": data,
                "from": {"username": "mallory"},
                "message": {"chat": {"id": 9999}, "message_id": 1},
            }
        }
        with patch.object(self.bot, "post_approve_decision") as fake_post, \
             patch.object(self.bot, "telegram_call") as fake_tg:
            self.bot.handle_callback(self.cfg, self.secret, update)
        fake_post.assert_not_called()
        # Plan: no answerCallbackQuery either. Silent drop so probes get no signal.
        fake_tg.assert_not_called()

    def test_handle_callback_bad_signature_dropped(self) -> None:
        update = {
            "callback_query": {
                "id": "cb3",
                "data": "a:deadbeef-dead-4dad-bdad-deadbeefdead:0000000000000000",
                "from": {"username": "alice"},
                "message": {"chat": {"id": 42}, "message_id": 1},
            }
        }
        with patch.object(self.bot, "post_approve_decision") as fake_post, \
             patch.object(self.bot, "telegram_call") as fake_tg:
            self.bot.handle_callback(self.cfg, self.secret, update)
        fake_post.assert_not_called()
        # Allowlisted user: bot answers the callback (so the spinner stops)
        # but does not POST to the broker.
        methods = [c.args[1] for c in fake_tg.call_args_list]
        self.assertIn("answerCallbackQuery", methods)


if __name__ == "__main__":
    unittest.main()
