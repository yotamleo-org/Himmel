# shellcheck shell=bash
# Shared stub keyring for suites that run the real scripts/lib/himmel-secrets.
# Source it after setting $TMP (a private temp dir the suite removes): it puts a
# `secret-tool` and a `busctl` stub first on PATH, points the session bus at a
# dead path, and defines kreset. No row that sources it reaches a real keyring.
#
# Knobs (all unset by default):
#   KSTUB_LOCKED=true       busctl reports the collection locked
#   KSTUB_LOOKUP_FAIL=1     every lookup fails (exit 1, as an absent item)
#   KSTUB_LOOKUP_RC=<n>     every lookup exits <n> (124 = timed out)
#   KSTUB_SEARCH_FAIL=1     every search fails
#   KSTUB_DROP_STORE=1      a store succeeds and keeps nothing
# Files: $KSTUB_STORE holds one `attrs<TAB>value` line per item; $KSTUB_LOG holds
# one line per stub call (argv only, so it never holds a stored value).

# Stub keyring: a lookup or search matches an item holding every queried
# attribute, as libsecret does.
KBIN="$TMP/kbin"
mkdir -p "$KBIN"
export KSTUB_STORE="$TMP/keyring.tsv" KSTUB_LOG="$TMP/keyring.log" KSTUB_LOCKED=false
cat >"$KBIN/secret-tool" <<'STUB'
#!/usr/bin/env bash
printf 'secret-tool %s\n' "$*" >>"$KSTUB_LOG"
verb="$1"; shift
[ "${1:-}" = --all ] && shift
if [ "$verb" = store ]; then shift 2; fi
q=""
while [ "$#" -ge 2 ]; do q="$q $1=$2"; shift 2; done
case "$verb" in
    store)
        IFS= read -r val || true
        [ -n "${KSTUB_DROP_STORE:-}" ] && exit 0
        printf '%s\t%s\n' "${q# }" "$val" >>"$KSTUB_STORE"; exit 0 ;;
    lookup)
        [ -z "${KSTUB_LOOKUP_FAIL:-}" ] || exit 1
        [ -z "${KSTUB_LOOKUP_RC:-}" ] || exit "$KSTUB_LOOKUP_RC" ;;
    search) [ -z "${KSTUB_SEARCH_FAIL:-}" ] || { echo 'secret-tool: stub failure' >&2; exit 1; } ;;
esac
rc=1
while IFS="$(printf '\t')" read -r attrs val; do
    m=1
    for p in $q; do case " $attrs " in *" $p "*) ;; *) m=0 ;; esac; done
    [ "$m" = 1 ] || continue
    case "$verb" in
        lookup) printf '%s' "$val"; exit 0 ;;
        # As libsecret's secret-tool.c: the item lines and the secret go to
        # stdout (g_print), the attribute lines to stderr (g_printerr).
        search)
            printf '[/stub]\nlabel = stub\nsecret = %s\n' "$val"
            for p in $attrs; do printf 'attribute.%s = %s\n' "${p%%=*}" "${p#*=}" >&2; done
            rc=0 ;;
    esac
done <"$KSTUB_STORE"
# A search that matches nothing exits 0, as libsecret's does.
[ "$verb" = search ] && exit 0
exit "$rc"
STUB
cat >"$KBIN/busctl" <<'STUB'
#!/usr/bin/env bash
printf 'busctl %s\n' "$*" >>"$KSTUB_LOG"
case "$*" in *" Locked") echo "b ${KSTUB_LOCKED:-false}" ;; esac
STUB
chmod +x "$KBIN/secret-tool" "$KBIN/busctl"
export PATH="$KBIN:$PATH"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/stub-bus"
unset CREDENTIALS_DIRECTORY HIMMEL_SECRETS_KEYRING
kreset() { : >"$KSTUB_STORE"; : >"$KSTUB_LOG"; }
