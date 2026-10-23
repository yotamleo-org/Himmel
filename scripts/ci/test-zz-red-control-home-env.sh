#!/usr/bin/env bash
# RED control for the merged home-canary shard: reads $HOME/.env (the PR 2883 shape)
cat "$HOME/.env" >/dev/null
exit 0
