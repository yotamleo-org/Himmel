#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
echo "== host"; uname -a; bash --version | head -1; echo "TMPDIR=${TMPDIR:-unset}"
echo "== flock: $(command -v flock || echo none)"
T=$(mktemp -d "${TMPDIR:-/tmp}/diag.XXXXXX") || exit 1; T=$(cd "$T" && pwd -P)
mkdir -p "$T/s/tmp" "$T/s/home/.himmel"
echo "== 9525: bare mktemp -d -t"
d=$(TMPDIR="$T/s/tmp" mktemp -d -t arm-resume-cache.XXXXXX); echo "rc=$? -> [$d]"
find "$T/s/tmp" -maxdepth 2 | sed 's/^/  /'
echo "== 9525: _arm_cache_dir_ensure"
env -u _ARM_CACHE_DIR TMPDIR="$T/s/tmp" HOME="$T/s/home" bash -c ". '$HERE/../lib/handover-path.sh'; _arm_cache_dir_ensure; echo \"cache=[\$_ARM_CACHE_DIR]\"; id=\$(_arm_identity_path '$T'); echo \"identity=[\$id]\""
find "$T/s/tmp" -maxdepth 3 | sed 's/^/  /'
echo "== arm-resume sources"
grep -n '_arm_cache_dir_ensure\|handover-path.sh' "$HERE/arm-resume.sh" | head
echo "== T32: fleet-manifest"
B="$T/b"; mkdir -p "$B"; H="$T/h"; mkdir -p "$H"
printf -- '---\nsession_kind: test\n---\n# worker\n' > "$B/TEST-4-N1-worker.md"
HOME="$H" bash "$HERE/chief-kit/fleet-manifest.sh" control init "$B/x.fleet.json" --target 1; echo "init rc=$?"
HOME="$H" bash "$HERE/chief-kit/fleet-manifest.sh" add "$B/x.fleet.json" "$B/TEST-4-N1-worker.md" --lane native --pending; echo "add rc=$?"
ls -la "$B"
HOME="$H" python3 -I "$HERE/../lib/fleet_runtime.py" resolve --doc "$B/TEST-4-N1-worker.md"; echo "resolve rc=$?"
exit 1
