# comment-count.awk — the classifier behind scripts/lint/check-new-comments.sh.
#
#   awk -f comment-count.awk -v mode=count|list [-v ranges=<a>:<n>,<a>:<n>] -v path=<name> <file>
#   awk -f comment-count.awk -v mode=tree <file>...
#
# count  prints one integer: the comment lines of <file> outside the keep list.
# list   prints `path:line: text` for each such line; with ranges, only lines inside
#        a range (first line a, n lines) are printed.
# tree   prints `path<TAB>count` for every input file whose count is above zero.
# path   names the file when the content arrives on stdin or under another name.
#
# A comment line is a whole-line `#` or `//` comment, a line of a `/* */` block, or a
# trailing comment after code. Kept, so never counted (docs/internals/code-comments.md):
#   the leading comment block of a file, before its first code line
#   a license or copyright line
#   a lint suppression directive
#   a comment carrying an http(s) link
#   a `/** */` doc block
# Detection is line-based: a heredoc body and a Python triple-quoted string are skipped,
# a `#` inside any other multi-line string is not.

function is_js(p) { return p ~ /\.(js|mjs|cjs|ts|tsx|mts|cts)$/ }

function ltrim(s) { sub(/^[ \t]+/, "", s); return s }

function regex_end(s, i, n,   before, j, c, cls) {
    before = substr(s, 1, i - 1)
    sub(/[ \t]+$/, "", before)
    if (before != "" && before !~ /[(,=:\[!&|?{};+*%<>~^-]$/) return 0
    for (j = i + 1; j <= n; j++) {
        c = substr(s, j, 1)
        if (c == "\\") { j++; continue }
        if (c == "[") cls = 1
        else if (c == "]") cls = 0
        else if (c == "/" && !cls) return j
    }
    return 0
}

function comment_start(s, kind,   i, c, q, n, prev, js, j) {
    js = (kind == "js")
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && q != sq) { i++; continue }
        if (q != "") { if (c == q) q = ""; continue }
        if (c == sq || c == "\"" || (c == "`" && js)) { q = c; continue }
        prev = substr(s, i - 1, 1)
        if (js) {
            if (c != "/") continue
            if (substr(s, i + 1, 1) == "/" || substr(s, i + 1, 1) == "*") return i
            j = regex_end(s, i, n)
            if (j) i = j
            continue
        }
        if (c == "#" && (kind == "py" || i == 1 || prev ~ /[ \t;&|]/)) return i
    }
    return 0
}

