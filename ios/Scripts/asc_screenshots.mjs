// Store-Screenshots ueber die App-Store-Connect-API verwalten.
//
//   node ios/Scripts/asc_screenshots.mjs stand
//   node ios/Scripts/asc_screenshots.mjs ersetze <setId> <alteId> <datei.png>
//   node ios/Scripts/asc_screenshots.mjs sortiere <setId> <id1,id2,...>
//
// Warum nicht die Weboberflaeche: dort landen mehrere Dateien auf einmal in
// beliebiger Reihenfolge, und sortieren geht nur per Drag — was sich nicht
// fernsteuern laesst (HTML5-Drag ignoriert synthetische Events). Ueber die API
// ist die Reihenfolge dagegen ein eigener Aufruf.
//
// Der .p8-Schluessel liegt in ~/.appstoreconnect/private_keys/ und gehoert
// NICHT ins Repo. Key-Id und Issuer sind keine Geheimnisse.
import crypto from "node:crypto";
import fs from "node:fs";

const KEY_ID = "84T69B383M";
const ISSUER = "87de864d-0331-4ad9-9dfe-cd752f709a29";
const KEY = fs.readFileSync(`${process.env.HOME}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`);
const APP_ID = "6798829082";

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");

function token() {
  const header = b64({ alg: "ES256", kid: KEY_ID, typ: "JWT" });
  const payload = b64({
    iss: ISSUER,
    aud: "appstoreconnect-v1",
    exp: Math.floor(Date.now() / 1000) + 900,
  });
  const sig = crypto
    .createSign("SHA256")
    .update(`${header}.${payload}`)
    .sign({ key: KEY, dsaEncoding: "ieee-p1363" })
    .toString("base64url");
  return `${header}.${payload}.${sig}`;
}

export async function api(path, opts = {}) {
  const url = path.startsWith("http") ? path : `https://api.appstoreconnect.apple.com${path}`;
  const res = await fetch(url, {
    ...opts,
    headers: {
      Authorization: `Bearer ${token()}`,
      "Content-Type": "application/json",
      ...(opts.headers || {}),
    },
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${res.status} ${path}\n${text.slice(0, 900)}`);
  return text ? JSON.parse(text) : null;
}

const cmd = process.argv[2];

if (cmd === "stand") {
  const versions = await api(`/v1/apps/${APP_ID}/appStoreVersions?limit=5`);
  const v = versions.data.find((x) => x.attributes.versionString === "2.0");
  console.log("Version 2.0:", v.id, v.attributes.appStoreState);

  const locs = await api(`/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations`);
  for (const l of locs.data) {
    console.log("  Lokalisierung", l.attributes.locale, l.id);
    const sets = await api(`/v1/appStoreVersionLocalizations/${l.id}/appScreenshotSets`);
    for (const s of sets.data) {
      const shots = await api(`/v1/appScreenshotSets/${s.id}/appScreenshots?limit=20`);
      console.log(`    Set ${s.attributes.screenshotDisplayType}  ${s.id}`);
      shots.data.forEach((sh, i) =>
        console.log(
          `      ${i + 1}. ${sh.attributes.fileName}  ${sh.id}  ${sh.attributes.assetDeliveryState?.state}`,
        ),
      );
    }
  }
}

if (cmd === "ersetze") {
  // node asc_screenshots.mjs ersetze <setId> <alteScreenshotId> <datei>
  const [setId, oldId, file] = process.argv.slice(3);
  const buf = fs.readFileSync(file);
  const name = file.split("/").pop();

  console.log(`[1/5] alten Screenshot loeschen: ${oldId}`);
  await api(`/v1/appScreenshots/${oldId}`, { method: "DELETE" });

  console.log(`[2/5] Platz reservieren: ${name} (${buf.length} Bytes)`);
  const created = await api("/v1/appScreenshots", {
    method: "POST",
    body: JSON.stringify({
      data: {
        type: "appScreenshots",
        attributes: { fileName: name, fileSize: buf.length },
        relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: setId } } },
      },
    }),
  });
  const id = created.data.id;
  const ops = created.data.attributes.uploadOperations;

  console.log(`[3/5] ${ops.length} Teil(e) hochladen`);
  for (const op of ops) {
    const part = buf.subarray(op.offset, op.offset + op.length);
    const headers = Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value]));
    const res = await fetch(op.url, { method: op.method, headers, body: part });
    if (!res.ok) throw new Error(`Upload-Teil fehlgeschlagen: ${res.status} ${await res.text()}`);
  }

  console.log("[4/5] als vollstaendig melden");
  const md5 = crypto.createHash("md5").update(buf).digest("hex");
  await api(`/v1/appScreenshots/${id}`, {
    method: "PATCH",
    body: JSON.stringify({
      data: { type: "appScreenshots", id, attributes: { uploaded: true, sourceFileChecksum: md5 } },
    }),
  });
  console.log(`      neue Id ${id}`);
  console.log("[5/5] fertig — Reihenfolge separat setzen (`sortiere`)");
}

if (cmd === "sortiere") {
  // node asc_screenshots.mjs sortiere <setId> <id1,id2,...>
  const [setId, ids] = process.argv.slice(3);
  const data = ids.split(",").map((id) => ({ type: "appScreenshots", id }));
  await api(`/v1/appScreenshotSets/${setId}/relationships/appScreenshots`, {
    method: "PATCH",
    body: JSON.stringify({ data }),
  });
  console.log("Reihenfolge gesetzt:", data.length, "Bilder");
}
