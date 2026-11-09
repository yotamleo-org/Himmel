#!/usr/bin/env python3
"""harvest-ceilings.py - move ponytail markers out of the code into a ledger draft.

A one-shot tool for the ceilings-ledger migration, never wired into a hook, a
suite or CI. Run it with `python3 -I` from the repo root.

  harvest PATH... [--carry OLD.tsv]
      stdout: a draft TSV (file anchor ceiling trigger ticket state note) that
      `scripts/ledger/ceiling-add.sh import --check` reads, one row per marker.
      stderr: `not-a-marker<TAB>path:line` for a token in code or data (its row
      is pre-set dropped), `backref<TAB>path:line` for the bare word.
      --carry keeps the state and note of an old row with the same file,
      anchor and sha256 of the ceiling; a new or changed block stays open.
  strip PATH...
      deletes the harvested `#` and `//` comment blocks and trailing comments,
      leaves a token in a quoted string or heredoc body (`left<TAB>path:line`)
      and the other forms (`hand<TAB>path:line`) for hand work, then checks that
      every changed file still parses (python and node heredocs included).
  verify BASE [--named FILE]
      for each file changed since the merge base outside the named list,
      `shfmt -mn` (.sh, .bash) or the comment-free token stream (.py) must be
      equal at the base and at HEAD, and no deleted line anywhere may be a
      directive comment. Prints `named<TAB>path` for each file it cannot vouch
      for, `FAIL path: why` for each failure, then one `verify:` line.

Exit: 0 done or clean; 1 a file no longer parses or verify failed; 2 usage or
cannot evaluate.
"""
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tokenize

TOK = "pony" + "tail:"
TOK_RE = re.compile(re.escape(TOK), re.I)
BARE_RE = re.compile(re.escape(TOK[:-1]) + r"(?!:)", re.I)
KEY_RE = re.compile(r"\b[A-Z][A-Z0-9]+-[0-9]+\b")
TRIG_RE = re.compile(r"\b(upgrade|revisit|until)\b|\bif\b.*?\bever\b", re.I)
DIRECTIVE_RE = re.compile(r"^(shellcheck\s|[a-z][a-z0-9-]*-ok:|residue-keep:|eslint-|@ts-|noqa|type:\s*ignore)")
NOT_A_MARKER = "migration: not a marker: code or test data, token rebuilt at runtime"
CAP = 2000
HEADER = ["file", "anchor", "ceiling", "trigger", "ticket", "state", "note"]

