# Handover token grammar

Handover docs quote tokens on purpose: release tokens, RETASK and judge
nonces, commit shas, sha256 digests. gitleaks' `generic-api-key` rule flags
them on entropy. The luna vault's pre-commit then refuses the doc and the
autosync commit stalls. Every site that mints such a token emits ONE grammar.
One anchored rule in the vault template's `.gitleaks.toml` allowlists it.

## The rule

```
^(?:[a-z0-9]+(?:-[a-z0-9]+)*-pid[0-9]+|[A-Z]{1,3}-(?:[A-Za-z]{1,4}[0-9]{1,5}[A-Za-z]{0,2}|[A-Z]{2,8}-[0-9]{1,6})(?:_[a-z]{1,8})?-[0-9a-f]{4,16}|[0-9a-f]{40}|[0-9a-f]{64})[.,;:)]?$
```

The rule has four alternatives:

| Alternative | Example |
|---|---|
| `<host>-pid<N>` | `cachyos-x8664-pid2124755` |
| `<letters>-<label>-<hex>` | `S-N2802-7023775e`, `Z-HIMMEL-4999-26f92f7e` |
| 40 lowercase hex | a git commit sha |
| 64 lowercase hex | a sha256 digest, a GO `mac=` line |

- The host is the lowercased hostname. Each non-alphanumeric run in it is folded to one `-`.
- The letters are one to three upper-case console letters.
- The label is a leg label or a judge qid in one of two low-entropy shapes: up to
  four letters, one to five digits and up to two letters (`N2802`, `N236b`,
  `jX3206m`), or an upper-case ticket key (`HIMMEL-4999`). Either may end in
  `_` and up to eight lower-case letters (`J12_tune`). A random string does not
  fit, so a secret wrapped as `S-<secret>-abcd` is still caught.
- One trailing `.,;:)` is allowed for a token quoted at the end of a sentence.

The rule is anchored, so a secret with a token prefix or suffix is still caught.

## Minting sites

| Site | Token |
|---|---|
| `scripts/handover/queue-lock.sh` (`_ql_default_session`) | release token `<host>-pid<N>` |
| `scripts/handover/console-kit/gen-briefs.py` | leg RETASK nonce `<letters>-<label>-<hex8>` |
| `scripts/handover/console-kit/gen-judge-brief.py` | judge nonce `<letters>-<qid>-<hex8>` |
| fresh-leg recovery and legacy nonces | `V-N236b-1d281f74`, `Y-N204-a68d71` |
| briefs, GO and verdict lines | commit shas, sha256 digests |

## Where the rule lives

- `templates/luna-second-brain/.gitleaks.toml`: the line after the
  `# handover-token grammar` comment. A vault gets it through luna-upgrade,
  never by a hand edit.
- `scripts/luna/vault-stall-cadence.sh` `CLOSED_SHAPES`: one `handover-token`
  row, a verbatim copy. The cadence re-adds the rule to a vault that lost it.
- `scripts/handover/console-kit/bucket-gitleaks.sh`: scans with the vault's
  config. If the vault has none, it uses the template's.
  `append-results.sh` runs this scan on every bullet before it writes it, and
  refuses a finding with exit 7.

## Adding a token shape

A new minting site must emit a token the rule already matches. Add a row for
it to `scripts/handover/console-kit/test-handover-token-grammar.sh`. That
suite mints every site's token, scans a bucket file quoting it with the
template config, and keeps real secret shapes (AWS key, GitHub PAT, generic
api key, grammar-prefixed secrets) failing. It also pins the toml rule,
`CLOSED_SHAPES` and this page to the same text.

Never add a `paths` allowlist for `handovers/`. This gitleaks build lets a
path match alone suppress a finding, so a real secret pasted into a bucket
would pass.
