#!/usr/bin/env bash
# The sprite-profiles demo: seven profiles composed into one Sprite. Each line is typed out, then
# run for real. It works in a scratch copy of this folder's `weekend` profile, creates and then
# destroys a Sprite named demo, and needs the `anthropic`, `antialias.shop-inventory` and
# `github-mcp` connectors in your org (`sprite-profiles connect <profile>` for each).
#
# Record it with asciinema and agg (no browser involved); pauses over 2 s are cut:
#   asciinema rec --headless --window-size 120x36 -i 2 --overwrite -c demo/demo.sh demo/demo.cast
#   agg --font-size 16 --theme monokai demo/demo.cast demo/demo.gif
# The page Claude builds is pulled to demo/weekend.png.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
work=/tmp/my-project && rm -rf "$work" && mkdir -p "$work" && cp -R "$here/weekend" "$work/" && cd "$work" || exit 1
type_line() { local s="$1" i; printf '\033[1;32m$\033[0m '; for ((i = 0; i < ${#s}; i++)); do printf '%s' "${s:i:1}"; sleep 0.02; done; sleep 0.5; printf '\n'; }
say() { printf '\033[2m'; type_line "# $1"; printf '\033[0m'; }
run() { type_line "$1"; eval "$1"; sleep "${2:-2}"; }
clear
say "This project's own profile holds its task, as a skill, and what Claude may use for it:"
run "sprite-profiles show ./weekend" 4
say "Compose it with a shop's profile, published on GitHub, and five bundled ones:"
run "sprite-profiles add claude-code anthropic @antialias/shop-inventory github-mcp playwright preview ./weekend" 2
run "sprite-profiles plan" 6
say "Add a second profile that also sets the model's key: refused, never settled silently."
run "sprite-profiles add anthropic-key && sprite-profiles plan" 4
run "sprite-profiles remove anthropic-key" 2
say "Launch. Each connector admits only a Sprite that carries its profile's label:"
run "sprite-profiles launch --name demo" 4
say "Ask Claude, inside the Sprite:"
run "sprite exec --no-stdin -s demo -- bash -lc 'claude -p \"Build the weekend page.\"' 2>/dev/null" 5
say "Playwright's screenshot of the page, at phone size, is under this recording:"
run "sprite file pull -s demo /home/sprite/site/screenshot.png weekend.png && file weekend.png" 3
run "sprite destroy --force demo" 2
cp -f weekend.png "$here/weekend.png" 2>/dev/null
