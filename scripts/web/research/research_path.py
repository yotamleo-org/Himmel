#!/usr/bin/env python3
"""research_path.py - deterministic pieces of the himmel research path (HIMMEL-5863/5864/5865/5862).

Stdlib-only apart from a lazy Scrapling import in fetch_reddit_html: callers
inject the search rungs as callables and hand in raw HTML / JSON. Entry point:
research(). PS3 (HIMMEL-5751) decides how it is wired. Only the two Reddit
fetchers touch the network, each pinned to one of REDDIT_ENDPOINT_HOSTS.

- Relevance floor: the topic's primary entity must appear in title or snippet.
- Search ladder: rungs tried in order, the header names the one that answered.
- Dated-in-window: unknown date is "unknown", never "in-window".
- Reddit lane: keyless site-search discovery (www.reddit.com via Scrapling),
  shreddit thread enrichment (score, comment count, top comments) and an
  Arctic Shift score backfill. reddit_rung() binds the operator's own query
  and refuses any other, so no vault or corpus text can reach the two hosts.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from urllib.parse import quote, urlparse

LADDER_ORDER = ("ddg-html", "ddg-lite", "startpage", "searxng", "bing")
REDDIT_ENDPOINT_HOSTS = ("arctic-shift.photon-reddit.com", "www.reddit.com")
REDDIT_ENRICH_LIMIT = 3
_THREAD_PATH = re.compile(r"^/r/([A-Za-z0-9_]+)/comments/([a-z0-9]+)/")


def _norm(text):
    return " ".join(re.sub(r"[\W_]+", " ", (text or "").lower()).split())


def passes_floor(entity, title, snippet):
    e = _norm(entity)
    if not e:
        return False
    return any(f" {e} " in f" {_norm(t)} " for t in (title, snippet))


def apply_floor(entity, items):
    kept, dropped = [], []
    for it in items:
        (kept if passes_floor(entity, it.get("title"), it.get("snippet")) else dropped).append(it)
    return kept, dropped


@dataclass
class LadderResult:
    rung: str | None
    results: list
    attempts: list = field(default_factory=list)

    def header(self):
        tried = ", ".join(f"{n}={s}" for n, s in self.attempts)
        return f"search ladder: {tried}; answered by: {self.rung or 'NONE'}"


def run_ladder(query, rungs):
    attempts = []
    for name, fn in rungs:
        try:
            results = list(fn(query))
        except Exception as exc:  # a failing rung must never abort the ladder
            attempts.append((name, f"error: {exc}"))
            continue
        if not results:
            attempts.append((name, "empty"))
            continue
        attempts.append((name, "ok"))
        return LadderResult(name, results, attempts)
    return LadderResult(None, [], attempts)


def _parse_iso(value):
    if not isinstance(value, str):
        return None
    try:
        d = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


_META_NAMES = {"article:published_time", "og:published_time", "og:article:published_time"}


class _DateScan(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.meta, self.time_tags, self.ld = [], [], []
        self._in_ld = False

    def handle_starttag(self, tag, attrs):
        a = {k: (v or "") for k, v in attrs}
        if tag == "meta" and (a.get("property") or a.get("name") or "").lower() in _META_NAMES:
            self.meta.append(a.get("content", ""))
        elif tag == "time" and a.get("datetime"):
            self.time_tags.append(a["datetime"])
        elif tag == "script" and a.get("type", "").lower() == "application/ld+json":
            self._in_ld = True
            self.ld.append("")

    def handle_endtag(self, tag):
        if tag == "script":
            self._in_ld = False

    def handle_data(self, data):
        if self._in_ld:
            self.ld[-1] += data


def _own_dates_published(node):
    """datePublished of the top-level node(s) and @graph entries only: a nested
    comment, related article or event carries somebody else's date."""
    if isinstance(node, list):
        for v in node:
            yield from _own_dates_published(v)
    elif isinstance(node, dict):
        if "datePublished" in node:
            yield node["datePublished"]
        if isinstance(node.get("@graph"), list):
            yield from _own_dates_published(node["@graph"])


