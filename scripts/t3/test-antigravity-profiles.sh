#!/usr/bin/env bash
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
bash "$GEN" --apply --profile design >/dev/null 2>&1; expect_eq "16 the setup apply exits 0" "$?" 0
printf '{"himmel-antigravity-backstop":null}\n' > "$(home_of)/config/hooks.json"
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "16 a null backstop key is not a ready home" "$rc" 1

fresh
bash "$GEN" --apply --profile design >/dev/null 2>&1; expect_eq "17 the setup apply exits 0" "$?" 0
mv "$(home_of)/config" "$T/cfg-moved-$N"
ln -s "$T/cfg-moved-$N" "$(home_of)/config"
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "17 a symlinked config dir is not a ready home" "$rc" 1

fresh
bash "$GEN" --apply --profile design >/dev/null 2>&1; expect_eq "18 the first setup apply exits 0" "$?" 0
printf 'x\n' >> "$HIMMEL_AGY_SKILL_CACHE/pinsrc@$PIN/skills/gemini-frontend-design/SKILL.md"
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "18 a modified pinned checkout exits 2 on apply" "$rc" 2
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "18 a modified pinned checkout exits 2 on check" "$rc" 2

fresh
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "18 the setup apply exits 0" "$rc" 0
printf 'garbage\n' > "$HIMMEL_AGY_SKILL_CACHE/pinsrc@$PIN/.git/index"
out="$(bash "$GEN" --apply --profile design 2>&1)"; rc=$?
expect_eq "18 a pinned checkout whose state cannot be read exits 2" "$rc" 2
expect_ok "18 the refusal says the state cannot be read" grep -q 'cannot read the state of pinned checkout' <<<"$out"

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

BARE_HEX="ac0a3dfd6dddb20962cecff6ee5fe65e19d3923be20e52c5ab52ff877f7e4c32"
TOK_REL="antigravity-acp/antigravity-oauth-token"
bare_tok() { printf '%s/userdata/providers/antigravity/%s/%s' "$T3CODE_HOME" "$BARE_HEX" "$TOK_REL"; }
mk_bare_tok() { mkdir -p "$(dirname "$(bare_tok)")"; printf 'stub-not-a-credential\n' > "$(bare_tok)"; chmod 600 "$(bare_tok)"; }

fresh
mk_bare_tok
chmod 000 "$(bare_tok)"
H="$(home_of)"
out="$(bash "$GEN" --apply --profile design 2>&1)"; rc=$?
expect_eq "19 apply with a bare login exits 0 (the unreadable stub proves no read)" "$rc" 0
expect_ok "19 the profile token is a symlink" test -L "$H/$TOK_REL"
expect_eq "19 the symlink points at the bare token" "$(readlink "$H/$TOK_REL")" "$(bare_tok)"
expect_ok "19 apply says the login is linked" grep -q "^LOGIN-LINKED " <<<"$out"
expect_eq "19 the profile antigravity-acp dir is mode 700" "$(mode_of "$H/antigravity-acp")" 700
expect_eq "19 no credential copy: the only profile entry under antigravity-acp is the link" "$(ls -A "$H/antigravity-acp")" antigravity-oauth-token
out="$(bash "$GEN" --apply --profile design 2>&1)"; rc=$?
expect_eq "19 a second apply exits 0" "$rc" 0
expect_ok "19 a second apply says LOGIN-OK" grep -q "^LOGIN-OK " <<<"$out"
chmod 600 "$(bare_tok)"
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "19 check passes with the linked login" "$rc" 0

fresh
mk_bare_tok
H="$(home_of)"
mkdir -p "$H/antigravity-acp"
printf 'own-stub\n' > "$H/$TOK_REL"
out="$(bash "$GEN" --apply --profile design 2>&1)"; rc=$?
expect_eq "20 apply over an own login exits 0" "$rc" 0
expect_ok "20 the own token stays a regular file" test -f "$H/$TOK_REL" -a ! -L "$H/$TOK_REL"
expect_eq "20 the own token content is untouched" "$(cat "$H/$TOK_REL")" own-stub
expect_ok "20 apply says LOGIN-KEPT" grep -q "^LOGIN-KEPT " <<<"$out"

