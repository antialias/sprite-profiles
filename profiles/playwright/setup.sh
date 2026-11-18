#!/usr/bin/env bash
# Measured on fresh Sprites in milestone M3: see docs/RESULTS.md.
# Idempotent: npm and Playwright skip what is already installed.
set -euo pipefail

npm install -g playwright
npx playwright install --with-deps chromium

echo "playwright: $(npx playwright --version)"

# Prove Chromium starts headless and the network policy lets it load a page.
NODE_PATH="$(npm root -g)" node "$HOME/.config/profiled/playwright/smoke.js" https://example.com
