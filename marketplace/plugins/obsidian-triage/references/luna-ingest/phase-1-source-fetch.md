# luna-ingest — Phase 1 — Source fetch (github URL)

Moved verbatim out of `SKILL.md`.

Normalize to `<owner>/<repo>`:

```bash
# strip protocol, trim trailing /, strip /tree/* and /blob/* suffix
owner_repo=$(printf '%s' "$URL" | sed -E 's|^https?://github\.com/||; s|/(tree|blob)/.*$||; s|/$||')
```

Validate it matches `^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*$` — the leading char rejects `.` or `..` as owner or repo (which would otherwise survive the looser `[A-Za-z0-9_.-]+` form and let `gh api "repos/../foo"` flow through). Else rc=1.

Fetch:

```bash
gh api "repos/${owner_repo}" --jq '{name, full_name, description, html_url, language, stargazers_count, topics, default_branch, pushed_at, license: .license.spdx_id}' > /tmp/luna-ingest-meta.$$.json
```

If `gh api` fails (rc≠0): exit 2 with the stderr inlined.

**Identity (HIMMEL-3055).** Fetch the default-branch HEAD SHA — this is `upstream_commit` in the synthesis, the field that lets later tooling tell whether upstream moved since ingest without re-fetching the whole repo:

```bash
default_branch=$(jq -r '.default_branch' /tmp/luna-ingest-meta.$$.json)
gh api "repos/${owner_repo}/commits/${default_branch}" --jq '.sha' > /tmp/luna-ingest-commit.$$.txt
```

On failure, continue with `upstream_commit` omitted from the synthesis rather than failing the ingest — the repo metadata and README are still useful without it.

Read README via:

```bash
# Strip the API's embedded newlines BEFORE base64-decoding. macOS
# base64 errors on newline-padded input without -i; GNU silently
# accepts it. Trim makes the decode portable across both.
gh api "repos/${owner_repo}/readme" --jq '.content' \
  | tr -d '\n' \
  | base64 -d > /tmp/luna-ingest-readme.$$.md
```

If the README endpoint returns 404 (some repos have none): proceed with an empty README; record `README: missing` in the synthesis; omit `readme_sha256` (a hash of an absent README is an absent field, not a hash of empty bytes).

Otherwise hash the decoded bytes for `readme_sha256` — this is the identity check for "did the README change since ingest", replacing the byte-count-in-prose proxy the audit log used before:

```bash
sha256sum /tmp/luna-ingest-readme.$$.md | cut -d' ' -f1   # macOS: shasum -a 256
```
