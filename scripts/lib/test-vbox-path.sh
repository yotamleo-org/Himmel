#!/usr/bin/env bash
# Smoke test for scripts/lib/vbox.py's VBoxManage path resolution
#: PATH-first, explicit VBOXMANAGE_PATH always wins, and the bare
# name is the fallback when `which` finds nothing. Hermetic — never invokes a
# real VBoxManage.
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows; a test
# fixture needs no .ps1 twin (WS5 T15 convention).
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=canon-path.sh
# shellcheck disable=SC1091
. "$LIB_DIR/canon-path.sh"

FAILED=0
TMP_RAW=$(mktemp -d "${TMPDIR:-/tmp}/vbox-path.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'rm -rf "$TMP_RAW"' EXIT
# canon_path_native gives the physical path, so the path python reports
# compares equal to the fixture's own.
TMP=$(canon_path_native "$TMP_RAW") || { echo "FAIL could not canonicalise $TMP_RAW"; exit 1; }
LIB_DIR_NATIVE=$(canon_path_native "$LIB_DIR") || { echo "FAIL could not canonicalise $LIB_DIR"; exit 1; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

PYTHON3="$(command -v python3)"

resolve() {
    # Print vbox.VBOXMANAGE as resolved under the given env.
    "$PYTHON3" -c "import sys; sys.path.insert(0, sys.argv[1]); import vbox; print(vbox.VBOXMANAGE)" "$LIB_DIR_NATIVE"
}

# T1: VBOXMANAGE_PATH unset, a fake VBoxManage on PATH → resolves via which.
FAKE_BIN_DIR="$TMP/bin"
mkdir -p "$FAKE_BIN_DIR"
FAKE_VBOXMANAGE="$FAKE_BIN_DIR/VBoxManage"
cat >"$FAKE_VBOXMANAGE" <<'EOF'
#!/usr/bin/env bash
echo "fake VBoxManage $*"
EOF
chmod +x "$FAKE_VBOXMANAGE"

got=$(unset VBOXMANAGE_PATH; PATH="$FAKE_BIN_DIR:$PATH" resolve)
assert_eq "T1 PATH resolution finds fake VBoxManage" "$FAKE_VBOXMANAGE" "$got"

# T2: explicit VBOXMANAGE_PATH override wins even with a fake on PATH.
got=$(VBOXMANAGE_PATH="/custom/VBoxManage" PATH="$FAKE_BIN_DIR:$PATH" resolve)
assert_eq "T2 explicit VBOXMANAGE_PATH overrides PATH" "/custom/VBoxManage" "$got"

# T3: VBOXMANAGE_PATH unset, nothing on PATH → falls back to the bare name,
# so a missing VBoxManage fails as a plain not-found when it runs.
EMPTY_BIN_DIR="$TMP/empty-bin"
mkdir -p "$EMPTY_BIN_DIR"
got=$(unset VBOXMANAGE_PATH; PATH="$EMPTY_BIN_DIR" resolve)
assert_eq "T3 falls back to the bare name when PATH has nothing" "VBoxManage" "$got"

# T6: with that bare name and nothing on PATH, _run() raises FileNotFoundError
# to its caller instead of swallowing it.
t6_rc=0
t6_err=$(unset VBOXMANAGE_PATH; PATH="$EMPTY_BIN_DIR" "$PYTHON3" -c \
    "import sys; sys.path.insert(0, sys.argv[1]); import vbox; vbox._run('list')" "$LIB_DIR_NATIVE" 2>&1 >/dev/null) || t6_rc=$?
case "$t6_err" in *FileNotFoundError*) t6_seen=yes ;; *) t6_seen=no ;; esac
assert_eq "T6 a missing VBoxManage reaches the caller as FileNotFoundError" "nonzero yes" \
    "$([ "$t6_rc" -ne 0 ] && echo nonzero || echo zero) $t6_seen"

# T4: VBoxManage runs with cwd $HOME, not the caller's cwd, so
# the VBoxSVC it may spawn cannot pin a worktree. The fake prints its cwd.
T4_HOME="$TMP/t4-home"; T4_CALLER="$TMP/t4-caller"; mkdir -p "$T4_HOME" "$T4_CALLER"
T4_FAKE="$TMP/t4-fake-vboxmanage"
printf '#!/bin/sh\npwd -P\n' > "$T4_FAKE"; chmod +x "$T4_FAKE"
got=$(cd "$T4_CALLER" && HOME="$T4_HOME" VBOXMANAGE_PATH="$T4_FAKE" "$PYTHON3" -c \
    "import sys; sys.path.insert(0, sys.argv[1]); import vbox; print(vbox._run('list')[1].strip())" "$LIB_DIR_NATIVE")
assert_eq "T4 VBoxManage runs with cwd HOME, not the caller's cwd" "$(cd "$T4_HOME" && pwd -P)" "$got"

# T5: a RELATIVE VBOXMANAGE_PATH is resolved against the
# caller's cwd at import, so it still runs after the cwd=$HOME change.
printf '#!/bin/sh\necho relative-ok\n' > "$T4_CALLER/rel-vbm"; chmod +x "$T4_CALLER/rel-vbm"
got=$(cd "$T4_CALLER" && HOME="$T4_HOME" VBOXMANAGE_PATH="./rel-vbm" "$PYTHON3" -c \
    "import sys; sys.path.insert(0, sys.argv[1]); import vbox; print(vbox._run('list')[1].strip())" "$LIB_DIR_NATIVE")
assert_eq "T5 relative VBOXMANAGE_PATH still runs under cwd HOME" "relative-ok" "$got"

# T7: ubuntu-vm-setup.py's vboxmanage() runs the binary this resolver picks.
# paramiko and dotenv are stubbed, so the script loads without its pip deps.
T7_STUBS="$TMP/t7-stubs"; mkdir -p "$T7_STUBS"
: > "$T7_STUBS/paramiko.py"
printf 'def dotenv_values(*a, **k):\n    return {}\n\n\ndef find_dotenv(*a, **k):\n    return ""\n' > "$T7_STUBS/dotenv.py"
got=$(ubuntu_vm_user=u ubuntu_vm_pass=p VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" "$PYTHON3" -c \
    "import sys, importlib.util; sys.path.insert(0, sys.argv[1]); s = importlib.util.spec_from_file_location('ubuntu_vm_setup', sys.argv[2]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); rc, out = m.vboxmanage('--version'); print(rc, out.strip())" \
    "$T7_STUBS" "$LIB_DIR_NATIVE/../machine-setup/ubuntu-vm-setup.py" 2>/dev/null)
assert_eq "T7 ubuntu-vm-setup.py vboxmanage() runs the resolved VBoxManage" "0 fake VBoxManage --version" "$got"

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILED"
    exit 1
fi
