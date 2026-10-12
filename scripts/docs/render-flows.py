#!/usr/bin/env python3
"""render-flows.py — render docs/assets/flows.svg, the README's flow graph.

Four himmel flows, one row each. A pulse walks each row step by step and
loops, so the reader sees the order things happen in. The animation is plain
CSS inside the SVG (no script), which GitHub renders in an <img>. With the
animation stripped the graph still reads: every box and label is static.

Edit the FLOWS table below, never the SVG; then re-render:

    python3 scripts/docs/render-flows.py            # writes docs/assets/flows.svg
    python3 scripts/docs/render-flows.py --out F    # writes F instead

scripts/docs/test-readme-hygiene.sh fails when the committed SVG differs from
what this script renders. Stdlib only, deterministic output.
"""

import argparse
import os
from xml.sax.saxutils import escape

# (title, [(label, caption), ...]). Six steps per flow keeps the boxes legible.
FLOWS = [
    ("1  Ship a change", [
        ("Jira ticket", "every commit cites it"),
        ("/worktree", "own branch, never main"),
        ("commit + push", "hooks gate each step"),
        ("/pr-check", "panel of review agents"),
        ("CI green", "the impacted suites"),
        ("merge", "then /clean prunes"),
    ]),
    ("2  Run a fleet: one console, many legs", [
        ("console", "plans the work"),
        ("dispatch leg", "own worktree + token"),
        ("leg ships a PR", "reports LIVE, READY"),
        ("console checks", "ready-check, judge"),
        ("GO file", "the console signs off"),
        ("merge + wrap", "merge-on-green"),
    ]),
    ("3  Carry work across sessions", [
        ("session works", "decisions pile up"),
        ("/handover", "writes a markdown doc"),
        ("state repo", "your handover repo"),
        ("cap or restart", "relaunch is armed"),
        ("/handover-resume", "reads the doc back"),
        ("picks up", "where it stopped"),
    ]),
    ("4  Find what you already know", [
        ("question", "in any session"),
        ("MEMORY.md", "index routes to notes"),
        ("qmd search", "keyword + vector"),
        ("graphify", "graph of the code"),
        ("source file", "the real file, read"),
        ("write back", "new lesson to memory"),
    ]),
]

W = 960            # canvas width
PAD = 24           # outer padding
ROW_H = 128        # one flow's height
TITLE_H = 30       # title band inside a row
BOX_H = 44
GAP = 30           # space between boxes (holds the arrow)
CYCLE = 9          # seconds for one pass of the pulse
STEP = 1.2         # seconds between consecutive steps lighting up

CSS = """
.card{fill:#ffffff;stroke:#d0d7de}
.title{fill:#1f2328;font:600 15px system-ui,-apple-system,'Segoe UI',sans-serif}
.box{fill:#f6f8fa;stroke:#d0d7de;stroke-width:1.5}
.label{fill:#1f2328;font:600 13px system-ui,-apple-system,'Segoe UI',sans-serif}
.cap{fill:#59636e;font:12px system-ui,-apple-system,'Segoe UI',sans-serif}
.arrow{stroke:#8c959f;stroke-width:2;fill:none}
.head{fill:#8c959f}
.box.p{animation:box %(c)ss linear infinite}
.label.p{animation:label %(c)ss linear infinite}
.arrow.p{animation:arrow %(c)ss linear infinite}
.head.p{animation:head %(c)ss linear infinite}
@keyframes box{0%%,14%%{fill:#0969da;stroke:#0969da}22%%,100%%{fill:#f6f8fa;stroke:#d0d7de}}
@keyframes label{0%%,14%%{fill:#ffffff}22%%,100%%{fill:#1f2328}}
@keyframes arrow{0%%,14%%{stroke:#0969da}22%%,100%%{stroke:#8c959f}}
@keyframes head{0%%,14%%{fill:#0969da}22%%,100%%{fill:#8c959f}}
@media (prefers-color-scheme:dark){
.card{fill:#0d1117;stroke:#3d444d}
.title,.label{fill:#f0f6fc}
.box{fill:#151b23;stroke:#3d444d}
.cap{fill:#9198a1}
.arrow{stroke:#656c76}
.head{fill:#656c76}
@keyframes box{0%%,14%%{fill:#1f6feb;stroke:#4493f8}22%%,100%%{fill:#151b23;stroke:#3d444d}}
@keyframes label{0%%,14%%{fill:#ffffff}22%%,100%%{fill:#f0f6fc}}
@keyframes arrow{0%%,14%%{stroke:#4493f8}22%%,100%%{stroke:#656c76}}
@keyframes head{0%%,14%%{fill:#4493f8}22%%,100%%{fill:#656c76}}
}
@media (prefers-reduced-motion:reduce){.p{animation:none!important}}
""" % {"c": CYCLE}


def fmt(x):
    """Stable number formatting so the output is byte-identical across runs."""
    return ("%.2f" % x).rstrip("0").rstrip(".")


def render():
    height = PAD * 2 + ROW_H * len(FLOWS)
    out = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d" role="img" aria-labelledby="t d">' % (W, height, W, height),
        "<title id=\"t\">himmel: four flows</title>",
        "<desc id=\"d\">%s</desc>" % escape("; ".join(
            "%s: %s" % (t.split("  ", 1)[1], " then ".join(s[0] for s in steps))
            for t, steps in FLOWS)),
        "<style>%s</style>" % CSS.strip(),
        '<rect class="card" x="0.5" y="0.5" width="%d" height="%d" rx="12"/>' % (W - 1, height - 1),
    ]
    for r, (title, steps) in enumerate(FLOWS):
        top = PAD + r * ROW_H
        out.append('<text class="title" x="%d" y="%d">%s</text>'
                   % (PAD, top + 18, escape(title)))
        n = len(steps)
        box_w = (W - 2 * PAD - GAP * (n - 1)) / n
        y = top + TITLE_H
        for i, (label, cap) in enumerate(steps):
            x = PAD + i * (box_w + GAP)
            # Stagger rows a little so the four pulses do not march in lockstep.
            delay = "animation-delay:%ss" % fmt(i * STEP + r * 0.3)
            out.append('<rect class="box p" style="%s" x="%s" y="%d" width="%s" '
                       'height="%d" rx="8"/>' % (delay, fmt(x), y, fmt(box_w), BOX_H))
            out.append('<text class="label p" style="%s" x="%s" y="%d" '
                       'text-anchor="middle">%s</text>'
                       % (delay, fmt(x + box_w / 2), y + BOX_H / 2 + 5, escape(label)))
            out.append('<text class="cap" x="%s" y="%d" text-anchor="middle">%s</text>'
                       % (fmt(x + box_w / 2), y + BOX_H + 20, escape(cap)))
            if i < n - 1:
                ax1 = x + box_w + 4
                ax2 = x + box_w + GAP - 6
                ay = y + BOX_H / 2
                adelay = "animation-delay:%ss" % fmt(i * STEP + r * 0.3 + STEP / 2)
                out.append('<line class="arrow p" style="%s" x1="%s" y1="%s" x2="%s" y2="%s"/>'
                           % (adelay, fmt(ax1), fmt(ay), fmt(ax2 - 4), fmt(ay)))
                out.append('<path class="head p" style="%s" d="M%s %sL%s %sL%s %sZ"/>'
                           % (adelay, fmt(ax2), fmt(ay), fmt(ax2 - 7), fmt(ay - 5),
                              fmt(ax2 - 7), fmt(ay + 5)))
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(root, "docs", "assets", "flows.svg"))
    args = ap.parse_args()
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(render())


if __name__ == "__main__":
    main()
