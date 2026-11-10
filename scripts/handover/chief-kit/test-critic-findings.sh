#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# Usage: bash scripts/handover/chief-kit/test-critic-findings.sh [test-name]
# Exit: 0 all rows pass, 1 a row failed, 2 a missing tool.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY CLAUDE_PLUGIN_ROOT

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd -P)"
FINDINGS="$HERE/critic-findings.py"
TSV="$HERE/fixtures/canonical-verdict-names.tsv"
SEALSH="$HERE/critic-seal.sh"
MINERVA="$REPO_ROOT/marketplace/plugins/himmel-ops/skills/minerva"
SKILL="$MINERVA/SKILL.md"
FORMAT="$MINERVA/critic-return-format.md"
PANEL="$MINERVA/panel-charter.md"
PLANCH="$MINERVA/plan-charter.md"

for tool in bun jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool is needed"; exit 2; }
done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || { echo "FATAL: sha256sum or shasum is needed"; exit 2; }
[ -f "$TSV" ] && [ -f "$SKILL" ] && [ -f "$PANEL" ] && [ -f "$PLANCH" ] || { echo "FATAL: fixture sources are missing"; exit 2; }

PASS=0 FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${OUT:-}" ] && printf '        out: %s\n' "$(printf '%s' "$OUT" | head -c 300)"; FAIL=$((FAIL+1)); }
check() { local label=$1; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }
refused() {
  local want_rc=$1 reason=$2 label=$3
  if [ "$RC" = "$want_rc" ] && jq -e --arg r "$reason" '.schema==1 and .kind=="critic-intake-refusal" and .state=="refused" and (.reasons|index($r)!=null)' <<<"$OUT" >/dev/null 2>&1; then pass "$label"; else fail "$label (rc=$RC)"; fi
}
neg() { ! "$@"; }
sedi() { sed "$1" "$2" > "$2.sedi" && mv "$2.sedi" "$2"; }
fstat() { python3 -I -c 'import os, sys; s = os.stat(sys.argv[1]); print(s.st_mtime_ns, s.st_ino)' "$1"; }
# shellcheck disable=SC2231
nfiles() { local n=0 f; for f in "$1"/$2; do [ -e "$f" ] && n=$((n+1)); done; printf '%s' "$n"; }
okrun() { if [ "$RC" = 0 ] && jq -e . <<<"$OUT" >/dev/null 2>&1; then pass "$1"; else fail "$1 (rc=$RC)"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/critic-findings.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT

sha256s() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi | cut -d' ' -f1; }
sha() { sha256s "$1"; }
cf() { OUT=$(python3 -I "$FINDINGS" "$@" 2>"$T/err"); RC=$?; }

newroot() {
  R="$T/$1"; SPEC="$R/specs/design/subject.md"; PLAN="$R/specs/plans/subject.md"
  mkdir -p "$R/specs/design" "$R/specs/plans" "$R/specs/decisions"
  printf '# Subject\n' > "$SPEC"; printf '# Plan\n' > "$PLAN"
  EXTRA_READ=""
}
# A root whose seals reach the round ledger: the spec is named for its ticket and the specs root is seeded.
newsealroot() {
  newroot "$1"; SPEC="$R/specs/design/HIMMEL-1-subject.md"
  printf -- '---\ntickets: HIMMEL-1\n---\n# Subject\n' > "$SPEC"
  bun "$REPO_ROOT/scripts/telegram/chief-route.ts" round-seed --all "$R/specs" >/dev/null || { echo "FATAL: round-seed failed in $R/specs"; exit 2; }
}
vpath() { printf '%s.critic-%s-r%s.md' "$SPEC" "$1" "$2"; }
mkret() {
  local kind=$1 round=$2 n=$3 dest=${4:-} up i
  [ -n "$dest" ] || dest=$(vpath "$kind" "$round")
  mkdir -p "$(dirname "$dest")"
  [ "$kind" = spec ] && up=SPEC || up=PLAN
  {
    printf 'Read %s SHA256 %s.\n' "$SPEC" "$(sha "$SPEC")"
    [ -z "$EXTRA_READ" ] || printf 'Read %s SHA256 %s.\n' "$EXTRA_READ" "$(sha "$EXTRA_READ")"
    i=1; while [ "$i" -le "$n" ]; do printf 'Finding %s-r%s-%s: an issue at line 1.\n' "$kind" "$round" "$i"; i=$((i+1)); done
    printf '```critic-findings-v1\n'
    jq -nc --arg k "$kind" --argjson r "$round" --argjson n "$n" --arg p "$SPEC" \
      '{schema:1,kind:"critic-findings",reviewer_id:"minerva-\($k)-r\($r)",findings:[range(1;$n+1)|{finding_id:"\($k)-r\($r)-\(.)",severity:(["minor","major","critical"][(.-1)%3]),location:{path:$p,start_line:1,end_line:1}}]}'
    printf '```\n'
    if [ "$n" = 0 ]; then printf '%s CLEAN\n' "$up"; else printf '%s FINDINGS %s\n' "$up" "$n"; fi
  } > "$dest"
}
mklegacy() { local kind=$1 round=$2 verdict_line=$3; printf 'Read %s SHA256 %s.\nSome prose finding.\n%s\n' "$SPEC" "$(sha "$SPEC")" "$verdict_line" > "$(vpath "$kind" "$round")"; }
norm() { local k=$1 r=$2; shift 2; cf normalize --spec "$SPEC" --kind "$k" --round "$r" --verdict "$(vpath "$k" "$r")" --out "$(vpath "$k" "$r").finding-index.json" "$@"; }
idx() { printf '%s.finding-index.json' "$(vpath "$1" "$2")"; }
prev() {
  local f=$1 first=1 p; shift
  { printf '{"schema":1,"verdicts":['; for p in "$@"; do [ "$first" = 1 ] || printf ','; first=0; printf '{"path":"%s","sha256":"%s"}' "$p" "$(sha "$p")"; done; printf ']}\n'; } > "$f"
}
bund() { cf bundle --spec "$SPEC" --previous-verdicts "$1" --out "$2"; }
valid() { cf validate-bundle "$2" --spec "$SPEC" --previous-verdicts "$1"; }
privdir() { local d="$T/priv-$1"; mkdir -p "$d"; chmod 700 "$d"; printf '%s' "$d"; }
inventory() {
  (cd "$1" && find . \( -type f -o -type l \) -print | sort | while IFS= read -r f; do
    if [ -L "$f" ]; then echo "L $f $(readlink "$f")"; else echo "F $f $(sha "$f")"; fi
  done)
}

