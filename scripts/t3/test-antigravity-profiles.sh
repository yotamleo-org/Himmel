#!/usr/bin/env bash
# scripts/t3/test-antigravity-profiles.sh - fixture suite for antigravity-profiles.sh.
# Hermetic: HOME and T3CODE_HOME live in a mktemp sandbox, the pinned repo is a local git repo, no network.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GEN="$HERE/antigravity-profiles.sh"
REAL_REGISTRY="$HERE/antigravity-profiles.json"
REAL_PLUGIN_PROFILES="$HERE/../lanes/plugin-profiles.json"
T="$(mktemp -d "${TMPDIR:-/tmp}/t3ap.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect_ok()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
expect_fail() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
expect_eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2 want: $3)"; fi; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; } # gnu-ok: BSD fallback on the same line

export HOME="$T/home"
P="$HOME/.claude/plugins"
mkdir -p "$P" "$T/mp/.claude-plugin"
mkskill() { mkdir -p "$1"; printf '# skill\n' > "$1/SKILL.md"; }

mkskill "$T/plug/a/skills/a1"; mkskill "$T/plug/a/skills/a2"
mkskill "$T/plug/b/skills/b1"; mkdir -p "$T/plug/b/.claude-plugin"
printf '{"name":"b","skills":"./skills/"}\n' > "$T/plug/b/.claude-plugin/plugin.json"
mkskill "$T/plug/g/.claude/skills/g1"; mkdir -p "$T/plug/g/.claude-plugin"
printf '{"name":"g","skills":"./.claude/skills/"}\n' > "$T/plug/g/.claude-plugin/plugin.json"
mkskill "$T/plug/c/skills/html"; mkskill "$T/plug/c/skills/design-artifact"; mkskill "$T/plug/c/skills/unlisted"
mkdir -p "$T/plug/c/.claude-plugin"
printf '{"name":"c","skills":["./skills/html","./skills/design-artifact"]}\n' > "$T/plug/c/.claude-plugin/plugin.json"
mkskill "$T/plug/d/higgsfield-generate"; mkskill "$T/plug/d/higgsfield-soul-id"; mkdir -p "$T/plug/d/notaskill"
mkskill "$T/plug/e-root"
mkdir -p "$T/plug/f"
cat > "$T/mp/.claude-plugin/marketplace.json" <<'JSON'
{"name":"mp","plugins":[
 {"name":"d","skills":["./higgsfield-generate","./higgsfield-soul-id"]},
 {"name":"e","skills":["./"]},
 {"name":"f"}
]}
JSON
cat > "$P/known_marketplaces.json" <<JSON
{"mp":{"installLocation":"$T/mp"}}
JSON
write_installed() {
    jq -n --arg r "$T/plug" '{version:2,plugins:(
      [{k:"a",p:"a"},{k:"b",p:"b"},{k:"c",p:"c"},{k:"d",p:"d"},{k:"e",p:"e-root"},{k:"f",p:"f"},{k:"g",p:"g"}]
      | map({key:(.k+"@mp"), value:[{scope:"user",installPath:($r+"/"+.p),version:"1"}]}) | from_entries)}' > "$P/installed_plugins.json"
}
write_installed
cat > "$T/plugin-profiles.json" <<'JSON'
{"profiles":{
 "design":{"enable":["a@mp","b@mp","c@mp","f@mp"]},
 "design-imagegen":{"enable":["d@mp","e@mp","a@mp","g@mp"]},
 "evilp":{"enable":["evil@mp"]}
}}
JSON