fresh
H="$(home_of)"
out="$(bash "$GEN" --apply --profile design 2>&1)"; rc=$?
expect_eq "21 apply with no bare login exits 0" "$rc" 0
expect_ok "21 apply says NOLOGIN" grep -q "^NOLOGIN antigravity_design" <<<"$out"
expect_eq "21 no profile token is made" "$(test -e "$H/$TOK_REL" -o -L "$H/$TOK_REL" && echo yes || echo no)" no
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "21 check passes with no bare login to share" "$rc" 0
mk_bare_tok
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "21 check fails once a bare login exists and the profile has none" "$rc" 1
out="$(bash "$GEN" --check --profile design 2>&1)"
expect_ok "21 check says why" grep -q "login not shared" <<<"$out"
bash "$GEN" --apply --profile design >/dev/null 2>&1
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "21 check passes after apply links the login" "$rc" 0

fresh
mk_bare_tok
out="$(bash "$GEN" --dry-run --profile design 2>&1)"; rc=$?
expect_eq "22 dry-run exits 0" "$rc" 0
expect_ok "22 dry-run plans the login link" grep -q "^login: would link" <<<"$out"
expect_eq "22 dry-run made no profile home" "$(test -e "$(home_of)" && echo yes || echo no)" no

fresh
mk_bare_tok
H="$(home_of)"
mkdir -p "$H/antigravity-acp"
ln -s "$T/no-such-token" "$H/$TOK_REL"
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "23 a dangling profile link is repaired, rc 0" "$rc" 0
expect_eq "23 the repaired link points at the bare token" "$(readlink "$H/$TOK_REL")" "$(bare_tok)"

fresh
mk_bare_tok
H="$(home_of)"
mkdir -p "$H" "$T/acp-moved-$N"
ln -s "$T/acp-moved-$N" "$H/antigravity-acp"
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "24 a symlinked antigravity-acp dir is refused, rc 2" "$rc" 2
expect_eq "24 nothing is written through the symlinked dir" "$(find "$T/acp-moved-$N" -mindepth 1 | wc -l | tr -d ' ')" 0

fresh
mk_bare_tok
bash "$GEN" --apply --profile design >/dev/null 2>&1
H="$(home_of)"
printf 'other\n' > "$T/other-token"
ln -sfn "$T/other-token" "$H/$TOK_REL"
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "33 a login link to some other file fails check" "$rc" 1

fresh
mk_bare_tok
H="$(home_of)"
mkdir -p "$H/$TOK_REL"
bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
expect_eq "34 a token path that is a directory is refused, rc 2" "$rc" 2

fresh
mk_bare_tok
mv "$(bare_tok)" "$T/real-bare-token-$N"
ln -s "$T/real-bare-token-$N" "$(bare_tok)"
H="$(home_of)"
out="$(bash "$GEN" --apply --profile design 2>&1)"; rc=$?
expect_eq "35 a bare token that is a symlink exits 0" "$rc" 0
expect_ok "35 it is not shared: NOLOGIN" grep -q "^NOLOGIN antigravity_design" <<<"$out"
expect_eq "35 no profile link is made" "$(test -e "$H/$TOK_REL" -o -L "$H/$TOK_REL" && echo yes || echo no)" no

