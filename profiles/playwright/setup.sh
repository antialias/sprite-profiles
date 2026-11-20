#!/usr/bin/env bash
# Measured on fresh Sprites in milestone M3: see docs/RESULTS.md.
# Idempotent: npm and Playwright skip what is already installed.
set -euo pipefail

# The installs print hundreds of progress lines; keep them in a log and show it only on failure.
log="$(mktemp)"
quiet() { "$@" >>"$log" 2>&1 || { tail -40 "$log"; exit 1; }; }
echo "Installing Playwright and Chromium with its system libraries"
quiet npm install -g playwright
quiet npx playwright install --with-deps chromium
rm -f "$log"

echo "playwright: $(npx playwright --version 2>/dev/null)"

# Prove Chromium starts headless and the network policy lets it load a page.
NODE_PATH="$(npm root -g)" node "$HOME/.config/profiled/playwright/smoke.js" https://example.com
