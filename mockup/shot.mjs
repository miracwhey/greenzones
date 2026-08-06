import { chromium } from "playwright";

const out = process.argv[2] ?? "shot.png";
const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
});
await page.goto("file://" + new URL("./index.html", import.meta.url).pathname);
await page.waitForFunction(() => window.__MAP_READY__ === true, null, { timeout: 30000 });
await page.waitForTimeout(800);
await page.screenshot({ path: out });
await browser.close();
console.log("written:", out);
