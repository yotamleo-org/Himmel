#!/usr/bin/env bash
# Exercise pstack's pin, opt-in boundary and runtime prerequisites.
set -uo pipefail
node --test scripts/lanes/tests/pstack-plugin.test.mjs