block() { awk '/<!-- critic-readiness-recipe-start -->/{f=1;next} /<!-- critic-readiness-recipe-end -->/{f=0} f' "${1:-$SKILL}"; }
outside() { awk '/<!-- critic-readiness-recipe-start -->/{f=1;next} /<!-- critic-readiness-recipe-end -->/{f=0;next} !f' "${1:-$SKILL}"; }
ctx_lines() {
  local k=$2 r=$3 raw
  raw=$(block "$1" | awk '/<!-- critic-context -->/{m=1;next} m&&/^```/{if(open){exit}; open=1; next} m&&open{print}')
  raw="${raw//'${K}'/$k}"; raw="${raw//'${R}'/$r}"
  printf '%s\n' "$raw"
}
ctx_ok() { [ "$(ctx_lines "$1" "$2" "$3")" = "$(printf 'critic_kind: %s\nrequested_round: %s\nreviewer_id: minerva-%s-r%s' "$2" "$3" "$2" "$3")" ]; }

cat > "$T/render.py" <<'PY'
import json, re, sys
fmt, kind, rnd, prefix, artifact, sha, reviewer = sys.argv[1:8]
text = open(fmt).read()
if text.count('<!-- example-start -->') != 1 or text.count('<!-- example-end -->') != 1:
    sys.exit('format example markers are not exactly one pair')
ex = re.search(r'<!-- example-start -->\n(.*?)<!-- example-end -->', text, re.S).group(1)
subs = {'{{KIND}}': kind, '{{ROUND}}': rnd, '{{VERDICT_PREFIX}}': prefix, '{{ARTIFACT}}': artifact,
        '{{ARTIFACT_SHA}}': sha, '{{ARTIFACT_JSON}}': json.dumps(artifact), '{{REVIEWER_ID}}': reviewer}
for k, v in subs.items():
    ex = ex.replace(k, v)
if '{{' in ex:
    sys.exit('unsubstituted placeholder in the format example')
sys.stdout.write(ex)
PY
render() { python3 -I "$T/render.py" "$FORMAT" "$@"; }

cat > "$T/race.py" <<'PY'
import contextlib, importlib.util, io, json, subprocess, sys
finder, scenario, spec, kind, rnd, verdict, out = sys.argv[1:8]
loaded = importlib.util.spec_from_file_location('critic_findings', finder)
mod = importlib.util.module_from_spec(loaded)
loaded.loader.exec_module(mod)
real = mod.archive_old_index
log = {}
def patched(index_path, old_bytes):
    result = real(index_path, old_bytes)
    if scenario == 'index-changed':
        open(index_path, 'w').write('{"someone":"else"}\n')
    elif scenario == 'verdict-changed':
        text = open(verdict).read()
        cut = text.rstrip('\n').rfind('\n') + 1
        open(verdict, 'w').write(text[:cut] + 'CONTENT-SHA256 ' + 'a' * 64 + ' x\n' + text[cut:])
    elif scenario == 'new-index-written':
        obj, _ = mod.build_index(spec, kind, int(rnd), verdict, open(verdict, 'rb').read())
        open(index_path, 'wb').write(mod.dump(obj))
    elif scenario == 'concurrent':
        r = subprocess.run([sys.executable, '-I', finder, 'normalize', '--spec', spec, '--kind', kind, '--round', rnd,
                            '--verdict', verdict, '--out', out, '--rebuild-stale'], capture_output=True, text=True)
        log['second'] = {'rc': r.returncode, 'out': r.stdout}
    return result
mod.archive_old_index = patched
argv = ['normalize', '--spec', spec, '--kind', kind, '--round', rnd, '--verdict', verdict, '--out', out, '--rebuild-stale']
if scenario == 'bundle-swap':
    real_check = mod.check_verdict
    swapped = []
    def check_then_swap(spec_, kind_, rnd_, path):
        data = real_check(spec_, kind_, rnd_, path)
        if not swapped:
            swapped.append(1)
            text = open(verdict).read()
            cut = text.rstrip('\n').rfind('\n') + 1
            open(verdict, 'w').write(text[:cut] + 'CONTENT-SHA256 ' + 'd' * 64 + ' x\n' + text[cut:])
        return data
    mod.check_verdict = check_then_swap
    argv = ['bundle', '--spec', spec, '--previous-verdicts', sys.argv[8], '--out', out]
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = mod.main(argv)
print(json.dumps({'rc': rc, 'out': buf.getvalue(), 'second': log.get('second')}))
PY

t_charters_bytes_unchanged() {
  local before after in_n out_n
  before="$(sha "$PANEL") $(sha "$PLANCH")"
  newroot charters; mkret spec 1 1; norm spec 1; prev "$(privdir charters)/PREVIOUS.json" "$(vpath spec 1)"; bund "$(privdir charters)/PREVIOUS.json" "$R/b.json"
  after="$(sha "$PANEL") $(sha "$PLANCH")"
  check "charter bytes identical around the fixture operations" test "$before" = "$after"
  check "exactly one marker pair" test "$(grep -c 'critic-readiness-recipe-start' "$SKILL")" = 1 -a "$(grep -c 'critic-readiness-recipe-end' "$SKILL")" = 1
  check "Stage 2 panel CHARTER assignment still names panel-charter.md" grep -qF -- 'CHARTER="$REPO/marketplace/plugins/himmel-ops/skills/minerva/panel-charter.md"' "$SKILL"
  check "the panel lane still passes --charter \"\$CHARTER\"" grep -qF -- '--charter "$CHARTER"' "$SKILL"
  check "Stage 4 still passes plan-charter.md" grep -qF -- '--charter "$REPO/marketplace/plugins/himmel-ops/skills/minerva/plan-charter.md"' "$SKILL"
  out_n=$(outside | grep -c 'critic-return-format.md'); in_n=$(block | grep -c 'critic-return-format.md')
  check "critic-return-format.md is named only inside the marker pair" test "$out_n" = 0 -a "$in_n" -ge 1
  check "charters are not in the marker pair" test "$(block | grep -c -E 'panel-charter|plan-charter')" = 0
  check "the format file exists" test -f "$FORMAT"
}

