#!/usr/bin/env bash
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 1
fails=0
checked=0

while IFS= read -r f; do
    [ -n "$f" ] || continue
    tools="$(awk 'NR == 1 { if ($0 != "---") exit; next } /^---$/ { exit } /^tools:/ { n++; t = $0 } END { if (n == 1) print t; else if (n > 1) print "MULTI" }' "$f")"
    [ -n "$tools" ] || { echo "ok - $f has no tools: line (inherits every tool)"; continue; }
    checked=$((checked + 1))
    has_fetch=0
    has_search=0
    case ", $tools," in *", WebFetch,"*) has_fetch=1 ;; esac
    case ", $tools," in *", WebSearch,"*) has_search=1 ;; esac
    if [ "$has_fetch" -eq 1 ] && [ "$has_search" -eq 1 ]; then
        echo "ok - R1 $f names WebFetch and WebSearch"
    else
        echo "FAIL - R1 $f tools line lacks WebFetch and WebSearch: [$tools]"
        fails=$((fails + 1))
    fi
done < <(git ls-files '.claude/agents/*.md' 'marketplace/plugins/*/agents/*.md')

if [ "$checked" -eq 0 ]; then
    echo "FAIL - R1 no agent file with a tools: line was found"
    fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
    echo "$fails failed"
    exit 1
fi
echo "all passed ($checked agent files)"
