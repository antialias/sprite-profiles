# The profile format and merge rules

This is the contract. The Elixir code implements it (`SpriteProfiles.Profile` reads a
profile, `SpriteProfiles.Merge` merges a set), but nothing here depends on Elixir: any tool
that reads TOML can read a profile and apply the same rules.

## Profiles

A **profile** is a folder under `profiles/<name>/` that says what a Sprite needs.

```
profiles/playwright/
  profile.toml      required
  setup.sh          optional; runs in the Sprite as user `sprite`; bash; must be idempotent
  files/            optional; pushed to $HOME with the tree preserved
  claude/skills/    optional; each subfolder becomes ~/.claude/skills/<profile>--<skill>/
```

- `files/` holds regular files only; symlinks and other special files are refused. A file
  keeps its executable bit (pushed as 0755) or gets 0644. Keep it small: pushing a file to a
  Sprite runs at a few MB/s.
- Each folder in `claude/skills/` must hold a `SKILL.md`. Skill names are lowercase letters,
  digits and `-`. Nothing else may sit in `claude/`.
- Other files in the profile folder (a README, say) are ignored.

### profile.toml

`profile.toml` is TOML 1.0. Every field the format does not define is refused, so a typo is
an error, not a silent no-op.

| field | type | default | meaning |
|---|---|---|---|
| `name` | string | required | the folder's name; 2-31 characters of `a-z`, `0-9` and `-`, starting with a letter |
| `summary` | string | required | one line, at most 80 characters |
| `description` | string | `""` | the honest paragraph: what it gives a Sprite and what it costs |
| `privileged` | bool | `false` | `true`: agents may not launch a set holding it, and it is applied after the checkpoint |
| `checkpoint` | bool | `true`, or `false` when privileged | `false`: applied after the checkpoint, never saved in it. A privileged profile may not set `true` |
| `timeout` | string | `"10m"` | how long `setup.sh` may take: a whole number of `s`, `m` or `h`, at most `1h` |
| `labels` | array of strings | `[]` | extra Sprite labels; lowercase letters, digits and `. _ : -`. Labels starting `profile:` are reserved |
| `[env]` | table | none | env for the Sprite; see below |
| `[policy]` | table | none | network policy rules; see below |
| `[[connectors]]` | array of tables | none | connectors this profile needs, each `{ provider = "github" }` |
| `[[services]]` | array of tables | none | Sprites services to create; see below |
| `[claude]` | table | none | `settings` (a Claude Code settings fragment) and `mcp_servers` |

#### env

Keys are uppercase letters, digits and `_`. `PROFILED_PROFILE` and `PROFILED_SET` are
reserved: the launcher sets them for every `setup.sh`. A value is one of:

| value | meaning |
|---|---|
| `"text"` | the value itself |
| `{ from = "connector", provider = "github" }` | the connector's gateway URL, resolved at launch. The profile must also declare that connector |
| `{ secret = "NAME" }` | read at launch from the launching machine, never from the repository. **Only a privileged profile may use it** |

#### policy

```toml
[policy]
rules = [ { include = "defaults" }, { action = "allow", domain = "api.sprites.dev" } ]
```

A rule is `{ include = "defaults" }` (the Sprites default list) or
`{ action = "allow" | "deny", domain = "example.com" }`. A domain may start with `*.`.

#### services

```toml
[[services]]
name      = "preview"
cmd       = "python3"
args      = ["-m", "http.server", "8080"]
http_port = 8080      # optional: the Sprite's URL is routed to this port
dir       = "~/site"  # optional
```

Names are lowercase letters, digits and `-`. Within one profile, names are unique and at
most one service has an `http_port`.

#### claude

```toml
[claude.settings.env]
BASH_DEFAULT_TIMEOUT_MS = "600000"

[claude.mcp_servers.context7]
type = "http"                         # http, sse or stdio (stdio when there is a command)
url  = "https://mcp.context7.com/mcp"
auth = "none"                         # says outright that it needs no sign-in
```

An MCP server takes the fields Claude Code's own configuration takes (`type`, `url`,
`headers`, `command`, `args`, `env`) plus two of ours, which are not passed on:

- `auth = "none"`: the server needs no credentials.
- `requires_env = ["NAME", ...]`: env the server needs from the set. References like
  `${NAME}` in `url`, `headers`, `env` or `args` count too; `${NAME:-default}` does not.

### What the format does not have

- **No includes.** Composition happens when a set is picked, not inside a profile.
- **No overrides or removals.** A profile only adds, so reading the set from the top tells
  you everything the Sprite gets.