t_prompt_metadata_contract() {
  local spec_k label ex
  for spec_k in "spec 1" "plan 1" "spec 2" "plan 2"; do
    local k=${spec_k% *} r=${spec_k#* }
    check "critic-context renders the three pinned lines for $k/r$r" ctx_ok "$SKILL" "$k" "$r"
    label="minerva-$k-r$r"
    newroot "meta-$k-$r"
    local up; [ "$k" = spec ] && up=SPEC || up=PLAN
    ex=$(render "$k" "$r" "$up" "$SPEC" "$(sha "$SPEC")" "$label") || ex=""
    printf '%s' "$ex" > "$(vpath "$k" "$r")"
    norm "$k" "$r"
    okrun "label from the context fence drives the format example for $k/r$r"
    check "index carries the supplied label and ID for $k/r$r" jq -e --arg l "$label" --arg id "$k-r$r-1" '.provenance.reviewer_id==$l and .findings[0].finding_id==$id and .round=='"$r"' and .critic_kind=="'"$k"'"' "$(idx "$k" "$r")"
  done
  local m="$T/skill-mutants"; mkdir -p "$m"
  grep -v '^requested_round: ' "$SKILL" > "$m/no-round.md"
  sed 's/^reviewer_id: .*/reviewer_id: someone/' "$SKILL" > "$m/bad-label.md"
  sed 's/^critic_kind: .*/critic_kind: both/' "$SKILL" > "$m/bad-kind.md"
  grep -v 'critic-context' "$SKILL" > "$m/no-marker.md"
  for f in no-round bad-label bad-kind no-marker; do
    check "a changed or missing context field fails the contract ($f)" neg ctx_ok "$m/$f.md" spec 1
  done
}

t_format_file_example_normalizes() {
  local k up ex v
  for k in spec plan; do
    [ "$k" = spec ] && up=SPEC || up=PLAN
    newroot "fmt-$k"
    ex=$(render "$k" 1 "$up" "$SPEC" "$(sha "$SPEC")" "minerva-$k-r1") || ex=""
    v=$(vpath "$k" 1); printf '%s' "$ex" > "$v"
    norm "$k" 1
    okrun "the shipped example normalizes ($k)"
    check "exact ID, path, hash, count and provenance ($k)" jq -e --arg k "$k" --arg v "$v" --arg h "$(sha "$v")" --arg s "$SPEC" \
      '.schema==1 and .kind=="critic-finding-index" and .complete==true and .spec_path==$s and .critic_kind==$k and .round==1 and .verdict.path==$v and .verdict.sha256==$h and (.findings|length)==1 and .findings[0].finding_id==($k+"-r1-1") and .findings[0].severity=="minor" and .findings[0].location.path==$s and .provenance=={method:"structured-return",reviewer_id:("minerva-"+$k+"-r1")}' "$(idx "$k" 1)"
    newroot "fmt-$k-count"
    ex2=$(render "$k" 1 "$up" "$SPEC" "$(sha "$SPEC")" "minerva-$k-r1"); printf '%s' "$ex2" | sed 's/FINDINGS 1$/FINDINGS 2/' > "$(vpath "$k" 1)"
    norm "$k" 1; refused 2 invalid "terminal count 1 to 2 fails with 2 ($k)"
    newroot "fmt-$k-id"; ex2=$(render "$k" 1 "$up" "$SPEC" "$(sha "$SPEC")" "minerva-$k-r1"); printf '%s' "$ex2" | sed "s/$k-r1-1/$k-r0-1/" > "$(vpath "$k" 1)"
    norm "$k" 1; refused 2 invalid "ID changed to $k-r0-1 fails with 2 ($k)"
    newroot "fmt-$k-two"; ex2=$(render "$k" 1 "$up" "$SPEC" "$(sha "$SPEC")" "minerva-$k-r1")
    { printf '%s' "$ex2" | sed '$d'; printf '%s' "$ex2" | awk '/^```critic-findings-v1/,/^```$/'; printf '%s' "$ex2" | tail -n 1; } > "$(vpath "$k" 1)"
    norm "$k" 1; refused 2 duplicate "two tagged blocks fail with 2 ($k)"
    newroot "fmt-$k-none"; ex2=$(render "$k" 1 "$up" "$SPEC" "$(sha "$SPEC")" "minerva-$k-r1")
    printf '%s' "$ex2" | awk '/^```critic-findings-v1/{s=1} !s{print} /^```$/&&s{s=0}' > "$(vpath "$k" 1)"
    norm "$k" 1; refused 3 legacy-provenance-missing "no block fails with 3 ($k)"
  done
}

t_structured_index_count() {
  newroot count; mkret spec 1 3; norm spec 1
  okrun "3 findings of three severities normalize"
  check "the index counts every severity and keeps the order" jq -e '.complete==true and (.findings|map(.severity))==["minor","major","critical"] and (.findings|map(.finding_id))==["spec-r1-1","spec-r1-2","spec-r1-3"]' "$(idx spec 1)"
  check "stdout is the index file" test "$OUT" = "$(cat "$(idx spec 1)")"
  newroot count-low; mkret spec 1 3; sedi 's/SPEC FINDINGS 3$/SPEC FINDINGS 2/' "$(vpath spec 1)"; norm spec 1
  refused 2 invalid "FINDINGS 2 over 3 listed findings"
  newroot count-high; mkret spec 1 1; sedi 's/SPEC FINDINGS 1$/SPEC FINDINGS 4/' "$(vpath spec 1)"; norm spec 1
  refused 2 invalid "FINDINGS 4 over 1 listed finding"
  newroot count-dup; mkret spec 1 2; sedi 's/spec-r1-2/spec-r1-1/' "$(vpath spec 1)"; norm spec 1
  refused 2 duplicate "a duplicate finding ID"
  newroot count-line; mkret spec 1 1; sedi 's/"end_line":1/"end_line":0/' "$(vpath spec 1)"; norm spec 1
  refused 2 invalid "end line before start line"
  newroot count-sev; mkret spec 1 1; sedi 's/"minor"/"trivial"/' "$(vpath spec 1)"; norm spec 1
  refused 2 invalid "unknown severity"
  newroot count-term; mkret spec 1 1; sedi 's/SPEC FINDINGS 1$/FINDINGS 1/' "$(vpath spec 1)"; norm spec 1
  refused 2 invalid "no SPEC|PLAN terminal line"
  check "no index written by any refusal" test ! -e "$(idx spec 1)"
}

t_clean_requires_complete_index() {
  newroot clean; mkret spec 1 0; norm spec 1
  okrun "a CLEAN structured return normalizes"
  check "the CLEAN index is complete with an explicit empty list" jq -e '.complete==true and .findings==[] and .provenance.method=="structured-return"' "$(idx spec 1)"
  newroot clean-bad; mkret spec 1 1; sedi 's/SPEC FINDINGS 1$/SPEC CLEAN/' "$(vpath spec 1)"; norm spec 1
  refused 2 invalid "SPEC CLEAN over a listed finding"
  newroot clean-zero; mkret spec 1 0; sedi 's/SPEC CLEAN$/SPEC FINDINGS 0/' "$(vpath spec 1)"; norm spec 1
  refused 2 invalid "FINDINGS 0 is not a clean verdict"
  newroot clean-legacy; mklegacy spec 1 "SPEC CLEAN"; norm spec 1
  refused 3 legacy-provenance-missing "a legacy CLEAN is not a zero-finding set"
  newroot clean-bundle; mkret spec 1 0; local p; p="$(privdir clean-bundle)/PREVIOUS.json"; prev "$p" "$(vpath spec 1)"
  bund "$p" "$R/b.json"; refused 3 missing "a CLEAN prior without its index is refused"
  norm spec 1; bund "$p" "$R/b.json"; okrun "a CLEAN prior with its index bundles"
  check "the CLEAN prior has a nonempty verdict entry and no findings" jq -e '(.verdicts|length)==1 and .verdicts[0].finding_ids==[] and .previous_findings==[]' "$R/b.json"
  jq '.complete=false' "$(idx spec 1)" > "$R/tmp" && mv "$R/tmp" "$(idx spec 1)"
  rm -f "$R/b.json"; bund "$p" "$R/b.json"; refused 3 incomplete "an index with complete=false is refused"
}

t_empty_previous_bundle() {
  newroot empty; local p b; p="$(privdir empty)/PREVIOUS.json"; b="$R/empty.bundle.json"
  printf '{"schema":1,"verdicts":[]}\n' > "$p"
  bund "$p" "$b"; okrun "an explicit empty PREVIOUS bundles"
  check "BUNDLE has exact empty arrays and the canonical SPEC" test "$(jq -c . "$b")" = "$(jq -nc --arg s "$SPEC" '{schema:1,kind:"critic-findings-bundle",spec_path:$s,verdicts:[],previous_findings:[]}')"
  valid "$p" "$b"; okrun "validate-bundle of the empty bundle succeeds"
  check "validate-bundle prints the same BUNDLE" test "$OUT" = "$(cat "$b")"
  cf bundle --spec "$SPEC" --previous-verdicts "$T/priv-empty/missing.json" --out "$R/other.bundle.json"
  refused 3 missing "a missing PREVIOUS is refused with 3"
  printf '{"schema":1}\n' > "$T/priv-empty/omitted.json"
  bund "$T/priv-empty/omitted.json" "$R/other.bundle.json"; refused 2 invalid "omitted verdicts is refused with 2"
  printf '{"schema":1,"verdicts":[],"extra":1}\n' > "$T/priv-empty/extra.json"
  bund "$T/priv-empty/extra.json" "$R/other.bundle.json"; refused 2 invalid "an unknown PREVIOUS key is refused"
  check "no bundle was written by the refusals" test ! -e "$R/other.bundle.json"
  valid "$p" "$R/absent.bundle.json"; refused 3 missing "a missing BUNDLE is refused with 3"
}

t_legacy_missing_not_zero() {
  newroot lm; mklegacy spec 1 "SPEC FINDINGS 2"; norm spec 1
  refused 3 legacy-provenance-missing "legacy FINDINGS refuses with 3"
  check "no index and no lock were created" test "$(nfiles "$R/specs/design" '*finding-index*')$(nfiles "$R/specs/design" '*lock*')" = 00
  cf normalize --spec "$SPEC" --kind spec --round 1 --verdict "$(vpath spec 1)" --out "$(idx spec 1)" --legacy-review "$R/review.json"
  refused 2 invalid "the retired --legacy-review option is refused"
  newroot lm-missing; norm spec 1; refused 3 missing "a missing verdict is not an empty finding set"
  check "missing is not malformed" test "$RC" = 3
  newroot lm-forged; mklegacy spec 1 "SPEC CLEAN"
  jq -nc --arg s "$SPEC" --arg v "$(vpath spec 1)" --arg h "$(sha "$(vpath spec 1)")" '{schema:1,kind:"critic-finding-index",spec_path:$s,critic_kind:"spec",round:1,verdict:{path:$v,sha256:$h},complete:true,findings:[],provenance:{method:"structured-return",reviewer_id:"x"}}' > "$(idx spec 1)"
  local p; p="$(privdir lm-forged)/PREVIOUS.json"; prev "$p" "$(vpath spec 1)"; bund "$p" "$R/b.json"
  refused 3 legacy-provenance-missing "a hand-written complete index does not cover a legacy return"
}

t_legacy_return_refused_exit3() {
  newroot lr; mklegacy plan 1 "PLAN FINDINGS 2"; local before; before=$(sha "$(vpath plan 1)")
  norm plan 1
  refused 3 legacy-provenance-missing "legacy plan FINDINGS refuses with 3"
  check "the refusal JSON has exactly the specified keys" jq -e 'keys==["kind","operation","reasons","schema","state"] and .operation=="normalize"' <<<"$OUT"
  check "the legacy return is unchanged" test "$(sha "$(vpath plan 1)")" = "$before"
  mklegacy plan 2 "PLAN CLEAN"; norm plan 2; refused 3 legacy-provenance-missing "legacy PLAN CLEAN refuses with 3"
}

t_canonical_filename_kind_round() {
  newroot cn; mkret spec 2 1
  cf normalize --spec "$SPEC" --kind spec --round 1 --verdict "$(vpath spec 2)" --out "$(vpath spec 2).finding-index.json"; refused 2 noncanonical-location "file r2 named as round 1"
  cf normalize --spec "$SPEC" --kind plan --round 2 --verdict "$(vpath spec 2)" --out "$(vpath spec 2).finding-index.json"; refused 2 noncanonical-location "a spec file named as kind plan"
  for r in 1.0 01 -1 x ""; do
    cf normalize --spec "$SPEC" --kind spec --round "$r" --verdict "$(vpath spec 2)" --out "$(vpath spec 2).finding-index.json"; refused 2 invalid "round '$r' is not a positive integer"
  done
  newroot cn-id; mkret spec 1 1; sedi 's/spec-r1-1/spec-r2-1/g' "$(vpath spec 1)"; norm spec 1; refused 2 invalid "an ID carrying another round"
  newroot cn-idkind; mkret spec 1 1; sedi 's/spec-r1-1/plan-r1-1/g' "$(vpath spec 1)"; norm spec 1; refused 2 invalid "an ID carrying another kind"
  newroot cn-prefix; mkret spec 1 0; sedi 's/SPEC CLEAN/PLAN CLEAN/' "$(vpath spec 1)"; norm spec 1; refused 2 invalid "a PLAN verdict in a spec return"
  newroot cn-block; mkret spec 1 1; sedi 's/"kind":"critic-findings"/"kind":"critic-finding"/' "$(vpath spec 1)"; norm spec 1; refused 2 invalid "a wrong block kind"
  newroot cn-schema; mkret spec 1 1; sedi 's/"schema":1/"schema":2/' "$(vpath spec 1)"; norm spec 1; refused 2 invalid "a wrong block schema"
  newroot cn-other; mkret spec 1 1; mkdir -p "$R/specs/other"; printf '# Other\n' > "$R/specs/other/o.md"
  cf normalize --spec "$R/specs/other/o.md" --kind spec --round 1 --verdict "$(vpath spec 1)" --out "$(idx spec 1)"; refused 2 noncanonical-location "a verdict beside another spec"
  cf normalize --spec "specs/design/subject.md" --kind spec --round 1 --verdict "$(vpath spec 1)" --out "$(idx spec 1)"; refused 2 invalid "a relative --spec"
  cf normalize --spec "$SPEC" --kind spec --round 1 --verdict "$(vpath spec 1)" --out "$R/elsewhere.json"; refused 2 noncanonical-location "--out other than verdict plus .finding-index.json"
  norm spec 1; okrun "the canonical form of the same return normalizes"
}

t_canonical_verdict_names_shared() {
  check "the shared table has the nine specified cases" test "$(tail -n +2 "$TSV" | cut -f1 | tr '\n' ' ')" = "spec_r1 plan_r2 zero padded missing_ordinal renamed symlink plan_folder missing_file "
  check "the table header is the specified tab-separated one" test "$(head -n 1 "$TSV")" = "$(printf 'case_id\tpath\tkind\tround\tentry\tcanonical')"
  local case_id path kind round entry canonical
  while IFS=$'\t' read -r case_id path kind round entry canonical; do
    [ "$case_id" = case_id ] && continue
    newroot "tsv-$case_id"
    case "$entry" in
      regular) mkret "$kind" "$round" 1 "$R/$path" ;;
      symlink) mkret "$kind" "$round" 1 "$R/targets/$case_id.md"; mkdir -p "$(dirname "$R/$path")"; ln -s "$R/targets/$case_id.md" "$R/$path" ;;
      missing) : ;;
    esac
    cf normalize --spec "$SPEC" --kind "$kind" --round "$round" --verdict "$R/$path" --out "$R/$path.finding-index.json"
    if [ "$canonical" = yes ]; then okrun "$case_id: canonical yes succeeds"
    elif [ "$entry" = missing ]; then refused 3 missing "$case_id: missing_file refuses 3/missing"
    else
      if [ "$RC" = 2 ] && jq -e '.kind=="critic-intake-refusal"' <<<"$OUT" >/dev/null 2>&1; then pass "$case_id: canonical no refuses 2"; else fail "$case_id: canonical no refuses 2 (rc=$RC)"; fi
    fi
  done < "$TSV"
}

