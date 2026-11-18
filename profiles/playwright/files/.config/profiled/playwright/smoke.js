// Loads a page in headless Chromium and prints its title: proof that the browser starts and
// that the Sprite's network policy lets it reach the page.
// Usage: NODE_PATH="$(npm root -g)" node ~/.config/profiled/playwright/smoke.js [url]
const { chromium } = require("playwright");

const url = process.argv[2] || "https://example.com";

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  await page.goto(url);
  console.log(`title: ${await page.title()}`);
  await browser.close();
})().catch((e) => {
  console.error(`smoke test failed: ${e.message.split("\n")[0]}`);
  process.exit(1);
});