git init -q "$T/pinsrc.git" || exit 1
mkskill "$T/pinsrc.git/skills/gemini-frontend-design"
git -C "$T/pinsrc.git" add -A
git -C "$T/pinsrc.git" -c user.name=t -c user.email=t@example.invalid commit -q -m pin || exit 1
PIN="$(git -C "$T/pinsrc.git" rev-parse HEAD)"
REPO="file://$T/pinsrc.git"
write_registry() {
    jq -n --arg repo "$REPO" --arg c "$1" --argjson from "$2" \
      '{profiles:{design:{fromProfiles:$from,pinnedSkills:[{repo:$repo,commit:$c,path:"skills",include:["gemini-frontend-design"],license:"Apache-2.0"}]}}}' > "$T/registry.json"
}
write_registry "$PIN" '["design","design-imagegen"]'

cat > "$T/backstop-ok.sh" <<'STUB'
#!/usr/bin/env bash
for d in "${T3CODE_HOME:?}"/userdata/providers/antigravity/*/; do
  [ -d "$d" ] || continue
  mkdir -p "$d/config"
  f="$d/config/hooks.json"
  [ -f "$f" ] || printf '{}' > "$f"
  jq '. * {"himmel-antigravity-backstop":{}}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/backstop-fail.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/backstop-noop.sh"
chmod +x "$T/backstop-ok.sh" "$T/backstop-fail.sh" "$T/backstop-noop.sh"

export T3_AP_REGISTRY="$T/registry.json"
export T3_AP_PLUGIN_PROFILES="$T/plugin-profiles.json"
export T3_AP_BACKSTOP="$T/backstop-ok.sh"
N=0
fresh() { N=$((N+1)); export T3CODE_HOME="$T/t3-$N" HIMMEL_AGY_SKILL_CACHE="$T/cache-$N"; }
ID_HEX="0a26fb5900d14a0aec6070688e23bf158dc4097e2721393e4d7b746a1b54914e"
home_of() { printf '%s/userdata/providers/antigravity/%s' "$T3CODE_HOME" "$ID_HEX"; }
entry_of() { jq -c --arg p "$2" '[.entries[] | select(.path == $p) | .include_only] | first' "$1"; }

fresh
H="$(home_of)"
out="$(bash "$GEN" --apply --profile design 2>"$T/err1")"; rc=$?
expect_eq "1 apply exits 0" "$rc" 0
expect_ok "1 home exists at sha256(antigravity_design)" test -d "$H"
expect_eq "1 home is mode 700" "$(mode_of "$H")" 700
expect_ok "1 hooks.json has the backstop key" jq -e 'has("himmel-antigravity-backstop")' "$H/config/hooks.json"
expect_ok "1 skills.json is a regular file" test -f "$H/config/skills.json" -a ! -L "$H/config/skills.json"
expect_eq "1 skills.json is mode 600" "$(mode_of "$H/config/skills.json")" 600

S="$H/config/skills.json"
CACHE_DIR="$HIMMEL_AGY_SKILL_CACHE/pinsrc@$PIN"
expect_eq "2 entry count" "$(jq '.entries | length' "$S")" 7
expect_eq "2a default skills dir" "$(entry_of "$S" "$T/plug/a/skills")" '["a1","a2"]'
expect_eq "2b plugin.json dir spec" "$(entry_of "$S" "$T/plug/b/skills")" '["b1"]'
expect_eq "2b plugin.json .claude/skills dir spec" "$(entry_of "$S" "$T/plug/g/.claude/skills")" '["g1"]'
expect_eq "2c plugin.json single-skill list" "$(entry_of "$S" "$T/plug/c/skills")" '["design-artifact","html"]'
expect_eq "2d marketplace root-level single skills in one entry" "$(entry_of "$S" "$T/plug/d")" '["higgsfield-generate","higgsfield-soul-id"]'
expect_eq "2e root SKILL.md: parent dirname, include basename" "$(entry_of "$S" "$T/plug")" '["e-root"]'
expect_eq "2 pinned gemini-frontend-design entry" "$(entry_of "$S" "$CACHE_DIR/skills")" '["gemini-frontend-design"]'
expect_eq "2f plugin without skills contributes nothing" "$(jq -r '[.entries[].path | select(contains("/plug/f"))] | length' "$S")" 0
expect_eq "2 entries sorted by path" "$(jq -c '[.entries[].path]' "$S")" "$(jq -c '[.entries[].path] | sort' "$S")"
expect_eq "2 pinned cache checkout is at the pin" "$(git -C "$CACHE_DIR" rev-parse HEAD)" "$PIN"

AGY_ROOT="$T3CODE_HOME/userdata/providers/antigravity"
fence_hits=0
for p in $(jq -r '.entries[].path' "$S"); do
    rp="$(cd -P "$p" && pwd -P)"
    case "$rp/" in "$AGY_ROOT"/*) fence_hits=$((fence_hits+1)) ;; esac
    case "$p$rp" in */.agents*|*/.gemini*) fence_hits=$((fence_hits+1)) ;; esac
