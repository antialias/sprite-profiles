# Inputs and a company's API

Some values differ for each person who launches a profile but aren't secrets: a repository,
a region, a mode. A profile declares them as inputs, and you give them with `-i` when you
plan, lock or launch. An input reaches the Sprite only through `[env]`, and it shows in the
plan, the lock and the launch record, so it must never be a secret.

A company's API needs a token, which is a secret. A profile doesn't hold it. Instead it
declares a custom API connector, and each person puts their own token in a connector in their
own org. The Sprite calls the API through the Sprites gateway, which adds the token, so the
Sprite never sees it. The profile has no secret and isn't privileged, so an agent may launch
it.

## An example: GitHub's MCP server

The bundled `github-mcp` does this for GitHub's remote MCP server. Its connector and inputs:

```toml
format = 2

[inputs.readonly]
summary = "true: only read tools; false: write tools too (the token must allow them)"
default = "true"
pattern = '^(true|false)$'

[env]
GITHUB_MCP_URL      = { from = "connector", provider = "custom_api" }
GITHUB_MCP_READONLY = { from = "input", name = "readonly" }

[[connectors]]
provider  = "custom_api"
base_url  = "https://api.githubcopilot.com"
endpoints = ["/mcp/"]
test_url  = "https://api.github.com/user"

[claude.mcp_servers.github]
type = "http"
url  = "${GITHUB_MCP_URL}/mcp/"
auth = "connector"            # the gateway adds the credential
headers = { X-MCP-Readonly = "${GITHUB_MCP_READONLY}" }
```

(The real file has a second input, `toolsets`.) Make a fine-grained GitHub token with only
the repositories and permissions you want agents to have, then create the connector once, in
a terminal:

```sh
sprite-profiles connect github-mcp
```

It prints what it will create, then asks for the token with echo off and sends it to Fly
once. The connector is named for the profile (`github-mcp`, or `<owner>.github-mcp` for a
published copy), and its access policy admits only Sprites labelled `profile:github-mcp`,
calling only `/mcp/`. Fly then tests the token against `test_url`. Run it again to change the
token. There is no flag for the token and it won't run without a terminal: this command is a
person's, never an agent's.

Then launch, choosing the inputs:

```sh
sprite-profiles launch claude-code github-mcp -i readonly=true --name demo-4
```

Before it creates anything, the launcher checks that the org has the connector, that its
policy admits this Sprite, that it allows every endpoint the profile declares, and that it
points at the profile's base URL. If any of those fail, it refuses and names the command that
fixes it.

The bundled `anthropic` and the published
[`@antialias/shop-inventory`](https://github.com/antialias/sprite-profile-shop-inventory) work
the same way, for Anthropic's API and a shop's MCP server.
[SPEC.md](SPEC.md#connecting-a-companys-api) has the connector fields.
