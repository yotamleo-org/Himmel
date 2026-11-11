#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# test-minerva-readiness.sh — the optional `minerva-spec-gate.sh SPEC --readiness MANIFEST
# --source-head SHA` mode. Every row runs the real gate against inputs built by the real Judge
# delegate (scripts/handover/chief-kit/critic-findings.py normalize and bundle), and the gate
# calls that real delegate's validate-bundle. The python3 on PATH is a recorder that logs the
# delegate argv and execs the real interpreter; there is no stub gate or stub validator.
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY CLAUDE_PLUGIN_ROOT HIMMEL_REPO

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../../../.." && pwd -P)"
gate="$here/minerva-spec-gate.sh"
fx="$here/fixtures/minerva-readiness"
judge="$repo/scripts/handover/chief-kit/critic-findings.py"
real_py="$(command -v python3)" || { echo "FATAL: python3 is needed"; exit 2; }
[ -f "$judge" ] && [ -f "$repo/scripts/lib/initiative-workers.sh" ] || { echo "FATAL: the Judge delegate or the checkout marker is missing"; exit 2; }
SH=0123456789abcdef0123456789abcdef01234567

td="$(mktemp -d "${TMPDIR:-/tmp}/minerva-readiness.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
td="$(cd "$td" && pwd -P)" || exit 1
trap 'rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }

mkdir -p "$td/bin" "$td/elsewhere"
cat >"$td/bin/python3" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${1:-}" >>"\$READINESS_CALLS_LOG"
case "\${1:-}" in *critic-findings.py) printf '%s\n' "\$@" >"\$READINESS_ARGV_LOG";; esac
exec "$real_py" "\$@"
EOF
printf '#!/usr/bin/env bash\necho PATH-CALL >>"$READINESS_CALLS_LOG"\nexit 99\n' >"$td/bin/critic-findings.py"
chmod +x "$td/bin/python3" "$td/bin/critic-findings.py"

