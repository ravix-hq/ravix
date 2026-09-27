#!/usr/bin/env python3
"""Owner-run, disposable Fountain sandbox contract check. See fountain-sandbox-check.md."""
import argparse
import json
import os
import signal
import sys
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler


class CheckFailure(Exception):
    """Only fixed, non-secret messages cross the reporting boundary."""


class ApiFailure(CheckFailure):
    def __init__(self, status, gone=False):
        super().__init__(f"HTTP {status}" if status else "transport outcome unknown")
        self.status = status
        self.gone = gone


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward the owner's bearer token to a redirect target.


class Api:
    def __init__(self, base, token, timeout=60):
        self.base, self.token, self.timeout = base.rstrip("/"), token, timeout
        self.opener = build_opener(NoRedirect())

    def request(self, method, path, body=None):
        payload = None if body is None else json.dumps(body).encode()
        request = Request(self.base + path, data=payload, method=method,
                          headers={"Authorization": "Bearer " + self.token,
                                   "Content-Type": "application/json",
                                   # Cloudflare refuses urllib's default agent (error 1010).
                                   "User-Agent": "ravix-fountain-sandbox-check/1"})
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except HTTPError as error:
            # Parse only to recognize absence. Never print response text or URLs.
            try:
                code = json.loads(error.read()).get("error")
            except (ValueError, AttributeError):
                code = None
            raise ApiFailure(error.code, error.code in (404, 410) and
                             code in ("sandbox_not_found", "sandbox_gone")) from None
        except (URLError, TimeoutError, OSError, ValueError):
            raise ApiFailure(0) from None


def data(raw):
    return raw.get("data", raw) if isinstance(raw, dict) else raw


def segment(value):
    return quote(str(value), safe="")


