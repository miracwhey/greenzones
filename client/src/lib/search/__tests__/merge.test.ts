import { describe, expect, it } from "vitest";
import { DEDUPE_DISTANCE_M, dedupeAgainstOffline } from "../merge";
import type { Result } from "../types";

const offline: Result[] = [
  { name: "Linden-Mitte", detail: "Stadtteil · Hannover", lat: 52.3663, lng: 9.7218, source: "place" },
];

function online(name: string, lat: number, lng: number): Result {
  return { name, detail: "30449, Hannover, Niedersachsen", lat, lng, source: "photon" };
}

describe("dedupeAgainstOffline", () => {
  it("wirft den Online-Treffer weg, wenn Name gleich und Distanz < 150 m", () => {
    // ~11 m nördlich
    const out = dedupeAgainstOffline(offline, [online("Linden-Mitte", 52.3664, 9.7218)]);
    expect(out).toEqual([]);
  });

  it("normalisiert den Namensvergleich (Umlaute, Groß/Klein)", () => {
    const off: Result[] = [
      { name: "Wülfel", detail: "Weiler · Hannover", lat: 52.3346, lng: 9.7743, source: "place" },
    ];
    expect(dedupeAgainstOffline(off, [online("WUELFEL", 52.3346, 9.7743)])).toEqual([]);
  });

  it("behält gleichnamige Treffer weiter weg als 150 m", () => {
    // ~1.1 km südlich
    const far = online("Linden-Mitte", 52.3563, 9.7218);
    expect(dedupeAgainstOffline(offline, [far])).toEqual([far]);
  });

  it("behält Treffer mit anderem Namen an gleicher Stelle", () => {
    const street = online("Falkenstraße", 52.3663, 9.7218);
    expect(dedupeAgainstOffline(offline, [street])).toEqual([street]);
  });

  it("ohne Offline-Treffer bleibt die Online-Liste unverändert", () => {
    const list = [online("Irgendwas", 52, 9)];
    expect(dedupeAgainstOffline([], list)).toBe(list);
  });

  it("Schwelle ist dokumentiert", () => {
    expect(DEDUPE_DISTANCE_M).toBe(150);
  });
});
