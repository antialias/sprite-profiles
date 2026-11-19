# Results: the example profiles on real Sprites

Measured on 2026-11-18 with `mix profiles.launch` and the `sprite` CLI adapter, each on a
fresh Sprite that was destroyed afterwards. Times are the launcher's own, per step, from the
laptop: each includes one CLI round trip to the Sprites API.

## Step timings

| step | claude-code + preview | claude-code + anthropic-key | claude-code + playwright |
|---|---:|---:|---:|
| create (labels in the request) | 0.64 s | 0.53 s | 0.82 s |
| policy | 0.34 s | 0.39 s | 0.68 s |
| prepare | 0.64 s | 0.76 s | 1.93 s |
| env (checkpointed) | 0.30 s | 0.31 s | 0.53 s |
| claude-code: files, settings, MCP, setup | 3.53 s | 3.80 s | 4.24 s |
| second profile, before the checkpoint | 6.02 s (service 5.44 s) | | 36.86 s (setup 36.27 s) |
| checkpoint `profiled: …` | 0.36 s | 0.42 s | 3.82 s |
| after the checkpoint (privileged env) | | 0.43 s | |
| **total** | **11.82 s** | **6.65 s** | **48.88 s** |

The playwright column is the recorded launch ([launch.cast](launch.cast)). Over four
launches of `claude-code + playwright` the numbers were:

| | min | median | max |
|---|---:|---:|---:|
| playwright `setup.sh` | 36.3 s | 44.5 s | 53.1 s |
| checkpoint | 2.4 s | 3.7 s | 4.1 s |
| total | 48.9 s | 54.5 s | 64.7 s |

Restoring that Sprite's `profiled` checkpoint took **3.9 s**, and the smoke test (headless
Chromium loading a page) passed 3.2 s later, on the first try.

`claude-code + github` was refused before anything was created (`connector_missing`): the
org had no GitHub connector. Nothing about it is measured yet.

## What was verified

- **playwright.** `setup.sh` installs Playwright and Chromium with its system packages, then
  loads https://example.com in headless Chromium and prints `title: Example Domain`. Beyond
  the Sprites defaults (which already cover npm and the Ubuntu archive), the policy needs
  `cdn.playwright.dev` for the browser download, and an allow rule for each page the browser
  visits: without `example.com` the page load fails with `net::ERR_NAME_NOT_RESOLVED`.
  Playwright's fallback mirror was not needed and is not in the policy.
- **anthropic-key** (with a dummy value, not a real key). After the launch the env file held
  `ANTHROPIC_API_KEY` and a login shell saw the value. After restoring the
  `profiled: claude-code+anthropic-key` checkpoint, the env file held no `ANTHROPIC_API_KEY`
  and no file under the home folder contained the value: the secret was never in the
  checkpoint. `mix profiles.plan … --agent` refused the set (`not_for_agents`).
- **preview.** The service answered on port 8080 inside the Sprite.

## What the numbers argue

The light profiles cost a few seconds: most of a launch is round trips, and creating a
service blocks about 5 s. The heavy one is different in kind. Playwright's setup took 36 to
53 s on a fresh Sprite, every time, while restoring a checkpoint that already holds it took
about 4 s. A checkpoint can only be restored into the Sprite that took it, though, so every
new Sprite pays the full setup again. Starting a new Sprite from a checkpoint would turn the
heavy part of a launch into a restore, and leave only the light, per-person profiles
(credentials, connectors, skills) to apply. Those are the ones that must stay out of
checkpoints anyway, which is what the post-checkpoint rule for privileged profiles is for.

## A company's credential, without a privileged profile

Tested on 2026-11-19 on two fresh Sprites, with Fly's custom API connector, which wraps any
token-authenticated HTTP API and can be created through the API. The "company" was an echo
service (httpbin.org) and the token a dummy value. The connector's access policy admitted
Sprites labelled `profile:spike-echo`, allowed the paths `/anything/*` and `/bearer`, and
blocked `/anything/blocked/*`.

