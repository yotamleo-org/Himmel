#!/usr/bin/env bash
# gcp-runner-startup.sh -- the GCE startup script of one ephemeral CI runner VM.
# gcp-runners.sh up hands it to the VM as metadata; it runs once
# as root at boot: install the tools ci.yml's github-hosted-gated steps would
# install, start ONE just-in-time (always ephemeral) runner labelled gcp from the
# per-VM `jit-config` metadata, run one job as the non-root, sudo-less `runner`
# user behind the root-owned fork guard (`job-started-hook`, wired as
# ACTIONS_RUNNER_HOOK_JOB_STARTED), then power off. The VM holds no PAT, no
# registration token and no shared secret: the JIT config is good for this one runner.
#
# ponytail: the runner tarball is the latest release without a checksum pin,
# upgrade by pinning version + sha256 in gcp-runners.sh metadata (hardening review follow-up).
set -uo pipefail

md() { curl -fsS -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }

# Whatever happens below, the VM must not idle on spot billing.
trap 'poweroff' EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || exit 1
apt-get install -y -qq at bubblewrap socat ffmpeg git jq curl unzip shellcheck python3-pip nodejs npm || exit 1
systemctl enable --now atd || true
sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 || true
python3 -m pip install --break-system-packages --disable-pip-version-check pre-commit==4.7.0 || exit 1

id runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash runner
tag="$(curl -fsS https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)" || exit 1
ver="${tag#v}"
mkdir -p /opt/runner
curl -fsSL "https://github.com/actions/runner/releases/download/${tag}/actions-runner-linux-x64-${ver}.tar.gz" | tar -xz -C /opt/runner || exit 1
/opt/runner/bin/installdependencies.sh || exit 1
chown -R runner:runner /opt/runner

jit="$(md jit-config)" || exit 1
repo="$(md runner-repo)" || exit 1
install -d -m 755 -o root -g root /usr/local/lib/himmel
md job-started-hook > /usr/local/lib/himmel/job-started-hook.sh || exit 1
chown root:root /usr/local/lib/himmel/job-started-hook.sh
chmod 755 /usr/local/lib/himmel/job-started-hook.sh
printf 'ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/himmel/job-started-hook.sh\nHIMMEL_CI_RUNNER_REPO=%s\n' "$repo" > /opt/runner/.env
chown runner:runner /opt/runner/.env
su runner -c "cd /opt/runner && ./run.sh --jitconfig '$jit'"
