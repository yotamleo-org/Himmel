#!/usr/bin/env python3
"""Daily no-LLM health probes for Luna clip-source fetch integrations."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

# the Instagram throttle lives with the obsidian-triage tools.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "marketplace" / "plugins" / "obsidian-triage" / "tools" / "lib"))
try:
    import ig_throttle
except ImportError:  # fail closed: no throttle module, no Instagram request
    ig_throttle = None

STATUSES = (
    "ok",
    "auth-or-cookie-expired",
    "blocked-or-rate-limited",
    "transport-fail",
    # the Instagram throttle is holding requests back. Not a fault.
    "cooldown",
)
TIMEOUT_SECONDS = 30
USER_AGENT = "himmel-fetch-health/1.0"

# Fixed known-good URLs send no Luna corpus content. The egress matrix governs
# corpus-to-provider content, so no matrix row or ledger applies; response bodies
# stay in memory and only the classification state below is persisted.
DEFAULT_URLS = {
    "reddit": "https://www.reddit.com/r/reddit.com/comments/87/the_downing_street_memo/",
    "x-fxtwitter": "https://api.fxtwitter.com/jack/status/20",
    "instagram-embed": "https://www.instagram.com/p/CG0UU3ylXnv/embed/captioned/",
    "instagram": "https://www.instagram.com/p/CG0UU3ylXnv/",
    # a 2012 photo tweet from a head-of-state account; the old pin
    # (Twitter/1354143047324299264) lost its media. Re-record the fxtwitter fixture
    # scripts/luna/fixtures/x-media-probe-fxtwitter.json when re-pinning.
    "x": "https://x.com/BarackObama/status/266031293945503744",
    "youtube": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "jina-reader": "https://example.com/",
}


@dataclass(frozen=True)
class ProbeResult:
    status: str
    reason: str

    def __post_init__(self) -> None:
        if self.status not in STATUSES:
            raise ValueError(f"invalid fetch-health status: {self.status}")


@dataclass(frozen=True)
class HttpResult:
    status: int
    body: bytes


class AuthScopedRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Never forward Cookie/Authorization headers to an off-scope redirect."""

    def __init__(self, allowed_auth_hosts: set[str]):
        super().__init__()
        self.allowed_auth_hosts = {host.lower() for host in allowed_auth_hosts}

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is None:
            return None
        host = (urllib.parse.urlparse(newurl).hostname or "").lower()
        if host not in self.allowed_auth_hosts:
            redirected.remove_header("Cookie")
            redirected.remove_header("Authorization")
        return redirected


def resolve_home(env: dict[str, str]) -> Path:
    if os.name == "nt" and env.get("USERPROFILE"):
        return Path(env["USERPROFILE"])
    return Path(env.get("HOME") or env.get("USERPROFILE") or str(Path.home()))


def state_path(env: dict[str, str]) -> Path:
    override = env.get("HIMMEL_FETCH_HEALTH_STATE", "").strip()
    if override:
        return Path(override)
    return resolve_home(env) / ".himmel" / "fetch-health.json"


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def fetch_http(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    data: bytes | None = None,
    allowed_auth_hosts: set[str] | None = None,
    timeout: int = TIMEOUT_SECONDS,
) -> HttpResult:
    request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    opener = urllib.request.build_opener(AuthScopedRedirectHandler(allowed_auth_hosts or set()))
    try:
        with opener.open(request, timeout=timeout) as response:
            return HttpResult(response.status, response.read())
    except urllib.error.HTTPError as error:
        return HttpResult(error.code, error.read())


def classify_http(
    result: HttpResult,
    *,
    auth_required: bool,
    valid_body: Callable[[bytes], bool],
) -> ProbeResult:
    if result.status == 429:
        return ProbeResult("blocked-or-rate-limited", "http-429")
    if result.status == 401:
        return ProbeResult("auth-or-cookie-expired", "http-401")
    if result.status == 403:
        status = "auth-or-cookie-expired" if auth_required else "blocked-or-rate-limited"
        return ProbeResult(status, "http-403")
    if result.status < 200 or result.status >= 300:
        return ProbeResult("transport-fail", f"http-{result.status}")
    if valid_body(result.body):
        return ProbeResult("ok", "known-good response validated")
    status = "auth-or-cookie-expired" if auth_required else "blocked-or-rate-limited"
    return ProbeResult(status, "unexpected response shape")


