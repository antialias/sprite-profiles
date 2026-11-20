# Contributing

## Publish a profile

The most useful contribution is a profile. It lives in your own repository, not this one, so
you need no one's approval to publish it:

1. Start from the [template](https://github.com/antialias/sprite-profile-template), or name a
   public repository `sprite-profile-NAME` with `profile.toml` at its root.
2. Tag a version and give the repository the topic `sprite-profile`.
3. [Add it to the gallery](../../issues/new?template=add-profile.yml) in the README.

[Writing a profile](docs/WRITING.md) and [Publishing a profile](docs/PUBLISHING.md) have the
details. A profile you'd like but can't write yourself is a
[request](../../issues/new?template=request-profile.yml). Questions go to
[Discussions](../../discussions).

A good profile does one thing, declares every domain it reaches, keeps tokens in a connector
rather than the Sprite, and says in its `description` what it costs. The privacy rules below
apply to a published profile too.

## Change sprite-profiles itself

Bug reports and pull requests are welcome. [AGENTS.md](AGENTS.md) has how to run and check
the code, for people as much as for agents.

### Before you open a pull request

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
