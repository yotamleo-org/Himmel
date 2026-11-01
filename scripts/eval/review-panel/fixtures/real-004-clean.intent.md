fix(codex): [HIMMEL-5350] dispatch refuses an oversize matcher, an empty command and a non-boolean trust entry

Closes two residuals so the dispatch preflight is at least as strict as codex. In the config.toml reader, lines that start inside a multi-line string are not read, so a forged header in a string is not a table, and an entry whose `enabled` is not exactly `true` is dropped, since codex reads it as a bool. Scope: `scripts/codex/dispatch-codex-exec.sh` and its suite only.
