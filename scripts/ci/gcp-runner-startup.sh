#!/usr/bin/env bash
# gcp-runner-startup.sh -- the GCE startup script of one ephemeral CI runner VM.
# gcp-runners.sh up hands it to the VM as metadata; it runs once
# as root at boot: install the tools ci.yml's github-hosted-gated steps would
# install, register ONE --ephemeral runner labelled gcp with the short-lived
# registration token from the `reg-token` metadata file, run one job as the
# non-root, sudo-less `runner` user, then power off. The VM holds no PAT and no
# long-lived secret: the token can only register runners and expires in 1 h.
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

token="$(md reg-token)" || exit 1
url="$(md runner-url)" || exit 1
su runner -c "cd /opt/runner && ./config.sh --unattended --ephemeral --url '$url' --token '$token' --labels gcp --name \"\$(hostname)\" --replace" || exit 1
su runner -c "cd /opt/runner && ./run.sh"
