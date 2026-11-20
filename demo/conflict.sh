#!/usr/bin/env bash
# Two profiles that set the same thing are refused. Needs no Sprite.
#   DEMO_ROWS=9 DEMO_COLS=100 asciinema rec --headless --window-size 100x9 -i 2 \
#     --overwrite -c demo/conflict.sh demo/conflict.cast
#   agg --font-size 16 --theme monokai demo/conflict.cast demo/conflict.gif
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
cd "$(mktemp -d)" || exit 1
begin
subtitle "Two profiles set the model's key. The set is refused, never merged silently."
run "sprite-profiles plan claude-code anthropic anthropic-key" 5
end
