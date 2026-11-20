#!/usr/bin/env bash
# The sprite-profiles demo: each line is typed out, then run for real. It creates and then
# destroys a Sprite named demo, and needs the `anthropic` and `antialias.shop-inventory`
# connectors in your org (`sprite-profiles connect anthropic`, and the shop's token).
#
# Record it with asciinema and agg (no browser involved):
#   asciinema rec --headless --window-size 120x34 -i 2 --overwrite -c demo/demo.sh demo/demo.cast
#   agg --font-size 16 demo/demo.cast demo/demo.gif
set -u

type_line() {   # a prompt, then the text one character at a time
  local s="$1" i
  printf '\033[1;32m$\033[0m '
  for ((i = 0; i < ${#s}; i++)); do printf '%s' "${s:i:1}"; sleep 0.025; done
  sleep 0.5; printf '\n'
}
say() { printf '\033[2m'; type_line "# $1"; printf '\033[0m'; }
run() { type_line "$1"; eval "$1"; sleep "${2:-2}"; }

clear
say "A shop published its inventory as a profile. Find it on GitHub:"
run "sprite-profiles search shop" 3

say "A Sprite with Claude Code, its model and the shop, each through a Fly connector:"
run "sprite-profiles launch claude-code anthropic @antialias/shop-inventory --name demo" 3

say "Ask Claude, inside the Sprite:"
run "sprite exec --no-stdin -s demo -- bash -lc 'claude -p \"What could I build this weekend with the tools in my shop? Three ideas, one line each.\" --allowedTools mcp__shop' 2>/dev/null" 5

say "The Sprite holds a placeholder, not the key; the shop answers only through the gateway:"
run "sprite exec --no-stdin -s demo -- bash -lc 'echo \"key: \$ANTHROPIC_API_KEY\"; echo \"shop, direct: \$(curl -s -m 5 -o /dev/null -w %{http_code} https://woodworking.haunt.house/mcp)\"' 2>/dev/null" 4

run "sprite destroy --force demo" 2
