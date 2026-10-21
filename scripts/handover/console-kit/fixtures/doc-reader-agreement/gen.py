#!/usr/bin/env python3
"""gen.py - grammar-driven console and leg docs, plus the one reference parser.

  gen.py gen <outdir> <seed> <n-console> <n-leg> <console-template>
      writes <n-console> console docs (the real console.sh template with a
      generated `legs:` block and Results) and <n-leg> leg docs (a leg brief
      header and generated Results bullets) under <outdir>/u/himmel/, and
      expect.tsv beside them. Same seed, same bytes.
  gen.py ref <console|leg> <doc>
      the reference parser alone, one TSV row, for a doc made some other way.

expect.tsv, one row per doc:
  console <file> <entry labels, comma> <malformed labels, comma>
  leg     <file> <label> <tail marker or ?> <pr or ->

The reference parser (ref_console, ref_leg) reads the written TEXT, from the
grammar in docs/handover/leg-preface.md and scripts/lib/leg-tail-status.sh's
header, never from a reader's code. gen also keeps what each generated doc was
BUILT to mean (intent_*) and refuses to emit a doc the reference parser reads
differently, so a drifting reference fails here and not as a reader disagreement.
Pure stdlib; offline.
"""
import os
import random
import re
import sys

MARKERS = "WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED"
MARKER_RE = re.compile(r"^- (?:[0-9]{1,2}:[0-9]{2}\s+)?(?:\*\*)?(" + MARKERS + r")(?:[^A-Za-z0-9_].*)?$")
WRAPPED_WORD_RE = re.compile(r"(?:^|[^A-Za-z0-9_])WRAPPED(?:[^A-Za-z0-9_]|$)")
LABEL_CLASS_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
SHAPED_RE = re.compile(r"^N[0-9]+[a-z]*$")
PR_RE = re.compile(
    r"^- (?:[0-9]{1,2}:[0-9]{2}\s+)?(?:LIVE\s*[-–—:]?\s*PR\s*#?([0-9]{2,})\s+open\b"
    r"|READY\s+#?([0-9]{2,})\s+[0-9a-f]{7,}|MERGED\s+#([0-9]{2,})\b)"
)


def section(lines, title, exact):
    out, on = [], False
    for ln in lines:
        if on and ln.startswith("## "):
            break
        if on:
            out.append(ln)
        if ln == title or (not exact and ln.startswith(title + " ")) or (not exact and ln == title):
            on = True
    return out


# ---------------------------------------------------------------- reference
def legs_block(live):
    """The `legs:` block(s): each `legs:` line plus the lines wrapped under it,
    ended by a blank line, a `word:` field line, a list marker or a `>`/`#` line."""
    block, inside = [], False
    for ln in live:
        if ln.startswith("legs:"):
            inside = True
        elif inside and (
            re.match(r"^\s*$", ln)
            or re.match(r"^[A-Za-z][A-Za-z ]*:", ln)
            or re.match(r"^\s*([-*+]|[0-9]+[.)])\s", ln)
            or re.match(r"^\s*[>#]", ln)
        ):
            inside = False
        if inside:
            block.append(ln)
    return block


def ref_console(text):
    live = section(text.split("\n"), "## Live state", True)
    entries, malformed = set(), set()
    for ln in legs_block(live):
        for span in re.findall(r"`([^`]*)`", ln):
            if span == "" or re.search(r"\s", span) or ":" not in span:
                continue
            f1 = span.split(":")[0]
            if f1 == "" or not LABEL_CLASS_RE.match(f1):
                continue
            fields = span.split(":")
            if len(fields) == 4 and all(fields):
                entries.add(f1)
            elif SHAPED_RE.match(f1):
                malformed.add(f1)
    return sorted(entries), sorted(malformed)


def ref_tail(text):
    res = section(text.split("\n"), "## Results", False)
    bullets = [ln for ln in res if ln.startswith("- ")]
    if not bullets:
        return "?"
    final = bullets[-1]
    m = MARKER_RE.match(final)
    if m:
        return m.group(1)
    if WRAPPED_WORD_RE.search(final):
        return "WRAPPED"
    for ln in reversed(bullets):
        m = MARKER_RE.match(ln)
        if m:
            return m.group(1)
    return "?"


def ref_pr(text):
    res = section(text.split("\n"), "## Results", False)
    pr = None
    for ln in res:
        if ln.startswith("- "):
            m = PR_RE.match(ln)
            if m:
                pr = int(m.group(1) or m.group(2) or m.group(3))
    return pr


# ---------------------------------------------------------------- grammar
WORDS = "alpha beta gamma delta checked wrote pushed reviewed green suite round ruling doc tick board leg lock".split()


