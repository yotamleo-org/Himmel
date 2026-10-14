#!/usr/bin/env python3
"""Build the YouTube Playwright storage-state file from a signed-in Chrome profile.

HIMMEL-2549: the documented route (`bun playwright-auth-save.mjs youtube`, an
interactive Playwright login) is now often blocked by Google as automated
sign-in. A cookie-exporter browser extension was tried too, but its export was
missing the HttpOnly login cookies (CR round 6 codex-1: that is an observation
about one extension, not a property of extensions in general — one granted the
`cookies` permission and reading via `chrome.cookies` rather than page
JavaScript CAN see HttpOnly cookies). The working route is to export the
signed-in Chrome profile's cookies with yt-dlp as a Netscape cookie jar, then
convert that jar to the Playwright storage-state JSON shape fetch-health.py's
`probe_youtube` reads (`state["cookies"]`: a list of dicts with at least
`domain`, `name`, `value`).
"""

from __future__ import annotations

import argparse
import http.cookiejar
from http.cookiejar import LoadError
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# yt-dlp's browser cookie export decrypts the OS keychain and can outrun a
# plain HTTP timeout; give it more room than fetch-health.py's probes need.
YTDLP_TIMEOUT_SECONDS = 60
YTDLP_PROBE_URL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
TARGET_DOMAINS = ("youtube.com", "www.youtube.com", "google.com")
# Measured live authenticated-only names (a signed-out
# profile carries NONE of these): SID, HSID, SSID, APISID, SAPISID, SIDCC,
# __Secure-1PSID, __Secure-3PSID, __Secure-1PSIDTS, __Secure-3PSIDTS,
# LOGIN_INFO. Require at least one before writing.
AUTH_MARKER_COOKIES = (
    "SID",
    "HSID",
    "SSID",
    "APISID",
    "SAPISID",
    "SIDCC",
    "__Secure-1PSID",
    "__Secure-3PSID",
    "__Secure-1PSIDTS",
    "__Secure-3PSIDTS",
    "LOGIN_INFO",
)
# yt-dlp's Chrome export
# writes the Netscape expiry column as Chrome's own WebKit/Chromium
# timestamp — microseconds since 1601-01-01 — NOT Unix seconds, even though
# the Netscape format nominally calls for Unix seconds. Observed on the real
WEBKIT_EPOCH_THRESHOLD = 1e12
WEBKIT_TO_UNIX_EPOCH_OFFSET = 11644473600


def _normalize_expires(raw_expires: int | float | None) -> float:
    if not raw_expires:
        return -1.0
    value = float(raw_expires)
    if value >= WEBKIT_EPOCH_THRESHOLD:
        return value / 1e6 - WEBKIT_TO_UNIX_EPOCH_OFFSET
    return value


def _current_unix_time() -> float:
    return time.time()


def resolve_home(env: dict[str, str]) -> Path:
    if os.name == "nt" and env.get("USERPROFILE"):
        return Path(env["USERPROFILE"])
    return Path(env.get("HOME") or env.get("USERPROFILE") or str(Path.home()))


def default_out_path(env: dict[str, str]) -> Path:
    return resolve_home(env) / ".luna" / "playwright-state" / "youtube.json"


def _cookie_to_state_entry(cookie: http.cookiejar.Cookie) -> dict:
    # MozillaCookieJar stores the `#HttpOnly_` line prefix as a nonstandard
    # attribute keyed "HTTPOnly" (verified empirically against CPython's
    # http.cookiejar: has_nonstandard_attr("HttpOnly") is always False —
    # the parser's own casing is "HTTPOnly", not "HttpOnly").
    http_only = cookie.has_nonstandard_attr("HTTPOnly")
    expires = _normalize_expires(cookie.expires)
    return {
        "name": cookie.name,
        "value": cookie.value,
        "domain": cookie.domain,
        "path": cookie.path,
        "expires": expires,
        "httpOnly": http_only,
        "secure": bool(cookie.secure),
    }


def _is_target_domain(domain: str) -> bool:
    return (domain or "").lstrip(".").lower() in TARGET_DOMAINS


def build_storage_state(cookie_file: Path) -> dict:
    # Both ignore_* flags are required: http.cookiejar would judge expiry in the wrong unit for WebKit timestamps and drop session (0-expiry) rows.
    jar = http.cookiejar.MozillaCookieJar(str(cookie_file))
    jar.load(ignore_discard=True, ignore_expires=True)
    cookies = [_cookie_to_state_entry(cookie) for cookie in jar if _is_target_domain(cookie.domain)]
    return {"cookies": cookies, "origins": []}