t_noncanonical_location_refused() {
  newroot nl; mkret spec 1 1; norm spec 1
  mkret plan 1 1 "$R/specs/plans/subject.md.critic-plan-r1.md"
  mkret spec 1 1 "$SPEC.critic-spec-r01.md"; mkret spec 1 1 "$SPEC.critic-spec-renamed.md"; mkret spec 0 1 "$SPEC.critic-spec-r0.md"
  local p cases c; p="$(privdir nl)/PREVIOUS.json"
  cases="$R/specs/plans/subject.md.critic-plan-r1.md $SPEC.critic-spec-r01.md $SPEC.critic-spec-renamed.md $SPEC.critic-spec-r0.md $SPEC/../design/subject.md.critic-spec-r1.md"
  for c in $cases; do
    printf '{"schema":1,"verdicts":[{"path":"%s","sha256":"%s"}]}\n' "$c" "$(sha "$(vpath spec 1)")" > "$p"
    bund "$p" "$R/nl.bundle.json"; refused 2 noncanonical-location "declared prior $(basename "$c") is refused, not omitted"
  done
  printf '{"schema":1,"verdicts":[{"path":"specs/design/subject.md.critic-spec-r1.md","sha256":"%s"}]}\n' "$(sha "$(vpath spec 1)")" > "$p"
  bund "$p" "$R/nl.bundle.json"; refused 2 noncanonical-location "a relative declared prior"
  ln -s "$(vpath spec 1)" "$SPEC.critic-spec-r2.md"
  printf '{"schema":1,"verdicts":[{"path":"%s","sha256":"%s"}]}\n' "$SPEC.critic-spec-r2.md" "$(sha "$(vpath spec 1)")" > "$p"
  bund "$p" "$R/nl.bundle.json"; refused 2 noncanonical-location "a symlinked declared prior"
  check "no bundle was written" test ! -e "$R/nl.bundle.json"
}