done
expect_eq "3 no entry under providers/antigravity or .agents/.gemini" "$fence_hits" 0

fresh
out="$(bash "$GEN" --dry-run --profile design 2>&1)"; rc=$?
expect_eq "4 dry-run exits 0" "$rc" 0
expect_ok "4 dry-run says would fetch" grep -q "would fetch $REPO@$PIN" <<<"$out"
expect_ok "4 dry-run shows the planned pinned path" grep -q "pinsrc@$PIN/skills" <<<"$out"
expect_ok "4 dry-run names the instance" grep -q 'antigravity_design' <<<"$out"
expect_eq "4 dry-run wrote no T3 tree" "$(test -e "$T3CODE_HOME" && echo yes || echo no)" no
expect_eq "4 dry-run wrote no cache" "$(test -e "$HIMMEL_AGY_SKILL_CACHE" && echo yes || echo no)" no
out2="$(bash "$GEN" --profile design 2>&1)"
expect_eq "4 default mode is dry-run" "$out2" "$out"

fresh
write_registry "0123456789012345678901234567890123456789" '["design"]'
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "5 unfetchable pin exits 2" "$rc" 2
expect_eq "5 no skills.json for an unfetchable pin" "$(test -e "$(home_of)/config/skills.json" && echo yes || echo no)" no
fresh
mkdir -p "$HIMMEL_AGY_SKILL_CACHE"
git clone -q "$T/pinsrc.git" "$HIMMEL_AGY_SKILL_CACHE/pinsrc@0123456789012345678901234567890123456789"
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "5 cache checkout at another commit exits 2" "$rc" 2
expect_eq "5 no skills.json for a mismatched cache" "$(test -e "$(home_of)/config/skills.json" && echo yes || echo no)" no
write_registry "$PIN" '["design","design-imagegen"]'

fresh
cp "$P/installed_plugins.json" "$T/installed.orig"
jq 'del(.plugins["b@mp"])' "$T/installed.orig" > "$P/installed_plugins.json"
out="$(bash "$GEN" --apply --profile design 2>"$T/err6")"; rc=$?
expect_eq "6 missing plugin exits 0" "$rc" 0
expect_ok "6 warns on stderr" grep -q "skip plugin 'b@mp': not installed" "$T/err6"
expect_eq "6 other entries still present" "$(jq '.entries | length' "$(home_of)/config/skills.json")" 6
cp "$T/installed.orig" "$P/installed_plugins.json"

fresh
H="$(home_of)"
mkdir -p "$H/config" "$H/antigravity-acp"
printf '{"keep":"me"}\n' > "$H/antigravity-acp/settings.json"
cp "$H/antigravity-acp/settings.json" "$T/settings.orig"
printf '{"entries":[]}\n' > "$T/elsewhere.json"
ln -s "$T/elsewhere.json" "$H/config/skills.json"
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "7 apply over a symlink exits 0" "$rc" 0
expect_ok "7 symlink replaced by a regular file" test -f "$H/config/skills.json" -a ! -L "$H/config/skills.json"
expect_eq "7 symlink referent untouched" "$(cat "$T/elsewhere.json")" '{"entries":[]}'
expect_ok "7 settings.json byte-identical" cmp -s "$H/antigravity-acp/settings.json" "$T/settings.orig"

