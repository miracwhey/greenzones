import { chromium } from "playwright";

// usage: node shot_bar.mjs <url> <out.png> <idle|detail|target> [dark]
// Interaktions-Screenshots der Status-Bar: Detail per Bar-Tap, Ziel per Such-Flow.
const [url, out, state = "idle", ...flags] = process.argv.slice(2);
const dark = flags.includes("dark");

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  colorScheme: dark ? "dark" : "light",
});
page.on("pageerror", (e) => console.error("[pageerror]", e.message));
page.on("console", (m) => {
  if (m.type() === "error" && !m.text().includes("GL Driver")) console.error("[console]", m.text());
});
await page.addInitScript(() => localStorage.setItem("gz_onboarded", "1"));
await page.goto(url);
await page.waitForFunction(() => window.__MAP_READY__ === true, null, { timeout: 30000 });
await page.waitForTimeout(1500);

if (state === "detail") {
  await page.click(".bar");
  await page.waitForTimeout(700);
} else if (state === "target") {
  await page.fill(".search input", "Küchengarten");
  await page.waitForSelector(".search-row", { timeout: 15000 });
  await page.dispatchEvent(".search-row", "pointerdown");
  await page.waitForTimeout(2500);
}

await page.screenshot({ path: out });
await browser.close();
console.log("written:", out);
