---
name: weekend-page
description: Build and serve the shop's "What can I build this weekend?" page from its real inventory. Use when asked for the weekend page or weekend projects.
---

# The weekend page

Build one page that answers **"What can I build this weekend?"** for the shop, and serve it.
The shop's inventory is the `shop` MCP server and GitHub is the `github` one, both read-only.
Neither key is in this Sprite: Fly's connector gateway adds them on the way out.

1. **Read the shop** with `shop`: `get_meta` first, then `search_items`, `get_item` and
   `list_unknowns` as needed. Learn which tools and battery platforms it really has, and
   their specs.
2. **Three projects** suited to these tools, from an afternoon one to a whole weekend. For
   each: what it is, the steps in a few lines, the shop's tools it uses by their names in
   the inventory (with a spec that matters, such as a capacity or a kerf), and anything it
   needs that the shop lacks. Ground every tool claim in the inventory; if a spec is marked
   verify, say so.
3. **Footer.** From `github`, the latest commit on `antialias/sprite-profiles` (main): short
   sha, first line and date, shown as "Set up by sprite-profiles @ <sha>".
4. **How this page was made**, a small table with what each result means, in a sentence:
   - `env | grep -iE 'token|bearer|secret|api_key' | cut -d= -f1`: the names of the variables
     that look like a credential. Names only: never print a value.
   - `echo "$ANTHROPIC_API_KEY"`: the model's key as this Sprite holds it.
   - `curl -s -m 8 -o /dev/null -w '%{http_code}' https://woodworking.haunt.house/mcp`: the
     shop called directly rather than through the gateway (`000` means the Sprite's network
     policy stopped it).
   - `curl -s -m 8 -o /dev/null -w '%{http_code}' "$SHOP_INVENTORY_URL/api/anything"`: the
     gateway asked for a path other than `/mcp`.
   Never show a gateway URL or an id.
5. **One self-contained file**, `~/site/index.html`: inline CSS, no web fonts, scripts or
   images (the network policy blocks most of the web). Mobile-first, easy to read, with a
   little workshop character. The `preview` service already serves `~/site` on port 8080.
6. **Check it**: `curl -s localhost:8080 | head -5`, then a phone-sized screenshot with
   `npx playwright screenshot --viewport-size=390,844 --full-page http://localhost:8080 ~/site/screenshot.png`.
7. Call it "the shop". Never name its owner or anyone in the household, and leave out the
   household's bikes. No prices, serial numbers or locations: the token can't see them, so
   don't guess them.
8. When done, your whole reply is one plain sentence under 90 characters: no list, no
   markdown, no details (they are on the page).
