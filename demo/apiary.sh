#!/usr/bin/env bash
# The Apiary swap: the same shop, with Claude's model reached through Apiary's HTTPS proxy
# (@antialias/apiary) instead of Fly's `anthropic` connector. The launch enrols the Sprite as an
# Apiary device, so someone approves it at apiary.wtf/devices while this runs (pauses are cut).
#   asciinema rec --headless --window-size 120x34 -i 2 --overwrite -c demo/apiary.sh demo/apiary.cast
#   agg --font-size 16 --theme monokai demo/apiary.cast demo/apiary.gif
set -u
type_line() { local s="$1" i; printf '\033[1;32m$\033[0m '; for ((i = 0; i < ${#s}; i++)); do printf '%s' "${s:i:1}"; sleep 0.02; done; sleep 0.5; printf '\n'; }
say() { printf '\033[2m'; type_line "# $1"; printf '\033[0m'; }
run() { type_line "$1"; eval "$1"; sleep "${2:-2}"; }
clear
say "Swap one profile: Claude's model through Apiary's HTTPS proxy, not Fly's connector."
run "sprite-profiles launch claude-code @antialias/apiary @antialias/shop-inventory --name demo" 4
say "Ask Claude, through the proxy, with the shop still through the gateway:"
run "sprite exec --no-stdin -s demo -- bash -lc 'claude -p \"Which battery platform does the shop use most, and for which tools? Two lines.\" --allowedTools mcp__shop' 2>/dev/null" 5
run "sprite destroy --force demo" 2
