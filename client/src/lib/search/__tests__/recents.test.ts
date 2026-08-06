import { describe, expect, it } from "vitest";
import { RECENTS_KEY, RECENTS_MAX, RecentsStore } from "../recents";
import type { Result } from "../types";
import { MemoryStorage } from "./fixtures";

function r(name: string, lat = 52, lng = 9): Result {
  return { name, detail: "Stadt · Niedersachsen", lat, lng, source: "place" };
}

describe("RecentsStore", () => {
  it("startet leer", () => {
    expect(new RecentsStore(new MemoryStorage()).list()).toEqual([]);
  });

  it("persistiert unter gz_recents und liest über eine neue Instanz zurück", () => {
    const storage = new MemoryStorage();
    new RecentsStore(storage).add(r("Hannover", 52.37, 9.73));

    expect(storage.getItem(RECENTS_KEY)).not.toBeNull();
    const reloaded = new RecentsStore(storage).list();
    expect(reloaded).toEqual([r("Hannover", 52.37, 9.73)]);
  });

  it("neuester zuerst", () => {
    const store = new RecentsStore(new MemoryStorage());
    store.add(r("A", 1, 1));
    store.add(r("B", 2, 2));
    expect(store.list().map((x) => x.name)).toEqual(["B", "A"]);
  });

  it("dedupliziert über Name + Koordinate", () => {
    const store = new RecentsStore(new MemoryStorage());
    store.add(r("Hannover", 52.37, 9.73));
    store.add(r("Linden", 52.36, 9.72));
    store.add(r("Hannover", 52.37, 9.73));

    expect(store.list().map((x) => x.name)).toEqual(["Hannover", "Linden"]);
  });

  it("gleicher Name an anderer Koordinate bleibt ein eigener Eintrag", () => {
    const store = new RecentsStore(new MemoryStorage());
    store.add(r("Linden", 52.3663, 9.7218));
    store.add(r("Linden", 50.5333, 8.65));
    expect(store.list()).toHaveLength(2);
  });

  it("kappt auf RECENTS_MAX", () => {
    const store = new RecentsStore(new MemoryStorage());
    for (let i = 0; i < RECENTS_MAX + 3; i++) store.add(r(`P${i}`, i, i));
    expect(store.list()).toHaveLength(RECENTS_MAX);
    expect(store.list()[0].name).toBe(`P${RECENTS_MAX + 2}`);
  });

  it("korrupter Storage-Inhalt ergibt eine leere Liste, keinen Crash", () => {
    const storage = new MemoryStorage();
    storage.setItem(RECENTS_KEY, "{nope");
    expect(new RecentsStore(storage).list()).toEqual([]);

    storage.setItem(RECENTS_KEY, JSON.stringify([{ name: "kaputt" }, r("OK", 1, 1)]));
    expect(new RecentsStore(storage).list()).toEqual([r("OK", 1, 1)]);
  });

  it("clear leert Liste und Storage", () => {
    const storage = new MemoryStorage();
    const store = new RecentsStore(storage);
    store.add(r("A", 1, 1));
    store.clear();
    expect(store.list()).toEqual([]);
    expect(storage.getItem(RECENTS_KEY)).toBeNull();
  });

  it("ohne Storage (null) funktioniert die Liste in-memory", () => {
    const store = new RecentsStore(null);
    store.add(r("A", 1, 1));
    expect(store.list().map((x) => x.name)).toEqual(["A"]);
  });
});