mkdir -p "$T/adp-deny" "$T/adp-allow" "$T/adp-rc1"
cat > "$T/adp-deny/antigravity-hook-adapter.sh" <<'STUB'
#!/usr/bin/env bash
in="$(cat)"
case "$in" in *antigravity-oauth-token*) printf '{"decision":"deny","reason":"stub self-protect"}\n' ;; esac
exit 0
STUB
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$T/adp-allow/antigravity-hook-adapter.sh"
chmod +x "$T/adp-deny/antigravity-hook-adapter.sh" "$T/adp-allow/antigravity-hook-adapter.sh"
smoke_hooks() { SMOKE_ADAPTER="$1"; jq -n --arg c "exec bash '$1' --event PreToolUse" '{"himmel-antigravity-backstop":{PreToolUse:[{matcher:"*",hooks:[{type:"command",command:$c}]}]}}' > "$(home_of)/config/hooks.json"; }
smoke_ready() {
    fresh
    mk_bare_tok
    bash "$GEN" --apply --profile design >/dev/null 2>&1
    smoke_hooks "$T/adp-deny/antigravity-hook-adapter.sh"
    jq -n '{providerInstances:{antigravity_design:{driver:"antigravity",enabled:true}}}' > "$T3CODE_HOME/userdata/settings.json"
    mkdir -p "$HOME/.himmel"
    jq -n '{t3:{instance_allowlist:["antigravity_design"]}}' > "$HOME/.himmel/config.json"
}
smoke() { SOUT="$(env T3_AP_ADAPTER="${SMOKE_ADAPTER:-}" bash "$GEN" --smoke --profile design 2>&1)"; SRC=$?; }

smoke_ready
smoke
expect_eq "25 smoke on a ready profile exits 0" "$SRC" 0
expect_eq "25 smoke prints six PASS lines" "$(grep -c '^PASS ' <<<"$SOUT")" 6
expect_eq "25 smoke prints no FAIL line" "$(grep -c '^FAIL ' <<<"$SOUT")" 0
expect_eq "25 smoke prints four INFO cli lines, never FAIL" "$(grep -c '^INFO cli ' <<<"$SOUT")" 4
expect_eq "25 check still passes after smoke" "$(bash "$GEN" --check --profile design >/dev/null 2>&1; echo $?)" 0

smoke_ready
rm -f "$HOME/.himmel/config.json"
smoke
expect_eq "26 smoke without an allowlist exits 1" "$SRC" 1
expect_ok "26 the FAIL names the allowlist" grep -q '^FAIL allowlist: antigravity_design is not in .t3.instance_allowlist' <<<"$SOUT"
expect_eq "26 the other five links still PASS" "$(grep -c '^PASS ' <<<"$SOUT")" 5

smoke_ready
jq -n '{t3:{instance_allowlist:"antigravity_design"}}' > "$HOME/.himmel/config.json"
smoke
expect_ok "27 an allowlist that is a string, not an array, FAILs allowlist" grep -q '^FAIL allowlist: ' <<<"$SOUT"

smoke_ready
rm -f "$T3CODE_HOME/userdata/settings.json"
smoke
expect_ok "27 a missing T3 instance FAILs by name" grep -q '^FAIL instance: ' <<<"$SOUT"