def prose(rng, lo=3, hi=9):
    return " ".join(rng.choice(WORDS) for _ in range(rng.randrange(lo, hi)))


def hexsha(rng):
    return "".join(rng.choice("0123456789abcdef") for _ in range(40))


# (kind, text builder). Each bullet kind is BUILT to mean: lead = the marker it
# leads with ('' when it leads with none), wrapped_word = it mentions WRAPPED as
# a whole word, pr = the PR number its grammar owns.
def bullet(rng, kind):
    k = rng.randrange(10, 9999)
    if kind == "LIVE":
        return "LIVE — " + prose(rng), "LIVE", False, None
    if kind == "LIVE-PR":
        n = rng.randrange(100, 4000)
        return "LIVE — PR %d open" % n, "LIVE", False, n
    if kind == "FINDING":
        return "FINDING — " + prose(rng), "FINDING", False, None
    if kind == "FINDING-LONG":
        body = " ".join(prose(rng, 8, 14) for _ in range(rng.randrange(30, 70)))
        return "FINDING — %s; WRAPPED later? READY when answered; see x.md:%d" % (body, k), "FINDING", True, None
    if kind == "RESOLVED":
        return "RESOLVED — ruling received, see console message", "RESOLVED", False, None
    if kind == "READY":
        n = rng.randrange(100, 4000)
        return "READY %d %s GREEN" % (n, hexsha(rng)), "READY", False, n
    if kind == "BLOCKED":
        return "BLOCKED — " + prose(rng), "BLOCKED", False, None
    if kind == "HALTED":
        return "HALTED — " + prose(rng), "HALTED", False, None
    if kind == "PARKED-BANK":
        return "PARKED-BANK — " + prose(rng), "PARKED-BANK", False, None
    if kind == "PARKED-USAGE":
        return "PARKED-USAGE — " + prose(rng), "PARKED-USAGE", False, None
    if kind == "RESUMED":
        return "RESUMED — " + prose(rng), "RESUMED", False, None
    if kind == "WRAPPED":
        return "WRAPPED — " + prose(rng), "WRAPPED", True, None
    if kind == "WRAPPED-COLON":
        return "WRAPPED: " + prose(rng), "WRAPPED", True, None
    if kind == "WRAPPED-BARE":
        return "WRAPPED", "WRAPPED", True, None
    if kind == "WRAPPED-BOLD":
        return "**WRAPPED** — " + prose(rng), "WRAPPED", True, None
    if kind == "LIVE-MENTIONS":
        return "LIVE — was BLOCKED, then WRAPPED nothing; %s" % prose(rng), "LIVE", True, None
    if kind == "LIVE-TOKEN":
        return "LIVE — saw `N%d:DC-N%d-ab12:tok%d:%d` in the console doc" % (k, k, k, k), "LIVE", False, None
    if kind == "FINDING-CITE":
        return "FINDING — see scripts/handover/console-kit/tick.sh:%d and docs/x.md:%d:%d" % (k, k, k % 90), "FINDING", False, None
    if kind == "UNMARKED-WRAPPED":
        return "Released lock `tok%d`, appended the WRAPPED bullet, ending turn" % k, "", True, None
    if kind == "UNMARKED":
        return "Sent READY to the console and %s" % prose(rng), "", False, None
    if kind == "NOT-A-MARKER":
        return rng.choice(["FINDINGS recorded", "UNRESOLVED left over", "WRAPPEDUP of the notes", "LIVELY exchange"]) + " " + prose(rng), "", False, None
    if kind == "SUCCESSION":
        return "SUCCESSION accepted: HIMMEL-nextleg-2026-10-20DC-%d-console replaces HIMMEL-nextleg-2026-10-20DB-%d-console" % (k, k), "", False, None
    if kind == "CONSULT":
        return "CONSULT lane-a :: " + prose(rng), "", False, None
    if kind == "MAIN-RED":
        return "MAIN-RED test-job case-%d" % k, "", False, None
    if kind == "BUS-FAIL":
        return "bus=FAIL:" + prose(rng, 2, 5).replace(" ", "-"), "", False, None
    raise ValueError(kind)


CANON = ["LIVE", "LIVE-PR", "FINDING", "RESOLVED", "READY", "BLOCKED", "HALTED", "PARKED-BANK", "PARKED-USAGE", "RESUMED", "WRAPPED",
         "SUCCESSION", "CONSULT", "MAIN-RED", "BUS-FAIL"]
ADVERSARIAL = ["FINDING-LONG", "WRAPPED-COLON", "WRAPPED-BARE", "WRAPPED-BOLD", "LIVE-MENTIONS", "LIVE-TOKEN", "FINDING-CITE",
               "UNMARKED-WRAPPED", "UNMARKED", "NOT-A-MARKER"]
