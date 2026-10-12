# shellcheck shell=bash
# sourced-lib
# RED: shebang-less, invokes git, and carries a bare `# sourced-lib` marker
# with NO reason. The marker must say who owns the scrub:
# `# sourced-lib: <reason>`.
git -C "$1" rev-parse --git-common-dir
