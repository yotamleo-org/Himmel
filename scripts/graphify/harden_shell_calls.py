# harden_shell_calls.py -- shell call resolution for harden-graph.py: reads
# each shell file the graph holds a file node for and turns
#   bash|sh|source|.|exec <path>   and a bare   <path>.sh   command word
# into "calls" (bash/sh/exec/direct) or "sources" (source/.) edges between
# the two file nodes. stdlib only, like harden-graph.py.
#
# Resolution rule (never guessed): <path> resolves only from what the SAME
# file says --
#   $0, ${BASH_SOURCE[0]}, $BASH_SOURCE          -> the file itself
#   $(dirname X), ${X%/*}                        -> X's directory
#   $(cd X && pwd)                               -> X
#   $(git rev-parse --show-toplevel)             -> the corpus root
#   $VAR / ${VAR} (incl. for VAR in ...)          -> every resolvable in-file
#                                                   value of VAR (one edge each)
#   a literal relative path                      -> corpus-root relative
#   <unresolved>/a/b.sh (a sandbox copy)         -> the root's a/b.sh, as an
#                                                   INFERRED edge
# Anything else ($1, an env var, a path outside the root or with no file
# node) is skipped and counted unresolved.
# Comments and heredoc bodies are never read as commands, and a quoted
# string is only a command where it is a $( ) / backtick substitution.
import os
import posixpath
import re

ROOT = "/@root"
TAIL = "/@tail"
MAX_VALUES = 32
CALL_WORDS = {"bash": "calls", "sh": "calls", "exec": "calls", "source": "sources", ".": "sources"}
BASH_WORDS = {'"$BASH"': "bash", "$BASH": "bash", '"${BASH}"': "bash", "${BASH}": "bash"}
PREFIX_WORDS ={"!", "then", "do", "else", "elif", "if", "while", "until", "{", "time", "nohup", "command", "builtin"}
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z_0-9]*)=(.*)$", re.S)
HEREDOC_RE = re.compile(r"(?<!<)<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z_0-9]*)\2")
SHELL_EXT = (".sh", ".bash")


def is_shell_file_node(node):
    sf = node.get("source_file") or ""
    return (
        sf.endswith(SHELL_EXT)
        and node.get("file_type") == "code"
        and node.get("source_location") == "L1"
        and (node.get("metadata") or {}).get("kind") == "file"
    )


def blank_heredocs(src):
    """Return src with every heredoc body line emptied (line count kept), so
    a fixture script written by `cat <<EOF` is never read as this file's
    own commands."""
    lines = src.split("\n")
    out = []
    pending = []
    for line in lines:
        if pending:
            strip_tabs, word = pending[0]
            if (line.lstrip("\t") if strip_tabs else line) == word:
                pending.pop(0)
            out.append("")
            continue
        out.append(line)
        if "<<" in line:
            for m in HEREDOC_RE.finditer(_unquoted_code(line)):
                pending.append((m.group(1) == "-", m.group(3)))
    return "\n".join(out)


def _unquoted_code(line):
    """line with quoted spans and a trailing comment removed, so a << inside
    a string or a comment never opens a heredoc."""
    out, i, n = [], 0, len(line)
    while i < n:
        c = line[i]
        if c == "\\":
            i += 2
        elif c in "'\"":
            j = line.find(c, i + 1)
            body = line[i + 1:n if j < 0 else j]
            i = n if j < 0 else j + 1
            heredoc_word = "".join(out).rstrip(" \t-").endswith("<<")
            subst = c == '"' and "$(" in body
            out.append(c + body + c if heredoc_word else body if subst else " ")
        elif c == "#" and (i == 0 or line[i - 1] in " \t;&|("):
            break
        else:
            out.append(c)
            i += 1
    return "".join(out)


