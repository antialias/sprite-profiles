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
