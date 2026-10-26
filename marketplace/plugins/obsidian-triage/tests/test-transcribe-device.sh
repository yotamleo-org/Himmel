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
# A regular nvidia package without cublas/cudnn shadows any installed nvidia wheels.
for d in cuda nocuda broken; do mkdir -p "$tmp/$d/nvidia"; : > "$tmp/$d/nvidia/__init__.py"; done

# Runs a python expression against transcribe.py with a stub ctranslate2.
# py <stubdir> <expr> [ENV=val ...]
py() {
  local stub="$1" expr="$2"; shift 2
  env -u HIMMEL_WHISPER_MODEL -u HIMMEL_WHISPER_DEVICE -u HIMMEL_WHISPER_ROUTE -u HIMMEL_WHISPER_CUDA_LOCK "$@" \
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

echo "== a CUDA failure after the model loads falls back to CPU"
mkdir -p "$tmp/failcuda/nvidia"; : > "$tmp/failcuda/nvidia/__init__.py"
cp "$tmp/cuda/ctranslate2.py" "$tmp/failcuda/ctranslate2.py"
cat > "$tmp/failcuda/faster_whisper.py" <<'STUB'
def decode_audio(p):
    return p
class Seg:
    text = "cpu-ok"; end = 1.0
class WhisperModel:
    def __init__(self, name, device, compute_type):
        self.device = device
    def detect_language(self, audio):
        raise RuntimeError("cudnn failed on first inference")
    def transcribe(self, wav, language=None):
        assert self.device == "cpu", "must have retried on cpu"
        return [Seg()], None
STUB
assert "cuda detect failure retries on cpu" "cpu-ok" "$(py "$tmp/failcuda" 'print(transcribe.run_model("x.wav", None)[0].text)' HIMMEL_WHISPER_CUDA_LOCK=1 | tail -n 1)"

echo "== a failed uv install falls back to CPU; the CPU retry keeps the pinned model"
mkdir -p "$tmp/namecuda/nvidia" "$tmp/bin"; : > "$tmp/namecuda/nvidia/__init__.py"
cp "$tmp/cuda/ctranslate2.py" "$tmp/namecuda/ctranslate2.py"
cat > "$tmp/namecuda/faster_whisper.py" <<'STUB'
def decode_audio(p):
    return p
class Seg:
    def __init__(self, text):
        self.text = text; self.end = 1.0
class WhisperModel:
    def __init__(self, name, device, compute_type):
        self.name = name; self.device = device
    def detect_language(self, audio):
        return "en", 0.99, {}
    def transcribe(self, wav, language=None):
        if self.device == "cuda":
            raise RuntimeError("cuda decode failed")
        return [Seg(self.device + ":" + self.name)], None
STUB
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/uv"; chmod +x "$tmp/bin/uv"
assert "uv failure falls back to cpu base" "cpu:base" "$(py "$tmp/namecuda" 'print(transcribe.run_model("x.wav", None)[0].text)' PATH="$tmp/bin:$PATH" | tail -n 1)"
assert "cpu retry keeps the env model" "cpu:small" "$(py "$tmp/namecuda" 'print(transcribe.run_model("x.wav", None)[0].text)' HIMMEL_WHISPER_CUDA_LOCK=1 HIMMEL_WHISPER_MODEL=small | tail -n 1)"
assert "cpu retry keeps the argv model" "cpu:tiny" "$(py "$tmp/namecuda" 'print(transcribe.run_model("x.wav", "tiny")[0].text)' HIMMEL_WHISPER_CUDA_LOCK=1 | tail -n 1)"

echo "== a healthy uv probe hands the run to uv; a bad wav is never decoded twice"
printf '#!/bin/sh\ncase "$*" in *" -c "*) exit 0 ;; esac\necho exec-ran\n' > "$tmp/bin/uv-ok"
mkdir -p "$tmp/okbin"; cp "$tmp/bin/uv-ok" "$tmp/okbin/uv"; chmod +x "$tmp/okbin/uv"
assert "probe ok: the run is handed to uv" "exec-ran" "$(py "$tmp/namecuda" 'transcribe.run_model("x.wav", None)' PATH="$tmp/okbin:$PATH" | tail -n 1)"

echo "== an end-to-end GPU run routes Hebrew to the ivrit model"
mkdir -p "$tmp/routecuda/nvidia"; : > "$tmp/routecuda/nvidia/__init__.py"
cp "$tmp/cuda/ctranslate2.py" "$tmp/routecuda/ctranslate2.py"
cat > "$tmp/routecuda/faster_whisper.py" <<'STUB'
def decode_audio(p):
    return p
class Seg:
    def __init__(self, text):
        self.text = text; self.end = 1.0
class WhisperModel:
    def __init__(self, name, device, compute_type):
        self.name = name; self.device = device
    def detect_language(self, audio):
        return "he", 0.9, {}
    def transcribe(self, wav, language=None):
        return [Seg(self.device + ":" + self.name + ":" + str(language))], None
STUB
assert "he at 0.9 loads the ivrit model" "cuda:ivrit-ai/whisper-large-v3-turbo-ct2:he" "$(py "$tmp/routecuda" 'print(transcribe.run_model("x.wav", None)[0].text)' HIMMEL_WHISPER_CUDA_LOCK=1 | tail -n 1)"
assert "a pinned model stays unrouted" "cuda:small:None" "$(py "$tmp/routecuda" 'print(transcribe.run_model("x.wav", None)[0].text)' HIMMEL_WHISPER_CUDA_LOCK=1 HIMMEL_WHISPER_MODEL=small | tail -n 1)"

echo "== the media fetchers pass no model unless --whisper-model was given"
caller() {
  python3 -I -c "import sys, importlib.util, subprocess, pathlib
spec = importlib.util.spec_from_file_location('m', sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
seen = []
class P:
    returncode = 0; stdout = 'x'; stderr = ''
subprocess.run = lambda cmd, **kw: (seen.append(cmd), P())[1]
m.shutil.which = lambda n: '/bin/uv'
m.whisper_transcribe(pathlib.Path('/tmp/a.wav'), $2)
print(seen[0][-1])" "$TOOLS_DIR/$1" 2>&1 | tail -n 1
}
assert "ig default passes no model" "/tmp/a.wav" "$(caller ig-media-fetch.py None)"
assert "x default passes no model" "/tmp/a.wav" "$(caller x-media-fetch.py None)"
assert "ig explicit model is passed" "small" "$(caller ig-media-fetch.py "'small'")"
assert "x explicit model is passed" "small" "$(caller x-media-fetch.py "'small'")"
assert "the argparse default is None" "None None" "$(python3 -I -c "import sys, importlib.util
out = []
for f in sys.argv[1:]:
    spec = importlib.util.spec_from_file_location('m', f); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    out.append(str(m.DEFAULT_WHISPER_MODEL))
print(*out)" "$TOOLS_DIR/ig-media-fetch.py" "$TOOLS_DIR/x-media-fetch.py" 2>&1 | tail -n 1)"

echo; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
