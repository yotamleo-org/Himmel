#!/usr/bin/env bash
# gcp-runner-startup.sh -- the GCE startup script of one ephemeral CI runner VM.
# gcp-runners.sh up hands it to the VM as metadata; it runs once
# as root at boot: install the tools ci.yml's github-hosted-gated steps would
# install, start ONE just-in-time (always ephemeral) runner labelled gcp from the
# per-VM `jit-config` metadata, run one job as the non-root, sudo-less `runner`
# user behind the root-owned fork guard (`job-started-hook`, wired as
# ACTIONS_RUNNER_HOOK_JOB_STARTED), then power off. The VM holds no PAT, no
# registration token and no shared secret: the JIT config is good for this one runner.
# The subnet denies all egress but tcp:3128 to the squid proxy, so the `proxy-env`
# metadata (gcp-net.sh proxy-env) is exported for apt and written into the runner's
# .env. The JIT config reaches run.sh through ACTIONS_RUNNER_INPUT_JITCONFIG, never
# argv, and an iptables owner-match rule keeps the runner uid off the metadata server.
#
# ponytail: the runner tarball is the latest release without a checksum pin,
# upgrade by pinning version + sha256 in gcp-runners.sh metadata (hardening review follow-up).
set -uo pipefail

md() { curl -fsS -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }

# Whatever happens below, the VM must not idle on spot billing.
trap 'poweroff' EXIT

export DEBIAN_FRONTEND=noninteractive
proxy_env="$(md proxy-env)" || exit 1
while IFS='=' read -r k v; do
    case "$k" in HTTPS_PROXY|HTTP_PROXY|NO_PROXY|https_proxy|http_proxy|no_proxy) export "$k=$v" ;; esac
done <<< "$proxy_env"
# shellcheck disable=SC2154  # exported by the loop above
printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$http_proxy" "$https_proxy" > /etc/apt/apt.conf.d/95ci-proxy
apt-get update -qq || exit 1
apt-get install -y -qq iptables at bubblewrap socat ffmpeg git jq curl unzip shellcheck python3-pip nodejs npm || exit 1
systemctl enable --now atd || true  # t13b-ok: stock at daemon on a throwaway CI VM, not a himmel service
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
[ -s /usr/local/lib/himmel/job-started-hook.sh ] || exit 1
chown root:root /usr/local/lib/himmel/job-started-hook.sh
chmod 755 /usr/local/lib/himmel/job-started-hook.sh
printf 'ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/himmel/job-started-hook.sh\nHIMMEL_CI_RUNNER_REPO=%s\n%s\n' "$repo" "$proxy_env" > /opt/runner/.env || exit 1
chown runner:runner /opt/runner/.env || exit 1
# Everything is read from metadata: the runner uid may not reach it from here on.
iptables -A OUTPUT -d 169.254.169.254 -m owner --uid-owner runner -j REJECT || exit 1
export ACTIONS_RUNNER_INPUT_JITCONFIG="$jit" HOME=/home/runner USER=runner
su runner -p -c "cd /opt/runner && exec ./run.sh"
