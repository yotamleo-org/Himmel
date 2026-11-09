# ticket-refs.awk — the one classifier behind the history-comment gate
# (scripts/lint/check-history-comments.sh, modes diff and count) and the hand-run
# whole-tree check (scripts/one-shot/check-ticket-refs.sh, mode tree).
#
#   awk -f ticket-refs.awk -v allow=<rule list> -v mode=diff|count|tree|exempt [-v binlist=<file>] <input>
#
# diff / count  input is a unified diff (-U0); only added lines are judged.
# tree          input is `git grep -n` output, path:line:text.
# exempt        input is one path per line; prints those under a whole-file row
#               (scripts/one-shot/no-markers.sh and harvest-ceilings.py verify).
# allow         scripts/lint/ticket-ref-allow.tsv: kind, path-regex, line-regex, reason.
#               The `key` row owns the ticket-key pattern; every other row exempts the
#               lines it matches. Nothing in this file names a project key.
# binlist       paths (one per line) whose index blob is binary; their lines are skipped.
#
# Exit: 0 clean, 1 findings (diff, tree), 2 cannot evaluate (rule list unreadable).
# Findings print as `path:line: <reason>: <text>` (tree mode: `HIT path:line: <text>`).
# count mode prints one integer: the added comment lines in code files.
#
# Rules, per added line:
#   non-test file  any key is refused unless a rule row covers it.
#   test file      a key is data, except on a whole-line comment and in four citation
#                  shapes: G1 keys in parentheses right before a closing quote, G2 SKIP
#                  or FAIL followed by a key, G3 a quoted message that opens with a key
#                  and a colon, G4 a trailing comment outside every quote.
#   code file      review-round, CR-fix and judge-qid wording is refused on a whole-line
#                  comment (a doc or YAML file is not judged for it).
#   any file       a ponytail marker (the word and a colon, any case) is refused in diff
#                  mode outside a whole-file row: the ceiling goes to the ledger.
# The two ceilings of these rules are the ponytail lines in check-history-comments.sh.

function fatal(msg) {
    print "ticket-refs.awk: " msg > "/dev/stderr"
    failed = 2
    exit 2
}

function is_code(p) {
    return p ~ /\.(sh|bash|zsh|ps1|psm1|py|js|mjs|cjs|ts|tsx|mts|cts)$/
}
function is_js(p) {
    return p ~ /\.(js|mjs|cjs|ts|tsx|mts|cts)$/
}
function is_test(p) {
    return p ~ /(^|\/)(tests?|__tests__)\// || p ~ /(^|\/)test[-_][^\/]*$/ || p ~ /\.(test|spec)\.[^\/]*$/
}

# a row without a line regex exempts its whole file from every refusal
function whole_file_row(p,   i) {
    for (i = 1; i <= nrow; i++)
        if (rl[i] == "" && p ~ rp[i]) return 1
    return 0
}
function row_covers(p, t,   i) {
    for (i = 1; i <= nrow; i++)
        if (p ~ rp[i] && (rl[i] == "" || t ~ rl[i])) return 1
    return 0
}

# Position of the first comment marker outside every quote, 0 if none. A marker only
# counts after whitespace or at the line start, so `$#`, `${#a}` and `a//b` stay code.
# which: 1 = `#`, 2 = `//` (and `/*` in js files), 3 = either.
function comment_start(p, s, which,   i, c, q, n, prev, js) {
    js = is_js(p)
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && q != sq) { i++; continue }
        if (q != "") { if (c == q) q = ""; continue }
        if (c == sq || c == "\"" || (c == "`" && js)) { q = c; continue }
        prev = substr(s, i - 1, 1)
        if (i > 1 && prev !~ /[ \t]/) continue
        if (c == "#" && (which == 1 || which == 3)) return i
        if (c == "/" && (which == 2 || which == 3)) {
            if (substr(s, i + 1, 1) == "/") return i
            if (js && substr(s, i + 1, 1) == "*") return i
        }
    }
    return 0
}

function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
function whole_line_comment(s) {
    s = ltrim(s)
    return (s ~ /^#/ && s !~ /^#!/) || s ~ /^\/\//
}

function g1(t,   rest) {
    rest = t
    while (match(rest, g1re)) {
        if (substr(rest, RSTART, RLENGTH) ~ keyre) return 1
        rest = substr(rest, RSTART + RLENGTH)
    }
    return 0
}
function g2(t,   rest) {
    rest = t
    while (match(rest, /(^|[^A-Za-z0-9])(SKIP|FAIL)[ \t:]+/)) {
        rest = substr(rest, RSTART + RLENGTH)
        if (match(rest, keyre) && RSTART == 1) return 1
    }
    return 0
}
function g3(t,   i, c, rest, m) {
    for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        if (c != sq && c != "\"") continue
        rest = substr(t, i + 1)
        if (match(rest, keyre) && RSTART == 1) {
            m = substr(rest, 1, RLENGTH)
            if (substr(m, RLENGTH, 1) == ":" || substr(rest, RLENGTH + 1, 1) == ":") return 1
        }
    }
    return 0
}
function g4(p, t,   i) {
    i = comment_start(p, t, 3)
    return i > 0 && substr(t, i) ~ keyre
}
function test_citation(p, t) {
    return whole_line_comment(t) || g1(t) || g2(t) || g3(t) || g4(p, t)
}

