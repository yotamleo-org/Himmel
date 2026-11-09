#!/usr/bin/env python3
"""The one shared spec page generator: a spec markdown in, a sign-off HTML page out.

Usage: spec-page-gen.py <spec.md> <out.html>

The page names its source in <meta name="spec-source" content="<absolute path of the md>">;
chief-route.ts send-file reads that marker (markedSource) to find the critic files that
govern the page wherever the copy sits. The page carries no draft status text. An ordinary front
matter status is left out of the page; a front matter status holding "draft" or "not for signature",
a body line starting with Status:, and a body line saying "not for signature" make the generator
refuse (naming file and line) and write nothing, because the draft state lives in the missing critic
seal. Only the plain spellings are refused: a decorated one (a bold or quoted Status:, other draft
wording) is not, and the page reaches the operator only after a critic reads those bytes. It prints two lines, the sha256 of the md it read and of the page it wrote; the critic
reads both files, quotes both shas, and both get sealed (chief-kit/critic-seal.sh, one run per file),
because send-file wants a seal for the page's own bytes. The page draws the spec's `svg` fence under
## Diagrams, refuses a spec with none, and carries send-file's CSP meta.
"""
import hashlib
import html
import os
import re
import sys
import xml.etree.ElementTree as ET

# dark is the default; the light set below is for print only (a printed dark page drops its background)
DARK = "--ink:#e6e9ed;--mute:#a9b3be;--blue:#7aa2ff;--grey:#3a434e;--red:#ff8079;--bg:#0f1318;--card:#151d29;--code:#1d252f;--th:#1a222c"
LIGHT = "--ink:#1c2430;--mute:#4a5563;--blue:#2457a6;--grey:#c3c9d1;--red:#a33a2a;--bg:#fff;--card:#f6f9fd;--code:#f2f4f7;--th:#f5f7fa"


TABLE_SEP = re.compile(r"^\|\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")
DRAFT_LINE = re.compile(r"^\s*status\s*:|not for signature", re.I)
FENCE_SVG, FENCE_END = "```svg", "```"
SVG_TAGS = {"svg", "g", "defs", "marker", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "title", "desc"}


def svg_problem(src):
    """Why an svg fence cannot be drawn on the page, or None: drawing elements only, nothing that runs or fetches."""
    if re.search(r"<[!?]", src):
        return "holds a <! or <? construct"
    try:
        root = ET.fromstring(src)
    except ET.ParseError as e:
        return f"is not well-formed ({e})"
    if root.tag.split("}")[-1] != "svg":
        return "does not start with <svg>"
    for el in root.iter():
        tag = el.tag.split("}")[-1]
        if tag not in SVG_TAGS:
            return f"holds a <{tag}> element"
        for k, v in el.attrib.items():
            name = k.split("}")[-1].lower()
            if name.startswith("on") or name == "style":
                return f"holds a {name} attribute"
            if name == "href" and not v.startswith("#"):
                return "holds an href that leaves the figure"
            if "\\" in v:
                return f"holds a backslash in {name}"
            if re.search(r"url\s*\(", v, re.I) and not re.fullmatch(r"url\(#[\w.-]+\)", v, re.I):
                return f"holds a url() in {name} that is not url(#id)"
    return None


def diagram_check(body, first):
    """None when the md holds at least one drawable svg fence under ## Diagrams, else '<line>: <reason>'; a leading ': ' means the refusal names the file only."""
    lines, i, section, found = body.split("\n"), 0, "", 0
    while i < len(lines):
        if lines[i].startswith("## "):
            section = lines[i][3:].strip()
        if lines[i] == FENCE_SVG:
            start = i
            i += 1
            while i < len(lines) and lines[i] != FENCE_END:
                i += 1
            if i == len(lines):
                return f"{first + start}: the svg fence is never closed"
            why = svg_problem("\n".join(lines[start + 1:i]))
            if why:
                return f"{first + start}: the svg fence {why}"
            found += section == "Diagrams"
        i += 1
    return None if found else ": has no svg fence under ## Diagrams; a page carries a diagram"


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
        elif ln == FENCE_SVG:
            i += 1
            fig = []
            while i < len(lines) and lines[i] != FENCE_END:
                fig.append(lines[i])
                i += 1
            i += 1
            out.append("<figure>" + "\n".join(fig) + "</figure>")
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
            while i < len(lines) and lines[i].strip() and lines[i] != FENCE_SVG and not re.match(r"(#|\||- |\d+\. )", lines[i]):
                para.append(lines[i])
                i += 1
            if re.match(r"I\d ", para[0]):
                out.append("<ul>" + "".join(f"<li>{inline(p)}</li>" for p in para) + "</ul>")
            else:
                out.append(f"<p>{inline(' '.join(para))}</p>")
    return "\n".join(out)