# a final bullet a leg writes last: the wrap, a hold, or a question
FINALS = ["WRAPPED", "WRAPPED-COLON", "WRAPPED-BARE", "WRAPPED-BOLD", "UNMARKED-WRAPPED", "READY", "FINDING", "FINDING-LONG",
          "LIVE", "BLOCKED", "UNMARKED", "SUCCESSION", "BUS-FAIL", "RESOLVED", "LIVE-MENTIONS", "NOT-A-MARKER"]
# interleaved lines that are NOT status bullets
NOISE = ["", "  continued text that mentions WRAPPED", "  - WRAPPED — nested, indented", "* WRAPPED — star list", "> - WRAPPED — quoted",
         "Plain prose line with LIVE and READY in it"]


def stamp(rng):
    return rng.choice(["%02d:%02d", "%02d:%02d", "%d:%02d"]) % (rng.randrange(0, 24), rng.randrange(0, 60))


def build_leg_doc(rng, k):
    head = (
        "---\nresume_cwd: /x/y\ntemplate_version: 3\n---\n\n"
        "# HIMMEL-%d — generated leg N%d\n\n"
        "> **Your RETASK token is `AW-N%d-%08x`; your console is `HIMMEL-nextleg-2026-10-20DC-gen-console`.**\n"
        "> - **Lock:** hold the queue lock on THIS document.\n\n"
        "## Results (newest at the bottom)\n" % (9000 + k, k, k, rng.getrandbits(32))
    )
    n = rng.randrange(1, 7)
    kinds = [rng.choice(CANON + ADVERSARIAL) for _ in range(n - 1)] + [rng.choice(FINALS)]
    lines, tail, pr = [], "?", None
    last_marked, final_wrapped_word, final_lead = "", False, ""
    for i, kind in enumerate(kinds):
        text, lead, wword, bpr = bullet(rng, kind)
        ts = stamp(rng) + " " if rng.randrange(8) else ""
        lines.append("- " + ts + text)
        if bpr is not None:
            pr = bpr
        if lead in MARKERS.split("|"):
            last_marked = lead
        final_lead, final_wrapped_word = lead, wword
        if i < len(kinds) - 1 and rng.randrange(3) == 0:
            lines.append(rng.choice(NOISE))
    # intent: the final bullet's own marker, else a whole-word WRAPPED, else the last marked bullet
    if final_lead in MARKERS.split("|"):
        tail = final_lead
    elif final_wrapped_word:
        tail = "WRAPPED"
    else:
        tail = last_marked or "?"
    return head + "\n".join(lines) + "\n", tail, pr


def entry(rng, label, i):
    return "`%s:DC-%s-%04x:cachyos-x8664-pid%d:%d`" % (label, label, rng.getrandbits(16), 1000 + i, 2000 + i)


def span_prose(rng):
    return rng.choice([
        "`legs:`", "`procs:2`", "`N191`", "`livestate=DRIFT:N192`", "`scripts/handover/x.md:408`", "`tick.sh`", "`a:b:c`",
        "`a b:c:d:e`", "`x.md:408:3`", "`bank, procs:2`", "`N2:only-two`", "`.md:12`", "`:::`", "``",
    ])


def span_malformed(rng, label):
    return rng.choice(["`%s:nonce:tok`" % label, "`%s:n:t:5:extra`" % label, "`%s::tok:5`" % label, "`%s:n:t:`" % label, "`%s:n`" % label])