fresh
for stub in fail noop; do
    rm -rf "$T3CODE_HOME"
    out="$(env T3_AP_BACKSTOP="$T/backstop-$stub.sh" bash "$GEN" --apply --profile design 2>&1)"; rc=$?
    expect_eq "8 $stub backstop exits 2" "$rc" 2
    expect_eq "8 $stub backstop leaves no skills.json" "$(test -e "$(home_of)/config/skills.json" && echo yes || echo no)" no
done

fresh
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "9 check before apply exits 1" "$rc" 1
expect_eq "9 check wrote nothing" "$(test -e "$T3CODE_HOME" && echo yes || echo no)" no
bash "$GEN" --apply --profile design >/dev/null 2>&1
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "9 check after apply exits 0" "$rc" 0
printf '{"entries":[]}\n' > "$(home_of)/config/skills.json"
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "9 check on a drifted skills.json exits 1" "$rc" 1
bash "$GEN" --apply --profile design >/dev/null 2>&1
rm -f "$(home_of)/config/hooks.json"
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "9 check without hooks.json exits 1" "$rc" 1

fresh
bash "$GEN" --apply --profile design >/dev/null 2>&1
cp "$(home_of)/config/skills.json" "$T/skills.first"
out="$(bash "$GEN" --apply --profile design 2>&1)"; rc=$?
expect_eq "10 second apply exits 0" "$rc" 0
expect_ok "10 second apply prints UNCHANGED" grep -q UNCHANGED <<<"$out"
expect_ok "10 skills.json byte-identical" cmp -s "$(home_of)/config/skills.json" "$T/skills.first"

fresh
mkdir -p "$T3CODE_HOME/userdata/providers/antigravity/x/skills/s1"
printf '# skill\n' > "$T3CODE_HOME/userdata/providers/antigravity/x/skills/s1/SKILL.md"
ln -s "$T3CODE_HOME/userdata/providers/antigravity/x" "$T/plug/evil"
jq --arg p "$T/plug/evil" '.plugins["evil@mp"] = [{scope:"user",installPath:$p,version:"1"}]' "$T/installed.orig" > "$P/installed_plugins.json"
write_registry "$PIN" '["design","evilp"]'
out="$(bash "$GEN" --apply --profile design 2>&1)"; rc=$?
expect_eq "11 symlinked install into providers/antigravity exits 3" "$rc" 3
expect_ok "11 prints REFUSED" grep -q REFUSED <<<"$out"
expect_eq "11 nothing written" "$(test -e "$(home_of)" && echo yes || echo no)" no
out="$(bash "$GEN" --dry-run --profile design 2>&1)"; rc=$?
expect_eq "11 dry-run refuses too" "$rc" 3
cp "$T/installed.orig" "$P/installed_plugins.json"
rm -f "$T/plug/evil"

fresh
write_registry "$PIN" '["design","nope"]'
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "12 unknown fromProfile exits 2" "$rc" 2
expect_eq "12 nothing written" "$(test -e "$T3CODE_HOME" && echo yes || echo no)" no
write_registry "$PIN" '["design","design-imagegen"]'

fresh
bash "$GEN" --bogus >/dev/null 2>&1; rc=$?
expect_eq "13 unknown flag exits 2" "$rc" 2
bash "$GEN" --dry-run --profile nosuch >/dev/null 2>&1; rc=$?
expect_eq "13 unknown --profile exits 2" "$rc" 2
printf '{"profiles":' > "$T/badreg.json"
env T3_AP_REGISTRY="$T/badreg.json" bash "$GEN" --dry-run >/dev/null 2>&1; rc=$?
expect_eq "13 malformed registry exits 2" "$rc" 2
bash "$GEN" --apply --check >/dev/null 2>&1; rc=$?
expect_eq "13 two modes exit 2" "$rc" 2

