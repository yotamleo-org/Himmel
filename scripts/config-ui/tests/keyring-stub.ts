// A stub Secret Service for the himmel-secrets resolver: secret-tool and busctl first on PATH, items in a TSV file.
// Every login test that touches the vault passes this env, so none reaches the real keyring.
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const SECRET_TOOL = [
  "#!/usr/bin/env bash",
  'verb="$1"; shift',
  '[ "${1:-}" = --all ] && shift',
  '[ "$verb" = store ] && shift 2',
  'q=""',
  'while [ "$#" -ge 2 ]; do q="$q $1=$2"; shift 2; done',
  'q="${q# }"',
  'case "$verb" in',
  "  store)",
  "    IFS= read -r val || true",
  '    [ -n "${KSTUB_STORE_NOOP:-}" ] && exit 0',
  '    { grep -vF "$q"$\'\\t\' "$KSTUB_STORE" || true; } >"$KSTUB_STORE.n"',
  '    printf \'%s\\t%s\\n\' "$q" "$val" >>"$KSTUB_STORE.n"',
  '    mv "$KSTUB_STORE.n" "$KSTUB_STORE"; exit 0 ;;',
  "  lookup)",
  '    [ -n "${KSTUB_LOOKUP_FAIL:-}" ] && exit 1',
  '    while IFS="$(printf \'\\t\')" read -r attrs val; do',
  "      m=1",
  '      for p in $q; do case " $attrs " in *" $p "*) ;; *) m=0 ;; esac; done',
  '      if [ "$m" = 1 ]; then printf \'%s\' "$val"; exit 0; fi',
  '    done <"$KSTUB_STORE"; exit 1 ;;',
  "  search)",
  '    [ -n "${KSTUB_SEARCH_FAIL:-}" ] && { echo "secret-tool: Cannot autolaunch D-Bus" >&2; exit 1; }',
  '    while IFS="$(printf \'\\t\')" read -r attrs val; do',
  "      m=1",
  '      for p in $q; do case " $attrs " in *" $p "*) ;; *) m=0 ;; esac; done',
  '      if [ "$m" = 1 ]; then found=1; for a in $attrs; do printf \'attribute.%s = %s\\n\' "${a%%=*}" "${a#*=}" >&2; done; fi',
  '    done <"$KSTUB_STORE"',
  '    [ -n "${KSTUB_SEARCH_RC1:-}" ] && [ "${found:-0}" = 0 ] && exit 1',
  "    exit 0 ;;",
  "esac",
  "exit 1",
].join("\n") + "\n";

const BUSCTL = [
  "#!/usr/bin/env bash",
  'case "$*" in *" Locked") echo "b ${KSTUB_LOCKED:-false}" ;; esac',
].join("\n") + "\n";

export function stubKeyring(dir: string) {
  const bin = join(dir, "kbin"), store = join(dir, "keyring.tsv");
  mkdirSync(bin, { recursive: true });
  writeFileSync(store, "");
  for (const [name, body] of [["secret-tool", SECRET_TOOL], ["busctl", BUSCTL]]) {
    writeFileSync(join(bin, name), body);
    chmodSync(join(bin, name), 0o755);
  }
  const env: Record<string, string> = {
    PATH: `${bin}:${process.env.PATH}`,
    KSTUB_STORE: store,
    DBUS_SESSION_BUS_ADDRESS: `unix:path=${join(dir, "stub-bus")}`,
  };
  // the stored value of a user-scope key, null when absent.
  const get = (key: string): string | null => {
    for (const line of readFileSync(store, "utf8").split("\n")) {
      const [attrs, val] = line.split("\t");
      if (attrs === `service=himmel key=${key} scope=user`) return val;
    }
    return null;
  };
  const put = (key: string, value: string) => writeFileSync(store, `${readFileSync(store, "utf8")}service=himmel key=${key} scope=user\t${value}\n`);
  const putProject = (key: string, value: string, project: string) => writeFileSync(store, `${readFileSync(store, "utf8")}service=himmel key=${key} project=${project}\t${value}\n`);
  return { env, store, get, put, putProject, raw: () => readFileSync(store, "utf8") };
}