| from | call | answer |
|---|---|---|
| a Sprite carrying the label | `/anything/hello` | 200; the echo showed `Authorization: Bearer <the dummy token>`, added by the gateway |
| | `/anything/blocked/x` | 403 `endpoint is blocked by policy` |
| | `/get` | 403 `endpoint is not in allowed list` |
| a Sprite without the label | every path | 403 `sprite is missing required labels: profile:spike-echo`; the gateway's list showed it no connector |

Neither Sprite's environment held the token.

A second custom API connector pointed at a remote MCP server (Context7, with the dummy token
in a header it ignores). In the labelled Sprite, `claude mcp add --transport http` with the
gateway URL, then `claude mcp list`, reported the server `✔ Connected`; its reply streamed
through the gateway as `text/event-stream`.

So a company's API, and its remote MCP server, can reach a Sprite through a connector granted
to that company's profile label, with the paths it may call listed in the connector's policy.
A profile for a company then holds no secret, need not be privileged, and an agent may launch
it. The format already covers the Sprite's side: env `{ from = "connector", ... }` gives the
gateway URL, and an MCP server's `url` may use `${NAME}`. What it lacks is a way to name a
custom API connector, since every one of them has the provider `custom_api`.

Not shown:

- An MCP server that keeps a session (`Mcp-Session-Id`); Context7 does not.
- An MCP server that accepts only an OAuth sign-in. A custom API connector holds a token and
  can't run a sign-in. Fly's catalogue has OAuth connectors for some companies (Slack,
  GitHub, Notion and Neon among about fifty); whether those reach a company's MCP server was
  not tested.
- A tool that reads a token from its env and calls the company's own host, as many CLIs do.
  It works through the gateway only if its base URL can be changed; otherwise its profile
  stays privileged.

## Profiles by address

Tested on 2026-11-19 on two fresh Sprites, destroyed afterwards.

**Labels.** Labels were set with `sprite config update --clear-labels --label ...` and read
back with `sprite info`.

| label | result |
|---|---|
| `profile:acme.linear` (with a `.`), set at create | accepted, read back as written |
| a 64-character `profile:...` label | accepted |
| an 80-character label | accepted |
| a 128-character label | accepted |
| a 129-character label | refused: `label at index 1 must be at most 128 bytes` |
| a 200-character label | refused, the same way |

So a dotted label is fine, and the limit is 128 bytes. The launcher used to stop at 63
characters, a guess; it now takes up to 128. A published profile's label is at most 79
characters (a GitHub owner is at most 39, a name 31), so `label_too_long` is a guard that
real addresses don't reach.

**Skills in a folder with a `.`.** Claude Code 2.1 on the Sprite was not signed in, so it
couldn't be asked to list its skills. Its debug log counts the skills it loads, though. With
`~/.claude/skills/acme.linear--demo/SKILL.md` beside the two skills the Sprite ships with,
it loaded 4 user skills; with that folder moved away, 3. It counted the folder with or
without a `name:` in the front matter. So skills keep the qualified name,
`<owner>.<name>--<skill>`.

**Task holds.** The first launch below showed one thing the design had missed: the Sprites
Task API refuses a `.` in a task name (`task name must contain only lowercase letters,
numbers, and dashes`). The hold for the published profile's `setup.sh` failed, quietly, and
the script ran anyway, without a hold. The runner now writes the `.` as `--`
(`profiled-setup-antialias--claude-code`). After the fix the hold was granted.

**A locked launch.** The set was this repository's `claude-code`, fetched by address, plus
the local `preview`:

```sh
mix profiles.lock -p antialias/sprite-profiles/profiles/claude-code@main -p preview
mix profiles.launch --lock sprite-profiles.lock --name <a test name>
mix profiles.plan --lock sprite-profiles.lock --offline
```

| step | time |
|---|---:|
| `mix profiles.lock`, empty cache (resolve, download, extract, plan) | 3.9 s |
| `mix profiles.lock` again, commit cached (resolve only) | 3.1 s |
| launch from the lock, second run (step times below) | 11.0 s |
| `mix profiles.plan --lock ... --offline` | 0.4 s |

