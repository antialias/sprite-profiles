# The profile format and merge rules

This is the contract. The Elixir code implements it (`SpriteProfiles.Profile` reads a
profile, `SpriteProfiles.Merge` merges a set), but nothing here depends on Elixir: any tool
that reads TOML can read a profile and apply the same rules.

## Profiles

A **profile** is a folder `<name>/` that says what a Sprite needs. The examples live under
`profiles/` in this repository; your own can live anywhere on the search path (below).

```
profiles/playwright/
  profile.toml      required
  setup.sh          optional; runs in the Sprite as user `sprite`; bash; must be idempotent
  files/            optional; pushed to $HOME with the tree preserved
  claude/skills/    optional; each subfolder becomes ~/.claude/skills/<qualified name>--<skill>/
```

- `files/` holds regular files only; symlinks and other special files are refused. A file
  keeps its executable bit (pushed as 0755) or gets 0644. Keep it small: pushing a file to a
  Sprite runs at a few MB/s.
- Each folder in `claude/skills/` must hold a `SKILL.md`. Skill names are lowercase letters,
  digits and `-`. Nothing else may sit in `claude/`.
- Other files in the profile folder (a README, say) are ignored.

### Where profiles are found

Profiles are looked up along a **search path** of folders, each holding profile folders:

1. every `--dir` given, in order;
2. then each folder in `SPRITE_PROFILES_PATH` (colon-separated);
3. when neither names a folder: the repository's `profiles/`, plus
   `~/.config/sprite-profiles/profiles` when it exists.

So a profile that names your own credential or your own tools can live outside the
repository and still compose with the examples. A pick must be in exactly one folder on the
path: the same name in two folders is refused (`profile_ambiguous`), naming both paths,
rather than one silently shadowing the other. A folder on the path that does not exist is
refused (`profile_dir_missing`).

Secrets for privileged profiles are read from `~/.config/sprite-profiles/secrets/<NAME>`,
or the folder `--secrets-dir` names.

### Profiles by address

A pick may also be an **address** on GitHub: `owner/repo[/path]@ref`, the form GitHub
Actions uses. `owner/repo` is the repository, `path` (optional) the folder in it that
holds `profile.toml`, and `ref` a tag, a branch or a 40-hex commit. The ref is required
(`address_needs_ref`). The publisher is the owner; a tag is a version. Owner and repository
are compared case-insensitively; a first segment holding a `.` is refused (`bad_address`),
kept for a host prefix later.

The ref is resolved to a commit (`ref_not_found`, `ref_ambiguous` when a tag and a branch
share the name, `repo_not_found`), the repository at that commit is fetched once into
`~/.cache/sprite-profiles/github/<owner>/<repo>/<sha>/` (`fetch_failed`,
`archive_too_large` over 32 MB, `bad_archive`; `not_cached` under `--offline`), and the
profile is read from `<path>` there by the rules above. With a path, the last segment must
equal `name`; at a repository root the repository's name is free. Only public repositories
can be fetched. `SPRITE_PROFILES_CACHE` (or `XDG_CACHE_HOME`) moves the cache; a commit never
changes, so nothing in it is ever invalidated.

A fetched profile's **qualified name** is `<owner>.<name>` (owner lowercased). It is the
profile's identity in a set, its label is `profile:<owner>.<name>`, its skills land in
`~/.claude/skills/<owner>.<name>--<skill>/`, and `PROFILED_PROFILE` carries it. A local
profile's qualified name is its `name`. Names never contain `.`, so only a repository of
`acme` can yield `profile:acme.linear`. Two picks with one qualified name are refused
(`profile_collision`). A local `linear` beside `acme/profiles/linear@v1` is allowed: their
labels and skills folders differ.

A set with addresses is pinned by `mix profiles.lock`, which writes a **lock file**: the
picks in order and, for each address, the owner, repo, path, ref, commit and name.
`--lock FILE` replaces `--profile` for `plan` and `launch` (giving both is bad usage); a
locked launch uses the commit and never resolves the ref. Re-running `mix profiles.lock`
resolves again and reports each commit that changed. A lock that cannot be read, misses a
field or has a newer `format` is refused (`bad_lock`).

```toml
format    = 1
locked_at = "2026-11-19T10:00:00Z"

[[picks]]
pick = "claude-code"                 # local: resolved on the search path at use

[[picks]]
pick  = "acme/profiles/linear@v1"
owner = "acme"
repo  = "profiles"
path  = "linear"
ref   = "v1"
sha   = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"
name  = "linear"
```

`format = 2` adds inputs, custom API connectors and MCP `auth = "connector"`. A profile
that uses a format-2 field must declare `format = 2` (`needs_format`), so an older
reader refuses it with one `unsupported_format`. A lock holding inputs is `format = 2`:

