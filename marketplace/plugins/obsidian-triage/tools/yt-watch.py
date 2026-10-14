#!/usr/bin/env python3
"""yt-watch.py - on-demand, cookieless "watch this YouTube video".

The ad-hoc sibling of the harvest path: yt-scrapling-meta.py supplies metadata
and the yt-dlp transcript, and with --visual this adds a yt-dlp download at 720p
or lower plus ffmpeg scene-change frames. No cookie and no Gemini/Grok/XAI key:
the caller (Claude) reads the transcript and the frames itself.

Prints one JSON object: the yt-scrapling-meta.py result plus
  "frames": [absolute jpg path, ...], "frames_error": null | str
(or the helper's {"status": "login_wall"|"removed"|"skipped"|"error", ...}
untouched). Exit 0 when the helper's status is ok, else the helper's exit code;
2 for a bad id or URL.

Frames use `-fps_mode vfr`: ffmpeg 9 rejects the old `-vsync` outright.

`--meta-json FILE` stands in for the helper (tests).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import parse_qs, urlparse

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,20}$")
YT_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"}
HELPER = Path(__file__).with_name("yt-scrapling-meta.py")
HELPER_TIMEOUT = 300
DOWNLOAD_TIMEOUT = int(os.environ.get("YT_WATCH_DOWNLOAD_TIMEOUT", "900"))
FFMPEG_TIMEOUT = int(os.environ.get("YT_WATCH_FFMPEG_TIMEOUT", "600"))
SCENE_THRESHOLD = "0.35"
MAX_FRAMES = 40


def video_id_of(url):
    """The video id of a youtube.com/watch or youtu.be URL, else None."""
    p = urlparse(url)
    host = (p.hostname or "").lower()
    if host == "youtu.be":
        vid = p.path.lstrip("/").split("/")[0]
    elif host in YT_HOSTS:
        vid = (parse_qs(p.query).get("v") or [""])[0]
        if not vid and p.path.startswith(("/shorts/", "/live/", "/embed/")):
            vid = p.path.split("/")[2] if p.path.count("/") >= 2 else ""
    else:
        return None
    return vid if VIDEO_ID_RE.match(vid) else None


def scrapling_python():
    override = os.environ.get("YT_SCRAPLING_PYTHON", "").strip()
    if override:
        return override
    py = Path(os.environ.get("HOME") or Path.home()) / ".himmel" / "scrapling-venv" / "bin" / "python"
    return str(py) if py.exists() else None


def helper_result(video_id, vault):
    """(result dict, exit code) from yt-scrapling-meta.py."""
    py = scrapling_python()
    if py is None:
        return {"status": "error", "detail": "scrapling venv missing"}, 3
    cmd = [py, str(HELPER), "--video-id", video_id]
    if vault:
        cmd += ["--vault", vault]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=HELPER_TIMEOUT)
    except (subprocess.TimeoutExpired, OSError) as e:
        return {"status": "error", "detail": f"helper: {type(e).__name__}"}, 6
    try:
        return json.loads(proc.stdout), proc.returncode
    except ValueError:
        return {"status": "error", "detail": f"helper unparseable output (rc={proc.returncode})"}, 6


def download_argv(ytdlp, video_id, out_template):
    return [ytdlp, "--no-config", "--no-playlist",
            "-f", "bv*[height<=720]+ba/b[height<=720]",
            "--merge-output-format", "mp4",
            "-o", out_template, "--", f"https://www.youtube.com/watch?v={video_id}"]


def ffmpeg_argv(ffmpeg, video, frames_dir):
    return [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(video),
            "-vf", f"select='gt(scene,{SCENE_THRESHOLD})'",
            "-fps_mode", "vfr", "-frames:v", str(MAX_FRAMES), "-q:v", "3",
            str(frames_dir / "frame_%04d.jpg")]


def extract_frames(video_id, out_dir):
    """([frame paths], None) or ([], error)."""
    ytdlp, ffmpeg = shutil.which("yt-dlp"), shutil.which("ffmpeg")
    if not ytdlp:
        return [], "yt_dlp_missing"
    if not ffmpeg:
        return [], "ffmpeg_missing"
    out_dir.mkdir(parents=True, exist_ok=True)
    frames_dir = out_dir / "frames"
    frames_dir.mkdir(exist_ok=True)
    for stale in frames_dir.glob("frame_*.jpg"):
        stale.unlink()
    with tempfile.TemporaryDirectory(prefix="yt-watch-", dir=out_dir) as d:
        try:
            dl = subprocess.run(download_argv(ytdlp, video_id, str(Path(d) / "%(id)s.%(ext)s")),
                                capture_output=True, text=True, timeout=DOWNLOAD_TIMEOUT)
        except subprocess.TimeoutExpired:
            return [], "download_timeout"
        videos = sorted(Path(d).glob(f"{video_id}.*"))
        if dl.returncode != 0 or not videos:
            return [], f"download_failed: {dl.stderr.strip()[-200:]}"
        try:
            ff = subprocess.run(ffmpeg_argv(ffmpeg, videos[0], frames_dir),
                                capture_output=True, text=True, timeout=FFMPEG_TIMEOUT)
        except subprocess.TimeoutExpired:
            return [], "ffmpeg_timeout"
        if ff.returncode != 0:
            return [], f"ffmpeg_failed: {ff.stderr.strip()[-200:]}"
    frames = sorted(str(p.resolve()) for p in frames_dir.glob("frame_*.jpg"))
    return frames, (None if frames else "no_scene_frames")


def main(argv=None):
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--video-id")
    src.add_argument("--url")
    ap.add_argument("--visual", action="store_true")
    ap.add_argument("--out-dir", type=Path)
    ap.add_argument("--vault")
    ap.add_argument("--meta-json", type=Path)
    args = ap.parse_args(argv)
    vid = args.video_id if args.video_id else video_id_of(args.url)
    if not vid or not VIDEO_ID_RE.match(vid):
        ap.error("not a YouTube video id or URL")
    if args.meta_json:
        out, rc = json.loads(args.meta_json.read_text(encoding="utf-8")), 0
    else:
        out, rc = helper_result(vid, args.vault)
    if out.get("status") == "ok":
        out["frames"], out["frames_error"] = [], None
        if args.visual:
            out_dir = args.out_dir or Path(tempfile.mkdtemp(prefix=f"yt-watch-{vid}-"))
            try:
                out["frames"], out["frames_error"] = extract_frames(vid, out_dir)
            except OSError as e:
                out["frames"], out["frames_error"] = [], f"frames_io_error: {e.strerror or type(e).__name__}"
    print(json.dumps(out, ensure_ascii=False))
    return rc


if __name__ == "__main__":
    sys.exit(main())