def _json(body: bytes):
    return json.loads(body.decode("utf-8"))


def probe_reddit(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    # Cookieless. The fetch path reaches Reddit through Scrapling, so a plain
    # unauthenticated GET is walled by design: 403 is expected, not an outage.
    url = env.get("FETCH_HEALTH_REDDIT_URL", DEFAULT_URLS["reddit"]).rstrip("/") + ".json?raw_json=1"
    try:
        result = http(url, headers={"Accept": "application/json", "User-Agent": USER_AGENT})
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "reddit request failed")
    if result.status == 403:
        return ProbeResult("ok", "expected (walled, served via Scrapling)")

    def valid(body: bytes) -> bool:
        try:
            data = _json(body)
            return isinstance(data, list) and len(data) >= 2 and data[0].get("data", {}).get("children", [{}])[0].get("kind") == "t3"
        except (ValueError, KeyError, IndexError, AttributeError):
            return False

    return classify_http(result, auth_required=False, valid_body=valid)


def probe_fxtwitter(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    url = env.get("FETCH_HEALTH_FXTWITTER_URL", DEFAULT_URLS["x-fxtwitter"])
    try:
        result = http(url, headers={"Accept": "application/json", "User-Agent": USER_AGENT})
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "fxtwitter request failed")

    def valid(body: bytes) -> bool:
        try:
            data = _json(body)
            return data.get("code") == 200 and isinstance(data.get("tweet"), dict)
        except (ValueError, AttributeError):
            return False

    return classify_http(result, auth_required=False, valid_body=valid)


def probe_instagram_embed(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    url = env.get("FETCH_HEALTH_INSTAGRAM_EMBED_URL", DEFAULT_URLS["instagram-embed"])
    try:
        result = http(url, headers={"Accept": "text/html", "User-Agent": USER_AGENT})
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "instagram embed request failed")
    return classify_http(result, auth_required=False, valid_body=lambda body: b"Caption" in body)


def classify_command(returncode: int, stderr: str) -> ProbeResult:
    if returncode == 0:
        return ProbeResult("ok", "command probe succeeded")
    text = stderr.lower()
    detail = f" (rc={returncode})"
    if re.search(r"429|rate.?limit|too many requests|temporarily blocked|challenge", text):
        return ProbeResult("blocked-or-rate-limited", "command reported block or rate limit" + detail)
    if re.search(r"401|403|auth|login|cookie|credential|unauthorized|forbidden", text):
        return ProbeResult("auth-or-cookie-expired", "command reported authentication failure" + detail)
    return ProbeResult("transport-fail", "command probe failed" + detail)


def run_command(args: list[str], *, env: dict[str, str], timeout: int = TIMEOUT_SECONDS) -> subprocess.CompletedProcess[str]:
    # Foreign CLIs (gh) may embed their own Python runtime. A
    # PYTHONHOME/PYTHONPATH inherited from the invoking interpreter (e.g. a uv
    # python stub that injects its own PYTHONHOME) points that runtime at the
    # WRONG stdlib and crashes it (SRE module mismatch class); PYTHONPATH is
    # stripped alongside it defensively (no observed repro, same failure class).
    # Scrub only what reaches subprocess.run — the caller's `env` dict (used for
    # config lookups) is left untouched.
    child_env = {k: v for k, v in env.items() if k not in ("PYTHONHOME", "PYTHONPATH")}
    return subprocess.run(args, capture_output=True, text=True, env=child_env, timeout=timeout, check=False)