```toml
[inputs]
readonly = "false"
```

There is no publisher allowlist: a fetched profile's `setup.sh` runs with the Sprite's full
access, like any other. What the set fetches is shown instead: the plan's **Sources**
section, after the apply order and only when the set holds an address, names each address's
publisher, repository, ref, commit and whether it runs a
`setup.sh`, and the launch prints it before any API call and keeps it in the launch record.

### profile.toml

`profile.toml` is TOML 1.0. Every field the format does not define is refused, so a typo is
an error, not a silent no-op.

| field | type | default | meaning |
|---|---|---|---|
| `format` | integer | `1` | the format this profile is written in. A reader refuses a format newer than it knows (`unsupported_format`) before checking any field |
| `name` | string | required | the folder's name (for a fetched profile, the last segment of the address's path; free at a repository root); 2-31 characters of `a-z`, `0-9` and `-`, starting with a letter |
| `summary` | string | required | one line, at most 80 characters |
| `description` | string | `""` | the honest paragraph: what it gives a Sprite and what it costs |
| `privileged` | bool | `false` | `true`: agents may not launch a set holding it, and it is applied after the checkpoint |
| `checkpoint` | bool | `true`, or `false` when privileged | `false`: applied after the checkpoint, never saved in it. A privileged profile may not set `true` |
| `timeout` | string | `"10m"` | how long `setup.sh` may take: a whole number of `s`, `m` or `h`, at most `1h` |
| `labels` | array of strings | `[]` | extra Sprite labels; at most 128 characters of lowercase letters, digits and `. _ : -`. Labels starting `profile:` are reserved |
| `[inputs]` | table of tables | none | values the launcher is given at launch; see below (format 2) |
| `[env]` | table | none | env for the Sprite; see below |
| `[policy]` | table | none | network policy rules; see below |
| `[[connectors]]` | array of tables | none | connectors this profile needs: `{ provider = "github" }` for a catalogue provider, or a custom API connector (format 2); see below |
| `[[services]]` | array of tables | none | Sprites services to create; see below |
| `[claude]` | table | none | `settings` (a Claude Code settings fragment) and `mcp_servers` |

#### inputs

An input is a value the launcher is given at launch, such as a repository, a workspace
or a region. It is **never a secret**: inputs appear in plans, lock files and launch
records. A secret is a connector's or a privileged profile's.

```toml
[inputs.readonly]
summary = "true: only read tools; false: write tools too"   # required, one line, ≤ 80
default = "true"            # optional; absent means the input must be given
pattern = '^(true|false)$'  # optional; matched against the whole value
```

Names are `[a-z][a-z0-9_]{0,30}`. A value is a string of at most 256 characters on one
line. A `default` must match `pattern`. An input reaches the Sprite only through
`[env]`, as `{ from = "input", name = "readonly" }`; an input no env uses is refused
(`input_unused`). Values are given as `--input name=value` (`-i`) to `plan`, `launch`
and `lock`, or by a lock's `[inputs]` table; `--lock` with `-i` is bad usage.

#### env

Keys are uppercase letters, digits and `_`. `PROFILED_PROFILE` and `PROFILED_SET` are
reserved: the launcher sets them for every `setup.sh`. A value is one of:

| value | meaning |
|---|---|
| `"text"` | the value itself |
| `{ from = "connector", provider = "github" }` | the connector's gateway URL, resolved at launch. The profile must also declare that connector |
| `{ secret = "NAME" }` | read at launch from the launching machine, never from the repository. **Only a privileged profile may use it** |
| `{ from = "input", name = "readonly" }` | the input's value, resolved before launch (format 2) |

#### policy

```toml
[policy]
rules = [ { include = "defaults" }, { action = "allow", domain = "api.sprites.dev" } ]
```

A rule is `{ include = "defaults" }` (the Sprites default list) or
`{ action = "allow" | "deny", domain = "example.com" }`. A domain may start with `*.`.

#### connectors

`{ provider = "github" }` names a catalogue provider. A **custom API connector** wraps
any token-authenticated HTTP API or remote MCP server:

```toml
[[connectors]]
provider  = "custom_api"
base_url  = "https://api.githubcopilot.com"              # https, no query
auth      = { method = "header", prefix = "Bearer" }     # the default
endpoints = ["/mcp/"]                                    # /exact or /prefix*; what the profile calls
test_url  = "https://api.github.com/user"                # optional; the credential test
```

