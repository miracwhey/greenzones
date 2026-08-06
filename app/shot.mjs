import { chromium } from "playwright";

const url = process.argv[2];
const out = process.argv[3] ?? "shot.png";
if (!url) { console.error("usage: node shot.mjs <url> [out.png]"); process.exit(1); }

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
});
page.on("console", m => { if (m.type() === "error" || m.type() === "warning") console.error("[console]", m.text()); });
page.on("pageerror", e => console.error("[pageerror]", e.message));
page.on("requestfailed", r => console.error("[reqfail]", r.url().slice(0, 120), r.failure()?.errorText));
await page.goto(url);
try {
  await page.waitForFunction(() => window.__MAP_READY__ === true, null, { timeout: 30000 });
} catch {
  console.error("[timeout] __MAP_READY__ never set — screenshotting anyway");
}
await page.waitForTimeout(800);
await page.screenshot({ path: out });
await browser.close();
console.log("written:", out);
