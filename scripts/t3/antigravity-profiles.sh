#!/usr/bin/env bash
# scripts/t3/antigravity-profiles.sh - give T3 Code an Antigravity provider instance per himmel
# profile (antigravity_<name>), with a private agy home that already has the himmel hooks and a
# skills.json pointing at the profile's plugin skills.
#
# Usage: antigravity-profiles.sh [--dry-run | --apply | --check | --list] [--profile <name>]...
#   --list     print the registry's profile names, one per line, and nothing else. rc 2 on a malformed
#              registry or a profile named relay or ending _relay (a relay copy id would collide).
#   --dry-run  (default) print, per profile, the instance id, home, whether the himmel backstop
#              hooks are present and the skills.json that --apply would write. Creates, fetches
#              and writes nothing.
#   --apply    for each profile, in this order: create the home (mode 700), run the hook backstop
#              installer, verify its himmel-antigravity-backstop key is in <home>/config/hooks.json,
#              and only then write <home>/config/skills.json (a regular file, mode 600). Missing
#              pinned skill checkouts are fetched into the cache first. No other file in the home
#              is created, changed or deleted.
#   --check    rc 0 iff every selected profile's home has the backstop key and a regular-file
#              skills.json equal to what --apply would write now. Writes and fetches nothing.
#   --profile  limit to one registry profile (repeatable); default is every profile.
# Home: ${T3CODE_HOME:-$HOME/.t3}/userdata/providers/antigravity/<sha256 hex of the instance id>.
# Every skills.json entry path is a canonical directory. One that resolves under
# <T3 home>/userdata/providers/antigravity, or has a path segment starting /.agents or /.gemini, is
# refused (the himmel read fence and hook adapter deny those).
# rc 0 ok; rc 1 --check not satisfied; rc 2 usage / missing jq / malformed registry or JSON input /
# unknown fromProfile / pinned fetch or verify failure / backstop failure; rc 3 fence refusal
# (nothing written).
# Env seams (tests): T3_AP_REGISTRY (registry; default antigravity-profiles.json beside this
# script), T3_AP_PLUGIN_PROFILES (default scripts/lanes/plugin-profiles.json), T3_AP_BACKSTOP
# (backstop command; default scripts/antigravity/install-antigravity-backstop.sh),
# HIMMEL_AGY_SKILL_CACHE (default $HOME/.himmel/cache/agy-skills). HOME and T3CODE_HOME as usual.
# Platform: POSIX bash 3.2+, jq, git (--apply fetches pinned skills).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
REGISTRY="${T3_AP_REGISTRY:-$HERE/antigravity-profiles.json}"
PLUGIN_PROFILES="${T3_AP_PLUGIN_PROFILES:-$REPO_ROOT/scripts/lanes/plugin-profiles.json}"
BACKSTOP="${T3_AP_BACKSTOP:-$REPO_ROOT/scripts/antigravity/install-antigravity-backstop.sh}"
CACHE_ROOT="${HIMMEL_AGY_SKILL_CACHE:-$HOME/.himmel/cache/agy-skills}"
T3_HOME="${T3CODE_HOME:-$HOME/.t3}"
INSTALLED_PLUGINS="$HOME/.claude/plugins/installed_plugins.json"
KNOWN_MARKETPLACES="$HOME/.claude/plugins/known_marketplaces.json"
BACKSTOP_KEY="himmel-antigravity-backstop"
SPEC_NORM='if type == "string" then [.] elif type == "array" then map(select(type == "string")) else empty end'
die() { echo "antigravity-profiles: $2" >&2; exit "$1"; }

MODE=""
SELECTED=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|--apply|--check|--list)
            [ -z "$MODE" ] || [ "$MODE" = "${1#--}" ] || die 2 "only one of --dry-run, --apply, --check"
            MODE="${1#--}"; shift ;;
        --profile) [ $# -ge 2 ] || die 2 "--profile needs a name"; SELECTED="$SELECTED $2"; shift 2 ;;
        *) die 2 "usage: antigravity-profiles.sh [--dry-run | --apply | --check | --list] [--profile <name>]... (got '$1')" ;;
    esac
done
MODE="${MODE:-dry-run}"

command -v jq >/dev/null 2>&1 || die 2 "jq is required"
# shellcheck source=../lib/sha256-bin.sh
. "$HERE/../lib/sha256-bin.sh"
[ -n "${_SHA256_CMD:-}" ] || die 2 "no sha256 tool on PATH"
# shellcheck source=../lib/prim.sh
. "$HERE/../lib/prim.sh" || die 2 "cannot load prim.sh"

