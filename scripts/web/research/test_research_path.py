#!/usr/bin/env python3
"""Offline table-driven tests for research_path.py (no network)."""

from __future__ import annotations

import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import research_path as rp  # noqa: E402

NOW = datetime(2026, 10, 16, 12, 0, tzinfo=timezone.utc)


class RelevanceFloor(unittest.TestCase):
    def test_table(self):
        rows = [
            ("Claude Code", "Claude Code hooks guide", "", True),
            ("Claude Code", "Unrelated title", "uses claude code daily", True),
            ("Claude Code", "Show HN: a code editor", "no entity here", False),
            ("Claude Code", "Claude-Code tips", "", True),
            ("Claude Code", "Exclaude Codex", "", False),
            ("MCP", "Using MCP servers", "", True),
            ("MCP", "MCPs everywhere", "", False),
            ("Claude Code", None, None, False),
            ("", "anything", "anything", False),
        ]
        for entity, title, snippet, want in rows:
            with self.subTest(entity=entity, title=title, snippet=snippet):
                self.assertEqual(rp.passes_floor(entity, title, snippet), want)

    def test_non_latin_and_accented_entities(self):
        rows = [
            ("日本語", "日本語 の hooks", "", True),
            ("日本語", "other", "中文", False),
            ("café", "Best café guide", "", True),
            ("café", "Best cafe guide", "", False),
        ]
        for entity, title, snippet, want in rows:
            with self.subTest(entity=entity, title=title):
                self.assertEqual(rp.passes_floor(entity, title, snippet), want)

    def test_apply_floor_splits(self):
        items = [{"title": "Claude Code x", "snippet": ""}, {"title": "other", "snippet": "n/a"}]
        kept, dropped = rp.apply_floor("Claude Code", items)
        self.assertEqual([i["title"] for i in kept], ["Claude Code x"])
        self.assertEqual(len(dropped), 1)


class Ladder(unittest.TestCase):
    def test_first_rung_answers(self):
        r = rp.run_ladder("q", [("ddg-html", lambda q: [{"url": "u"}]), ("bing", lambda q: [{"url": "v"}])])
        self.assertEqual(r.rung, "ddg-html")
        self.assertEqual(r.attempts, [("ddg-html", "ok")])
        self.assertIn("answered by: ddg-html", r.header())

    def test_falls_through_visibly(self):
        def boom(q):
            raise RuntimeError("HTTP 202")

        r = rp.run_ladder("q", [("ddg-html", boom), ("ddg-lite", lambda q: []), ("bing", lambda q: [{"url": "v"}])])
        self.assertEqual(r.rung, "bing")
        self.assertEqual(r.attempts, [("ddg-html", "error: HTTP 202"), ("ddg-lite", "empty"), ("bing", "ok")])
        h = r.header()
        for s in ("ddg-html=error: HTTP 202", "ddg-lite=empty", "bing=ok", "answered by: bing"):
            self.assertIn(s, h)

    def test_generator_rungs_are_materialized_inside_the_try(self):
        def empty_gen(q):
            return
            yield  # pragma: no cover

        def dying_gen(q):
            yield {"url": "u"}
            raise RuntimeError("mid-iteration")

        r = rp.run_ladder("q", [("a", empty_gen), ("b", dying_gen), ("c", lambda q: [{"url": "v"}])])
        self.assertEqual(r.rung, "c")
        self.assertEqual(r.attempts, [("a", "empty"), ("b", "error: mid-iteration"), ("c", "ok")])

    def test_none_answered_is_loud(self):
        r = rp.run_ladder("q", [("a", lambda q: [])])
        self.assertIsNone(r.rung)
        self.assertEqual(r.results, [])
        self.assertIn("answered by: NONE", r.header())

    def test_default_order(self):
        self.assertEqual(rp.LADDER_ORDER, ("ddg-html", "ddg-lite", "startpage", "searxng", "bing"))