function kept(c,   l) {
    l = tolower(c)
    if (l ~ /https?:\/\//) return 1
    if (l ~ /copyright|spdx-license-identifier|licensed under|license:/) return 1
    if (l ~ /shellcheck (disable|source|shell|enable)=|eslint-(disable|enable)|prettier-ignore|biome-ignore|@ts-(ignore|expect-error|nocheck)|noqa|type: ignore|pylint: (disable|enable)|pragma: no cover/) return 1
    if (l ~ /(^|[^a-z0-9-])[a-z][a-z0-9-]*-ok:/) return 1
    return 0
}

function heredoc_tag(t,   i, c, q, n, r, depth) {
    n = length(t)
    for (i = 1; i <= n; i++) {
        c = substr(t, i, 1)
        if (c == "\\" && q != sq) { i++; continue }
        if (q == "\"" && c == "$" && substr(t, i + 1, 1) == "(") { q = ""; depth = 1; i++; continue }
        if (q != "") { if (c == q) q = ""; continue }
        if (depth && c == "(") depth++
        if (depth && c == ")" && --depth == 0) { q = "\""; continue }
        if (c == sq || c == "\"") { q = c; continue }
        if (c == "#" && (i == 1 || substr(t, i - 1, 1) ~ /[ \t;&|]/)) return ""
        if (c != "<" || substr(t, i + 1, 1) != "<") continue
        if (substr(t, i + 2, 1) == "<") { i += 2; continue }
        r = substr(t, i)
        if (match(r, /^<<-?[ \t]*["\\']?[A-Za-z_][A-Za-z0-9_]*/)) {
            r = substr(r, 1, RLENGTH)
            sub(/^<<-?[ \t]*["\\']?/, "", r)
            return r
        }
        i++
    }
    return ""
}

function triple_open(s,   i, c, n, d, e) {
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c != sq && c != "\"") continue
        d = substr(s, i, 3)
        if (d == c c c) {
            e = index(substr(s, i + 3), d)
            if (!e) return d
            i += e + 4
            continue
        }
        for (i++; i <= n; i++) {
            if (substr(s, i, 1) == "\\") i++
            else if (substr(s, i, 1) == c) break
        }
    }
    return ""
}

function triple_toggles(s, d,   n, rest) {
    n = 0; rest = s
    while (index(rest, d)) { n++; rest = substr(rest, index(rest, d) + 3) }
    return n % 2
}

function counted(p, t,   s, i, js, c, code, e) {
    s = ltrim(t)
    js = is_js(p)
    if (FNR == 1 && s ~ /^#!/) return ""
    if (js) {
        if (blk) {
            e = index(t, "*/")
            if (e) { blk = 0; if (ltrim(substr(t, e + 2)) != "") header = 0 }
            c = s
            if (blkdoc) return ""
        } else if (s ~ /^\/\//) {
            c = s
        } else {
            i = comment_start(t, "js")
            if (i == 0) { if (s != "") header = 0; return "" }
            c = substr(t, i)
            if (substr(c, 1, 2) == "/*") {
                blkdoc = (substr(c, 1, 3) == "/**")
                e = index(substr(c, 3), "*/")
                if (!e) blk = 1
                else if (ltrim(substr(c, e + 4)) != "") header = 0
                if (blkdoc) { if (i > 1 && ltrim(substr(t, 1, i - 1)) != "") header = 0; return "" }
            }
            if (ltrim(substr(t, 1, i - 1)) != "") header = 0
        }
    } else {
        if (heredoc != "") {
            if (s == heredoc || t == heredoc) heredoc = ""
            return ""
        }
        if (p ~ /\.py$/) {
            if (pydoc != "") {
                if (triple_toggles(t, pydoc)) pydoc = ""
                return ""
            }
            i = comment_start(t, "py")
            code = i ? substr(t, 1, i - 1) : t
            pydoc = triple_open(code)
            if (pydoc != "") { header = 0; return "" }
        }
        if (s ~ /^#/) {
            c = s
        } else {
            if (s != "") header = 0
            if (p !~ /\.py$/ && !index(t, "((")) heredoc = heredoc_tag(t)
            i = comment_start(t, (p ~ /\.py$/) ? "py" : "sh")
            if (i == 0) return ""
            c = substr(t, i)
        }
    }
    if (header) return ""
    if (kept(c)) return ""
    return c
}

function in_ranges(n,   i) {
    if (nr == 0) return 1
    for (i = 1; i <= nr; i++) if (n >= ra[i] && n < ra[i] + rn[i]) return 1
    return 0
}

function flush() {
    if (mode == "tree" && cur != "" && cnt > 0) printf "%s\t%d\n", cur, cnt
}

BEGIN {
    sq = sprintf("%c", 39)
    if (mode != "count" && mode != "list" && mode != "tree") {
        print "comment-count.awk: mode must be count, list or tree" > "/dev/stderr"
        failed = 2
        exit 2
    }
    nr = 0
    if (ranges != "") {
        m = split(ranges, parts, ",")
        for (k = 1; k <= m; k++) {
            split(parts[k], ab, ":")
            nr++; ra[nr] = ab[1] + 0; rn[nr] = ab[2] + 0
        }
    }
}

FNR == 1 {
    flush()
    cur = (mode == "tree" || path == "") ? FILENAME : path
    cnt = 0; header = 1; blk = 0; blkdoc = 0; heredoc = ""; pydoc = ""
}

{
    c = counted(cur, $0)
    if (c == "") next
    cnt++
    if (mode == "list" && in_ranges(FNR)) printf "%s:%d: %s\n", cur, FNR, c
}

END {
    if (failed) exit failed
    flush()
    if (mode == "count") print cnt + 0
}