t_every_declared_prior_bound() {
  newroot bound; mkret spec 1 2; mkret spec 2 0; norm spec 1; norm spec 2
  local p b; p="$(privdir bound)/PREVIOUS.json"; b="$R/bound.bundle.json"
  prev "$p" "$(vpath spec 1)" "$(vpath spec 2)"
  bund "$p" "$b"; okrun "two indexed priors bundle"
  check "every verdict entry is bound to its index and finding IDs" jq -e --arg v1 "$(vpath spec 1)" --arg h1 "$(sha "$(vpath spec 1)")" --arg i1 "$(idx spec 1)" --arg ih1 "$(sha "$(idx spec 1)")" \
    '.verdicts[0]=={path:$v1,sha256:$h1,index_path:$i1,index_sha256:$ih1,finding_ids:["spec-r1-1","spec-r1-2"]} and .verdicts[1].finding_ids==[] and (.verdicts[1]|keys)==["finding_ids","index_path","index_sha256","path","sha256"]' "$b"
  check "previous_findings pairs each ID with its verdict hash" jq -e --arg h1 "$(sha "$(vpath spec 1)")" '.previous_findings==[{finding_id:"spec-r1-1",verdict_sha256:$h1},{finding_id:"spec-r1-2",verdict_sha256:$h1}]' "$b"
  valid "$p" "$b"; okrun "validate-bundle accepts the bundle"; check "validate-bundle prints it" test "$OUT" = "$(cat "$b")"
  rm -f "$(idx spec 2)"; rm -f "$b"; bund "$p" "$b"; refused 3 missing "a prior without an index is refused"
  norm spec 2
  printf '{"schema":1,"verdicts":[{"path":"%s","sha256":"%s"},{"path":"%s","sha256":"%s"}]}\n' "$(vpath spec 1)" "$(sha "$(vpath spec 1)")" "$(vpath spec 1)" "$(sha "$(vpath spec 1)")" > "$T/priv-bound/dup.json"
  bund "$T/priv-bound/dup.json" "$b"; refused 2 duplicate "a duplicate prior"
  printf '{"schema":1,"verdicts":[{"path":"%s","sha256":"%s"}]}\n' "$(vpath spec 1)" "$(printf 'x' | sha256s)" > "$T/priv-bound/stale.json"
  bund "$T/priv-bound/stale.json" "$b"; refused 3 stale "a declared hash that is not the file's hash"
  printf '{"schema":1,"verdicts":[{"path":"%s","sha256":"%s"}]}\n' "$(vpath spec 5)" "$(sha "$SPEC")" > "$T/priv-bound/missing.json"
  bund "$T/priv-bound/missing.json" "$b"; refused 3 missing "a declared prior file that does not exist"
  bund "$p" "$b"; okrun "the full set bundles again"
  jq '.verdicts[0].finding_ids=["spec-r1-1"]' "$b" > "$R/tampered.json"; mv "$R/tampered.json" "$b"
  valid "$p" "$b"; refused 2 invalid "a tampered bundle fails validate-bundle"
  rm -f "$b"; bund "$p" "$b"; sedi 's/"schema":1/"schema":true/' "$b"
  valid "$p" "$b"; refused 2 invalid "a bundle whose schema is true is not the bundle"
  rm -f "$b"
  local swapr; swapr=$(python3 -I "$T/race.py" "$FINDINGS" bundle-swap "$SPEC" spec 1 "$(vpath spec 1)" "$b" "$p" 2>/dev/null); OUT=$swapr
  check "a prior changed between the hash and the derivation is stale (3), not invalid" jq -e '.rc==3 and (.out|fromjson|.reasons|index("stale")!=null)' <<<"$swapr"
  check "and no bundle was written" test ! -e "$b"
  mkret spec 1 2; norm spec 1 --rebuild-stale; prev "$p" "$(vpath spec 1)" "$(vpath spec 2)"
  bund "$p" "$b"
  printf 'SPEC CLEAN again\n' >> "$(vpath spec 2)"
  valid "$p" "$b"; refused 3 stale "a prior changed after bundling fails validate-bundle"
}

