#!/usr/bin/env bash
# The Apiary swap: the same project with one profile changed, so Claude's model goes through
# Apiary's HTTPS proxy (@antialias/apiary) instead of Fly's `anthropic` connector. The launch
# enrols the Sprite as an Apiary device; someone approves it at apiary.wtf/devices.
#   DEMO_ROWS=24 DEMO_COLS=100 asciinema rec --headless --window-size 100x24 -i 2 \
#     --overwrite -c demo/apiary.sh demo/apiary.cast
#   agg --font-size 16 --theme monokai demo/apiary.cast demo/apiary.gif
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
project || exit 1
begin
subtitle "Swap one profile: Claude's model through Apiary's proxy instead."
run "sprite-profiles remove anthropic && sprite-profiles add @antialias/apiary" 3 || stop
subtitle "The Sprite signs in to Apiary as a device that someone approves."
run "sprite-profiles launch --name demo" 3 || stop
subtitle "Ask Claude, now through the proxy."
run 'sprite-profiles exec demo claude -p "Which battery platform does the shop use most? One line."' 4 || stop
quietly sprite destroy --force demo
end
