import { chromium } from "playwright";

// EIN Frame pro Lauf. Mehrere Screenshots in einem Lauf kosten jeweils Zeit
// und verschieben die folgenden Zeitpunkte — die spaeteren Bilder zeigen dann
// nicht den Moment, den ihr Name behauptet.
//
//   node motionshot.mjs <datei> <szene> <now|new> <out.png> <light|dark> <ms>
const [, , file, kind, fassung, out, scheme, msRaw] = process.argv;
const ms = Number(msRaw ?? 0);

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 402, height: 1180 },
  deviceScaleFactor: 2,
  colorScheme: scheme ?? "light",
});
await page.goto("file://" + file);
await page.waitForTimeout(500);

await page.click(`.tab[data-k="${kind}"]`);
await page.waitForTimeout(3000);
await page.click(fassung === "now" ? "#segNow" : "#segNew");
await page.waitForTimeout(3000);

const t0 = Date.now();
await page.click("#play");
const rest = t0 + ms - Date.now();
if (rest > 0) await page.waitForTimeout(rest);
await page.locator(".stagewrap").screenshot({ path: out });

await browser.close();
console.log("frame:", out, "@", ms, "ms");