function key_refused(p, t) {
    if (t !~ keyre) return 0
    if (row_covers(p, t)) return 0
    if (!is_test(p)) return 1
    return test_citation(p, t)
}

function why(t,   l) {
    l = tolower(t)
    if (l ~ /(^|[^a-z0-9])cr fix/) return "CR fix"
    if (l ~ /coderabbit round/) return "CodeRabbit round"
    if (l ~ /(^|[^a-z0-9])round [0-9]+/) return "review round"
    if (l ~ /(^|[^a-z0-9])j[0-9][0-9][0-9][0-9][a-z]([^a-z0-9]|$)/) return "judge qid"
    return ""
}

function judge(p, t,   s, r) {
    if (key_refused(p, t)) return "ticket id"
    if (mode == "diff" && !whole_file_row(p) && t ~ /[Pp][Oo][Nn][Yy][Tt][Aa][Ii][Ll]:/) return "ponytail marker"
    if (mode == "tree" || !is_code(p) || whole_file_row(p)) return ""
    s = ltrim(t)
    if (whole_line_comment(s)) return why(s)
    return ""
}

# Added comment lines in one line of a code file. blk (js block comment) and doc
# (python docstring delimiter) carry across the lines of one hunk.
function count_line(p, t,   s, i, rest) {
    s = ltrim(t)
    if (is_js(p)) {
        if (blk) { if (index(t, "*/")) blk = 0; return 1 }
        if (s ~ /^\/\//) return 1
        i = comment_start(p, t, 2)
        if (i == 0) return 0
        if (substr(t, i, 2) == "/*") { if (!index(substr(t, i + 2), "*/")) blk = 1; return 1 }
        return 1
    }
    if (p ~ /\.py$/ && doc != "") {
        if (index(t, doc)) doc = ""
        return 1
    }
    if (s ~ /^#!/) return 0
    if (s ~ /^#/) return 1
    if (p ~ /\.py$/ && (s ~ /^"""/ || s ~ /^'''/)) {
        doc = substr(s, 1, 3)
        if (index(substr(s, 4), doc)) doc = ""
        return 1
    }
    return comment_start(p, t, 1) > 0
}

BEGIN {
    sq = sprintf("%c", 39)
    g1re = "\\([^()]*\\)[\"" sq "]"
    if (allow == "") fatal("no rule list given")
    nrow = 0
    while ((rc = (getline line < allow)) > 0) {
        if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) continue
        split(line, f, "\t")
        if (f[1] == "key") {
            if (keyre != "") fatal("the rule list has more than one key row")
            keyre = f[3]; continue
        }
        if (f[1] !~ /^K[1-7]$/ || f[2] == "") fatal("malformed rule row: " line)
        nrow++; rp[nrow] = f[2]; rl[nrow] = f[3]
    }
    if (rc < 0) fatal("cannot read the rule list " allow)
    close(allow)
    if (keyre == "") fatal("the rule list has no key row")
    if (binlist != "") {
        while ((getline bp < binlist) > 0) bin[bp] = 1
        close(binlist)
    }
    if (mode != "diff" && mode != "count" && mode != "tree" && mode != "exempt") fatal("mode must be diff, count, tree or exempt")
}

mode == "exempt" {
    if ($0 != "" && whole_file_row($0)) print
    next
}

mode == "tree" {
    if (!match($0, /:[0-9]+:/)) next
    p = substr($0, 1, RSTART - 1)
    n = substr($0, RSTART + 1, RLENGTH - 2)
    t = substr($0, RSTART + RLENGTH)
    if (key_refused(p, t)) { printf "HIT %s:%s: %s\n", p, n, t; bad = 1 }
    next
}

/^\+\+\+ / {
    path = substr($0, 7)
    if ($0 == "+++ /dev/null" || (path in bin)) path = ""
    blk = 0; doc = ""
    next
}
/^@@ / {
    n = $0; sub(/^@@ -[0-9,]+ \+/, "", n); sub(/[ ,].*/, "", n); ln = n + 0
    blk = 0; doc = ""
    next
}
/^\+/ {
    if (path != "") {
        t = substr($0, 2)
        if (mode == "count") {
            if (is_code(path) && !whole_file_row(path)) cnt += count_line(path, t)
        } else {
            r = judge(path, t)
            if (r != "") {
                s = ltrim(t)
                printf "%s:%d: %s: %s\n", path, ln, r, s; bad = 1
            }
        }
    }
    ln++
    next
}

END {
    if (failed) exit failed
    if (mode == "count") { print cnt + 0; exit 0 }
    exit bad ? 1 : 0
}