For scale, a plan of local profiles takes 0.4 s, Mix's start included. The rest of a lock
is the calls to GitHub; it was not broken down further. The launch's steps:

| step | time |
|---|---:|
| create (labels in the request) | 0.35 s |
| policy | 0.35 s |
| prepare | 0.59 s |
| env | 0.45 s |
| `antialias.claude-code`: files, settings, MCP, setup | 2.92 s |
| `preview`: files, service | 6.02 s (service 5.38 s) |
| checkpoint | 0.28 s |
| **total** | **10.97 s** |

That is the same as the local `claude-code + preview` launch above (11.8 s): a launch from a
lock makes no request to GitHub, and the cached commit is read like a local folder.

On the Sprite: its labels were `profile:antialias.claude-code` and `profile:preview`; the
skill was at `~/.claude/skills/antialias.claude-code--profiled/`, and Claude Code loaded it;
`claude mcp list` showed `context7` connected; `~/work` was trusted; the preview service
answered 200; the launch record held the source (pick, owner, repo, path, ref, commit). The
plan printed the Sources section before the first API call.

Offline: with the commit cached, `--offline` planned the set in 0.4 s and a dry-run launch
passed. With an empty cache, `--offline` refused it (`not_cached`), naming the cache path.
The tests check that a locked plan or launch makes no ref lookup.

Not shown: a private repository (not supported), a tag (the live check used a branch; tags,
annotated tags and a tag that moves are covered by tests against a stub).

## Inputs and a custom API connector, end to end

Tested on 2026-11-19 on one fresh Sprite, destroyed afterwards, with the setup of "A
company's credential" above: httpbin.org as the company, and a dummy token. The throwaway
profile (outside the repository) declared a custom API connector to `https://httpbin.org`
with `endpoints = ["/anything/*"]` and a `test_url`, a required input `greeting` with a
pattern, env from both, a service, and an MCP server with `auth = "connector"` whose
header came from the input.

**Creating the connector.** The function `mix profiles.connect` calls created it, and Fly's
credential test answered `ok` (`HTTP 200 — Connection OK`). The listing gave the name as
`provider_account_name`, the policy as written (`sprite_labels`, `allowed_endpoints`), and
in `provider_info` the base URL as `base_api_url`, with `auth_method`,
`auth_header_prefix`, `test_url` and the description. So the launcher's base-URL check
runs; it is not skipped. Running `mix profiles.connect` again, in a pseudo-terminal, updated
the same connector in place (same id, new `updated_at`). The token was not echoed and does
not appear in the session's transcript. With standard input not a terminal, the command
refused (`needs_terminal`) before asking.

Under Mix, `:io.get_password/0` answers `{:error, :enotsup}`: Mix runs without an Erlang
shell, in cooked mode. In raw mode it reads a line without echoing it, so the command
switches to raw mode for the token and back afterwards.

**The launch**, with `-i greeting=...`:

| step | time |
|---|---:|
| connectors (list, check name, policy, endpoints, base URL) | 0.36 s |
| create (labels in the request) | 0.61 s |
| policy | 0.33 s |
| prepare | 0.70 s |
| env | 0.23 s |
| MCP server | 1.38 s |
| service | 5.35 s |
| checkpoint | 0.29 s |
| **total** | **9.25 s** |

Inside the Sprite:

- The env file held the gateway URL and the input's value. The service, which wrote its
  own environment to a file when it started, had the same two variables: services now get
  their phase's env.
- A call to the gateway URL reached httpbin, whose echo showed `Authorization: Bearer
  <the dummy token>`, added by the gateway.
- **Client headers pass through.** The same call carried `X-MCP-Toolsets: repos,issues`,
  `X-MCP-Readonly: true` and the input as `X-Greeting`, and httpbin echoed all three. So
  inputs can reach a remote MCP server as request headers, as the `github-mcp` example
  needs.
