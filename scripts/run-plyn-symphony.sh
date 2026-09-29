#!/bin/zsh
set -euo pipefail

root=/Volumes/ext/git/plyn-symphony
export PATH=/opt/homebrew/opt/erlang@28/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
unset GITHUB_TOKEN GH_TOKEN
export GH_CONFIG_DIR=/Users/yanlobau/Library/Application\ Support/plyn-symphony/gh-config

mkdir -p "$root/var/logs" "$root/var/workspaces" "$GH_CONFIG_DIR"
chmod 700 "$GH_CONFIG_DIR"
exec /opt/homebrew/opt/erlang@28/bin/escript "$root/elixir/bin/symphony" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$root/var/logs" \
  "$@" "$root/WORKFLOW.plyn.md"
