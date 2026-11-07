#!/usr/bin/env python3
"""The one shared spec page generator: a spec markdown in, a sign-off HTML page out.

Usage: spec-page-gen.py <spec.md> <out.html>

The page names its source in <meta name="spec-source" content="<absolute path of the md>">;
chief-route.ts send-file reads that marker (markedSource) to find the critic files that
govern the page wherever the copy sits. The page carries no draft status text: the front matter
status is left out, and a body line starting with Status: or saying "not for signature" makes the
generator refuse (naming the line) and write nothing, because the draft state lives in the missing
critic seal. It prints two lines, the sha256 of the md it read and of the page it wrote; the critic
reads both files, quotes both shas, and both get sealed (chief-kit/critic-seal.sh, one run per file),
because send-file wants a seal for the page's own bytes.
"""
import hashlib
import html
import os
import re
import sys

INK, MUTE, BLUE, GREY, RED = "#1c2430", "#4a5563", "#2457a6", "#c3c9d1", "#a33a2a"


TABLE_SEP = re.compile(r"^\|\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")
DRAFT_LINE = re.compile(r"^\s*status\s*:|not for signature", re.I)


def attr(value):
    """Escape for a double- or single-quoted attribute; the reader in chief-route.ts undoes exactly these five."""
    return (value.replace("&", "&amp;").replace('"', "&quot;").replace("'", "&#39;")
            .replace("<", "&lt;").replace(">", "&gt;"))