`auth.method` is `header` (`prefix`, default `Bearer`; `""` sends the bare token),
`custom_header` (`header`, default `X-Api-Key`), `query_param` (`param`, default
`api_key`) or `url_path` (`template`, holding `{token}`; its `test_url` is then a path,
which Fly joins to the base URL and the token's path). A profile declares at most one
custom API connector (`duplicate_connector`); **its name is the profile's qualified
name**, `github.mcp` for `github/sprite-profiles/mcp@v1`. Env reaches its gateway URL
with `{ from = "connector", provider = "custom_api" }`. The profile holds no token: a
person creates the connector in their org with `mix profiles.connect -p <pick>`, which
reads the token from the terminal, sends it to Fly once, and keeps nothing.

An endpoint is matched as Fly's gateway matches it: `/exact` admits that path alone (a
trailing `/` counts, so `/mcp/` does not admit `/mcp`), and `/prefix*` every path starting
with `prefix`.

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
- `auth = "connector"`: the credential is added by the gateway; the `url` must start with
  `${KEY}` where `KEY` is this profile's connector env.
- `requires_env = ["NAME", ...]`: env the server needs from the set. References like
  `${NAME}` in `url`, `headers`, `env` or `args` count too; `${NAME:-default}` does not.

### What the format does not have

- **No includes.** Composition happens when a set is picked, not inside a profile.
- **No overrides or removals.** A profile only adds, so reading the set from the top tells
  you everything the Sprite gets.
- **No sizes.** Sprites have no size to choose at creation.

## Merging a set

A **set** is an ordered list of picks, each a profile name or an address. Merging a set gives either a **plan** (what
the Sprite will get and in what order) or one or more **refusals**. The rule throughout:
union where that is safe, refusal where two profiles disagree. Nothing is picked silently.

