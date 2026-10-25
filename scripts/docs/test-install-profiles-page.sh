#!/usr/bin/env bash
# Suite for docs/setup/profiles/README.md, the Install profiles page.
#
# The page states what each install profile fills in and the commands that
# move between profiles and scopes. Both drift when scripts/himmelctl/bin.js
# moves, so every claim is pinned to the code:
#
#   1. PROFILES — the page's profile headings are exactly the keys of
#                 PROFILE_HELP, which are exactly the keys of PROFILE_PRESETS.
#   2. SEEDS    — each profile's "fills in" bullets carry the values its
#                 PROFILE_PRESETS row seeds (vault, session notes, always-on,
#                 scheduled jobs, Telegram bridge, voice-note model).
#   3. CONTRIBUTE — bin.js offers operator only with --contribute, and the
#                 page's operator section says so.
#   4. COMMANDS — every himmelctl command on the page names a command, a
#                 sub-command and flags that `himmelctl --help` lists.
#   5. CACHE    — the answers file path on the page is cachePath()'s default.
#   6. MOVE     — the "Change install profile" section names the starter to
#                 luna move and no longer says it is "Not yet verified".
#   7. CONTROL  — fixture pages with a missing profile, a wrong seed, an
#                 unseeded scheduled job, an unknown command (indented in
#                 a fence, after a leading flag) and the unverified move text
#                 fail cases 1, 2, 4 and 6, so none passes vacuously.
#
# Usage: bash scripts/docs/test-install-profiles-page.sh [page.md]
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PAGE="${1:-$ROOT/docs/setup/profiles/README.md}"
BIN="$ROOT/scripts/himmelctl/bin.js"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fx=$(mktemp -d -t install-profiles-page.XXXXXX) || { bad "mktemp"; finish; }
trap 'rm -rf "$fx"' EXIT

# PROFILE_PRESETS, PROFILE_HELP and WHISPER_MODEL_FILENAMES as JSON, read from
# the bin.js source (it exports none of them).
if ! node -e '
const src = require("fs").readFileSync(process.argv[1], "utf8");
const out = {};
for (const name of ["PROFILE_PRESETS", "PROFILE_HELP", "WHISPER_MODEL_FILENAMES"]) {
  const m = src.match(new RegExp("^const " + name + " = (\\{[\\s\\S]*?\\n\\});", "m"));
  if (!m) { console.error("no " + name + " in bin.js"); process.exit(1); }
  out[name] = new Function("return " + m[1])();
}
const opts = src.match(/^\s*const profileOpts = devOverlay \? (\[[^\]]*\]) : (\[[^\]]*\]);/m);
if (!opts) { console.error("no profileOpts in bin.js"); process.exit(1); }
out.withContribute = JSON.parse(opts[1].replace(/'\''/g, "\""));
out.without = JSON.parse(opts[2].replace(/'\''/g, "\""));
process.stdout.write(JSON.stringify(out));
' "$BIN" >"$fx/code.json"; then
  bad "read the profile tables from bin.js" "$BIN"
  finish
fi
if ! node "$BIN" --help >"$fx/help.txt" 2>&1; then
  bad "himmelctl --help exits 0"
  finish
fi