smoke_ready
smoke_hooks "$T/adp-allow/antigravity-hook-adapter.sh"
smoke
expect_eq "28 a hook that does not deny exits 1" "$SRC" 1
expect_ok "28 the FAIL says the control deny did not fire" grep -q '^FAIL hooks: .*not denied' <<<"$SOUT"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf %%s "{\\"decision\\":\\"deny\\"}"\nexit 1\n' > "$T/adp-rc1/antigravity-hook-adapter.sh"
smoke_ready
smoke_hooks "$T/adp-rc1/antigravity-hook-adapter.sh"
smoke
expect_ok "28 a hook that denies but exits non-zero FAILs hooks" grep -q '^FAIL hooks: .*rc 1' <<<"$SOUT"
smoke_ready
jq -n '{"himmel-antigravity-backstop":{PreToolUse:[{matcher:"*",hooks:[{type:"command",command:"exec bash /bin/true --event PreToolUse"}]}]}}' > "$(home_of)/config/hooks.json"
smoke
expect_ok "28 a command that is not the backstop is not run and FAILs hooks" grep -q '^FAIL hooks: the PreToolUse command is not the himmel backstop' <<<"$SOUT"
smoke_ready
jq -n --arg c "exec bash '$T/adp-allow/antigravity-hook-adapter.sh'; touch $T/injected; echo '/x/antigravity-hook-adapter.sh' --event PreToolUse" '{"himmel-antigravity-backstop":{PreToolUse:[{matcher:"*",hooks:[{type:"command",command:$c}]}]}}' > "$(home_of)/config/hooks.json"
smoke
expect_eq "28 a command with an injected tail is never executed" "$(test -e "$T/injected" && echo yes || echo no)" no
expect_eq "28 a command with an injected tail exits 1" "$SRC" 1
expect_ok "28 a command with an injected tail FAILs hooks as not the backstop" grep -q '^FAIL hooks: the PreToolUse command is not the himmel backstop' <<<"$SOUT"
smoke_ready
jq -n --arg c "exec bash '$T/adp-deny/antigravity-hook-adapter.sh" '{"himmel-antigravity-backstop":{PreToolUse:[{matcher:"*",hooks:[{type:"command",command:$c}]}]}}' > "$(home_of)/config/hooks.json"
smoke
expect_ok "28 a command with no closing quote and no event suffix FAILs hooks" grep -q '^FAIL hooks: the PreToolUse command is not the himmel backstop' <<<"$SOUT"
smoke_ready
SOUT="$(env T3_AP_ADAPTER="$T/adp-allow/antigravity-hook-adapter.sh" bash "$GEN" --smoke --profile design 2>&1)"; SRC=$?
expect_ok "28 an adapter that is not this checkout's is not run" grep -q "^FAIL hooks: .*not this checkout's" <<<"$SOUT"
smoke_ready
printf '{}' > "$(home_of)/config/hooks.json"
smoke
expect_ok "28 a home without the backstop key FAILs hooks" grep -q '^FAIL hooks: .*lacks the himmel-antigravity-backstop' <<<"$SOUT"

smoke_ready
rm -f "$(home_of)/antigravity-acp/antigravity-oauth-token"
smoke
expect_ok "29 a profile without a login link FAILs login" grep -q '^FAIL login: ' <<<"$SOUT"

smoke_ready
jq '.entries += [{path:"/nonexistent-smoke-dir",include_only:["ghost"]}]' "$(home_of)/config/skills.json" > "$T/skills.smoke"
cp "$T/skills.smoke" "$(home_of)/config/skills.json"
smoke
expect_ok "30 a skill with no SKILL.md FAILs skills and names it" grep -q '^FAIL skills: .*/nonexistent-smoke-dir/ghost' <<<"$SOUT"

smoke_ready
printf '{"mcpServers":{"nope":{"command":"no-such-mcp-cmd-xyz"}}}\n' > "$(home_of)/config/mcp_config.json"
smoke
expect_ok "31 an MCP server whose command is absent FAILs mcp" grep -q '^FAIL mcp: .*no-such-mcp-cmd-xyz' <<<"$SOUT"
printf '{"mcpServers":{"ok":{"command":"sh"}}}\n' > "$(home_of)/config/mcp_config.json"
smoke
expect_ok "31 an MCP server whose command exists PASSes mcp" grep -q '^PASS mcp: 1 MCP servers reachable' <<<"$SOUT"

fresh
smoke
expect_eq "32 smoke on a profile with no home exits 1" "$SRC" 1
expect_ok "32 the FAIL names the missing home" grep -q '^FAIL home: ' <<<"$SOUT"

