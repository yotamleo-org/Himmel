# CI image — prebuilt tooling (HIMMEL-2872)

`ghcr.io/yotamleo-org/himmel-ci` carries the tools the Linux CI jobs install per run
today, so a job starts from a ready environment that only changes when we change it.

- **Source:** `.github/ci-image/Dockerfile` (Ubuntu 24.04, base pinned by `@sha256:` digest;
  Dependabot's `docker` entry bumps that digest weekly, never the release).
- **Build:** `.github/workflows/ci-image.yml` builds, smokes and pushes `:<sha>-<run number>-<attempt>` (immutable per run) and
  `:latest` on a push to main that touches `.github/ci-image/**`, weekly (Mon 04:17 UTC,
  fresh apt packages) and on `workflow_dispatch`. It never runs on `pull_request`. The Push
  step writes the pushed `@sha256:` digest to the run summary.
- **Digest bump:** when the pushed digest differs from the one `ci.yml` names, the
  `digest-bump` job (`contents: read`, `issues: write` only) opens, or refreshes, one issue
  titled `ci-image: bump ci.yml to the rebuilt image digest` carrying the `sed` line for an
  operator PR. The repo lets no workflow open a PR, and `ci.yml` keeps pulling the digest it
  names until that PR merges, so a rebuild never changes CI by itself.
- **Drift check:** `scripts/ci/test-ci-image.sh` reads the apt packages, ffmpeg, bun,
  pre-commit, node, gitleaks and shellcheck-py pins live from `ci.yml`, `.bun-version`,
  `.pre-commit-config.yaml` and `gcp-runner-startup.sh` and fails when the Dockerfile
  lacks one.
- **Who can publish:** the job runs only for `refs/heads/main` of `yotamleo-org/Himmel`, so a
  dispatch from another branch builds nothing. That `if:` is the only branch gate: GHCR
  access is granted per repository, so any workflow run of this repo whose `GITHUB_TOKEN`
  has `packages: write` (a branch writer editing the workflow on their own branch) can push
  a tag, and an environment does not narrow that token. Tags are therefore overwritable by
  any write holder: consumers pin the image by `@sha256:` digest, never by tag.
- **Visibility:** the `himmel-ci` package stays private. Each containerized job pulls it
  with `credentials:` from the job's own `GITHUB_TOKEN` and `permissions: packages: read`.

## Contents

at, bubblewrap, socat, ffmpeg 6.1, gh, git, jq, curl, sudo, unzip, python3-pip, apt
shellcheck 0.9.0; the hosted-runner base tools the suites call (procps, psmisc, rsync, xxd,
sqlite3, bsdextrautils, file, gawk, lsof, make, netcat, iproute2, ping, ssh client, patch,
tmux, expect, tree, wget, zip, zstd, less); the tools whose absence fails or SKIPs a suite
row (bison, gcc and libc6-dev for the bwk awk build, cron, python-is-python3 for a bare
`python`, python3-yaml, zsh 5.9, shfmt and uv, the last
two pinned + sha256); jq 1.8.2 (pinned + sha256, in /usr/local/bin ahead of apt's 1.7,
which cannot compile the bash-ast engine's jq programs); node (one exact nodejs.org release, sha256
pinned in the Dockerfile), bun (pinned to `.bun-version`, sha256), gitleaks (pinned +
sha256), pre-commit 4.7.0, shellcheck-py 0.11.0.1 first on PATH. A `runner` user, uid/gid
1001 like the hosted runner's, with passwordless sudo, so jobs need not run as root.

## Pinning decisions (HIMMEL-6493)

- **Base image:** pinned by digest; Dependabot bumps the digest, release jumps are manual.
- **Node:** an exact `NODE_VERSION` with its `NODE_SHA256` in the Dockerfile, so a
  tampered or re-rolled nodejs.org tarball fails the build; the drift check holds the
  major to `ci.yml`'s. Bumped by hand with the hash from the release's `SHASUMS256.txt`.
- **pip:** exact top-level pins, no `--require-hashes`: hashing needs pre-commit's whole
  transitive closure pinned, which nothing here bumps. Upgrade path: a hashed
  `requirements.txt` beside the Dockerfile.

## How ci.yml uses it

Seven Linux jobs run in the image: `ci-quick`, `lint`, `lanes-and-trust-suites`,
`bun-suites`, `security-scan`, `shell-unit-shard` and `guard-corpus-full`. Each has a
block-form `container:` whose image is

```yaml
image: ${{ !(<fork or dependabot>[ || <self-hosted route>]) && (vars.CI_IMAGE || 'ghcr.io/yotamleo-org/himmel-ci@sha256:<digest>') || '' }}
```

with `credentials:` from `github.actor` / `github.token` (check-no-secrets.sh refuses a
`secrets.*` interpolation), `--init` (without an init, PID 1 is the runner's
`tail -f /dev/null`, which never reaps an orphan, so a killed process group stays
visible as zombies), `--user 1001` (the
image's `runner` user) and `--privileged` where bwrap needs user namespaces (`ci-quick`,
`shell-unit-shard`, `guard-corpus-full`).

- **Host fallback:** an empty image means no container (the runner treats `image: ''` as
  no job container), so the job runs on the host with its old setup steps. Those steps are
  gated `!job.container.id`; the few container-only steps (start `atd`, the image's
  gitleaks and shellcheck pins) are gated `job.container.id`.
- **Who falls back:** a fork PR and a `dependabot[bot]` run. Both get a read-only
  `GITHUB_TOKEN` and no secrets
  ([automatic token authentication](https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication#permissions-for-the-github_token),
  [Dependabot on Actions](https://docs.github.com/en/code-security/dependabot/troubleshooting-dependabot/troubleshooting-dependabot-on-github-actions)),
  so they are not counted on to pull a private package; they run the host path instead of
  a red job. `shell-unit-shard` also falls back on its self-hosted routes
  (`vars.HIMMEL_VM_RUNNER`, `vars.CI_GCP`), which run on the VM itself.
- **Override:** `vars.CI_IMAGE` replaces the default ref for owner runs (never for a fork).
  Only a repo admin can set it, and it may name a tag: an accepted risk, since the same
  admin can edit the workflow.
- **The default ref** is digest-pinned and identical in every job; `check-actions-pinned.sh`
  refuses a tag-pinned `container:` or `services:` image, and
  `scripts/ci/test-ci-container-jobs.sh` checks the shape, evaluates the expression for each
  event, and checks the host-step gating.

## GCP runners

`gcp-runner-startup.sh` could drop its apt line (`at bubblewrap socat ffmpeg git jq curl
unzip shellcheck python3-pip nodejs npm`, keeping `iptables`), the `pip install pre-commit`
and the bun download + sha check, if the job ran in the image: the VM then needs only
docker, the runner tarball and the proxy, and pulls the image through the squid proxy
(`ghcr.io` is already in the `gcp-net.sh` allowlist). The apt install behind the proxy is
the slow, flaky part of VM boot today.

## Measured trial

Baseline, the real run `39211989855` (main, 2026-10-19), per `shell-unit-shard` job, steps
that the image replaces: at/atd 4-15 s, ffmpeg 6-11 s, pre-commit 3-4 s, setup-bun 3 s,
apt cache restore 3 s each: about 20-35 s of setup per shard, 8 shards. `lint` spends 5 s
on pre-commit; `claude-startup` 5 s on bubblewrap/socat.

Not measured: the container side. The station has no docker daemon and the workflow cannot
run before it is on main, so no image pull time exists yet. A multi-hundred-MB pull on a
hosted runner is likely the same order as the 20-35 s it replaces, so on hosted runners the
gain is immunity to apt-mirror outages (HIMMEL-2871), not speed; the speed gain is on the
GCP VMs. The first `ci-image.yml` run after merge gives the build time; compare a trial
`container:` job's "Initialize containers" step against the figures above before switching.
