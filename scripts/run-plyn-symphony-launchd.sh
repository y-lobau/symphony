#!/bin/zsh
set -euo pipefail

root=/Volumes/ext/git/plyn-symphony
runtime="$root/bin/symphony-v0.0.3-macos_arm64"
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export GITHUB_TOKEN="$(/usr/bin/awk -F ": " '/^    oauth_token:/ {print $2; exit}' /Users/yanlobau/.config/gh/hosts.yml)"

[[ -n "$GITHUB_TOKEN" ]] || { print -u2 "GitHub token unavailable"; exit 1; }

mkdir -p /Users/yanlobau/Library/Logs/plyn-symphony
exec "$runtime" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$root/var/logs" \
  --port 4097 \
  "$root/WORKFLOW.plyn.md"
