---
name: profiled
description: How to work on a Sprite set up with sprite-profiles. Use before long-running work, before risky changes, or when asked how this Sprite was set up.
---

# Working on a profiled Sprite

This Sprite was built from a set of profiles. Each profile added files, settings, skills
or services; nothing was removed. `~/.config/profiled/env.sh` holds the env the set defines
and is sourced from `~/.bashrc`.

## Stay awake while you work

A Sprite pauses about 30 seconds after output stops, even in the middle of a job. While a
Claude Code turn runs, hooks hold a Task named `claude-turn` for you. For work that runs
after your turn ends (a background build, a long download), hold your own Task:

    sprite-env curl -s -X POST /v1/tasks -H 'Content-Type: application/json' \
      -d '{"name":"build","expire":"10m"}'

Extend it every minute or so with `PUT /v1/tasks/build {"expire":"5m"}`, and delete it when
done: `sprite-env curl -s -X DELETE /v1/tasks/build`. A Task lasts at most an hour.

## Checkpoint at good moments

Checkpoints are fast (well under a second). Make one before a risky change and after
reaching a good state:

    sprite-env checkpoints create --comment "before: upgrade deps"

The checkpoint made when this Sprite was profiled has the comment `profiled: <set>`.

## External APIs

If the set includes a connector profile, use its gateway URL from the env (for example
`$GITHUB_GATEWAY_URL`). Never ask the user for a token and never write one to disk.