def build_console_doc(rng, template, name):
    nlab = rng.randrange(0, 9)
    labels = ["N%d%s" % (rng.randrange(1, 3000), rng.choice(["", "", "", "b"])) for _ in range(nlab)]
    labels = sorted(set(labels))
    entries = [entry(rng, lab, i) for i, lab in enumerate(labels)]
    # tokens on the legs: lines: entries, prose cites, backticked non-entries, malformed entries
    toks = list(entries)
    malformed = []
    for _ in range(rng.randrange(0, 4)):
        tok = span_prose(rng)
        toks.append(tok)
        if tok == "`N2:only-two`":
            malformed.append("N2")
    for _ in range(rng.randrange(0, 3)):
        lab = "N%d" % rng.randrange(3000, 3500)
        toks.append(span_malformed(rng, lab))
        malformed.append(lab)
    for _ in range(rng.randrange(0, 3)):
        toks.append(rng.choice(["see scripts/x.md:408", "bank ok", "(wrapped below)", "N191 mentioned", "procs 2 live"]))
    rng.shuffle(toks)
    layout = rng.choice(["one", "wrap", "wrap", "wrap-flush", "multi", "none", "absent"])
    block = []
    if layout == "one":
        block = ["legs: " + " ".join(toks)]
    elif layout in ("wrap", "wrap-flush"):
        per = rng.randrange(1, 4)
        chunks = [toks[i:i + per] for i in range(0, len(toks), per)] or [[]]
        pad = "" if layout == "wrap-flush" else "  "
        block = ["legs: " + " ".join(chunks[0])] + [pad + " ".join(c) for c in chunks[1:]]
    elif layout == "multi":
        half = len(toks) // 2
        block = ["legs: " + " ".join(toks[:half]), "queue: K1 | 112 `N7:fake:queue:9` | 113", "legs: " + " ".join(toks[half:])]
    elif layout == "none":
        block = ["legs: none"]
        entries, labels, malformed = [], [], []
    # trailing fields and bullets that are NOT part of the block
    tail_lines = [""]
    tail_lines.append("- detail under legs `N%d:fake:detail:7` x.md:408" % rng.randrange(1, 99))
    tail_lines.append("queue: 111 `N%d:fake:queue:8`" % rng.randrange(1, 99))
    tail_lines.append("last GO: `N%d:fake:go:6` quoted" % rng.randrange(1, 99))
    if layout == "absent":
        block, entries, labels, malformed = [], [], [], []
    # the fake ones above sit after a blank / list / field line: never entries
    lines = template.split("\n")
    out, done = [], False
    for ln in lines:
        out.append(ln)
        if ln == "## Live state" and not done:
            out.extend(block + tail_lines + [""])
            done = True
    doc = "\n".join(out)
    # Results: leg-describing WRAPPED bullets, mid-doc and last
    res = []
    for _ in range(rng.randrange(0, 5)):
        res.append("- %s %s" % (stamp(rng), rng.choice([
            "WRAPPED — N%d merged, window closed" % rng.randrange(1, 99),
            "N%d WRAPPED, lock released" % rng.randrange(1, 99),
            "LIVE — dispatched N%d" % rng.randrange(1, 99),
            "legs: `N%d:DC-N1-aa:t:1` re-armed" % rng.randrange(1, 99),
            "MERGED #%d" % rng.randrange(100, 4000),
        ])))
    return doc + ("\n".join(res) + "\n" if res else ""), sorted(set(labels)), sorted(set(malformed))


def main(argv):
    if len(argv) == 4 and argv[1] == "ref":
        text = open(argv[3], encoding="utf-8").read()
        if argv[2] == "console":
            e, m = ref_console(text)
            print("console\t%s\t%s\t%s" % (argv[3], ",".join(e), ",".join(m)))
        else:
            pr = ref_pr(text)
            print("leg\t%s\t-\t%s\t%s" % (argv[3], ref_tail(text), "-" if pr is None else pr))
        return 0
    if len(argv) != 7 or argv[1] != "gen":
        sys.stderr.write(__doc__)
        return 2
    outdir, seed, n_console, n_leg, tpl = argv[2], int(argv[3]), int(argv[4]), int(argv[5]), argv[6]
    rng = random.Random(seed)
    template = open(tpl, encoding="utf-8").read().rstrip("\n").split("\n## Results")[0] + "\n\n## Results (newest at the bottom)\n"
    bdir = os.path.join(outdir, "u", "himmel")
    os.makedirs(bdir, exist_ok=True)
    rows = []
    for i in range(n_console):
        name = "HIMMEL-nextleg-2026-10-20%s-gen%d-console.md" % (chr(65 + i % 26) + (chr(65 + i // 26) if i >= 26 else ""), i)
        doc, labels, malformed = build_console_doc(rng, template, name)
        got_e, got_m = ref_console(doc)
        if (got_e, got_m) != (labels, malformed):
            sys.stderr.write("gen: reference parser disagrees with the console doc built for %s: built %r/%r, read %r/%r\n" % (name, labels, malformed, got_e, got_m))
            return 1
        with open(os.path.join(bdir, name), "w", encoding="utf-8") as fh:
            fh.write(doc)
        rows.append("console\t%s\t%s\t%s" % (name, ",".join(labels), ",".join(malformed)))
    for i in range(n_leg):
        k = 100 + i
        name = "HIMMEL-%d-N%d-g%d-2026-10-20.md" % (9000 + k, k, k)
        doc, tail, pr = build_leg_doc(rng, k)
        if ref_tail(doc) != tail or ref_pr(doc) != pr:
            sys.stderr.write("gen: reference parser disagrees with the leg doc built for %s: built %s/%s, read %s/%s\n" % (name, tail, pr, ref_tail(doc), ref_pr(doc)))
            return 1
        with open(os.path.join(bdir, name), "w", encoding="utf-8") as fh:
            fh.write(doc)
        rows.append("leg\t%s\tN%d\t%s\t%s" % (name, k, tail, "-" if pr is None else pr))
    with open(os.path.join(outdir, "expect.tsv"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(rows) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
