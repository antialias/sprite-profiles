#!/usr/bin/env bash
# Untested: written before the launcher exists; first run on a Sprite is milestone M3,
# where its time on a fresh Sprite is measured.
# Idempotent: npm and Playwright skip what is already installed.
set -euo pipefail

npm install -g playwright
npx playwright install --with-deps chromium

echo "playwright: $(npx playwright --version)"
