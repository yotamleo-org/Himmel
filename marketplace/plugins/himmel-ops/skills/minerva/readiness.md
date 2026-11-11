# Critic-input readiness (optional spec-gate mode)

Before a paid spec or plan critic round, the caller can ask the spec gate to check
that the round gets the right inputs: the canonical spec, the requested plan, the
current source head, and every earlier finding with its disposition.

```text
bash marketplace/plugins/himmel-ops/scripts/minerva-spec-gate.sh SPEC --readiness MANIFEST --source-head SHA
```

`SPEC` is always the canonical design spec, also for a plan critic. `SHA` is the
full source-repo HEAD the caller verified. The mode is off by default: with only
`SPEC` the gate prints its old text and keeps its old exits (0 ok, 1 refused,
2 spec not found).

## Manifest

```text
{schema:1, critic_kind:"spec"|"plan", round:<positive integer>,
 artifact:{path,sha256}, companion:{path,sha256}|null, source_head,
 estimate:{path,sha256}, finding_intake:{path,sha256},
 previous_verdicts:[{path,sha256}], previous_findings:[{finding_id,verdict_sha256}],
 dispositions:[{finding_id,state:"fixed"|"accepted"|"deferred",evidence_path}],
 unresolved_rulings:[id]}
```

- A relative path resolves against the manifest's directory.
- `critic_kind:"spec"`: the artifact is SPEC and the companion is `null`, so a spec
  round can be ready before any plan exists.
- `critic_kind:"plan"`: the artifact is the requested plan, distinct from SPEC, and
  the companion is SPEC.
- `estimate` is the passing `Estimate record:` that SPEC itself names.
- `finding_intake` is the bundle that `critic-findings.py bundle` wrote over exactly
  `previous_verdicts`. An explicit empty bundle is how a first round, or a round
  after CLEAN priors, says "no earlier findings"; a missing index is never read as zero.
- `dispositions` covers every validated earlier finding, no more and no fewer.

**Evidence root.** Every path must resolve beneath the directory that holds SPEC.
One exception: a plan-kind artifact may sit in the literal sibling `specs/plans/`
when SPEC sits in `specs/design/` or `specs/designs/` of the same bucket, and
neither that directory nor the plan is a symlink. Any other escape, symlinked
escape or other bucket is refused.

## Order of checks

1. Flags, manifest JSON and field types: exit 2, `invalid`.
2. The whole old gate (SPEC exists, Estimate record, Alternatives, Definition of
   done): exit 3, `estimate-refused`. The old gate's stderr is kept.
3. Kind, path and evidence-root bindings: exit 2, `invalid`.
4. Stale or missing inputs, exit 3: `stale-source` (manifest head is not `SHA`),
   `stale-artifact` (artifact, companion or estimate missing or hash changed),
   `intake-incomplete` (bundle missing or changed), `disposition-mismatch`
   (evidence file missing), `unresolved-ruling` (a listed ruling is still open).
5. The Judge delegate, `python3 <R>/scripts/handover/chief-kit/critic-findings.py
   validate-bundle BUNDLE --spec SPEC --previous-verdicts <private temp>/PREVIOUS.json`.
   Its exit 2 becomes `intake-invalid` (exit 2) and any other refusal, including
   `legacy-provenance-missing` for a prose-only prior, becomes `intake-incomplete`
   (exit 3). Then `previous_findings` must equal the validated bundle
   (`intake-incomplete`) and the dispositions must match its finding IDs
   (`disposition-mismatch`).

`<R>` is `HIMMEL_REPO` when it is absolute and holds `scripts/lib/initiative-workers.sh`;
otherwise the nearest ancestor of the gate script itself that holds that marker. The
gate never looks in the cwd, PATH, the plugin cache or SPEC's repository. No anchor,
or a delegate that is missing or resolves outside `<R>`, is `intake-incomplete` (exit 3).

## Receipt

Every handled exit prints one JSON line on stdout:

```text
{schema:1, kind:"critic-readiness", state:"ready"|"refused", critic_kind, round,
 manifest_sha256, source_head, artifact, companion, estimate,
 finding_intake_sha256, reasons:[]}
```

A ready receipt has `reasons:[]` and no null field, except `companion`, which is
`null` exactly for a spec round. A refused receipt carries one reason and keeps every
key, with `null` for what was not established.

**Ready is not authorization.** The receipt says the inputs are complete and
current. It grants no round, model, spend, review clearance or approval; `round`
only echoes the manifest. Round caps, model choice and the decision to dispatch stay
with their existing owners.
