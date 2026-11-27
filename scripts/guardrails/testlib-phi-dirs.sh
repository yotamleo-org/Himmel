#!/usr/bin/env bash
# scripts/guardrails/testlib-phi-dirs.sh — builds the fixture states of
# phi-dir-cases.tsv under a fixture HOME, for the resolver suite and every
# reader suite. Sourced; it sets no shell option.
#
#   phi_dirs_cases                      print the case ids
#   phi_dirs_expect <id> <column>       print one cell of the table
#   phi_dirs_build <id> <fixture home>  build the state; refuses the real HOME
#   phi_dirs_enter <id> <fixture home>  in a SUBSHELL: set HOME and the override,
#                                       cd to the row's working directory (C22
#                                       locks it)
#   phi_dirs_restore <fixture home>     put modes back so rm -rf can clean up
#
# Under the fixture HOME, R is phi-root-fixture and the "other root" is
# phi-other-root.

case "${BASH_SOURCE[0]}" in
    */*) PHI_DIRS_TSV="${BASH_SOURCE[0]%/*}/phi-dir-cases.tsv" ;;
    *) PHI_DIRS_TSV="./phi-dir-cases.tsv" ;;
esac
case "$PHI_DIRS_TSV" in /*) : ;; *) PHI_DIRS_TSV="$PWD/$PHI_DIRS_TSV" ;; esac

if command -v getent >/dev/null 2>&1; then
    PHI_DIRS_REAL_HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)" || PHI_DIRS_REAL_HOME=""
else
    PHI_DIRS_REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')" || PHI_DIRS_REAL_HOME=""
fi

phi_dirs_cases() {
    awk -F '\t' 'NR > 1 && $1 != "" { print $1 }' "$PHI_DIRS_TSV"
}

phi_dirs_expect() {
    awk -F '\t' -v id="$1" -v col="$2" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == col) c = i; next }
        $1 == id && c { print $c; found = 1 }
        END { exit !found }' "$PHI_DIRS_TSV"
}

_phi_dirs_safe_target() {
    local t="$1" up rest="" canon real
    if [ -z "$PHI_DIRS_REAL_HOME" ]; then
        echo "phi_dirs: no real HOME on record, refusing" >&2
        return 1
    fi
    if [ -z "$t" ]; then
        echo "phi_dirs: no fixture HOME given, refusing" >&2
        return 1
    fi
    case "/$t/" in
        */../*) echo "phi_dirs: '..' in the fixture HOME, refusing" >&2; return 1 ;;
    esac
    up="$t"
    while [ ! -d "$up" ]; do
        rest="/${up##*/}$rest"
        case "$up" in
            */*) up="${up%/*}"; [ -n "$up" ] || up=/ ;;
            *) up=. ;;
        esac
    done
    canon="$(cd -P -- "$up" && pwd -P)" || return 1
    canon="${canon%/}$rest"
    real="$(cd -P -- "$PHI_DIRS_REAL_HOME" 2>/dev/null && pwd -P)" || real="$PHI_DIRS_REAL_HOME"
    case "$canon/" in
        "${real%/}"/*) echo "phi_dirs: $t is the real HOME or under it, refusing" >&2; return 1 ;;
    esac
}

_phi_dirs_list() {
    mkdir -p "${1%/*}" && printf '%s\n' "$2" > "$1"
}

phi_dirs_build() {
    local id="$1" h="$2" c n d o lane root other p
    _phi_dirs_safe_target "$h" || return 1
    for p in "$h/.config" "$h/glm-override" "$h/work"; do
        if [ -e "$p" ] || [ -L "$p" ]; then
            echo "phi_dirs: $p already exists, a build never writes through it, refusing" >&2
            return 1
        fi
    done
    phi_dirs_expect "$id" id >/dev/null || { echo "phi_dirs: unknown case $id" >&2; return 1; }
    c="$h/.config"; n="$c/himmel/phi"; d="$c/claude-glm"; o="$h/glm-override"; lane="$c/claude-codex"
    root="$h/phi-root-fixture"; other="$h/phi-other-root"
    mkdir -p "$root" "$other" || return 1
    case "$id" in
        C1) _phi_dirs_list "$n/phi-roots" "$root" ;;
        C2) _phi_dirs_list "$n/egress-denylist" "$root" ;;
        C3) _phi_dirs_list "$d/phi-roots" "$root" ;;
        C4) _phi_dirs_list "$o/phi-roots" "$root" ;;
        C5) _phi_dirs_list "$d/phi-roots" "$root" && mkdir -p "$o" ;;
        C6) _phi_dirs_list "$n/phi-roots" "$other" && _phi_dirs_list "$d/phi-roots" "$other" ;;
        C7) : ;;
        C8) mkdir -p "$n" && chmod 000 "$n" ;;
        C9) mkdir -p "$n" && chmod 000 "$c/himmel" ;;
        C10) mkdir -p "$n" && ln -s "$h/nowhere" "$n/phi-roots" ;;
        C11) mkdir -p "$n/phi-roots" ;;
        C12) _phi_dirs_list "$n/phi-roots" "$root" && chmod 000 "$n/phi-roots" ;;
        C13) mkdir -p "$d" && chmod 000 "$d" ;;
        C14) mkdir -p "$n" "$d" && chmod 000 "$c" ;;
        C15) mkdir -p "$c/himmel" && : > "$n" && chmod 755 "$n" ;;
        C16) mkdir -p "$c" && ln -s "$h/nowhere" "$d" ;;
        C17) mkdir -p "$o" && chmod 000 "$o" ;;
        C18) mkdir -p "$n" "$d" ;;
        C19) _phi_dirs_list "$n/phi-roots" "$root" && mkdir -p "$o" ;;
        C20) _phi_dirs_list "$o/phi-roots" "$other" && _phi_dirs_list "$d/phi-roots" "$root" ;;
        C21) mkdir -p "$h/work" ;;
        C22) _phi_dirs_list "$h/work/cfg/phi-roots" "$root" ;;
        C23) _phi_dirs_list "$lane/phi-roots" "$root" && chmod 000 "$lane" ;;
        *) echo "phi_dirs: no builder for $id" >&2; return 1 ;;
    esac
}

phi_dirs_enter() {
    local ov
    ov="$(phi_dirs_expect "$1" override)" || return 1
    export HOME="$2"
    unset CLAUDE_GLM_CONFIG_DIR
    case "$ov" in
        unset) cd "$2" || return 1 ;;
        home:*) export CLAUDE_GLM_CONFIG_DIR="$2/${ov#home:}"; cd "$2" || return 1 ;;
        rel:*) export CLAUDE_GLM_CONFIG_DIR="${ov#rel:}"; cd "$2/work" || return 1 ;;
        *) return 1 ;;
    esac
    if [ "$1" = C22 ]; then chmod 000 . || return 1; fi
}

phi_dirs_restore() {
    local h="$1" p
    _phi_dirs_safe_target "$h" || return 1
    for p in .config .config/himmel .config/himmel/phi .config/himmel/phi/phi-roots \
        .config/claude-glm .config/claude-codex glm-override work work/cfg; do
        if [ -e "$h/$p" ] && [ ! -L "$h/$p" ]; then chmod u+rwX "$h/$p"; fi
    done
    return 0
}