t_private_previous_original_root() {
  newroot priv; mkret spec 1 1; norm spec 1
  local d p before; d=$(privdir priv); p="$d/PREVIOUS.json"; prev "$p" "$(vpath spec 1)"
  before=$(inventory "$d")
  bund "$p" "$R/specs/design/subject.md.critic-spec-r2-op.bundle.json"; okrun "a PREVIOUS in a private directory bundles"
  check "the bundle names only original beside-SPEC paths" bash -c "! grep -qF '$d' '$R/specs/design/subject.md.critic-spec-r2-op.bundle.json'"
  valid "$p" "$R/specs/design/subject.md.critic-spec-r2-op.bundle.json"; okrun "validate-bundle succeeds"
  check "the private carrier directory is unchanged by bundle and validate-bundle" test "$(inventory "$d")" = "$before"
  cp "$(vpath spec 1)" "$d/copy.critic-spec-r1.md"
  prev "$d/copy.json" "$d/copy.critic-spec-r1.md"; bund "$d/copy.json" "$R/other.bundle.json"
  refused 2 noncanonical-location "a copy inside the private carrier never becomes the evidence root"
}

t_index_symlink_or_escape_refused() {
  newroot esc; mkret spec 1 1
  printf 'victim\n' > "$R/victim.txt"; local vh; vh=$(sha "$R/victim.txt")
  ln -s "$R/victim.txt" "$(idx spec 1)"; norm spec 1; refused 2 noncanonical-location "a symlinked index path"
  check "the symlink target is untouched" test "$(sha "$R/victim.txt")" = "$vh"
  rm -f "$(idx spec 1)"
  ln -s "$R/victim.txt" "$(idx spec 1).lock"; norm spec 1; refused 2 noncanonical-location "a symlinked lock path"
  check "the lock symlink target is untouched" test "$(sha "$R/victim.txt")" = "$vh"
  rm -f "$(idx spec 1).lock"
  cf normalize --spec "$SPEC" --kind spec --round 1 --verdict "$(vpath spec 1)" --out "$R/specs/plans/escape.json"; refused 2 noncanonical-location "an --out that escapes the verdict's folder"
  check "nothing was written at the escape path" test ! -e "$R/specs/plans/escape.json"
  norm spec 1; okrun "the plain path still works"
  local p; p="$(privdir esc)/PREVIOUS.json"; prev "$p" "$(vpath spec 1)"
  mv "$(idx spec 1)" "$R/real-index.json"; ln -s "$R/real-index.json" "$(idx spec 1)"
  bund "$p" "$R/esc.bundle.json"; refused 2 noncanonical-location "a prior whose index is a symlink"
  rm -f "$(idx spec 1)"; mv "$R/real-index.json" "$(idx spec 1)"
  ln -s "$R/victim.txt" "$R/esc.bundle.json"; bund "$p" "$R/esc.bundle.json"; refused 2 noncanonical-location "a symlinked bundle output"
  check "the bundle symlink target is untouched" test "$(sha "$R/victim.txt")" = "$vh"
}

t_intake_exit_json() {
  newroot ex; mkret spec 1 1; norm spec 1
  okrun "normalize success exits 0 with JSON"; check "normalize prints the INDEX" test "$OUT" = "$(cat "$(idx spec 1)")"
  check "one JSON document on one line" test "$(printf '%s\n' "$OUT" | wc -l)" = 1
  local p; p="$(privdir ex)/PREVIOUS.json"; prev "$p" "$(vpath spec 1)"
  bund "$p" "$R/ex.bundle.json"; okrun "bundle exits 0"; check "bundle prints the BUNDLE" test "$OUT" = "$(cat "$R/ex.bundle.json")"
  valid "$p" "$R/ex.bundle.json"; okrun "validate-bundle exits 0"; check "validate-bundle prints the BUNDLE" test "$OUT" = "$(cat "$R/ex.bundle.json")"
  local keys='keys==["kind","operation","reasons","schema","state"]'
  mklegacy spec 2 "SPEC CLEAN"; norm spec 2
  check "a refusal has exactly the specified keys and operation" jq -e "$keys and .operation==\"normalize\" and .state==\"refused\"" <<<"$OUT"
  check "a refusal is one JSON document" test "$(printf '%s\n' "$OUT" | jq -s length)" = 1
  rm -f "$R/ex.bundle.json"; printf '{"schema":1}\n' > "$T/priv-ex/o.json"; bund "$T/priv-ex/o.json" "$R/x.json"
  check "bundle refusal names its operation" jq -e "$keys and .operation==\"bundle\"" <<<"$OUT"
  valid "$p" "$R/none.json"; check "validate-bundle refusal names its operation" jq -e "$keys and .operation==\"validate-bundle\"" <<<"$OUT"
  local bad argv
  for bad in "" "wat" "normalize" "normalize --spec $SPEC" "bundle --bogus" "validate-bundle"; do
    read -r -a argv <<<"$bad"
    cf "${argv[@]+"${argv[@]}"}"; refused 2 invalid "malformed CLI '$bad' exits 2 with a refusal JSON"
  done
}

t_original_verdict_immutable() {
  newroot imm; mkret spec 1 2; mkret spec 2 0
  local v1 v2 h1 h2 p; v1=$(vpath spec 1); v2=$(vpath spec 2); h1=$(sha "$v1"); h2=$(sha "$v2"); p="$(privdir imm)/PREVIOUS.json"
  norm spec 1; norm spec 1; norm spec 2; prev "$p" "$v1" "$v2"; bund "$p" "$R/imm.bundle.json"
  local before; before=$(inventory "$R")
  valid "$p" "$R/imm.bundle.json"; okrun "validate-bundle succeeds"
  check "the evidence inventory is identical around validate-bundle (no lock, no output)" test "$(inventory "$R")" = "$before"
  mklegacy spec 3 "SPEC FINDINGS 1"; norm spec 3
  check "original verdict bytes are unchanged by normalize, bundle, validate-bundle and a refusal" test "$(sha "$v1") $(sha "$v2")" = "$h1 $h2"
  before=$(inventory "$R")
  valid "$T/priv-imm/nope.json" "$R/imm.bundle.json"; refused 3 missing "a refused validate-bundle also leaves the evidence alone"
  check "inventory still identical after the refusal" test "$(inventory "$R")" = "$before"
}

