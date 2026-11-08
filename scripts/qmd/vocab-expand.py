#!/usr/bin/env python3
"""vocab-expand.py -- bridge the old and new fleet vocabularies in a retrieval question.

The rename registry (scripts/lib/rename-aliases.tsv) pairs each old word with its new one
(console/chief, leg/worker, wave/parallel wave, ...). Docs use both, so a question in one
vocabulary misses the docs written in the other. This turns the question into a qmd query
document that asks it in both:

  doc query|search <question>
      Prints the query document: "lex: <question>", one "lex:" line per vocabulary swap
      (every old word to its new one, every new word to its old one) and, for query, a
      "vec: <question>" line. Each leg is shaped first: the lex lines drop filler words
      (shape_lex) and the vec line drops a leading dash word (shape_vec), which qmd rejects
      in a vec query. Prints the question unchanged when no leg changes, it is already a
      query document, or it holds what a lex line rejects (an odd number of double quotes).

  argv <verb> <arg>...
      Prints the qmd argv, NUL-separated: the question (every positional) replaced by the
      document. search is lex-only and qmd search reads no document, so an expanded search
      runs as query with --no-rerank appended: lex lines only, no model call. A verb other
      than query or search, or a question that does not expand, prints the argv unchanged.

Fails open: an unreadable registry expands nothing.
ponytail: whole-word swaps from the registry, no stemming beyond a plural s; a word used in
another sense ("lane worker") is swapped too, which only adds a lex line, never drops one.
"""
import re
import sys
from pathlib import Path

REGISTRY = Path(__file__).resolve().parent.parent / "lib" / "rename-aliases.tsv"
PREFIXES = ("lex:", "vec:", "hyde:", "intent:", "expand:")
STRING_OPTS = {
    "index", "context", "n", "min-score", "format", "collection", "filter", "match", "key-limit",
    "key-offset", "value-limit", "value-offset", "sort", "min-count", "name", "mask", "glob",
    "max-docs-per-batch", "max-batch-mb", "timeout", "l", "from", "max-bytes", "candidate-limit",
    "intent", "chunk-strategy", "port", "host",
}
SHORT_STRING = set("cCnl")
NEGATION = re.compile(r'(^|\s)-[\w"]')
# ponytail: one fixed English list, no per-corpus tuning; grow it from a miss.
STOPWORDS = frozenset(
    "a an the is are was were be been being do does did how what why when where who whom whose which "
    "of to in on at for from by with about into and or it its this that these those can could should "
    "would will there here as if than then i we you they he she me my our your their".split()
)


def shape_lex(question):
    """question for a lex leg: filler words dropped, "quoted phrases" and every other token kept.
    A question of only filler words stays whole."""
    toks = re.findall(r'[^\s"]*"[^"]*"[^\s"]*|\S+', question)
    keep = [t for t in toks if '"' in t or t.strip("?,.;:!()").lower() not in STOPWORDS]
    return " ".join(keep) if keep else question


def shape_vec(question):
    """question for a vec leg: a leading dash word dropped (qmd rejects the whole vec query holding
    one, see validateSemanticQuery); "" when nothing is left."""
    return " ".join(t for t in question.split() if not NEGATION.match(t))


def rows(path=REGISTRY):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        cols = line.split("\t")
        if len(cols) == 6 and not line.startswith("#") and cols[0] != "old":
            out.append(cols)
    return out


def pairs(path=REGISTRY):
    """(old, new) word pairs, lowercase: prose rows as is, env, prefix and marker rows by the one word they swap."""
    seen = []
    for old, new, kind, *_ in rows(path):
        if kind == "prose":
            pair = (old.lower(), new.lower())
        elif kind in ("env", "env-prefix", "marker") and new not in (old, "pending-N2892"):
            o = [w for w in re.split(r"[_-]", old.lower()) if w]
            n = [w for w in re.split(r"[_-]", new.lower()) if w]
            while o and n and o[0] == n[0]:
                o, n = o[1:], n[1:]
            while o and n and o[-1] == n[-1]:
                o, n = o[:-1], n[:-1]
            if len(o) != 1 or len(n) != 1:
                continue
            pair = (o[0], n[0])
        else:
            continue
        if pair not in seen:
            seen.append(pair)
    return seen


def other_sense(path=REGISTRY):
    """Names that already use a new word in another sense: retrieval never aliases them."""
    return {old for old, _, kind, *_ in rows(path) if kind == "other-sense"}


def swap(text, direction, prs=None):
    """text with every old word made new (to-new) or every new word made old (to-old), in one pass."""
    prs = pairs() if prs is None else prs
    if not prs:
        return text
    target = {}
    for old, new in prs:
        if direction == "to-new":
            target.setdefault(old, new)
            target.setdefault(new, new)
        else:
            if new not in target or len(old) < len(target[new]):
                target[new] = old
            target[old] = old
    alt = "|".join(re.escape(w) for w in sorted(target, key=len, reverse=True))
    rx = re.compile(r"\b(" + alt + r")(s?)\b", re.IGNORECASE)

    def sub(m):
        word = target[m.group(1).lower()]
        if m.group(1)[0].isupper():
            word = word[0].upper() + word[1:]
        return word + m.group(2)

    return rx.sub(sub, text)


def document(verb, question, prs=None):
    """The query document for question, or question itself when it does not expand."""
    if "\n" in question or question.lstrip().lower().startswith(PREFIXES):
        return question
    if question.count('"') % 2:
        return question
    lex = shape_lex(question)
    lines = [lex]
    for direction in ("to-new", "to-old"):
        alt = swap(lex, direction, prs)
        if alt not in lines:
            lines.append(alt)
    vec = shape_vec(question) if verb == "query" else question
    if lines == [question] and vec == question:
        return question
    doc = [f"lex: {line}" for line in lines]
    if verb == "query" and vec:
        doc.append(f"vec: {vec}")
    return "\n".join(doc)


def argv(verb, args, prs=None):
    """The qmd argv with the question expanded; unchanged when nothing expands."""
    if verb not in ("query", "search"):
        return [verb, *args]
    flags, positional, take, i = [], [], False, 0
    while i < len(args):
        a = args[i]
        if take:
            flags.append(a)
            take = False
        elif a == "--":
            positional.extend(args[i + 1:])
            break
        elif a.startswith("--"):
            flags.append(a)
            take = "=" not in a and a[2:] in STRING_OPTS
        elif a.startswith("-") and len(a) > 1:
            flags.append(a)
            for j, c in enumerate(a[1:], 1):
                if c in SHORT_STRING:
                    take = j == len(a) - 1
                    break
        else:
            positional.append(a)
        i += 1
    if not positional:
        return [verb, *args]
    question = " ".join(positional)
    doc = document(verb, question, prs)
    if doc == question:
        return [verb, *args]
    if verb == "search":
        return ["query", *flags, "--no-rerank", "--", doc]
    return ["query", *flags, "--", doc]


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "doc" and sys.argv[2] in ("query", "search"):
        print(document(sys.argv[2], sys.argv[3]))
        return 0
    if len(sys.argv) >= 3 and sys.argv[1] == "argv":
        sys.stdout.write("".join(a + "\0" for a in argv(sys.argv[2], sys.argv[3:])))
        return 0
    print("usage: vocab-expand.py doc query|search <question> | argv <verb> <arg>...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