class _Scanner:
    """Splits shell source into simple commands, each a list of raw words
    (quotes kept) plus its line number, descending into $( ) and backticks."""

    def __init__(self, src):
        self.s = src
        self.i = 0
        self.line = 1
        self.commands = []

    def run(self):
        self._list(None)
        return self.commands

    def _list(self, closer):
        words, cur, start = [], None, self.line
        depth = 0
        s = self.s

        redirect_target = False

        def end_word():
            nonlocal cur, redirect_target
            if cur is not None:
                if not redirect_target:
                    words.append("".join(cur))
                redirect_target = False
                cur = None

        def flush():
            nonlocal words, start
            end_word()
            if words:
                self.commands.append((words, start))
            words, start = [], self.line

        while self.i < len(s):
            c = s[self.i]
            if closer == "`" and c == "`":
                self.i += 1
                flush()
                return
            if c == ")" and closer == ")" and depth == 0:
                self.i += 1
                flush()
                return
            if c == "\n":
                flush()
                self.line += 1
                self.i += 1
                start = self.line
                continue
            if c in " \t":
                end_word()
                self.i += 1
                continue
            if c in ";&|":
                flush()
                self.i += 1
                continue
            if c == "(" and cur is None:
                depth += 1
                flush()
                self.i += 1
                continue
            if c == ")":
                depth = max(0, depth - 1)
                flush()
                self.i += 1
                continue
            if c == "#" and cur is None:
                while self.i < len(s) and s[self.i] != "\n":
                    self.i += 1
                continue
            if c in "<>":
                if cur is not None and "".join(cur).isdigit():
                    cur = None
                end_word()
                b = self.i
                while self.i < len(s) and s[self.i] in "<>&0123456789-":
                    self.i += 1
                fd_dup = re.fullmatch(r"[<>]+&[0-9-]+", s[b:self.i])
                while self.i < len(s) and s[self.i] in " \t":
                    self.i += 1
                if not fd_dup and s[self.i:self.i + 1] not in ("(", "\n", ""):
                    redirect_target = True
                continue
            if c == "\\" and s[self.i + 1:self.i + 2] == "\n":
                self.line += 1
                self.i += 2
                continue
            if cur is None:
                cur = []
                if not words:
                    start = self.line
            if c == "\\":
                cur.append(s[self.i:self.i + 2])
                if s[self.i + 1:self.i + 2] == "\n":
                    self.line += 1
                self.i += 2
            elif c == "'":
                j = s.find("'", self.i + 1)
                j = len(s) if j < 0 else j
                self.line += s.count("\n", self.i, j)
                cur.append(s[self.i:j + 1])
                self.i = j + 1
            elif c == '"':
                cur.append(self._dquote())
            elif c == "$" and s[self.i + 1:self.i + 2] == "(":
                cur.append(self._subst())
            elif c == "$" and s[self.i + 1:self.i + 2] == "{":
                cur.append(self._brace())
            elif c == "`":
                b = self.i
                self.i += 1
                self._list("`")
                cur.append(s[b:self.i])
            else:
                cur.append(c)
                self.i += 1
        flush()

    def _subst(self):
        b = self.i
        self.i += 2
        self._list(")")
        return self.s[b:self.i]

    def _brace(self):
        b, n = self.i, 0
        while self.i < len(self.s):
            ch = self.s[self.i]
            self.i += 1
            if ch == "{":
                n += 1
            elif ch == "}":
                n -= 1
                if n == 0:
                    break
        return self.s[b:self.i]

    def _dquote(self):
        b = self.i
        self.i += 1
        s = self.s
        while self.i < len(s) and s[self.i] != '"':
            c = s[self.i]
            if c == "\\":
                if s[self.i + 1:self.i + 2] == "\n":
                    self.line += 1
                self.i += 2
            elif c == "$" and s[self.i + 1:self.i + 2] == "(":
                self._subst()
            elif c == "$" and s[self.i + 1:self.i + 2] == "{":
                self._brace()
            elif c == "`":
                self.i += 1
                self._list("`")
            else:
                if c == "\n":
                    self.line += 1
                self.i += 1
        self.i += 1
        return s[b:self.i]


