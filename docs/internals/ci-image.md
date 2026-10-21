# CI image — prebuilt tooling (HIMMEL-2872)

`ghcr.io/yotamleo-org/himmel-ci` carries the tools the Linux CI jobs install per run
today, so a job starts from a ready environment that only changes when we change it.

- **Source:** `.github/ci-image/Dockerfile` (Ubuntu 24.04, base pinned by `@sha256:` digest;
  Dependabot's `docker` entry bumps that digest weekly, never the release).
- **Build:** `.github/workflows/ci-image.yml` builds, smokes and pushes `:<sha>-<run number>-<attempt>` (immutable per run) and
  `:latest` on a push to main that touches `.github/ci-image/**`, weekly (Mon 04:17 UTC,
  fresh apt packages) and on `workflow_dispatch`. It never runs on `pull_request`. The Push
  step writes the pushed `@sha256:` digest to the run summary.
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
- **One-time step:** after the first push, set the `himmel-ci` package visibility to
  public (GHCR defaults to private) so a job can pull it without a token.

## Contents

at, bubblewrap, socat, ffmpeg 6.1, gh, git, jq, curl, sudo, unzip, python3-pip, apt
shellcheck 0.9.0; the hosted-runner base tools the suites call (procps, psmisc, rsync, xxd,
sqlite3, bsdextrautils, file, gawk, lsof, make, netcat, iproute2, ping, ssh client, patch,
tmux, expect, tree, wget, zip, zstd, less); the tools whose absence fails or SKIPs a suite
row (bison, gcc and libc6-dev for the bwk awk build, cron, python-is-python3 for a bare
`python`, python3-yaml, zsh 5.9, shfmt and uv, the last
two pinned + sha256); node (one exact nodejs.org release, sha256
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

## Not switched yet

`ci.yml` is untouched (other legs hold it). Adopting the image means, in `ci.yml`:

- `shell-unit-shard` (job at line 1099): add `container: ghcr.io/yotamleo-org/himmel-ci@sha256:<digest>`
  (the digest from the build's run summary; a tag can be repointed)
  to the job, and delete these steps for the Linux legs: `Record runner image` /
  `Cache apt debs (at/atd)` / `Install + enable at/atd` (1178-1203), `Allow unprivileged
  user namespaces` (1204; needs `options: --security-opt seccomp=unconfined` or the
  host sysctl, since a container cannot set it), `oven-sh/setup-bun` (1214), the ffmpeg
  record/cache/install steps (1232-1248), `Put pinned gitleaks on PATH` (1262) and
  `Install pre-commit` (1278). Keep `Install obsidian-triage tool deps` (1224): it installs
  repo-versioned deps, not tooling. Add `service atd start || atd` as the first step: a
  container has no systemd, so `systemctl enable --now atd` is gone.
- `lint`, `claude-startup`, `lanes-and-trust-suites`, `node-suites`, `security-scan`:
  drop their `setup-node` / `setup-bun` / `pip install pre-commit` / `apt-install.sh` steps
  the same way, and pin the digest in each `container:`.
- The self-hosted `himmel-vm` and `gcp` legs run the job on the host, not in a container;
  gate `container:` on the hosted leg (an expression that yields no container for them).

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
