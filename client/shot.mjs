import { chromium } from "playwright";

// usage: node shot.mjs <url> <out.png> [dark] [onboarded]
const [url, out, ...flags] = process.argv.slice(2);
const dark = flags.includes("dark");
const onboarded = flags.includes("onboarded");

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
if (onboarded) {
  await page.addInitScript(() => localStorage.setItem("gz_onboarded", "1"));
}
await page.goto(url);
if (onboarded) {
  try {
    await page.waitForFunction(() => window.__MAP_READY__ === true, null, { timeout: 30000 });
  } catch {
    console.error("[timeout] map never ready");
  }
  await page.waitForTimeout(1500);
} else {
  await page.waitForTimeout(1200);
}
await page.screenshot({ path: out });
await browser.close();
console.log("written:", out);
