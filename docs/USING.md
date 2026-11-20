# Using profiles

Plan a set, find published profiles, pin a project's set, and launch it. Planning needs no
Sprite and no token; launching needs the [`sprite` command](https://docs.sprites.dev),
signed in. From a checkout, every command here is also a Mix task: `mix profiles.plan -p
claude-code` is `sprite-profiles plan claude-code`.

## Plan a set

The bundled profiles ship inside the binary.

```sh
sprite-profiles plan claude-code playwright
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
  allow console.anthropic.com
  allow platform.claude.com
  allow cdn.playwright.dev
  allow example.com

Env:
  DISABLE_AUTOUPDATER = "1"  (claude-code)

Services: none

MCP servers:
  context7 (http) https://mcp.context7.com/mcp  (claude-code)
...
```

Name the profiles in the order they should apply (`-p NAME` works too, as in the Mix tasks).
A refused set exits 1 and prints one line per refusal: a code in brackets for programs, then
a sentence for people. `--agent` judges the set as an agent would launch it.

The bundled profiles are listed in the [README](../README.md#install-and-a-30-second-start).
`github` needs a GitHub connector in your org whose access policy names the label
`profile:github`. Without one, the launch is refused before anything is created.

## Find a profile

Published profiles are git repositories that follow a naming convention, so nothing is
hosted. Search GitHub for them:

```
$ sprite-profiles search shop
@antialias/shop-inventory  1.0.0  ★0  A woodworking shop's tool inventory over MCP, read-only; no key in the Sprite · connector woodworking.haunt.house /mcp, allows api.sprites.dev
See one in full with: sprite-profiles show @antialias/shop-inventory
```

Each line ends with what the profile can touch. `sprite-profiles show @antialias/shop-inventory`
prints all of it: the connector and its endpoints, the network rules, MCP servers, env,
skills, whether it runs a `setup.sh`, and whether it is privileged.

Pick a published profile by name. `@antialias/shop-inventory` is the newest version;
`@antialias/shop-inventory@1` the newest 1.x, as are `@1.2` and `@1.2.3` at their level; a
branch or a commit (`@main`) works while a profile is in development.

## A project's set

```sh
sprite-profiles add claude-code @antialias/shop-inventory
sprite-profiles lock
sprite-profiles launch --lock sprite-profiles.lock --name demo-2
```

`add` writes `sprite-profiles.toml`, this project's set, with each name at its major
version (`@1`), like npm's `^`. In a folder holding that file, `plan`, `lock` and `launch`
take no picks. `lock` writes `sprite-profiles.lock` ([below](#by-address)); commit both.
`sprite-profiles remove` takes a profile out of the file.

A pick starting with `./`, `../`, `/` or `~/` is a path to a profile folder, so a project's
own profile composes with published and bundled ones without changing the search path; in
`sprite-profiles.toml` it is relative to that file's folder:

```sh
sprite-profiles launch claude-code @antialias/shop-inventory ./weekend --name demo
```

## By address

A profile can also be picked by its address, in the form GitHub Actions uses:
`owner/repo/path@ref`. The ref is a tag, a branch or a commit, and it is required. This
repository's own `preview`, fetched from GitHub:

```sh
sprite-profiles plan claude-code antialias/sprite-profiles/profiles/preview@main
```

The plan gains a Sources section, so you see where the code comes from before it runs:

```
Sources:
  antialias/sprite-profiles/profiles/preview@main  publisher antialias, repo antialias/sprite-profiles, main = 60deb823, no setup.sh

Labels:
  profile:claude-code
  profile:antialias.preview
```

A fetched profile is named for its publisher: its label is `profile:antialias.preview`, not
`profile:preview`. A label follows how the profile is picked, so only a repository owned by
`antialias` can give that label, and a connector granted to it stays with it.

Fetching a public GitHub repository needs no token and no `git`. A private one, a very large
one, or one on another git host (`git.example.com/team/profiles/linear@v1`) is fetched with
`git`, through the credentials your git already has. What is fetched is kept once per commit
in `~/.cache/sprite-profiles/`. A branch moves, so pin the set before you launch it:

```sh
sprite-profiles lock claude-code antialias/sprite-profiles/profiles/preview@main
sprite-profiles launch --lock sprite-profiles.lock --name demo-3
sprite-profiles plan --lock sprite-profiles.lock --offline
```

`sprite-profiles lock` writes `sprite-profiles.lock`: the set, with every name and address
pinned to a commit, and each name's version. A launch from the lock uses those commits and
looks nothing up. Run `lock` again to move to the newest versions and commits; it prints
each one that changed. `--offline` calls nothing, and works once the commits are cached.

A fetched profile's `setup.sh` runs with the Sprite's full access, like your own. Read the
Sources section before you launch.

## Launch a Sprite

You need the [`sprite` CLI](https://docs.fly.io/sprites/quickstart.md), logged in. The
launcher runs it for you and never reads or prints your token.

```sh
sprite-profiles launch claude-code anthropic github-mcp playwright preview ./weekend --name demo
sprite-profiles exec demo claude -p "Build the weekend page."   # run something inside
sprite checkpoint list -s demo
sprite destroy --force demo                                      # when you're done
```

It prints a line for the Sprite, then one per profile as it finishes, with the time it took
and what it added, then the last line with the Sprite's URL:

```
✓ Sprite demo    1.9 s  2 connectors admitted · network policy · 6 env vars
✓ claude-code    4.6 s  setup · MCP context7 · hooks · 1 setting · 1 skill · 1 file
✓ anthropic      0.3 s  connector api.anthropic.com
✓ github-mcp     1.6 s  connector api.githubcopilot.com · MCP github · 1 skill
✓ playwright    41.0 s  setup · 1 file
✓ preview        5.8 s  service preview :8080 · 1 file
✓ ./weekend      1.3 s  9 permissions · 1 skill
✓ demo: 6 profiles · checkpointed · 57.9 s
  https://demo-b6mfx.sprites.app
```

While a profile's `setup.sh` runs, its output shows under a `… <profile>` line (the last ten
lines, dimmed), so you can act on what it asks, such as a sign-in's address and code; when it
finishes, those lines give way to the profile's ✓ line. When the output is not a terminal (a
pipe, an agent), nothing is erased: the setup lines are printed indented, then the ✓ line. A
failed step prints a ✗ line with its error and its last 20 lines of output, and how to
destroy the Sprite. `--verbose` prints every step with its time instead, the setup output as
it comes, and a summary (labels, checkpoint id, the launch record's path).

`sprite-profiles exec NAME CMD [ARG ...]` runs a command in the Sprite in a login shell, so
the profiles' env and shell hooks apply, with each argument passed as it is. It prints the
output as it comes and exits with the command's status; standard input is not passed on.
Everything after NAME belongs to the command, options and all.

The launch, step by step:

1. Merge the set, and refuse before any API call.
2. If the set needs a connector, check that one in the org admits it.
3. Create the Sprite, with a `profile:<name>` label for every pick (`profile:<owner>.<name>`
   for a published one).
4. Set the network policy.
5. Apply each profile in order: files, skills, Claude settings, MCP servers, then `setup.sh`
   (holding a Sprites Task so the Sprite stays awake, and showing its output as it runs),
   then services.
6. Checkpoint it as `profiled: claude-code+preview`.
7. Apply privileged profiles, after the checkpoint.

`--dry-run` stops after step 1. `--destroy-on-failure` removes the Sprite if a later step
fails; otherwise it is left for you to inspect. A record of each launch goes to
`~/.local/state/sprite-profiles/launches/`, outside the repository.

A privileged profile's secret is read on your machine from
`~/.config/sprite-profiles/secrets/<NAME>` (one line, `chmod 600`), or from the folder
`--secrets-dir` names. It is never in a profile. On a server without the CLI,
`--adapter api` calls the Sprites API with the org token in `SPRITES_TOKEN`; so far that path
is tested against a stub only.