class Check:
    def __init__(self, api, args):
        self.api, self.args = api, args
        self.prefix = "ravix-check-" + uuid.uuid4().hex
        self.resources = []  # intent is recorded BEFORE each create (including unknown outcomes)
        self.sandboxes = set()
        self.conversations = set()
        self.results = []
        self.path = "/tmp/" + self.prefix

    def request(self, method, path, body=None):
        return data(self.api.request(method, path, body))

    def create(self, collection, suffix, **fields):
        intent = {"collection": collection, "name": self.prefix + "-" + suffix, "id": None}
        self.resources.append(intent)
        record = self.request("POST", "/api/" + collection,
                              {**fields, "name": intent["name"]})
        if not isinstance(record, dict) or not isinstance(record.get("id"), str) or not record["id"]:
            raise CheckFailure("create acknowledgement lacked an id; reconcile before retry")
        intent["id"] = record["id"]
        return record["id"]

    def wait_for(self, inspect, description):
        deadline = time.monotonic() + self.args.wait_seconds
        while time.monotonic() < deadline:
            result = inspect()
            if result:
                return result
            time.sleep(0.5)
        raise CheckFailure(description + " did not complete before deadline")

    def idle(self, conversation):
        def inspect():
            status = self.request("GET", "/api/conversations/" + segment(conversation)).get("status")
            if status in ("failed", "terminated"):
                raise CheckFailure("verification conversation ended before completing its turn")
            return status == "idle"
        self.wait_for(inspect, "turn")

    def launch(self, agent, vault, prompt=None, sandbox=None, channel=None, discard=False):
        body = {"agent_id": agent, "environment_id": self.environment, "vault_id": vault,
                "channel_id": channel or self.prefix + "-" + uuid.uuid4().hex, "fresh": True}
        if prompt is not None:
            body["prompt"] = prompt
        if sandbox:
            body["sandbox_id"] = sandbox
        else:
            body["sandbox_mode"] = "persistent"
        # No retry, even if the POST acknowledgement is lost.
        record = self.request("POST", "/api/conversations", body)
        if discard:
            return None  # deliberate lost-response simulation: do not retain either returned id
        if not isinstance(record, dict) or not all(isinstance(record.get(k), str) and record[k] for k in ("id", "sandbox_id")):
            raise CheckFailure("launch acknowledgement lacked identity")
        self.conversations.add(record["id"])
        self.sandboxes.add(record["sandbox_id"])
        if sandbox and record["sandbox_id"] != sandbox:
            raise CheckFailure("guest attached to an unexpected sandbox")
        if prompt:
            self.idle(record["id"])
        return record

    def content(self, sandbox):
        record = self.request("GET", "/api/sandboxes/" + segment(sandbox) +
                              "/file?" + urlencode({"path": self.path}))
        if record.get("encoding") != "utf8":
            raise CheckFailure("marker was not readable as UTF-8")
        return record.get("content", "")

    def remove_sandbox(self, sandbox):
        try:
            self.request("DELETE", "/api/sandboxes/" + segment(sandbox))
        except ApiFailure as error:
            if not error.gone and error.status not in (0, 408) and error.status < 500:
                raise
            # An uncertain DELETE is reconciled, never counted as complete by itself.
        def absent():
            try:
                self.request("GET", "/api/sandboxes/" + segment(sandbox))
                return False
            except ApiFailure as error:
                if error.gone:
                    return True
                raise
        self.wait_for(absent, "sandbox deletion")

    def run(self):
        self.environment = self.create("environments", "env", packages={})
        first_vault = self.create("vaults", "vault-a")
        second_vault = self.create("vaults", "vault-b")
        agents = {}
        for runtime in ("claude", "codex"):
            agents[runtime] = self.create("agents", runtime, runtime=runtime,
                                          model=getattr(self.args, runtime + "_model"),
                                          inference_credential_id=self.args.credential_set_id)
        home = agents[self.args.home_runtime]
        guest = agents["codex" if self.args.home_runtime == "claude" else "claude"]
        first = self.launch(home, first_vault, f"Write exactly FIRST to {self.path}. Do nothing else.")
        second = self.launch(home, second_vault, f"Write exactly SECOND to {self.path}. Do nothing else.")
        box, sibling = first["sandbox_id"], second["sandbox_id"]
        if box == sibling or self.content(box).strip() != "FIRST" or self.content(sibling).strip() != "SECOND":
            raise CheckFailure("per-vault disks were not distinct")
        self.results.append(("distinct vault identities / disks", "PASS"))
        attached = self.launch(guest, first_vault, sandbox=box,
                               prompt=f"Append a newline and GUEST to {self.path}. Do nothing else.")
        if "GUEST" not in self.content(box) or "GUEST" in self.content(sibling):
            raise CheckFailure("guest did not share only the home disk")
        self.results.append(("other-runtime guest attach", "PASS"))
        self.launch(home, first_vault, sandbox=box,
                    prompt=f"Append a newline and THREAD to {self.path}. Do nothing else.")
        content = self.content(box)
        if not all(marker in content for marker in ("FIRST", "GUEST", "THREAD")):
            raise CheckFailure("threads did not share disk changes")
        self.results.append(("threads share one disk", "PASS"))
        self.request("POST", "/api/conversations/" + segment(attached["id"]) + "/terminate")
        if self.content(box) != content:
            raise CheckFailure("terminating a thread changed or lost the disk")
        self.results.append(("thread termination retains disk", "PASS"))
        self.remove_sandbox(box)
        if self.content(sibling).strip() != "SECOND":
            raise CheckFailure("deleting one sandbox changed its sibling")
        self.results.append(("DELETE completion / sibling isolation", "PASS"))
        self.reconcile_lost(home)

    def reconcile_lost(self, home):
        vault = self.create("vaults", "lost-vault")
        channel = self.prefix + "-lost-create"
        try:
            self.launch(home, vault, "Reply READY. Do nothing else.", channel=channel, discard=True)
        except ApiFailure as error:
            if error.status not in (0, 408) and error.status < 500:
                raise
        boxes = self.request("GET", "/api/sandboxes")
        matches = [box for box in boxes if box.get("agent_id") == home and
                   box.get("environment_id") == self.environment and box.get("vault_id") == vault]
        self.sandboxes.update(box["id"] for box in matches)
        conversations = self.request("GET", "/api/conversations?" + urlencode({"agent_id": home}))
        threads = [c for c in conversations if c.get("channel_id") == channel]
        self.conversations.update(c["id"] for c in threads)
        if len(matches) != 1 or len(threads) != 1 or threads[0].get("sandbox_id") != matches[0]["id"]:
            raise CheckFailure("lost create cannot be uniquely reconciled; no second allocation attempted")
        self.results.append(("lost acknowledgement reconciliation (simulated)", "PASS"))

    def cleanup(self):
        failures = []
        # Resolve unknown resource creates by this run's unique name, never by broad account ownership.
        for resource in self.resources:
            if resource["id"] is None:
                try:
                    rows = self.request("GET", "/api/" + resource["collection"])
                    found = [r for r in rows if r.get("name") == resource["name"]]
                    if len(found) == 1:
                        resource["id"] = found[0]["id"]
                    else:
                        failures.append("unresolved " + resource["collection"] + " intent " + resource["name"])
                except Exception:
                    failures.append("cannot reconcile " + resource["collection"] + " intent " + resource["name"])
        # Discover allocations whose create reply was lost, using only owned home agents.
        homes = {r["id"] for r in self.resources if r["collection"] == "agents" and r["id"]}
        try:
            for box in self.request("GET", "/api/sandboxes"):
                if box.get("agent_id") in homes:
                    self.sandboxes.add(box["id"])
        except Exception:
            failures.append("sandbox discovery unavailable; owned agent deletion is the fallback")
        for conversation in self.conversations:
            try:
                self.request("POST", "/api/conversations/" + segment(conversation) + "/terminate")
            except ApiFailure as error:
                if error.status not in (404, 410):
                    failures.append("conversation cleanup failed")
            except Exception:
                failures.append("conversation cleanup failed")
        for sandbox in self.sandboxes:
            try:
                self.remove_sandbox(sandbox)
            except Exception:
                failures.append("sandbox cleanup unconfirmed: " + str(sandbox))
        # Guest first, then home; home-agent lifecycle is also a fallback for unknown allocations.
        for resource in reversed(self.resources):
            if resource["id"]:
                try:
                    self.request("DELETE", "/api/" + resource["collection"] + "/" + segment(resource["id"]))
                except ApiFailure as error:
                    if error.status not in (404, 410):
                        failures.append("resource cleanup failed: " + resource["collection"] + "/" + str(resource["id"]))
                except Exception:
                    failures.append("resource cleanup failed")
        return failures


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="print the plan without credentials or network")
    parser.add_argument("--base-url", default=os.environ.get("FOUNTAIN_CHECK_URL", ""))
    parser.add_argument("--credential-set-id", help="owner's existing set with both runtimes connected; never modified")
    parser.add_argument("--claude-model")
    parser.add_argument("--codex-model")
    parser.add_argument("--home-runtime", choices=("claude", "codex"), default="claude")
    parser.add_argument("--wait-seconds", type=float, default=180)
    return parser.parse_args(argv)


