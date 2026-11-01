fix(hooks): [HIMMEL-7009] let judges write evidence and call write-verdict past the env-prefix guard

block-chokepoint-env-prefix.sh refused a judge's evidence write: a quoted-heredoc body line that opens with a verb word (`read`, `export`, `printf`) beside a glob path under `scripts/` read as a seam write to the raw-text layer. The hook now drops such a heredoc body from the scanned text, only when the opener `cat > /tmp/claude-<uid>/....md|.txt <<'TAG'` is the whole line, the tag is quoted and closes, and the file is named nowhere else except after `--evidence-file`.