# check <case> <page>: prints one problem per line; nothing when the case holds.
check() {
  python3 -I - "$1" "$2" "$fx/code.json" "$fx/help.txt" <<'PY' || echo "could not check $2"
import json, re, sys
case, page, code_path, help_path = sys.argv[1:5]
text = re.sub(r"<!--.*?-->", "", open(page, encoding="utf-8").read(), flags=re.S)
code = json.load(open(code_path, encoding="utf-8"))
helptext = open(help_path, encoding="utf-8").read()
presets, helps = code["PROFILE_PRESETS"], code["PROFILE_HELP"]

def section(body, level, title_re):
    m = re.search(r"^" + "#" * level + r" " + title_re + r".*?\n(.*?)(?=^#{1," + str(level) + r"} |\Z)", body, flags=re.S | re.M)
    return m.group(1) if m else None

profiles_body = section(text, 2, r"The four install profiles")
headings = {}
if profiles_body is not None:
    for m in re.finditer(r"^### [^\n`]*`([^`]+)`[^\n]*\n(.*?)(?=^#{1,3} |\Z)", profiles_body, flags=re.S | re.M):
        headings[m.group(1)] = m.group(2)

if case == "profiles":
    if profiles_body is None:
        print("no 'The four install profiles' section")
    if set(helps) != set(presets):
        print("PROFILE_HELP keys %s differ from PROFILE_PRESETS keys %s" % (sorted(helps), sorted(presets)))
    if set(headings) != set(helps):
        print("page profiles %s differ from PROFILE_HELP keys %s" % (sorted(headings), sorted(helps)))

elif case == "seeds":
    model_key = {v: k for k, v in code["WHISPER_MODEL_FILENAMES"].items()}
    fields = [("Notes vault", "vaultMode"), ("Session notes", "handoverMode"), ("Always-on machine", "alwaysOn"),
              ("Scheduled jobs", "cadenceIds"), ("Telegram bridge", "bridge"), ("Voice-note model", "whisperModel")]
    for name, preset in presets.items():
        body = headings.get(name)
        if body is None:
            print("no section for profile " + name)
            continue
        for label, key in fields:
            line = next((l for l in body.splitlines() if l.startswith("- **" + label + ":**")), None)
            if line is None:
                print("%s: no '%s' bullet" % (name, label))
                continue
            ticks = re.findall(r"`([^`]+)`", line)
            want = preset[key]
            if key == "cadenceIds":
                if not want and "none picked" not in line:
                    print("%s: %s seeds none, the bullet does not say 'none picked'" % (name, label))
                if set(ticks) != set(want):
                    print("%s: %s seeds %s, the bullet says %s" % (name, label, sorted(want), sorted(ticks)))
                continue
            if key == "whisperModel":
                want = model_key.get(want, want)
            if not ticks or ticks[0] != want:
                print("%s: %s seeds %s, the bullet says %s" % (name, label, want, ticks[0] if ticks else "nothing"))

elif case == "contribute":
    only = [p for p in code["withContribute"] if p not in code["without"]]
    if only != ["operator"]:
        print("bin.js offers %s only with --contribute, not operator alone" % only)
    if "--contribute" not in headings.get("operator", ""):
        print("the operator section does not say it needs --contribute")

elif case == "commands":
    cmds = re.findall(r"`(himmelctl [^`]+)`", text)
    for block in re.findall(r"^```[^\n]*\n(.*?)^```", text, flags=re.S | re.M):
        cmds += [l.split(" #")[0].strip() for l in block.splitlines() if l.lstrip().startswith("himmelctl ")]
    if not cmds:
        print("no himmelctl commands on the page")
    listed = set(re.findall(r"^  ([a-z][a-z-]*)\b", helptext.split("\noptions:")[0], flags=re.M))
    flat = " ".join(helptext.split())
    for cmd in cmds:
        words = cmd.split()[1:]
        verb = words[0] if words else ""
        while words and words[0].startswith("--"):
            flag = words.pop(0)
            if not re.search(r"(?<![\w-])" + re.escape(flag) + r"(?![\w-])", flat):
                print("flag not in --help: " + cmd)
            if flag == "--help":
                words = []
        if not words:
            continue
        verb = words[0]
        if verb not in listed:
            print("command not in --help: " + cmd)
            continue
        if len(words) > 1 and re.fullmatch(r"[a-z][a-z-]*", words[1]) and not re.search(r"\b" + re.escape(verb + " " + words[1]) + r"\b", flat):
            print("sub-command not in --help: " + cmd)
        for flag in (w for w in words if w.startswith("--")):
            if not re.search(r"(?<![\w-])" + re.escape(flag) + r"(?![\w-])", flat):
                print("flag not in --help: " + cmd)
PY
}

if [ ! -f "$PAGE" ]; then
  bad "page exists" "$PAGE"
  finish
fi

run_case() { # run_case <case> <label>
  local problems
  problems=$(check "$1" "$PAGE")
  if [ -z "$problems" ]; then ok "$2"; else bad "$2" "$problems"; fi
}

run_case profiles "PROFILES: the page's profiles are PROFILE_HELP's and PROFILE_PRESETS' keys"
run_case seeds "SEEDS: each profile's bullets carry its PROFILE_PRESETS defaults"
run_case contribute "CONTRIBUTE: operator is offered only with --contribute, and the page says so"
run_case commands "COMMANDS: every himmelctl command on the page is in himmelctl --help"