def write_storage_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(state, handle)
            handle.write("\n")
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def convert_and_write(cookie_file: Path, out_path: Path) -> int:
    try:
        state = build_storage_state(cookie_file)
    except (OSError, LoadError):
        print(f"youtube-state-from-chrome: could not read cookie file {cookie_file}", file=sys.stderr)
        return 1
    count = len(state["cookies"])
    if count == 0:
        print(
            "youtube-state-from-chrome: export carried no YouTube cookies "
            "(wrong or signed-out Chrome profile?)",
            file=sys.stderr,
        )
        return 1
    markers = [
        cookie for cookie in state["cookies"]
        if cookie["name"] in AUTH_MARKER_COOKIES and cookie["value"].strip()
    ]
    if not markers:
        print(
            "youtube-state-from-chrome: export carried cookies but no signed-in "
            "session marker (looked for one of "
            f"{', '.join(AUTH_MARKER_COOKIES)}) — the profile is signed out, "
            "or it is the wrong profile",
            file=sys.stderr,
        )
        return 1
    now = _current_unix_time()
    if not any(marker["expires"] == -1.0 or marker["expires"] > now for marker in markers):
        expired_names = ", ".join(sorted({marker["name"] for marker in markers}))
        print(
            f"youtube-state-from-chrome: the signed-in session marker ({expired_names}) "
            "has EXPIRED — re-authenticate in Chrome and re-export",
            file=sys.stderr,
        )
        return 1
    write_storage_state(out_path, state)
    print(f"wrote {count} cookies to {out_path}")
    return 0


def export_cookies_with_ytdlp(profile: str, tmp_dir: Path, env: dict[str, str]) -> Path | None:
    binary = shutil.which("yt-dlp", path=env.get("PATH"))
    if not binary:
        print("youtube-state-from-chrome: yt-dlp not found on PATH", file=sys.stderr)
        return None
    cookie_file = tmp_dir / "cookies.txt"
    try:
        completed = subprocess.run(
            [
                binary,
                "--cookies-from-browser",
                f"chrome:{profile}",
                "--cookies",
                str(cookie_file),
                "--skip-download",
                YTDLP_PROBE_URL,
            ],
            capture_output=True,
            text=True,
            timeout=YTDLP_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"youtube-state-from-chrome: yt-dlp invocation failed: {error}", file=sys.stderr)
        return None
    # HIMMEL-2549, measured live: yt-dlp exits non-zero for reasons that have
    # nothing to do with the cookie export (signature/n-challenge solving,
    # "The page needs to be reloaded" trying to actually play the probe URL)
    # while still writing the complete, correct Netscape jar (316 lines, 22
    # .youtube.com + 18 .google.com cookies observed). The jar is the
    # deliverable, not the video extraction — so a non-zero exit is only a
    # real failure when the jar itself never landed (missing or empty).
# yt-dlp's
    # own YoutubeDLCookieJar.save() writes the file DIRECTLY (`with
    # self.open(filename, write=True) as f: ...`) — no temp-file-and-rename —
    # so a kill or a full disk mid-write genuinely leaves a partial file on
    # disk with a nonzero size. `_really_save` writes one complete
    # newline-terminated line per cookie (verified against the real jar: its
    # last byte is 0x0a), so a mid-line kill is detectable by requiring the
    jar_landed = cookie_file.is_file() and cookie_file.stat().st_size > 0
    if not jar_landed:
        print(f"youtube-state-from-chrome: yt-dlp cookie export failed: {completed.stderr.strip()}", file=sys.stderr)
        return None
    if cookie_file.read_bytes()[-1:] != b"\n":
        print(
            "youtube-state-from-chrome: yt-dlp cookie export looks TRUNCATED "
            "(yt-dlp died mid-write; the jar does not end with a complete line)",
            file=sys.stderr,
        )
        return None
    if completed.returncode != 0:
        first_stderr_line = next((line.strip() for line in completed.stderr.splitlines() if line.strip()), "")
        print(
            "youtube-state-from-chrome: cookie export succeeded despite a "
            f"yt-dlp extraction warning: {first_stderr_line}",
            file=sys.stderr,
        )
    return cookie_file


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="Default", help="Chrome profile name for yt-dlp --cookies-from-browser (default: Default)")
    parser.add_argument("--from-cookies", metavar="PATH", help="convert an existing Netscape cookie file instead of exporting from Chrome")
    parser.add_argument("--out", help="override the output Playwright storage-state path")
    args = parser.parse_args(argv)
    env = dict(os.environ)
    out_path = Path(args.out) if args.out else default_out_path(env)

    if args.from_cookies:
        return convert_and_write(Path(args.from_cookies), out_path)

    with tempfile.TemporaryDirectory() as tmp:
        cookie_file = export_cookies_with_ytdlp(args.profile, Path(tmp), env)
        if cookie_file is None:
            return 1
        return convert_and_write(cookie_file, out_path)


if __name__ == "__main__":
    sys.exit(main())