def probe_github(
    env: dict[str, str],
    command: Callable[..., subprocess.CompletedProcess[str]],
    *,
    child_env: dict[str, str] | None = None,
) -> ProbeResult:
    binary = shutil.which("gh", path=env.get("PATH"))
    if not binary:
        return ProbeResult("transport-fail", "gh CLI missing")
    try:
        # gh authenticates from its own
        # config, needing no .env key — child_env (pre-merge process env)
        # unchanged, never `env` (the whole-checkout-.env lookup dict).
        completed = command(
            [binary, "api", "repos/cli/cli", "--jq", ".full_name"],
            env=child_env if child_env is not None else env,
            timeout=TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ProbeResult("transport-fail", "gh invocation failed")
    return classify_command(completed.returncode, completed.stderr)


def primary_repo_root() -> Path:
    """Resolve the primary checkout, matching scripts/bitbucket/src/env.ts."""
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
            check=False,
        )
        if completed.returncode == 0 and completed.stdout.strip():
            common = Path(completed.stdout.strip())
            if not common.is_absolute():
                common = (Path.cwd() / common).resolve()
            return common.parent
    except (OSError, subprocess.TimeoutExpired):
        pass
    return Path(__file__).resolve().parents[2]


def _clean_dotenv_value(raw: str) -> str:
    # Normalize a dotenv value: the prior raw value.strip() left
    # BITBUCKET_API_TOKEN="secret" holding literal quotes, so Basic auth failed
    # on any non-cron path where no shell pre-sources the file, and an inline
    # `# comment` was kept on the value. Strip MATCHED surrounding single or
    # double quotes (an unmatched opening quote is left verbatim — don't guess
    # where it closes), then drop a trailing unquoted inline comment: a `#`
    # preceded by whitespace, mirroring python-dotenv so a bare mid-token `#`
    # (KEY=a#b) is preserved and a quoted value keeps the `#` inside its quotes.
    # Scan for the first UNESCAPED closing quote (prev char not a
    # backslash) so an embedded `\"` no longer counts as the delimiter — the
    # prior value.find(value[0], 1) truncated `"abc\"def"` to `abc\`. A full
    # escape parser is out of scope, so `\\"` (escaped backslash, then the real
    # closing quote) still reads as escaped and over-runs — accepted here.
    value = raw.strip()
    if value and value[0] in ('"', "'"):
        quote = value[0]
        for close in range(1, len(value)):
            if value[close] == quote and value[close - 1] != "\\":
                return value[1:close]
    return re.sub(r"\s+#.*", "", value)


DOTENV_KEYS = frozenset({
    "BITBUCKET_EMAIL", "BITBUCKET_API_TOKEN", "FIRECRAWL_API_KEY", "FIRECRAWL_BASE_URL",
    "HIMMEL_FETCH_HEALTH_STATE", "HIMMEL_FIRECRAWL_LEDGER", "HIMMEL_IG_PROBE_CACHE", "HIMMEL_IG_PROBE_TTL_S",
    "FETCH_HEALTH_REDDIT_URL", "FETCH_HEALTH_FXTWITTER_URL", "FETCH_HEALTH_INSTAGRAM_EMBED_URL",
    "FETCH_HEALTH_INSTAGRAM_MEDIA_URL", "FETCH_HEALTH_X_MEDIA_URL",
    "FETCH_HEALTH_YOUTUBE_URL", "FETCH_HEALTH_JINA_URL", "IG_SCRAPLING_PYTHON", "X_SCRAPLING_PYTHON", "YT_SCRAPLING_PYTHON",
})


def load_repo_env(env: dict[str, str], repo_root: Path) -> dict[str, str]:
    loaded = dict(env)
    env_file = repo_root / ".env"
    if not env_file.is_file():
        return loaded
    # Duplicate/absent policy, mirroring scripts/lib/load-dotenv.sh
    # so the two loaders cannot disagree about the same file:
    #   * the FIRST occurrence of a key in the file wins (that loader's awk
    #     `key in seen` guard) — including an empty `KEY=` placeholder, which
    #     therefore shadows a value appended lower down, in BOTH loaders;
    #   * an existing value that is set-but-EMPTY counts as ABSENT (its
    #     rule). A plain setdefault would let a bare `KEY=` exported
    #     into the process env win, and every probe would then read "missing" while
    #     the .env held the real value.
    # A live NON-empty process value still wins over the file.
    #
    # "empty" here means ZERO-LENGTH, exactly like
    # bash's `[ -z "${KEY-}" ]` (the documented shell-side policy this
    # mirrors) — NOT `.strip()`-empty. A whitespace-only exported value
    # (`KEY="   "`) makes `[ -z ]` false, so load_dotenv.sh treats it as
    # PRESENT and does not load from the file; a `.strip()` check here would
    # have disagreed and loaded from the file anyway, breaking the parity
    # this function exists to guarantee. Confirmed both ways:
    # `KEY="   "; [ -z "${KEY-}" ]` -> false (present) in bash. The FILE side
    # is unaffected by this distinction: `_clean_dotenv_value` (this file)
    # and `_load_dotenv_trim` (load-dotenv.sh) both strip a file value before
    # it is ever compared, so a whitespace-only line in the .env still reads
    # as the trimmed value on both sides either way.
    seen: set[str] = set()
    try:
        for line in env_file.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            key = key.strip()
            if key not in DOTENV_KEYS or key in seen or loaded.get(key, ""):
                continue
            seen.add(key)
            loaded[key] = _clean_dotenv_value(value)
    except OSError:
        pass
    return loaded


