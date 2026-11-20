# Writing a profile

A profile is a folder named for it, with a `profile.toml` that declares what it gives a
Sprite. Your own profiles live outside this repository, in
`~/.config/sprite-profiles/profiles/`, and compose with the bundled ones. To share one,
[publish it](PUBLISHING.md).

## The folder

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

Plan it with a bundled profile, then launch it. Launched as written, `claude-code +
node-tools` took 12.6 s:

```sh
sprite-profiles plan claude-code node-tools
sprite-profiles launch claude-code node-tools --name demo-2
```

## Rules worth knowing first

- **Say what network you need.** When no profile in a set declares a policy, the Sprite's
  default applies, which is unrestricted. As soon as one does, only the combined rules
  apply. So a profile that needs a domain should allow it, as `node-tools` does above.
- **`setup.sh` runs in a plain shell.** Node's global commands, such as `tsc` here, are on
  the PATH of an interactive shell but not of `setup.sh`. Call them through `npx`.
- **Keep secrets out.** A secret is `{ secret = "NAME" }` in `[env]`, and only a profile
  marked `privileged = true` may use one. The value stays on the launching machine. A
  company's API token belongs in a connector instead: see [Inputs and a company's
  API](INPUTS.md).
- **Add, never override.** A profile can't remove or change what another one sets. If two
  profiles set the same thing, the set is refused, and you choose which one gives way.
- **Typos are errors.** A field the format doesn't define is refused, so a misspelling can't
  silently do nothing.

## How your profile meets others

Profiles are declarations, so the whole set is merged and checked before a Sprite exists.
Where two setup scripts would quietly overwrite each other, such as both setting the same
variable, both registering an MCP server called `github`, or both claiming the Sprite's URL,
two profiles are refused, in a sentence that names both.

Network rules combine with every deny ahead of every allow, so a profile that blocks a
domain beats one that allows it. A missing connector, or an MCP server that would sit
waiting for a sign-in nobody can answer, is refused before anything is created, not a minute
into setup.

## Where profiles are found

`--dir` (repeatable) or `SPRITE_PROFILES_PATH` (colon-separated) replaces the search path; a
path pick (`./weekend`) names one folder and leaves the path alone. The same name found in
two folders is refused, so your profile never silently shadows a bundled one.

[SPEC.md](SPEC.md) has every field, merge rule and refusal code.
