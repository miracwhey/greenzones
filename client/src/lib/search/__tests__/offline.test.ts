import { afterEach, describe, expect, it, vi } from "vitest";
import { LocalOfflineIndex, fetchPlaces, isPlacesFile } from "../offline";
import { HANNOVER, PLACES_FILE } from "./fixtures";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("isPlacesFile", () => {
  it("akzeptiert nur ein Objekt mit places-Array", () => {
    expect(isPlacesFile(PLACES_FILE)).toBe(true);
    expect(isPlacesFile({ places: [] })).toBe(true);
    expect(isPlacesFile({ v: 1 })).toBe(false);
    expect(isPlacesFile(null)).toBe(false);
    expect(isPlacesFile("places")).toBe(false);
  });
});

describe("fetchPlaces", () => {
  it("liefert die geparste Datei", async () => {
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve({
      ok: true,
      status: 200,
      json: () => Promise.resolve(PLACES_FILE),
    })));
    await expect(fetchPlaces("https://app/places.json")).resolves.toEqual(PLACES_FILE);
  });

  it("macht aus einem HTTP-Fehler einen Fehler, kein leeres Ergebnis", async () => {
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve({ ok: false, status: 404 })));
    await expect(fetchPlaces("https://app/places.json")).rejects.toThrow("places.json: HTTP 404");
  });
});

describe("LocalOfflineIndex", () => {
  it("load liefert die Anzahl Einträge, danach sucht der Index", async () => {
    const source = new LocalOfflineIndex(() => Promise.resolve(PLACES_FILE));
    await expect(source.load()).resolves.toBe(PLACES_FILE.places.length);

    const hits = await source.search("linden", HANNOVER, 3);
    expect(hits.map((r) => r.name)).toContain("Linden-Mitte");
    expect(hits.every((r) => r.source === "place")).toBe(true);
    expect(hits.length).toBeLessThanOrEqual(3);
  });

  it("ohne geladenen Index liefert die Suche leer statt zu werfen", async () => {
    const source = new LocalOfflineIndex(() => Promise.resolve(PLACES_FILE));
    await expect(source.search("linden", null, 5)).resolves.toEqual([]);
  });

  it("unerwartetes Dateiformat lehnt ab", async () => {
    const source = new LocalOfflineIndex(() => Promise.resolve({ nope: true } as never));
    await expect(source.load()).rejects.toThrow("unerwartetes Format");
  });

  it("ein Ladefehler wird durchgereicht", async () => {
    const source = new LocalOfflineIndex(() => Promise.reject(new Error("places.json: HTTP 500")));
    await expect(source.load()).rejects.toThrow("places.json: HTTP 500");
  });
});