def probe_bitbucket(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    # The .env merge happens in build_probe_registry, so this
    # probe is no longer the only one that can see the checkout's config.
    email = env.get("BITBUCKET_EMAIL", "").rstrip()
    token = env.get("BITBUCKET_API_TOKEN", "").rstrip()
    if not email or not token:
        return ProbeResult("auth-or-cookie-expired", "Bitbucket credentials missing")
    auth = base64.b64encode(f"{email}:{token}".encode()).decode()
    try:
        result = http(
            "https://api.bitbucket.org/2.0/user",
            headers={"Accept": "application/json", "Authorization": f"Basic {auth}", "User-Agent": USER_AGENT},
            allowed_auth_hosts={"api.bitbucket.org"},
        )
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "Bitbucket request failed")

    def valid(body: bytes) -> bool:
        try:
            data = _json(body)
            return bool(data.get("uuid") or data.get("account_id"))
        except (ValueError, AttributeError):
            return False

    return classify_http(result, auth_required=True, valid_body=valid)


def firecrawl_ledger_append(env: dict[str, str], endpoint: str, credits: int, ok: bool = True) -> None:
    """One line in the shared per-call Firecrawl ledger: same
    file and shape as harvest-clip-body-batch.py. Never the key or any body;
    a write failure never fails the probe."""
    override = env.get("HIMMEL_FIRECRAWL_LEDGER", "").strip()
    path = Path(override) if override else resolve_home(env) / ".himmel" / "state" / "firecrawl-ledger.jsonl"
    row = {
        "v": 1,
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": socket.gethostname(),
        "source": "firecrawl",
        "kind": "call",
        "call_site": "fetch-health",
        "endpoint": endpoint,
        "credits": credits,
        "ok": ok,
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(row) + "\n")
    except OSError:
        pass