[ -f "$REGISTRY" ] || die 2 "registry not found: $REGISTRY"
jq -e '(.profiles | type) == "object"' "$REGISTRY" >/dev/null 2>&1 || die 2 "registry is not a JSON object with an object .profiles: $REGISTRY"
if [ "$MODE" = list ]; then
    [ -z "$SELECTED" ] || die 2 "--list takes no --profile"
    names="$(jq -r '.profiles | keys_unsorted[]' "$REGISTRY")" || die 2 "cannot list registry profiles"
    for p in $names; do
        case "$p" in ''|*[!A-Za-z0-9._-]*) die 2 "bad profile name '$p'" ;; esac
        case "$p" in relay|*_relay) die 2 "profile name '$p' is reserved (it collides with a relay copy id)" ;; esac
    done
    [ -z "$names" ] || printf '%s\n' "$names"
    exit 0
fi
[ -f "$PLUGIN_PROFILES" ] || die 2 "plugin profiles not found: $PLUGIN_PROFILES"
jq -e '(.profiles | type) == "object"' "$PLUGIN_PROFILES" >/dev/null 2>&1 || die 2 "plugin profiles is not a JSON object with an object .profiles: $PLUGIN_PROFILES"

ALL="$(jq -r '.profiles | keys_unsorted[]' "$REGISTRY")" || die 2 "cannot list registry profiles"
if [ -z "$SELECTED" ]; then
    SELECTED="$ALL"
else
    for p in $SELECTED; do
        printf '%s\n' "$ALL" | grep -qxF -- "$p" || die 2 "no profile '$p' in $REGISTRY"
    done
fi
for p in $SELECTED; do
    case "$p" in ''|*[!A-Za-z0-9._-]*) die 2 "bad profile name '$p'" ;; esac
done

WORK="$(tmpdir)" || die 2 "cannot create a scratch dir"
trap 'rm -rf "$WORK"' EXIT

canon() {
    local p="$1" rest=""
    while [ ! -e "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do
        rest="/$(basename "$p")$rest"
        p="$(dirname "$p")"
    done
    if [ -d "$p" ]; then
        p="$(cd -P "$p" && pwd -P)" || return 1
    else
        p="$(cd -P "$(dirname "$p")" && pwd -P)/$(basename "$p")" || return 1
    fi
    printf '%s%s' "${p%/}" "$rest"
}

AGY_RAW="${T3_HOME%/}/userdata/providers/antigravity"
AGY_REAL="$(canon "$AGY_RAW")" || die 2 "cannot resolve $AGY_RAW"

fence_check() {
    local raw="$1" real q
    real="$(canon "$raw")" || die 2 "cannot resolve $raw"
    for q in "$raw" "$real"; do
        case "$q/" in
            "$AGY_RAW"/*|"$AGY_REAL"/*)
                echo "antigravity-profiles: REFUSED - $raw resolves under $AGY_REAL (the himmel read fence denies it)" >&2
                exit 3 ;;
        esac
        case "$q" in
            */.agents*|*/.gemini*)
                echo "antigravity-profiles: REFUSED - $raw has a .agents or .gemini path segment (the himmel hook adapter denies it)" >&2
                exit 3 ;;
        esac
    done
}

fence_pairs() {
    local par item
    while IFS="$(printf '\t')" read -r par item; do
        [ -n "$par" ] || continue
        fence_check "$par"
        fence_check "$par/$item"
    done < "$1"
}

