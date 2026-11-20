# Shared by the demo scripts: a subtitle bar on the terminal's last row, outside the scroll
# region, and commands typed out, then run for real. DEMO_ROWS and DEMO_COLS must match the
# recording's --window-size.
rows=${DEMO_ROWS:-24}
cols=${DEMO_COLS:-100}
subtitle_text=""
subtitle() {
  subtitle_text="$1"
  printf '\0337\033[%d;1H\033[2K\033[48;5;236m\033[1;97m%-*s\033[0m\0338' "$rows" "$cols" "  $1"
}
begin() { printf '\033[2J\033[1;%dr\033[1;1H' $((rows - 2)); }
# Hide the cursor and give the whole screen back, leaving the subtitle where it is.
end() { printf '\033[?25l\0337\033[r\0338'; sleep 1; }
type_line() {
  local s="$1" i
  printf '\033[1;32m$\033[0m '
  for ((i = 0; i < ${#s}; i++)); do printf '%s' "${s:i:1}"; sleep 0.015; done
  sleep 0.4; printf '\n'
}
run() {
  type_line "$1"; eval "$1"; local status=$?
  subtitle "$subtitle_text"; sleep "${2:-2}"; return $status
}
# A step that failed ends the take: the Sprite is destroyed and the script exits 1.
stop() { quietly sprite destroy --force demo; end; exit 1; }
quietly() { "$@" >/dev/null 2>&1; }
# A project folder holding this demo's own profile and the set, as a project file.
project() {
  rm -rf /tmp/my-project && mkdir -p /tmp/my-project && cp -R "$here/weekend" /tmp/my-project/ &&
    cat >/tmp/my-project/sprite-profiles.toml <<'TOML' && cd /tmp/my-project
profiles = [
  "claude-code",
  "anthropic",
  "@antialias/shop-inventory@1",
  "github-mcp",
  "playwright",
  "preview",
  "./weekend",
]
TOML
}