def main(argv=None):
    args = arguments(argv)
    if args.dry_run:
        print("DRY RUN: no credentials read, no requests sent. Disposable environment, three vaults, two agents.")
        print("Checks: distinct disks; guest attach; shared writes; retained disk; DELETE isolation; lost reply reconciliation.")
        print("Finally: terminate owned conversations, discover/delete owned sandboxes, delete owned agents/vaults/environment.")
        return 0
    token = os.environ.get("FOUNTAIN_CHECK_TOKEN")
    parsed = urlsplit(args.base_url)
    if not (token and args.credential_set_id and args.claude_model and args.codex_model and
            args.wait_seconds > 0 and parsed.scheme == "https" and parsed.netloc and
            not parsed.username and not parsed.password and not parsed.query and not parsed.fragment and
            parsed.path in ("", "/")):
        print("FAIL: provide an HTTPS origin, FOUNTAIN_CHECK_TOKEN, credential-set id and both model names.")
        return 2
    check = Check(Api(args.base_url, token), args)
    def interrupt(_signum, _frame):
        raise KeyboardInterrupt
    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        check.run()
    except (Exception, KeyboardInterrupt) as error:
        # Provider bodies, token values, argv and traceback locals must never be printed.
        safe = str(error) if type(error) in (CheckFailure, ApiFailure) else "verification interrupted or failed"
        check.results.append((safe, "FAIL"))
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        previous_int = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            failures = check.cleanup()
        except Exception:
            failures = ["cleanup interrupted; inspect owned resources with prefix " + check.prefix]
        finally:
            signal.signal(signal.SIGTERM, previous)
            signal.signal(signal.SIGINT, previous_int)
    for failure in failures:
        check.results.append((failure, "FAIL"))
    check.results.append(("cleanup", "FAIL" if failures else "PASS"))
    print("RESULT | CHECK")
    for label, result in check.results:
        print(f"{result:6} | {label.replace(token, '[REDACTED]')}")
    return int(any(result == "FAIL" for _, result in check.results))


if __name__ == "__main__":
    sys.exit(main())