REG_ORIG="$T/registry.json"
jq '.profiles.design.excludePlugins = ["b@mp"]' "$REG_ORIG" > "$T/registry-ex.json"
fresh
env T3_AP_REGISTRY="$T/registry-ex.json" bash "$GEN" --apply --profile design >/dev/null 2>&1; rc=$?
S="$(home_of)/config/skills.json"
expect_eq "36 apply with excludePlugins exits 0" "$rc" 0
expect_eq "36 the excluded plugin's skills are gone" "$(entry_of "$S" "$T/plug/b/skills")" null
expect_eq "36 the other plugins stay (entry count 6)" "$(jq '.entries | length' "$S")" 6
jq '.profiles.design.excludePlugins = "b@mp"' "$REG_ORIG" > "$T/registry-exbad.json"
env T3_AP_REGISTRY="$T/registry-exbad.json" bash "$GEN" --dry-run --profile design >/dev/null 2>&1; rc=$?
expect_eq "36 a non-list excludePlugins exits 2" "$rc" 2

jq '.mcpCatalog = {playwright:{command:"sh",args:["-c","true"]},needsrepo:{command:"npm",args:["--prefix","${HIMMEL_REPO}/x"]}}' "$T/plugin-profiles.json" > "$T/plugin-profiles-mcp.json"
jq '.profiles.design.mcpServers = {ctx:{command:"sh",args:["-c","true"]}} | .profiles.design.optionalMcpServers = ["playwright","ghost","needsrepo"]' "$REG_ORIG" > "$T/registry-mcp.json"
mcp_env() { env T3_AP_REGISTRY="$T/registry-mcp.json" T3_AP_PLUGIN_PROFILES="$T/plugin-profiles-mcp.json" "$@"; }
fresh
out="$(mcp_env bash "$GEN" --apply --profile design 2>&1)"; rc=$?
M="$(home_of)/config/mcp_config.json"
expect_eq "37 apply with MCP servers exits 0" "$rc" 0
expect_eq "37 mcp_config.json holds the own and the catalog server" "$(jq -c '.mcpServers | keys' "$M")" '["ctx","playwright"]'
expect_ok "37 an optional server missing from the catalog is skipped with a note" grep -q "skip optional MCP server 'ghost'" <<<"$out"
expect_ok "37 an optional server that needs a checkout path is skipped with a note" grep -q "skip optional MCP server 'needsrepo'" <<<"$out"
expect_eq "37 mcp_config.json is mode 600" "$(mode_of "$M")" 600
mcp_env bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "37 check passes after apply" "$rc" 0
out="$(mcp_env bash "$GEN" --apply --profile design 2>&1)"
expect_ok "37 a second apply leaves mcp_config.json UNCHANGED" grep -q "^UNCHANGED .*mcp_config.json" <<<"$out"
printf '{"mcpServers":{}}\n' > "$M"
mcp_env bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "37 check fails on a drifted mcp_config.json" "$rc" 1
fresh
bash "$GEN" --apply --profile design >/dev/null 2>&1
expect_eq "37 a registry with no MCP data writes no mcp_config.json" "$(test -e "$(home_of)/config/mcp_config.json" && echo yes || echo no)" no
fresh
mk_bare_tok
mcp_env bash "$GEN" --apply --profile design >/dev/null 2>&1
smoke_hooks "$T/adp-deny/antigravity-hook-adapter.sh"
jq -n '{providerInstances:{antigravity_design:{driver:"antigravity",enabled:true}}}' > "$T3CODE_HOME/userdata/settings.json"
mkdir -p "$HOME/.himmel"
jq -n '{t3:{instance_allowlist:["antigravity_design"]}}' > "$HOME/.himmel/config.json"
SOUT="$(mcp_env T3_AP_ADAPTER="$T/adp-deny/antigravity-hook-adapter.sh" bash "$GEN" --smoke --profile design 2>&1)"; SRC=$?
expect_eq "38 smoke with registry MCP servers exits 0" "$SRC" 0
expect_ok "38 smoke counts the two MCP servers" grep -q '^PASS mcp: 2 MCP servers reachable' <<<"$SOUT"
cp "$(home_of)/config/mcp_config.json" "$T/mcp-copy.json"
rm -f "$(home_of)/config/mcp_config.json"
SOUT="$(mcp_env T3_AP_ADAPTER="$T/adp-deny/antigravity-hook-adapter.sh" bash "$GEN" --smoke --profile design 2>&1)"; SRC=$?
expect_eq "38 smoke with the MCP config missing exits 1" "$SRC" 1
expect_ok "38 the FAIL says the MCP config differs from the registry" grep -q '^FAIL mcp: .*differs from the registry' <<<"$SOUT"
ln -s "$T/mcp-copy.json" "$(home_of)/config/mcp_config.json"
SOUT="$(mcp_env T3_AP_ADAPTER="$T/adp-deny/antigravity-hook-adapter.sh" bash "$GEN" --smoke --profile design 2>&1)"; SRC=$?
expect_ok "38 a symlinked mcp_config.json FAILs mcp" grep -q '^FAIL mcp: config/mcp_config.json is a symlink' <<<"$SOUT"