def probe_firecrawl(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    api_key = env.get("FIRECRAWL_API_KEY", "").strip()
    if not api_key:
        return ProbeResult("auth-or-cookie-expired", "Firecrawl API key missing")
    # Normalize the base: rstrip("/") alone left a FIRECRAWL_BASE_URL
    # set WITH a /v2 suffix composing /v2/v2/scrape. Drop a trailing /v2 (then any
    # newly-exposed slash) before appending the /v2 path ourselves.
    base_url = re.sub(r"/v2$", "", env.get("FIRECRAWL_BASE_URL", "").strip().rstrip("/")) or "https://api.firecrawl.dev"
    api_host = (urllib.parse.urlparse(base_url).hostname or "").lower()
    # probe the FREE credit-usage endpoint — a scrape probe cost a
    # credit every night. A valid response proves the key and the API are live.
    endpoint = "/v2/team/credit-usage"
    try:
        result = http(
            f"{base_url}{endpoint}",
            headers={"Authorization": f"Bearer {api_key}", "User-Agent": USER_AGENT},
            allowed_auth_hosts={api_host},
        )
    except (OSError, urllib.error.URLError, TimeoutError):
        firecrawl_ledger_append(env, endpoint, 0, ok=False)
        return ProbeResult("transport-fail", "Firecrawl request failed")
    firecrawl_ledger_append(env, endpoint, 0, ok=200 <= result.status < 300)

    def valid(body: bytes) -> bool:
        try:
            data = _json(body)
            return data.get("success") is True and isinstance(data.get("data"), dict)
        except (ValueError, AttributeError):
            return False

    return classify_http(result, auth_required=True, valid_body=valid)


def probe_jina_reader(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    # Keyless Jina Reader scrape rung: fetch a known public page
    # through r.jina.ai and check the page text comes back.
    url = env.get("FETCH_HEALTH_JINA_URL", DEFAULT_URLS["jina-reader"])
    try:
        result = http(f"https://r.jina.ai/{url}", headers={"User-Agent": USER_AGENT})
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "Jina Reader request failed")

    def valid(body: bytes) -> bool:
        return b"Example Domain" in body

    return classify_http(result, auth_required=False, valid_body=valid)


SCRAPLING_TIMEOUT_SECONDS = 120  # the helper's 60 s page load plus browser start-up
IG_SCRAPLING_HELPER = Path("marketplace/plugins/obsidian-triage/tools/ig-scrapling-media.py")


def probe_instagram_scrapling(
    env: dict[str, str],
    command: Callable[..., subprocess.CompletedProcess[str]],
    repo_root: Path,
    *,
    child_env: dict[str, str] | None = None,
) -> ProbeResult:
    """HIMMEL-4675: the cookieless Scrapling path /ig-media-enrich tries first.
    Same venv lookup as ig-media-fetch.py; no cookie is sent."""
    override = (env.get("IG_SCRAPLING_PYTHON") or "").strip()
    py = Path(override) if override else resolve_home(env) / ".himmel" / "scrapling-venv" / "bin" / "python"
    if not py.is_file():
        return ProbeResult("transport-fail", f"scrapling python missing ({py}); create ~/.himmel/scrapling-venv "
                                             "from requirements-scrapling.txt")
    url = env.get("FETCH_HEALTH_INSTAGRAM_MEDIA_URL", DEFAULT_URLS["instagram"])
    parts = [p for p in urllib.parse.urlparse(url).path.split("/") if p]
    shortcode = parts[1] if len(parts) >= 2 and parts[0] in ("p", "reel", "reels", "tv") else ""
    if not shortcode:
        return ProbeResult("transport-fail", "instagram probe URL has no post shortcode")
    try:
        completed = command(
            [str(py), str(repo_root / IG_SCRAPLING_HELPER), "--url", url, "--shortcode", shortcode],
            env=child_env if child_env is not None else env,
            timeout=SCRAPLING_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ProbeResult("transport-fail", "scrapling helper invocation failed")
    try:
        out = json.loads(completed.stdout or "")
    except ValueError:
        out = {}
    status = out.get("status") if isinstance(out, dict) else None
    detail = str(out.get("detail", ""))[:80] if isinstance(out, dict) else ""
    if completed.returncode == 0 and status == "ok":
        return ProbeResult("ok", f"scrapling found {len(out.get('items') or [])} media item(s), no cookie")
    if status == "login_wall":
        return ProbeResult("blocked-or-rate-limited", "instagram served a login_wall to the cookieless fetch")
    if completed.returncode == 3:
        return ProbeResult("transport-fail", "scrapling not installed in the venv")
    return ProbeResult("transport-fail", f"scrapling helper rc={completed.returncode} status={status or 'unparsed'} {detail}".rstrip())


X_SCRAPLING_HELPER = Path("marketplace/plugins/obsidian-triage/tools/x-scrapling-media.py")
YT_SCRAPLING_HELPER = Path("marketplace/plugins/obsidian-triage/tools/yt-scrapling-meta.py")
# The YouTube helper runs yt-dlp after the page load (its own 180 s budget).
YT_SCRAPLING_TIMEOUT_SECONDS = SCRAPLING_TIMEOUT_SECONDS + 180
SCRAPLING_PYTHON_OVERRIDE = {"x": "X_SCRAPLING_PYTHON", "youtube": "YT_SCRAPLING_PYTHON"}


def scrapling_python(env: dict[str, str], source: str) -> Path:
    """The venv python x-media-fetch.py / playwright-crawl-youtube.mjs use."""
    override = (env.get(SCRAPLING_PYTHON_OVERRIDE[source]) or "").strip()
    return Path(override) if override else resolve_home(env) / ".himmel" / "scrapling-venv" / "bin" / "python"


def _scrapling_helper(
    py: Path, args: list[str], env: dict[str, str], command: Callable[..., subprocess.CompletedProcess[str]], timeout: int
) -> tuple[subprocess.CompletedProcess[str] | None, dict]:
    try:
        completed = command([str(py), *args], env=env, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None, {}
    try:
        out = json.loads(completed.stdout or "")
    except ValueError:
        out = {}
    return completed, out if isinstance(out, dict) else {}


def _scrapling_failure(completed: subprocess.CompletedProcess[str], out: dict, site: str) -> ProbeResult:
    status = out.get("status")
    if status == "login_wall":
        return ProbeResult("blocked-or-rate-limited", f"{site} served a login_wall to the cookieless fetch")
    if completed.returncode == 3:
        return ProbeResult("transport-fail", "scrapling not installed in the venv")
    detail = str(out.get("detail", ""))[:80]
    return ProbeResult("transport-fail", f"scrapling helper rc={completed.returncode} status={status or 'unparsed'} {detail}".rstrip())


def probe_x_scrapling(
    env: dict[str, str],
    command: Callable[..., subprocess.CompletedProcess[str]],
    repo_root: Path,
    *,
    child_env: dict[str, str] | None = None,
) -> ProbeResult:
    """HIMMEL-4677: the cookieless Scrapling path /x-media-enrich tries first."""
    py = scrapling_python(env, "x")
    if not py.is_file():
        return ProbeResult("transport-fail", f"scrapling python missing ({py}); create ~/.himmel/scrapling-venv "
                                             "from requirements-scrapling.txt")
    url = env.get("FETCH_HEALTH_X_MEDIA_URL", DEFAULT_URLS["x"])
    parts = [p for p in urllib.parse.urlparse(url).path.split("/") if p]
    status_id = parts[2] if len(parts) >= 3 and parts[1] == "status" and parts[2].isdigit() else ""
    if not status_id:
        return ProbeResult("transport-fail", "x probe URL has no status id")
    completed, out = _scrapling_helper(py, [str(repo_root / X_SCRAPLING_HELPER), "--url", url, "--status-id", status_id],
                                       child_env if child_env is not None else env, command, SCRAPLING_TIMEOUT_SECONDS)
    if completed is None:
        return ProbeResult("transport-fail", "scrapling helper invocation failed")
    if completed.returncode == 0 and out.get("status") == "ok":
        return ProbeResult("ok", f"scrapling found {len(out.get('items') or [])} media item(s), no cookie")
    return _scrapling_failure(completed, out, "x")


def probe_youtube_scrapling(
    env: dict[str, str],
    command: Callable[..., subprocess.CompletedProcess[str]],
    repo_root: Path,
    *,
    child_env: dict[str, str] | None = None,
) -> ProbeResult:
    """HIMMEL-4677: the cookieless YouTube path the crawler tries first:
    metadata from Scrapling, the transcript from yt-dlp subtitles."""
    py = scrapling_python(env, "youtube")
    if not py.is_file():
        return ProbeResult("transport-fail", f"scrapling python missing ({py}); create ~/.himmel/scrapling-venv "
                                             "from requirements-scrapling.txt")
    if not shutil.which("yt-dlp", path=env.get("PATH")):
        return ProbeResult("transport-fail", "yt-dlp missing from PATH (the transcript source)")
    url = env.get("FETCH_HEALTH_YOUTUBE_URL", DEFAULT_URLS["youtube"])
    video_id = (urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("v") or [""])[0]
    if not video_id:
        return ProbeResult("transport-fail", "youtube probe URL has no video id")
    completed, out = _scrapling_helper(py, [str(repo_root / YT_SCRAPLING_HELPER), "--video-id", video_id],
                                       child_env if child_env is not None else env, command, YT_SCRAPLING_TIMEOUT_SECONDS)
    if completed is None:
        return ProbeResult("transport-fail", "scrapling helper invocation failed")
    if completed.returncode == 0 and out.get("status") == "ok":
        lines = len(out.get("transcript") or [])
        if not lines:
            return ProbeResult("transport-fail", f"metadata ok, no transcript from yt-dlp ({out.get('transcript_error') or 'empty'})")
        return ProbeResult("ok", f"scrapling metadata ok, transcript via yt-dlp ({lines} lines), no cookie")
    return _scrapling_failure(completed, out, "youtube")


IG_PROBE_SOURCES = ("instagram-embed", "instagram-scrapling")
IG_OK_TTL_S = 24 * 3600
IG_BAD_TTL_S = 3600


def _ig_cache_path(env: dict[str, str]) -> Path:
    override = (env.get("HIMMEL_IG_PROBE_CACHE") or "").strip()
    if override:
        return Path(override)
    return resolve_home(env) / ".himmel" / "state" / "instagram-probe-cache.json"


def _ig_cache_read(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _ig_cooldown(reason: str) -> ProbeResult:
    return ProbeResult("cooldown", f"instagram cooldown ({reason}); probe skipped, no request sent")


def guarded_instagram_probe(
    source: str, env: dict[str, str], probe: Callable[[], ProbeResult], now: Callable[[], float] | None = None
) -> ProbeResult:
    """Throttle + cache an Instagram probe. Never sleeps: a probe
    that cannot send right now reports `cooldown` instead of waiting."""
    import time

    t = (now or time.time)()
    if ig_throttle is None:
        return _ig_cooldown("throttle module unavailable")
    st = ig_throttle.status(env, now=lambda: t)
    if st["state"] == "cooldown":
        until = datetime.fromtimestamp(st["until_epoch"], timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
        return _ig_cooldown(f"{st.get('reason', 'cooldown')} until {until}")

    cache_path = _ig_cache_path(env)
    cache = _ig_cache_read(cache_path)
    entry = cache.get(source)
    if isinstance(entry, dict) and isinstance(entry.get("checked_epoch"), (int, float)):
        age = t - entry["checked_epoch"]
        ttl = IG_BAD_TTL_S
        if entry.get("status") == "ok":
            try:
                ttl = float(env.get("HIMMEL_IG_PROBE_TTL_S", IG_OK_TTL_S))
            except ValueError:
                ttl = IG_OK_TTL_S
        if 0 <= age < ttl and entry.get("status") in STATUSES:
            return ProbeResult(entry["status"], f"{entry.get('reason', '')} (cached {int(age // 3600)}h ago)")

    decision = ig_throttle.acquire(env, now=lambda: t, wait=False)
    if not decision.ok:
        return _ig_cooldown(decision.reason)
    result = probe()
    if result.status == "ok":
        ig_throttle.record(env, ok=True)
    elif result.status == "blocked-or-rate-limited":
        ig_throttle.record(env, http_status=429)
    else:
        ig_throttle.record(env, ok=False)
    cache[source] = {"status": result.status, "reason": result.reason, "checked_epoch": t}
    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = cache_path.with_name(cache_path.name + f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(cache, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(tmp, cache_path)
    except OSError:
        pass
    return result


def build_probe_registry(
    env: dict[str, str],
    http: Callable[..., HttpResult],
    command: Callable[..., subprocess.CompletedProcess[str]],
    repo_root: Path,
) -> dict[str, Callable[[], ProbeResult]]:
    # Merge the primary checkout's .env HERE — the one boundary
    # where the process env and the resolved repo root meet — so every probe,
    # the FETCH_HEALTH_* URL overrides included, sees the
    # same effective config on both the `--probe` and the scheduled path. The
    # cron wrapper sources nothing, so without it only a probe that called
    # load_repo_env itself could read a key that lives only in .env.
    #
    # That merge is for CONFIG LOOKUP only. The checkout's
    # .env carries ~120 keys (router/wifi/sudo passwords, Jira/Confluence/Codex
    # tokens, Grafana/VM credentials, a dozen vendor API keys...) that a
    # third-party child process (gh) has no business seeing. `effective` is the merged
    # lookup dict every probe reads config from; `child_env` is the ORIGINAL,
    # pre-merge process env — the only thing a command probe's subprocess is
    # ever handed.
    effective = load_repo_env(env, repo_root)
    child_env = env
    registry = {
        "reddit": lambda: probe_reddit(effective, http),
        "x-fxtwitter": lambda: probe_fxtwitter(effective, http),
        "instagram-embed": lambda: probe_instagram_embed(effective, http),
        "instagram-scrapling": lambda: probe_instagram_scrapling(effective, command, repo_root, child_env=child_env),
        "x-scrapling": lambda: probe_x_scrapling(effective, command, repo_root, child_env=child_env),
        "youtube-scrapling": lambda: probe_youtube_scrapling(effective, command, repo_root, child_env=child_env),
        "github": lambda: probe_github(effective, command, child_env=child_env),
        "bitbucket": lambda: probe_bitbucket(effective, http),
        "firecrawl": lambda: probe_firecrawl(effective, http),
        "jina-reader": lambda: probe_jina_reader(effective, http),
    }
    for source in IG_PROBE_SOURCES:
        registry[source] = (lambda s, p: lambda: guarded_instagram_probe(s, effective, p))(source, registry[source])
    return registry


def run_probes(
    env: dict[str, str],
    *,
    http: Callable[..., HttpResult] = fetch_http,
    command: Callable[..., subprocess.CompletedProcess[str]] = run_command,
    repo_root: Path | None = None,
) -> dict[str, ProbeResult]:
    root = repo_root or primary_repo_root()
    probes = build_probe_registry(env, http, command, root)
    results: dict[str, ProbeResult] = {}
    for source, probe in probes.items():
        try:
            results[source] = probe()
        except Exception:
            results[source] = ProbeResult("transport-fail", "unexpected probe failure")
    return results


def run_single_probe(
    source: str,
    env: dict[str, str],
    *,
    http: Callable[..., HttpResult] = fetch_http,
    command: Callable[..., subprocess.CompletedProcess[str]] = run_command,
    repo_root: Path | None = None,
) -> ProbeResult:
    root = repo_root or primary_repo_root()
    probes = build_probe_registry(env, http, command, root)
    if source not in probes:
        valid = ", ".join(sorted(probes))
        raise ValueError(f"unknown probe source: {source!r} (valid sources: {valid})")
    try:
        return probes[source]()
    except Exception:
        return ProbeResult("transport-fail", "unexpected probe failure")


def read_previous(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_state(path: Path, results: dict[str, ProbeResult], now: datetime) -> None:
    previous = read_previous(path).get("sources", {})
    checked_at = now.isoformat().replace("+00:00", "Z")
    checked_epoch = int(now.timestamp())
    sources = {}
    for source, result in sorted(results.items()):
        old = previous.get(source, {}) if isinstance(previous, dict) else {}
        if not isinstance(old, dict):
            # A malformed per-source entry (e.g. a corrupt state file with a
            # string value) must not crash write_state — that would wedge every
            # future run on the same bad file (CR r1 codex-1).
            old = {}
        last_success = checked_epoch if result.status == "ok" else old.get("last_success_timestamp")
        row = {"status": result.status, "checked_at": checked_at, "reason": result.reason}
        if isinstance(last_success, int) and last_success >= 0:
            row["last_success_timestamp"] = last_success
        sources[source] = row
    payload = {"version": 1, "checked_at": checked_at, "sources": sources}
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", help="override output state path")
    parser.add_argument("--probe", metavar="SOURCE", help="run a single probe and print its JSON result (skips state writes)")
    args = parser.parse_args(argv)
    env = dict(os.environ)

    if args.probe:
        try:
            result = run_single_probe(args.probe, env)
        except ValueError as error:
            parser.error(str(error))
        print(json.dumps({"status": result.status, "reason": result.reason}))
        return 0 if result.status in ("ok", "cooldown") else 1

    path = Path(args.state) if args.state else state_path(env)
    results = run_probes(env)
    write_state(path, results, utc_now())
    for source, result in sorted(results.items()):
        print(f"{source}: {result.status} ({result.reason})")
    return 0 if all(result.status in ("ok", "cooldown") for result in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
