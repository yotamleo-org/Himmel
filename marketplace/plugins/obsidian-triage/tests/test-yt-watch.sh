#!/usr/bin/env bash
# Tests for the on-demand cookieless YouTube watch:
# tools/yt-watch.py - transcript + metadata JSON, and with --visual a yt-dlp
# download at <=720p plus ffmpeg scene frames. Hermetic: NO network; yt-dlp and
# ffmpeg are stubs on a sealed PATH that log their argv. The -vsync rejection
# text in the stub is copied from the real ffmpeg n9.0.2 on the Linux station.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
WATCH="$TOOLS_DIR/yt-watch.py"
VID=Xxuxg8PcBvc

pass=0; fail=0
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  PASS  $desc"; pass=$((pass+1));
  else echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1)); fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/yt-watch.XXXXXX")" || exit 1; [ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$tmp"' EXIT; echo "tmp=$tmp"
HOME="$tmp/home"; mkdir -p "$HOME"; export HOME USERPROFILE="$HOME"
unset GEMINI_API_KEY XAI_API_KEY

jq_py() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# Stubs: yt-dlp writes <id>.mp4 where -o points; ffmpeg rejects -vsync like
# ffmpeg 9 and otherwise writes two frames. Both append their argv to a log.
bin="$tmp/bin"; mkdir -p "$bin"
cat >"$bin/yt-dlp" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/ytdlp.argv"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
out="${out//%(id)s/$STUB_VID}"; [ -n "$out" ] && : >"${out//%(ext)s/mp4}"
exit 0
STUB
cat >"$bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/ffmpeg.argv"
for a in "$@"; do
  if [ "$a" = "-vsync" ]; then
    echo "Unrecognized option 'vsync'." >&2
    echo "Error splitting the argument list: Option not found" >&2
    exit 8
  fi
done
last="${*: -1}"
: >"${last//%04d/0001}"; : >"${last//%04d/0002}"
exit 0
STUB
chmod +x "$bin/yt-dlp" "$bin/ffmpeg"
export STUB_LOG="$tmp" STUB_VID="$VID"
PYBIN="$(command -v python3)"
PATH="$bin:/usr/bin:/bin"

printf '%s' '{"status":"ok","title":"T","channel":"C","duration":"11:45","views":"1","published":"2026-04-14","description":"d","transcript":[{"ts":"0:00","tx":"hello"}],"transcript_source":"yt-dlp","transcript_lang":"en","transcript_error":null}' >"$tmp/meta-ok.json"
watch() { "$PYBIN" "$WATCH" --video-id "$VID" --meta-json "$tmp/meta-ok.json" "$@"; }

echo "Test 1: transcript only, no download, no key"
watch >"$tmp/t1.json"; assert "exit 0" 0 "$?"
assert "status ok" ok "$(jq_py "$tmp/t1.json" 'd["status"]')"
assert "transcript carried" "hello" "$(jq_py "$tmp/t1.json" 'd["transcript"][0]["tx"]')"
assert "no frames" "[]" "$(jq_py "$tmp/t1.json" 'd["frames"]')"
assert "yt-dlp never ran" "no" "$([ -e "$tmp/ytdlp.argv" ] && echo yes || echo no)"
assert "ffmpeg never ran" "no" "$([ -e "$tmp/ffmpeg.argv" ] && echo yes || echo no)"

echo "Test 2: --visual downloads at <=720p and extracts scene frames with -fps_mode vfr"
watch --visual --out-dir "$tmp/out" >"$tmp/t2.json"; assert "exit 0" 0 "$?"
assert "two frames listed" 2 "$(jq_py "$tmp/t2.json" 'len(d["frames"])')"
assert "frame files exist" yes "$([ -f "$tmp/out/frames/frame_0001.jpg" ] && echo yes || echo no)"
assert "ffmpeg argv carries -fps_mode vfr" yes "$(grep -q -- '-fps_mode vfr' "$tmp/ffmpeg.argv" && echo yes || echo no)"
assert "ffmpeg argv never carries -vsync" no "$(grep -q -- '-vsync' "$tmp/ffmpeg.argv" && echo yes || echo no)"
assert "scene filter used" yes "$(grep -q 'gt(scene' "$tmp/ffmpeg.argv" && echo yes || echo no)"
assert "yt-dlp capped at 720p" yes "$(grep -q 'height<=720' "$tmp/ytdlp.argv" && echo yes || echo no)"
assert "yt-dlp is cookieless and config-free" yes "$(grep -q -- '--no-config' "$tmp/ytdlp.argv" && ! grep -q -- 'cookies' "$tmp/ytdlp.argv" && echo yes || echo no)"

echo "Test 3: RED control - the old -vsync argv fails the stub like ffmpeg 9"
ffmpeg -i x -vsync vfr y.jpg 2>"$tmp/vs.err"; assert "old arg list rejected" 8 "$?"
assert "rejection text is ffmpeg's" "Unrecognized option 'vsync'." "$(head -1 "$tmp/vs.err")"

echo "Test 4: ffmpeg failure is reported, not hidden"
cat >"$bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
echo "boom" >&2; exit 1
STUB
watch --visual --out-dir "$tmp/out4" >"$tmp/t4.json"; assert "exit 0 (transcript still returned)" 0 "$?"
assert "frames empty" 0 "$(jq_py "$tmp/t4.json" 'len(d["frames"])')"
assert "frames_error set" yes "$(jq_py "$tmp/t4.json" '"yes" if d["frames_error"] else "no"')"

echo "Test 5: video id is validated"
"$PYBIN" "$WATCH" --video-id 'a b;rm' --meta-json "$tmp/meta-ok.json" >/dev/null 2>&1; assert "bad id rejected" 2 "$?"

echo "Test 6: a YouTube URL resolves to its id"
"$PYBIN" "$WATCH" --url "https://youtu.be/$VID?t=10" --meta-json "$tmp/meta-ok.json" >"$tmp/t6.json"; assert "youtu.be exit 0" 0 "$?"
"$PYBIN" "$WATCH" --url "https://www.youtube.com/watch?v=$VID&feature=x" --meta-json "$tmp/meta-ok.json" >/dev/null; assert "watch?v= exit 0" 0 "$?"
"$PYBIN" "$WATCH" --url "https://example.com/watch?v=$VID" --meta-json "$tmp/meta-ok.json" >/dev/null 2>&1; assert "non-YouTube host rejected" 2 "$?"

echo; echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
