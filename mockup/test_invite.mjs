import { chromium } from "playwright";

const base = "file:///Users/leonvalentin/Workspace/greenzones/mockup/invite.html";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const shots = "/Users/leonvalentin/Workspace/greenzones/mockup";
const fail = [];
const expect = (name, cond) => { console.log((cond ? "PASS" : "FAIL") + " " + name); if (!cond) fail.push(name); };

await page.goto(base + "?s=picker");
await page.waitForFunction(() => window.__MAP_READY__ === true, null, { timeout: 30000 });

// 1) Drag auf dem Band: nach links ziehen = Zeit später
const tape = page.locator("#tp-invite .tape");
const box = await tape.boundingBox();
const cx = box.x + box.width / 2, cy = box.y + box.height / 2;
await page.mouse.move(cx, cy);
await page.mouse.down();
await page.mouse.move(cx - 96, cy, { steps: 8 }); // 96px links = +120 min
await page.mouse.up();
await page.waitForTimeout(600);
const readout1 = await page.locator("#tp-invite .readout b").textContent();
expect("drag ergibt 22:00", readout1.includes("22:00"));
const cta1 = await page.locator("#cta-send").textContent();
expect("CTA folgt Drag", cta1.includes("22:00"));

// 2) Anker-Klick springt aufs Band
await page.locator('#tp-invite .anchor[data-clock="1,20,0"]').click();
await page.waitForTimeout(600);
const readout2 = await page.locator("#tp-invite .readout b").textContent();
expect("Anker Morgen Abend", readout2.includes("Morgen") && readout2.includes("20:00"));
await page.locator('#tp-invite .anchor[data-clock="0,20,0"]').click();
await page.waitForTimeout(600);

// 3) Loop: senden -> Tara sagt eigene Zeit -> Leon sieht nur Push + Liste
await page.locator('[data-go="send"]').click();
await page.waitForTimeout(300);
expect("Toast nach Senden", await page.locator("#toast.show").count() === 1);
await page.locator("#role-pill").click(); // -> Tara
await page.waitForTimeout(300);
expect("Push bei Tara", await page.locator("body.has-push").count() === 1);
await page.locator("#push").click();
await page.waitForTimeout(300);
expect("Antwort-Sheet offen", await page.locator("#sheet-received.open").count() === 1);
await page.locator('[data-go="mytime"]').click();
await page.waitForTimeout(300);
const mytimeCta = await page.locator("#cta-mytime").textContent();
expect("Mytime-CTA Komme um 21:00", mytimeCta.includes("Komme um 21:00"));
expect("Leon-ab-Flagge sichtbar", await page.locator("#tp-mytime .ref-flag").evaluate(el => el.style.opacity) === "1");
await page.locator('[data-go="send-mytime"]').click();
await page.waitForTimeout(300);
expect("Tara sieht Zusage mit eigener Zeit", await page.locator("#sheet-updated.open").count() === 1);
const updSub = await page.locator("#upd-sub").textContent();
expect("Sub bestätigt eigene Zeit", updSub.includes("21:00"));
await page.screenshot({ path: shots + "/iv_t1_tara_done.png" });

await page.locator("#role-pill").click(); // -> Leon
await page.waitForTimeout(400);
expect("Leon bekommt nur Push, kein Entscheid-Sheet", await page.locator("body.has-push").count() === 1);
const pushTitle = await page.locator("#push-title").textContent();
expect("Push sagt Taras Zeit", pushTitle.includes("Tara kommt um 21:00"));
await page.screenshot({ path: shots + "/iv_t2_host_push.png" });
await page.locator("#push").click();
await page.waitForTimeout(300);
expect("Manage-Sheet mit Liste", await page.locator("#sheet-manage.open").count() === 1);
const taraRow = await page.locator("#mng-tara").textContent();
expect("Tara-Zeile: kommt um 21:00", taraRow.includes("kommt um 21:00"));
const mngTitle = await page.locator("#mng-title").textContent();
expect("Host-Zeit UNVERAENDERT 20:00", mngTitle.includes("20:00"));
const pill = await page.locator(".spot.session .time-pill").first().textContent();
expect("Karten-Pin ab 20:00", pill.trim() === "ab 20:00");
await page.screenshot({ path: shots + "/iv_t3_host_list.png" });

// 4) Host aendert eigene Zeit nachtraeglich — Taras Antwort bleibt
await page.locator('[data-go="edit-time"]').click();
await page.waitForTimeout(300);
const editBox = await page.locator("#tp-edit .tape").boundingBox();
const ex = editBox.x + editBox.width / 2, ey = editBox.y + editBox.height / 2;
await page.mouse.move(ex, ey);
await page.mouse.down();
await page.mouse.move(ex - 24, ey, { steps: 6 }); // +30 min -> 20:30
await page.mouse.up();
await page.waitForTimeout(600);
expect("bisher-Flagge erscheint", await page.locator("#tp-edit .ref-flag").evaluate(el => el.style.opacity) === "1");
await page.locator('[data-go="send-edit"]').click();
await page.waitForTimeout(300);
const mngTime = await page.locator("#mng-time").textContent();
expect("Host-Zeit geaendert auf 20:30", mngTime.includes("20:30"));
const taraRow2 = await page.locator("#mng-tara").textContent();
expect("Taras Antwort bleibt", taraRow2.includes("kommt um 21:00"));

console.log(fail.length ? "\n" + fail.length + " FAILURES" : "\nALL PASS");
await browser.close();
process.exit(fail.length ? 1 : 0);
