#!/usr/bin/env python3
"""Offline tests for fetch-health.py (all network and command probes stubbed)."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.request
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).with_name("fetch-health.py")
SPEC = importlib.util.spec_from_file_location("fetch_health", MODULE_PATH)
assert SPEC and SPEC.loader
fetch_health = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = fetch_health
SPEC.loader.exec_module(fetch_health)

# --- stub keyring: every row that reaches himmel-secrets runs over this ---
import atexit
import shutil

_KSTUB_DIR = tempfile.mkdtemp(prefix="test-fetch-health-kstub.")
atexit.register(shutil.rmtree, _KSTUB_DIR, ignore_errors=True)
_KSTUB_SECRET_TOOL = r'''#!/usr/bin/env bash
printf 'secret-tool %s\n' "$*" >>"$KSTUB_LOG"
verb="$1"; shift
[ "${1:-}" = --all ] && shift
q=""
while [ "$#" -ge 2 ]; do q="$q $1=$2"; shift 2; done
[ "$verb" = lookup ] || exit 1
while IFS="$(printf '\t')" read -r attrs val; do
    m=1
    for p in $q; do case " $attrs " in *" $p "*) ;; *) m=0 ;; esac; done
    [ "$m" = 1 ] && { printf '%s' "$val"; exit 0; }
done <"$KSTUB_STORE"
exit 1
'''
_KSTUB_BUSCTL = r'''#!/usr/bin/env bash
printf 'busctl %s\n' "$*" >>"$KSTUB_LOG"
case "$*" in *" Locked") echo "b false" ;; esac
'''
for _n, _body in (("secret-tool", _KSTUB_SECRET_TOOL), ("busctl", _KSTUB_BUSCTL)):
    _p = Path(_KSTUB_DIR) / _n
    _p.write_text(_body)
    _p.chmod(0o755)
_KSTUB_STORE = str(Path(_KSTUB_DIR) / "keyring.tsv")
_KSTUB_LOG = str(Path(_KSTUB_DIR) / "keyring.log")
Path(_KSTUB_STORE).write_text("")
Path(_KSTUB_LOG).write_text("")
os.environ.update({"PATH": _KSTUB_DIR + os.pathsep + os.environ["PATH"],
                   "KSTUB_STORE": _KSTUB_STORE, "KSTUB_LOG": _KSTUB_LOG,
                   "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + _KSTUB_DIR + "/stub-bus"})
os.environ.pop("CREDENTIALS_DIRECTORY", None)
os.environ.pop("HIMMEL_SECRETS_KEYRING", None)
# Suite guard: abort unless the stubs are what resolve, so no row reaches a real keyring.
for _n in ("secret-tool", "busctl"):
    if not (shutil.which(_n) or "").startswith(_KSTUB_DIR):
        sys.exit(f"test_fetch_health: {_n} does not resolve to the stub keyring; aborting")


def _kput(name, value):
    with open(_KSTUB_STORE, "a") as fh:
        fh.write(f"service=himmel key={name} scope=user\t{value}\n")


class _StubResponse:
    """Minimal urlopen-style response for the main()-level probe tests."""

    def __init__(self, status: int, body: bytes):
        self.status = status
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class _StubOpener:
    def __init__(self, body: bytes, status: int = 200):
        self._body = body
        self._status = status

    def open(self, request, timeout=None):  # noqa: ANN001 - urllib opener shape
        return _StubResponse(self._status, self._body)


class FetchHealthTests(unittest.TestCase):
    def test_consumer_keys_still_load_without_unrelated_api_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text(
                "BITBUCKET_EMAIL=fixture@example.invalid\n"
                "BITBUCKET_API_TOKEN=dummy\nFIRECRAWL_API_KEY=dummy-firecrawl\n"
                "FETCH_HEALTH_REDDIT_URL=https://fixture.invalid\n"
                "TEST_ANTHROPIC_API_KEY=dummy-unrelated\nUNRELATED_API_KEY=dummy-other\n"
            )
            loaded = fetch_health.load_repo_env({}, root)
            self.assertEqual(loaded["BITBUCKET_EMAIL"], "fixture@example.invalid")
            self.assertEqual(loaded["BITBUCKET_API_TOKEN"], "dummy")
            self.assertEqual(loaded["FIRECRAWL_API_KEY"], "dummy-firecrawl")
            self.assertEqual(loaded["FETCH_HEALTH_REDDIT_URL"], "https://fixture.invalid")
            self.assertNotIn("TEST_ANTHROPIC_API_KEY", loaded)
            self.assertNotIn("UNRELATED_API_KEY", loaded)

    def test_http_classifier_covers_exact_status_taxonomy(self):
        valid = lambda body: body == b"ok"
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(200, b"ok"), auth_required=True, valid_body=valid).status, "ok")
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(401, b""), auth_required=True, valid_body=valid).status, "auth-or-cookie-expired")
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(403, b""), auth_required=False, valid_body=valid).status, "blocked-or-rate-limited")
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(429, b""), auth_required=True, valid_body=valid).status, "blocked-or-rate-limited")
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(503, b""), auth_required=True, valid_body=valid).status, "transport-fail")
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(200, b"login"), auth_required=True, valid_body=valid).status, "auth-or-cookie-expired")

    def test_command_classifier_distinguishes_auth_block_and_transport(self):
        self.assertEqual(fetch_health.classify_command(0, "").status, "ok")
        self.assertEqual(fetch_health.classify_command(1, "login required").status, "auth-or-cookie-expired")
        self.assertEqual(fetch_health.classify_command(1, "HTTP 429 rate limit").status, "blocked-or-rate-limited")
        self.assertEqual(fetch_health.classify_command(1, "connection reset").status, "transport-fail")

    def test_missing_auth_artifacts_are_classified_without_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"HOME": tmp, "PATH": ""}
            forbidden_http = lambda *args, **kwargs: self.fail("network should not run")
            forbidden_command = lambda *args, **kwargs: self.fail("command should not run")
            self.assertEqual(fetch_health.probe_bitbucket(env, forbidden_http).status, "auth-or-cookie-expired")
            self.assertEqual(fetch_health.probe_firecrawl(env, forbidden_http).status, "auth-or-cookie-expired")

    def test_reddit_is_probed_cookieless_and_validates_listing(self):
        seen = {}

        def http(url, **kwargs):
            seen.update(kwargs)
            body = json.dumps([{"data": {"children": [{"kind": "t3"}]}}, {"data": {"children": []}}]).encode()
            return fetch_health.HttpResult(200, body)

        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "reddit.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text("# Netscape HTTP Cookie File\n.reddit.com\tTRUE\t/\tTRUE\t2147483647\treddit_session\tsecret\n", encoding="utf-8")
            result = fetch_health.probe_reddit({"HOME": tmp, "REDDIT_COOKIE_FILE": str(cookie)}, http)
        self.assertEqual(result.status, "ok")
        self.assertNotIn("Cookie", seen["headers"])
        self.assertNotIn("allowed_auth_hosts", seen)

    def test_reddit_without_any_cookie_file_is_probed_not_reported_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = fetch_health.probe_reddit({"HOME": tmp}, lambda *a, **k: fetch_health.HttpResult(200, b"[]"))
        self.assertNotIn("cookie file", result.reason)

    def test_reddit_plain_403_is_the_expected_wall_not_a_page(self):
        # The fetch path reaches Reddit through Scrapling; a cookieless plain GET
        # is walled by design, so a 403 must not read as an outage.
        with tempfile.TemporaryDirectory() as tmp:
            result = fetch_health.probe_reddit({"HOME": tmp}, lambda *a, **k: fetch_health.HttpResult(403, b""))
        self.assertEqual(result.status, "ok")
        self.assertIn("expected (walled, served via Scrapling)", result.reason)

    def test_reddit_rate_limit_and_html_wall_still_alert(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"HOME": tmp}
            self.assertEqual(fetch_health.probe_reddit(env, lambda *a, **k: fetch_health.HttpResult(429, b"")).status, "blocked-or-rate-limited")
            self.assertEqual(fetch_health.probe_reddit(env, lambda *a, **k: fetch_health.HttpResult(200, b"<html>login</html>")).status, "blocked-or-rate-limited")

    def test_auth_free_probes_validate_expected_response_shape(self):
        fxt = fetch_health.probe_fxtwitter({}, lambda *args, **kwargs: fetch_health.HttpResult(200, b'{"code":200,"tweet":{"id":"20"}}'))
        ig = fetch_health.probe_instagram_embed({}, lambda *args, **kwargs: fetch_health.HttpResult(200, b'<div class="Caption">hello</div>'))
        self.assertEqual(fxt.status, "ok")
        self.assertEqual(ig.status, "ok")
        blocked = fetch_health.probe_instagram_embed({}, lambda *args, **kwargs: fetch_health.HttpResult(200, b"login wall"))
        self.assertEqual(blocked.status, "blocked-or-rate-limited")

    def test_github_uses_gh_api(self):
        seen = []

        def command(args, **kwargs):
            seen.extend(args)
            return subprocess.CompletedProcess(args, 0, "cli/cli\n", "")

        with patch.object(fetch_health.shutil, "which", return_value="/bin/gh"):
            result = fetch_health.probe_github({"PATH": "/bin"}, command)
        self.assertEqual(result.status, "ok")
        self.assertEqual(seen, ["/bin/gh", "api", "repos/cli/cli", "--jq", ".full_name"])

    def test_run_command_scrubs_pythonhome_and_pythonpath_from_child_env(self):
        # a uv python stub injects its own PYTHONHOME into
        # os.environ. Foreign CLIs (gh) may embed a DIFFERENT
        # Python runtime, so inheriting it crashes them (SRE module mismatch).
        # run_command is the single chokepoint all command probes route
        # through — assert the env handed to subprocess.run lacks both keys.
        seen_env = {}

        def fake_run(args, *, capture_output, text, env, timeout, check):
            seen_env.update(env)
            return subprocess.CompletedProcess(args, 0, "", "")

        outer_env = {"PATH": "/bin", "PYTHONHOME": "/uv/cpython", "PYTHONPATH": "/uv/lib", "SOME_KEY": "tok"}
        with patch.object(fetch_health.subprocess, "run", fake_run):
            fetch_health.run_command(["some-cli"], env=outer_env)
        self.assertNotIn("PYTHONHOME", seen_env)
        self.assertNotIn("PYTHONPATH", seen_env)
        self.assertEqual(seen_env["PATH"], "/bin")
        self.assertEqual(seen_env["SOME_KEY"], "tok")
        # The caller's own env dict (used for config lookups) is untouched.
        self.assertEqual(outer_env["PYTHONHOME"], "/uv/cpython")
        self.assertEqual(outer_env["PYTHONPATH"], "/uv/lib")

    def test_primary_repo_root_uses_git_common_dir_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            completed = subprocess.CompletedProcess(
                ["git", "rev-parse", "--git-common-dir"],
                0,
                str(root / ".git") + "\n",
                "",
            )
            with patch.object(fetch_health.subprocess, "run", return_value=completed):
                self.assertEqual(fetch_health.primary_repo_root(), root)

    def test_bitbucket_loads_primary_repo_env_shape_and_sends_basic_auth(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text("BITBUCKET_EMAIL=u@example.com\nBITBUCKET_API_TOKEN=token\n", encoding="utf-8")
            seen = {}

            def http(url, **kwargs):
                seen.update(kwargs)
                return fetch_health.HttpResult(200, b'{"uuid":"{abc}"}')

            # the merge is the registry's job now, so the probe
            # is handed the effective dict the registry would build.
            result = fetch_health.probe_bitbucket(fetch_health.load_repo_env({}, root), http)
            self.assertEqual(result.status, "ok")
            self.assertTrue(seen["headers"]["Authorization"].startswith("Basic "))
            self.assertNotIn("token", seen["headers"]["Authorization"])

    def test_load_repo_env_strips_quotes_and_inline_comments(self):
        # a raw value.strip() left a quoted dotenv value holding
        # its literal quotes (Basic auth then fails on non-cron paths) and kept
        # an inline `# comment` on the value. Covered: double + single quoted
        # values, a quoted value with a trailing comment, an inline comment, a
        # bare mid-token `#` (kept), and an unmatched opening quote (verbatim).
        clean = fetch_health._clean_dotenv_value
        self.assertEqual(clean('"secret"'), "secret")
        self.assertEqual(clean(r'"abc\"def"'), r'abc\"def')  # HIMMEL-1476: escaped quote is not the delimiter
        self.assertEqual(clean("'secret'"), "secret")
        self.assertEqual(clean('"value" # trailing comment'), "value")
        self.assertEqual(clean("tok_abc # scoped to fetch-health"), "tok_abc")
        self.assertEqual(clean("a#b"), "a#b")  # no whitespace before # → kept
        self.assertEqual(clean('"unmatched'), '"unmatched')  # leave unmatched alone
        # End-to-end via load_repo_env: a quoted token + inline comment parse
        # to the bare secret, and a leading export stays part of an unquoted value.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text(
                'BITBUCKET_API_TOKEN="quoted-secret"  # operator-injected\n'
                "BITBUCKET_EMAIL=ops@example.com # noqa\n",
                encoding="utf-8",
            )
            loaded = fetch_health.load_repo_env({}, root)
            self.assertEqual(loaded["BITBUCKET_API_TOKEN"], "quoted-secret")
            self.assertEqual(loaded["BITBUCKET_EMAIL"], "ops@example.com")

    def test_firecrawl_probes_free_credit_usage_not_scrape(self):
        # the nightly probe must not spend a credit — it reads the
        # free GET /v2/team/credit-usage, never POST /v2/scrape.
        seen = {}
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Path(tmp) / "ledger.jsonl"

            def http(url, **kwargs):
                seen["url"] = url
                seen.update(kwargs)
                return fetch_health.HttpResult(200, b'{"success":true,"data":{"remainingCredits":109,"planCredits":1000}}')

            env = {"FIRECRAWL_API_KEY": "secret", "HIMMEL_FIRECRAWL_LEDGER": str(ledger)}
            result = fetch_health.probe_firecrawl(env, http)
            self.assertEqual(result.status, "ok")
            self.assertEqual(seen["url"], "https://api.firecrawl.dev/v2/team/credit-usage")
            self.assertEqual(seen.get("method", "GET"), "GET")
            self.assertIsNone(seen.get("data"))
            rows = [json.loads(l) for l in ledger.read_text().splitlines()]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["call_site"], "fetch-health")
            self.assertEqual(rows[0]["endpoint"], "/v2/team/credit-usage")
            self.assertEqual(rows[0]["credits"], 0)
            self.assertEqual(rows[0]["v"], 1)
            self.assertEqual(rows[0]["source"], "firecrawl")
            self.assertEqual(rows[0]["kind"], "call")
            self.assertTrue(rows[0]["host"])
            self.assertTrue(rows[0]["ts"])
            self.assertNotIn("secret", ledger.read_text())

    def test_firecrawl_credit_usage_rejects_bad_body(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"FIRECRAWL_API_KEY": "secret", "HIMMEL_FIRECRAWL_LEDGER": str(Path(tmp) / "l.jsonl")}
            http = lambda url, **kw: fetch_health.HttpResult(200, b'{"success":false}')
            self.assertEqual(fetch_health.probe_firecrawl(env, http).status, "auth-or-cookie-expired")

    def test_firecrawl_normalizes_base_url_with_v2_suffix(self):
        # a FIRECRAWL_BASE_URL set WITH a /v2 suffix (or a trailing
        # slash) used to compose /v2/v2/<path>. Each variant must collapse to the
        # single canonical /v2 path.
        for base_url in (
            "https://api.firecrawl.dev/v2",
            "https://api.firecrawl.dev/v2/",
            "https://api.firecrawl.dev/",
        ):
            seen = {}

            def http(url, **kwargs):
                seen.update(url=url)
                return fetch_health.HttpResult(200, b'{"success":true,"data":{"remainingCredits":1}}')
            with tempfile.TemporaryDirectory() as tmp:
                env = {"FIRECRAWL_API_KEY": "secret", "FIRECRAWL_BASE_URL": base_url, "HIMMEL_FIRECRAWL_LEDGER": str(Path(tmp) / "l.jsonl")}
                result = fetch_health.probe_firecrawl(env, http)
            self.assertEqual(result.status, "ok", base_url)
            self.assertEqual(seen["url"], "https://api.firecrawl.dev/v2/team/credit-usage", base_url)

    def test_jina_probe_reads_public_page_without_a_key(self):
        seen = {}

        def http(url, **kwargs):
            seen["url"] = url
            seen.update(kwargs)
            return fetch_health.HttpResult(200, b"Title: Example Domain\n\nMarkdown Content:\nExample Domain\nThis domain is for use in examples.")

        result = fetch_health.probe_jina_reader({}, http)
        self.assertEqual(result.status, "ok")
        self.assertEqual(seen["url"], "https://r.jina.ai/https://example.com/")
        self.assertNotIn("Authorization", seen.get("headers") or {})
        bad = fetch_health.probe_jina_reader({}, lambda url, **kw: fetch_health.HttpResult(200, b"<html>blocked</html>"))
        self.assertEqual(bad.status, "blocked-or-rate-limited")
        limited = fetch_health.probe_jina_reader({}, lambda url, **kw: fetch_health.HttpResult(429, b""))
        self.assertEqual(limited.status, "blocked-or-rate-limited")

    def test_redirect_handler_strips_auth_off_scope(self):
        handler = fetch_health.AuthScopedRedirectHandler({"www.reddit.com"})
        request = urllib.request.Request("https://www.reddit.com/a", headers={"Cookie": "secret", "Authorization": "Bearer secret"})
        redirected = handler.redirect_request(request, None, 302, "Found", {}, "https://evil.example/landing")
        self.assertIsNotNone(redirected)
        self.assertIsNone(redirected.get_header("Cookie"))
        self.assertIsNone(redirected.get_header("Authorization"))

    def test_state_preserves_last_success_across_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fetch-health.json"
            first = datetime(2026, 8, 1, 1, 0, tzinfo=timezone.utc)
            second = datetime(2026, 8, 2, 1, 0, tzinfo=timezone.utc)
            fetch_health.write_state(path, {"reddit": fetch_health.ProbeResult("ok", "good")}, first)
            fetch_health.write_state(path, {"reddit": fetch_health.ProbeResult("transport-fail", "down")}, second)
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(data["sources"]["reddit"]["status"], "transport-fail")
            self.assertEqual(data["sources"]["reddit"]["last_success_timestamp"], int(first.timestamp()))

    def test_state_recovers_from_malformed_source_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fetch-health.json"
            path.write_text('{"version":1,"sources":{"reddit":"corrupt"}}', encoding="utf-8")
            now = datetime(2026, 8, 2, 1, 0, tzinfo=timezone.utc)
            fetch_health.write_state(path, {"reddit": fetch_health.ProbeResult("transport-fail", "down")}, now)
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(data["sources"]["reddit"]["status"], "transport-fail")
            self.assertNotIn("last_success_timestamp", data["sources"]["reddit"])

    def test_run_probes_converts_unexpected_adapter_error_to_transport(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"HOME": tmp, "PATH": ""}

            def broken_http(*args, **kwargs):
                raise RuntimeError("stub failure")

            results = fetch_health.run_probes(env, http=broken_http, command=lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError("stub failure")), repo_root=Path(tmp))
            self.assertEqual(set(results), {"reddit", "x-fxtwitter", "instagram-embed", "instagram-scrapling", "x-scrapling", "youtube-scrapling", "github", "bitbucket", "firecrawl", "jina-reader"})
            self.assertTrue(all(result.status in fetch_health.STATUSES for result in results.values()))

    def test_probe_mode_matches_full_run_for_every_source(self):
        # spec V2 "probe parity": --probe must return the same verdict as the
        # full scheduled run for every source, driven off the registry itself
        # so a newly added source cannot silently escape the assertion.
        with tempfile.TemporaryDirectory() as tmp:
            env = {"HOME": tmp, "PATH": ""}

            def http(url, **kwargs):
                return fetch_health.HttpResult(200, b"")

            def command(args, **kwargs):
                return subprocess.CompletedProcess(args, 1, "", "unauthorized")

            root = Path(tmp)
            full = fetch_health.run_probes(env, http=http, command=command, repo_root=root)
            registry = fetch_health.build_probe_registry(env, http, command, root)
            self.assertEqual(set(registry), set(full))
            for source in registry:
                # Instagram probes share throttle + cache state, so
                # each comparison starts from the same fresh state the full run had.
                fresh = dict(env, HIMMEL_IG_THROTTLE_STATE=str(root / f"{source}-t.json"),
                             HIMMEL_IG_PROBE_CACHE=str(root / f"{source}-c.json"))
                single = fetch_health.run_single_probe(source, fresh, http=http, command=command, repo_root=root)
                if source in fetch_health.IG_PROBE_SOURCES and full[source].status == "cooldown":
                    continue  # an earlier Instagram probe in the same run opened the shared cooldown
                self.assertEqual(single, full[source], source)

    def test_probe_unknown_source_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(ValueError):
                fetch_health.run_single_probe("nonexistent", {"HOME": tmp, "PATH": ""}, repo_root=root)

            stderr = io.StringIO()
            with patch.object(fetch_health, "primary_repo_root", return_value=root):
                with patch.dict(os.environ, {"HOME": tmp, "PATH": ""}, clear=True):
                    with redirect_stderr(stderr):
                        with self.assertRaises(SystemExit) as cm:
                            fetch_health.main(["--probe", "nonexistent"])
            self.assertNotEqual(cm.exception.code, 0)
            self.assertIn("nonexistent", stderr.getvalue())

    def test_probe_mode_skips_state_file_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state_file = root / "fetch-health.json"
            env = {"HOME": tmp, "PATH": "", "HIMMEL_SECRETS_KEYRING": "off", "HIMMEL_FETCH_HEALTH_STATE": str(state_file)}
            with patch.object(fetch_health, "primary_repo_root", return_value=root):
                with patch.dict(os.environ, env, clear=True):
                    stdout = io.StringIO()
                    with redirect_stdout(stdout):
                        exit_code = fetch_health.main(["--probe", "github"])
            self.assertEqual(exit_code, 1)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload, {"status": "transport-fail", "reason": "gh CLI missing"})
            self.assertFalse(state_file.exists())

    def test_probe_mode_exit_code_zero_when_status_ok(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = {"HOME": tmp, "PATH": "/bin", "HIMMEL_SECRETS_KEYRING": "off"}
            completed = subprocess.CompletedProcess(["gh"], 0, "cli/cli\n", "")
            with patch.object(fetch_health, "primary_repo_root", return_value=root):
                with patch.object(fetch_health.shutil, "which", return_value="/bin/gh"):
                    with patch.object(fetch_health.subprocess, "run", return_value=completed):
                        with patch.dict(os.environ, env, clear=True):
                            stdout = io.StringIO()
                            with redirect_stdout(stdout):
                                exit_code = fetch_health.main(["--probe", "github"])
            self.assertEqual(exit_code, 0)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload, {"status": "ok", "reason": "command probe succeeded"})

    def test_main_probe_reads_keys_that_live_only_in_the_repo_dotenv(self):
        # load_repo_env used to be called from probe_bitbucket
        # ALONE, so every other probe saw the raw process env. The cron wrapper
        # sources nothing, so a key that lives only in the checkout's .env — the
        # documented place — read as "missing" on every scheduled and manual
        # run. Drive this through main() so the fix has to sit at the loader
        # boundary, not in one more probe.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text(
                "FIRECRAWL_API_KEY=fc-secret\n",
                encoding="utf-8",
            )
            firecrawl_body = b'{"success":true,"data":{"remainingCredits":109}}'

            def run_probe(source):
                # main() reaches fetch_http through a DEFAULT ARGUMENT bound at
                # def time, so patching the module attribute would not take and
                # the probe would hit the real network. Stub the opener that
                # fetch_http builds instead — that is the actual socket seam.
                with patch.object(fetch_health, "primary_repo_root", return_value=root):
                    with patch.object(fetch_health.urllib.request, "build_opener", lambda *a, **k: _StubOpener(firecrawl_body)):
                        with patch.dict(os.environ, {"HOME": tmp, "PATH": "/bin", "HIMMEL_SECRETS_KEYRING": "off", "HIMMEL_FIRECRAWL_LEDGER": str(root / "ledger.jsonl")}, clear=True):
                            stdout = io.StringIO()
                            with redirect_stdout(stdout):
                                code = fetch_health.main(["--probe", source])
                return code, json.loads(stdout.getvalue())

            for source in ("firecrawl",):
                code, payload = run_probe(source)
                self.assertNotIn("missing", payload["reason"], source)
                self.assertEqual(payload["status"], "ok", source)
                self.assertEqual(code, 0, source)

            # Control: with the .env gone the same probe must still report
            # the credential as missing — the fix must read the FILE, not
            # invent a default.
            (root / ".env").unlink()
            for source, expected in (("firecrawl", "Firecrawl API key missing"),):
                code, payload = run_probe(source)
                self.assertEqual(payload["status"], "auth-or-cookie-expired", source)
                self.assertIn(expected, payload["reason"], source)

    def test_load_repo_env_keeps_first_occurrence_and_treats_empty_as_absent(self):
        # Duplicate-key policy: FIRST occurrence in the file wins,
        # matching the awk `key in seen` guard in scripts/lib/load-dotenv.sh.
        # A set-but-EMPTY process value counts as ABSENT (also matching that
        # loader) — an exported `KEY=` placeholder used to shadow
        # the real .env value and every probe then reported "missing".
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text(
                "FIRECRAWL_API_KEY=first\nFIRECRAWL_API_KEY=second\nBITBUCKET_EMAIL=from-file\n",
                encoding="utf-8",
            )
            loaded = fetch_health.load_repo_env({"BITBUCKET_EMAIL": "", "BITBUCKET_API_TOKEN": "live"}, root)
            self.assertEqual(loaded["FIRECRAWL_API_KEY"], "first")
            self.assertEqual(loaded["BITBUCKET_EMAIL"], "from-file")
            # A live NON-empty process value still wins over the file.
            self.assertEqual(loaded["BITBUCKET_API_TOKEN"], "live")

    def test_load_repo_env_treats_a_whitespace_only_process_value_as_present(self):
        # "empty" means ZERO-LENGTH, exactly
        # like bash's `[ -z "${KEY-}" ]` (the documented shell-side policy
        # this mirrors) — confirmed live: `KEY="   "; [ -z "${KEY-}" ]` is
        # FALSE, i.e. present, so load_dotenv.sh does NOT load from the file.
        # A prior `.strip()` check here disagreed (treated it as absent and
        # loaded from the file), breaking the parity this function exists to
        # guarantee. The zero-length ("") case is the DIFFERENT, correct
        # behaviour — see the test above, which must stay green.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text("FIRECRAWL_API_KEY=from-file\n", encoding="utf-8")
            loaded = fetch_health.load_repo_env({"FIRECRAWL_API_KEY": "   "}, root)
            self.assertEqual(loaded["FIRECRAWL_API_KEY"], "   ")

    def test_child_process_probes_never_see_the_merged_dotenv_secrets(self):
        # build_probe_registry's merged .env dict
        # (`effective`) is for CONFIG LOOKUP only. A probe that shells out to
        # a third-party binary (gh) must receive the PRE-MERGE process env as
        # its child environment, never `effective` -- the checkout's real .env
        # carries ~120 keys (ROUTER_PASS, WIFI_5_PASS, JIRA_API_TOKEN, ...)
        # that no child has any business seeing. ROUTER_PASS stands in for that
        # whole class of unrelated repo secret.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text("FIRECRAWL_API_KEY=fc\nROUTER_PASS=should-not-leak\n", encoding="utf-8")
            seen_envs: dict[str, dict[str, str]] = {}

            def command(args, **kwargs):
                seen_envs[args[0]] = dict(kwargs["env"])
                return subprocess.CompletedProcess(args, 0, "{}", "")

            def which_stub(binary, path=None):
                return f"/bin/{binary}"

            base_env = {"HOME": tmp, "PATH": "/bin"}
            with patch.object(fetch_health.shutil, "which", which_stub):
                registry = fetch_health.build_probe_registry(
                    base_env, lambda *a, **k: fetch_health.HttpResult(200, b""), command, root
                )
                self.assertEqual(registry["github"]().status, "ok")

            self.assertNotIn("ROUTER_PASS", seen_envs["/bin/gh"])


@unittest.skipIf(sys.platform == "darwin", "the resolver skips the keyring on Darwin")
class KeyringReaderTests(unittest.TestCase):
    """HIMMEL-8370 S0b: load_repo_env finds a secret in the keyring (rows S0-R6, S0-R2)."""

    def setUp(self):
        Path(_KSTUB_STORE).write_text("")
        Path(_KSTUB_LOG).write_text("")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        env = patch.dict(os.environ)
        env.start()
        self.addCleanup(env.stop)
        for k in ("BITBUCKET_API_TOKEN", "FIRECRAWL_API_KEY"):
            os.environ.pop(k, None)

    def test_s0_r6_keyring_only_bitbucket_token(self):
        _kput("BITBUCKET_API_TOKEN", "dummy-bb-s0")
        loaded = fetch_health.load_repo_env({}, self.root)
        self.assertEqual(loaded["BITBUCKET_API_TOKEN"], "dummy-bb-s0")
        log = Path(_KSTUB_LOG).read_text()
        self.assertIn("secret-tool lookup", log)
        self.assertNotIn("dummy-bb-s0", log)  # a lookup argv carries no value

    def test_s0_r2_keyring_wins_over_dotenv(self):
        _kput("FIRECRAWL_API_KEY", "dummy-from-keyring")
        (self.root / ".env").write_text("FIRECRAWL_API_KEY=dummy-from-dotenv\n")
        loaded = fetch_health.load_repo_env({}, self.root)
        self.assertEqual(loaded["FIRECRAWL_API_KEY"], "dummy-from-keyring")

    def test_a_live_process_value_still_wins(self):
        _kput("BITBUCKET_API_TOKEN", "dummy-from-keyring")
        loaded = fetch_health.load_repo_env({"BITBUCKET_API_TOKEN": "dummy-live"}, self.root)
        self.assertEqual(loaded["BITBUCKET_API_TOKEN"], "dummy-live")

    def test_dotenv_stays_the_last_fallback(self):
        (self.root / ".env").write_text("BITBUCKET_API_TOKEN=dummy-from-dotenv\n")
        loaded = fetch_health.load_repo_env({}, self.root)
        self.assertEqual(loaded["BITBUCKET_API_TOKEN"], "dummy-from-dotenv")


class InstagramScraplingProbeTests(unittest.TestCase):
    """HIMMEL-4675: the cookieless Scrapling path the media rung now tries first."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.py = self.tmp / ".himmel" / "scrapling-venv" / "bin" / "python"
        self.env = {"HOME": str(self.tmp), "PATH": "",
                    "HIMMEL_IG_THROTTLE_STATE": str(self.tmp / "t.json"),
                    "HIMMEL_IG_PROBE_CACHE": str(self.tmp / "c.json"),
                    "HIMMEL_IG_MIN_GAP_S": "0", "HIMMEL_IG_JITTER_S": "0"}
        self.seen = []

    def venv(self):
        self.py.parent.mkdir(parents=True)
        self.py.write_text("#!/bin/sh\n", encoding="utf-8")
        self.py.chmod(0o755)

    def command(self, returncode, stdout):
        def run(args, **kwargs):
            self.seen.append((args, kwargs))
            return subprocess.CompletedProcess(args, returncode, stdout, "")
        return run

    def probe(self, command):
        return fetch_health.run_single_probe("instagram-scrapling", self.env, http=lambda *a, **k: None,
                                             command=command, repo_root=self.tmp)

    def test_is_a_guarded_instagram_probe(self):
        self.assertIn("instagram-scrapling", fetch_health.IG_PROBE_SOURCES)

    def test_missing_venv_names_the_venv_and_sends_nothing(self):
        r = self.probe(lambda *a, **k: self.fail("command should not run"))
        self.assertEqual(r.status, "transport-fail")
        self.assertIn("scrapling-venv", r.reason)

    def test_ok_runs_the_plugin_helper_cookieless(self):
        self.venv()
        r = self.probe(self.command(0, '{"status": "ok", "caption": null, "items": [{"kind": "image", "url": "u"}]}'))
        self.assertEqual(r.status, "ok")
        args, kwargs = self.seen[0]
        helper = self.tmp / "marketplace/plugins/obsidian-triage/tools/ig-scrapling-media.py"
        self.assertEqual(args[:2], [str(self.py), str(helper)])
        self.assertEqual(args[2:], ["--url", fetch_health.DEFAULT_URLS["instagram"], "--shortcode", "CG0UU3ylXnv"])
        self.assertNotIn("--cookies", args)

    def test_login_wall_is_blocked(self):
        self.venv()
        r = self.probe(self.command(4, '{"status": "login_wall", "detail": "/accounts/login/"}'))
        self.assertEqual(r.status, "blocked-or-rate-limited")
        self.assertIn("login_wall", r.reason)

    def test_helper_without_scrapling_is_transport_fail(self):
        self.venv()
        r = self.probe(self.command(3, '{"status": "error", "detail": "scrapling not installed"}'))
        self.assertEqual(r.status, "transport-fail")
        self.assertIn("scrapling not installed", r.reason)