fresh
mcp_env bash "$GEN" --apply --profile design >/dev/null 2>&1
M="$(home_of)/config/mcp_config.json"
chmod 644 "$M"
mcp_env bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "39 check fails on a byte-identical mcp_config.json with mode 644" "$rc" 1
out="$(mcp_env bash "$GEN" --apply --profile design 2>&1)"
expect_eq "39 apply sets mode 600 on an identical file" "$(mode_of "$M")" 600
expect_ok "39 a mode repair prints WROTE, not UNCHANGED" grep -q "^WROTE .*mcp_config.json" <<<"$out"
chmod 644 "$M"
mcp_env T3_AP_ADAPTER="$T/adp-deny/antigravity-hook-adapter.sh" bash "$GEN" --smoke --profile design 2>&1 | grep -q '^FAIL mcp: .*mode 644'
expect_eq "39 smoke FAILs a byte-identical mcp_config.json with mode 644" "$?" 0

fresh
bash "$GEN" --apply --profile design >/dev/null 2>&1
chmod 644 "$(home_of)/config/skills.json"
bash "$GEN" --check --profile design >/dev/null 2>&1; rc=$?
expect_eq "39 check fails on a byte-identical skills.json with mode 644" "$rc" 1
bash "$GEN" --apply --profile design >/dev/null 2>&1
expect_eq "39 apply sets mode 600 on an identical skills.json" "$(mode_of "$(home_of)/config/skills.json")" 600

jq '.profiles.design.mcpServers = {}' "$REG_ORIG" > "$T/registry-mcp-empty.json"
fresh
mkdir -p "$(home_of)/config"
printf '{"mcpServers":{"stale":{"command":"sh"}}}\n' > "$(home_of)/config/mcp_config.json"
env T3_AP_REGISTRY="$T/registry-mcp-empty.json" bash "$GEN" --apply --profile design >/dev/null 2>&1
expect_eq "39 an explicit empty mcpServers removes a stale server" "$(jq -c '.mcpServers' "$(home_of)/config/mcp_config.json")" '{}'

jq '.profiles.design.excludePlugins = false' "$REG_ORIG" > "$T/registry-bad1.json"
jq '.profiles.design.mcpServers = false' "$REG_ORIG" > "$T/registry-bad2.json"
jq '.profiles.design.optionalMcpServers = false' "$REG_ORIG" > "$T/registry-bad3.json"
jq '.profiles.design.mcpServers = {x:"notanobject"}' "$REG_ORIG" > "$T/registry-bad4.json"
for b in 1 2 3 4; do
    env T3_AP_REGISTRY="$T/registry-bad$b.json" bash "$GEN" --dry-run --profile design >/dev/null 2>&1; rc=$?
    expect_eq "39 a malformed profile field (case $b) exits 2" "$rc" 2
done

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
