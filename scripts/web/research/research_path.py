#!/usr/bin/env python3
"""research_path.py - deterministic pieces of the himmel research path (HIMMEL-5863/5864/5865/5862).

Pure, stdlib-only, no network: callers inject the search rungs as callables
and hand in raw HTML / JSON. Entry point: research(). PS3 (HIMMEL-5751)
decides how it is wired; nothing here fetches anything.

- Relevance floor: the topic's primary entity must appear in title or snippet.
- Search ladder: rungs tried in order, the header names the one that answered.
- Dated-in-window: unknown date is "unknown", never "in-window".
- Reddit lane: parser/normalizer for an Arctic Shift style JSON response.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser

LADDER_ORDER = ("ddg-html", "ddg-lite", "startpage", "searxng", "bing")
REDDIT_ENDPOINT_HOSTS = ("arctic-shift.photon-reddit.com", "www.reddit.com")


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
