# sprite-profiles

Composable profiles for [Fly.io Sprites](https://sprites.dev).

A **profile** is a small folder that says what a Sprite needs: packages to install, files to
push, services to run, the network policy and connectors it depends on, Claude Code skills
and MCP servers, and whether it is **privileged** (holds a credential, so agents may not
launch it and it is never saved in a checkpoint). Pick a few profiles and they merge by
explicit rules: union where that is safe, a refusal in plain words where two of them
disagree.

**Status: work in progress.** The profile format, the merge rules and `mix profiles.plan`
work today. Creating and profiling a real Sprite, the MCP server for agents, and the web
catalogue are next.

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

## The example profiles

| profile | shows |
|---|---|
| `claude-code` | Claude Code ready to work unattended: hooks that keep the Sprite awake mid-turn, a pre-trusted `~/work`, an MCP server that needs no sign-in |
| `github` | GitHub through Fly's connector gateway, with no token in the Sprite |
| `playwright` | the heavy one: a browser install that takes minutes |
| `anthropic-key` | privileged: an Anthropic API key, read from your machine at launch |
| `preview` | a static-file service on the Sprite's URL |

Setup scripts in the examples have not yet been run on a Sprite.

## Read more

- [docs/SPEC.md](docs/SPEC.md): the profile format and the merge rules.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to contribute, and what must never be committed.

## License

Apache-2.0.
