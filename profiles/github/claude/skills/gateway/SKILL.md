---
name: gateway
description: How to reach GitHub from this Sprite. Use for any GitHub API call, clone, push or pull request.
---

# GitHub through the connector gateway

This Sprite reaches GitHub through the Sprites connector gateway. The gateway adds the
credentials; the Sprite never holds a GitHub token.

- Send GitHub API requests to `$GITHUB_GATEWAY_URL` in place of `https://api.github.com`,
  with the same paths, for example `curl -s "$GITHUB_GATEWAY_URL/user"`.
- Never ask the user for a GitHub token, never create one, and never write one to disk.
- If a call is refused for scope, list the gateway's connections with
  `curl -s https://api.sprites.dev/v1/gateway/list` and tell the user which scope to
  grant at the `request_scopes_url` it gives. Do not work around it.