HASH_EXT = (".sh", ".bash", ".zsh", ".yaml", ".yml", ".toml", ".awk", ".conf", ".cfg", ".ini")
SH_EXT = (".sh", ".bash", ".zsh")
JS_EXT = (".js", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts", ".jsx")

HAND = {
    "scripts/lint/ticket-refs.awk", "scripts/lint/check-history-comments.sh",
    "scripts/lint/test-check-history-comments.sh", "scripts/lint/ticket-ref-allow.tsv",
    "scripts/lib/gap-audit.sh", "scripts/lib/test-gap-audit.sh",
    "scripts/eval/lane-quality/prune-history.sh",
    "scripts/one-shot/harvest-ceilings.py", "scripts/ledger/test-harvest-ceilings.sh",
    "scripts/one-shot/no-markers.sh", "scripts/ledger/test-marker-scan.sh",
}


def die(msg, rc=2):
    sys.stderr.write("harvest-ceilings: %s\n" % msg)
    sys.exit(rc)


def kind_of(path):
    p = path.lower()
    if p.endswith(".py"):
        return "py"
    if p.endswith(SH_EXT):
        return "sh"
    if p.endswith(JS_EXT):
        return "js"
    if p.endswith(".json"):
        return "json"
    if p.endswith(".md"):
        return "md"
    if p.endswith(HASH_EXT):
        return "hash"
    return "other"


def is_directive(text):
    return bool(DIRECTIVE_RE.match(text.strip()))


def scan_quoted(lines, leaders, sh=False, js=False):
    out, heredocs, q, blk = [], [], None, False
    hd_active = []
    for line in lines:
        if hd_active:
            delim, dash, cmd, body = hd_active[0]
            probe = line.lstrip("\t") if dash else line
            if probe == delim:
                heredocs.append((cmd, body))
                hd_active.pop(0)
                out.append(("code", -1))
            else:
                body.append(line)
                out.append(("data", -1))
            continue
        state = "data" if q else ("block" if blk else "code")
        cstart, j, n, pending = -1, 0, len(line), []
        while j < n:
            c = line[j]
            if blk:
                if line.startswith("*/", j):
                    blk = False
                    j += 2
                    continue
                j += 1
                continue
            if q:
                if c == "\\" and q != "'":
                    j += 2
                    continue
                if c == q:
                    q = None
                j += 1
                continue
            if c == "\\":
                j += 2
                continue
            if c in "'\"" or (js and c == "`"):
                q = c
                j += 1
                continue
            at_word = j == 0 or line[j - 1] in " \t"
            if sh and line.startswith("<<<", j):
                j += 3
                continue
            if sh and line.startswith("<<", j):
                m = re.match(r"<<(-?)\s*(?:(['\"])([^'\"\n]+)\2|\\?([A-Za-z_][A-Za-z0-9_.-]*))", line[j:])
                if m:
                    pending.append([m.group(3) or m.group(4), m.group(1) == "-", line[:j], []])
                    j += m.end()
                    continue
            if at_word and "#" in leaders and c == "#":
                cstart = j
                break
            if at_word and "//" in leaders and line.startswith("//", j):
                cstart = j
                break
            if js and line.startswith("/*", j):
                blk = True
                j += 2
                continue
            j += 1
        out.append((state, cstart))
        hd_active.extend(pending)
    return out, heredocs


def scan_py(text, lines):
    out = [("code", -1)] * len(lines)
    docs, data_lines = {}, set()
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        return [("data", -1)] * len(lines), docs
    prev = None
    for i, t in enumerate(toks):
        if t.type == tokenize.COMMENT:
            r = t.start[0] - 1
            out[r] = (out[r][0], t.start[1])
        elif t.type == tokenize.STRING:
            nxt = toks[i + 1].type if i + 1 < len(toks) else None
            is_doc = prev in (None, tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT, tokenize.ENCODING) \
                and nxt in (tokenize.NEWLINE, tokenize.ENDMARKER) and t.string.lstrip("rRbBuU")[:3] in ('"""', "'''")
            for r in range(t.start[0] - 1, t.end[0]):
                if is_doc:
                    docs[r] = (t.start[0] - 1, t.end[0] - 1)
                else:
                    data_lines.add(r)
        if t.type not in (tokenize.COMMENT, tokenize.NL):
            prev = t.type
    for r in docs:
        out[r] = ("doc", out[r][1])
    for r in data_lines:
        if r not in docs and out[r][1] < 0:
            out[r] = ("data", -1)
    return out, docs


SH_FN = [re.compile(r"^\s*function\s+([A-Za-z_][\w:.-]*)"), re.compile(r"^\s*([A-Za-z_][\w:.-]*)\s*\(\)")]
SH_CASE = re.compile(r"^\s*\(?([^()#\s][^()#]*?)\)(\s|$)")
ASSIGN = re.compile(r"^\s*(?:local\s+|export\s+|readonly\s+|declare\s+\S+\s+)?([A-Za-z_]\w*)\+?=")
PY_FN = re.compile(r"^\s*(?:async\s+)?(?:def|class)\s+(\w+)")
PY_ASSIGN = re.compile(r"^\s*([A-Za-z_]\w*)\s*(?::[^=]*)?=(?!=)")
JS_FN = [re.compile(r"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*(\w+)"),
         re.compile(r"^\s*(?:export\s+)?(?:const|let|var)\s+(\w+)\s*="),
         re.compile(r"^\s*(?:export\s+)?(?:default\s+)?class\s+(\w+)"),
         re.compile(r"^\s*(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{\s*$")]


def indent_of(line):
    return len(line) - len(line.lstrip())


def head_name(kind, line):
    pats = {"sh": SH_FN + [SH_CASE, ASSIGN], "hash": [ASSIGN], "py": [PY_FN, PY_ASSIGN], "js": JS_FN}.get(kind, [])
    for p in pats:
        m = p.match(line)
        if m and m.group(1).strip() and TOK_RE.search(m.group(1)) is None:
            return m.group(1).strip()
    return None


def clip(line):
    s = line.split("\t", 1)[0].strip()
    return s[:80].strip()


def is_code_line(line, scan_row):
    s = line.strip()
    return bool(s) and scan_row[0] == "code" and (scan_row[1] < 0 or scan_row[1] > indent_of(line))


def anchor_for(kind, lines, scan, first, last, level):
    if level > 0:
        lim = level
        for r in range(first - 1, -1, -1):
            line = lines[r]
            if not line.strip() or not is_code_line(line, scan[r]):
                continue
            ind = indent_of(line)
            if ind >= lim:
                continue
            name = head_name(kind, line)
            if name:
                return name
            lim = ind
            if ind == 0:
                break
    for r in list(range(last + 1, len(lines))) + list(range(first - 1, -1, -1)):
        if is_code_line(lines[r], scan[r]) and not TOK_RE.search(lines[r]):
            return clip(lines[r])
    for line in lines:
        if line.strip() and not TOK_RE.search(line):
            return clip(line)
    return "file"


def md_anchor(lines, at):
    for r in range(at - 1, -1, -1):
        m = re.match(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$", lines[r])
        if m and m.group(1) and not TOK_RE.search(m.group(1)):
            return clip(m.group(1))
    for line in lines:
        if line.strip() and not TOK_RE.search(line):
            return clip(line)
    return "file"


def after_token(text):
    m = TOK_RE.search(text)
    return text[m.end():] if m else text


def norm(s):
    return re.sub(r"\s+", " ", s.replace("\t", " ")).strip()


def fields(texts):
    ceiling = norm(" ".join(texts))
    if len(ceiling) > CAP:
        ceiling = ceiling[:CAP - 1] + "\u2026"
    m = TRIG_RE.search(ceiling)
    if m:
        trigger = ceiling[m.start():]
    elif ", " in ceiling:
        trigger = ceiling.split(", ", 1)[1]
    else:
        trigger = "none-planned: no trigger at the marker"
    k = KEY_RE.search(ceiling)
    return ceiling, norm(trigger)[:CAP], k.group(0) if k else ""


def strip_leader(s):
    s = s.strip()
    for lead in ("/**", "/*", "//", "#", "*", "<!--"):
        if s.startswith(lead):
            s = s[len(lead):]
            break
    return re.sub(r"(\*/|-->)\s*$", "", s).strip()


class Hit:
    def __init__(self, path, line, form, ceiling_texts, anchor, span=None, trailing_col=-1, data=False):
        self.path, self.line, self.form = path, line, form
        self.texts, self.anchor = ceiling_texts, anchor
        self.span, self.trailing_col, self.data = span, trailing_col, data


def comment_block(lines, scan, i, leader):
    level = scan[i][1]
    texts = [after_token(lines[i][level:].lstrip("#/ \t"))]
    end = i
    for r in range(i + 1, len(lines)):
        st, cs = scan[r]
        line = lines[r]
        if st != "code" or cs < 0 or cs != indent_of(line) or cs < level:
            break
        if not line[cs:].startswith(leader):
            break
        body = line[cs + len(leader):]
        if leader == "#" and body.startswith("!"):
            break
        if not body.strip() or is_directive(body) or TOK_RE.search(body):
            break
        texts.append(body)
        end = r
    return texts, end, level


def jsdoc_block(lines, i):
    texts = [after_token(strip_leader(lines[i]))]
    end = i
    if "*/" in lines[i]:
        return texts, end
    for r in range(i + 1, len(lines)):
        s = lines[r].strip()
        if s.startswith("*/") or not s.startswith("*"):
            break
        body = strip_leader(s)
        if not body or is_directive(body) or TOK_RE.search(body):
            break
        texts.append(body)
        end = r
    return texts, end


def harvest_file(path, out_hits, backrefs):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as e:
        die("cannot read %s: %s" % (path, e))
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    for n, line in enumerate(lines):
        if BARE_RE.search(line):
            backrefs.append("%s:%d" % (path, n + 1))
    kind = kind_of(path)
    if kind == "py":
        scan, docs = scan_py(text, lines)
    elif kind in ("sh", "hash"):
        scan, _ = scan_quoted(lines, ("#",), sh=(kind == "sh"))
    elif kind == "js":
        scan, _ = scan_quoted(lines, ("//",), js=True)
    else:
        scan, docs = [("code", -1)] * len(lines), {}
    if kind != "py":
        docs = {}
    i = 0
    while i < len(lines):
        line = lines[i]
        if not TOK_RE.search(line):
            i += 1
            continue
        st, cs = scan[i]
        hit = None
        if kind in ("sh", "hash", "py", "js") and st == "code" and cs >= 0 and TOK_RE.search(line[cs:]):
            leader = "//" if kind == "js" else "#"
            if cs == indent_of(line):
                texts, end, level = comment_block(lines, scan, i, leader)
                anchor = anchor_for(kind, lines, scan, i, end, level)
                hit = Hit(path, i, "comment", texts, anchor, span=(i, end))
                out_hits.append(hit)
                i = end + 1
                continue
            name = head_name(kind, line[:cs]) or clip(line[:cs])
            out_hits.append(Hit(path, i, "comment", [after_token(line[cs:].lstrip("#/ \t"))], name, trailing_col=cs))
            i += 1
            continue
        opener = line.find("/*")
        if kind == "js" and (st == "block" or (st == "code" and 0 <= opener < TOK_RE.search(line).start())):
            texts, end = jsdoc_block(lines, i)
            anchor = anchor_for(kind, lines, scan, i, end, indent_of(line) if indent_of(line) > 1 else 0)
            out_hits.append(Hit(path, i, "jsdoc", texts, anchor, span=(i, end)))
            i = end + 1
            continue
        if kind == "py" and st == "doc":
            dstart, dend = docs[i]
            texts, end = [after_token(line.strip())], i
            for r in range(i + 1, dend + 1):
                s = lines[r].strip()
                if not s or s.startswith(('"""', "'''")) or TOK_RE.search(s):
                    break
                texts.append(s.rstrip("\"'").strip())
                end = r
                if s.endswith(('"""', "'''")):
                    break
            texts = [t.replace('"""', "").replace("'''", "") for t in texts]
            anchor = anchor_for(kind, lines, scan, dstart, dend, indent_of(lines[dstart]))
            out_hits.append(Hit(path, i, "docstring", texts, anchor, span=(i, end)))
            i = end + 1
            continue
        if kind == "json":
            for seg_hit in json_hits(path, lines, i):
                out_hits.append(seg_hit)
            i += 1
            continue
        if kind == "md":
            texts, end = [after_token(strip_md(line))], i
            for r in range(i + 1, len(lines)):
                s = lines[r]
                if not s.strip() or re.match(r"^\s*([-*+>|#]|\d+\.\s|```)", s) or TOK_RE.search(s):
                    break
                texts.append(strip_md(s))
                end = r
            out_hits.append(Hit(path, i, "markdown", texts, md_anchor(lines, i), span=(i, end)))
            i = end + 1
            continue
        anchor = anchor_for(kind, lines, scan, i, i, indent_of(line)) if kind in ("sh", "hash", "py", "js") else md_anchor(lines, i)
        out_hits.append(Hit(path, i, "data", [line], anchor, data=True))
        i += 1


def strip_md(s):
    s = re.sub(r"^\s*(?:[-*+]\s+|\d+\.\s+|>\s*)?", "", s)
    return re.sub(r"<!--|-->", "", s).strip()


def json_hits(path, lines, i):
    line, hits = lines[i], []
    key = None
    for r in range(i, -1, -1):
        m = re.search(r'"([^"\\]+)"\s*:', lines[r] if r < i else line)
        if m:
            key = m.group(1)
            break
    for m in TOK_RE.finditer(line):
        if line[:m.start()].count('"') % 2 == 0:
            hits.append(Hit(path, i, "data", [line], key or clip(line), data=True))
            continue
        close = line.find('"', m.end())
        nxt = TOK_RE.search(line, m.end())
        stop = min(x for x in (close if close >= 0 else len(line), nxt.start() if nxt else len(line)))
        hits.append(Hit(path, i, "json", [line[m.end():stop]], key or clip(line)))
    return hits


def draft_rows(hits):
    rows = []
    for h in hits:
        if h.data:
            base = norm(h.texts[0])[:CAP - 8] or "data"
            k = len(TOK_RE.findall(h.texts[0])) or 1
            for n in range(k):
                ceiling = base if n == 0 else "%s (%d)" % (base, n + 1)
                rows.append([h.path, h.anchor, ceiling, "none-planned: not a marker", "", "dropped", NOT_A_MARKER])
            continue
        parts = TOK_RE.split(h.texts[0])
        for n, part in enumerate(parts):
            texts = [part] + h.texts[1:] if n == len(parts) - 1 else [part]
            ceiling, trigger, ticket = fields(texts)
            if not ceiling:
                ceiling = norm(h.texts[0]) or "empty marker"
            rows.append([h.path, h.anchor, ceiling, trigger, ticket, "open", "migration: harvested from a %s marker" % h.form])
    return rows


def sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def read_draft(path):
    rows = {}
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh.read().split("\n")):
            if not line or (n == 0 and line.split("\t", 1)[0] == "file"):
                continue
            f = line.split("\t")
            if len(f) == 7:
                rows[(f[0], f[1], sha(f[2]))] = (f[5], f[6])
    return rows


def cmd_harvest(args):
    carry, paths = None, []
    while args:
        a = args.pop(0)
        if a == "--carry":
            if not args:
                die("--carry needs a draft file")
            carry = read_draft(args.pop(0))
        else:
            paths.append(a)
    if not paths:
        die("harvest needs at least one path")
    hits, backrefs = [], []
    for p in paths:
        harvest_file(p, hits, backrefs)
    out = sys.stdout
    out.write("\t".join(HEADER) + "\n")
    for row in draft_rows(hits):
        if carry is not None:
            old = carry.get((row[0], row[1], sha(row[2])))
            if old:
                row[5], row[6] = old
        out.write("\t".join(row) + "\n")
    for h in hits:
        if h.data:
            sys.stderr.write("not-a-marker\t%s:%d\n" % (h.path, h.line + 1))
    for b in backrefs:
        sys.stderr.write("backref\t%s\n" % b)
    sys.stderr.write("harvest: %d rows, %d not a marker, %d back-references\n"
                     % (len(hits), sum(1 for h in hits if h.data), len(backrefs)))
    return 0


def parses(path, text):
    kind = kind_of(path)
    if kind == "py":
        try:
            compile(text, path, "exec")
        except SyntaxError as e:
            return "python: %s" % e
        return None
    if kind == "json":
        try:
            json.loads(text)
        except ValueError as e:
            return "json: %s" % e
        return None
    if kind == "sh" and not path.endswith(".zsh"):
        r = subprocess.run(["bash", "-n"], input=text, text=True, capture_output=True)
        if r.returncode != 0:
            return "bash -n: %s" % r.stderr.strip()[:200]
        lines = text.split("\n")
        _, heredocs = scan_quoted(lines, ("#",), sh=True)
        for cmd, body in heredocs:
            src = "\n".join(body) + "\n"
            if re.search(r"\bpython3?\b", cmd):
                try:
                    compile(src, path + " (heredoc)", "exec")
                except SyntaxError as e:
                    return "python heredoc: %s" % e
            elif re.search(r"\bnode\b", cmd) and not node_ok(src):
                return "node heredoc does not parse"
        return None
    if kind == "js" and path.endswith((".js", ".mjs", ".cjs")):
        return None if node_ok(text, os.path.splitext(path)[1]) else "node --check failed"
    return None


def node_ok(src, ext=None):
    for suffix in ([ext] if ext else [".mjs", ".cjs"]):
        with tempfile.NamedTemporaryFile("w", suffix=suffix, delete=False) as fh:
            fh.write(src)
            name = fh.name
        try:
            if subprocess.run(["node", "--check", name], capture_output=True).returncode == 0:
                return True
        finally:
            os.unlink(name)
    return False


def code_changed(path, old, new):
    ext = os.path.splitext(path)[1]
    if ext in (".sh", ".bash"):
        if shutil.which("shfmt") is None:
            return "shfmt is not installed, cannot prove the cut is comment-only"
        a, b = shfmt(old.encode("utf-8")), shfmt(new.encode("utf-8"))
    elif ext == ".py":
        a, b = py_tokens(old.encode("utf-8")), py_tokens(new.encode("utf-8"))
    else:
        return None
    if a is None:
        return "it does not parse before the cut"
    if a != b:
        return "the cut would change code or data, not only comments"
    return None


def cmd_strip(paths):
    if not paths:
        die("strip needs at least one path")
    broken = 0
    for path in paths:
        hits = []
        harvest_file(path, hits, [])
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        lines = text.split("\n")
        drop, cut = set(), {}
        for h in hits:
            if h.data:
                print("left\t%s:%d" % (path, h.line + 1))
            elif h.form != "comment":
                print("hand\t%s:%d" % (path, h.line + 1))
            elif h.trailing_col >= 0:
                cut[h.line] = h.trailing_col
            else:
                drop.update(range(h.span[0], h.span[1] + 1))
        if not drop and not cut:
            continue
        new = [lines[r][:cut[r]].rstrip() if r in cut else lines[r] for r in range(len(lines)) if r not in drop]
        new_text = "\n".join(new)
        changed = code_changed(path, text, new_text)
        if changed:
            print("REFUSED\t%s: %s; the file is left as it was, remove its markers by hand" % (path, changed))
            broken = 1
            continue
        before = parses(path, text)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(new_text)
        after = parses(path, new_text)
        if before is None and after is not None:
            print("BROKEN\t%s: %s" % (path, after))
            broken = 1
        print("stripped\t%s: %d lines deleted, %d trailing comments cut" % (path, len(drop), len(cut)))
    return broken


def git(*args, check=True):
    r = subprocess.run(["git"] + list(args), capture_output=True)
    if check and r.returncode != 0:
        die("git %s failed: %s" % (" ".join(args), r.stderr.decode("utf-8", "replace").strip()))
    return r


def shfmt(src):
    r = subprocess.run(["shfmt", "-mn", "-ln", "bash"], input=src, capture_output=True)
    return r.stdout if r.returncode == 0 else None


def py_tokens(src):
    try:
        toks = tokenize.generate_tokens(io.StringIO(src.decode("utf-8")).readline)
        return [(t.type, t.string) for t in toks if t.type not in (tokenize.COMMENT, tokenize.NL)]
    except (tokenize.TokenError, IndentationError, SyntaxError, UnicodeDecodeError):
        return None


def directive_in(line):
    s = line.strip()
    if s.startswith("#!"):
        return True
    for m in re.finditer(r"(?:^|\s)(#|//|/\*|\*)\s*", s):
        if is_directive(s[m.end():]):
            return True
    return False


def whole_file_rows(paths):
    lint = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lint")
    r = subprocess.run(["awk", "-f", os.path.join(lint, "ticket-refs.awk"),
                        "-v", "allow=" + os.path.join(lint, "ticket-ref-allow.tsv"), "-v", "mode=exempt"],
                       input="\n".join(paths) + "\n", capture_output=True, text=True, env=dict(os.environ, LC_ALL="C"))
    if r.returncode != 0:
        die("ticket-refs.awk exempt mode failed: %s" % r.stderr.strip())
    return set(r.stdout.split("\n")) - {""}


def cmd_verify(args):
    if not args:
        die("verify needs a base")
    base, named_extra = args.pop(0), set()
    while args:
        a = args.pop(0)
        if a == "--named" and args:
            with open(args.pop(0), encoding="utf-8") as fh:
                named_extra = {l.strip() for l in fh if l.strip()}
        else:
            die("unknown argument %s" % a)
    mb = git("merge-base", base, "HEAD").stdout.decode().strip()
    status = git("diff", "--name-status", "--no-renames", mb, "HEAD").stdout.decode("utf-8", "replace")
    rows = [r.split("\t", 1) for r in status.splitlines()]
    exempt = whole_file_rows([p for _, p in rows])
    named, fails, compared = [], [], 0
    for st, path in rows:
        kind = os.path.splitext(path)[1]
        if st != "M" or path in HAND or path in named_extra or path in exempt or kind not in (".sh", ".bash", ".py"):
            named.append(path)
            continue
        old = git("show", "%s:%s" % (mb, path)).stdout
        new = git("show", "HEAD:%s" % path).stdout
        if kind == ".py":
            a, b = py_tokens(old), py_tokens(new)
        else:
            if shutil.which("shfmt") is None:
                die("shfmt is not installed, cannot evaluate")
            a, b = shfmt(old), shfmt(new)
        compared += 1
        if a is None or b is None:
            fails.append("FAIL %s: does not parse at the %s" % (path, "base" if a is None else "head"))
        elif a != b:
            fails.append("FAIL %s: code changed, not only comments" % path)
    diff = git("diff", "-U0", "--text", "--no-color", "--no-ext-diff", "--no-renames", mb, "HEAD").stdout.decode("utf-8", "replace")
    path, removed, added = None, {}, {}
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            path = line.split(" b/", 1)[1] if " b/" in line else None
            continue
        if line.startswith(("--- ", "+++ ")):
            continue
        if line.startswith("-") and directive_in(line[1:]):
            removed.setdefault((path, line[1:].strip()), []).append(line)
        elif line.startswith("+") and directive_in(line[1:]):
            added[(path, line[1:].strip())] = added.get((path, line[1:].strip()), 0) + 1
    for (p, text), occ in sorted(removed.items(), key=lambda kv: (kv[0][0] or "", kv[0][1])):
        if len(occ) > added.get((p, text), 0):
            fails.append("FAIL %s: a directive comment was deleted: %s" % (p, text[:120]))
    for p in named:
        print("named\t%s" % p)
    for f in fails:
        print(f)
    if fails:
        print("verify: FAIL - %d failure(s), %d files compared, %d named for the judge" % (len(fails), compared, len(named)))
        return 1
    print("verify: PASS - %d files compared equal, %d named for the judge" % (compared, len(named)))
    return 0


def main(argv):
    if not argv:
        die("usage: harvest-ceilings.py harvest|strip|verify ... (see the docstring)")
    verb, args = argv[0], argv[1:]
    if verb == "harvest":
        return cmd_harvest(args)
    if verb == "strip":
        return cmd_strip(args)
    if verb == "verify":
        return cmd_verify(args)
    die("unknown verb %s" % verb)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
