# sprite-profiles

Composable profiles for [Fly.io Sprites](https://sprites.dev). Pick a few, and a fresh Sprite
gets all of them, merged by rules that refuse rather than guess.

```sh
mix profiles.launch -p claude-code -p playwright -p preview --name demo-1
```

A **profile** is a small folder: what to install, files to push, services to run, the
network rules and connectors it needs, Claude Code skills and MCP servers, and whether it
holds a credential.

## Why not a setup script?

You could install all of that with a setup script in a couple of minutes. Profiles are for
the parts a script can't do.

**Part of a Sprite's setup isn't inside the Sprite.** Network policy, connector access and
labels are set through the Sprites API, from outside. A script running in the Sprite can't
change them, and it shouldn't be able to. A profile declares both halves. Picking `github`
gives the Sprite a skill that tells its agent how to reach GitHub, a network rule for Fly's
gateway, and a label that the org's GitHub connector admits. That's GitHub access with no
token in the Sprite, as one pick.

**Scripts don't combine; profiles do.** Run two setup scripts and the second one silently
wins: both set the same variable, both register an MCP server called `github`, or both
claim the Sprite's URL. Profiles are declarations, so the whole set is merged and checked
before a Sprite exists. A disagreement is refused, in a sentence that names both profiles.
Here the example `preview` meets a profile of your own that also serves the Sprite's URL:

```
$ mix profiles.plan -p preview -p docs-site
Refused:
  [http_port_conflict] profiles 'preview' and 'docs-site' both give a service an http_port ('preview' on 8080, 'docs' on 4000); a Sprite routes its URL to one service, so drop http_port from one of them.
```

Network rules combine with every deny ahead of every allow, so a profile that blocks a
domain beats one that allows it. A missing connector, or an MCP server that would sit
waiting for a sign-in nobody can answer, is refused before anything is created, not a
minute into setup.

**Agents get a boundary.** An agent can write a setup script in seconds, so setup isn't what
needs guarding. What needs guarding is what an agent shouldn't choose: credentials, network
reach and connectors. A profile that holds a credential is marked **privileged**. An agent
may not launch a set that holds one, and the credential is applied after the Sprite's
checkpoint, so restoring that checkpoint never brings a key back.

```
$ mix profiles.plan -p claude-code -p anthropic-key --agent
Refused:
  [not_for_agents] profile 'anthropic-key' is privileged; an agent may not launch a set that holds it, so a person must launch this set.
```

If you are one person with one setup that never changes, a script is fine. Profiles start to
pay when there is a second author, such as a teammate or a vendor whose profile sits next to
yours, or when an agent is the one launching Sprites.

## Quick start: plan a set

Planning needs no Sprite and no token. You need Elixir 1.17 or later.

```sh
git clone https://github.com/antialias/sprite-profiles
cd sprite-profiles
mix deps.get
mix profiles.plan -p claude-code -p playwright
```

The plan says what the Sprite will get, which profile each part comes from, and in what
order:

```
Plan for claude-code+playwright

Apply order:
  1. claude-code  (setup.sh, up to 5m)
  2. playwright  (setup.sh, up to 20m)
  -- checkpoint "profiled: claude-code+playwright" --

Labels:
  profile:claude-code
  profile:playwright

Connectors: none

Network policy:
  include defaults
  allow mcp.context7.com
  allow cdn.playwright.dev
  allow example.com

Env:
  DISABLE_AUTOUPDATER = "1"  (claude-code)

Services: none

MCP servers:
  context7 (http) https://mcp.context7.com/mcp  (claude-code)
...
```

`-p` is short for `--profile`; repeat it in the order the profiles should apply. A refused
set exits 1 and prints one line per refusal: a code in brackets for programs, then a
sentence for people. `--agent` judges the set as an agent would launch it.

## Launch a Sprite

You need the [`sprite` CLI](https://docs.fly.io/sprites/quickstart.md), logged in. The
launcher runs it for you and never reads or prints your token.

```sh
mix profiles.launch -p claude-code -p preview --name demo-1
sprite exec -s demo-1 -- claude mcp list       # look inside
sprite checkpoint list -s demo-1
sprite destroy --force demo-1                   # when you're done
```

The launcher prints each step's time as it goes:

1. Merge the set, and refuse before any API call.
2. If the set needs a connector, check that one in the org admits it.
3. Create the Sprite, with a `profile:<name>` label for every pick.
4. Set the network policy.
5. Apply each profile in order: files, skills, Claude settings, MCP servers, then
   `setup.sh` (holding a Sprites Task so the Sprite stays awake), then services.
6. Checkpoint it as `profiled: claude-code+preview`.
7. Apply privileged profiles, after the checkpoint.

`--dry-run` stops after step 1. `--destroy-on-failure` removes the Sprite if a later step
fails; otherwise it is left for you to inspect. A record of each launch goes to
`~/.local/state/sprite-profiles/launches/`, outside the repository.

A privileged profile's secret is read on your machine from
`~/.config/sprite-profiles/secrets/<NAME>` (one line, `chmod 600`), or from the folder
`--secrets-dir` names. It is never in a profile. On a server without the CLI,
`--adapter api` calls the Sprites API with the org token in `SPRITES_TOKEN`; so far that
path is tested against a stub only.

## Write your own profile

Your own profiles live outside this repository, in `~/.config/sprite-profiles/profiles/`,
and compose with the examples. A profile is a folder named for it:

```
~/.config/sprite-profiles/profiles/node-tools/
  profile.toml      required
  setup.sh          optional: runs in the Sprite as user `sprite`; must be safe to run twice
  files/            optional: pushed to $HOME, keeping the tree
  claude/skills/    optional: each folder becomes ~/.claude/skills/node-tools--<skill>/
```

`profile.toml`:

```toml
name    = "node-tools"
summary = "The TypeScript compiler and Prettier"

[policy]
rules = [ { include = "defaults" } ]   # the defaults already allow npm's registry
```

`setup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
npm install -g typescript prettier
npx tsc --version
```

Plan it with an example, then launch it. Launched as written, `claude-code + node-tools`
took 12.6 s:

```sh
mix profiles.plan -p claude-code -p node-tools
mix profiles.launch -p claude-code -p node-tools --name demo-2
```

Some rules worth knowing before you write more:

- **Say what network you need.** When no profile in a set declares a policy, the Sprite's
  default applies, which is unrestricted. As soon as one does, only the combined rules
  apply. So a profile that needs a domain should allow it, as `node-tools` does above.
- **`setup.sh` runs in a plain shell.** Node's global commands, such as `tsc` here, are on
  the PATH of an interactive shell but not of `setup.sh`. Call them through `npx`.
- **Keep secrets out.** A secret is `{ secret = "NAME" }` in `[env]`, and only a profile
  marked `privileged = true` may use one. The value stays on the launching machine.
- **Add, never override.** A profile can't remove or change what another one sets. If two
  profiles set the same thing, the set is refused, and you choose which one gives way.
- **Typos are errors.** A field the format doesn't define is refused, so a misspelling can't
  silently do nothing.

[docs/SPEC.md](docs/SPEC.md) has every field, merge rule and refusal code. `--dir`
(repeatable) or `SPRITE_PROFILES_PATH` (colon-separated) replaces the search path. The same
name found in two folders is refused, so your profile never silently shadows an example.

## For agents

- [docs/SPEC.md](docs/SPEC.md) is the contract, and [AGENTS.md](AGENTS.md) has the rules
  for working on this repository.
- Before you launch a set, plan it with `--agent`. Exit 0 means you may launch it. Exit 1
  means it is refused: act on the code in brackets. When the sentence says a person must
  launch the set, hand it to a person; don't look for a way around it.
- Never write a credential into a profile, a file or a command line. If a set needs a
  secret, it needs a privileged profile, and that is a person's to launch.
- To give Sprites a new capability, add a profile rather than changing one Sprite by hand.
  The next Sprite gets it too, and the merge checks it against everything else.
- Inside a launched Sprite, each profile's skills are at
  `~/.claude/skills/<profile>--<skill>/`.

Next comes an MCP server, so that an agent can list profiles and launch sets without ever
holding the Sprites token. It will refuse privileged sets on its own; today that judgment is
`mix profiles.plan --agent`.

## The example profiles

| profile | gives a Sprite |
|---|---|
| `claude-code` | Claude Code ready to work unattended: hooks that keep the Sprite awake mid-turn, a pre-trusted `~/work`, and an MCP server that needs no sign-in. No model access of its own |
| `github` | GitHub through Fly's connector gateway, with no token in the Sprite |
| `playwright` | Playwright and Chromium, then a headless page load to prove it works |
| `anthropic-key` | **privileged**: an Anthropic API key, read from your machine at launch |
| `preview` | a static-file service on the Sprite's own URL |

`github` needs a GitHub connector in your org whose access policy names the label
`profile:github`. Without one, the launch is refused before anything is created.

## What it costs, measured

Each example set was launched on fresh Sprites ([docs/RESULTS.md](docs/RESULTS.md) has every
step):

| set | total | of which |
|---|---:|---|
| `claude-code + anthropic-key` | 6.7 s | the key, applied after the 0.4 s checkpoint |
| `claude-code + preview` | 11.8 s | creating the service, 5.4 s |
| `claude-code + playwright` | 49-65 s | Playwright's setup, 36-53 s |

Restoring the playwright Sprite's checkpoint takes 3.9 s, but a checkpoint can only be
restored into the Sprite that took it, so every new Sprite pays the full setup again.
Starting a new Sprite from a checkpoint would turn that minute into seconds, and a set of
profiles at fixed versions is a natural key for such a template.

[docs/launch.cast](docs/launch.cast) is a terminal recording of a launch; play it with
`asciinema play docs/launch.cast`. It shows an agent refused a privileged set, then a person
launching `claude-code + playwright`, with headless Chromium loading a page in the new
Sprite.

## Where this could go

A shelf of setup scripts isn't something you can share safely, because you can't combine
two of them. A shelf of profiles can be: each declares what it needs, the merged plan shows
everything before launch, and a conflict is a refusal. A profile's network rules work like
an app's permission list: you see "reaches github.com and npm" before it runs. So the vendor
of a tool or a connector could publish the profile for it.

That needs pieces this repository doesn't have yet: versioned and signed profiles, since
`setup.sh` runs with the Sprite's full access; dependencies between profiles; and starting a
Sprite from a template, which only the platform can provide.

## Status

The profile format, the merge rules, `mix profiles.plan` and `mix profiles.launch` work
today, and four of the five examples have been launched on real Sprites. `github` waits on a
connector. Next come the MCP server for agents and a web catalogue for picking a set.

- [docs/SPEC.md](docs/SPEC.md): the profile format, the merge rules and the launch sequence.
- [docs/RESULTS.md](docs/RESULTS.md): step timings on real Sprites.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to contribute, and what must never be committed.

## License

Apache-2.0.