t_idempotent_output_no_overwrite() {
  newroot idem; mkret spec 1 1; norm spec 1; local i m; i=$(idx spec 1)
  m=$(fstat "$i"); local content; content=$(cat "$i"); sleep 1
  norm spec 1; okrun "the second normalize succeeds"
  check "the identical index is not rewritten (same inode and mtime)" test "$(fstat "$i")" = "$m"
  check "the same bytes are printed" test "$OUT" = "$content"
  jq '.provenance.reviewer_id="someone-else"' "$i" -c > "$R/edit.json"; mv "$R/edit.json" "$i"; local edited; edited=$(sha "$i")
  norm spec 1; refused 2 index-conflict "different bytes at the same verdict hash refuse overwrite"
  check "the conflicting index is left as it was" test "$(sha "$i")" = "$edited"
  local p b; p="$(privdir idem)/PREVIOUS.json"; b="$R/idem.bundle.json"; rm -f "$i"; norm spec 1
  prev "$p" "$(vpath spec 1)"; bund "$p" "$b"; okrun "bundle writes once"; local bb; bb=$(sha "$b"); m=$(fstat "$b"); sleep 1
  bund "$p" "$b"; okrun "an identical bundle is idempotent"; check "the bundle is not rewritten" test "$(fstat "$b")" = "$m"
  mkret spec 2 0; norm spec 2; prev "$p" "$(vpath spec 1)" "$(vpath spec 2)"
  bund "$p" "$b"; refused 2 index-conflict "a different bundle at the same path is not overwritten"
  check "the bundle is unchanged" test "$(sha "$b")" = "$bb"
  check "no archive appeared from a plain conflict" test "$(nfiles "$R/specs/design" '*previous*')" = 0
}

t_forged_empty_index_refused() {
  newroot forge; mkret spec 1 1; norm spec 1
  local i p; i=$(idx spec 1); p="$(privdir forge)/PREVIOUS.json"; prev "$p" "$(vpath spec 1)"
  jq -c '.findings=[]' "$i" > "$R/forged.json"; mv "$R/forged.json" "$i"
  bund "$p" "$R/forge.bundle.json"; refused 2 invalid "a forged empty index does not cover a FINDINGS return"
  norm spec 1; refused 2 index-conflict "normalize will not replace the forged index at the same hash"
  norm spec 1 --rebuild-stale; refused 2 index-conflict "--rebuild-stale does not replace a same-hash forged index"
  check "no archive was made" test "$(nfiles "$R/specs/design" '*.previous.*')" = 0
  rm -f "$i"; norm spec 1; bund "$p" "$R/forge.bundle.json"; okrun "the honest index bundles"
  jq -c '.findings=[]' "$i" > "$R/forged.json"; mv "$R/forged.json" "$i"
  valid "$p" "$R/forge.bundle.json"; refused 2 invalid "validate-bundle also refuses the forged index"
  rm -f "$i"; norm spec 1; sedi 's/"round":1,/"round":1.0,/' "$i"
  rm -f "$R/forge.bundle.json"; bund "$p" "$R/forge.bundle.json"; refused 2 invalid "an index whose round is 1.0 is not the index"
}

t_seal_after_index_stale_then_renormalize() {
  newsealroot seal; printf '<html>rendered</html>\n' > "$R/specs/design/subject.html"; EXTRA_READ="$R/specs/design/subject.html"
  mkret spec 1 2; local v i p b h0 h1 h2; v=$(vpath spec 1); i=$(idx spec 1); p="$(privdir seal)/PREVIOUS.json"; b="$R/seal.bundle.json"
  norm spec 1; okrun "the unsealed saved bytes can be indexed"; h0=$(sha "$v")
  bash "$SEALSH" "$v" "$SPEC" "$(sha "$SPEC")" >"$T/seal.out" 2>&1; local src=$?
  check "the first seal succeeds (0)" test "$src" = 0
  h1=$(sha "$v"); check "the seal changed the verdict hash" test "$h1" != "$h0"
  prev "$p" "$v"; bund "$p" "$b"; refused 3 stale "a bundle over the pre-seal index is stale"
  norm spec 1; refused 3 stale-index "default normalize reports stale-index"
  check "the stale index is left in place" jq -e --arg h "$h0" '.verdict.sha256==$h' "$i"
  local old; old=$(sha "$i")
  norm spec 1 --rebuild-stale; okrun "renormalize with --rebuild-stale succeeds"
  check "the index is rebound to the sealed bytes with the same findings" jq -e --arg h "$h1" '.verdict.sha256==$h and (.findings|length)==2' "$i"
  check "the old index is archived under its own hash" test -f "$i.previous.$old.json"
  prev "$p" "$v"; bund "$p" "$b"; okrun "the bundle now succeeds"
  bash "$SEALSH" "$v" "$SPEC" "$(sha "$SPEC")" >"$T/seal.out" 2>&1; src=$?
  check "a second seal of the same file is refused (1)" test "$src" = 1
  check "the refused seal left the verdict unchanged" test "$(sha "$v")" = "$h1"
  norm spec 1; okrun "the index is still current after the refused seal"
  bash "$SEALSH" "$v" "$EXTRA_READ" "$(sha "$EXTRA_READ")" >"$T/seal.out" 2>&1; src=$?
  check "a seal of another quoted file succeeds (0)" test "$src" = 0
  h2=$(sha "$v"); check "and changes the hash again" test "$h2" != "$h1"
  norm spec 1; refused 3 stale-index "the index is stale again"
  norm spec 1 --rebuild-stale; okrun "rebuilt again"
  check "the count is unchanged" jq -e --arg h "$h2" '.verdict.sha256==$h and (.findings|length)==2' "$i"
  check "both archives are kept" test "$(nfiles "$R/specs/design" '*.finding-index.json.previous.*')" = 2
}

t_rebuild_archives_old_index() {
  newroot rb; mkret spec 1 1; local v i old new; v=$(vpath spec 1); i=$(idx spec 1)
  norm spec 1 --rebuild-stale; refused 3 missing "--rebuild-stale without an existing index refuses"
  norm spec 1; old=$(sha "$i")
  norm spec 1 --rebuild-stale; okrun "an index that is current is idempotent under the flag"
  check "no archive for a current index" test "$(nfiles "$R/specs/design" '*.previous.*')" = 0
  local oldbytes; oldbytes=$(cat "$i")
  printf 'CONTENT-SHA256 %s x\n' "$(printf 'z' | sha256s)" > "$R/line"
  python3 -I -c 'import sys; p=sys.argv[1]; t=open(p).read(); c=t.rstrip("\n").rfind("\n")+1; open(p,"w").write(t[:c]+open(sys.argv[2]).read()+t[c:])' "$v" "$R/line"
  mkdir -p "$R/pre"; cp "$i" "$R/pre/old.json"
  printf 'different\n' > "$i.previous.$old.json"
  norm spec 1 --rebuild-stale; refused 2 index-conflict "an archive with different bytes at the archive name refuses"
  check "the index was not replaced when the archive failed" test "$(sha "$i")" = "$old"
  rm -f "$i.previous.$old.json"; cp "$R/pre/old.json" "$i.previous.$old.json"
  norm spec 1 --rebuild-stale; okrun "an identical existing archive is idempotent"
  new=$(sha "$i"); check "the index now binds the current hash" jq -e --arg h "$(sha "$v")" '.verdict.sha256==$h' "$i"
  check "the archive holds the old bytes exactly" test "$(cat "$i.previous.$old.json")" = "$oldbytes"
  check "the new index differs from the old" test "$new" != "$old"
  check "the rebuild never edited the verdict beyond the test's own seal line" test "$(grep -c '^CONTENT-SHA256 ' "$v")" = 1
  newroot rb-bind; mkret spec 1 1; norm spec 1; mkret spec 2 1; cp "$(idx spec 1)" "$(idx spec 2)"
  python3 -I -c 'import sys; p=sys.argv[1]; t=open(p).read(); c=t.rstrip("\n").rfind("\n")+1; open(p,"w").write(t[:c]+"CONTENT-SHA256 "+"b"*64+" x\n"+t[c:])' "$(vpath spec 2)"
  norm spec 2 --rebuild-stale; refused 2 index-conflict "an index bound to another round is not rebuilt"
}

