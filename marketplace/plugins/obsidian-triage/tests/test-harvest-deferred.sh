#!/usr/bin/env bash
# source-level per-clip partials are a deferred, NON-blocking
# class. The retry count lives on the clip (frontmatter), so it survives the
# daily G-5 state rotation; after DEFER_ATTENTION_AFTER retries a clip moves to
# the needs-attention bucket of the pending report and is no longer retried.
# Blocking classes (failed, and the runbook-level stale-read / rate-limited /
# catastrophic) keep the run from writing .harvest.done.
set -euo pipefail
export HARVEST_SCRAPE_DENY=all
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/../tools/harvest-clip-body-batch.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/harvest-deferred.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
# the runbook body plus its on-demand references.
hc="$tmp/harvest-clips.all.md"
cat "$here/../commands/harvest-clips.md" "$here"/../references/harvest-clips/*.md > "$hc"

cat > "$tmp/t.py" <<'PY'
import importlib.util, subprocess, sys
from pathlib import Path

tool, tmp = sys.argv[1], Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("harvest_batch", tool)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.TODAY = "2026-10-06"
fails = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)
        if detail:
            print(detail)


def clip(name, source, body="short.\n", extra=""):
    p = tmp / name
    p.write_text(f"---\ntype: article\nsource: {source}\n{extra}---\n{body}", encoding="utf-8")
    return p


def fm(p):
    return mod.parse_frontmatter(p.read_text(encoding="utf-8"))[0]


check("attention threshold is 5", mod.DEFER_ATTENTION_AFTER == 5)

# Class: thin-body skeleton -> deferred, count on the clip.
p = clip("thin.md", "https://example.com/post")
g, msg, _ = mod.process_clip(p, dry_run=False)
check("thin-body is a deferred partial", g == "~" and "deferred 1/5" in msg, msg)
check("thin-body count on frontmatter", fm(p).get("harvest_defer_count") == "1", p.read_text())

# Class: enricher-gap -> deferred.
p = clip("gap.md", "https://www.tiktok.com/@a/video/1")
g, msg, _ = mod.process_clip(p, dry_run=False)
check("enricher-gap is a deferred partial", g == "~" and "deferred 1/5" in msg
      and fm(p).get("harvest_enricher_gap"), msg)

# Class: IG media-pending -> deferred.
p = clip("ig.md", "https://www.instagram.com/reel/DEF4675/")
g, msg, _ = mod.process_clip(p, dry_run=False)
check("ig media-pending is a deferred partial", g == "~" and "deferred 1/5" in msg
      and fm(p).get("ig_media_pending") == "true", msg)


# A reverted defer-count write is a G-3 failure: blocking, never a deferred partial.
real_bump = mod.bump_defer
mod.bump_defer = lambda _p: None
p = clip("g3.md", "https://example.com/g3")
g, msg, _ = mod.process_clip(p, dry_run=False)
mod.bump_defer = real_bump
check("reverted defer-count write fails (G-3, blocking)", g == "x" and "G-3" in msg, msg)


class Chain:
    def __init__(self, remaining, exc=None):
        self.remaining, self.exc, self.last_backend = remaining, exc, None

    def scrape(self, url):
        raise self.exc


# Class: firecrawl fetch failed (source-level) -> deferred, counted.
p = clip("fc-fail.md", "https://example.org/a")
g, msg, _ = mod.process_clip(p, dry_run=False, chain=Chain(3, RuntimeError("boom")), url_rules=mod.UrlRules())
check("firecrawl fetch failed is deferred + counted", g == "~"
      and fm(p).get("harvest_defer_count") == "1", msg + "\n" + p.read_text())

# Class: firecrawl budget exhausted (run-level) -> deferred, NOT counted.
p = clip("fc-budget.md", "https://example.org/b")
g, msg, _ = mod.process_clip(p, dry_run=False, chain=Chain(0), url_rules=mod.UrlRules())
check("budget exhausted is deferred, not counted", g == "~"
      and "harvest_defer_count" not in fm(p), msg + "\n" + p.read_text())

# Dry-run never bumps the count.
p = clip("dry.md", "https://example.com/dry")
mod.process_clip(p, dry_run=True)
check("dry-run does not bump", "harvest_defer_count" not in p.read_text())

# The count accumulates across runs and the 5th defer moves the clip to
# needs-attention; the body is never touched.
p = clip("five.md", "https://example.com/five", body="short.\n")
for day in range(1, 6):  # one bump per calendar day, so five nights
    mod.TODAY = f"2026-10-{day:02d}"
    g, msg, _ = mod.process_clip(p, dry_run=False)
mod.TODAY = "2026-10-06"
f = fm(p)
check("5th defer -> needs-attention", f.get("harvest_defer_count") == "5"
      and f.get("harvest_needs_attention") == "true" and "needs-attention" in msg, msg + "\n" + p.read_text())
check("body untouched after 5 defers", p.read_text().endswith("---\nshort.\n"))
before = p.read_text()
g, msg, _ = mod.process_clip(p, dry_run=False)
check("needs-attention clip is skipped, not retried", g == "o" and "needs-attention" in msg
      and p.read_text() == before, msg)

# re-runs on the same day bump the counter at most once.
p = clip("sameday.md", "https://example.com/sameday")
mod.TODAY = "2026-10-06"
for _ in range(5):
    g, msg, _ = mod.process_clip(p, dry_run=False)
f = fm(p)
check("five same-day runs bump once", f.get("harvest_defer_count") == "1"
      and f.get("harvest_defer_last") == "2026-10-06"
      and "harvest_needs_attention" not in f, p.read_text())
check("same-day re-run still reports a deferred partial", g == "~" and "deferred 1/5" in msg, msg)
mod.TODAY = "2026-10-07"
mod.process_clip(p, dry_run=False)
check("next day bumps again", fm(p).get("harvest_defer_count") == "2"
      and fm(p).get("harvest_defer_last") == "2026-10-07", p.read_text())
p = clip("nodate.md", "https://example.com/nodate",
         extra="harvest_status: partial\nharvest_defer_count: 3\n")
mod.TODAY = "2026-10-06"
mod.process_clip(p, dry_run=False)
mod.process_clip(p, dry_run=False)
check("counter without a date bumps once and sets it", fm(p).get("harvest_defer_count") == "4"
      and fm(p).get("harvest_defer_last") == "2026-10-06", p.read_text())

# Batch level: deferred-only run exits 0, prints the deferred count and writes
# the pending report; a needs-attention clip is listed, never dropped.
v = tmp / "vault"
(v / "Clippings").mkdir(parents=True)
(v / "Clippings/a-thin.md").write_text("---\ntype: article\nsource: https://example.com/x\n---\nshort.\n")
(v / "Clippings/b-ig.md").write_text("---\ntype: instagram\nsource: https://www.instagram.com/p/BIG1/\n---\nshort.\n")
(v / "Clippings/c-stuck.md").write_text(
    "---\ntype: article\nsource: https://example.com/s\nharvest_status: partial\n"
    "harvest_defer_count: 5\nharvest_needs_attention: true\n---\nshort.\n")
r = subprocess.run([sys.executable, tool, str(v)], capture_output=True, text=True)
check("deferred-only batch exits 0", r.returncode == 0, r.stdout + r.stderr)
# the tool writes only a PROVISIONAL marker; a run that dies before
# G-8 promotes it (a rename) leaves no .harvest.done, so downstream stays gated closed.
done = v / ".harvest.done"
prov = v / ".harvest.done.provisional"
check("deferred-only batch writes the provisional marker", prov.is_file(), r.stdout)
check("aborted run (no promote) leaves no .harvest.done", not done.exists())
check("provisional marker carries a timestamp and a batch hash",
      prov.is_file() and len(prov.read_text().split()) == 2, prov.read_text() if prov.is_file() else "")
prov.rename(done)  # what the G-8 runbook step does
check("promote renames the provisional marker to .harvest.done", done.is_file() and not prov.exists())
check(".harvest.done keeps the timestamp and batch hash",
      len(done.read_text().split()) == 2, done.read_text())
check("summary counts deferred + needs-attention",
      "harvest-clip-body-batch: 2 deferred (non-blocking), 1 needs-attention" in r.stdout, r.stdout)
rep = v / ".harvest-pending.md"
text = rep.read_text() if rep.exists() else ""
check("pending report lists deferred clips", "[[Clippings/a-thin]]" in text and "[[Clippings/b-ig]]" in text, text)
na = text.split("## Needs attention", 1)
check("pending report has needs-attention bucket", len(na) == 2 and "[[Clippings/c-stuck]]" in na[1], text)

# Blocking class: failed -> exit 4.
(v / "Clippings/d-bad.md").write_text("---\ntype: article\nsource: not a url\n---\nshort.\n")
r = subprocess.run([sys.executable, tool, str(v)], capture_output=True, text=True)
check("failed clip blocks (exit 4)", r.returncode == 4, r.stdout + r.stderr)
check("failed batch leaves no .harvest.done", not (v / ".harvest.done").exists())
check("failed batch leaves no provisional marker", not (v / ".harvest.done.provisional").exists())

# Dry-run writes no report.
v2 = tmp / "vault2"
(v2 / "Clippings").mkdir(parents=True)
(v2 / "Clippings/a.md").write_text("---\ntype: article\nsource: https://example.com/x\n---\nshort.\n")
r = subprocess.run([sys.executable, tool, str(v2), "--dry-run"], capture_output=True, text=True)
check("dry-run exits 0", r.returncode == 0, r.stdout + r.stderr)
check("dry-run writes no pending report", not (v2 / ".harvest-pending.md").exists())
check("dry-run writes no .harvest.done", not (v2 / ".harvest.done").exists())
check("dry-run writes no provisional marker", not (v2 / ".harvest.done.provisional").exists())

# A thin partial article clip with no try time is retried even when triage
# wrote a metadata summary that makes the body read rich, and the attempt
# records a try time instead of stamping the summary ok.
v3 = tmp / "vault3"
ev = v3 / "Clippings" / "_evidence"
ev.mkdir(parents=True)
summarised = ev / "summarised.md"
summarised.write_text(
    "---\ntype: article\nsource: https://example.com/post\nharvested_at: 2026-08-17\n"
    "harvest_skill: clip-body\nharvest_status: partial\nharvest_flag: thin-body\n---\n"
    "## Summary\nA blog post about sessions; the clipper captured only the title and the link.\n\n"
    "## Source\nhttps://example.com/post\n", encoding="utf-8")
retry, _partials = mod.evidence_clips(v3 / "Clippings")
check("a summarised thin partial with no try time is selected for retry", summarised in retry, str(retry))
g, msg, _ = mod.process_clip(summarised, dry_run=False, chain=Chain(3, RuntimeError("offline")), url_rules=mod.UrlRules())
f = fm(summarised)
check("its failed retry records a try time and stays partial", g == "~" and f.get("harvest_status") == "partial"
      and f.get("harvest_defer_last") == mod.TODAY, msg + "\n" + summarised.read_text())


# The fetch budget goes to the least recently tried clip first, so a clip
# never tried is not starved by one that keeps failing ahead of it.
class RecordingChain(Chain):
    def __init__(self, remaining):
        super().__init__(remaining, RuntimeError("offline"))
        self.backends, self.charge_failures, self.seen = [object()], True, []

    def scrape(self, url):
        self.seen.append(url)
        raise self.exc


v4 = tmp / "vault4"
ev = v4 / "Clippings" / "_evidence"
ev.mkdir(parents=True)
(ev / "a-tried.md").write_text(
    "---\ntype: article\nsource: https://example.com/tried\nharvest_status: partial\nharvest_flag: thin-body\n"
    "harvest_defer_count: 1\nharvest_defer_last: 2026-10-04\n---\nshort.\n", encoding="utf-8")
never = ev / "b-never.md"
never.write_text(
    "---\ntype: article\nsource: https://example.com/never\nharvest_status: partial\nharvest_flag: thin-body\n"
    "---\nshort.\n", encoding="utf-8")
rec = RecordingChain(1)
real_build, mod.build_scrape_chain = mod.build_scrape_chain, lambda *a, **k: rec
real_argv, sys.argv = sys.argv, [tool, str(v4), "--date", "2026-10-06"]
try:
    mod.main()
except SystemExit:
    pass
finally:
    mod.build_scrape_chain, sys.argv = real_build, real_argv
check("the budget goes to the never-tried clip first", rec.seen == ["https://example.com/never"]
      and fm(never).get("harvest_defer_last") == "2026-10-06", f"{rec.seen}\n{never.read_text()}")

sys.exit(1 if fails else 0)
PY
python3 "$tmp/t.py" "$tool" "$tmp"

# Runbook contract: the class table, and G-8 writes the marker when every
# partial is deferred-class.
table=$(awk '/^### Partial classes/{p=1;next} /^### /{if(p) exit} p' "$here/../references/harvest-clips/partial-classes.md")
for row in "thin-body" "enricher-gap" "ig_media_pending" "x_media_pending" "firecrawl" \
           "stale-read" "rate-limited" "failed" "catastrophic" "needs-attention" \
           "harvest_defer_count" ".harvest-pending.md"; do
    grep -qF -- "$row" <<< "$table" || { echo "FAIL: class table lacks $row"; exit 1; }
done
for cls in "stale-read" "rate-limited" "catastrophic"; do
    hit=$(grep -F -- "$cls" <<< "$table" | grep -i "block" || true); [ -n "$hit" ] \
        || { echo "FAIL: class table does not mark $cls as blocking"; exit 1; }
done
g8=$(awk '/^### G-8/{p=1;next} /^### /{if(p) exit} p' "$here/../references/harvest-clips/g-8-completion-marker.md")
grep -qi "deferred" <<< "$g8" || { echo "FAIL: G-8 does not admit deferred partials"; exit 1; }
echo "HARVEST-DEFERRED PASS"
