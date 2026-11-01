---
allowed-tools: Bash, Read
description: Watch/summarize a YouTube URL cookielessly (opt. --visual frames); not /youtube, which needs a Gemini/Grok key
argument-hint: "<youtube-url> [--visual]"
---

# /watch-youtube <youtube-url> [--visual]

On-demand read of one YouTube video. No cookie, no Gemini/Grok/XAI key: you
(Claude) read the transcript and frames and write the summary yourself.

## Steps

1. **Vault first (no network).** `node <plugin>/tools/clip-lookup-cli.mjs "<url>"`
   (`<plugin>` = the installed plugin root, as in `/read-link`). An `enriched: true` hit and no `--visual` → read the clip at `path`
   and answer from it, STOP. With `--visual` (or a question about what is shown) a hit
   is context only: go on to step 2. `null`, an error, or a thin hit → step 2.
2. **Fetch.** Resolve `<plugin>` as in `/read-link` (installed plugin root) and run
   `python3 <plugin>/tools/yt-watch.py --url "<url>"` (add `--visual` when asked
   for frames / "what is shown"; add `--out-dir <scratch>` to choose where frames land).
   It prints one JSON object: `title`, `channel`, `duration`, `published`,
   `description`, `transcript` (`[{ts, tx}]`), `transcript_error`, `frames`
   (absolute jpg paths) and `frames_error`.
3. **Read and answer.** Summarize from the transcript; with `--visual`, `Read` the
   frame images (sample if there are many) and tie them to the transcript
   timestamps. Answer the operator's actual question.
4. **Failures.** `status` other than `ok` → say which (`login_wall`, `removed`,
   `skipped`, `error`) and stop; do not fall back to the vault plugin's `/youtube`.
   `transcript_error` set → say there is no transcript and work from the
   description. `frames_error` set → report it, continue with the transcript.
5. Optionally offer to file it as a clip so next time is vault-first.

## Hard rules
- No cookies, no API key, no Grok. Frames use `ffmpeg -fps_mode vfr` (never `-vsync`).
- Downloads are for frame extraction only, 720p or lower, in a scratch dir.