CSS = f"""
:root{{{DARK};color-scheme:dark}}
body{{font:14px/1.45 system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;color:var(--ink);max-width:980px;margin:24px auto;padding:0 18px;background:var(--bg)}}
h1{{font-size:21px;line-height:1.25;margin:6px 0 8px}} h2{{font-size:15.5px;margin:18px 0 6px;border-bottom:1px solid var(--grey);padding-bottom:2px}}
p{{margin:6px 0;overflow-wrap:anywhere}} .card{{border:2px solid var(--blue);border-radius:8px;padding:2px 14px;margin:10px 0;background:var(--card)}} .card h2{{border:0;color:var(--blue);margin:8px 0 2px}} li.decision{{border-left:3px solid var(--red);padding-left:6px;list-style:none;margin-left:-6px}} ul,ol{{margin:6px 0;padding-left:20px}} li{{margin:3px 0}}
code{{font:12.5px ui-monospace,Menlo,monospace;background:var(--code);padding:0 3px;border-radius:3px;overflow-wrap:anywhere}}
table{{border-collapse:collapse;width:100%;margin:8px 0;font-size:13px}} th,td{{border:1px solid var(--grey);padding:3px 7px;text-align:left;vertical-align:top}} th{{background:var(--th)}}
figure{{margin:10px 0}} svg{{width:100%;height:auto;display:block}} figcaption{{font-size:12.5px;color:var(--mute);margin-top:3px}}
.meta{{font-size:12.5px;color:var(--mute)}}
@media print{{:root{{{LIGHT};color-scheme:light}} body{{font-size:10px;line-height:1.25;margin:0;max-width:none}} h1{{font-size:14px}} h2{{font-size:11px;margin:6px 0 2px}} p{{margin:4px 0}} li{{margin:2px 0}} table{{font-size:9px;margin:5px 0}} th,td{{padding:1px 5px}} code{{font-size:9px}} figure{{margin:4px 0;break-inside:avoid}} figcaption{{font-size:8.5px}} svg{{max-height:100px}} @page{{margin:9mm}}}}
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
            sys.exit(f"spec-page-gen: {spec}:{n} is a draft status line ({line.strip()[:80]!r}); the draft state lives in the missing critic seal, not in the page words. Remove the line from the md, generate the page again, then run the critic on the md and the new page. Nothing written")
    if fm:
        for n, line in enumerate(md[:fm.end()].split("\n"), 1):
            if re.match(r"\s*status\s*:", line, re.I) and re.search(r"\bdraft\b|not for signature", line.split(":", 1)[1], re.I):
                sys.exit(f"spec-page-gen: {spec}:{n} is a front matter status holding draft text ({line.strip()[:80]!r}); the draft state lives in the missing critic seal, not in the md. Remove the words from the status, generate the page again, then run the critic on the md and the new page. Nothing written")
    why = diagram_check(body, first + 1)
    if why:
        n, why = ("", why[2:]) if why.startswith(": ") else why.split(": ", 1)
        sys.exit(f"spec-page-gen: {spec}{':' + n if n else ''} {why}. Draw it in the md, generate the page again, then run the critic on the md and the new page. Nothing written")
    title = re.search(r"^# (.+)$", body, re.M)
    bar =" | ".join(html.escape(meta[k][:9] if k == "base" else meta[k]) for k in ("tickets", "date", "base", "author") if k in meta)
    if DRAFT_LINE.search(bar):
        sys.exit(f"spec-page-gen: the front matter metadata of {spec} carries draft text; nothing written")
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="spec-source" content="{attr(spec)}"><title>{html.escape(title.group(1) if title else os.path.basename(spec))}</title><style>{CSS}</style></head>
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
