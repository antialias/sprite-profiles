#!/usr/bin/env bash
# Claude Code hook: hold a Sprites Task while a turn runs, release it when Claude stops.
# A Sprite pauses about 30 s after output stops, even mid-job, unless a Task holds it.
# `hold` creates the Task or extends it by 5 minutes; `release` deletes it.
# Untested until milestone M2. A hook must never block Claude, so this always exits 0.
name="claude-turn"
case "${1:-}" in
  hold)
    sprite-env curl -s -f -X PUT "/v1/tasks/$name" \
      -H 'Content-Type: application/json' -d '{"expire":"5m"}' >/dev/null 2>&1 ||
      sprite-env curl -s -X POST /v1/tasks \
        -H 'Content-Type: application/json' -d "{\"name\":\"$name\",\"expire\":\"5m\"}" >/dev/null 2>&1
    ;;
  release)
    sprite-env curl -s -X DELETE "/v1/tasks/$name" >/dev/null 2>&1
    ;;
esac
exit 0
