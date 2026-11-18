# sprite-profiles

Composable profiles for [Fly.io Sprites](https://sprites.dev).

A **profile** is a small folder that says what a Sprite needs: packages to install, files to
push, services to run, the network policy and connectors it depends on, Claude Code skills
and MCP servers, and whether it is **privileged** (holds a credential, so agents may not
launch it and it is never saved in a checkpoint). Pick a few profiles and they merge by
explicit rules: union where that is safe, a refusal in plain words where two of them
disagree.

**Status: work in progress.** The profile format, the merge rules, `mix profiles.plan` and
`mix profiles.launch` (create a real Sprite and apply a set to it) work today. The MCP server
for agents and the web catalogue are next.

## Try it

You need Elixir 1.17 or later.

```sh
mix deps.get
mix profiles.plan --profile claude-code --profile github
mix profiles.plan --profile claude-code --profile anthropic-key            # privileged: applied after the checkpoint
mix profiles.plan --profile claude-code --profile anthropic-key --agent    # refused: agents may not launch it
```

`mix profiles.plan` prints the merged plan, including the order profiles are applied in, or
the refusal (and exits non-zero). It needs no Sprite and no token.

### Launch a Sprite

You need the [`sprite` CLI](https://docs.fly.io/sprites/quickstart.md), logged in. The
launcher runs it for you; it never reads or prints your token.

```sh
mix profiles.launch --profile claude-code --profile preview --name demo-1
mix profiles.launch --profile claude-code --profile github --name demo-2   # refused until a GitHub connector admits profile:github
sprite destroy --force demo-1
```

It creates the Sprite with its labels, sets the network policy, applies each profile
(files, skills, Claude settings, MCP servers, `setup.sh` under a Task hold, services),
checkpoints it as `profiled: claude-code+preview`, applies privileged profiles after the
checkpoint, and prints each step's time as it goes. `--dry-run` stops after resolving the
set; `--destroy-on-failure` removes the Sprite if a step fails. A record of each launch goes
to `~/.local/state/sprite-profiles/launches/`, outside the repository.

To look inside afterwards:

```sh
sprite exec -s demo-1 -- claude mcp list
sprite exec -s demo-1 -- ls ~/.claude/skills
sprite checkpoint list -s demo-1
```

A privileged profile's secret is read from `~/.config/sprite-profiles/secrets/<NAME>` (one
line, `chmod 600`), or from the folder `--secrets-dir` names. On a server without the CLI, `--adapter api` calls the Sprites API with
the org token in `SPRITES_TOKEN`; that path is tested against a stub only so far.

### Your own profiles

Profiles that hold your own credentials or tools belong outside this repository. Put them in
`~/.config/sprite-profiles/profiles/<name>/` and they are found next to the examples; or name
folders with `--dir` (repeatable) or `SPRITE_PROFILES_PATH` (colon-separated), which replace
the default path. A name found in two folders is refused, naming both, so a private profile
never silently shadows an example.

```sh
mix profiles.plan -p claude-code -p my-model --dir profiles --dir ~/my-profiles
```

## The example profiles

| profile | shows |
|---|---|
| `claude-code` | Claude Code ready to work unattended: hooks that keep the Sprite awake mid-turn, a pre-trusted `~/work`, an MCP server that needs no sign-in |
| `github` | GitHub through Fly's connector gateway, with no token in the Sprite |
| `playwright` | the heavy one: a browser install that takes minutes |
| `anthropic-key` | privileged: an Anthropic API key, read from your machine at launch |
| `preview` | a static-file service on the Sprite's URL |

`claude-code` and `preview` have been applied to fresh Sprites. `github` needs a GitHub
connector in your org; `playwright` and `anthropic-key` are measured next.

## Read more

- [docs/SPEC.md](docs/SPEC.md): the profile format and the merge rules.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to contribute, and what must never be committed.

## License

Apache-2.0.
