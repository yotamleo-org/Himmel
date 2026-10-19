# .github/ci-image/Dockerfile -- the CI tooling image.
# Built and pushed to ghcr.io/yotamleo/himmel-ci by .github/workflows/ci-image.yml
# when this directory changes (plus a weekly rebuild for base-image updates).
# Every pin below mirrors ci.yml / .bun-version / .pre-commit-config.yaml;
# scripts/ci/test-ci-image.sh fails when one drifts.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_MAJOR=22
ARG BUN_VERSION=1.4.3
ARG BUN_SHA256=3e730528d89775f03f87f05c06787c4df4099d0a37f3f252e7b829cb23816e18
ARG GITLEAKS_VERSION=8.30.1
ARG GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb

# at/bubblewrap/socat: arm-resume + sandbox suites; ffmpeg 6.1: obsidian-triage HLS
# suite; sudo: ci.yml steps call it; gh: the ticket asks for it.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      at bubblewrap ca-certificates curl ffmpeg=7:6.1.* gh git jq \
      python3-pip shellcheck socat sudo unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

# node: the newest NODE_MAJOR release, sha256-verified against nodejs.org's own list.
RUN base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x" \
 && tgz="$(curl -fsSL "$base/SHASUMS256.txt" | awk '/linux-x64\.tar\.xz$/ {print $2; exit}')" \
 && curl -fsSLO "$base/$tgz" \
 && curl -fsSL "$base/SHASUMS256.txt" | grep " $tgz\$" | sha256sum -c - \
 && tar -xJf "$tgz" -C /usr/local --strip-components=1 \
 && rm -f "$tgz" \
 && node --version | grep -q "^v${NODE_MAJOR}\."

RUN curl -fsSL -o /tmp/bun.zip "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip" \
 && echo "${BUN_SHA256}  /tmp/bun.zip" | sha256sum -c - \
 && unzip -q /tmp/bun.zip -d /tmp/bun \
 && install -m 755 /tmp/bun/bun-linux-x64/bun /usr/local/bin/bun \
 && rm -rf /tmp/bun /tmp/bun.zip

RUN curl -fsSL -o /tmp/gitleaks.tgz "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
 && echo "${GITLEAKS_SHA256}  /tmp/gitleaks.tgz" | sha256sum -c - \
 && tar -xzf /tmp/gitleaks.tgz -C /usr/local/bin gitleaks \
 && rm -f /tmp/gitleaks.tgz

# pre-commit and the shellcheck rev the pre-commit hook pins; pip puts shellcheck in
# /usr/local/bin, ahead of the apt 0.9.0 in /usr/bin.
RUN python3 -m pip install --no-cache-dir --break-system-packages --ignore-installed \
      pre-commit==4.7.0 shellcheck-py==0.11.0.1