class XYouTubeScraplingProbeTests(unittest.TestCase):
    """HIMMEL-4677: the cookieless Scrapling paths X and YouTube use."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.py = self.tmp / ".himmel" / "scrapling-venv" / "bin" / "python"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.env = {"HOME": str(self.tmp), "PATH": str(self.bin)}
        self.seen = []

    def venv(self):
        self.py.parent.mkdir(parents=True)
        self.py.write_text("#!/bin/sh\n", encoding="utf-8")
        self.py.chmod(0o755)

    def ytdlp(self):
        exe = self.bin / "yt-dlp"
        exe.write_text("#!/bin/sh\n", encoding="utf-8")
        exe.chmod(0o755)

    def command(self, returncode, stdout):
        def run(args, **kwargs):
            self.seen.append((args, kwargs))
            return subprocess.CompletedProcess(args, returncode, stdout, "")
        return run

    def probe(self, source, command):
        return fetch_health.run_single_probe(source, self.env, http=lambda *a, **k: self.fail("no http"),
                                             command=command, repo_root=self.tmp)

    def test_missing_venv_names_the_venv_and_sends_nothing(self):
        for source in ("x-scrapling", "youtube-scrapling"):
            r = self.probe(source, lambda *a, **k: self.fail("command should not run"))
            self.assertEqual(r.status, "transport-fail", source)
            self.assertIn("scrapling-venv", r.reason, source)

    def test_x_ok_runs_the_plugin_helper_cookieless(self):
        self.venv()
        r = self.probe("x-scrapling", self.command(0, '{"status": "ok", "items": [{"kind": "video", "url": "u", "hls": true}]}'))
        self.assertEqual(r.status, "ok")
        self.assertIn("1 media item", r.reason)
        args, _ = self.seen[0]
        helper = self.tmp / "marketplace/plugins/obsidian-triage/tools/x-scrapling-media.py"
        self.assertEqual(args[:2], [str(self.py), str(helper)])
        self.assertEqual(args[2:], ["--url", fetch_health.DEFAULT_URLS["x"], "--status-id", "266031293945503744"])
        self.assertNotIn("--cookies", args)

    def test_x_probe_tweet_still_carries_media(self):
        # the old pin (Twitter/1354143047324299264) lost its media, so
        # the helper correctly said no_media and the probe alerted nightly. The
        # fixture is the recorded api.fxtwitter.com response for the pinned tweet;
        # re-record it when re-pinning DEFAULT_URLS["x"].
        fx = json.loads((Path(__file__).with_name("fixtures") / "x-media-probe-fxtwitter.json").read_text())["tweet"]
        self.assertEqual(fetch_health.DEFAULT_URLS["x"].rstrip("/").split("/")[-1], fx["id"])
        self.assertTrue((fx.get("media") or {}).get("all"), "the pinned probe tweet must carry media")

    def test_x_login_wall_is_blocked(self):
        self.venv()
        r = self.probe("x-scrapling", self.command(4, '{"status": "login_wall", "detail": "/i/flow/login"}'))
        self.assertEqual(r.status, "blocked-or-rate-limited")

    def test_youtube_needs_ytdlp_for_the_transcript(self):
        self.venv()
        r = self.probe("youtube-scrapling", lambda *a, **k: self.fail("command should not run"))
        self.assertEqual(r.status, "transport-fail")
        self.assertIn("yt-dlp", r.reason)

    def test_youtube_ok_reports_the_transcript_source(self):
        self.venv()
        self.ytdlp()
        out = json.dumps({"status": "ok", "title": "t", "transcript": [{"ts": "0:00", "tx": "a"}, {"ts": "0:01", "tx": "b"}],
                          "transcript_source": "yt-dlp", "transcript_error": None})
        r = self.probe("youtube-scrapling", self.command(0, out))
        self.assertEqual(r.status, "ok")
        self.assertIn("transcript via yt-dlp", r.reason)
        self.assertIn("2 line", r.reason)
        args, _ = self.seen[0]
        helper = self.tmp / "marketplace/plugins/obsidian-triage/tools/yt-scrapling-meta.py"
        self.assertEqual(args, [str(self.py), str(helper), "--video-id", "dQw4w9WgXcQ"])

    def test_youtube_metadata_without_transcript_is_not_ok(self):
        self.venv()
        self.ytdlp()
        out = json.dumps({"status": "ok", "title": "t", "transcript": [], "transcript_source": "yt-dlp",
                          "transcript_error": "yt_dlp_error"})
        r = self.probe("youtube-scrapling", self.command(0, out))
        self.assertEqual(r.status, "transport-fail")
        self.assertIn("yt_dlp_error", r.reason)

class InstagramGuardTests(unittest.TestCase):
    """HIMMEL-4306: the Instagram probes share the throttle and cache their
    verdict, so status/doctor runs stop hitting the operator's account."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.env = {
            "HOME": str(self.tmp),
            "PATH": "",
            "HIMMEL_IG_THROTTLE_STATE": str(self.tmp / "throttle.json"),
            "HIMMEL_IG_PROBE_CACHE": str(self.tmp / "probe-cache.json"),
            "HIMMEL_IG_MIN_GAP_S": "0",
            "HIMMEL_IG_JITTER_S": "0",
        }
        self.calls = 0

    def command(self, returncode=0, stderr=""):
        def run(*args, **kwargs):
            self.calls += 1
            return subprocess.CompletedProcess(args, returncode, "", stderr)
        return run

    def http(self, status=200, body=b'<div class="Caption">hi</div>'):
        def get(*args, **kwargs):
            self.calls += 1
            return fetch_health.HttpResult(status, body)
        return get

    def probe(self, source, *, command=None, http=None):
        return fetch_health.run_single_probe(
            source, self.env, http=http or self.http(), command=command or self.command(), repo_root=self.tmp)

    def age_cache(self, source, seconds):
        path = Path(self.env["HIMMEL_IG_PROBE_CACHE"])
        data = json.loads(path.read_text(encoding="utf-8"))
        data[source]["checked_epoch"] -= seconds
        path.write_text(json.dumps(data), encoding="utf-8")

    def test_cooldown_is_a_status(self):
        self.assertIn("cooldown", fetch_health.STATUSES)

    def test_second_embed_probe_is_served_from_the_cache(self):
        first = self.probe("instagram-embed")
        second = self.probe("instagram-embed")
        self.assertEqual(first.status, "ok")
        self.assertEqual(second.status, "ok")
        self.assertEqual(self.calls, 1)
        self.assertIn("cached", second.reason)

    def test_embed_probe_is_cached_too(self):
        self.probe("instagram-embed")
        self.probe("instagram-embed")
        self.assertEqual(self.calls, 1)

    def test_an_ok_verdict_expires_after_24h(self):
        self.probe("instagram-embed")
        self.age_cache("instagram-embed", 24 * 3600 + 60)
        self.probe("instagram-embed")
        self.assertEqual(self.calls, 2)

    def test_a_failed_verdict_is_only_cached_for_an_hour(self):
        self.env["HIMMEL_IG_BACKOFF_BASE_S"] = "0"  # isolate the cache TTL from the throttle backoff
        bad = self.http(503, b"")
        self.assertEqual(self.probe("instagram-embed", http=bad).status, "transport-fail")
        self.probe("instagram-embed", http=bad)
        self.assertEqual(self.calls, 1)
        self.age_cache("instagram-embed", 3600 + 60)
        self.probe("instagram-embed", http=bad)
        self.assertEqual(self.calls, 2)

    def test_429_starts_a_cooldown_and_later_probes_send_nothing(self):
        r = self.probe("instagram-embed", http=self.http(429, b""))
        self.assertEqual(r.status, "blocked-or-rate-limited")
        self.calls = 0
        media = self.probe("instagram-scrapling")
        self.assertEqual(media.status, "cooldown")
        self.assertIn("cooldown", media.reason)
        embed = self.probe("instagram-embed")
        self.assertEqual(embed.status, "cooldown")
        self.assertEqual(self.calls, 0)

    def test_a_probe_never_waits_for_a_slot_it_reports_cooldown(self):
        self.env["HIMMEL_IG_MIN_GAP_S"] = "600"
        self.probe("instagram-embed")  # takes the slot
        r = self.probe("instagram-scrapling")
        self.assertEqual(r.status, "cooldown")
        self.assertEqual(self.calls, 1)

    def test_a_cooldown_run_exits_zero_and_is_not_a_failure(self):
        import contextlib
        self.env["HIMMEL_IG_DAILY_CAP"] = "0"
        with patch.dict(os.environ, self.env, clear=False), patch.object(fetch_health, "primary_repo_root", return_value=self.tmp):
            buf = io.StringIO()
            with redirect_stdout(buf), redirect_stderr(io.StringIO()):
                rc = fetch_health.main(["--probe", "instagram-embed"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(buf.getvalue())["status"], "cooldown")

    def test_other_sources_are_not_throttled_or_cached(self):
        for _ in range(2):
            fetch_health.run_single_probe("x-fxtwitter", self.env, http=self.http(200, b'{"code":200,"tweet":{"id":"20"}}'),
                                          command=self.command(), repo_root=self.tmp)
        self.assertEqual(self.calls, 2)


if __name__ == "__main__":
    unittest.main()