- **No sizes.** Sprites have no size to choose at creation.

## Merging a set

A **set** is an ordered list of profile names. Merging a set gives either a **plan** (what
the Sprite will get and in what order) or one or more **refusals**. The rule throughout:
union where that is safe, refusal where two profiles disagree. Nothing is picked silently.

| field | rule | refusal |
|---|---|---|
| `env` | union; a key two profiles define is refused, **even with the same value** | `env_collision` |
| `policy.rules` | union, deduplicated; `include = "defaults"` at most once; every `deny` before every `allow`, so a deny in any profile wins. No profile declares a policy: none is set (the Sprite's default, unrestricted). One does: the union is set, so a profile that needs the network must say so | |
| `connectors` | union by provider. At launch, each must match an org connector whose access policy admits this Sprite: it allows all Sprites, or this Sprite carries **all** the labels it lists and its name starts with the name prefix it sets (whichever of the two it sets; a policy with neither admits nothing) | `connector_missing` |
| `labels` | `profile:<name>` for every pick, then declared labels, deduplicated. So a connector is granted to a *profile*: a GitHub connector whose policy names `profile:github` admits exactly the Sprites carrying that profile | |
| `services` | union; the same name twice is refused; two services with `http_port` are refused, since a Sprite routes its URL to one service | `service_collision`, `http_port_conflict` |
| `claude.mcp_servers` | union; the same name twice is refused. An `http`/`sse` server with no `Authorization` header and no `auth = "none"`, or any server needing env the set does not define, is refused before a Sprite is created: an unattended Sprite cannot answer a sign-in | `mcp_server_collision`, `mcp_needs_login` |
| `claude.settings` | deep merge of tables; a leaf two profiles set to different values is refused (the same value is fine). Arrays are leaves, except the ones Claude Code applies entry by entry: each `hooks.<event>` array and `permissions.allow` / `permissions.deny` **combine**, appending entries in pick order (each entry, such as one profile's hook group, kept whole) and keeping an identical entry once. A leaf in one profile where another has a table is refused. At launch each profile's settings are laid over the Sprite's own `~/.claude/settings.json` by the same rule: combining lists append, other leaves replace the image's | `settings_collision` |
| skills | namespaced `<profile>--<skill>`, so they never collide | |
| `files/` | pushed in pick order; the same path from two profiles is refused, as is a file where another profile has a folder (skills count as files here) | `file_collision` |
| `setup.sh` | runs in apply order, each with its own `timeout`, with `PROFILED_PROFILE`, `PROFILED_SET` and the merged env exported; a failure stops the launch | |
| `privileged` | a set holding a privileged profile is privileged: a person may launch it, an agent may not | `not_for_agents` |
| order | pick order, except that privileged profiles (and any with `checkpoint = false`) are applied after the `profiled` checkpoint, so credentials are never in a checkpoint. The plan prints the final order | |
| bounds | 1 to 8 picks, none repeated, every name valid | `no_profiles`, `too_many_profiles`, `duplicate_pick`, `bad_name` |

A pick that names no folder is refused with `profile_not_found`; a profile that fails
validation is reported with its validation codes.

### Refusals

A refusal is a code for programs and a full sentence for people. The sentence names every
profile involved and says what to change:

> profiles 'github' and 'claude-code' both define env GITHUB_TOKEN; a set will not pick one
> silently, so remove it from one of them.

### Validation codes

| code | when |
|---|---|
| `missing_profile_toml` | the folder has no `profile.toml` |
| `bad_toml` | `profile.toml` is not valid TOML 1.0 |
| `missing_field` | `name` or `summary` is missing |
| `unknown_field` | a field the format does not define, at any level |
| `bad_field` | a field of the wrong type or shape |
| `bad_name` | a name that breaks the pattern |
| `name_mismatch` | `name` differs from the folder's name |
| `secret_needs_privileged` | `{ secret = ... }` in a profile that is not privileged |
| `privileged_checkpoint` | a privileged profile sets `checkpoint = true` |
| `env_connector_undeclared` | env from a connector the profile does not declare |
| `reserved_env` | env `PROFILED_PROFILE` or `PROFILED_SET` |
| `reserved_label` | a declared label starting `profile:` |
| `duplicate_service` | two services of one name in one profile |
| `http_port_conflict` | two services with `http_port` in one profile |
| `bad_skill` | a skill that is not a folder, has a bad name, or has no `SKILL.md` |
| `bad_file` | a symlink or special file under `files/` or a skill |
| `unknown_entry` | anything in `claude/` other than `skills/` |
