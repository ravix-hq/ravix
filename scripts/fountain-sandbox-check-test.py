#!/usr/bin/env python3
"""Offline behavioral tests: no sockets, no real provider or credentials."""
import contextlib
import importlib.util
import io
import os
import sys
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("sandbox_check", Path(__file__).with_name("fountain-sandbox-check.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class Provider:
    def __init__(self):
        self.rows = {name: {} for name in ("agents", "vaults", "environments", "sandboxes", "conversations")}
        self.disk = {}
        self.calls = []
        self.seq = 0
        self.fail = None
        self.hide_identity = False

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        parts = path.split("?")[0].strip("/").split("/")[1:]
        collection = parts[0]
        row_id = parts[1] if len(parts) > 1 else None
        rows = self.rows[collection]
        if method == "POST" and row_id is None:
            self.seq += 1
            row = {**body, "id": str(self.seq)}
            if collection == "conversations":
                sandbox = body.get("sandbox_id")
                if not sandbox:
                    sandbox = "box-" + row["id"]
                    self.rows["sandboxes"][sandbox] = {
                        "id": sandbox, **{key: body[key] for key in ("agent_id", "vault_id", "environment_id")}}
                    self.disk[sandbox] = ""
                # Like Fountain: a new conversation reads idle before its turn exists.
                row.update(sandbox_id=sandbox, status="idle",
                           turns=[{"status": "completed"}] if body.get("prompt") else [])
                prompt = body.get("prompt", "")
                for marker in ("FIRST", "SECOND", "GUEST", "THREAD"):
                    if marker in prompt:
                        self.disk[sandbox] += marker + "\n"
            rows[row["id"]] = row
            if self.fail == collection:
                self.fail = None
                raise check.ApiFailure(0)  # provider committed but the response was lost
            return {"data": row}
        if method == "GET" and row_id is None:
            listed = list(rows.values())
            if self.hide_identity and collection == "sandboxes":
                listed = [{"id": row["id"]} for row in listed]
            return {"data": listed}
        if method == "GET":
            if row_id not in rows:
                raise check.ApiFailure(404, collection == "sandboxes")
            if parts[-1] == "file":
                return {"data": {"encoding": "utf-8", "content": self.disk[row_id]}}
            if parts[-1] == "turns":
                return {"data": rows[row_id].get("turns", [])}
            return {"data": rows[row_id]}
        if method == "POST" and parts[-1] == "terminate":
            rows[row_id]["status"] = "terminated"
            return None
        if method == "DELETE":
            if row_id not in rows:
                raise check.ApiFailure(404, collection == "sandboxes")
            if collection == "sandboxes":
                # Like Fountain: the row stays, terminated; a repeat is not resettable.
                if rows[row_id].get("status") == "terminated":
                    raise check.ApiFailure(422, False, "sandbox_not_resettable")
                rows[row_id]["status"] = "terminated"
                if self.fail == "delete":
                    self.fail = None
                    raise check.ApiFailure(0)
                return None
            del rows[row_id]
            if collection == "agents":
                for box_id, box in list(self.rows["sandboxes"].items()):
                    if box["agent_id"] == row_id:
                        box["status"] = "terminated"
            if self.fail == "delete":
                self.fail = None
                raise check.ApiFailure(0)
            return None
        raise AssertionError("unimplemented offline fixture request")


class SandboxCheckTest(unittest.TestCase):
    def args(self):
        return check.arguments(["--wait-seconds", "0.01", "--credential-set-id", "owner-set",
                                "--claude-model", "claude-model", "--codex-model", "codex-model"])

    def assert_clean(self, provider):
        for name in ("agents", "vaults", "environments"):
            self.assertEqual(provider.rows[name], {}, name)
        for box in provider.rows["sandboxes"].values():
            self.assertEqual(box.get("status"), "terminated", box["id"])

    def test_dry_run_never_builds_a_client(self):
        with patch.object(check, "Api", side_effect=AssertionError("must not connect")), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(check.main(["--dry-run"]), 0)
        self.assertIn("no requests sent", out.getvalue())

    def test_all_six_checks_and_cleanup_without_reallocating_a_lost_create(self):
        provider = Provider()
        runner = check.Check(provider, self.args())
        runner.run()
        self.assertEqual(len(runner.results), 6)
        self.assertTrue(all(result == "PASS" for _, result in runner.results))
        creates = [body for method, path, body in provider.calls if method == "POST" and path == "/api/conversations"]
        self.assertEqual(len(creates), 5)
        self.assertEqual(len([b for b in creates if b["channel_id"].endswith("-lost-create")]), 1)
        self.assertEqual(runner.cleanup(), [])
        self.assert_clean(provider)
        self.assertFalse(any("credential" in path for _, path, _ in provider.calls))

    def test_lost_resource_acknowledgement_reconciles_name_and_cleans_up(self):
        provider = Provider()
        provider.fail = "vaults"
        runner = check.Check(provider, self.args())
        with self.assertRaises(check.ApiFailure):
            runner.run()
        self.assertEqual(runner.cleanup(), [])
        self.assert_clean(provider)

    def test_unknown_launch_is_discovered_and_cleaned_without_retry(self):
        provider = Provider()
        provider.fail = "conversations"
        runner = check.Check(provider, self.args())
        with self.assertRaises(check.ApiFailure):
            runner.run()
        self.assertEqual(runner.cleanup(), [])
        self.assert_clean(provider)
        self.assertEqual(sum(method == "POST" and path == "/api/conversations" for method, path, _ in provider.calls), 1)

    def test_unknown_delete_is_confirmed_by_read(self):
        provider = Provider()
        provider.fail = "delete"
        runner = check.Check(provider, self.args())
        runner.run()
        self.assertEqual(runner.cleanup(), [])
        self.assert_clean(provider)

    def test_missing_reconciliation_fields_fail_without_second_create(self):
        provider = Provider()
        provider.hide_identity = True
        runner = check.Check(provider, self.args())
        with self.assertRaisesRegex(check.CheckFailure, "cannot be uniquely reconciled"):
            runner.run()
        runner.cleanup()
        self.assert_clean(provider)  # home agent lifecycle covers the undiscoverable allocation
        creates = [b for m, p, b in provider.calls if m == "POST" and p == "/api/conversations"]
        self.assertEqual(len(creates), 5)

    def test_cleanup_continues_after_one_delete_failure_and_reports_it(self):
        provider = Provider()
        runner = check.Check(provider, self.args())
        runner.run()
        original = provider.request
        blocked = next(r["id"] for r in runner.resources if r["collection"] == "vaults")
        def fail_one(method, path, body=None):
            if method == "DELETE" and path == "/api/vaults/" + blocked:
                raise check.ApiFailure(403)
            return original(method, path, body)
        provider.request = fail_one
        failures = runner.cleanup()
        self.assertEqual(len(failures), 1)
        self.assertIn("resource cleanup failed", failures[0])
        self.assertEqual(provider.rows["environments"], {})
        self.assertEqual(provider.rows["agents"], {})
        self.assertTrue(all(box.get("status") == "terminated" for box in provider.rows["sandboxes"].values()))

    def test_main_cleans_on_failure_and_never_prints_secret_exception_details(self):
        provider = Provider()
        provider.fail = "conversations"
        token = "TOP-SECRET-TEST-TOKEN"
        argv = ["--base-url", "https://fountain.invalid", "--credential-set-id", "set",
                "--claude-model", "model", "--codex-model", "model", "--wait-seconds", "0.01"]
        with patch.dict(os.environ, {"FOUNTAIN_CHECK_TOKEN": token}), patch.object(check, "Api", return_value=provider), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(check.main(argv), 1)
        self.assertNotIn(token, out.getvalue())
        self.assertIn("transport outcome unknown", out.getvalue())
        self.assertIn("cleanup", out.getvalue())
        self.assert_clean(provider)

    def test_http_errors_hide_echoed_tokens_and_redirects_are_refused(self):
        api = check.Api("https://fountain.invalid", "TOP-SECRET")
        error = HTTPError("https://fountain.invalid", 404, "TOP-SECRET", {},
                          io.BytesIO(b'{"error":"sandbox_not_found","message":"TOP-SECRET"}'))
        with patch.object(api.opener, "open", side_effect=error):
            with self.assertRaises(check.ApiFailure) as raised:
                api.request("DELETE", "/api/sandboxes/s1")
        self.assertTrue(raised.exception.gone)
        self.assertNotIn("TOP-SECRET", str(raised.exception))
        with patch.object(api.opener, "open", side_effect=URLError("TOP-SECRET")):
            with self.assertRaises(check.ApiFailure) as raised:
                api.request("POST", "/api/conversations", {})
        self.assertEqual(str(raised.exception), "transport outcome unknown")
        self.assertIsNone(check.NoRedirect().redirect_request(None, None, 302, None, {}, "https://elsewhere.invalid"))


if __name__ == "__main__":
    unittest.main()