install_path() {
    jq -r --arg id "$1" '(.plugins[$id] // []) as $e
        | (($e | map(select(.scope == "user")) | first) // ($e | first) // {}) | .installPath // empty' "$INSTALLED_PLUGINS"
}

skill_specs() {
    local id="$1" ip="$2" name mkt spec="" mloc mf
    name="${id%%@*}"; mkt="${id#*@}"
    if [ -f "$ip/.claude-plugin/plugin.json" ]; then
        spec="$(jq -c "(.skills // empty) | $SPEC_NORM" "$ip/.claude-plugin/plugin.json")" || die 2 "malformed JSON: $ip/.claude-plugin/plugin.json"
    fi
    if [ -z "$spec" ] && [ -f "$KNOWN_MARKETPLACES" ]; then
        mloc="$(jq -r --arg m "$mkt" '.[$m].installLocation // empty' "$KNOWN_MARKETPLACES")" || die 2 "malformed JSON: $KNOWN_MARKETPLACES"
        mf="$mloc/.claude-plugin/marketplace.json"
        if [ -n "$mloc" ] && [ -f "$mf" ]; then
            spec="$(jq -c --arg n "$name" "[.plugins[]? | select(.name == \$n)] | first | (.skills // empty) | $SPEC_NORM" "$mf")" || die 2 "malformed JSON: $mf"
        fi
    fi
    [ -n "$spec" ] || spec='["./skills"]'
    printf '%s' "$spec" | jq -r '.[]'
}

add_skill_dirs() {
    local out="$1" spec="$2" ip="$3" rel d dc c
    case "$spec" in /*) return 0 ;; esac
    rel="${spec#./}"; [ "$rel" = "." ] && rel=""; rel="${rel%/}"
    case "/$rel/" in */../*) echo "antigravity-profiles: skip skill path '$spec': outside the plugin" >&2; return 0 ;; esac
    d="$ip"; [ -z "$rel" ] || d="$ip/$rel"
    [ -d "$d" ] || return 0
    dc="$(cd -P "$d" && pwd -P)" || return 0
    if [ -f "$dc/SKILL.md" ]; then
        printf '%s\t%s\n' "$(dirname "$dc")" "$(basename "$dc")" >> "$out"
        return 0
    fi
    for c in "$dc"/*; do
        [ -d "$c" ] && [ -f "$c/SKILL.md" ] || continue
        printf '%s\t%s\n' "$dc" "$(basename "$c")" >> "$out"
    done
}

resolve_plugins() {
    local p="$1" out="$2" froms f ids id ip spec
    froms="$(jq -c --arg p "$p" '.profiles[$p].fromProfiles // []' "$REGISTRY")" || die 2 "malformed fromProfiles for '$p'"
    for f in $(printf '%s' "$froms" | jq -r '.[]'); do
        jq -e --arg f "$f" '.profiles | has($f)' "$PLUGIN_PROFILES" >/dev/null 2>&1 || die 2 "profile '$p': unknown fromProfile '$f' (not in $PLUGIN_PROFILES)"
    done
    ids="$(jq -r --argjson froms "$froms" '. as $d | [$froms[] | $d.profiles[.].enable // []] | add // []
        | reduce .[] as $x ([]; if index($x) then . else . + [$x] end) | .[]' "$PLUGIN_PROFILES")" || die 2 "malformed plugin profiles: $PLUGIN_PROFILES"
    : > "$out"
    for id in $ids; do
        ip=""
        if [ -f "$INSTALLED_PLUGINS" ]; then
            ip="$(install_path "$id")" || die 2 "malformed JSON: $INSTALLED_PLUGINS"
        fi
        case "$ip" in /*) ;; *) ip="" ;; esac
        if [ -z "$ip" ]; then echo "antigravity-profiles: skip plugin '$id': not installed" >&2; continue; fi
        if [ ! -d "$ip" ]; then echo "antigravity-profiles: skip plugin '$id': install path missing: $ip" >&2; continue; fi
        skill_specs "$id" "$ip" > "$WORK/specs"
        while IFS= read -r spec; do
            add_skill_dirs "$out" "$spec" "$ip"
        done < "$WORK/specs"
    done
}

fetch_pin() {
    local repo="$1" commit="$2" dir="$3" tmp
    mkdir -p "$CACHE_ROOT" || die 2 "cannot create $CACHE_ROOT"
    # prim-ok: sibling of the cache dir so the rename into place stays on one filesystem
    tmp="$(mktemp -d "$CACHE_ROOT/.fetch.XXXXXX")" || die 2 "cannot create a temp dir in $CACHE_ROOT"
    if ! { git -C "$tmp" init -q && GIT_TERMINAL_PROMPT=0 git -C "$tmp" fetch -q --depth 1 "$repo" "$commit" && git -C "$tmp" checkout -q FETCH_HEAD; } >"$WORK/git.out" 2>&1; then
        cat "$WORK/git.out" >&2
        rm -rf "$tmp"
        die 2 "cannot fetch $repo@$commit"
    fi
    if [ -e "$dir" ]; then
        rm -rf "$tmp"
    else
        # prim-ok: rename of a private temp checkout into a path that does not exist yet
        mv "$tmp" "$dir" || { rm -rf "$tmp"; die 2 "cannot move the fetched checkout into $dir"; }
    fi
}

resolve_pins() {
    local p="$1" out="$2" notes="$3" US row repo commit rpath names dir name n
    US="$(printf '\037')"
    n="$(jq -r --arg p "$p" '(.profiles[$p].pinnedSkills // []) | length' "$REGISTRY")" || die 2 "malformed pinnedSkills for '$p'"
    local i=0
    while [ "$i" -lt "$n" ]; do
        row="$(jq -r --arg p "$p" --argjson i "$i" '.profiles[$p].pinnedSkills[$i]
            | [.repo, .commit, .path, (.include | join(","))] | join("\u001f")' "$REGISTRY")" || die 2 "malformed pinnedSkills[$i] for '$p'"
        IFS="$US" read -r repo commit rpath names <<EOF
$row
EOF
        i=$((i+1))
        [ -n "$repo" ] && [ -n "$rpath" ] && [ -n "$names" ] || die 2 "profile '$p': pinnedSkills[$((i-1))] needs repo, commit, path and include"
        printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$' || die 2 "profile '$p': pin commit must be a full 40-hex sha: $commit"
        case "/$rpath/" in */../*|//*) die 2 "profile '$p': pin path must be relative without '..': $rpath" ;; esac
        dir="$CACHE_ROOT/$(basename "$repo" .git)@$commit"
        fence_check "$dir"
        if [ ! -d "$dir" ]; then
            if [ "$MODE" = apply ]; then
                fetch_pin "$repo" "$commit" "$dir"
            else
                printf 'would fetch %s@%s -> %s\n' "$repo" "$commit" "$dir" >> "$notes"
                for name in $(printf '%s' "$names" | tr ',' ' '); do
                    printf '%s\t%s\n' "$dir/$rpath" "$name" >> "$out"
                done
                continue
            fi
        fi
        [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ] || die 2 "pinned checkout $dir is not at $commit"
        [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] || die 2 "pinned checkout $dir has local changes"
        for name in $(printf '%s' "$names" | tr ',' ' '); do
            case "$name" in ''|*[!A-Za-z0-9._-]*) die 2 "profile '$p': bad pinned skill name '$name'" ;; esac
            [ -f "$dir/$rpath/$name/SKILL.md" ] || die 2 "pinned skill '$name' has no SKILL.md under $dir/$rpath"
            printf '%s\t%s\n' "$(cd -P "$dir/$rpath" && pwd -P)" "$name" >> "$out"
        done
    done
}

build_skills_json() {
    jq -R -s -S 'split("\n") | map(select(length > 0) | split("\t"))
        | group_by(.[0]) | map({path: .[0][0], include_only: (map(.[1]) | unique)})
        | {entries: sort_by(.path)}' "$1"
}

hooks_present() { jq -e --arg k "$BACKSTOP_KEY" '(.[$k] | type) == "object"' "$1/config/hooks.json" >/dev/null 2>&1; }

for p in $SELECTED; do
    resolve_plugins "$p" "$WORK/$p.pairs"
    fence_pairs "$WORK/$p.pairs"
    : > "$WORK/$p.notes"
    resolve_pins "$p" "$WORK/$p.pairs" "$WORK/$p.notes"
    fence_pairs "$WORK/$p.pairs"
    build_skills_json "$WORK/$p.pairs" > "$WORK/$p.skills.json" || die 2 "cannot build skills.json for '$p'"
done

RC=0
for p in $SELECTED; do
    id="antigravity_$p"
    hex="$(printf '%s' "$id" | sha256_hex)" || die 2 "sha256 failed"
    home="$AGY_RAW/$hex"
    cur="$home/config/skills.json"
    new="$WORK/$p.skills.json"
    case "$MODE" in
        dry-run)
            hooks=absent; hooks_present "$home" && hooks=present
            printf '== %s\nhome: %s\nhooks: backstop %s\n' "$id" "$home" "$hooks"
            cat "$WORK/$p.notes"
            printf 'skills.json (%s):\n' "$cur"
            cat "$new"
            ;;
        check)
            why=""
            [ -d "$home" ] || why="$why; home missing"
            if [ -L "$home" ] || [ -L "$home/config" ]; then why="$why; home or its config dir is a symlink"; fi
            hooks_present "$home" || why="$why; hooks.json lacks $BACKSTOP_KEY"
            [ -s "$WORK/$p.notes" ] && why="$why; pinned checkout not fetched"
            if [ ! -f "$cur" ] || [ -L "$cur" ]; then
                why="$why; skills.json is not a regular file"
            elif ! cmp -s "$new" "$cur"; then
                why="$why; skills.json differs from what apply would write"
            fi
            if [ -z "$why" ]; then echo "OK $id"; else echo "NOT OK $id${why}"; RC=1; fi
            ;;
        apply)
            [ ! -L "$home" ] && [ ! -L "$home/config" ] || die 2 "$home or its config dir is a symlink; refusing"
            if ! mkdir -p "$home" || ! chmod 700 "$home"; then die 2 "cannot create $home"; fi
            "$BACKSTOP" > "$WORK/backstop.out" 2>&1 || { cat "$WORK/backstop.out" >&2; die 2 "backstop installer failed; skills.json not written for $id"; }
            hooks_present "$home" || die 2 "$home/config/hooks.json has no $BACKSTOP_KEY after the backstop ran; skills.json not written for $id"
            if [ -f "$cur" ] && [ ! -L "$cur" ] && cmp -s "$new" "$cur"; then
                echo "UNCHANGED $cur"
            else
                atomic_write "$cur" < "$new" || die 2 "cannot write $cur"
                echo "WROTE $cur"
            fi
            ;;
    esac
done
exit "$RC"
