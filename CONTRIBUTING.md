# Contributing

## Before you open a pull request

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

A change to the merge rules changes `docs/SPEC.md` and adds a test for the rule in
`test/sprite_profiles/merge_test.exs`.

## Keep it private: what never goes in this repository

This repository is public. Check every change, its commit messages and anything you paste
into an issue against this list.

- **No credentials.** No tokens, API keys, passwords, connector ids, org ids or Sprite URLs
  that carry an id. A privileged profile names its secret (`{ secret = "NAME" }`); the value
  lives on the launching machine, never here. `.env` files and `secrets/` folders are
  gitignored. A test fails if a profile reads a secret without being privileged.
- **No personal infrastructure.** No hostnames, IP addresses, network ranges or internal DNS
  names; no names of private servers, services or other private projects.
- **No personal details.** No names of people, households, calendars or devices; no email
  addresses other than GitHub's no-reply address.
- **Model access stays generic.** Examples use a claude.ai sign-in, an Anthropic API key
  (the `anthropic-key` profile), or a Fly connector. Nothing else.
- **No real Sprites.** Example and test Sprites are named `demo-*` or `agent-*` and are
  destroyed after use. Their names, URLs and checkpoint ids do not go in docs or fixtures.
- **No pasted output that carries any of the above,** in code, docs, fixtures, screenshots,
  recordings or commit messages. Read `git log -p` before you push.
- **Local state stays local.** Launch records and caches go under `~/.local/state`, never in
  the repository.
- **Your own work.** Contribute code and prose you wrote or may license under Apache-2.0.