def extract_date(html):
    """Page date from meta published_time, JSON-LD datePublished, then <time>; None if absent."""
    scan = _DateScan()
    scan.feed(html or "")
    for c in scan.meta:
        d = _parse_iso(c)
        if d:
            return d
    ld = []
    for blob in scan.ld:
        try:
            ld.extend(_own_dates_published(json.loads(blob)))
        except ValueError:
            continue
    # JSON-LD and <time> can carry a comment's or a related item's date: trust
    # a source only when every date it holds agrees, otherwise try the next
    for source in (ld, scan.time_tags):
        by_day = {d.astimezone(timezone.utc).date(): d for d in map(_parse_iso, source) if d}
        if len(by_day) == 1:
            return next(iter(by_day.values()))
    return None


def classify(date, now, days):
    if date is None:
        return "unknown"
    if date.tzinfo is None:
        date = date.replace(tzinfo=timezone.utc)
    # day granularity in UTC: page dates often carry no time of day
    now = now.astimezone(timezone.utc) if now.tzinfo else now.replace(tzinfo=timezone.utc)
    return "in-window" if (now - timedelta(days=days)).date() <= date.astimezone(timezone.utc).date() <= now.date() else "out-of-window"


def dated_report(items):
    total = len(items)
    unknown = sum(1 for i in items if i["status"] == "unknown")
    in_window = sum(1 for i in items if i["status"] == "in-window")
    return {
        "total": total,
        "in_window": in_window,
        "out_of_window": total - unknown - in_window,
        "unknown": unknown,
        "dated_share": (total - unknown) / total if total else 0.0,
    }


def format_dated_report(rep):
    return (f"dated {rep['total'] - rep['unknown']}/{rep['total']} ({rep['dated_share']:.0%}): "
            f"{rep['in_window']} in window, {rep['out_of_window']} out of window, {rep['unknown']} unknown")


def parse_reddit_posts(raw):
    """Normalize an Arctic Shift /api/posts/search body; [] for anything malformed."""
    try:
        data = json.loads(raw).get("data")
    except (ValueError, AttributeError, TypeError):
        return []
    if not isinstance(data, list):
        return []
    items = []
    for p in data:
        if not isinstance(p, dict):
            continue
        title, permalink, selftext = p.get("title"), p.get("permalink"), p.get("selftext")
        if not isinstance(title, str) or not title or not isinstance(permalink, str) or not permalink:
            continue
        items.append({
            "source": "reddit",
            "title": title,
            "snippet": selftext[:300] if isinstance(selftext, str) else "",
            "url": "https://www.reddit.com" + permalink,
            "subreddit": p.get("subreddit"),
            "score": _to_int(p.get("score")),
            "num_comments": _to_int(p.get("num_comments")),
            "date": _to_utc(p.get("created_utc")),
        })
    return items


def _to_int(value):
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return 0


def _to_utc(ts):
    try:
        secs = int(float(ts))
        return datetime.fromtimestamp(secs, timezone.utc) if secs > 0 else None
    except (TypeError, ValueError, OverflowError, OSError):
        return None


