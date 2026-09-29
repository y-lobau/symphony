#!/bin/zsh
set -euo pipefail

root=/Volumes/ext/git/plyn-symphony
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export GITHUB_TOKEN="$(gh auth token)"

mkdir -p "$root/var/logs" "$root/var/workspaces"
exec "$root/bin/symphony-v0.0.3-macos_arm64" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$root/var/logs" \
  "$@" "$root/WORKFLOW.plyn.md"