- **Response headers come back.** With the policy widened for a moment to httpbin's
  `/response-headers`, a call asking for `Mcp-Session-Id: sess-123` got that header back
  through the gateway. Whether a real MCP server's session then works was not tested.
- A path outside the policy (`/get`) answered 403 `endpoint is not in allowed list`.
- The token was in none of: the shell's environment, the env file, `~/.claude.json`, the
  service's environment.
- Claude Code registered the MCP server with `${ECHO_URL}` and `${ECHO_GREETING}` as
  written; they are expanded from the environment when Claude Code runs. httpbin is not
  an MCP server, so `claude mcp list` was not part of this check.

**Exact endpoints.** With the policy narrowed to `/anything/exact/`:

| path called | answer |
|---|---|
| `/anything/exact/` | 200 |
| `/anything/exact` | 403 |
| `/anything/exact/more` | 403 |

An exact pattern admits that path alone, trailing slash included. Claude Code calls an
MCP server's URL as written, so the `github-mcp` example now declares the exact `/mcp/`
rather than `/mcp/*`.

**Refusals**, each with nothing created:

| how | code |
|---|---|
| before the connector existed | `connector_missing`, naming `mix profiles.connect -p m6echo` |
| no `-i greeting` | `input_missing` |
| `-i greeting=KIA ORA` (fails the pattern) | `input_invalid` |
| policy narrowed to `/anything/exact/` | `connector_endpoints` |
| policy's label changed to another profile's | `connector_not_admitted` |
| the profile's `base_url` changed to `https://httpbin.org/anything` | `connector_base_url` |

The connector was then deleted (`DELETE /v1/oauth/connections/<id>` answered 204).

The real company's version of this check follows.

## GitHub's MCP server, through a connector

Tested on 2026-11-19 on one fresh Sprite, destroyed afterwards. The owner made a
fine-grained GitHub token (read-only, 7 days) and stored it in a custom API connector named
`github-mcp`: base URL `https://api.githubcopilot.com`, Bearer header, test URL
`https://api.github.com/user`, admitting Sprites labelled `profile:github-mcp` on
`/mcp/*`. The token went from the owner's clipboard to Fly in one command and was never
shown. Fly's credential test answered `ok` (`HTTP 200 — Connection OK`, 287 ms). The
connector predates `mix profiles.connect` and allows `/mcp/*` where the example declares
`/mcp/`; the launch admitted it, since `/mcp/*` covers `/mcp/`.

    mix profiles.launch -p claude-code -p github-mcp -i readonly=true -i toolsets=repos,issues --name <sprite>

| step | time |
|---|---:|
| connectors | 0.38 s |
| create | 0.88 s |
| claude-code (policy, files, settings, MCP, setup) | 4.34 s |
| github-mcp (skill, MCP server) | 2.03 s |
| checkpoint | 0.55 s |
| **total** | **9.80 s** |

Inside the Sprite:

- `claude mcp list` showed `github: ${GITHUB_MCP_URL}/mcp/ (HTTP) - ✔ Connected`, next to
  context7.
- `initialize` through the gateway returned an `Mcp-Session-Id`, and the calls that sent it
  back worked: the session round-trip passes the gateway in both directions.
- With `X-MCP-Toolsets: repos,issues` and `X-MCP-Readonly: true`, as the inputs set them,
  `tools/list` gave 19 tools, all reads. With the readonly header set to `false`, 29,
  among them `create_branch`, `push_files` and `delete_file`. So both headers reach GitHub,
  and the input decides what Claude Code is offered. (The token is read-only too, so a write
  would be refused by GitHub either way.)
- A `tools/call` of `list_commits` on this repository returned its three latest commits.
- `/mcp` without the slash answered 403; Claude Code never called it.
- No token-shaped string was in the shell's environment, the env file or `~/.claude.json`.

Not shown: a model driving the server from inside the Sprite (`claude -p` needs model
access, which `claude-code` alone does not give), and an MCP server that only accepts OAuth.