class Dating(unittest.TestCase):
    def test_extract_table(self):
        rows = [
            ('<meta property="article:published_time" content="2026-10-10T08:00:00Z">', "2026-10-10"),
            ('<meta content="2026-10-09T08:00:00+02:00" property="article:published_time">', "2026-10-09"),
            ('<script type="application/ld+json">{"@type":"Article","datePublished":"2026-10-01"}</script>', "2026-10-01"),
            ('<script type="application/ld+json">{"@graph":[{"datePublished":"2026-09-30T10:00:00Z"}]}</script>', "2026-09-30"),
            ('<time datetime="2026-10-05">Oct 5</time>', "2026-10-05"),
            ("<p>no date at all</p>", None),
            ('<meta property="article:published_time" content="not a date">', None),
            ('<script type="application/ld+json">{broken</script>', None),
        ]
        for html, want in rows:
            with self.subTest(html=html[:50]):
                got = rp.extract_date(html)
                self.assertEqual(got.date().isoformat() if got else None, want)

    def test_classify(self):
        def d(s):
            return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)

        self.assertEqual(rp.classify(d("2026-10-10"), NOW, 30), "in-window")
        self.assertEqual(rp.classify(d("2026-09-16"), NOW, 30), "in-window")
        self.assertEqual(rp.classify(d("2026-09-15"), NOW, 30), "out-of-window")
        self.assertEqual(rp.classify(d("2026-10-20"), NOW, 30), "out-of-window")
        self.assertEqual(rp.classify(None, NOW, 30), "unknown")

    def test_naive_date_treated_as_utc(self):
        self.assertEqual(rp.classify(datetime(2026, 10, 10), NOW, 30), "in-window")

    def test_report_never_counts_unknown_as_in_window(self):
        items = [
            {"status": "in-window"},
            {"status": "out-of-window"},
            {"status": "unknown"},
            {"status": "unknown"},
        ]
        rep = rp.dated_report(items)
        self.assertEqual(rep["total"], 4)
        self.assertEqual(rep["in_window"], 1)
        self.assertEqual(rep["unknown"], 2)
        self.assertAlmostEqual(rep["dated_share"], 0.5)
        self.assertIn("2 unknown", rp.format_dated_report(rep))

    def test_report_empty(self):
        rep = rp.dated_report([])
        self.assertEqual(rep["dated_share"], 0.0)


class RedditLane(unittest.TestCase):
    def setUp(self):
        self.raw = (HERE / "fixtures" / "arctic-shift-posts.json").read_text(encoding="utf-8")

    def test_fixture_parses(self):
        items = rp.parse_reddit_posts(self.raw)
        self.assertEqual(len(items), 3)
        first = items[0]
        self.assertEqual(first["source"], "reddit")
        self.assertTrue(first["url"].startswith("https://www.reddit.com/r/ClaudeAI/comments/"))
        self.assertTrue(first["title"])
        self.assertIsInstance(first["score"], int)
        self.assertIsInstance(first["num_comments"], int)
        self.assertEqual(first["date"].tzinfo, timezone.utc)
        self.assertEqual(first["date"].year, 2026)

    def test_malformed_inputs(self):
        for raw in ("", "not json", "[]", '{"data": null, "error": "Timeout"}', '{"data": [{"id": "x"}]}'):
            with self.subTest(raw=raw):
                self.assertEqual(rp.parse_reddit_posts(raw), [])

    def test_bad_field_values_degrade_per_post(self):
        base = {"id": "a", "title": "T", "permalink": "/r/x/comments/a/t"}
        rows = [
            ({"score": "abc"}, {"score": 0}),
            ({"num_comments": [1]}, {"num_comments": 0}),
            ({"created_utc": 10**30}, {"date": None}),
            ({"created_utc": "-5"}, {"date": None}),
            ({"created_utc": 1792154260.5}, {"date": datetime.fromtimestamp(1792154260, timezone.utc)}),
        ]
        for extra, want in rows:
            with self.subTest(extra=extra):
                items = rp.parse_reddit_posts(json.dumps({"data": [{**base, **extra}, {**base, "id": "b"}]}))
                self.assertEqual(len(items), 2)
                for k, v in want.items():
                    self.assertEqual(items[0][k], v)

    def test_missing_date_stays_unknown(self):
        raw = json.dumps({"data": [{"id": "a", "title": "T", "permalink": "/r/x/comments/a/t"}]})
        items = rp.parse_reddit_posts(raw)
        self.assertIsNone(items[0]["date"])
        self.assertEqual(rp.classify(items[0]["date"], NOW, 30), "unknown")

    def test_hosts_listed_for_egress_review(self):
        self.assertEqual(rp.REDDIT_ENDPOINT_HOSTS, ("arctic-shift.photon-reddit.com", "www.reddit.com"))


class Entry(unittest.TestCase):
    def test_research_end_to_end(self):
        def rung(q):
            return [
                {"url": "https://a", "title": "Claude Code hooks", "snippet": "", "html": '<time datetime="2026-10-10">x</time>'},
                {"url": "https://b", "title": "Off topic", "snippet": "nothing", "html": ""},
                {"url": "https://c", "title": "Claude Code old", "snippet": "", "html": '<time datetime="2025-01-01">x</time>'},
                {"url": "https://d", "title": "Claude Code undated", "snippet": "", "html": ""},
            ]

        out = rp.research("Claude Code hooks", "Claude Code", [("bing", rung)], NOW, 30)
        self.assertEqual([i["url"] for i in out["items"]], ["https://a", "https://c", "https://d"])
        self.assertEqual([i["status"] for i in out["items"]], ["in-window", "out-of-window", "unknown"])
        self.assertEqual(out["dropped_by_floor"], 1)
        self.assertIn("answered by: bing", out["header"])
        self.assertEqual(out["dated"]["unknown"], 1)


if __name__ == "__main__":
    unittest.main()