# 5. CACHE
if ! grep -qF "path.join(os.homedir(), '.claude', 'himmel')" "$ROOT/scripts/himmelctl/lib/helpers.js"; then
  bad "CACHE: cacheDir() defaults to ~/.claude/himmel" "scripts/himmelctl/lib/helpers.js"
elif ! grep -qF "path.join(cacheDir(), 'install-profile.json')" "$BIN"; then
  bad "CACHE: cachePath() names install-profile.json" "$BIN"
elif ! grep -qF "\`~/.claude/himmel/install-profile.json\`" "$PAGE"; then
  bad "CACHE: the page names the answers file at cachePath()"
else
  ok "CACHE: the page names the answers file at cachePath()"
fi

# 6. MOVE
move_problems() { # move_problems <page>
  python3 -I -c '
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^### Change install profile\n(.*?)(?=^#{1,3} |\Z)", text, flags=re.S | re.M)
if m is None:
    print("no Change install profile section")
else:
    body = m.group(1)
    if re.search(r"not\s+yet\s+verified", body, flags=re.I):
        print("the Change install profile section still says Not yet verified")
    if "starter" not in body or "luna" not in body:
        print("the Change install profile section does not name the starter to luna move")
    if not re.search(r"test\s+VM", body, flags=re.I):
        print("the Change install profile section does not say the move ran on a test VM")
' "$1" || echo "could not check $1"
}
problems=$(move_problems "$PAGE")
if [ -z "$problems" ]; then ok "MOVE: the Change install profile section states the starter to luna result"; else bad "MOVE: the Change install profile section states the starter to luna result" "$problems"; fi

# 7. CONTROL
# shellcheck disable=SC2016  # the backticks in the python are markdown code spans
if ! { python3 -I -c '
import re, sys
page, out = sys.argv[1], sys.argv[2]
text = open(page, encoding="utf-8").read()
open(out + "/no-custom.md", "w", encoding="utf-8").write(re.sub(r"^### [^\n]*`custom`.*?(?=^#{1,3} )", "", text, count=1, flags=re.S | re.M))
open(out + "/wrong-seed.md", "w", encoding="utf-8").write(re.sub(r"^(- \*\*Notes vault:\*\*[^`\n]*)`existing`", r"\1`none`", text, count=1, flags=re.M))
open(out + "/extra-job.md", "w", encoding="utf-8").write(re.sub(r"^(- \*\*Scheduled jobs:\*\*) none picked", r"\1 `qmd` picked", text, count=1, flags=re.M))
open(out + "/bad-command.md", "w", encoding="utf-8").write(text + "\n```bash\n  himmelctl --contribute profile wipe\n```\n")
open(out + "/unverified-move.md", "w", encoding="utf-8").write(re.sub(r"(^### Change install profile\n)", r"\1\nNot yet verified: a second install over a starter install, switching to luna,\nhas not been run on a test machine yet.\n", text, count=1, flags=re.M))
' "$PAGE" "$fx"; }; then
  bad "CONTROL: write the fixtures" "$fx"
  finish
fi
case "$(check profiles "$fx/no-custom.md")" in *"differ from PROFILE_HELP keys"*) ok "CONTROL: a page missing a profile fails PROFILES" ;; *) bad "CONTROL: a page missing a profile fails PROFILES" ;; esac
case "$(check seeds "$fx/wrong-seed.md")" in *"operator: Notes vault seeds existing, the bullet says none"*) ok "CONTROL: a wrong seed fails SEEDS" ;; *) bad "CONTROL: a wrong seed fails SEEDS" ;; esac
case "$(check seeds "$fx/extra-job.md")" in *"starter: Scheduled jobs seeds [], the bullet says ['qmd']"*) ok "CONTROL: an unseeded scheduled job fails SEEDS" ;; *) bad "CONTROL: an unseeded scheduled job fails SEEDS" ;; esac
case "$(check commands "$fx/bad-command.md")" in *"sub-command not in --help: himmelctl --contribute profile wipe"*) ok "CONTROL: an unknown command fails COMMANDS" ;; *) bad "CONTROL: an unknown command fails COMMANDS" ;; esac
case "$(move_problems "$fx/unverified-move.md")" in *"still says Not yet verified"*) ok "CONTROL: the unverified move text fails MOVE" ;; *) bad "CONTROL: the unverified move text fails MOVE" ;; esac

finish