def _single_quoted_expansion(word):
    """True when a $ or backtick sits inside a top-level '...' span, where the
    shell keeps it literal."""
    i, n, dq = 0, len(word), False
    while i < n:
        c = word[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            dq = not dq
        elif c == "'" and not dq:
            j = word.find("'", i + 1)
            j = n if j < 0 else j
            if "$" in word[i:j] or "`" in word[i:j]:
                return True
            i = j
        i += 1
    return False


def _unquote(word):
    return word.replace('"', "").replace("'", "")


class _Resolver:
    def __init__(self, self_path, assigns):
        self.self_path = posixpath.join(ROOT, self_path)
        self.assigns = assigns

    def word(self, word, seen=frozenset()):
        """Set of absolute (ROOT-prefixed) paths a word can evaluate to;
        empty when it cannot be resolved."""
        if _single_quoted_expansion(word):
            return set()
        text = _unquote(word)
        if "$" not in text and "`" not in text:
            if not text or text.startswith("/") or text.startswith("~"):
                return set()
            return {posixpath.normpath(posixpath.join(ROOT, text))}
        return self._expr(text, seen)

    def _expr(self, text, seen):
        outs = {""}
        i = 0
        while i < len(text):
            c = text[i]
            if c != "$":
                outs = {o + c for o in outs}
                i += 1
                continue
            if text.startswith("$(", i):
                j = _match_pair(text, i + 1, "(", ")")
                vals = self._command(text[i + 2:j], seen) if j >= 0 else set()
                i = j + 1 if j >= 0 else len(text)
            elif text.startswith("${", i):
                j = _match_pair(text, i + 1, "{", "}")
                vals = self._param(text[i + 2:j], seen) if j >= 0 else set()
                i = j + 1 if j >= 0 else len(text)
            else:
                m = re.match(r"\$([A-Za-z_][A-Za-z_0-9]*|0)", text[i:])
                vals = self._var(m.group(1), seen) if m else set()
                i += m.end() if m else 1
            if not vals:
                return _repo_tail(text[i:])
            outs = {o + v for o in outs for v in vals}
            if len(outs) > MAX_VALUES:
                return set()
        res = set()
        for o in outs:
            o = posixpath.normpath(o) if o.startswith((ROOT, TAIL)) else ""
            if o == ROOT or o.startswith((ROOT + "/", TAIL + "/")):
                res.add(o)
        return res

    def _var(self, name, seen):
        if name in ("0", "BASH_SOURCE"):
            return {self.self_path}
        if name in seen or name not in self.assigns:
            return set()
        vals = set()
        for v in self.assigns[name]:
            vals |= self.word(v, seen | {name})
        return vals

    def _param(self, body, seen):
        m = re.fullmatch(r"([A-Za-z_][A-Za-z_0-9]*|0)(?:\[0\])?(%/\*)?(?::?-(.*))?", body, re.S)
        if not m:
            return set()
        name, strip, default = m.groups()
        vals = self._var(name, seen)
        if not vals and default and name not in self.assigns:
            vals = self._expr(default, seen) if "$" in default else set()
        return {posixpath.dirname(v) for v in vals} if strip else vals

    def _command(self, body, seen):
        body = re.sub(r"\s(?:--|-P|-L|2>/dev/null)(?=\s)", "", " " + body.strip() + " ").strip()
        if body == "git rev-parse --show-toplevel":
            return {ROOT}
        m = re.fullmatch(r"dirname (.+)", body)
        if m:
            return {posixpath.dirname(v) for v in self._expr(m.group(1), seen)}
        m = re.fullmatch(r"cd (.+?)\s*(?:&&|;)\s*pwd", body)
        if m:
            return self._expr(m.group(1), seen)
        return set()


def _repo_tail(tail):
    """A literal tail of two or more path components after an unresolved
    expansion ("$fx/scripts/cr/x.sh", a test's sandbox copy) names the corpus
    file at that root-relative path."""
    parts = tail.split("/")
    if not tail.startswith("/") or "$" in tail or "`" in tail or len(parts) < 3 or ".." in parts or "" in parts[1:]:
        return set()
    return {TAIL + tail}


def _match_pair(text, i, opener, closer):
    depth = 0
    for j in range(i, len(text)):
        if text[j] == opener:
            depth += 1
        elif text[j] == closer:
            depth -= 1
            if depth == 0:
                return j
    return -1


def _strip_prefix(words):
    i = 0
    while i < len(words):
        w = words[i]
        if ASSIGN_RE.match(w) or w in PREFIX_WORDS:
            i += 1
        elif w == "env":
            i += 1
            while i < len(words) and (words[i].startswith("-") or ASSIGN_RE.match(words[i]) or words[i] == '"$@"'):
                i += 2 if words[i] in ("-u", "-C", "-S") else 1
        elif w == "timeout":
            i += 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in ("-k", "-s") else 1
            i += 1
        else:
            break
    return words[i:]


def scan_file(src):
    """(assigns, calls) for one shell source: assigns maps a variable to every
    raw value it is given; calls is [(relation, raw target word, line)]."""
    commands = _Scanner(blank_heredocs(src)).run()
    assigns = {}
    calls = []
    for words, line in commands:
        head = words
        if head and head[0] in ("local", "readonly", "export", "declare", "typeset"):
            head = [w for w in head[1:] if not w.startswith("-")]
        if head and all(ASSIGN_RE.match(w) for w in head):
            for w in head:
                name, value = ASSIGN_RE.match(w).groups()
                assigns.setdefault(name, []).append(value)
            continue
        if len(words) > 3 and words[0] == "for" and words[2] == "in":
            assigns.setdefault(words[1], []).extend(words[3:])
            continue
        rest = _strip_prefix(words)
        while rest:
            relation = CALL_WORDS.get(BASH_WORDS.get(rest[0], rest[0]))
            if relation is None:
                if _unquote(rest[0]).endswith(SHELL_EXT):
                    calls.append(("calls", rest[0], line))
                break
            args = rest[1:]
            while args and args[0][:1] in "-+" and args[0] != "-c":
                args = args[2 if args[0] in ("-o", "+o", "-O", "+O", "-a") else 1:]
            if not args or args[0] == "-c":
                break
            if rest[0] == "exec" and args[0] in CALL_WORDS:
                rest = args
                continue
            calls.append((relation, args[0], line))
            break
    return assigns, calls


def find_shell_edges(nodes, root):
    """(edges, unresolved) over every shell file node whose file is readable
    under root."""
    by_path = {}
    for node_id, node in nodes.items():
        if is_shell_file_node(node):
            by_path[node["source_file"]] = node_id
    edges = []
    unresolved = 0
    for sf, src_id in sorted(by_path.items()):
        try:
            with open(os.path.join(root, sf), "r", encoding="utf-8", errors="replace") as f:
                src = f.read()
        except OSError:
            continue
        assigns, calls = scan_file(src)
        resolver = _Resolver(sf, assigns)
        for relation, word, line in calls:
            targets = {}
            for t in resolver.word(word):
                tgt_id = by_path.get(t[len(ROOT) + 1:])
                if tgt_id is not None:
                    targets[tgt_id] = targets.get(tgt_id) or t.startswith(ROOT + "/")
            if not targets:
                unresolved += 1
            for tgt_id in sorted(set(targets) - {src_id}):
                extracted = targets[tgt_id]
                edges.append(
                    {
                        "source": src_id,
                        "target": tgt_id,
                        "relation": relation,
                        "confidence": "EXTRACTED" if extracted else "INFERRED",
                        "confidence_score": 1.0 if extracted else 0.8,
                        "source_file": sf,
                        "source_location": f"L{line}",
                        "weight": 1.0,
                        "hardened": "shell-call",
                    }
                )
    return edges, unresolved
