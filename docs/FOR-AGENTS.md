# For agents

An agent can write a setup script in seconds, so setup isn't what needs guarding. What needs
guarding is what an agent shouldn't choose: credentials, network reach and connectors.
Profiles draw that line, and these are the rules for staying on your side of it.

- [SPEC.md](SPEC.md) is the contract, and [AGENTS.md](../AGENTS.md) has the rules for
  working on this repository.
- Before you launch a set, plan it with `--agent`. Exit 0 means you may launch it. Exit 1
  means it is refused: act on the code in brackets. When the sentence says a person must
  launch the set, hand it to a person; don't look for a way around it.
- Never write a credential into a profile, a file or a command line. If a set needs a
  secret, it needs a privileged profile or a connector, and those are a person's to set up.
  `sprite-profiles connect` is a person's command; never try to run it.
- Inputs are not secrets, so you may pass them with `-i`. A refusal for a missing or invalid
  input names the input and what it takes.
- To give Sprites a new capability, add a profile rather than changing one Sprite by hand.
  The next Sprite gets it too, and the merge checks it against everything else.
- Inside a launched Sprite, each profile's skills are at
  `~/.claude/skills/<profile>--<skill>/`, or `<owner>.<profile>--<skill>/` for a published
  one.
- Prefer launching a lock file. A lock names exact commits, so the set you checked is the
  set you launch.
- `sprite-profiles exec NAME CMD` runs a command in a launched Sprite and exits with its
  status. When a launch's output isn't a terminal, as for an agent, nothing is erased: the
  setup lines print indented, then each profile's ✓ line.

```
$ sprite-profiles plan claude-code anthropic-key --agent
Refused:
  [not_for_agents] profile 'anthropic-key' is privileged; an agent may not launch a set that holds it, so a person must launch this set.
```

Next comes an MCP server, so that an agent can list profiles and launch sets without ever
holding the Sprites token. It will refuse privileged sets on its own; today that judgment is
`sprite-profiles plan --agent`.