t_current_hash_conflict_refused() {
  newroot ch; mkret spec 1 1; norm spec 1; local i b; i=$(idx spec 1)
  jq -c '.findings[0].severity="critical"' "$i" > "$R/e.json"; mv "$R/e.json" "$i"; b=$(sha "$i")
  norm spec 1; refused 2 index-conflict "same verdict hash, different index: refused"
  norm spec 1 --rebuild-stale; refused 2 index-conflict "still refused with --rebuild-stale"
  check "the index is untouched" test "$(sha "$i")" = "$b"
  check "no archive was made" test "$(nfiles "$R/specs/design" '*.previous.*')" = 0
  printf 'not json\n' > "$i"; norm spec 1 --rebuild-stale; refused 2 index-conflict "a structurally invalid index is not rebuilt"
}

race() { python3 -I "$T/race.py" "$FINDINGS" "$@"; }
seal_line() { python3 -I -c 'import sys; p=sys.argv[1]; t=open(p).read(); c=t.rstrip("\n").rfind("\n")+1; open(p,"w").write(t[:c]+"CONTENT-SHA256 "+"c"*64+" x\n"+t[c:])' "$1"; }

t_rebuild_race_refused() {
  local sc r
  for sc in index-changed verdict-changed; do
    newroot "race-$sc"; mkret spec 1 1; norm spec 1; seal_line "$(vpath spec 1)"
    local before; before=$(cat "$(idx spec 1)")
    r=$(race "$sc" "$SPEC" spec 1 "$(vpath spec 1)" "$(idx spec 1)" 2>"$T/race.err"); OUT=$r
    check "$sc: the rebuild reports refusal 3/stale-index" jq -e '.rc==3 and (.out|fromjson|.reasons|index("stale-index")!=null)' <<<"$r"
    check "$sc: the old index was archived before the race" test "$(nfiles "$R/specs/design" '*.finding-index.json.previous.*')" = 1
    if [ "$sc" = index-changed ]; then check "$sc: the other writer's index is not overwritten" test "$(cat "$(idx spec 1)")" = '{"someone":"else"}'
    else check "$sc: the stale index was not replaced" test "$(cat "$(idx spec 1)")" = "$before"; fi
  done
  newroot race-new; mkret spec 1 1; norm spec 1; seal_line "$(vpath spec 1)"
  r=$(race new-index-written "$SPEC" spec 1 "$(vpath spec 1)" "$(idx spec 1)" 2>"$T/race.err"); OUT=$r
  check "an identical new index written meanwhile is idempotent success" jq -e '.rc==0' <<<"$r"
  check "and it binds the current verdict" jq -e --arg h "$(sha "$(vpath spec 1)")" '.verdict.sha256==$h' "$(idx spec 1)"
}

t_concurrent_rebuild_no_lost_update() {
  newroot conc; mkret spec 1 1; norm spec 1; seal_line "$(vpath spec 1)"
  local old r; old=$(sha "$(idx spec 1)")
  r=$(race concurrent "$SPEC" spec 1 "$(vpath spec 1)" "$(idx spec 1)" 2>"$T/race.err"); OUT=$r
  check "the first writer finishes with 0" jq -e '.rc==0' <<<"$r"
  check "the second writer, started while the first holds the lock, gets 3/busy" jq -e '.second.rc==3 and (.second.out|fromjson|.reasons|index("busy")!=null)' <<<"$r"
  check "the archive of the first writer is preserved" test -f "$(idx spec 1).previous.$old.json"
  check "no update was lost: the index binds the current verdict" jq -e --arg h "$(sha "$(vpath spec 1)")" '.verdict.sha256==$h' "$(idx spec 1)"
  check "the lock file stays as a working artifact" test -f "$(idx spec 1).lock"
  printf '{"schema":1,"verdicts":[]}\n' > "$(privdir conc)/p.json"
  OUT=$(python3 -I -c '
import fcntl, subprocess, sys
spec, prevf, out, finder = sys.argv[1:5]
fd = open(out + ".lock", "a+")
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
r = subprocess.run([sys.executable, "-I", finder, "bundle", "--spec", spec, "--previous-verdicts", prevf, "--out", out], capture_output=True, text=True)
print(r.returncode, r.stdout)
' "$SPEC" "$(privdir conc)/p.json" "$R/held.bundle.json" "$FINDINGS")
  check "a bundle writer against a held lock gets 3/busy" bash -c "case '$OUT' in 3\ *busy*) exit 0;; *) exit 1;; esac"
  check "and wrote no output" test ! -e "$R/held.bundle.json"
}

TESTS="charters_bytes_unchanged prompt_metadata_contract format_file_example_normalizes structured_index_count clean_requires_complete_index empty_previous_bundle legacy_missing_not_zero legacy_return_refused_exit3 canonical_filename_kind_round canonical_verdict_names_shared noncanonical_location_refused every_declared_prior_bound private_previous_original_root index_symlink_or_escape_refused intake_exit_json original_verdict_immutable idempotent_output_no_overwrite forged_empty_index_refused seal_after_index_stale_then_renormalize rebuild_archives_old_index current_hash_conflict_refused rebuild_race_refused concurrent_rebuild_no_lost_update"
ONLY="${1:-}"
if [ -n "$ONLY" ] && ! case " $TESTS " in *" $ONLY "*) true ;; *) false ;; esac; then
  echo "FATAL: unknown test name: $ONLY"; exit 2
fi
for t in $TESTS; do
  [ -z "$ONLY" ] || [ "$ONLY" = "$t" ] || continue
  printf '== %s\n' "$t"
  OUT=""; "t_$t"
done
if [ -z "$ONLY" ]; then
  bash "$0" no_such_test >/dev/null 2>&1; unknown_rc=$?
  check "an unknown test name is refused with exit 2" test "$unknown_rc" = 2
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
