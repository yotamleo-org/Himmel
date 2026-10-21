# .github/ci-image/Dockerfile -- the CI tooling image.
# Built and pushed to ghcr.io/yotamleo-org/himmel-ci by .github/workflows/ci-image.yml
# when this directory changes (plus a weekly rebuild that refreshes the apt packages).
# Every pin below mirrors ci.yml / .bun-version / .pre-commit-config.yaml;
# scripts/ci/test-ci-image.sh fails when one drifts.
# The base is pinned by digest; Dependabot's docker entry bumps it.
FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_VERSION=22.23.3
ARG NODE_SHA256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
ARG BUN_VERSION=1.4.3
ARG BUN_SHA256=3e730528d89775f03f87f05c06787c4df4099d0a37f3f252e7b829cb23816e18
ARG GITLEAKS_VERSION=8.30.1
ARG GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
ARG SHFMT_VERSION=3.14.1
ARG SHFMT_SHA256=76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf
ARG UV_VERSION=0.13.4
ARG UV_SHA256=2b428396f12572d4429cf210ca234dd599a33b3af0958a4d5ed569d63e3f344f

# at/bubblewrap/socat: arm-resume + sandbox suites; ffmpeg 6.1: obsidian-triage HLS
# suite; sudo: ci.yml steps call it; gh: the ticket asks for it. The second line is
# the base tooling a GitHub-hosted runner carries and the suites call (ps, pgrep,
# rsync, xxd, sqlite3, column, ...); the minimal ubuntu base has none of it. The third
# line is what the suites need beyond that: bison + gcc + libc6-dev build the bwk awk,
# cron gives crontab, python-is-python3 the bare `python` the obsidian-triage suites
# call, python3-yaml the PyYAML a suite imports, zsh runs the escape-corpus zsh shapes.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      at bubblewrap ca-certificates curl ffmpeg=7:6.1.* gh git jq \
      python3-pip shellcheck socat sudo unzip xz-utils \
      bsdextrautils expect file gawk iproute2 iputils-ping less lsof make \
      netcat-openbsd openssh-client patch procps psmisc rsync sqlite3 tmux tree \
      wget xxd zip zstd \
      bison cron gcc libc6-dev python-is-python3 python3-yaml zsh=5.9-* \
 && rm -rf /var/lib/apt/lists/*

# runner: uid/gid 1001 like the GitHub-hosted runner user, so a job that runs as it
# owns the checkout the host runner created, and the suites do not run as root
# (a root uid reads mode-000 files). Passwordless sudo, as on the hosted runner.
RUN groupadd -g 1001 runner \
 && useradd -m -u 1001 -g 1001 -s /bin/bash runner \
 && printf 'runner ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/runner \
 && chmod 0440 /etc/sudoers.d/runner

# node: one exact release, sha256-verified against the hash pinned above.
RUN tgz="node-v${NODE_VERSION}-linux-x64.tar.xz" \
 && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/$tgz" \
 && echo "${NODE_SHA256}  $tgz" | sha256sum -c - \
 && tar -xJf "$tgz" -C /usr/local --strip-components=1 \
 && rm -f "$tgz" \
 && node --version | grep -qx "v${NODE_VERSION}"

RUN curl -fsSL -o /tmp/bun.zip "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip" \
 && echo "${BUN_SHA256}  /tmp/bun.zip" | sha256sum -c - \
 && unzip -q /tmp/bun.zip -d /tmp/bun \
 && install -m 755 /tmp/bun/bun-linux-x64/bun /usr/local/bin/bun \
 && rm -rf /tmp/bun /tmp/bun.zip

RUN curl -fsSL -o /tmp/gitleaks.tgz "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
 && echo "${GITLEAKS_SHA256}  /tmp/gitleaks.tgz" | sha256sum -c - \
 && tar -xzf /tmp/gitleaks.tgz -C /usr/local/bin gitleaks \
 && rm -f /tmp/gitleaks.tgz

# shfmt: the bash-ast engine the write-fence hooks parse with.
RUN curl -fsSL -o /tmp/shfmt "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64" \
 && echo "${SHFMT_SHA256}  /tmp/shfmt" | sha256sum -c - \
 && install -m 755 /tmp/shfmt /usr/local/bin/shfmt \
 && rm -f /tmp/shfmt

# uv: check-uv-lock.sh and the graphify install path.
RUN curl -fsSL -o /tmp/uv.tgz "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
 && echo "${UV_SHA256}  /tmp/uv.tgz" | sha256sum -c - \
 && tar -xzf /tmp/uv.tgz -C /usr/local/bin --strip-components=1 uv-x86_64-unknown-linux-gnu/uv uv-x86_64-unknown-linux-gnu/uvx \
 && rm -f /tmp/uv.tgz

# pre-commit and the shellcheck rev the pre-commit hook pins; pip puts shellcheck in
# /usr/local/bin, ahead of the apt 0.9.0 in /usr/bin.
# ponytail: top-level pins only, no --require-hashes (pre-commit's transitive closure
# floats); upgrade path: a hashed requirements.txt beside this file.
RUN python3 -m pip install --no-cache-dir --break-system-packages --ignore-installed \
      pre-commit==4.7.0 shellcheck-py==0.11.0.1