sha(){ "$real_py" -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
judge_run(){ JOUT="$("$real_py" -I "$judge" "$@" 2>/dev/null)"; JRC=$?; }

# mktree <name> <specs subdir>: a state repo with SPEC, its estimate, a plan beside it and one in
# specs/plans, a disposition evidence file, and a marker + delegate copy at its root (a trap: the
# gate must never resolve its delegate from SPEC's repository).
mktree(){
  T="$td/$1"; ROOT="$T/specs/$2"; SPEC="$ROOT/feature.md"; PLAN="$T/specs/plans/feature.md"
  mkdir -p "$ROOT" "$T/specs/plans" "$T/scripts/lib" "$T/scripts/handover/chief-kit"
  cp "$fx/spec.md" "$SPEC"; cp "$fx/estimate.json" "$ROOT/estimate.json"
  cp "$fx/plan.md" "$ROOT/feature-plan.md"; cp "$fx/plan.md" "$PLAN"
  echo "fixed in the spec" >"$ROOT/evidence.md"
  : >"$T/scripts/lib/initiative-workers.sh"; cp "$judge" "$T/scripts/handover/chief-kit/critic-findings.py"
}
# addverdict <kind> <round> <fixture>: the saved critic return plus its real normalized index.
addverdict(){
  local v="$SPEC.critic-$1-r$2.md"
  cp "$fx/$3" "$v"
  judge_run normalize --spec "$SPEC" --kind "$1" --round "$2" --verdict "$v" --out "$v.finding-index.json"
  [ "$JRC" = 0 ] || { echo "FATAL: real normalize refused $v: $JOUT"; exit 2; }
}
# mkbundle <out> <verdict paths...>: the real Judge bundle over exactly those priors.
mkbundle(){
  local out="$1" prev="$td/prev.$RANDOM.json"; shift
  "$real_py" -I -c 'import hashlib,json,sys
rows=[{"path":p,"sha256":hashlib.sha256(open(p,"rb").read()).hexdigest()} for p in sys.argv[2:]]
open(sys.argv[1],"w").write(json.dumps({"schema":1,"verdicts":rows}))' "$prev" "$@"
  judge_run bundle --spec "$SPEC" --previous-verdicts "$prev" --out "$out"
  [ "$JRC" = 0 ] || { echo "FATAL: real bundle refused $out: $JOUT"; exit 2; }
}

# mkman <out> <spec> <kind> <round> <artifact> <companion|-> <bundle> <verdicts csv|-> [python stmt on m]
MK='import hashlib,json,os,sys
out,spec,kind,rnd,art,comp,bundle,verdicts,head,stmt=sys.argv[1:11]
def h(p):
    try: return hashlib.sha256(open(p,"rb").read()).hexdigest()
    except OSError: return "0"*64
def ref(p): return {"path":p,"sha256":h(p)}
root=os.path.dirname(spec)
try: pf=json.load(open(bundle))["previous_findings"]
except (OSError,ValueError,KeyError): pf=[]
m={"schema":1,"critic_kind":kind,"round":int(rnd),"artifact":ref(art),
   "companion":None if comp=="-" else ref(comp),"source_head":head,
   "estimate":ref(os.path.join(root,"estimate.json")),"finding_intake":ref(bundle),
   "previous_verdicts":[] if verdicts=="-" else [ref(v) for v in verdicts.split(",")],
   "previous_findings":pf,
   "dispositions":[{"finding_id":f["finding_id"],"state":"fixed","evidence_path":os.path.join(root,"evidence.md")} for f in pf],
   "unresolved_rulings":[]}
raw=None
exec(stmt)
open(out,"w").write(raw if raw is not None else json.dumps(m))'
mkman(){ "$real_py" -I -c "$MK" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$SH" "${9:-}"; }

# rawrun <gate> <args...>: from an unrelated cwd (CWD overrides), HIMMEL_REPO unset unless ANCHOR.
rawrun(){
  local g="$1"; shift
  local envs=("PATH=$td/bin:$PATH" "READINESS_ARGV_LOG=$td/argv" "READINESS_CALLS_LOG=$td/calls")
  [ -n "${ANCHOR:-}" ] && envs+=("HIMMEL_REPO=$ANCHOR")
  : >"$td/argv"; : >"$td/calls"
  OUT="$(cd "${CWD:-$td/elsewhere}" && env -u HIMMEL_REPO "${envs[@]}" bash "$g" "$@" 2>"$td/err")"; RC=$?
}
run(){ rawrun "${GATE:-$gate}" "$1" --readiness "$2" --source-head "$SH"; }

CHECK='import json,os,sys
out,state,reason,extra=sys.argv[1:5]
KEYS={"schema","kind","state","critic_kind","round","manifest_sha256","source_head","artifact","companion","estimate","finding_intake_sha256","reasons"}
lines=out.strip().split("\n")
assert len(lines)==1, "stdout is not one JSON line"
r=json.loads(lines[0])
assert set(r)==KEYS, sorted(r)
assert r["schema"]==1 and r["kind"]=="critic-readiness" and r["state"]==state, r
if state=="ready":
    assert r["reasons"]==[], r
    for k in KEYS-{"companion"}: assert r[k] is not None, k
    assert (r["companion"] is None)==(r["critic_kind"]=="spec"), r
else:
    assert r["reasons"]==[reason], r["reasons"]
if extra: assert eval(extra,{"r":r,"os":os}), extra'
# expect <label> <rc> <ready|refused> <reason|-> [python expression on r]
expect(){
  if [ "$RC" = "$2" ] && "$real_py" -I -c "$CHECK" "$OUT" "$3" "$4" "${5:-}" 2>"$td/why"; then ok "$1"
  else bad "$1 (rc=$RC want $2; $(tr '\n' ' ' <"$td/why" | head -c 200); out=$(printf '%s' "$OUT" | head -c 300); err=$(head -c 200 "$td/err"))"; fi
}
argv_line(){ sed -n "${1}p" "$td/argv"; }
no_delegate_call(){ [ ! -s "$td/argv" ] && ! grep -q 'critic-findings\|PATH-CALL' "$td/calls"; }

# ---- tree A: specs/design, spec priors r1 (one finding) and r2 (CLEAN), a plan prior r1 (CLEAN)
mktree A design; A_SPEC="$SPEC"; A_ROOT="$ROOT"; A_PLAN="$PLAN"
addverdict spec 1 verdict-spec-r1-findings.md; addverdict spec 2 verdict-spec-clean.md
A_V="$SPEC.critic-spec-r1.md,$SPEC.critic-spec-r2.md"
mkbundle "$ROOT/intake-spec-r3.json" "$SPEC.critic-spec-r1.md" "$SPEC.critic-spec-r2.md"; A_B="$ROOT/intake-spec-r3.json"
mkbundle "$ROOT/intake-spec-r1.json"; A_B1="$ROOT/intake-spec-r1.json"
addverdict plan 1 verdict-plan-clean.md
mkbundle "$ROOT/intake-plan-r2.json" "$SPEC.critic-plan-r1.md"; A_BP="$ROOT/intake-plan-r2.json"; A_VP="$SPEC.critic-plan-r1.md"
cp "$A_SPEC" "$A_ROOT/other.md"
m="$td/m"; mkdir -p "$m"

# ---- the eight R1-R4 variants
mkman "$m/r1-good.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V"
run "$A_SPEC" "$m/r1-good.json"; expect "R1-good: spec intake with a complete CLEAN prior is ready 0" 0 ready - 'r["round"]==3 and r["companion"] is None'
R1_OUT="$OUT"
mkman "$m/r1-bad.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["dispositions"]=[]'
run "$A_SPEC" "$m/r1-bad.json"; expect "R1-bad: a missing canonical disposition is disposition-mismatch 3" 3 refused disposition-mismatch
mkman "$m/r2-good.json" "$A_SPEC" plan 2 "$A_PLAN" "$A_SPEC" "$A_BP" "$A_VP"
run "$A_SPEC" "$m/r2-good.json"; expect "R2-good: a plan bound to SPEC is ready 0" 0 ready -
mkman "$m/r2-bad.json" "$A_SPEC" plan 2 "$A_PLAN" "$A_ROOT/other.md" "$A_BP" "$A_VP"
run "$A_SPEC" "$m/r2-bad.json"; expect "R2-bad: a sibling-SPEC companion is invalid 2" 2 refused invalid
mkman "$m/r3-good.json" "$A_SPEC" spec 1 "$A_SPEC" - "$A_B1" -
run "$A_SPEC" "$m/r3-good.json"; expect "R3-good: current artifact and source hashes are ready 0" 0 ready -
mkman "$m/r3-bad.json" "$A_SPEC" spec 1 "$A_SPEC" - "$A_B1" - 'm["artifact"]["sha256"]="f"*64'
run "$A_SPEC" "$m/r3-bad.json"; expect "R3-bad: a stale artifact hash is stale-artifact 3" 3 refused stale-artifact
mkman "$m/r4-good.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["unresolved_rulings"]=[]'
run "$A_SPEC" "$m/r4-good.json"; expect "R4-good: resolved inputs are ready 0" 0 ready -
mkman "$m/r4-bad.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["unresolved_rulings"]=["ruling-7"]'
run "$A_SPEC" "$m/r4-bad.json"; expect "R4-bad: an unresolved ruling is unresolved-ruling 3" 3 refused unresolved-ruling

# ---- ready-is-not-authorized: the real ready receipt carries provenance only
OUT="$R1_OUT"; RC=0
expect "ready-is-not-authorized: no model, round grant, spend or clearance field; round is a plain integer" 0 ready - \
  'type(r["round"]) is int and not any(w in k for k in r for w in ("model","grant","spend","budget","clear","approv","authori","go"))'

# ---- judge-argv-contract: plan kind from an unrelated cwd still passes the canonical SPEC as --spec
run "$A_SPEC" "$m/r2-good.json"
prev="$(argv_line 7)"
if [ "$(argv_line 1)" = "$judge" ] && [ "$(argv_line 2)" = validate-bundle ] && [ "$(argv_line 3)" = "$A_BP" ] \
   && [ "$(argv_line 4)" = --spec ] && [ "$(argv_line 5)" = "$A_SPEC" ] && [ "$(argv_line 6)" = --previous-verdicts ] \
   && [ "$(basename "$prev")" = PREVIOUS.json ] && case "$prev" in "$td/A/"*) false;; /*) true;; *) false;; esac \
   && [ ! -e "$prev" ] && [ -z "$(argv_line 8)" ]; then
  ok "judge-argv-contract: python3 ABS_DELEGATE validate-bundle ABS_BUNDLE --spec SPEC --previous-verdicts PRIVATE/PREVIOUS.json"
else bad "judge-argv-contract: recorded argv: $(tr '\n' ' ' <"$td/argv")"; fi

# ---- spec-stage-no-companion-ready and plan-kind-companion-is-spec
run "$A_SPEC" "$m/r3-good.json"; expect "spec-stage-no-companion-ready: spec kind with a null companion is ready" 0 ready - 'r["companion"] is None and r["artifact"]["path"]=='"'$A_SPEC'"
mkman "$m/spec-comp.json" "$A_SPEC" spec 1 "$A_SPEC" "$A_SPEC" "$A_B1" -
run "$A_SPEC" "$m/spec-comp.json"; expect "spec-stage-no-companion-ready: spec kind with a companion is invalid 2" 2 refused invalid
run "$A_SPEC" "$m/r2-good.json"; expect "plan-kind-companion-is-spec: the ready companion is SPEC and the artifact the requested plan" 0 ready - \
  'r["companion"]["path"]=='"'$A_SPEC'"' and r["artifact"]["path"]=='"'$A_PLAN'"' and r["critic_kind"]=="plan"'
mkman "$m/plan-nocomp.json" "$A_SPEC" plan 2 "$A_PLAN" - "$A_BP" "$A_VP"
run "$A_SPEC" "$m/plan-nocomp.json"; expect "plan-kind-companion-is-spec: plan kind with a null companion is invalid 2" 2 refused invalid
mkman "$m/plan-is-spec.json" "$A_SPEC" plan 2 "$A_SPEC" "$A_SPEC" "$A_BP" "$A_VP"
run "$A_SPEC" "$m/plan-is-spec.json"; expect "plan-kind-companion-is-spec: a plan artifact equal to SPEC is invalid 2" 2 refused invalid
mkman "$m/spec-is-plan.json" "$A_SPEC" spec 1 "$A_PLAN" - "$A_B1" -
run "$A_SPEC" "$m/spec-is-plan.json"; expect "spec kind naming the plan as its artifact (the plan exception) is invalid 2" 2 refused invalid
mkman "$m/spec-sibling.json" "$A_SPEC" spec 1 "$A_ROOT/other.md" - "$A_B1" -
run "$A_SPEC" "$m/spec-sibling.json"; expect "spec kind with a sibling-spec artifact is invalid 2" 2 refused invalid

# ---- readiness-round-type-echo
for c in 'del m["round"]|missing' 'm["round"]=0|zero' 'm["round"]=-1|negative' 'm["round"]="2"|string' 'm["round"]=True|boolean'; do
  mkman "$m/round.json" "$A_SPEC" spec 1 "$A_SPEC" - "$A_B1" - "${c%|*}"
  run "$A_SPEC" "$m/round.json"; expect "readiness-round-type-echo: a ${c#*|} round is invalid 2 with round=null" 2 refused invalid 'r["round"] is None'
done

# ---- clean-prior-complete-empty (tree C: one CLEAN prior before the second spec critic)
mktree C design; C_SPEC="$SPEC"
addverdict spec 1 verdict-spec-clean.md
mkbundle "$ROOT/intake.json" "$SPEC.critic-spec-r1.md"
mkman "$m/clean.json" "$C_SPEC" spec 2 "$C_SPEC" - "$ROOT/intake.json" "$SPEC.critic-spec-r1.md"
run "$C_SPEC" "$m/clean.json"; expect "clean-prior-complete-empty: an explicit complete CLEAN empty index is ready 0" 0 ready - \
  'r["finding_intake_sha256"]=="'"$(sha "$ROOT/intake.json")"'"'
expect "readiness-round-type-echo: round 2 echoes 2" 0 ready - 'r["round"]==2'
rm "$SPEC.critic-spec-r1.md.finding-index.json"
run "$C_SPEC" "$m/clean.json"; expect "clean-prior-complete-empty: an absent CLEAN index is intake-incomplete 3, never inferred zero" 3 refused intake-incomplete

# ---- legacy-intake-refused (tree L: a prose-only prior with no structured provenance)
mktree L design; L_SPEC="$SPEC"; LV="$SPEC.critic-spec-r1.md"
cp "$fx/verdict-legacy.md" "$LV"
judge_run normalize --spec "$SPEC" --kind spec --round 1 --verdict "$LV" --out "$LV.finding-index.json"
[ "$JRC" = 3 ] && case "$JOUT" in *legacy-provenance-missing*) true;; *) false;; esac \
  && ok "legacy-intake-refused: the real normalizer gives no index for prose-only provenance (exit 3)" \
  || bad "legacy-intake-refused: normalize rc=$JRC $JOUT"
"$real_py" -I -c 'import hashlib,json,sys
spec,v=sys.argv[1:3]
idx={"schema":1,"kind":"critic-finding-index","spec_path":spec,"critic_kind":"spec","round":1,
     "verdict":{"path":v,"sha256":hashlib.sha256(open(v,"rb").read()).hexdigest()},"complete":True,"findings":[],
     "provenance":{"method":"structured-return","reviewer_id":"unknown"}}
open(v+".finding-index.json","w").write(json.dumps(idx,separators=(",",":"))+"\n")
open(sys.argv[3],"w").write(json.dumps({"schema":1,"kind":"critic-findings-bundle","spec_path":spec,"verdicts":[],"previous_findings":[]},separators=(",",":"))+"\n")' \
  "$L_SPEC" "$LV" "$ROOT/intake.json"
"$real_py" -I -c 'import json,sys; json.dump({"schema":1,"verdicts":[{"path":sys.argv[2],"sha256":__import__("hashlib").sha256(open(sys.argv[2],"rb").read()).hexdigest()}]},open(sys.argv[1],"w"))' "$td/legacy-prev.json" "$LV"
judge_run validate-bundle "$ROOT/intake.json" --spec "$L_SPEC" --previous-verdicts "$td/legacy-prev.json"
[ "$JRC" = 3 ] && case "$JOUT" in *legacy-provenance-missing*) true;; *) false;; esac \
  && ok "legacy-intake-refused: the real delegate's validate-bundle answers legacy-provenance-missing (exit 3)" \
  || bad "legacy-intake-refused: validate-bundle rc=$JRC $JOUT"
mkman "$m/legacy.json" "$L_SPEC" spec 2 "$L_SPEC" - "$ROOT/intake.json" "$LV" 'm["dispositions"]=[{"finding_id":"spec-r1-1","state":"fixed","evidence_path":os.path.join(root,"evidence.md")}]; m["previous_findings"]=[]'
run "$L_SPEC" "$m/legacy.json"
expect "legacy-intake-refused: the gate maps it to intake-incomplete 3 and invents no finding IDs" 3 refused intake-incomplete \
  '"spec-r1" not in str(r)'
[ "$(argv_line 1)" = "$judge" ] && ok "legacy-intake-refused: only the real delegate was asked, no other reviewer" || bad "legacy-intake-refused: delegate argv $(tr '\n' ' ' <"$td/argv")"

# ---- judge-anchor-resolution
cache="$td/home/.claude/plugins/cache/himmel/himmel-ops/9.9.9/scripts"
mkdir -p "$cache"; cp "$gate" "$cache/minerva-spec-gate.sh"
GATE="$cache/minerva-spec-gate.sh" ANCHOR="$repo" run "$A_SPEC" "$m/r1-good.json"
expect "judge-anchor-resolution: a plugin-cache gate with a valid HIMMEL_REPO is ready" 0 ready -
[ "$(argv_line 1)" = "$judge" ] && ok "judge-anchor-resolution: it ran the anchor's absolute delegate" || bad "judge-anchor-resolution: argv $(tr '\n' ' ' <"$td/argv")"
GATE="$cache/minerva-spec-gate.sh" CWD="$td/A" run "$A_SPEC" "$m/r1-good.json"
expect "judge-anchor-resolution: unset anchor outside a gate-owned checkout is intake-incomplete 3" 3 refused intake-incomplete
no_delegate_call && ok "judge-anchor-resolution: no relative, PATH, cwd or SPEC-repo delegate was tried" || bad "judge-anchor-resolution: calls $(tr '\n' ' ' <"$td/calls")"
GATE="$cache/minerva-spec-gate.sh" CWD="$repo" ANCHOR="." run "$A_SPEC" "$m/r1-good.json"
expect "judge-anchor-resolution: a relative HIMMEL_REPO is not an anchor" 3 refused intake-incomplete
no_delegate_call && ok "judge-anchor-resolution: the relative anchor launched nothing" || bad "judge-anchor-resolution: calls $(tr '\n' ' ' <"$td/calls")"
mkdir -p "$td/nomarker/scripts/handover/chief-kit"; cp "$judge" "$td/nomarker/scripts/handover/chief-kit/critic-findings.py"
GATE="$cache/minerva-spec-gate.sh" ANCHOR="$td/nomarker" run "$A_SPEC" "$m/r1-good.json"
expect "judge-anchor-resolution: an anchor without the initiative-workers.sh marker is refused" 3 refused intake-incomplete
run "$A_SPEC" "$m/r1-good.json"
expect "judge-anchor-resolution: the gate's own marker-bound checkout is the fallback" 0 ready -
[ "$(argv_line 1)" = "$judge" ] && ok "judge-anchor-resolution: the fallback ran the checkout's absolute delegate" || bad "judge-anchor-resolution: argv $(tr '\n' ' ' <"$td/argv")"
fco="$td/fixco"; mkdir -p "$fco/scripts/lib" "$fco/scripts/handover/chief-kit" "$fco/marketplace/plugins/himmel-ops/scripts"
: >"$fco/scripts/lib/initiative-workers.sh"; cp "$judge" "$fco/scripts/handover/chief-kit/critic-findings.py"
cp "$gate" "$fco/marketplace/plugins/himmel-ops/scripts/minerva-spec-gate.sh"
GATE="$fco/marketplace/plugins/himmel-ops/scripts/minerva-spec-gate.sh" run "$A_SPEC" "$m/r1-good.json"
expect "judge-anchor-resolution: a gate inside a himmel fixture checkout uses that checkout" 0 ready -
[ "$(argv_line 1)" = "$fco/scripts/handover/chief-kit/critic-findings.py" ] && ok "judge-anchor-resolution: it ran the fixture checkout's delegate" || bad "judge-anchor-resolution: argv $(tr '\n' ' ' <"$td/argv")"
mkdir -p "$td/badco/scripts/lib" "$td/badco/scripts/handover/chief-kit"; : >"$td/badco/scripts/lib/initiative-workers.sh"
ln -s "$judge" "$td/badco/scripts/handover/chief-kit/critic-findings.py"
GATE="$cache/minerva-spec-gate.sh" ANCHOR="$td/badco" run "$A_SPEC" "$m/r1-good.json"
expect "judge-anchor-resolution: a delegate escaping the anchor is refused" 3 refused intake-incomplete
no_delegate_call && ok "judge-anchor-resolution: the escaping delegate was not run" || bad "judge-anchor-resolution: calls $(tr '\n' ' ' <"$td/calls")"
mkdir -p "$td/nodel/scripts/lib"; : >"$td/nodel/scripts/lib/initiative-workers.sh"
GATE="$cache/minerva-spec-gate.sh" ANCHOR="$td/nodel" run "$A_SPEC" "$m/r1-good.json"
expect "judge-anchor-resolution: a missing delegate is refused" 3 refused intake-incomplete

# ---- evidence-root-escape
mkman "$m/same-dir.json" "$A_SPEC" plan 2 "$A_ROOT/feature-plan.md" "$A_SPEC" "$A_BP" "$A_VP"
run "$A_SPEC" "$m/same-dir.json"; expect "evidence-root-escape: a plan beside SPEC is ready" 0 ready -
run "$A_SPEC" "$m/r2-good.json"; expect "evidence-root-escape: the specs/design + specs/plans layout is ready" 0 ready -
mktree D designs; D_SPEC="$SPEC"; D_PLAN="$PLAN"
addverdict plan 1 verdict-plan-clean.md; mkbundle "$ROOT/intake.json" "$SPEC.critic-plan-r1.md"
mkman "$m/designs.json" "$D_SPEC" plan 2 "$D_PLAN" "$D_SPEC" "$ROOT/intake.json" "$SPEC.critic-plan-r1.md"
run "$D_SPEC" "$m/designs.json"; expect "evidence-root-escape: the specs/designs + specs/plans layout is ready" 0 ready -
mktree X design
mkman "$m/other-bucket.json" "$A_SPEC" plan 2 "$PLAN" "$A_SPEC" "$A_BP" "$A_VP"
run "$A_SPEC" "$m/other-bucket.json"; expect "evidence-root-escape: a plan in another repo's specs/plans is invalid 2" 2 refused invalid
mktree S design; S_SPEC="$SPEC"
addverdict plan 1 verdict-plan-clean.md; mkbundle "$ROOT/intake.json" "$SPEC.critic-plan-r1.md"
mv "$T/specs/plans" "$T/specs/plans-real"; ln -s plans-real "$T/specs/plans"
mkman "$m/symdir.json" "$S_SPEC" plan 2 "$T/specs/plans/feature.md" "$S_SPEC" "$ROOT/intake.json" "$SPEC.critic-plan-r1.md"
run "$S_SPEC" "$m/symdir.json"; expect "evidence-root-escape: a symlinked specs/plans directory is invalid 2" 2 refused invalid
ln -s feature.md "$td/A/specs/plans/linked.md"
mkman "$m/symplan.json" "$A_SPEC" plan 2 "$td/A/specs/plans/linked.md" "$A_SPEC" "$A_BP" "$A_VP"
run "$A_SPEC" "$m/symplan.json"; expect "evidence-root-escape: a symlinked plan is invalid 2" 2 refused invalid
mktree O notes; O_SPEC="$SPEC"
addverdict plan 1 verdict-plan-clean.md; mkbundle "$ROOT/intake.json" "$SPEC.critic-plan-r1.md"
mkman "$m/notes.json" "$O_SPEC" plan 2 "$PLAN" "$O_SPEC" "$ROOT/intake.json" "$SPEC.critic-plan-r1.md"
run "$O_SPEC" "$m/notes.json"; expect "evidence-root-escape: specs/plans is no exception for a SPEC outside design/designs" 2 refused invalid
mkman "$m/intake-in-plans.json" "$A_SPEC" plan 2 "$A_PLAN" "$A_SPEC" "$A_BP" "$A_VP" 'm["finding_intake"]["path"]="'"$A_PLAN"'"'
run "$A_SPEC" "$m/intake-in-plans.json"; expect "evidence-root-escape: non-artifact evidence in specs/plans is invalid 2" 2 refused invalid
mkman "$m/escape.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["dispositions"][0]["evidence_path"]=os.path.join(root,"..","..","..","outside.md")'
echo outside >"$td/outside.md"
run "$A_SPEC" "$m/escape.json"; expect "evidence-root-escape: a ../ evidence path is invalid 2" 2 refused invalid
ln -s "$td/outside.md" "$A_ROOT/escape.md"
mkman "$m/escape-link.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["dispositions"][0]["evidence_path"]=os.path.join(root,"escape.md")'
run "$A_SPEC" "$m/escape-link.json"; expect "evidence-root-escape: an escaping symlink is invalid 2" 2 refused invalid
cp "$A_ROOT/estimate.json" "$A_ROOT/estimate-copy.json"
mkman "$m/other-est.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["estimate"]={"path":os.path.join(root,"estimate-copy.json"),"sha256":h(os.path.join(root,"estimate-copy.json"))}'
run "$A_SPEC" "$m/other-est.json"; expect "an estimate that is not SPEC's own Estimate record is invalid 2" 2 refused invalid
mkman "$A_ROOT/rel.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" \
  'for k in ("artifact","estimate","finding_intake"): m[k]["path"]=os.path.relpath(m[k]["path"],root)
for v in m["previous_verdicts"]: v["path"]=os.path.relpath(v["path"],root)
for d in m["dispositions"]: d["evidence_path"]=os.path.relpath(d["evidence_path"],root)'
run "$A_SPEC" "$A_ROOT/rel.json"; expect "manifest-relative paths resolve against the manifest's directory" 0 ready -

# ---- stale, missing and mismatched intake
mkman "$m/stale-src.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["source_head"]="b"*40'
run "$A_SPEC" "$m/stale-src.json"; expect "a manifest source_head other than --source-head is stale-source 3" 3 refused stale-source
mkman "$m/no-intake.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_ROOT/absent.json" "$A_V"
run "$A_SPEC" "$m/no-intake.json"; expect "a missing finding_intake bundle is intake-incomplete 3" 3 refused intake-incomplete
mkman "$m/no-evidence.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["dispositions"][0]["evidence_path"]=os.path.join(root,"absent.md")'
run "$A_SPEC" "$m/no-evidence.json"; expect "missing disposition evidence is disposition-mismatch 3" 3 refused disposition-mismatch
mkman "$m/extra-disp.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["dispositions"].append({"finding_id":"spec-r1-9","state":"deferred","evidence_path":os.path.join(root,"evidence.md")})'
run "$A_SPEC" "$m/extra-disp.json"; expect "a disposition for an unknown finding is disposition-mismatch 3" 3 refused disposition-mismatch
mkman "$m/pf.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["previous_findings"]=[]'
run "$A_SPEC" "$m/pf.json"; expect "previous_findings short of the validated bundle is intake-incomplete 3" 3 refused intake-incomplete
mkman "$m/one-prior.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_SPEC.critic-spec-r1.md"
run "$A_SPEC" "$m/one-prior.json"; expect "a bundle that does not match the declared priors is intake-invalid 2 (the delegate's exit 2)" 2 refused intake-invalid
mkman "$m/stale-prior.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["previous_verdicts"][1]["sha256"]="e"*64'
run "$A_SPEC" "$m/stale-prior.json"; expect "a stale prior verdict hash is intake-incomplete 3 (the delegate's exit 3)" 3 refused intake-incomplete

# ---- malformed input, before anything else
mkman "$m/badjson.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'raw="{not json"'
run "$A_SPEC" "$m/badjson.json"; expect "malformed manifest JSON is invalid 2" 2 refused invalid 'r["manifest_sha256"] is not None'
mkman "$m/dupkey.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'raw=json.dumps(m)[:-1]+",\"round\":3}"'
run "$A_SPEC" "$m/dupkey.json"; expect "a duplicate manifest key is invalid 2" 2 refused invalid
mkman "$m/authority.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["model"]="opus"'
run "$A_SPEC" "$m/authority.json"; expect "an unknown manifest field (an authority claim) is invalid 2" 2 refused invalid
mkman "$m/dupdisp.json" "$A_SPEC" spec 3 "$A_SPEC" - "$A_B" "$A_V" 'm["dispositions"]=m["dispositions"]*2'
run "$A_SPEC" "$m/dupdisp.json"; expect "a duplicate disposition is invalid 2" 2 refused invalid
mkman "$m/badkind.json" "$A_SPEC" review 3 "$A_SPEC" - "$A_B" "$A_V"
run "$A_SPEC" "$m/badkind.json"; expect "an unknown critic_kind is invalid 2 with critic_kind=null" 2 refused invalid 'r["critic_kind"] is None'
run "$A_SPEC" "$m/absent-manifest.json"; expect "a missing manifest is invalid 2" 2 refused invalid 'r["manifest_sha256"] is None'
rawrun "$gate" "$A_SPEC" --readiness "$m/r1-good.json" --source-head 0123abc
expect "a short --source-head is invalid 2" 2 refused invalid 'r["source_head"] is None'
rawrun "$gate" "$A_SPEC" --readiness "$m/r1-good.json"
expect "--readiness without --source-head is invalid 2" 2 refused invalid
rawrun "$gate" "$A_SPEC" --readiness "$m/r1-good.json" --source-head "$SH" --model opus
expect "an unknown flag is invalid 2" 2 refused invalid
rawrun "$gate" "$A_SPEC" --readiness "$m/r1-good.json" --readiness "$m/r1-good.json"
expect "a repeated --readiness is invalid 2" 2 refused invalid
rawrun "$gate" "$A_SPEC" --source-head "$SH" --readiness "$m/r1-good.json"
expect "the two flags in either order are accepted" 0 ready -

# ---- legacy-gate-failure-exit3: the whole old gate maps to estimate-refused 3 and keeps its stderr
run "$A_ROOT/absent.md" "$m/r1-good.json"
expect "legacy-gate-failure-exit3: a missing SPEC is estimate-refused 3" 3 refused estimate-refused
grep -q "spec file not found" "$td/err" && ok "legacy-gate-failure-exit3: the old missing-spec stderr survives" || bad "legacy-gate-failure-exit3: stderr $(cat "$td/err")"
run "$A_ROOT/absent.md" "$m/spec-comp.json"
expect "legacy-gate-failure-exit3: a missing SPEC with a kind binding error is still estimate-refused 3" 3 refused estimate-refused
run "$A_ROOT/absent.md" "$m/badjson.json"
expect "legacy-gate-failure-exit3: malformed JSON outranks a missing SPEC (invalid 2)" 2 refused invalid
grep -q "spec file not found" "$td/err" && bad "legacy-gate-failure-exit3: the old gate ran before the JSON check" || ok "legacy-gate-failure-exit3: the JSON check runs before the old gate"
mktree E design; E_ROOT="$ROOT"
"$real_py" -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["dod"]["passed"]=False; json.dump(d,open(sys.argv[2],"w"))' "$E_ROOT/estimate.json" "$E_ROOT/refused.json"
grep -v '^Estimate record:' "$fx/spec.md" >"$E_ROOT/no-est.md"
sed 's/^Estimate record: .*/Estimate record: refused.json/' "$fx/spec.md" >"$E_ROOT/bad-est.md"
awk '/^## Alternatives considered/{skip=1; next} /^## /{skip=0} !skip' "$fx/spec.md" >"$E_ROOT/no-alt.md"
awk '/^## Definition of done/{skip=1; next} /^## /{skip=0} !skip' "$fx/spec.md" >"$E_ROOT/no-dod.md"
for s in no-est bad-est no-alt no-dod; do
  mkman "$m/$s.json" "$E_ROOT/$s.md" spec 1 "$E_ROOT/$s.md" - "$E_ROOT/none.json" -
  run "$E_ROOT/$s.md" "$m/$s.json"
  expect "legacy-gate-failure-exit3: $s is estimate-refused 3" 3 refused estimate-refused
  grep -q "REFUSED" "$td/err" && ok "legacy-gate-failure-exit3: $s keeps the old REFUSED stderr" || bad "legacy-gate-failure-exit3: $s stderr $(cat "$td/err")"
done

# ---- default-off: without the flags the gate keeps its old text and exits
rawrun "$gate" "$A_SPEC"
[ "$RC" = 0 ] && [ "$OUT" = "minerva-spec-gate: ok" ] && ok "default-off: a passing spec prints the old ok line" || bad "default-off: rc=$RC out=$OUT"
rawrun "$gate" "$A_ROOT/absent.md"
[ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q "spec file not found" "$td/err" && ok "default-off: a missing spec keeps exit 2 and its stderr" || bad "default-off: rc=$RC out=$OUT"
rawrun "$gate" "$E_ROOT/no-dod.md"
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "REFUSED" "$td/err" && ok "default-off: a refused spec keeps exit 1 and its stderr" || bad "default-off: rc=$RC out=$OUT"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