| field | rule | refusal |
|---|---|---|
| `env` | union; a key two profiles define is refused, **even with the same value** | `env_collision` |
| `policy.rules` | union, deduplicated; `include = "defaults"` at most once; every `deny` before every `allow`, so a deny in any profile wins. No profile declares a policy: none is set (the Sprite's default, unrestricted). One does: the union is set, so a profile that needs the network must say so | |
| `connectors` | union: catalogue providers by provider, custom API connectors by name (one per profile). At launch each must match an org connector that admits this Sprite (it allows all Sprites, or this Sprite carries **all** the labels it lists and its name starts with its name prefix, whichever of the two it sets; a policy with neither admits nothing). A custom connector must also cover every declared endpoint (no `allowed_endpoints`, or one that covers it, and no `blocked_endpoints` that overlaps it) and, when the API reports it, have the declared base URL | `connector_missing`, `connector_not_admitted`, `connector_endpoints`, `connector_base_url` |
| `inputs` | union; a name two profiles declare is refused. A required input with no value, a value failing its pattern, or a value for a name no profile declares is refused before any API call | `input_collision`, `input_missing`, `input_invalid`, `input_unknown` |
| `labels` | `profile:<qualified name>` for every pick, then declared labels, deduplicated. So a connector is granted to a *profile*: a connector whose policy names `profile:acme.linear` admits exactly the Sprites carrying acme's `linear`. A Sprite takes labels of up to 128 bytes | `label_too_long` |
| `services` | union; the same name twice is refused; two services with `http_port` are refused, since a Sprite routes its URL to one service | `service_collision`, `http_port_conflict` |
| `claude.mcp_servers` | union; the same name twice is refused. An `http`/`sse` server with no `Authorization` header and neither `auth = "none"` nor `auth = "connector"`, or any server needing env the set does not define, is refused before a Sprite is created: an unattended Sprite cannot answer a sign-in | `mcp_server_collision`, `mcp_needs_login` |
| `claude.settings` | deep merge of tables; a leaf two profiles set to different values is refused (the same value is fine). Arrays are leaves, except the ones Claude Code applies entry by entry: each `hooks.<event>` array and `permissions.allow` / `permissions.deny` **combine**, appending entries in pick order (each entry, such as one profile's hook group, kept whole) and keeping an identical entry once. A leaf in one profile where another has a table is refused. At launch each profile's settings are laid over the Sprite's own `~/.claude/settings.json` by the same rule: combining lists append, other leaves replace the image's | `settings_collision` |
| skills | namespaced `<qualified name>--<skill>`, so they never collide | |
| `files/` | pushed in pick order; the same path from two profiles is refused, as is a file where another profile has a folder (skills count as files here) | `file_collision` |
| `setup.sh` | runs in apply order, each with its own `timeout`, with `PROFILED_PROFILE`, `PROFILED_SET` and the merged env exported; a failure stops the launch | |
| `privileged` | a set holding a privileged profile is privileged: a person may launch it, an agent may not | `not_for_agents` |
| order | pick order, except that privileged profiles (and any with `checkpoint = false`) are applied after the `profiled` checkpoint, so credentials are never in a checkpoint. The plan prints the final order | |
| bounds | 1 to 8 picks, none repeated (an address repeated at another ref counts), every pick a valid name or address; no two with one qualified name | `no_profiles`, `too_many_profiles`, `duplicate_pick`, `bad_name`, `bad_address`, `address_needs_ref`, `profile_collision` |

A pick that names no folder on the search path is refused with `profile_not_found`, one found
in two folders with `profile_ambiguous`; a profile that fails
validation is reported with its validation codes.

### Refusals

A refusal is a code for programs and a full sentence for people. The sentence names every
profile involved and says what to change:

> profiles 'github' and 'claude-code' both define env GITHUB_TOKEN; a set will not pick one
> silently, so remove it from one of them.

A refusal names a fetched profile by its pick as written, `acme/profiles/linear@v1`.

### Validation codes

| code | when |
|---|---|
| `unsupported_format` | `format` is newer than the reader knows; reported alone |
| `needs_format` | a format-2 field in a profile declaring (or defaulting to) format 1 |
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
| `env_input_undeclared` | env from an input the profile does not declare |
| `input_unused` | an input no `[env]` entry uses |
| `duplicate_connector` | two custom API connectors in one profile |
| `reserved_env` | env `PROFILED_PROFILE` or `PROFILED_SET` |
| `reserved_label` | a declared label starting `profile:` |
| `duplicate_service` | two services of one name in one profile |
| `http_port_conflict` | two services with `http_port` in one profile |
| `bad_skill` | a skill that is not a folder, has a bad name, or has no `SKILL.md` |
| `bad_file` | a symlink or special file under `files/` or a skill |
| `unknown_entry` | anything in `claude/` other than `skills/` |

## Launching a set

`mix profiles.launch` (`SpriteProfiles.Launcher`) turns a plan into a Sprite. A launcher in
another language should do the same, in this order:

1. **Resolve locally.** Read the lock or resolve each address, fetch what the cache lacks,
   then merge the set and refuse before any Sprites API call. The plan's Sources section is
   printed first. Two more refusals exist here: `secret_missing` (a privileged profile's
   secret is not on the launching machine) and `bad_sprite_name`.
2. **Check connectors**, only when the set declares one: list the org's connectors and
   apply the rules in the merge table (access policy; for a custom API connector also its
   name, endpoints and base URL). A refusal here creates nothing.
3. **Create the Sprite with its labels** in the create request, then confirm them from the
   answer. If they did not stick, set the whole list again and read it back.
4. **Set the network policy**, when the plan has one. It can only be set from outside the
   Sprite.
5. **Apply each profile**, in plan order. The env file `~/.config/profiled/env.sh` (0600,
   sourced from `~/.bashrc`) is written at the start of each phase: before the checkpoint
   it holds the checkpointed profiles' env, after it everyone's. Then, per profile:
   - push `files/` and skills, with modes 0644 or 0755;
   - lay its `claude.settings` over the Sprite's `~/.claude/settings.json` (combining lists
     append, other leaves replace the image's);
   - register its MCP servers with `claude mcp add-json --scope user`, replacing any of the
     same name;
   - run `setup.sh` under a Sprites Task hold named `profiled-setup-<qualified name>`, with
     `.` written `--` since a Task name takes only `a-z`, `0-9` and `-`; extended
     every 60 s and released when the script ends, within its `timeout`, with
     `PROFILED_PROFILE`, `PROFILED_SET` and the env file loaded;
   - create its services (`~` in `dir` is expanded), each with that phase's env, the set
     the env file holds. Services come after `setup.sh`, so a service may run what the
     script installed.
6. **Checkpoint** with the comment `profiled: <set>`.
7. **Apply the privileged and `checkpoint = false` profiles** the same way. They are never in
   a checkpoint.
8. **Record** the launch: the steps with their times, the labels and how they were set, the
   policy, the env keys (never values), the inputs (name and value), the sources (pick,
   owner, repo, path, ref, commit)
   and the checkpoint id, as JSON under
   `~/.local/state/sprite-profiles/launches/`.

A failed step stops the launch. The Sprite is left for inspection unless
`--destroy-on-failure` was given.

## Connecting a company's API

`mix profiles.connect -p <pick>` creates or updates, in your org, the custom API
connector a profile declares: name `<qualified name>`, its base URL, auth method and
`test_url`, and an access policy that admits Sprites labelled `profile:<qualified
name>` and allows the declared endpoints. The token is read from the terminal with echo
off, sent to Fly once and never printed, logged or stored; the command refuses to run
without a terminal (`needs_terminal`), takes no token flag, and is a person's, never an
agent's. Running it again rotates the token and rewrites the policy. With a `test_url`,
it then asks Fly to test the stored credential and reports the result. A pick that
declares no custom API connector is refused (`no_custom_connector`).
