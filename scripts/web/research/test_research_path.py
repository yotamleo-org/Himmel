#!/usr/bin/env python3
"""Offline table-driven tests for research_path.py (no network)."""

from __future__ import annotations

import json
import sys
import unittest
import urllib.request
from unittest import mock
from datetime import datetime, timedelta, timezone
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

    def test_only_the_pages_own_date_counts(self):
        ld = '<script type="application/ld+json">%s</script>'
        rows = [
            # a nested comment's or related item's date is not the page date
            (ld % '{"@type":"Article","comment":[{"datePublished":"2026-10-12"}]}', None),
            (ld % '{"@type":"Article","datePublished":"2026-10-01","comment":[{"datePublished":"2026-10-12"}]}', "2026-10-01"),
            (ld % '[{"@type":"Person"},{"@type":"Article","datePublished":"2026-10-02"}]', "2026-10-02"),
            # two graph entries with different dates: which one is the page is unknown
            (ld % '{"@graph":[{"@type":"Comment","datePublished":"2026-10-12"},{"@type":"Article","datePublished":"2026-10-01"}]}', None),
            (ld % '{"@graph":[{"@type":"Article","datePublished":"2026-10-01"},{"@type":"WebPage","datePublished":"2026-10-01T09:00:00Z"}]}', "2026-10-01"),
            # several different <time> tags are ambiguous: unknown, not the first one
            ('<time datetime="2026-10-12">a</time><time datetime="2026-10-14">b</time>', None),
            ('<time datetime="2026-10-12">a</time><time datetime="2026-10-12">b</time>', "2026-10-12"),
        ]
        for html, want in rows:
            with self.subTest(html=html[:60]):
                got = rp.extract_date(html)
                self.assertEqual(got.date().isoformat() if got else None, want)

    def test_classify_uses_utc_for_now(self):
        plus2 = timezone(timedelta(hours=2))
        now = datetime(2026, 10, 17, 1, 0, tzinfo=plus2)  # 2026-10-16 23:00 UTC
        edge = datetime(2026, 9, 16, tzinfo=timezone.utc)
        self.assertEqual(rp.classify(edge, now, 30), "in-window")

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
        for raw in (None, 5, b"\xff", "", "not json", "[]", '{"data": null, "error": "Timeout"}', '{"data": [{"id": "x"}]}'):
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