class _SearchScan(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "a" and a.get("data-testid") == "post-title" and a.get("href") and a.get("aria-label"):
            self.found.append((a["href"], a["aria-label"]))


def parse_reddit_search_html(page_html):
    """Thread hits from a www.reddit.com/search page; [] for anything unparsable."""
    scan = _SearchScan()
    try:
        scan.feed(page_html)
    except (TypeError, AssertionError):
        return []
    items, seen = [], set()
    for href, title in scan.found:
        m = _THREAD_PATH.match(href)
        if not m or href in seen or not title.strip():
            continue
        seen.add(href)
        items.append({"source": "reddit", "title": title.strip(), "snippet": "",
                      "url": "https://www.reddit.com" + href, "subreddit": m.group(1),
                      "score": None, "num_comments": None, "date": None, "id": m.group(2)})
    return items


class _ThreadScan(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.post = None
        self.comments = []
        self._tag = None
        self._depth = 0
        self._buf = []

    def flush(self):
        text = " ".join("".join(self._buf).split())
        if text:
            self.comments.append(text)
        self._tag, self._depth, self._buf = None, 0, []

    def handle_starttag(self, tag, attrs):
        a = {k: (v or "") for k, v in attrs}
        if tag == "shreddit-post" and self.post is None:
            self.post = a
        elif tag == "shreddit-comment":
            self.flush()
        elif self._tag is None and a.get("slot") == "comment":
            self._tag, self._depth = tag, 1
        elif self._tag == tag:
            self._depth += 1

    def handle_endtag(self, tag):
        if self._tag == tag:
            self._depth -= 1
            if self._depth == 0:
                self.flush()

    def handle_data(self, data):
        if self._tag:
            self._buf.append(data)


def parse_reddit_thread_html(page_html, max_comments=3):
    """{score, num_comments, date, comments} from a shreddit thread page; None if no post."""
    scan = _ThreadScan()
    try:
        scan.feed(page_html)
        scan.close()
    except (TypeError, AssertionError):
        return None
    scan.flush()
    if not scan.post:
        return None
    return {
        "score": _to_int(scan.post.get("score")),
        "num_comments": _to_int(scan.post.get("comment-count")),
        "date": _parse_iso(scan.post.get("created-timestamp")),
        "comments": [c[:300] for c in scan.comments[:max_comments]],
    }


def _backfill(items, arctic_raw):
    """Fill score / num_comments / date / snippet that discovery left empty from an Arctic ids body."""
    by_url = {i["url"]: i for i in parse_reddit_posts(arctic_raw)}
    for it in items:
        known = by_url.get(it["url"])
        if not known:
            continue
        for k in ("score", "num_comments", "date", "snippet"):
            if it.get(k) in (None, ""):
                it[k] = known[k]
    return items


def reddit_rung(operator_query, fetch_html, fetch_json, enrich_limit=REDDIT_ENRICH_LIMIT):
    """Search-ladder rung for Reddit, bound to the operator's own query.

    The returned rung refuses any other query: the lane sends only what the
    operator typed to the two Reddit hosts, never text taken from a note.
    fetch_html / fetch_json take a URL; failures degrade, never abort the rung.
    """
    if not isinstance(operator_query, str) or not operator_query.strip():
        raise ValueError("reddit_rung needs the operator's own non-empty query")

    def rung(query):
        if query != operator_query:
            raise ValueError("reddit rung refuses a query the operator did not type")
        items = parse_reddit_search_html(fetch_html(
            "https://www.reddit.com/search/?q=" + quote(operator_query) + "&sort=top&t=month"))
        if not items:
            return []
        try:
            _backfill(items, fetch_json(
                "https://arctic-shift.photon-reddit.com/api/posts/ids?ids=" + ",".join(i["id"] for i in items)))
        except Exception:  # backfill is best effort
            pass
        for it in items[:enrich_limit]:
            try:
                info = parse_reddit_thread_html(fetch_html(it["url"]))
            except Exception:  # one dead thread must not drop the rest
                continue
            if info:
                it.update({k: info[k] for k in ("score", "num_comments", "date") if info[k] not in (None, "")})
                it["comments"] = info["comments"]
        for it in items:
            for k in ("score", "num_comments"):
                if it[k] is None:
                    it[k] = 0
        return items

    return rung


def _pinned(url, host):
    u = urlparse(url)
    if u.scheme != "https" or u.hostname != host:
        raise ValueError("refusing a url outside https://" + host + ": " + str(u.hostname))


def fetch_reddit_html(url, timeout_ms=60000):
    """Keyless Scrapling fetch of www.reddit.com; ImportError when scrapling is missing."""
    _pinned(url, "www.reddit.com")
    from scrapling.fetchers import StealthyFetcher
    page = StealthyFetcher.fetch(url, headless=True, network_idle=True, timeout=timeout_ms)
    if getattr(page, "status", 200) >= 400:
        raise OSError(f"HTTP {page.status}")
    return getattr(page, "html_content", None) or ""


def fetch_arctic_json(url, timeout_s=60):
    """Keyless GET of the Arctic Shift API."""
    _pinned(url, "arctic-shift.photon-reddit.com")
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (himmel research)"})
    with urllib.request.urlopen(req, timeout=timeout_s) as r:
        return r.read(8_000_000).decode("utf-8", "replace")


def research(query, entity, rungs, now, days=30):
    """Search via the ladder, apply the relevance floor, then the date window.

    Returns {"header", "items", "dropped_by_floor", "dated"}. Each rung item is a
    dict with title/snippet/url and optionally "date" (datetime) or "html".
    """
    ladder = run_ladder(query, rungs)
    kept, dropped = apply_floor(entity, ladder.results)
    items = []
    for it in kept:
        date = it.get("date") or extract_date(it.get("html"))
        items.append({**it, "date": date, "status": classify(date, now, days)})
    rep = dated_report(items)
    return {
        "header": ladder.header() + "\n" + format_dated_report(rep),
        "items": items,
        "dropped_by_floor": len(dropped),
        "dated": rep,
    }