expect_ok "14 shipped registry is valid" jq -e '.profiles.design.fromProfiles | length > 0' "$REAL_REGISTRY"
for f in $(jq -r '.profiles[].fromProfiles[]' "$REAL_REGISTRY"); do
    # shellcheck disable=SC2016
    expect_ok "14 shipped fromProfile '$f' exists in plugin-profiles.json" jq -e --arg f "$f" '.profiles | has($f)' "$REAL_PLUGIN_PROFILES"
done
expect_eq "14 shipped pin is a full commit sha" "$(jq -r '.profiles.design.pinnedSkills[0].commit | test("^[0-9a-f]{40}$")' "$REAL_REGISTRY")" true

fresh
bash "$GEN" --apply --profile 'des.gn' >/dev/null 2>&1; rc=$?
expect_eq "15 a --profile that only matches as a regex exits 2" "$rc" 2
expect_eq "15 a --profile that only matches as a regex writes nothing" "$(test -e "$T3CODE_HOME" && echo yes || echo no)" no

fresh
bash "$GEN" --apply --profile design >/dev/null 2>&1
printf '{"himmel-antigravity-backstop":null}\n' > "$(home_of)/config/hooks.json"
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "16 a null backstop key is not a ready home" "$rc" 1

fresh
bash "$GEN" --apply --profile design >/dev/null 2>&1
mv "$(home_of)/config" "$T/cfg-moved-$N"
ln -s "$T/cfg-moved-$N" "$(home_of)/config"
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "17 a symlinked config dir is not a ready home" "$rc" 1

fresh
bash "$GEN" --apply --profile design >/dev/null 2>&1
printf 'x\n' >> "$HIMMEL_AGY_SKILL_CACHE/pinsrc@$PIN/skills/gemini-frontend-design/SKILL.md"
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "18 a modified pinned checkout exits 2 on apply" "$rc" 2
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "18 a modified pinned checkout exits 2 on check" "$rc" 2

fresh
bash "$GEN" --apply --profile design >/dev/null 2>&1
printf 'garbage\n' > "$HIMMEL_AGY_SKILL_CACHE/pinsrc@$PIN/.git/index"
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "18 a pinned checkout whose state cannot be read exits 2" "$rc" 2

out="$(bash "$GEN" --list 2>"$T/err-l1")"; rc=$?
expect_eq "L1 --list exits 0" "$rc" 0
expect_eq "L1 --list prints the registry's profile names" "$out" design
expect_eq "L1 --list on the shipped registry prints design" "$(env T3_AP_REGISTRY="$REAL_REGISTRY" bash "$GEN" --list 2>/dev/null)" design
env T3_AP_REGISTRY="$T/badreg.json" bash "$GEN" --list >/dev/null 2>&1; rc=$?
expect_eq "L1 --list on a malformed registry exits 2" "$rc" 2
env T3_AP_REGISTRY="$T/none.json" bash "$GEN" --list >/dev/null 2>&1; rc=$?
expect_eq "L1 --list on a missing registry exits 2" "$rc" 2
printf '{"profiles":{"design":{},"relay":{}}}\n' > "$T/reg-relay.json"
env T3_AP_REGISTRY="$T/reg-relay.json" bash "$GEN" --list >/dev/null 2>&1; rc=$?
expect_eq "L1 --list on a profile named relay exits 2" "$rc" 2
printf '{"profiles":{"design":{},"x_relay":{}}}\n' > "$T/reg-relay2.json"
env T3_AP_REGISTRY="$T/reg-relay2.json" bash "$GEN" --list >/dev/null 2>&1; rc=$?
expect_eq "L1 --list on a profile ending _relay exits 2" "$rc" 2
bash "$GEN" --list --apply >/dev/null 2>&1; rc=$?
expect_eq "L1 --list with another mode exits 2" "$rc" 2

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
