#!/usr/bin/env bash
# selector: tree-scan
# Every interactive claude launch site under scripts/ is behind the launch-guard
# check or carries a `launch-guard-ok` marker (launch-site-scan.mjs --guard).
# Platform: POSIX bash 3.2+, node.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCAN="$HERE/launch-site-scan.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/launch-site-guard.XXXXXX")" || exit 1; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"
printf '#!/usr/bin/env bash\nclaude --model x "hi"\n' > "$T/scripts/seed.sh"
printf '#!/usr/bin/env bash\nclaude -p "hi"\n' > "$T/scripts/print.sh"
printf '#!/usr/bin/env bash\nmkdir -p d && claude --model x "hi"\n' > "$T/scripts/mixed.sh"
printf 'import os\nos.system("claude --model x hi")\n' > "$T/scripts/py.py"
printf '#!/usr/bin/env bash\n# launch-guard-ok: probe\nclaude --model x "a"\n' > "$T/scripts/marked.sh"
printf '#!/usr/bin/env bash\n# launch-guard-ok-file: probes\nclaude --model x "a"\nclaude --model y "b"\n' > "$T/scripts/filemarked.sh"

out="$(node "$SCAN" --guard "$T")"; rc=$?
if [ "$rc" -eq 1 ]; then ok "guard_scan_exit_1_when_flagged"; else bad "guard_scan_exit_1_when_flagged rc=$rc"; fi
case "$out" in *seed.sh:2*) ok "guard_scan_flags_seeded_site" ;; *) bad "guard_scan_flags_seeded_site: $out" ;; esac
case "$out" in *print.sh*) bad "guard_scan_skips_print: $out" ;; *) ok "guard_scan_skips_print" ;; esac
case "$out" in *mixed.sh:2*) ok "guard_scan_flags_mixed_print_line" ;; *) bad "guard_scan_flags_mixed_print_line: $out" ;; esac
case "$out" in *py.py:2*) ok "guard_scan_reads_py" ;; *) bad "guard_scan_reads_py: $out" ;; esac
case "$out" in *marked.sh*) bad "guard_scan_honours_markers: $out" ;; *) ok "guard_scan_honours_markers" ;; esac

# profile mode: unchanged by the flag (no .py, no guard markers, -p still reported)
act="$(node "$SCAN" "$T" | sort)"
want='scripts/filemarked.sh:3: claude --model x "a"
scripts/filemarked.sh:4: claude --model y "b"
scripts/marked.sh:3: claude --model x "a"
scripts/mixed.sh:2: mkdir -p d && claude --model x "hi"
scripts/print.sh:2: claude -p "hi"
scripts/seed.sh:2: claude --model x "hi"'
if [ "$act" = "$want" ]; then ok "profile_mode_unchanged"; else bad "profile_mode_unchanged"; echo "$act"; fi

out="$(node "$SCAN" --guard "$REPO")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "guard_scan_clean"; else bad "guard_scan_clean (rc=$rc):"; echo "$out"; fi

echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