class RedditFetchLane(unittest.TestCase):
    """Fixtures are verbatim excerpts of live keyless responses (fixtures/README.md)."""

    def setUp(self):
        self.search = (HERE / "fixtures" / "reddit-search.html").read_text(encoding="utf-8")
        self.thread = (HERE / "fixtures" / "reddit-thread.html").read_text(encoding="utf-8")
        self.ids = (HERE / "fixtures" / "arctic-shift-ids.json").read_text(encoding="utf-8")
        self.calls = []

    def fetch_html(self, url):
        self.calls.append(url)
        if "/search/" in url:
            return self.search
        if "/comments/1wn7qdj/" in url:
            return self.thread
        raise OSError("no fixture for " + url)

    def fetch_json(self, url):
        self.calls.append(url)
        return self.ids

    def test_search_page_parses(self):
        items = rp.parse_reddit_search_html(self.search)
        self.assertEqual(len(items), 3)
        self.assertEqual(items[0]["source"], "reddit")
        self.assertEqual(items[0]["subreddit"], "technology")
        self.assertTrue(items[0]["url"].startswith("https://www.reddit.com/r/technology/comments/1wn7qdj/"))
        self.assertIn("Claude Code", items[0]["title"])
        self.assertEqual(rp.parse_reddit_search_html("<html>"), [])
        self.assertEqual(rp.parse_reddit_search_html(None), [])

    def test_comment_text_keeps_block_boundaries(self):
        page = ('<shreddit-post score="1" comment-count="1"></shreddit-post>'
                '<shreddit-comment><div slot="comment"><p>first</p><p>second<br>third</p></div></shreddit-comment>')
        self.assertEqual(rp.parse_reddit_thread_html(page)["comments"], ["first second third"])

    def test_thread_page_parses(self):
        info = rp.parse_reddit_thread_html(self.thread)
        self.assertEqual(info["score"], 17634)
        self.assertEqual(info["num_comments"], 1363)
        self.assertEqual(info["date"].year, 2026)
        self.assertEqual(len(info["comments"]), 3)
        self.assertIn("automatic", info["comments"][0])
        self.assertIsNone(rp.parse_reddit_thread_html("<html>"))

    def test_rung_end_to_end_has_score_and_comments(self):
        rung = rp.reddit_rung("claude code hooks", self.fetch_html, self.fetch_json)
        out = rp.research("claude code hooks", "claude code", [("reddit", rung)], NOW, 60)
        self.assertIn("answered by: reddit", out["header"])
        self.assertTrue(out["items"])
        top = out["items"][0]
        self.assertEqual((top["score"], top["num_comments"]), (17634, 1363))
        self.assertTrue(top["comments"])
        raw = rung("claude code hooks")
        self.assertEqual([i["score"] for i in raw], [17634, 1, 15166])
        self.assertEqual(raw[2]["num_comments"], 152)
        self.assertEqual(out["dropped_by_floor"], 2)

    def test_failed_enrichment_degrades_to_backfill(self):
        def only_search(url):
            if "/search/" not in url:
                raise OSError("down")
            return self.search
        items = rp.reddit_rung("claude code hooks", only_search, self.fetch_json)("claude code hooks")
        self.assertTrue(items)
        self.assertTrue(all(i["score"] is not None for i in items))

    def test_only_the_operator_query_is_sent(self):
        rung = rp.reddit_rung("claude code hooks", self.fetch_html, self.fetch_json)
        with self.assertRaises(ValueError):
            rung("text taken from a vault note")
        with self.assertRaises(ValueError):
            rp.reddit_rung("  ", self.fetch_html, self.fetch_json)
        self.assertEqual(self.calls, [])

    def test_failed_discovery_fetch_is_a_recorded_rung_error(self):
        def down(url):
            raise OSError("timeout")
        rung = rp.reddit_rung("claude code hooks", down, self.fetch_json)
        out = rp.research("claude code hooks", "claude code", [("reddit", rung)], NOW, 60)
        self.assertIn("reddit=error: timeout", out["header"])
        self.assertIn("answered by: NONE", out["header"])

    def test_arctic_fetch_refuses_an_off_host_redirect(self):
        import urllib.request
        handler = rp._same_host_redirect("arctic-shift.photon-reddit.com")
        req = urllib.request.Request("https://arctic-shift.photon-reddit.com/api/posts/ids?ids=a")
        for target in ("https://example.com/x", "http://arctic-shift.photon-reddit.com/x"):
            with self.subTest(target=target):
                with self.assertRaises(ValueError):
                    handler.redirect_request(req, None, 302, "Found", {}, target)
        ok = handler.redirect_request(req, None, 302, "Found", {}, "https://arctic-shift.photon-reddit.com/y")
        self.assertEqual(ok.full_url, "https://arctic-shift.photon-reddit.com/y")

    def test_browser_resolves_only_reddit_owned_hosts(self):
        flag = rp.reddit_resolver_rules()
        self.assertTrue(flag.startswith("--host-resolver-rules=MAP * ~NOTFOUND, "))
        for d in ("reddit.com", "redd.it", "redditstatic.com", "redditmedia.com"):
            self.assertIn(f"EXCLUDE {d}", flag)
            self.assertIn(f"EXCLUDE *.{d}", flag)
        self.assertEqual(flag.count("EXCLUDE"), 8)

    def _fake_scrapling(self, page_url, status=200):
        """Fake scrapling modules whose StealthyFetcher records its fetch kwargs."""
        calls = []

        class Page:
            url = page_url
            html_content = "<html></html>"

        Page.status = status

        class Fetcher:
            @staticmethod
            def fetch(url, **kw):
                calls.append((url, kw))
                return Page()

        mods = {}
        for name in ("scrapling", "scrapling.fetchers", "scrapling.engines", "scrapling.engines.constants"):
            mods[name] = mock.MagicMock()
        mods["scrapling.fetchers"].StealthyFetcher = Fetcher
        mods["scrapling.engines.constants"].STEALTH_ARGS = ("--stealth-marker",)
        return calls, mock.patch.dict(sys.modules, mods)

    def test_browser_fetch_carries_resolver_rule_and_stealth_flags(self):
        calls, patched = self._fake_scrapling("https://www.reddit.com/search/?q=x")
        with patched:
            rp.fetch_reddit_html("https://www.reddit.com/search/?q=x")
        flags = calls[0][1]["extra_flags"]
        self.assertIn(rp.reddit_resolver_rules(), flags)
        self.assertIn("--stealth-marker", flags)

    def test_browser_fetch_refuses_a_final_url_off_host(self):
        calls, patched = self._fake_scrapling("https://out.reddit.com/redirect?to=x")
        with patched:
            with self.assertRaises(ValueError):
                rp.fetch_reddit_html("https://www.reddit.com/search/?q=x")

    def test_arctic_fetch_uses_the_same_host_redirect_handler(self):
        seen = []
        real = urllib.request.build_opener

        def spy(*handlers):
            seen.extend(handlers)
            raise OSError("stop before any network")

        with mock.patch.object(urllib.request, "build_opener", spy):
            with self.assertRaises(OSError):
                rp.fetch_arctic_json("https://arctic-shift.photon-reddit.com/api/posts/ids?ids=x")
        self.assertTrue(any(isinstance(h, urllib.request.HTTPRedirectHandler) for h in seen))
        self.assertIsNotNone(real)

    def test_fetchers_refuse_other_hosts(self):
        for fn in (rp.fetch_reddit_html, rp.fetch_arctic_json):
            for url in ("https://example.com/x", "http://www.reddit.com/x", "https://www.reddit.com.evil.io/x"):
                with self.subTest(fn=fn.__name__, url=url):
                    with self.assertRaises(ValueError):
                        fn(url)


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
