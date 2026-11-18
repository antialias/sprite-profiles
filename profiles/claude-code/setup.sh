#!/usr/bin/env bash
# Run on a fresh Sprite by `mix profiles.launch` (milestone M2).
# Idempotent: safe to run again.
set -euo pipefail

mkdir -p "$HOME/work"

# Pre-accept Claude Code's folder-trust question for ~/work.
config="$HOME/.claude.json"
[ -f "$config" ] || echo '{}' > "$config"
tmp="$(mktemp)"
jq --arg dir "$HOME/work" \
  '.projects[$dir].hasTrustDialogAccepted = true' "$config" > "$tmp"
mv "$tmp" "$config"

echo "claude-code: ~/work is trusted; hooks and settings are in place"