def inline(t):
    t = html.escape(t, quote=False)
    parts = re.split(r"(`[^`]*`)", t)
    out = []
    for p in parts:
        if p.startswith("`") and p.endswith("`") and len(p) > 1:
            out.append(f"<code>{p[1:-1]}</code>")
        else:
            out.append(re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", p))
    return "".join(out)


def split_row(line):
    return re.split(r"(?<!\\)\|", line.strip().strip("|"))


def render(text):
    out, i = [], 0
    lines = text.split("\n")
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("# "):
            out.append(f"<h1>{inline(ln[2:])}</h1>")
            i += 1
        elif ln.startswith("## "):
            name = ln[3:].strip()
            if name == "At a glance":
                block = []
                i += 1
                while i < len(lines) and not lines[i].startswith("## "):
                    block.append(lines[i])
                    i += 1
                content = [x for x in block if x.strip()]
                if content and all(x.startswith("- ") for x in content):
                    lis = "".join(f'<li class="{"decision" if x.startswith("**A", 2) else "fact"}">{inline(x[2:])}</li>' for x in content)
                    inner = f"<ul>{lis}</ul>"
                else:
                    inner = render("\n".join(block))
                out.append(f'<div class="card"><h2>{inline(name)}</h2>{inner}</div>')
                continue
            out.append(f"<h2>{inline(name)}</h2>")
            i += 1
        elif re.match(r"#{3,6} ", ln):
            level = len(ln) - len(ln.lstrip("#"))
            out.append(f"<h{level}>{inline(ln[level + 1:].strip())}</h{level}>")
            i += 1
        elif ln.startswith("|") and i + 1 < len(lines) and TABLE_SEP.match(lines[i + 1]):
            head = split_row(ln)
            i += 2
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            th = "".join(f"<th>{inline(c.strip())}</th>" for c in head)
            tr = "".join("<tr>" + "".join(f"<td>{inline(c.strip())}</td>" for c in r) + "</tr>" for r in rows)
            out.append(f"<table><thead><tr>{th}</tr></thead><tbody>{tr}</tbody></table>")
        elif re.match(r"(- |\d+\. )", ln):
            ordered = bool(re.match(r"\d+\. ", ln))
            items = []
            while i < len(lines) and re.match(r"(- |\d+\. )", lines[i]):
                items.append(re.sub(r"^(- |\d+\. )", "", lines[i]))
                i += 1
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>" + "".join(f"<li>{inline(x)}</li>" for x in items) + f"</{tag}>")
        elif not ln.strip():
            i += 1
        else:
            para = [ln]
            i += 1
            while i < len(lines) and lines[i].strip() and not re.match(r"(#|\||- |\d+\. )", lines[i]):
                para.append(lines[i])
                i += 1
            if re.match(r"I\d ", para[0]):
                out.append("<ul>" + "".join(f"<li>{inline(p)}</li>" for p in para) + "</ul>")
            else:
                out.append(f"<p>{inline(' '.join(para))}</p>")
    return "\n".join(out)


CSS = f"""
body{{font:14px/1.45 system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;color:{INK};max-width:980px;margin:24px auto;padding:0 18px;background:#fff}}
h1{{font-size:21px;line-height:1.25;margin:6px 0 8px}} h2{{font-size:15.5px;margin:18px 0 6px;border-bottom:1px solid {GREY};padding-bottom:2px}}
p{{margin:6px 0;overflow-wrap:anywhere}} .card{{border:2px solid {BLUE};border-radius:8px;padding:2px 14px;margin:10px 0;background:#f6f9fd}} .card h2{{border:0;color:{BLUE};margin:8px 0 2px}} li.decision{{border-left:3px solid {RED};padding-left:6px;list-style:none;margin-left:-6px}} ul,ol{{margin:6px 0;padding-left:20px}} li{{margin:3px 0}}
code{{font:12.5px ui-monospace,Menlo,monospace;background:#f2f4f7;padding:0 3px;border-radius:3px;overflow-wrap:anywhere}}
table{{border-collapse:collapse;width:100%;margin:8px 0;font-size:13px}} th,td{{border:1px solid {GREY};padding:3px 7px;text-align:left;vertical-align:top}} th{{background:#f5f7fa}}
figure{{margin:10px 0}} svg{{width:100%;height:auto;display:block}} figcaption{{font-size:12.5px;color:{MUTE};margin-top:3px}}
.meta{{font-size:12.5px;color:{MUTE}}}
@media print{{body{{font-size:10px;line-height:1.25;margin:0;max-width:none}} h1{{font-size:14px}} h2{{font-size:11px;margin:6px 0 2px}} p{{margin:4px 0}} li{{margin:2px 0}} table{{font-size:9px;margin:5px 0}} th,td{{padding:1px 5px}} code{{font-size:9px}} figure{{margin:4px 0;break-inside:avoid}} figcaption{{font-size:8.5px}} svg{{max-height:100px}} @page{{margin:9mm}}}}
"""


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: spec-page-gen.py <spec.md> <out.html>")
    spec = os.path.abspath(sys.argv[1])
    out_path = os.path.abspath(sys.argv[2])
    if os.path.realpath(out_path) == os.path.realpath(spec):
        sys.exit(f"spec-page-gen: the output path is the md itself ({spec}); nothing written")
    raw = open(spec, "rb").read()
    md = raw.decode("utf-8").replace("\r\n", "\n")
    fm = re.match(r"---\n(.*?)\n---\n", md, re.S)
    meta = dict(x.split(": ", 1) for x in fm.group(1).split("\n") if ": " in x) if fm else {}
    body = md[fm.end():] if fm else md
    first = md[:fm.end()].count("\n") if fm else 0
    for n, line in enumerate(body.split("\n"), first + 1):
        if DRAFT_LINE.search(line):
            sys.exit(f"spec-page-gen: {spec}:{n} is a draft status line ({line.strip()[:80]!r}); the draft state lives in the missing critic seal, not in the page words. Remove the line from the md, re-run the critic, then generate. Nothing written")
    title = re.search(r"^# (.+)$", body, re.M)
    bar = " | ".join(html.escape(meta[k][:9] if k == "base" else meta[k]) for k in ("tickets", "date", "base", "author") if k in meta)
    if DRAFT_LINE.search(bar):
        sys.exit(f"spec-page-gen: the front matter metadata of {spec} carries draft text; nothing written")
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="spec-source" content="{attr(spec)}"><title>{html.escape(title.group(1) if title else os.path.basename(spec))}</title><style>{CSS}</style></head>
<body>
{f'<p class="meta">{bar}</p>' if bar else ""}
{render(body)}
</body></html>
"""
    data = page.encode("utf-8")
    open(out_path, "wb").write(data)
    print(f"sha256 {hashlib.sha256(raw).hexdigest()} {spec}")
    print(f"sha256 {hashlib.sha256(data).hexdigest()} {out_path}")


main()
