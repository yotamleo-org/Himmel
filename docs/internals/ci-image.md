# CI image — prebuilt tooling (HIMMEL-2872)

`ghcr.io/yotamleo/himmel-ci` carries the tools the Linux CI jobs install per run
today, so a job starts from a ready environment that only changes when we change it.

- **Source:** `.github/ci-image/Dockerfile` (Ubuntu 24.04).
- **Build:** `.github/workflows/ci-image.yml` builds, smokes and pushes `:<sha>` and
  `:latest` on a push to main that touches `.github/ci-image/**`, weekly (Mon 04:17 UTC,
  base-image updates) and on `workflow_dispatch`. It never runs on `pull_request`.
- **Drift check:** `scripts/ci/test-ci-image.sh` reads the apt packages, ffmpeg, bun,
  pre-commit, node, gitleaks and shellcheck-py pins live from `ci.yml`, `.bun-version`,
  `.pre-commit-config.yaml` and `gcp-runner-startup.sh` and fails when the Dockerfile
  lacks one.
- **One-time step:** after the first push, set the `himmel-ci` package visibility to
  public (GHCR defaults to private) so a job can pull it without a token.

## Contents

at, bubblewrap, socat, ffmpeg 6.1, gh, git, jq, curl, sudo, unzip, python3-pip, apt
shellcheck 0.9.0; node 22 (nodejs.org, sha256-checked), bun (pinned to `.bun-version`),
gitleaks (pinned + sha256), pre-commit 4.7.0, shellcheck-py 0.11.0.1 first on PATH.

## Not switched yet

`ci.yml` is untouched (other legs hold it). Adopting the image means, in `ci.yml`:

- `shell-unit-shard` (job at line 1099): add `container: ghcr.io/yotamleo/himmel-ci:<sha tag>`
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
  the same way, and pin the tag in each `container:`.
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
