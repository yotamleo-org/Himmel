// scripts/telegram/spawn-glm.ts
// Poller-free GLM worker spawn (offload spike; spec D4). Owns the
// glue the poller provides for bridge runs: prompt composition (minted session
// paths), run.log persistence from the returned tail, meta.json transitions.
// Sessions live under <BRIDGE_ROOT>/glm-sessions/ — the live poller scans ONLY
// <root>/sessions/, so nothing here can be double-spawned or Telegram-flushed.
import { existsSync, mkdirSync, writeFileSync, appendFileSync, readFileSync, readdirSync, statSync, renameSync, unlinkSync, copyFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { homedir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { runSession, killTree, BASH_BIN, REPO_ROOT, detectGlmCap, type PermissionMode, type GlmCapWindow, type RunObserver } from "./run";
import { checkPhiEgressGuards } from "./phi-egress-guard";
import { buildGlmEnv, findSettingsConflicts, formatConflict, fetchGlmUsage, readZaiKey, glmContextPreset, type SettingsConflict, type GlmUsage } from "./glm-env";
import { appendQuotaGauge, buildGlmRow, isGlmPeak } from "./quota-gauge";
import { parseGrantFlag, composeGrantLine, nextGrantId, authorityGate, classifyShape, composeEscalationForRefusedGrant, carryGrants, seedCarriedGrants, type GrantSpec } from "./grants";
// plugin profiles: resolve the dispatch's lane profile (default
// lane-impl) into a `--settings` payload, injected per-dispatch so the worker
// runs lean while the operator's shared ~/.claude stays full.
import { resolveProfileByName, parseAddPlugins, readEnabledPluginIds, loadListingLib } from "../lanes/plugin-profiles.mjs";
import { scanSkillCosts } from "../lanes/skill-cost.mjs";
import { legacyNamesOn } from "../lib/env-alias.mjs";
await loadListingLib();
// symptom-brief loop breaker, two-stage — at 2 reviewed rounds
// the brief must carry an INVARIANT section; at 3+ this cheap lane is refused
// outright (judgment-tier lane or recorded --rounds-override). Thresholds live
// in round-guard.ts (ROUND_WARN_THRESHOLD / ROUND_ESCALATE_THRESHOLD) — this
// comment deliberately names no number twice (a stated
// threshold that drifts from the code is the exact prose-vs-mechanism failure
// this guard exists to end).
import { checkRoundGuard } from "./round-guard";
// huge-diff lane guard — warn (never block) when the target
// branch's diff vs main is dominated by one huge file, naming the file, so a
// worker ingesting `git diff main` can't blow its context window unattributed.
import { checkHugeDiff } from "./huge-diff-guard";
// shared declarative flag-table parser — the mechanical part of
// parseArgs (and spawn-claudex's parseClaudexArgs) collapsed into one loop.
import { parseLaneArgs, type FlagTable } from "./lane-args";
import { DEFAULT_LANE_PROFILE, PUSH_PROTECTION_DISCLOSURE, SKILLS_SYSTEM_OVERHEAD_CHARS, STASH_BAN_LINE, WORKER_BASH_ALLOW, armStartupWatchdog, composeBashShapeWarning, composeDispatchGitState, composeOutboxWriteHint, composeRetaskBlock, composeWorkerSettings, ensureWorkspaceTrust, finalMeta, gitCapture, isHelpFlag, measureOverheadChars, mintRetaskNonce, mintSpawnStamp, preflightWindowCheck, readBriefFile, refuseBypassPermissions, refuseUnknownPermissionMode, resolveFailfastWindowMs, resolveProfileSettings, teardownMintedWorktree, toPermissionPath, transcriptDirFor, writeLiveWorkerMeta } from "./spawn-common";
export { DEFAULT_LANE_PROFILE, PUSH_PROTECTION_DISCLOSURE, SKILLS_SYSTEM_OVERHEAD_CHARS, STASH_BAN_LINE, WORKER_BASH_ALLOW, armStartupWatchdog, composeBashShapeWarning, composeDispatchGitState, composeOutboxWriteHint, composeRetaskBlock, composeWorkerSettings, ensureWorkspaceTrust, finalMeta, gitCapture, isHelpFlag, measureOverheadChars, mintRetaskNonce, mintSpawnStamp, preflightWindowCheck, readBriefFile, refuseBypassPermissions, refuseUnknownPermissionMode, resolveFailfastWindowMs, resolveProfileSettings, teardownMintedWorktree, toPermissionPath, transcriptDirFor, writeLiveWorkerMeta };

export function glmSessionRoot(): string {
  return join(process.env.BRIDGE_ROOT ?? join(homedir(), ".claude", "handover", "bridge"), "glm-sessions");
}

// mint the reporting helper beside the session metadata from the
// dispatcher's trusted checkout.
//
// Its writability is IRRELEVANT on the GLM lane, because it is never executed
// there: block-glm-external-writes.sh intercepts the report command, performs
// the decode/validate/append ITSELF, and then denies the Bash call. (An earlier
// revision of this comment claimed "the worker cannot write this directory" —
// that was false: composeWorkerSettings grants Edit on the session dir and the
// worker holds Bash(node *)/Bash(bash *). Trusting a worker-reachable file by
// pathname was the bug; the hook is now the executor, so the file is not a
// trust boundary.) It is kept as a working fallback for the non-GLM case where
// that hook is absent, and as the reference implementation of the payload
// contract.
export function mintGlmOutboxHelper(sessionDir: string, source = join(REPO_ROOT, "scripts", "glm", "append-outbox.sh")): string {
  const destination = join(sessionDir, "append-outbox.sh");
  copyFileSync(source, destination);
  return destination;
}

// GLM's external-write hook must never explicitly allow a command containing
// model-controlled report text. The fixed helper accepts only one strict
// base64url argv token and derives the destination from inherited
// GLM_SESSION_DIR; decoded text never becomes shell source.
export function composeGlmOutboxWriteHint(outbox: string): string {
  return `OUTBOX WRITE (HIMMEL-1378/1649): Write/Edit stays denied for ${outbox} by the native safety layer. The ONLY GLM reporting path is: bash "$GLM_SESSION_DIR/append-outbox.sh" <base64url-token>. The token must be unpadded base64url ([A-Za-z0-9_-]+, at most 16384 characters). EXPECTED BEHAVIOUR: the guard hook records your report itself and then DENIES that Bash call with a "guard recorded your report" message — that denial means SUCCESS, so do not retry or reword it. A denial naming a different reason (bad payload, schema, session dir) means nothing was recorded. Portable encoding example (copy its output into the fixed command): node -e "process.stdout.write(Buffer.from(process.argv[1], 'utf8').toString('base64url'))" "progress note"`;
}

// opts.shared: the shared-branch-mode variant of the branch
// instruction line — the branch is an EXISTING PR branch with history, not a
// fresh throwaway one, so the worker must be told explicitly not to touch its
// history and that a lock — not sole ownership — governs its write access.
export function composeWorkerPrompt(task: string, sessionDir: string, branch: string, opts?: { shared?: boolean }): string {
  const outbox = join(sessionDir, "outbox.jsonl");
  const context = join(sessionDir, "context.md");
  const branchLine = opts?.shared
    ? `Work ONLY inside your current directory (a dedicated git worktree). The branch ${branch} is a SHARED PR branch with EXISTING history, already checked out — do NOT create a new branch, do NOT reset/rebase/amend/force-anything; ADD new commits on top only. A lock serializes writers, so no other worker touches this branch while you run.`
    : `Work ONLY inside your current directory (a dedicated git worktree). Commit your work on the branch ${branch} which is already checked out.`;
  return [
    `You are an unattended GLM-lane worker session (himmel offload spike).`,
    branchLine,
    `HARD RULES: never push, never open a PR — a validating session reviews your branch and owns the git/PR surface. Jira updates (status, comments, followup tickets) ARE allowed via node scripts/jira/dist/index.js (audited + recoverable).`,
    STASH_BAN_LINE,
    `COMMIT EARLY (HIMMEL-1200): the MOMENT your tests pass — or the change is otherwise coherent — git commit your work on ${branch}, then keep refining in FOLLOW-UP commits. Use a CONVENTIONAL commit message ("type(scope): [HIMMEL-N ]summary", type one of feat|fix|chore|docs|refactor|test; the [HIMMEL-N ] ticket ref is optional but validated if present) — the commit-msg gate REJECTS a non-conventional message, and a rejected commit would recreate the very uncommitted-timeout failure this rule prevents. Do NOT hold all your work for one final commit: a committed-but-imperfect branch is recoverable by the parent, but an uncommitted timeout at the wall loses everything.`,
    `ATTESTATION (HIMMEL-1210): the pre-push gate needs two trailers on that first commit, and they must be TRUE — actually do the work they claim, then attest it, never paste them by rote. If you touched a shell/script file, run/exercise it, then add \`Platforms tested: <os>\` naming the OS you actually tested on. On any non-docs code change, actually read back your own diff, then add \`Security reviewed: <token>\` with whichever of these matches what you did: manual, claude-code-security-review, pr-review-toolkit, ad-hoc.`,
    composeRetaskBlock(mintRetaskNonce()),
    composeBashShapeWarning(outbox),
    composeGlmOutboxWriteHint(outbox),
    `Report progress through bash "$GLM_SESSION_DIR/append-outbox.sh" <base64url-token>; one JSON line is appended to ${outbox} and the Bash call is then DENIED — that denial is the SUCCESS signal, not a failure to retry. Encode plain text for a progress note; it is recorded as {"type":"note","text":"<decoded note>"}. If you encode a JSON OBJECT it must carry a "type" of "note" or "escalation" (see the escalation shape below) — an object without "type" is rejected by the schema and nothing is recorded. That is the only channel to the operator.`,
    `THE TASK: ${task}`,
    `If a step is hard-blocked by the GLM-lane guard, do NOT retry or give up: send a STRUCTURED escalation through the same report command — base64url-encode the JSON {"type":"escalation","capability":"<the command>","arm":"<git-push|git-url|gh|network>","reason":"<why>","step":"<which step>"} and pass that as the token. The guard validates the schema and records it so \`adjudicate list\` surfaces it to the operator; a plain-text note does NOT reach adjudication. Then SKIP that step, continue the rest of the task, and note the skipped step in your final ${context} summary.`,
    `As your FINAL action, append a one-line summary of what you did to ${context}, then stop.`,
  ].join("\n");
}

// Pointer-prompt dispatch (the handover-load pattern): the SUBMITTED
// CLI prompt is a SHORT pointer to a brief file, not the whole brief inlined.
// Inlining a ~70-line brief into the prompt — on top of the himmel session
// context (CLAUDE.md + memory + skills) — overflowed the model window, so the
// worker died at SUBMIT with "prompt is too long" before doing any work. The
// full brief (composeWorkerPrompt output) is written to <sessionDir>/brief.md
// (under the glm-sessions root, OUTSIDE the repo worktree so the worker cannot
// commit it) and the worker reads it as its complete task.
export function composePointerPrompt(briefPath: string): string {
  return [
    `You are an unattended GLM-lane worker session (himmel offload spike).`,
    `Read the file at ${briefPath} — it is your COMPLETE task brief — and execute it exactly, treating its instructions as if they were this prompt.`,
  ].join("\n");
}

export type SpawnPlan = { ok: true; slug: string; worktree: string; branch: string; warnings: SettingsConflict[] } | { ok: false; reason: string };
// Pure decision logic — deps injected so every refusal branch is testable.
export function planSpawn(
  cwd: string, name: string | undefined,
  deps: { isHimmelCheckout: (d: string) => boolean; settingsConflicts: (files: string[]) => SettingsConflict[]; home: string },
): SpawnPlan {
  if (!deps.isHimmelCheckout(cwd)) return { ok: false, reason: `spawn-glm: ${cwd} is not a himmel checkout (v1 scope: himmel repo only)` };
  const conflicts = deps.settingsConflicts([
    join(deps.home, ".claude", "settings.json"),
    // checkout layers ≡ the worktree's at branch time; settings.local.json is
    // gitignored and lives ONLY in the checkout — checking here is intentional.
    join(cwd, ".claude", "settings.json"),
    join(cwd, ".claude", "settings.local.json"),
  ]);
  // A settings `model` key is downgraded to a WARNING: the CLI's explicit
  // --model flag beats a settings model key, and under the GLM env block a lost
  // precedence fails loudly at the endpoint, never silently (spec amendment,
  // acceptance finding). env (silent-wrong-lane) and unparseable (fail-closed)
  // stay HARD REFUSALS. Keyed on the structured `kind`, not a formatted string.
  const warnings = conflicts.filter((c) => c.kind === "model");
  const refusals = conflicts.filter((c) => c.kind !== "model");
  if (refusals.length) return { ok: false, reason: `spawn-glm: settings conflicts (remove these keys first): ${refusals.map(formatConflict).join("; ")}` };
  const slug = (name?.trim() || `t${mintSpawnStamp()}`).replace(/[^a-zA-Z0-9-]/g, "-");
  return { ok: true, slug, worktree: join(cwd, ".claude", "worktrees", `glm+${slug}`), branch: `glm/${slug}`, warnings };
}

export type SharedSpawnPlan = { ok: true; slug: string; worktree: string; branch: string; warnings: SettingsConflict[]; needsWorktreeAdd: boolean } | { ok: false; reason: string };
// pure decision logic for shared-branch mode — deps injected so
// every refusal branch is testable, parallel to planSpawn. Distinct from
// planSpawn in two structural ways: (1) it NEVER mints a branch — the branch
// must already exist, a typo must refuse loudly rather than silently minting
// one; (2) the worktree is resolved from git's OWN worktree list rather than
// always minting .claude/worktrees/glm+<slug> — the branch may already be
// checked out somewhere (iterative CR-fix rounds reuse the SAME worktree
// across dispatches), and the primary checkout is a hard refusal (never
// dispatch a worker into the checkout the operator/parent is using).
export function planSharedSpawn(
  cwd: string, branch: string,
  deps: {
    isHimmelCheckout: (d: string) => boolean;
    settingsConflicts: (files: string[]) => SettingsConflict[];
    home: string;
    branchExists: (branch: string) => boolean;
    worktreeOf: (branch: string) => { path: string; isPrimary: boolean } | null;
    isDirty: (path: string) => boolean;
  },
): SharedSpawnPlan {
  if (!deps.isHimmelCheckout(cwd)) return { ok: false, reason: `spawn-glm: ${cwd} is not a himmel checkout (v1 scope: himmel repo only)` };
  const conflicts = deps.settingsConflicts([
    join(deps.home, ".claude", "settings.json"),
    join(cwd, ".claude", "settings.json"),
    join(cwd, ".claude", "settings.local.json"),
  ]);
  const warnings = conflicts.filter((c) => c.kind === "model");
  const refusals = conflicts.filter((c) => c.kind !== "model");
  if (refusals.length) return { ok: false, reason: `spawn-glm: settings conflicts (remove these keys first): ${refusals.map(formatConflict).join("; ")}` };

  // (b) a typo must not silently mint a branch — refuse, name the branch.
  if (!deps.branchExists(branch)) return { ok: false, reason: `spawn-glm: --branch ${branch} does not exist — shared mode never mints a branch (check for a typo)` };
  // (c) never point a worker at the trunk.
  if (branch === "main" || branch === "master") return { ok: false, reason: `spawn-glm: --branch ${branch} refused — shared mode never dispatches a worker at the trunk branch` };

  // (d) reuse the branch's existing worktree if it has one (never the primary
  // checkout); else mint a fresh worktree under .claude/worktrees.
  const found = deps.worktreeOf(branch);
  let worktree: string;
  let needsWorktreeAdd: boolean;
  if (found) {
    if (found.isPrimary) return { ok: false, reason: `spawn-glm: --branch ${branch} is checked out in the primary checkout (${found.path}) — refusing to dispatch a worker into the primary checkout` };
    // Plan rule 4 / codex-lane parity (I11): reuse is scoped to worktrees under
    // .claude/worktrees/ — the codex lane enforces exactly that containment.
    // A branch checked out in some arbitrary external worktree is refused; the
    // lane dispatches only into its own managed worktree tree.
    if (!found.path.replace(/\\/g, "/").includes("/.claude/worktrees/")) {
      return { ok: false, reason: `spawn-glm: --branch ${branch} is checked out in ${found.path}, outside .claude/worktrees/ — shared mode reuses only lane-managed worktrees, refusing to dispatch a worker there` };
    }
    worktree = found.path;
    needsWorktreeAdd = false;
  } else {
    const slug0 = branch.replace(/[^a-zA-Z0-9-]/g, "-");
    worktree = join(cwd, ".claude", "worktrees", `glm+${slug0}`);
    needsWorktreeAdd = true;
  }

  // (e) a REUSED worktree must start clean — a shared handoff mid-edit is not
  // a state a worker should silently inherit.
  if (!needsWorktreeAdd && deps.isDirty(worktree)) return { ok: false, reason: `spawn-glm: worktree for --branch ${branch} (${worktree}) has uncommitted changes — commit or stash before a shared-mode handoff` };

  // (f) slug mirrors planSpawn's sanitization, used only for session-dir naming.
  const slug = branch.replace(/[^a-zA-Z0-9-]/g, "-");
  return { ok: true, slug, worktree, branch, warnings, needsWorktreeAdd };
}

// isHimmelCheckout real impl: a himmel checkout carries the GLM launcher.
function isHimmelCheckout(d: string): boolean {
  return existsSync(join(d, "scripts", "claude-glm"));
}

// ── primary-checkout cwd guard ─────────────────────────────
//
// Live incident (2026-08-03 ~13:15 WEST): the orchestrator's session cwd had
// persisted inside a WORKTREE (.claude/worktrees/claudex+himmel-1474-render-
// liveness) from an earlier command, and this wrapper happily minted its
// fresh worktree/branch NESTED inside it, based off that worktree's branch
// HEAD instead of main — any diff-vs-main gate on the result would have
// carried the whole unrelated delta. The "spawn from the PRIMARY checkout"
// rule was prose in the orchestrator handover for 12+ workers and still bit
// live; per CLAUDE.md's structural>instructional doctrine (second drift =
// escalate to structural), this is a HARD REFUSE — the ticket's smaller,
// safer option (a). Transparent re-anchoring (option (b)) is deliberately
// NOT built.
//
// Detection: a linked worktree's --git-dir (per-worktree, under
// <primary>/.git/worktrees/<name>) differs from its --git-common-dir
// (always the PRIMARY repo's .git) — the primary checkout's own git-dir and
// git-common-dir are identical (verified live against this very repo). The
// /.claude/worktrees/ substring is a second, git-independent signal —
// defense in depth: still refuses a cwd that names a worktree path even
// when the git probe itself can't run (e.g. a since-removed worktree
// directory). Either signal alone refuses.
function gitDirs(cwd: string): { gitDir: string; commonDir: string } | null {
  const gd = Bun.spawnSync(["git", "-C", cwd, "rev-parse", "--git-dir"], { stdout: "pipe", stderr: "pipe" });
  const cd = Bun.spawnSync(["git", "-C", cwd, "rev-parse", "--git-common-dir"], { stdout: "pipe", stderr: "pipe" });
  if (gd.exitCode !== 0 || cd.exitCode !== 0) return null;
  return { gitDir: gd.stdout.toString().trim(), commonDir: cd.stdout.toString().trim() };
}

// Pure decision fn — `probe` injected so this is testable without real git.
// primaryPath: --git-common-dir's PARENT is always the primary checkout root
// (the common dir is <primary>/.git in both the primary checkout and every
// linked worktree); resolve(cwd, ...) makes a relative probe result (the
// not-a-worktree case, where git prints a bare ".git") absolute without
// changing an already-absolute one (the worktree case).
export function detectNonPrimaryCwd(cwd: string, probe: (cwd: string) => { gitDir: string; commonDir: string } | null = gitDirs): { ok: true } | { ok: false; primaryPath?: string } {
  const norm = (p: string) => p.replace(/\\/g, "/");
  const pathLooksLikeWorktree = norm(cwd).includes("/.claude/worktrees/");
  const dirs = probe(cwd);
  const gitSaysWorktree = dirs !== null && norm(dirs.gitDir) !== norm(dirs.commonDir);
  if (!pathLooksLikeWorktree && !gitSaysWorktree) return { ok: true };
  const primary = dirs ? dirname(resolve(cwd, dirs.commonDir)) : undefined;
  // Only name a primary that is somewhere ELSE. A standalone repo nested under
  // .claude/worktrees/ trips the path signal while git reports
  // gitDir === commonDir, so this resolves to the very cwd being refused —
  // telling the caller to cd where they already are. Drop it and let the
  // path-only diagnostic speak instead.
  const usable = primary !== undefined && norm(resolve(primary)) !== norm(resolve(cwd));
  return { ok: false, primaryPath: usable ? primary : undefined };
}

// Message composer for main()'s call site — names the primary path so the
// operator can `cd` there and retry immediately; a bare "refused" would
// waste the recovery. `probe` is threaded through for tests only.
export function refuseNonPrimaryCwd(cwd: string, probe?: (cwd: string) => { gitDir: string; commonDir: string } | null): string | undefined {
  const r = probe ? detectNonPrimaryCwd(cwd, probe) : detectNonPrimaryCwd(cwd);
  if (r.ok) return undefined;
  return r.primaryPath
    ? `spawn-glm: refusing to dispatch from ${cwd} — this is not the PRIMARY checkout (resolved primary: ${r.primaryPath}); cd there and retry.`
    : `spawn-glm: refusing to dispatch from ${cwd} — this looks like a worktree cwd (path contains /.claude/worktrees/), not the PRIMARY checkout; cd to the primary checkout and retry.`;
}

// ── real git probes for planSharedSpawn's injected deps ─────────
export function gitBranchExists(cwd: string, branch: string): boolean {
  const r = Bun.spawnSync(["git", "-C", cwd, "rev-parse", "--verify", "--quiet", `refs/heads/${branch}`], { stdout: "pipe", stderr: "pipe" });
  return r.exitCode === 0;
}

// `git worktree list --porcelain` emits one stanza per worktree (blank-line
// separated); the FIRST stanza is always the primary checkout (git's own
// listing order) — that is what lets planSharedSpawn refuse dispatching a
// worker into it.
function gitWorktreeOf(cwd: string, branch: string): { path: string; isPrimary: boolean } | null {
  const r = Bun.spawnSync(["git", "-C", cwd, "worktree", "list", "--porcelain"], { stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) return null;
  const wantRef = `refs/heads/${branch}`;
  let currentPath: string | null = null;
  let firstPath: string | null = null;
  for (const line of r.stdout.toString().split("\n")) {
    if (line.startsWith("worktree ")) {
      currentPath = line.slice("worktree ".length).trim();
      if (firstPath === null) firstPath = currentPath;
    } else if (line.startsWith("branch ") && currentPath && line.slice("branch ".length).trim() === wantRef) {
      return { path: currentPath, isPrimary: currentPath === firstPath };
    }
  }
  return null;
}

export function gitIsDirty(worktreePath: string): boolean {
  const r = Bun.spawnSync(["git", "-C", worktreePath, "status", "--porcelain"], { stdout: "pipe", stderr: "pipe" });
  // FAIL-CLOSED (C3): a failed `git status` (corrupt/stale worktree) must NOT
  // read as clean and slip past the reused-worktree-must-be-clean gate — throw
  // so the dispatch refuses cleanly (mirrors gitBranchExists/gitWorktreeOf's
  // exitCode checks). A thrown planSharedSpawn dep surfaces at main().catch.
  if (r.exitCode !== 0) throw new Error(`cannot determine worktree state for ${worktreePath}: git status failed: ${r.stderr.toString().trim()}`);
  return r.stdout.toString().trim().length > 0;
}

export type ParsedArgs = { task?: string; briefFile?: string; cwd: string; name?: string; branch?: string; timeoutMins?: number; permMode?: PermissionMode; armOnCap: boolean; grants: GrantSpec[]; autonomous: boolean; carryFrom?: string; context?: "big" | "small"; profile: string; addPlugins: string[]; roundsOverride?: string };

// the declarative flag table for parseArgs (shared loop mechanics
// live in lane-args.ts's parseLaneArgs; spawn-claudex.ts's CLAUDEX_FLAG_TABLE
// is its twin). Each entry is the exact per-flag validation the old inline
// if/else chain had — only the "requires a value" / unrecognized-flag /
// positional-capture mechanics moved out.
const GLM_FLAG_TABLE: FlagTable<ParsedArgs> = {
  "--cwd": { kind: "value", apply: (s, v) => { s.cwd = v; return undefined; } },
  "--name": { kind: "value", apply: (s, v) => { s.name = v; return undefined; } },
  // --branch selects shared-branch mode (commit onto an existing
  // caller-named branch under a lock, instead of minting glm/<slug> fresh).
  "--branch": { kind: "value", apply: (s, v) => { s.branch = v; return undefined; } },
  "--timeout-mins": {
    kind: "value",
    apply: (s, v) => {
      const n = Number(v);
      if (!Number.isFinite(n) || n <= 0) return `--timeout-mins must be a positive number (got "${v}")`;
      s.timeoutMins = n;
      return undefined;
    },
  },
  "--permission-mode": {
    kind: "value",
    apply: (s, v) => {
      const err = refuseUnknownPermissionMode(v);
      if (err) return err;
      s.permMode = v as PermissionMode;
      return undefined;
    },
  },
  "--arm-on-cap": { kind: "bool", apply: (s) => { s.armOnCap = true; } },
  "--no-arm-on-cap": { kind: "bool", apply: (s) => { s.armOnCap = false; } },
  "--grant": {
    kind: "value",
    apply: (s, v) => {
      const p = parseGrantFlag(v);
      if (!p.ok) return `--grant ${p.error}`;
      s.grants.push(p.spec);
      return undefined;
    },
  },
  "--autonomous": { kind: "bool", apply: (s) => { s.autonomous = true; } },
  "--carry-from": { kind: "value", apply: (s, v) => { s.carryFrom = v; return undefined; } },
  // --brief-file reads the TASK from a file, so a multi-line
  // dispatch is ONE literal command (`bun scripts/telegram/spawn-glm.ts
  // --brief-file <path> ...`) instead of the cd/$(cat)/var compound that
  // defeats both the allow-rule prefix and the native permission matcher.
  // The file is READ in main(), not here — parseArgs stays
  // pure (fs-free), so a missing/unreadable path is a clean main()-side
  // usage refusal.
  "--brief-file": { kind: "value", apply: (s, v) => { s.briefFile = v; return undefined; } },
  "--context": {
    kind: "value",
    apply: (s, v) => {
      if (v !== "big" && v !== "small") return `--context must be big or small (got "${v}")`;
      s.context = v;
      return undefined;
    },
  },
  // --profile selects the lane plugin profile (default lane-impl);
  // --add-plugins a@m,b@m is the per-dispatch overlay (repeatable — values
  // accumulate). Resolution/validation happens in main() so a bad name/id is a
  // clean pre-side-effect refusal.
  "--profile": { kind: "value", apply: (s, v) => { s.profile = v; return undefined; } },
  "--add-plugins": { kind: "value", apply: (s, v) => { s.addPlugins.push(...parseAddPlugins(v)); return undefined; } },
  // recorded operator override for the round guard's cheap-lane
  // refusal at ROUND_ESCALATE_THRESHOLD. Reason substance is enforced by the
  // guard itself (checkRoundGuard), so the refusal can explain the floor.
  "--rounds-override": {
    kind: "value",
    missingValueError: "--rounds-override requires a value (why another cheap-lane round is justified)",
    apply: (s, v) => { s.roundsOverride = v; return undefined; },
  },
};

// Pure + validated: a value-taking flag with no value, or a non-positive /
// non-finite --timeout-mins, is a USAGE REFUSAL (main → exit 2) — NOT a silent
// NaN that setTimeout(NaN)≈0 turns into an instant kill, and NOT a bare
// resolve() throw from a trailing --cwd with no value.
export function parseArgs(argv: string[]): { ok: true; args: ParsedArgs } | { ok: false; error: string } {
  const args: ParsedArgs = {
    task: undefined, briefFile: undefined, cwd: process.cwd(), name: undefined, branch: undefined,
    timeoutMins: undefined, permMode: undefined, armOnCap: true, grants: [], autonomous: false,
    carryFrom: undefined, context: undefined, profile: DEFAULT_LANE_PROFILE, addPlugins: [], roundsOverride: undefined,
  };
  const result = parseLaneArgs(argv, GLM_FLAG_TABLE, args, (s, token) => { if (s.task === undefined) s.task = token; });
  if (!result.ok) return result;
  // --branch and --name are mutually exclusive — shared mode
  // derives its slug from the branch name, so a co-supplied --name would be
  // silently ignored (or ambiguous about which name wins). Refuse instead.
  if (args.branch !== undefined && args.name !== undefined) return { ok: false, error: "--branch and --name are mutually exclusive (shared mode derives the slug from the branch)" };
  // --brief-file and a positional prompt are mutually exclusive —
  // the file's contents BECOME the task, so a co-supplied positional would be
  // silently dropped (or ambiguous about which brief wins). Refuse instead.
  if (args.briefFile !== undefined && args.task !== undefined) return { ok: false, error: "--brief-file and a positional prompt are mutually exclusive (pass the brief as a file or inline, not both)" };
  return { ok: true, args };
}

// read a capped session's grants.jsonl and compute the
// carried grant + escalation lines to seed into a respawned session. The
// shape-split (READ → seed, autonomous WRITE → re-escalate) lives in the pure
// seedCarriedGrants; this adds the fs read + fail-open + observability.
// Exported so the security wiring (autonomousEff → gate) is unit-tested
// end-to-end against a temp dir, not just by inspection. FAIL-OPEN: a missing OR
// UNREADABLE grants.jsonl (EACCES/EISDIR/TOCTOU) → no carry (F4 reset), NEVER
// throws — carry is best-effort side work that must not abort the dispatch it
// exists to perform (mirrors the buildGlmEnv / quota-gauge guards).
export function applyCarryFrom(carryFrom: string, autonomous: boolean, existing: string[], now: Date): { grantLines: string[]; escalationLines: string[]; summary: string } {
  const src = join(carryFrom, "grants.jsonl");
  if (!existsSync(src)) return { grantLines: [], escalationLines: [], summary: `--carry-from ${carryFrom} has no grants.jsonl — no grants carried (F4 reset).` };
  try {
    const lines = readFileSync(src, "utf8").split("\n").filter(Boolean);
    const { grantLines, escalationLines } = seedCarriedGrants(carryGrants(lines, now), autonomous, existing, now);
    const esc = escalationLines.length ? `; ${escalationLines.length} write grant(s) re-escalated (F4 not preserved for writes on the autonomous path)` : "";
    return { grantLines, escalationLines, summary: `carried ${grantLines.length} grant(s) from ${carryFrom} (${lines.length} line(s) seen)${esc}.` };
  } catch (e) {
    return { grantLines: [], escalationLines: [], summary: `--carry-from ${carryFrom} grants.jsonl unreadable (${String((e as { message?: string })?.message ?? e)}) — no grants carried (F4 reset).` };
  }
}

// the submit-reject that killed inlined-brief workers. Distinct from
// a usage cap — this is a DETERMINISTIC per-turn rejection (the request itself is
// too large), NOT a quota reset to arm against. Matched so a bare `failed` run
// carries an honest failure_class instead of vanishing as an unexplained failure.
export function detectPromptTooLong(tail: string): boolean {
  return /prompt is too long/i.test(tail);
}

// ── the spawner owns durability ────────────────────────────────
// Measured 2026-08-06: FOUR of four GLM dispatches produced substantive,
// in-scope work and committed NONE of it; the parent harvested all four by
// hand. "Commit early" is already in every brief (composeWorkerPrompt) and
// already allowed by WORKER_BASH_ALLOW — it failed 4/4. Per the
// structural>instructional rule, durability therefore moves OUT of the brief
// and INTO the spawner.
//
// The declared checkpoint scope. spawn-glm has no per-dispatch file-scope
// declaration today, so this is the standing default: an EXTENSION allow-list.
// git pathspec globs match across `/` (no FNM_PATHNAME), so `*.ts` reaches
// `scripts/telegram/x.ts` — the list captures source written anywhere in the
// tree, including files the worker newly created, while excluding the run
// logs, transcripts and binaries a worktree accumulates.
//
// NOT `git add -A`. .gitignore is the primary defense against generated
// artifacts and makes -A *mostly* safe, but a checkpoint is harvested with
// `git restore --source`, which writes every captured path back into the
// operator's tree — so the blast radius of a stray capture is a dirtied
// checkout, not just an ugly diff. An allow-list keeps that bounded, and
// leaves no `-A` precedent in a spawner a worker's own scripts run beside.
export const CHECKPOINT_GLOBS = [
  "*.ts", "*.tsx", "*.js", "*.mjs", "*.cjs", "*.sh", "*.ps1", "*.py",
  "*.md", "*.json", "*.jsonc", "*.yml", "*.yaml", "*.toml", "*.txt", "*.sql",
];

export type CheckpointRun = (cmd: string[], cwd: string, env?: Record<string, string>) => { code: number; stdout: string };

// PLUMBING, deliberately. write-tree/commit-tree/update-ref run NO hooks at
// all, so there is nothing to bypass and no `--no-verify` precedent for a later
// agent to cite. The ref sits at refs/checkpoints/<slug>, OUTSIDE refs/heads/,
// so no branch push (`git push origin <b>`, `--all`, `--tags`, `--follow-tags`)
// can carry it — the containment a wip-commit approach could only assert. A
// private GIT_INDEX_FILE leaves the worker's own index untouched.
//
// Callers must treat this as advisory: it never throws and never changes the
// run's exit code.
export function checkpointWorktree(
  worktree: string,
  slug: string,
  sessionDir: string,
  globs: string[],
  run: CheckpointRun,
): { committed: boolean; ref?: string; reason: string } {
  const safe = (cmd: string[], env?: Record<string, string>) => {
    try { return run(cmd, worktree, env); }
    catch { return { code: -1, stdout: "" }; }   // never throw into runBody's finally
  };
  const st = safe(["status", "--porcelain"]);
  if (st.code === -1) return { committed: false, reason: "git unavailable" };
  if (st.code !== 0) return { committed: false, reason: `status rc=${st.code}` };
  if (st.stdout.trim() === "") return { committed: false, reason: "clean" };

  // The private index lives in the SESSION DIR, not the worktree: an index file
  // inside the worktree is itself untracked, so it would dirty
  // `status --porcelain` and corrupt the next checkpoint's "clean" check.
  const env = { GIT_INDEX_FILE: join(sessionDir, "checkpoint-index") };
  // SEED THE INDEX FROM HEAD FIRST. A fresh GIT_INDEX_FILE is EMPTY, so
  // write-tree over it yields a tree containing ONLY the globbed files — i.e. a
  // commit whose diff vs HEAD DELETES the entire rest of the repo. Any
  // cherry-pick, merge or restore from that ref would be destructive.
  // read-tree makes the snapshot HEAD-plus-changes, which is what "checkpoint"
  // means. The mock suite cannot catch this (canned SHAs) — the real-git test
  // asserting no `D` lines is the gate.
  if (safe(["read-tree", "HEAD"], env).code !== 0) return { committed: false, reason: "read-tree failed" };
  // Per-glob and TOLERANT: `git add -- <glob>` is FATAL when a glob matches
  // nothing on disk, so a single unmatched declared glob would otherwise throw
  // the whole checkpoint away.
  let staged = 0;
  for (const g of globs) {
    if (safe(["add", "--", g], env).code === 0) staged++;
  }
  if (staged === 0) return { committed: false, reason: "no declared glob matched" };
  const tree = safe(["write-tree"], env);
  if (tree.code !== 0 || !tree.stdout.trim()) return { committed: false, reason: "write-tree failed" };
  // `git add` exits 0 on a pathspec MATCH, not on a CHANGE: a worktree dirty
  // only in an EXCLUDED path (run.log) passes the status guard above, a declared
  // glob then matches tracked UNCHANGED files, and write-tree yields HEAD's OWN
  // tree. Committing that empty delta would report `committed: true` and print
  // the recovery line — telling the operator uncommitted work was captured when
  // NOTHING in scope changed. That is worse than reporting nothing, because it
  // is trusted. Compare the written tree to HEAD's tree and refuse if identical.
  // An unborn HEAD (no commits yet) has no HEAD^{tree}: there a non-empty tree
  // is genuinely new work and must still checkpoint.
  const headTree = safe(["rev-parse", "HEAD^{tree}"]);
  if (headTree.code === 0 && headTree.stdout.trim() === tree.stdout.trim()) {
    return { committed: false, reason: "no in-scope change" };
  }
  const head = safe(["rev-parse", "HEAD"]);
  const msg = `checkpoint(${slug}): spawner snapshot — UNREVIEWED, not a commit`;
  const args = ["commit-tree", tree.stdout.trim(), "-m", msg];
  // Parented on HEAD when there is one (an unborn branch has none), so the ref
  // is diffable against the branch instead of being a rootless orphan.
  if (head.code === 0 && head.stdout.trim()) args.splice(2, 0, "-p", head.stdout.trim());
  const commit = safe(args, env);
  if (commit.code !== 0 || !commit.stdout.trim()) return { committed: false, reason: "commit-tree failed" };
  const ref = `refs/checkpoints/${slug}`;
  if (safe(["update-ref", ref, commit.stdout.trim()]).code !== 0) {
    return { committed: false, reason: "update-ref failed" };
  }
  return { committed: true, ref, reason: "checkpointed" };
}

// READ-MERGE-WRITE, never a blind write. executeRun records the run's terminal
// state at five sites (:885 final, :891 prompt-too-long, :908 long-window cap,
// :927 cap+resume, and the outer catch's failed-meta), and the checkpoint lands
// AFTER all of them — a `writeFileSync(metaPath, {...runningMeta, checkpoint})`
// would clobber whichever one just fired and flip the run back to "running".
// Fail-open on every branch: a meta that cannot be read or written must not
// change the run's outcome, so the worst case is a checkpoint that exists on
// disk but is not advertised in meta.json (the chief line below still names it).
export function mergeMetaCheckpoint(metaPath: string, checkpoint: Record<string, unknown>): boolean {
  try {
    const prior = JSON.parse(readFileSync(metaPath, "utf8"));
    writeFileSync(metaPath, JSON.stringify({ ...prior, checkpoint }, null, 2));
    return true;
  } catch (e) {
    console.error(`spawn-glm: checkpoint recorded on disk but meta.json merge failed (non-fatal): ${String((e as any)?.message ?? e)}`);
    return false;
  }
}

// ── done_escalated — a timeout is not the same shape as an
// unfinished run when the worker actually finished. The observed shape (GLM
// probation, 2026-08-08): a worker commits its work, trailers, tests all
// green, checkpoint reason=clean — then spends the REST of its window
// escalating a git push, which block-glm-external-writes.sh hard-blocks by
// design (the GLM lane cannot push; the parent must). The worker's own
// outbox contract already names the block precisely
// ({"type":"escalation","arm":"git-push",...}, see composeWorkerPrompt's
// escalation line); this only checks for that one arm — the shape a
// structurally-blocked (not failed) push produces. Tolerant of a torn/partial
// last line (a mid-write outbox at kill time): only whole, parseable JSON
// lines are considered, and a corrupt tail fails CLOSED (not an escalation)
// rather than throwing.
export function hasGitPushEscalation(outboxText: string): boolean {
  return outboxText.split("\n").some((line) => {
    const t = line.trim();
    if (!t) return false;
    try {
      const row = JSON.parse(t);
      return row && row.type === "escalation" && row.arm === "git-push";
    } catch {
      return false;
    }
  });
}

// Real worktree-cleanliness probe for the done_escalated check in executeRun:
// a clean `git status --porcelain` means nothing is left uncommitted, i.e.
// the worker's own commits already captured everything (mirrors
// checkpointWorktree's "clean" classification above). A git failure fails
// CLOSED (not clean) — an unreadable worktree state must never manufacture a
// false success.
function defaultCheckTreeClean(worktree: string): boolean {
  const r = gitCapture(["status", "--porcelain"], worktree);
  return r.code === 0 && r.stdout.trim() === "";
}

// ── dispatcher-SIGTERM finalize ───────────────────────────
// A caller-side kill (the documented shape: a bounded foreground Bash-tool
// call caps at 10 min and SIGTERMs the whole spawn-glm tree) used to leave
// meta.json stuck at "running" forever — reconcile-workers.sh then reads a
// CONFIRMED-dead pid past its grace window and marks the row "orphaned",
// indistinguishable from a genuinely wedged/never-started worker. A
// synchronous SIGTERM handler (wired at the bottom, import.meta.main ONLY —
// never on a test import, which must not have a stray SIGTERM exit the test
// runner) writes a distinct terminal status BEFORE the process dies, so a
// caller-killed tree can never masquerade as orphaned or as a
// startup-hang. Armed/disarmed around executeRun's live runSession window
// (module-level state — there is exactly one dispatch per process).
let liveTermState: { metaPath: string; runningMeta: Record<string, unknown> } | undefined;

export function armSigtermFinalize(metaPath: string, runningMeta: Record<string, unknown>): void {
  liveTermState = { metaPath, runningMeta };
}

export function disarmSigtermFinalize(): void {
  liveTermState = undefined;
}

// Exported (not inlined in the process.on listener below) so a test can drive
// the write directly — calling the real listener would call process.exit()
// and kill the test runner.
export function sigtermFinalize(): void {
  if (!liveTermState) return;
  try {
    writeFileSync(liveTermState.metaPath, JSON.stringify({ ...liveTermState.runningMeta, status: "killed-by-caller", exit_code: -1, pid: 0, timed_out: false }, null, 2));
  } catch (e) {
    console.error(`spawn-glm: SIGTERM finalize failed (best-effort, process is exiting anyway): ${String((e as any)?.message ?? e)}`);
  }
}

// The run-and-record step, extracted so the meta-transition contract is
// testable with an injected runSession. meta.json ALWAYS leaves "running": the
// success path writes finalMeta (done/failed/capped/blocked), and a thrown
// runSession writes {status:"failed", exit_code:-1} THEN rethrows to
// main().catch — never a stuck "running" meta orphaned by a mid-run throw.
export async function executeRun(deps: {
  runSession: typeof runSession;
  prompt: string; worktree: string; permMode?: PermissionMode;
  sessionDir: string; metaPath: string; runningMeta: Record<string, unknown>;
  capGuard?: CapGuardDeps;
  // the resolved `--settings` plugin-profile payload (undefined =
  // operator profile / no injection). Threaded to runSession's 6th arg.
  settings?: string;
  // test seams for the startup-hang watchdog (all optional; prod
  // callers pass nothing and get the env-tunable defaults below).
  startupWatch?: { rootDir?: string; windowMs?: number; pollMs?: number; kill?: (pid: number) => void };
  // test seam: override the real git worktree-cleanliness
  // probe used by the done_escalated reclassification below.
  checkTreeClean?: (worktree: string) => boolean;
}): Promise<{ code: number }> {
  // live observability. A worker that hangs at its very first
  // tool call (the documented shape — a native permission prompt
  // the closed-stdin session can never answer) used to be INVISIBLE for the
  // entire RUN_TIMEOUT_MS window: run.log was appended only from the final
  // `res.tail`, below, AFTER runSession resolves — which for a truly-hung
  // worker never happens until the timeout kill. onSpawn records the REAL pid
  // (meta.json previously stayed pid:0 for the whole "running" window, so an
  // external watcher had no pid to check liveness against — see
  // await-glm-worker.sh's new stall/phantom check) and stamps a first
  // last_output_at; onChunk live-appends every stdout/stderr chunk to run.log
  // AS IT ARRIVES and refreshes last_output_at, so a watcher can detect "no
  // output for N minutes" long before the full timeout. Both writers are
  // best-effort (never allowed to throw into the run) and merge over
  // deps.runningMeta so "status" stays "running" until the terminal write
  // below. liveChunksSeen gates the legacy final-tail append (next block)
  // so a real run's output is never written to run.log TWICE.
  let liveChunksSeen = false;
  let livePid: number | undefined;
  const runLogPath = join(deps.sessionDir, "run.log");
  // startup-hang fail-fast. ~30% of dispatches die having written
  // NOTHING beyond the 192-byte banner — the worker process is alive for the
  // whole RUN_TIMEOUT window but the model never responds (72 of 73 timeouts in
  // the measured history; 30h of wall-clock burned waiting). stdout is NOT the
  // discriminator (a healthy interactive worker also sits at 192 B and flushes
  // at the end — the 1560 case), so the watchdog reads the session TRANSCRIPT
  // (~/.claude/projects/<mangled-cwd>/*.jsonl): Claude Code appends it on every
  // model response, independent of stdout buffering. Growth = the model
  // answered = permanently disarm. SIZE, never mtime — mtime advances on a
  // frozen file (the 3h-dead-session trap). Fires only inside the startup
  // window and only when the transcript never grew AND stdout stayed at the
  // banner; every error path disarms (fail-open — this must never kill a
  // healthy worker on the watchdog's own bugs). Killed runs are classified
  // failure_class="startup-hang" so the lane's accounting finally separates
  // never-started from ran-then-timed-out (the ticket's step 1).
  let startupHang = false;
  let outputBytes = 0;
  let disarmWatch: () => void = () => {};
  const watchWindowMs = deps.startupWatch?.windowMs ?? resolveFailfastWindowMs(process.env.GLM_STARTUP_FAILFAST_MINS);
  if (watchWindowMs > 0) {
    disarmWatch = armStartupWatchdog({
      worktree: deps.worktree, windowMs: watchWindowMs,
      rootDir: deps.startupWatch?.rootDir ?? join(homedir(), ".claude", "projects"),
      pollMs: deps.startupWatch?.pollMs, kill: deps.startupWatch?.kill,
      livePid: () => livePid, outputBytes: () => outputBytes,
      onHang: () => { startupHang = true; },
      label: "spawn-glm", tuneHint: "GLM_STARTUP_FAILFAST_MINS",
    });
  }
  const writeRunningMeta = (extra: Record<string, unknown>) => {
    // CR/T14: write-then-rename, not a truncating in-place write —
    // await-glm-worker.sh polls this same file every POLL_SECS, and a read
    // landing mid-truncate could see a partial object (e.g. started_at present,
    // last_output_at not yet written), which the stall check misreads as a
    // spurious STALLED on a healthy worker. rename() is atomic within a dir.
    writeLiveWorkerMeta(deps.metaPath, deps.runningMeta, extra, "spawn-glm");
  };
  const observe: RunObserver = {
    onSpawn: (pid) => { livePid = pid; writeRunningMeta({ pid, last_output_at: new Date().toISOString() }); },
    onChunk: (chunk) => {
      liveChunksSeen = true;
      outputBytes += chunk.length;
      if (outputBytes > 512) disarmWatch(); // real output beyond the banner — not the 1575 class
      try { appendFileSync(runLogPath, chunk); }
      catch (e) { console.error(`spawn-glm: live run.log append failed (non-fatal): ${String((e as any)?.message ?? e)}`); }
      writeRunningMeta({ pid: livePid ?? 0, last_output_at: new Date().toISOString() });
    },
  };
  // arm the SIGTERM finalize for exactly the live run
  // window below; the finally at the bottom of this try/catch disarms it on
  // every exit path (success, capped/blocked/timeout/failed, or a thrown
  // runSession).
  armSigtermFinalize(deps.metaPath, deps.runningMeta);
  try {
    const res = await deps.runSession(deps.prompt, deps.worktree, deps.permMode, "glm", undefined, deps.settings, observe);
    disarmWatch(); // the run is over either way — never let the interval outlive it
    // run.log append is COSMETIC persistence (the debug tail). Isolate it (#849):
    // an I/O failure here (EACCES/EISDIR/ENOSPC) must NOT throw into the outer
    // catch — that writes status:failed + rethrows, flipping a successful run to
    // failed. The final-meta write below is the load-bearing terminal-state record.
    // Skipped when the live onChunk path already streamed the run's output
    // — deps.runSession stubs in tests never call onChunk, so
    // this stays the ONLY write path for every existing pinned test.
    if (res.tail !== undefined && !liveChunksSeen) {
      try { appendFileSync(runLogPath, res.tail); }
      catch (e) { console.error(`spawn-glm: run.log append failed (non-fatal): ${String((e as any)?.message ?? e)}`); }
    }
    const fm = finalMeta(res.code, res.pid, res.capped, res.blocked, res.timedOut);
    writeFileSync(deps.metaPath, JSON.stringify({ ...deps.runningMeta, ...fm }, null, 2));
    // a bare timeout is not the same shape as an unfinished
    // run when the worker actually finished — committed its work, left a
    // clean tree — and only kept spinning because the LAST remaining step
    // (git push) is a structurally hard-blocked capability. Reclassify so
    // await-glm-worker/reconcile-workers/verify-return read a finished
    // dispatch as SUCCESS-shaped, not a failure. Scoped to a bare timeout
    // ONLY: capped/blocked/failed stay their own honest terminal state, and a
    // code===0 run is already "done" and needs no relabeling. doneEscalated
    // gates the startup-hang/prompt-too-long reclassifications below so a
    // done_escalated run is never further relabeled.
    let doneEscalated = false;
    if (fm.status === "timeout") {
      const outboxPath = join(deps.sessionDir, "outbox.jsonl");
      let outboxText = "";
      try { outboxText = existsSync(outboxPath) ? readFileSync(outboxPath, "utf8") : ""; }
      catch { /* fail-open: an unreadable outbox reads as no escalation */ }
      const treeClean = (deps.checkTreeClean ?? defaultCheckTreeClean)(deps.worktree);
      if (treeClean && hasGitPushEscalation(outboxText)) {
        doneEscalated = true;
        writeFileSync(deps.metaPath, JSON.stringify({ ...deps.runningMeta, ...fm, status: "done_escalated", escalation: "git-push" }, null, 2));
        console.error("spawn-glm: run hit the timeout but the worktree is clean with a git-push escalation on record — reclassified done_escalated: the worker finished, block-glm-external-writes.sh stopped the push by design; the parent must push from the primary checkout and run verify-return.");
      }
    }
    // a watchdog-killed run is a classified startup hang, not a
    // generic failure — the lane's accounting must separate never-started
    // (clean tree, banner-only log) from ran-then-timed-out (dirty tree,
    // >192 B). Mirrors the prompt-too-long classification below.
    if (!doneEscalated && startupHang && (fm.status === "failed" || fm.status === "timeout")) {
      writeFileSync(deps.metaPath, JSON.stringify({ ...deps.runningMeta, ...fm, failure_class: "startup-hang" }, null, 2));
      console.error("spawn-glm: run classified startup-hang — the model never responded; killed at the fail-fast window instead of the full run cap. Do NOT blind-retry as primary mitigation; the base rate is ~30%.");
    }
    // an honest failure_class for the submit-reject. ONLY on a bare
    // `failed` (a capped/blocked/timeout run is a distinct terminal state, handled
    // below/elsewhere) whose tail carries the reject. Base status stays "failed" —
    // no new status union member, downstream consumers switch on the existing set.
    if (!doneEscalated && fm.status === "failed" && detectPromptTooLong(res.tail ?? "")) {
      writeFileSync(deps.metaPath, JSON.stringify({ ...deps.runningMeta, ...fm, failure_class: "prompt-too-long" }, null, 2));
      console.error("spawn-glm: run FAILED — classified prompt-too-long (the model rejected the request as too large). run.log holds the raw API error tail. NOTE: a quota-side reject can masquerade as this — cross-check the preflight usage line above.");
    }
    if (deps.capGuard && res.capped) {
      // Cap-guard post-processing is BEST-EFFORT armor around an already-honest
      // terminal state: the capped meta above is the base layer. A throw below
      // (Bun.spawnSync THROWS on an unspawnable binary — distinct from a nonzero
      // rc — and writeFileSync can throw on I/O) must degrade to a loud warn,
      // never fall to the outer catch: that would clobber the capped meta to
      // "failed" and flip spawn-glm's exit code (CR round finding).
      try {
        const g = deps.capGuard;
        const now = g.now?.() ?? new Date();
        const cls = detectGlmCap(res.tail ?? "");
        const cap_window: MetaCapWindow = cls?.window ?? "generic";
        const base = { ...deps.runningMeta, ...finalMeta(res.code, res.pid, res.capped, res.blocked, res.timedOut), cap_window };
        if (cap_window === "long") {
          writeFileSync(deps.metaPath, JSON.stringify({ ...base, cap_source: "no-arm-long-window" }, null, 2));
          console.error("spawn-glm: long-window GLM cap — NOT auto-armed; recover manually after the documented reset");
          // chunk B: observe the long-window cap passively (NO new fetch
          // — glm_peak stamped from `now`) so a long-window GLM cap shows up in
          // the ledger instead of vanishing at this early return. window:"long"
          // mirrors GlmCapWindow — the detector cannot distinguish weekly from
          // monthly/balance/expired here, so a specific sub-window would be
          // fabricated precision (CR [codex-1]). Own try/catch: a ledger failure
          // must NEVER change meta/exit behavior (mirrors the preflight append's
          // guard); meta above is the base layer, already written.
          try { appendQuotaGauge({ v: 1, ts: now.toISOString(), lane: "glm", source: "cap-long", used_pct: null, window: "long", reset_at: null, tier: null, glm_peak: isGlmPeak(now.getTime()), note: "long-window GLM cap - not auto-armed" }); } catch (e) { console.error(`spawn-glm: quota-gauge cap-long append failed (non-fatal): ${String((e as any)?.message ?? e)}`); }
          return { code: res.code };
        }
        const usage = await g.fetchUsage();
        appendQuotaGauge(buildGlmRow(usage, Date.now())); // WS9 (HIMMEL-654): observe the cap-time GLM reading (null -> invisible row); passive, no new fetch
        // spirit at cap time too: a null re-query is visible, not a
        // silent fall-through to the floor (preflight has its own line).
        if (usage === null) console.error("spawn-glm: usage invisible at cap time (monitor endpoint unavailable) — resume slot falls back to error-body/cycle-floor");
        const { resumeAt, capSource } = computeResumeAt({ now, startedAt: g.startedAt, usage, tail: res.tail });
        writeFileSync(deps.metaPath, JSON.stringify({ ...base, resume_at: resumeAt.toISOString(), cap_source: capSource }, null, 2)); // meta FIRST (base layer)
        if (g.armOnCap) {
          const snap = join(deps.sessionDir, "respawn-handover.md");
          writeFileSync(snap, composeRespawnHandover({ task: g.task, cwd: g.cwd, slug: g.slug, timeoutMins: g.timeoutMins, permMode: g.permMode, sessionDir: deps.sessionDir, branch: g.branch, resumeAtIso: resumeAt.toISOString(), shared: g.shared, profile: g.profile, addPlugins: g.addPlugins, roundsOverride: g.roundsOverride }));
          const rc = g.arm(toArmHHMM(resumeAt), snap);
          // rc=3 honesty (CR round): --dedup-any defers to ANY queued resume job,
          // possibly an UNRELATED handover — this task's respawn handover is then
          // NOT independently scheduled; the meta resume_at is the breadcrumb.
          if (rc === 0) console.error(`spawn-glm: GLM cap — resume ARMED at ${toArmHHMM(resumeAt)} (${capSource})`);
          else if (rc === 3) console.error(`spawn-glm: GLM cap — resume deferred: another resume job is already armed (dedup-any); this task is NOT independently scheduled — if that job does not cover this work, recover via resume_at in meta.json`);
          else console.error(`spawn-glm: GLM cap — arm FAILED (rc=${rc}); resume_at ${resumeAt.toISOString()} recorded in meta for manual recovery`);
        }
      } catch (e) {
        console.error(`spawn-glm: GLM cap — post-processing threw (${String((e as any)?.message ?? e)}); capped meta preserved, resume NOT armed — recover via resume_at/started_at in meta.json`);
      }
      return { code: res.code };
    }
    return { code: res.code };
  } catch (e) {
    disarmWatch(); // a thrown run must not leave the interval holding the event loop
    writeFileSync(deps.metaPath, JSON.stringify({ ...deps.runningMeta, status: "failed", exit_code: -1, pid: 0 }, null, 2));
    throw e;
  } finally {
    // every exit path from the live run window disarms —
    // a SIGTERM arriving AFTER this function has already written its own
    // terminal meta must never overwrite it with killed-by-caller.
    disarmSigtermFinalize();
  }
}

// the shared-branch acquire/poison/run/restore/release lifecycle,
// extracted from main() so it is executable-testable against a real temp git
// repo + the real lock script (spawn-glm.test.ts I6/I7) rather than only
// source-text wiring-pinned. Dependency-injected: `gitAdd` performs the
// existing-branch (NO -b) worktree add main() supplies, `runBody` is the
// mkdir-sessionDir-through-executeRun block main() builds. Returns ok:false on
// a failed lock acquire (main maps it to exit 4). The lock release runs in a
// finally on every CATCHABLE exit path (including a thrown runBody, which
// still propagates after cleanup); a SIGKILL/hard-kill is not catchable, so a
// leaked lock is recovered manually via `shared-branch-lock.sh release`
// (GLM lane, dropped).
export async function runSharedDispatch(p: {
  repoDir: string; worktree: string; branch: string; needsWorktreeAdd: boolean;
  lockScript: string; gitAdd: () => void; runBody: () => Promise<number>;
}): Promise<{ ok: true; code: number } | { ok: false; reason: string }> {
  const acquire = Bun.spawnSync([BASH_BIN, p.lockScript, "acquire", p.repoDir, p.branch, "glm"], {
    stdout: "pipe", stderr: "pipe",
    env: { ...process.env, SHARED_BRANCH_LOCK_HOLDER_PID: String(process.pid) },
  });
  if (acquire.exitCode !== 0) return { ok: false, reason: acquire.stderr.toString().trim() || `spawn-glm: shared-branch-lock acquire failed (rc=${acquire.exitCode})` };
  try {
    if (p.needsWorktreeAdd) p.gitAdd(); // NO -b: an existing branch, never minted here
    // Unconditional: a REUSED managed
    // worktree (needsWorktreeAdd=false) from a pre-change or failed dispatch
    // may never have been trust-seeded — seeding is idempotent, so cover both.
    ensureWorkspaceTrust(p.worktree);
    // No pushurl mutation here any more (see the removal note
    // above): this dispatch leaves the operator's git config exactly as it
    // found it, in every scope.
    const code = await p.runBody();
    return { ok: true, code };
  } finally {
    // Releasing the lock is now the ONLY cleanup: a leaked lock blocks the
    // next writer on this branch, so it keeps its own try/catch — a THROWING
    // Bun.spawnSync (unspawnable git/bash binary, not just a nonzero exit)
    // must degrade to a logged warning and never replace/out-rank a
    // substantive error already propagating from runBody/gitAdd above.
    try {
      const rel = Bun.spawnSync([BASH_BIN, p.lockScript, "release", p.repoDir, p.branch], { stdout: "pipe", stderr: "pipe" });
      if (rel.exitCode !== 0) console.error(`spawn-glm: WARNING - shared-branch-lock release failed (rc=${rel.exitCode}); the lock for ${p.branch} may stay held: ${rel.stderr.toString().trim()}`);
    } catch (e) {
      console.error(`spawn-glm: WARNING - shared-branch-lock release threw (${String((e as any)?.message ?? e)}); the lock for ${p.branch} may stay held`);
    }
  }
}

async function main(): Promise<void> {
  const usage = "usage: spawn-glm [<prompt> | --brief-file <path>] [--cwd <dir>] [--name <slug>] [--branch <existing-branch>] [--timeout-mins <n>] [--permission-mode dontAsk] [--context big|small] [--profile <name>] [--add-plugins a@m,b@m] [--rounds-override <why>] (the prompt is the task brief, inline, or read verbatim from --brief-file; default --permission-mode: dontAsk; bypassPermissions is refused)";
  const rawArgv = process.argv.slice(2);
  // help short-circuit — before parseArgs, before any side effect.
  if (isHelpFlag(rawArgv)) { console.log(usage); process.exit(0); }
  const parsed = parseArgs(rawArgv);
  if (!parsed.ok) { console.error(`spawn-glm: ${parsed.error}`); console.error(usage); process.exit(2); }
  const { task: taskArg, briefFile, cwd, name, branch: branchArg, timeoutMins, permMode: permModeArg, armOnCap, grants, autonomous, carryFrom, context, profile, addPlugins, roundsOverride } = parsed.args;
  // --brief-file's contents BECOME the task. Read here — before
  // any side effect and before every task-consuming consumer below (round
  // guard, window preflight, composeWorkerPrompt) — so a missing/unreadable/
  // empty file is a clean exit-2 usage refusal that leaves no orphan
  // worktree/branch/meta, and the file's brief flows through the EXISTING
  // brief.md + pointer-prompt machinery unchanged.
  let task: string | undefined = taskArg;
  if (briefFile !== undefined) {
    const brief = readBriefFile(briefFile);
    if (!brief.ok) { console.error(`spawn-glm: ${brief.error}`); console.error(usage); process.exit(2); }
    task = brief.task;
  }
  if (!task) { console.error(usage); process.exit(2); }
  // structural forbid, before any side effect. Never a silent
  // downgrade — a caller asking for bypassPermissions gets a clean usage
  // refusal naming why.
  const bypassRefusal = refuseBypassPermissions(permModeArg);
  if (bypassRefusal) { console.error(`spawn-glm: ${bypassRefusal}`); console.error(usage); process.exit(2); }
  const unknownModeRefusal = refuseUnknownPermissionMode(permModeArg);
  if (unknownModeRefusal) { console.error(`spawn-glm: ${unknownModeRefusal}`); console.error(usage); process.exit(2); }
  // dontAsk is the worker-lane DEFAULT (never bypassPermissions,
  // never the settings-inherited "auto" default that let the hang
  // through) — an explicit --permission-mode still overrides for a future
  // narrower need, but omitting the flag no longer means "inherit whatever
  // ~/.claude/settings.json's permissions.defaultMode happens to be".
  const permMode: PermissionMode = permModeArg ?? "dontAsk";
  const absCwd = resolve(cwd);
  // refuse BEFORE any worktree/branch side-effect if this
  // dispatch is not running from the PRIMARY checkout — see
  // detectNonPrimaryCwd above for the incident + detection rationale.
  const nonPrimaryRefusal = refuseNonPrimaryCwd(absCwd);
  if (nonPrimaryRefusal) { console.error(nonPrimaryRefusal); process.exit(2); }
  // refuse a symptom-loop dispatch BEFORE any side effect — at 2
  // reviewed rounds the brief must state the invariant the fix preserves; at 3
  // this cheap lane is refused outright (judgment-tier lane or recorded
  // --rounds-override). round-guard.ts has the incident + fail-open rationale.
  const roundGuard = checkRoundGuard("spawn-glm", { task, branch: branchArg, name, cwd: absCwd, roundsOverride });
  if (roundGuard.refusal) { console.error(roundGuard.refusal); process.exit(2); }
  if (roundGuard.note) console.error(roundGuard.note);
  // validate the profile NAME + overlay ids BEFORE any side effect —
  // an unknown --profile / malformed --add-plugins id is a clean usage refusal
  // (exit 2), never an orphan worktree/branch. `installed: []` keeps this to pure
  // validation: the REAL deny baseline is computed later, in runBody, from the
  // WORKER'S worktree (CR) — that is the cwd claude actually runs in, and its
  // branch-local .claude/settings{,.local}.json can differ from the dispatcher's.
  try { resolveProfileSettings(profile, addPlugins, absCwd, []); }
  catch (e) { console.error(`spawn-glm: ${String((e as any)?.message ?? e)}`); console.error(usage); process.exit(2); }
  // thread --context big|small into buildGlmEnv via GLM_CONTEXT (read by
  // the runSession env path + the preflight buildGlmEnv below). `?? "big"` makes the
  // default explicit so an ambient GLM_CONTEXT in the parent shell can't silently flip
  // an omitted --context (the doc/test intent is "--context absent => big").
  process.env.GLM_CONTEXT = context ?? "big";

  // shared-branch mode (--branch) commits onto a caller-named
  // EXISTING branch under a lock, instead of always minting glm/<slug> fresh.
  // Both modes converge on the same {slug, worktree, branch, warnings} shape
  // below; needsWorktreeAdd is always true for own-branch mode (a fresh
  // worktree+branch is minted every dispatch) — only shared mode may reuse.
  const sharedMode = branchArg !== undefined;
  let slug: string, worktree: string, branch: string, warnings: SettingsConflict[], needsWorktreeAdd: boolean;
  // Narrow on the literal `branchArg !== undefined` (I9) so TS proves branchArg
  // is a string here — no non-null assertion. sharedMode stays for the other
  // shared-vs-own reads below (it is exactly this predicate).
  if (branchArg !== undefined) {
    const plan = planSharedSpawn(absCwd, branchArg, {
      isHimmelCheckout, settingsConflicts: findSettingsConflicts, home: homedir(),
      branchExists: (b) => gitBranchExists(absCwd, b),
      worktreeOf: (b) => gitWorktreeOf(absCwd, b),
      isDirty: (p) => gitIsDirty(p),
    });
    if (!plan.ok) { console.error(plan.reason); process.exit(2); }
    ({ slug, worktree, branch, warnings, needsWorktreeAdd } = plan);
  } else {
    const plan = planSpawn(absCwd, name, { isHimmelCheckout, settingsConflicts: findSettingsConflicts, home: homedir() });
    if (!plan.ok) { console.error(plan.reason); process.exit(2); }
    ({ slug, worktree, branch, warnings } = plan);
    needsWorktreeAdd = true;
  }
  for (const w of warnings) console.error(`spawn-glm: WARNING — settings model key present (${formatConflict(w)}); explicit --model flag takes precedence, verify via the transcript model id.`);

  // Preflight the ZAI key BEFORE any side effect (before worktree add): a
  // missing key must be a clean refusal (exit 2), not a failure AFTER the
  // worktree+branch+running-meta exist (orphans + a stuck "running" meta).
  // runSession re-derives the env internally — the double build is cheap.
  try { buildGlmEnv(REPO_ROOT); } catch (e) { console.error(`spawn-glm: ${String((e as any)?.message ?? e)}`); process.exit(2); }
  const preflightUsage = await fetchGlmUsage(readZaiKey(REPO_ROOT).key);
  // WS9: observe the preflight GLM reading; passive, reuses the
  // existing fetch. GUARDED — this runs BEFORE the worktree exists, so an
  // unguarded ledger-write throw would propagate to main().catch and ABORT the
  // dispatch; the passive layer must never block a dispatch (mirrors the
  // cap-time site's try/catch and the bash twin's `|| true`).
  try { appendQuotaGauge(buildGlmRow(preflightUsage, Date.now())); } catch (e) { console.error(`spawn-glm: quota-gauge preflight append failed (non-fatal): ${String((e as any)?.message ?? e)}`); }
  const warn = formatUsageWarn(preflightUsage, parseWarnPct(process.env.GLM_USAGE_WARN_PCT));
  if (warn) console.error(warn);

  // Per-model window preflight: refuse a brief that cannot fit the
  // resolved GLM window BEFORE any side effect (before the worktree exists), so a
  // refusal leaves NO orphan worktree/branch/meta. sessionDir is computed here
  // (no mkdir yet — the real mkdir stays below) because composeWorkerPrompt needs
  // it to mint the outbox/context paths; the same sessionDir feeds both the brief
  // composition and the later mkdir. Window derives from the same context
  // resolution main() already applied (context ?? "big"), via glmContextPreset.
  const sessionDir = join(glmSessionRoot(), `glm-${slug}-${mintSpawnStamp()}`);
  const briefText = composeWorkerPrompt(task, sessionDir, branch, { shared: sharedMode });
  const { window: windowTokens } = glmContextPreset(context ?? "big");
  const overheadChars = measureOverheadChars(absCwd, homedir());
  const pre = preflightWindowCheck({ briefChars: briefText.length, overheadChars, windowTokens });
  if (!pre.ok) { console.error(pre.reason); process.exit(2); }

  // GLM guard (spec D2) BEFORE any worktree/branch mutation (#848): a refusal
  // must leave NO orphan worktree/branch behind. The
  // path-under-list checks resolve worktree as a string, so a PHI- or
  // egress-denied dispatch path refuses here, pre-creation.
  const guard = checkPhiEgressGuards(worktree);
  if (!guard.ok) { console.error(guard.reason); process.exit(3); }

  const g = (args: string[]) => { const r = Bun.spawnSync(["git", "-C", absCwd, ...args], { stdout: "pipe", stderr: "pipe" }); if (r.exitCode !== 0) throw new Error(`git ${args[0]} failed: ${r.stderr.toString()}`); };

  // The run body (mkdir sessionDir through executeRun) is IDENTICAL between
  // own-branch and shared modes; only the surrounding worktree
  // creation/mutation + lock ownership differ, below.
  // onSetupFail runs ONLY if the profile resolve below throws —
  // i.e. before ANY of the worker's state exists. The own-branch caller passes a
  // teardown; shared mode passes nothing (runSharedDispatch calls runBody()).
  // the worker branch's tip BEFORE the worker runs (own-branch:
  // the cut point; shared: the pre-existing tip), the base for `commits:`.
  let baseSha: string | undefined;
  const runBody = async (onSetupFail?: () => void): Promise<number> => {
    // runBody is the one seam that covers BOTH modes after the
    // branch exists and BEFORE the worker launches (own-branch: minted just
    // above; shared: gitAdd ran inside runSharedDispatch). Warn-only — a
    // legitimately large branch still dispatches; the warning names the
    // dominating path + share so the next context-window death is attributable.
    const hugeDiff = checkHugeDiff("spawn-glm", { cwd: worktree, branch });
    if (hugeDiff.note) console.error(hugeDiff.note);
    // resolve the profile FIRST — before meta.json is written.
    // resolveProfileSettings throws on an unreadable/malformed settings layer, and
    // it sits OUTSIDE executeRun's failure-transition guard; if it ran after the
    // "running" write, a throw would exit leaving meta stuck at running — fleet
    // control would report a phantom worker and await-glm-worker.sh would block to
    // its deadline. Resolving here keeps the "meta.json ALWAYS leaves running"
    // invariant: nothing has been written yet, so a throw simply aborts the
    // dispatch. Uses the WORKTREE (the cwd the worker runs in), which exists by now.
    let settings: string;
    try {
      // the permission-hardening overlay is NEVER optional (unlike
      // the plugin profile, whose "operator" sentinel means no injection) — it
      // always merges in, so `--settings` is now unconditionally passed.
      settings = composeWorkerSettings(resolveProfileSettings(profile, addPlugins, worktree), worktree, sessionDir);
    } catch (e) {
      // the resolve NEEDS the worktree cwd (branch-local settings
      // layers), so it necessarily runs after `worktree add` — which is why a
      // throw here would otherwise strand the worktree+branch we just minted.
      // Undo them, then rethrow the ORIGINAL error unchanged.
      onSetupFail?.();
      throw e;
    }
    mkdirSync(sessionDir, { recursive: true });
    mintGlmOutboxHelper(sessionDir);
    // GLM_SESSION_DIR (spec D5): the deny hook (running inside the worker child)
    // reads ${GLM_SESSION_DIR}/grants.jsonl. sessionEnv('glm') spreads process.env
    // into the child, so setting it here propagates; unset => hook skips grants.
    process.env.GLM_SESSION_DIR = sessionDir;
    // Pre-seed operator/parent grants into the session ledger (escalation channel,
    // spec D8): classify each grant's shape and, under autonomous authority, refuse
    // a write-shaped grant — recording a pending operator escalation instead of a
    // grant. accumulated feeds nextGrantId so repeated --grant flags get distinct
    // ids (g1, g2, …) rather than all colliding on g1 against the empty file.
    const autonomousEff = autonomous || !!process.env.HIMMEL_AFK || (legacyNamesOn() && !!process.env.HIMMEL_OVERNIGHT);
    const grantsPath = join(sessionDir, "grants.jsonl");
    const seedOutbox = join(sessionDir, "outbox.jsonl");
    const accumulated: string[] = [];
    // carry the capped session's still-valid grants forward
    // (absolute expires_at + remaining budget) BEFORE the --grant loop, so
    // nextGrantId continues past the carried ids. Shape-split (reads seed, autonomous
    // writes re-escalate), fail-open, and observability all live in applyCarryFrom.
    if (carryFrom) {
      const { grantLines, escalationLines, summary } = applyCarryFrom(carryFrom, autonomousEff, accumulated, new Date());
      for (const line of grantLines) { appendFileSync(grantsPath, line + "\n"); accumulated.push(line); }
      for (const esc of escalationLines) appendFileSync(seedOutbox, esc + "\n");
      console.error(`spawn-glm: ${summary}`);
    }
    for (const spec of grants) {
      const shape = classifyShape(spec.arm, spec.pattern);
      if (authorityGate(shape, autonomousEff).action === "grant") {
        const line = composeGrantLine(spec, { capability: spec.pattern, grantId: nextGrantId(accumulated), grantedBy: "parent:spawn-glm", now: new Date() });
        appendFileSync(grantsPath, line + "\n");
        accumulated.push(line);
      } else {
        appendFileSync(seedOutbox, composeEscalationForRefusedGrant({ capability: spec.pattern, arm: spec.arm, reason: "autonomous refuses write grant — operator adjudication required", step: "pre-seed", now: new Date() }) + "\n");
        console.error(`spawn-glm: --grant ${spec.arm} is write-shaped and refused under autonomous authority; recorded a pending operator escalation.`);
      }
    }
    const metaPath = join(sessionDir, "meta.json");
    const started_at = new Date().toISOString();
    // Task 1.2 (Step 2b): record the worktree path and branch.
    // The liveness check in await-glm-worker.sh can only read meta.json, and
    // without these two fields its only staleness signal is last_output_at --
    // which reads 0 for a worker that commits early and leaves a clean tree,
    // so the BETTER-BEHAVED the worker, the more it looks STALLED. Both extra
    // signals (newest worktree mtime, branch HEAD commit time) are unreachable
    // until they are written here.
    // `worktree` records the DISPATCH CWD (kept as-is for
    // existing readers); worker_worktree is the worker's OWN minted/reused
    // worktree — the correct root for the liveness mtime walk. Walking the
    // dispatch CWD sweeps every sibling worktree in the checkout, so a
    // SIBLING worker's writes read as THIS worker's liveness (a false ALIVE,
    // the dangerous direction) — and costs a full-checkout find each verge.
    const baseMeta = {
      status: "running", pid: 0, started_at, lane: "glm", task_name: slug,
      worktree: absCwd, branch, worker_worktree: worktree,
    };
    // shared_branch marks a shared-mode run in meta.json so a
    // reader can tell it apart from an own-branch run at a glance. Typed
    // construction (I8): a ternary builds the object with-or-without the field,
    // no Record<string, unknown> widening + conditional mutation.
    const runningMeta = sharedMode ? { ...baseMeta, shared_branch: branch } : baseMeta;
    writeFileSync(metaPath, JSON.stringify(runningMeta, null, 2));

    // write the composed brief to <sessionDir>/brief.md and submit a
    // SHORT pointer prompt (not the inlined brief) — the fix for the submit-reject
    // deaths. brief.md lives under glm-sessions/ (outside the repo worktree), the
    // proven-accessible path the worker already reads/writes outbox+context in.
    const briefPath = join(sessionDir, "brief.md");
    writeFileSync(briefPath, briefText);
    const prompt = composePointerPrompt(briefPath);
    if (timeoutMins !== undefined) process.env.RUN_TIMEOUT_MS = String(timeoutMins * 60 * 1000);

    const capGuard: CapGuardDeps = {
      startedAt: new Date(started_at),
      task, cwd: absCwd, slug, branch, timeoutMins, permMode,
      armOnCap, shared: sharedMode,
      // carry the profile + overlay so a capped-run respawn
      // re-dispatches on the SAME lane profile (not the lane-impl default).
      profile, addPlugins,
      // A cap-respawn is a continuation of this dispatch, so it inherits the
      // same recorded round-guard authority instead of deterministically dying.
      roundsOverride,
      fetchUsage: () => fetchGlmUsage(readZaiKey(REPO_ROOT).key),
      arm: (hhmm, snap) => Bun.spawnSync(buildArmArgv(REPO_ROOT, hhmm, snap), { stdout: "inherit", stderr: "inherit", env: buildArmEnv() }).exitCode ?? 1,
    };
    // checkpoint in a FINALLY, not "after executeRun returns".
    // executeRun's outer catch writes failed-meta and RETHROWS, so a thrown
    // runSession — a spawner-side crash mid-run, precisely when uncommitted
    // work is stranded — would otherwise skip the checkpoint entirely. That is
    // the exact hole moving this call out of executeRun was meant to avoid.
    let code: number;
    const head0 = gitCapture(["rev-parse", "HEAD"], worktree);
    baseSha = head0.code === 0 ? head0.stdout.trim() : undefined;
    try {
      ({ code } = await executeRun({ runSession, prompt, worktree, permMode, sessionDir, metaPath, runningMeta, capGuard, settings }));
    } finally {
      const cp = checkpointWorktree(worktree, slug, sessionDir, CHECKPOINT_GLOBS, gitCapture);
      mergeMetaCheckpoint(metaPath, { ...cp, at: new Date().toISOString() });
      if (cp.committed) {
        // Harvest ergonomics: the recovery line, printed every time. A ref
        // nobody knows how to read is the same as no checkpoint.
        console.error(`spawn-glm: checkpointed uncommitted work to ${cp.ref} (UNREVIEWED — not a commit, not pushable)`);
        console.error(`spawn-glm: recover with: git -C ${worktree} restore --source ${cp.ref} -- .`);
      } else {
        console.error(`spawn-glm: no checkpoint (${cp.reason})`);
      }
    }
    return code;
  };

  let code: number;
  if (!sharedMode) {
    g(["worktree", "add", worktree, "-b", branch]);
    ensureWorkspaceTrust(worktree);
    // this dispatch MINTED both the worktree and the branch (-b), so
    // it owns them until the worker starts. Teardown is passed ONLY here — shared
    // mode must never tear down a caller-owned worktree/branch.
    code = await runBody(() => teardownMintedWorktree(absCwd, worktree, branch));
  } else {
    // serialize writers on the shared branch (single-writer
    // invariant, CLAUDE.md Subagent policy). runSharedDispatch acquires the
    // lock AFTER guards pass (a refusal above must leave no lock held), BEFORE
    // any worktree mutation, and releases it in a finally on every catchable
    // exit path. rc 11 = already held / any other nonzero = usage/derivation
    // error; both surface as ok:false here and map to exit 4 (a new code,
    // distinct from the existing 1 operational / 2 refusal / 3 D2-guard).
    const lockScript = join(REPO_ROOT, "scripts", "lib", "shared-branch-lock.sh");
    const shared = await runSharedDispatch({ repoDir: absCwd, worktree, branch, needsWorktreeAdd, lockScript, gitAdd: () => g(["worktree", "add", worktree, branch]), runBody });
    if (!shared.ok) { console.error(shared.reason); process.exit(4); }
    code = shared.code;
  }

  console.log(`session-dir: ${sessionDir}`);
  console.log(`transcript-dir: ${transcriptDirFor(worktree)}`);
  console.log(PUSH_PROTECTION_DISCLOSURE);
  for (const line of composeDispatchGitState(worktree, branch, baseSha)) console.log(line);
  console.log(`exit: ${code}`);
  process.exit(code);
}

if (import.meta.main) {
  // registered ONLY for the real CLI process — never on a
  // test import, which must not have a stray SIGTERM exit the test runner.
  // sigtermFinalize() is a no-op unless executeRun has armed a live run.
  process.on("SIGTERM", () => {
    sigtermFinalize();
    process.exit(143);
  });
  main().catch((e) => { console.error(`spawn-glm: ${String(e?.message ?? e)}`); process.exit(1); });
}

// ── cap guard: resume-time helpers ──────────────────────────────
export type CapSource = "monitor-endpoint" | "error-body" | "cycle-floor";
// On-disk meta unions are WIDER than the helpers' return types (CR round —
// types must not lie to meta.json readers): cap_window adds the "generic"
// fallback (base sentinel matched, no GLM classification), cap_source adds
// the long-window no-arm marker.
export type MetaCapWindow = GlmCapWindow | "generic";
export type MetaCapSource = CapSource | "no-arm-long-window";
const TWO_MIN = 120_000, DAY = 24 * 3600_000, FIVE_H = 5 * 3600_000;
// Clamp window [now+2min, now+24h]: arm-resume HH:MM expresses only the next
// future occurrence; 2min mirrors auto-arm-on-cap's registration-latency floor.
// Out-of-range candidates FALL THROUGH to the next source; a past cycle floor
// (capped >5h after start) arms at now+2min.
export function computeResumeAt(p: { now: Date; startedAt: Date; usage: GlmUsage | null; tail?: string }): { resumeAt: Date; capSource: CapSource } {
  const lo = p.now.getTime() + TWO_MIN, hi = p.now.getTime() + DAY;
  const inRange = (t: number) => t >= lo && t <= hi;
  const m = p.usage?.nextResetTime;
  if (typeof m === "number" && inRange(m)) return { resumeAt: new Date(m), capSource: "monitor-endpoint" };
  const b = p.tail?.match(/your limit will reset at ([0-9T:. Z+-]+)/i)?.[1]?.trim();
  if (b) {
    const t = /^\d{12,}$/.test(b) ? Number(b) : Date.parse(b);
    if (Number.isFinite(t) && inRange(t)) return { resumeAt: new Date(t), capSource: "error-body" };
  }
  const floor = p.startedAt.getTime() + FIVE_H;
  return { resumeAt: new Date(Math.min(Math.max(floor, lo), hi)), capSource: "cycle-floor" };
}
export function toArmHHMM(d: Date): string {
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}
// -rN retry suffix (spec D7): a capped run leaves its worktree+branch behind;
// a same-name respawn would refuse on the existing worktree.
export function nextRetrySlug(slug: string): string {
  const m = slug.match(/^(.*)-r(\d+)$/);
  return m ? `${m[1]}-r${Number(m[2]) + 1}` : `${slug}-r1`;
}

// Self-contained cold-start respawn handover (spec (b) 3): the armed session
// may be a fresh cold start — everything needed to re-dispatch is inline.
const shellSingleQuote = (value: string): string => `'${value.replace(/'/g, `'"'"'`)}'`;
// quote only values a shell would split or interpret, so plain values stay byte-identical.
const shellArg = (value: string): string => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(value) ? value : shellSingleQuote(value));
export function composeRespawnHandover(p: { task: string; cwd: string; slug: string; timeoutMins?: number; permMode?: string; sessionDir: string; branch: string; resumeAtIso: string; shared?: boolean; profile?: string; addPlugins?: string[]; roundsOverride?: string }): string {
  const respawnName = nextRetrySlug(p.slug);
  // a shared-mode respawn carries --branch (the caller-named
  // branch, unchanged across retries) instead of --name <slug>-rN — shared
  // mode never mints -rN branches, it keeps writing onto the same one.
  // carry --profile only when it differs from the default, and
  // --add-plugins only when a non-empty overlay was set, so the respawn lands on
  // the same lean profile the original dispatch selected.
  const profileFlag = p.profile && p.profile !== DEFAULT_LANE_PROFILE ? `--profile ${shellArg(p.profile)}` : "";
  const addPluginsFlag = p.addPlugins && p.addPlugins.length ? `--add-plugins ${shellArg(p.addPlugins.join(","))}` : "";
  // A cap is a continuation of the SAME authorized dispatch, not a new round.
  // Preserve the recorded authority and single-quote it so spaces/metacharacters
  // remain data when the markdown command is executed by a shell.
  const roundsOverrideFlag = p.roundsOverride ? `--rounds-override ${shellSingleQuote(p.roundsOverride)}` : "";
  const flags = [`--cwd ${shellArg(p.cwd)}`, p.shared ? `--branch ${shellArg(p.branch)}` : `--name ${shellArg(respawnName)}`, p.timeoutMins !== undefined ? `--timeout-mins ${p.timeoutMins}` : "", p.permMode ? `--permission-mode ${shellArg(p.permMode)}` : "", profileFlag, addPluginsFlag, roundsOverrideFlag, `--carry-from ${shellArg(p.sessionDir)}`].filter(Boolean).join(" ");
  return [
    "---",
    "type: handover",
    "task: respawn a GLM worker capped on the z.ai 5-hour cycle",
    "armed-by: spawn-glm cap guard (HIMMEL-654)",
    `resume_cwd: ${p.cwd}`,
    "---",
    "",
    "# Capped GLM worker — respawn at cycle reset",
    "",
    `A GLM-lane worker hit the z.ai usage cap; a resume was armed for ${p.resumeAtIso}.`,
    "",
    "## Before spending quota",
    "",
    `1. Check whether this work was already validated/merged meanwhile (branch ${p.branch}, capped session dir ${p.sessionDir}) — if merged, just clean up; do NOT re-dispatch.`,
    `2. Inspect the ${p.shared ? "shared" : "capped"} worktree for ${p.branch}: if it holds unpushed commits, re-dispatch with a "continue from the existing branch state on ${p.branch}" preamble; else re-dispatch fresh.`,
    "",
    "## Re-dispatch command",
    "",
    "```",
    `bun scripts/telegram/spawn-glm.ts ${JSON.stringify(p.task)} ${flags}`,
    "```",
  ].join("\n");
}

// ── cap guard: orchestration deps + arm argv builder ────────────
export type CapGuardDeps = {
  startedAt: Date;
  task: string; cwd: string; slug: string; branch: string;
  timeoutMins?: number; permMode?: string;
  armOnCap: boolean;
  // threads shared-branch mode into the respawn handover so a
  // capped shared-mode run re-dispatches with --branch, not a fresh -rN --name.
  shared?: boolean;
  // the lane plugin profile + overlay, carried into the respawn
  // handover so a capped run re-dispatches on the same lean profile.
  profile?: string; addPlugins?: string[];
  // a cap-respawn continues the already-authorized round.
  roundsOverride?: string;
  fetchUsage: () => Promise<GlmUsage | null>;
  arm: (hhmm: string, handoverPath: string) => number;   // rc of arm-resume.sh
  now?: () => Date;
};
// argv builder for the real arm invoker — pure so the flag contract
// (--dedup-any --time <HH:MM> --handover <path>) is unit-asserted.
export function buildArmArgv(repoRoot: string, hhmm: string, handoverPath: string): string[] {
  return [BASH_BIN, join(repoRoot, "scripts", "handover", "arm-resume.sh"), "--dedup-any", "--time", hhmm, "--handover", handoverPath];
}

// Child env for the auto-arm invoker: ARM_RESUME_SAFETY_ARM=1 marks this as an
// automated machine-wide SAFETY arm (the cap-respawn watchdog) so arm-resume's
// long-gap guard exempts it — a multi-hour cap-reset park is the
// safety arm's whole point, not an orchestrator's silent far default. Pure so
// the env contract is unit-asserted (the --dedup-any argv stays dedup-scope
// only and does NOT bypass the guard). Spreads process.env so a runtime
// override + the live PATH/.env-sourced vars still reach the child (Bun's
// default env is a process-START snapshot, not live process.env — same reason
// ensureWorkspaceTrust passes env: process.env).
export function buildArmEnv(): NodeJS.ProcessEnv {
  return { ...process.env, ARM_RESUME_SAFETY_ARM: "1" };
}

// Preflight warn (spec (c)): warn-only — a heuristic-threshold refusal would
// strand work on a miscount (D4). Null = visible-invisible line.
export function formatUsageWarn(u: GlmUsage | null, warnPct: number): string | null {
  if (u === null) return "spawn-glm: usage invisible (monitor endpoint unavailable)";
  if (u.percentage < warnPct) return null;
  return `spawn-glm: WARNING — GLM 5h cycle ${u.percentage}% used${u.level ? ` (${u.level} tier)` : ""}; resets ${toArmHHMM(new Date(u.nextResetTime))} local`;
}
// env-knob coercion, pure + tested (main() wiring must not hide coercion rules)
export function parseWarnPct(raw: string | undefined): number {
  const s = raw?.trim(); // whitespace-only must not coerce to 0 (= warn-always)
  const n = Number(s);
  return s !== undefined && s !== "" && Number.isFinite(n) && n >= 0 && n <= 100 ? n : 80;
}
