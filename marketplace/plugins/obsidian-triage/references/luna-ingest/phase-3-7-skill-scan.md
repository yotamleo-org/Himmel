# luna-ingest — Phase 3.7 — Advisory skill scan (HIMMEL-5913, `--skill-scan` only)

Skip this entire phase unless `--skill-scan` was passed. Runs after Phase 3.6 and before Phase 4. **Advisory and opt-in**: it runs SkillSpector Stage 1 (static, `--no-llm`) over each skill directory in the source repo and stores the JSON reports with the note. A finding means "read the flagged line before adopting or using the skill". It never blocks, never changes `trust_tier`, `safety_flag`, `repo_scan` or the Phase 1.5 outcome, and never changes rc. Stage 2 (LLM) is out of scope. The pilot (HIMMEL-5860) found Stage 1 flags real patterns but also false positives on clean skills, and it never returns SAFE alone; do not read a clean report as a pass.

1. **Dry-run and existing-note short-circuit.** With `--dry-run`, print `DRY luna-ingest: would run skill scan for <owner_repo>` to stderr, set `skill_scan: unavailable`, and continue to Phase 4. When the Phase 4 target note already exists (Phase 4 will refuse with rc=3), skip the scan the same way, so no report is written or overwritten beside a note that is not rewritten.
2. **Find the skills.** A skill is a directory holding a `SKILL.md`. List them from the repo tree through `gh api` (`git/trees/<ref>?recursive=1`, entries ending `/SKILL.md` or a root `SKILL.md`). `<ref>` is the default branch, or the `<branch>` of a `/tree/<branch>/<path>` input URL. Resolve it to a commit sha once (`gh api repos/<owner_repo>/commits/<ref> --jq .sha`) and use that sha for the tree listing and for every contents fetch in step 3, so the scanned text is one revision of the clipped text. When the input URL named a `/tree/<branch>/<path>` directory, scan only the skill directories under that path. Scan at most 5 skills; list the rest in the section as `not scanned (cap)`.
3. **Fetch text only.** For each skill, make a throwaway directory and write that skill's files into it through `gh api` contents at `?ref=<ref>` (files up to 200 KB, no clone, nothing executed). A file over 200 KB, or one that fails to fetch, is omitted from the directory and the skill is marked `incomplete`; an `incomplete` skill is never counted `clean` and the section lists it as `not fully scanned (<file>)`:

   ```bash
   skill_tmp="$(mktemp -d "${TMPDIR:-/tmp}/luna-ingest-skill.XXXXXX")" || skill_tmp=""
   ```

   If `skill_tmp` is empty (the directory could not be created), record `skill_scan: unavailable` and continue to Phase 4; this phase never changes the ingest rc.

   The directory name is the slugified repository-relative skill path (`[a-z0-9-]`, `/` becomes `-`) followed by `-` and the first 8 hex characters of the sha256 of the unslugified path, so `skills/a-b` and `skills/a/b` never share a report; a root skill uses `root`.
4. **Scan through the one wrapper.** The provider must be the no-egress value: upstream defaults an unset provider to `nv_build`, which sends the skill text to build.nvidia.com, so the wrapper refuses to run unless `SKILLSPECTOR_PROVIDER=ollama`.

   ```bash
   export SKILLSPECTOR_PROVIDER=ollama
   bash "<plugin>/tools/skillspector-scan.sh" "$skill_tmp/<skill-slug>" "<vault>/<dest>/<repo-slug>.skillspector/<skill-slug>.json"
   ```

   Create `<repo-slug>.skillspector/` next to the note first and apply the Phase 4 path-safety check to it. The wrapper prints `skillspector-scan: score=<n> issues=<k> high=<h>`. Remove `$skill_tmp` afterwards. SkillSpector is never installed here: a missing binary (rc 3) or refused provider (rc 2) is `unavailable`. Install it only in a throwaway sandbox or the test VM.
5. **Record in the synthesis:**
   - Frontmatter `skill_scan: clean | flagged | unavailable`: `flagged` when any scanned skill has `issues` above 0, `unavailable` on a wrapper rc 2 or 3 for any skill or no skill found, else `clean`. A partial run is never `clean`: when the cap left skills unscanned or any skill is `incomplete`, the result is `flagged` if any scanned skill has `issues` above 0, else `unavailable`.
   - A `## Skill scan (advisory)` section: one line per skill as `` `<skill>`: score=<n> issues=<k> high=<h>, report [[<repo-slug>.skillspector/<skill-slug>.json]] ``. When `high` is above 0 add `read the flagged line before adopting`. Quote nothing from the skill text; the report holds the detail.
