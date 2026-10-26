#!/usr/bin/env python3
"""transcribe.py - local faster-whisper transcript of one WAV. stdout = text.

Invoked by ig-media-fetch.py via:
  uv run --python 3.12 --with-requirements requirements-whisper.txt python transcribe.py <wav> [model]

No network at call time beyond the one-time model-weights fetch uv/faster-whisper
performs on first use (cached under the HF cache dir thereafter).

Device: CUDA float16 (large-v3-turbo) when a CUDA device is visible, else CPU int8
(base). When CUDA is usable but the cuBLAS/cuDNN wheels are not in the environment,
the script re-execs itself once under uv with requirements-whisper-cuda.txt added.
On CUDA with no pinned model, turbo detects the language first and Hebrew at
probability >= 0.8 is transcribed by the ivrit-ai fine-tune (HIMMEL_WHISPER_ROUTE=0
turns that off; the CPU path never routes).
HIMMEL_WHISPER_DEVICE (cpu|cuda) and HIMMEL_WHISPER_MODEL override; an explicit
[model] argument wins over both."""
import ctypes
import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULTS = {"cuda": ("float16", "large-v3-turbo"), "cpu": ("int8", "base")}
CUDA_LOCK_MARKER = "HIMMEL_WHISPER_CUDA_LOCK"
HEBREW_MODEL = "ivrit-ai/whisper-large-v3-turbo-ct2"
ROUTE_MIN_PROB = 0.8


def cuda_visible():
    try:
        import ctranslate2
        return ctranslate2.get_cuda_device_count() > 0
    except Exception:
        return False


def select_runtime(model_arg):
    """-> (device, compute_type, model_name)."""
    device = os.environ.get("HIMMEL_WHISPER_DEVICE", "").lower()
    if device not in DEFAULTS:
        device = "cuda" if cuda_visible() else "cpu"
    compute, default_model = DEFAULTS[device]
    model = model_arg or os.environ.get("HIMMEL_WHISPER_MODEL") or default_model
    return device, compute, model


def cuda_libs_present():
    try:
        import nvidia.cublas.lib  # noqa: F401
        import nvidia.cudnn.lib  # noqa: F401
        return True
    except Exception:
        return False


def needs_cuda_lock(device):
    return device == "cuda" and not cuda_libs_present() and not os.environ.get(CUDA_LOCK_MARKER)


def preload_cuda_libs():
    """ctranslate2 dlopens libcublas/libcudnn by soname; the pip wheels keep them off the loader path."""
    import nvidia.cublas.lib
    import nvidia.cudnn.lib
    for pkg in (nvidia.cublas.lib, nvidia.cudnn.lib):
        for lib in sorted(glob.glob(os.path.join(list(pkg.__path__)[0], "lib*.so*"))):
            try:
                ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
            except OSError:
                pass


def reexec_with_cuda_lock():
    uv = shutil.which("uv")
    if uv:
        env = dict(os.environ, **{CUDA_LOCK_MARKER: "1"})
        argv = [uv, "run", "--python", "3.12",
                "--with-requirements", os.path.join(HERE, "requirements-whisper.txt"),
                "--with-requirements", os.path.join(HERE, "requirements-whisper-cuda.txt"),
                "python", os.path.abspath(__file__)] + sys.argv[1:]
        done = subprocess.run(argv, env=env, stdout=subprocess.PIPE)
        if done.returncode == 0:
            sys.stdout.buffer.write(done.stdout)
            sys.exit(0)
        print("transcribe: cuda environment unavailable (uv exited "
              f"{done.returncode}); using cpu", file=sys.stderr)
    os.environ["HIMMEL_WHISPER_DEVICE"] = "cpu"


def route_model(device, language, probability, pinned):
    """GPU only: Hebrew detected with confidence goes to the Hebrew fine-tune, all else to turbo."""
    default = DEFAULTS[device][1]
    if device != "cuda" or pinned or os.environ.get("HIMMEL_WHISPER_ROUTE") == "0":
        return default
    return HEBREW_MODEL if language == "he" and probability >= ROUTE_MIN_PROB else default


def cpu_model_name(model_arg):
    return model_arg or os.environ.get("HIMMEL_WHISPER_MODEL") or DEFAULTS["cpu"][1]


def load_model(device, compute, name, model_arg=None):
    """-> (model, device actually used)."""
    from faster_whisper import WhisperModel
    if device == "cuda":
        try:
            if cuda_libs_present():
                preload_cuda_libs()
            return WhisperModel(name, device="cuda", compute_type=compute), "cuda"
        except Exception as e:
            print(f"transcribe: cuda unusable ({type(e).__name__}: {e}); falling back to cpu",
                  file=sys.stderr)
            compute, name = DEFAULTS["cpu"][0], cpu_model_name(model_arg)
    return WhisperModel(name, device="cpu", compute_type=compute), "cpu"


def run_model(wav, model_arg):
    """-> segments. A CUDA failure at any stage (load, detect, route load, decode) retries on CPU."""
    pinned = bool(model_arg or os.environ.get("HIMMEL_WHISPER_MODEL"))
    device, compute, name = select_runtime(model_arg)
    if needs_cuda_lock(device):
        reexec_with_cuda_lock()  # returns only when the cuda environment is unusable
        device, compute, name = select_runtime(model_arg)
    model, device = load_model(device, compute, name, model_arg)
    if device == "cuda":
        try:
            language = None
            if not pinned:
                from faster_whisper import decode_audio
                language, prob, _ = model.detect_language(decode_audio(wav))
                target = route_model(device, language, prob, pinned)
                if target != name:
                    model = None  # free turbo's VRAM before the Hebrew model loads
                    model = load_model(device, compute, target)[0]
            segments, _info = model.transcribe(wav, language=language)
            return list(segments)
        except Exception as e:
            print(f"transcribe: cuda failed ({type(e).__name__}: {e}); retrying on cpu",
                  file=sys.stderr)
            model = None
            model, _ = load_model("cpu", DEFAULTS["cpu"][0], cpu_model_name(model_arg))
    segments, _info = model.transcribe(wav)
    return list(segments)


def main():
    if len(sys.argv) < 2:
        print("usage: transcribe.py <wav> [model]", file=sys.stderr)
        sys.exit(1)
    segments = run_model(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    text = " ".join(seg.text.strip() for seg in segments).strip()
    sys.stdout.write(text + "\n")
    # Optional side channel: last segment end, seconds.
    meta = os.environ.get("X_TRANSCRIBE_META_FILE")
    if meta and segments:
        with open(meta, "w") as f:
            f.write(str(max(seg.end for seg in segments)))

if __name__ == "__main__":
    main()
