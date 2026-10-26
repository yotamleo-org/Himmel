#!/usr/bin/env bash
# Tests for transcribe.py device/model selection. Hermetic: a stub
# ctranslate2 on PYTHONPATH reports a CUDA device count; no model, no GPU, no network.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"

pass=0; fail=0
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  PASS  $desc"; pass=$((pass+1));
  else echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1)); fi
}

tmp="$(mktemp -d -t transcribe-device.XXXXXX)" || exit 1; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cuda" "$tmp/nocuda" "$tmp/broken"
printf 'def get_cuda_device_count():\n    return 1\n' > "$tmp/cuda/ctranslate2.py"
printf 'def get_cuda_device_count():\n    return 0\n' > "$tmp/nocuda/ctranslate2.py"
printf 'raise ImportError("no ctranslate2")\n' > "$tmp/broken/ctranslate2.py"

# Runs a python expression against transcribe.py with a stub ctranslate2.
# py <stubdir> <expr> [ENV=val ...]
py() {
  local stub="$1" expr="$2"; shift 2
  env -u HIMMEL_WHISPER_MODEL -u HIMMEL_WHISPER_DEVICE -u HIMMEL_WHISPER_CUDA_LOCK "$@" \
    python3 -I -c "import sys; sys.path[:0]=[sys.argv[1], sys.argv[2]]
import transcribe
$expr" "$stub" "$TOOLS_DIR" 2>&1
}
sel() { py "$1" 'print(*transcribe.select_runtime(None))' "${@:2}"; }

echo "== no CUDA -> CPU int8, base"
assert "no cuda picks cpu int8 base" "cpu int8 base" "$(sel "$tmp/nocuda")"
assert "ctranslate2 import failure falls to cpu" "cpu int8 base" "$(sel "$tmp/broken")"

echo "== CUDA present -> cuda float16, large-v3-turbo"
assert "cuda picks float16 turbo" "cuda float16 large-v3-turbo" "$(sel "$tmp/cuda")"

echo "== overrides win"
assert "env device cpu beats cuda" "cpu int8 base" "$(sel "$tmp/cuda" HIMMEL_WHISPER_DEVICE=cpu)"
assert "env model beats default" "cuda float16 small" "$(sel "$tmp/cuda" HIMMEL_WHISPER_MODEL=small)"
assert "argv model beats env model" "cpu int8 tiny" "$(py "$tmp/nocuda" 'print(*transcribe.select_runtime("tiny"))' HIMMEL_WHISPER_MODEL=small)"
assert "env device cuda forced" "cuda float16 large-v3-turbo" "$(sel "$tmp/nocuda" HIMMEL_WHISPER_DEVICE=cuda)"

echo "== the CUDA lock is requested only when CUDA is usable and its libs are absent"
assert "no cuda: cuda lock not requested" "False" "$(py "$tmp/nocuda" 'print(transcribe.needs_cuda_lock(transcribe.select_runtime(None)[0]))')"
assert "cpu forced: cuda lock not requested" "False" "$(py "$tmp/cuda" 'print(transcribe.needs_cuda_lock(transcribe.select_runtime(None)[0]))' HIMMEL_WHISPER_DEVICE=cpu)"
assert "cuda, libs absent: cuda lock requested" "True" "$(py "$tmp/cuda" 'print(transcribe.needs_cuda_lock(transcribe.select_runtime(None)[0]))')"
assert "re-exec marker stops a second request" "False" "$(py "$tmp/cuda" 'print(transcribe.needs_cuda_lock("cuda"))' HIMMEL_WHISPER_CUDA_LOCK=1)"

echo "== Hebrew/English routing on the GPU path"
route() { py "$tmp/cuda" "print(transcribe.route_model($1))" "${@:2}"; }
assert "hebrew at 0.80 picks ivrit" "ivrit-ai/whisper-large-v3-turbo-ct2" "$(route '"cuda", "he", 0.80, False')"
assert "hebrew at 0.99 picks ivrit" "ivrit-ai/whisper-large-v3-turbo-ct2" "$(route '"cuda", "he", 0.99, False')"
assert "hebrew at 0.79 picks turbo" "large-v3-turbo" "$(route '"cuda", "he", 0.79, False')"
assert "english picks turbo" "large-v3-turbo" "$(route '"cuda", "en", 0.99, False')"
assert "another language picks turbo" "large-v3-turbo" "$(route '"cuda", "ar", 0.95, False')"
assert "cpu never routes" "base" "$(route '"cpu", "he", 0.99, False')"
assert "a pinned model never routes" "large-v3-turbo" "$(route '"cuda", "he", 0.99, True')"
assert "HIMMEL_WHISPER_ROUTE=0 turns routing off" "large-v3-turbo" "$(route '"cuda", "he", 0.99, False' HIMMEL_WHISPER_ROUTE=0)"

echo; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
