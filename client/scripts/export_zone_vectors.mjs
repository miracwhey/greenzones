/**
 * Testvektoren fuer die Swift-Zonen-Engine (SPEC 6).
 *
 * Laeuft die UNVERAENDERTE v1-Engine (`src/lib/zones.ts`) gegen die echte
 * `public/zones.pmtiles` und schreibt ihr Urteil als JSON. Der Swift-Test
 * vergleicht dagegen — v1 ist die Autoritaet, nicht die Absicht des Ports.
 *
 * Aufruf (aus client/):  npx tsx scripts/export_zone_vectors.mjs
 *
 * Warum eine eigene Quelle statt `new PMTiles(url)`: die Engine bekommt in der
 * App eine URL, in Node kennt `fetch` kein `file://`. `PMTiles` nimmt statt der
 * URL auch ein Source-Objekt — die Engine bleibt dadurch unangetastet.
 */
import { openAsBlob } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ZoneEngine } from "../src/lib/zones.ts";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLIENT = path.resolve(HERE, "..");
const TILES = path.join(CLIENT, "public", "zones.pmtiles");
const OUT = path.resolve(
  CLIENT,
  "..",
  "ios/Packages/GreenZonesKit/Tests/GreenZonesKitTests/Fixtures/zone_vectors.json",
);

/** Raster ueber die Hannoveraner Innenstadt (SPEC 6). */
const GRID = { minLng: 9.7, maxLng: 9.78, minLat: 52.35, maxLat: 52.39, n: 16 };
/**
 * Handpunkte: Fixture-Position der Screenshots, Linden, Kroepcke — plus
 * Weitpunkte ohne Zone im 2-km-Umkreis. Ohne die letzten waere die Regel
 * `nearestM > 2000 → Infinity` in KEINEM Vektor geprueft; ein Raster ueber die
 * Innenstadt trifft sie nie.
 */
const HAND = [
  { lat: 52.3595, lng: 9.74, note: "Maschsee-Nordufer (Fixture-Position der Shots)" },
  { lat: 52.366, lng: 9.718, note: "Kuechengarten Linden" },
  { lat: 52.3745, lng: 9.7386, note: "Kroepcke" },
  { lat: 54.2, lng: 7.2, note: "weit-Nordsee" },
  { lat: 54.6, lng: 12.2, note: "weit-Ostsee" },
  { lat: 52.9, lng: 9.95, note: "weit-Lueneburger-Heide" },
  { lat: 50.3, lng: 6.4, note: "weit-Eifel" },
  { lat: 53.5, lng: 12.6, note: "weit-Mecklenburg" },
  { lat: 48.9, lng: 10.6, note: "weit-Donauries" },
];
/** Wie viele der jeweils naechstliegenden Rasterpunkte Randproben bekommen. */
const EDGE_SEEDS = 10;
/** Versatz der Randproben in Metern. */
const EDGE_OFFSET_M = 5;

const R = 6371000;
const DEG = Math.PI / 180;

/** Punkt um `dx`/`dy` Meter verschieben (gleiche Naeherung wie geo.ts). */
function offsetM(p, dx, dy) {
  return {
    lng: p.lng + dx / (R * DEG * Math.cos(p.lat * DEG)),
    lat: p.lat + dy / (R * DEG),
  };
}

/** Eine Quelle fuer die pmtiles-Bibliothek, die aus einer lokalen Datei liest. */
function fileSource(blob, key) {
  return {
    getKey: () => key,
    async getBytes(offset, length) {
      const buf = await blob.slice(offset, offset + length).arrayBuffer();
      return { data: buf };
    },
  };
}

/** Infinity ist in JSON nicht darstellbar — `null` traegt die Bedeutung. */
function num(value) {
  return Number.isFinite(value) ? Number(value.toFixed(6)) : null;
}

function round(value) {
  return Number(value.toFixed(7));
}

async function main() {
  const blob = await openAsBlob(TILES);
  const engine = new ZoneEngine(fileSource(blob, "zones.pmtiles"));

  const grid = [];
  for (let i = 0; i < GRID.n; i++) {
    for (let j = 0; j < GRID.n; j++) {
      grid.push({
        lng: GRID.minLng + ((GRID.maxLng - GRID.minLng) * i) / (GRID.n - 1),
        lat: GRID.minLat + ((GRID.maxLat - GRID.minLat) * j) / (GRID.n - 1),
        note: "raster",
      });
    }
  }

  const evaluate = async (p) => {
    const s = await engine.status({ lng: p.lng, lat: p.lat });
    return {
      lat: round(p.lat),
      lng: round(p.lng),
      note: p.note,
      ban: { inside: s.ban.inside, nearestM: num(s.ban.nearestM) },
      time: { inside: s.time.inside, nearestM: num(s.time.nearestM) },
    };
  };

  const gridResults = [];
  for (const p of grid) gridResults.push(await evaluate(p));
  console.log(`[vectors] Raster: ${gridResults.length} Punkte`);

  // Randproben: dort, wo eine Kante nah ist, entscheidet sich inside/outside —
  // genau da muss der Port sitzen. Die Saatpunkte kommen aus dem ersten Lauf,
  // nicht aus geratenen Koordinaten.
  const seeds = [];
  for (const layer of ["ban", "time"]) {
    const sorted = gridResults
      .filter((r) => r[layer].nearestM !== null)
      .sort((a, b) => a[layer].nearestM - b[layer].nearestM)
      .slice(0, EDGE_SEEDS);
    for (const r of sorted) seeds.push({ lat: r.lat, lng: r.lng, layer });
  }

  const edgeResults = [];
  for (const seed of seeds) {
    const deltas = [
      [EDGE_OFFSET_M, 0],
      [-EDGE_OFFSET_M, 0],
      [0, EDGE_OFFSET_M],
      [0, -EDGE_OFFSET_M],
    ];
    for (const [dx, dy] of deltas) {
      const p = offsetM(seed, dx, dy);
      edgeResults.push(await evaluate({ ...p, note: `rand-${seed.layer}` }));
    }
  }
  console.log(`[vectors] Randproben: ${edgeResults.length} Punkte`);

  const handResults = [];
  for (const p of HAND) handResults.push(await evaluate(p));
  console.log(`[vectors] Handpunkte: ${handResults.length} Punkte`);
  for (const r of handResults) {
    console.log(
      `           ${r.note}: ban inside=${r.ban.inside} nearest=${r.ban.nearestM} | ` +
        `time inside=${r.time.inside} nearest=${r.time.nearestM}`,
    );
  }

  const points = [...gridResults, ...edgeResults, ...handResults];
  const payload = {
    source: "client/src/lib/zones.ts gegen client/public/zones.pmtiles",
    generatedBy: "client/scripts/export_zone_vectors.mjs",
    zoom: 14,
    searchRadiusM: 2000,
    note: "nearestM = null bedeutet Infinity (keine Zone im Suchradius)",
    count: points.length,
    points,
  };

  await mkdir(path.dirname(OUT), { recursive: true });
  await writeFile(OUT, `${JSON.stringify(payload, null, 1)}\n`);

  const inside = points.filter((p) => p.ban.inside || p.time.inside).length;
  const finite = points.filter((p) => p.ban.nearestM !== null || p.time.nearestM !== null).length;
  console.log(
    `[vectors] ${points.length} Punkte geschrieben nach ${path.relative(process.cwd(), OUT)}\n` +
      `[vectors] davon ${inside} in einer Zone, ${finite} mit endlicher Distanz`,
  );
}

await main();
