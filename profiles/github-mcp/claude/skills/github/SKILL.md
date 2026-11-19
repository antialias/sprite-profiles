---
name: github
description: How to work with GitHub from this Sprite. Use for any GitHub repository, issue or pull request task.
---

# GitHub through the `github` MCP server

This Sprite reaches GitHub through GitHub's remote MCP server, registered in Claude Code as
`github`. It is reached through a connector: the Sprites gateway adds the credential, and
the Sprite never holds a GitHub token.

- Use the `github` MCP server's tools for repositories, issues and pull requests.
- Never ask the user for a GitHub token, never create one, and never set or write one.
- The tools on offer follow two settings chosen at launch: `GITHUB_MCP_TOOLSETS` (empty
  means GitHub's default set) and `GITHUB_MCP_READONLY` (`true` offers read tools only).
  If a tool you need is missing or a call is refused, say which and stop; the person who
  launched the Sprite changes the inputs or the token's permissions. Do not work around it.
