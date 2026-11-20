#!/usr/bin/env bash
# The sprite-profiles demo: a project's own profile composed with six others into one Sprite,
# and Claude building a page in it. Creates, then destroys, a Sprite named demo; needs the
# `anthropic`, `antialias.shop-inventory` and `github-mcp` connectors in your org.
#   DEMO_ROWS=24 DEMO_COLS=100 asciinema rec --headless --window-size 100x24 -i 2 \
#     --overwrite -c demo/demo.sh demo/demo.cast
#   agg --font-size 16 --theme monokai demo/demo.cast demo/demo.gif
# Pauses over 2 s are cut. The page's screenshot is pulled to demo/weekend.png.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
project || exit 1
begin
subtitle "A project lists the profiles it needs, its own among them."
run "cat sprite-profiles.toml" 3
subtitle "One command: a Sprite with all seven. Keys stay with Fly, not in the Sprite."
run "sprite-profiles launch --name demo" 3
subtitle "Ask Claude, inside the Sprite."
run 'sprite-profiles exec demo claude -p "Build the weekend page."' 4
subtitle "It built a page from the shop's real inventory: its screenshot is below."
quietly sprite file pull -s demo /home/sprite/site/screenshot.png "$here/weekend.png"
sleep 3
quietly sprite destroy --force demo
end
