import { chromium } from "playwright";

// Usage: node shot-any.mjs <file.html?query> <out.png>
const src = process.argv[2] ?? "index.html";
const out = process.argv[3] ?? "shot.png";
const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
});
const [file, query] = src.split("?");
await page.goto("file://" + new URL("./" + file, import.meta.url).pathname + (query ? "?" + query : ""));
await page.waitForFunction(() => window.__MAP_READY__ === true, null, { timeout: 30000 });
await page.waitForTimeout(800);
await page.screenshot({ path: out });
await browser.close();
console.log("written:", out);
