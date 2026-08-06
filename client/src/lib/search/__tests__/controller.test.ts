import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DEBOUNCE_MS, SearchController, type PlacesLoader } from "../controller";
import { RECENTS_KEY } from "../recents";
import type { PhotonSource } from "../photon";
import type { PhotonOutcome, Result, SearchState } from "../types";
import { HANNOVER, MemoryStorage, PLACES_FILE } from "./fixtures";

/** Photon-Stub mit manueller Auflösung — erlaubt Out-of-Order-Antworten. */
class ManualPhoton implements PhotonSource {
  calls: string[] = [];
  private pending: Array<(outcome: PhotonOutcome) => void> = [];

  search(query: string): Promise<PhotonOutcome> {
    this.calls.push(query);
    return new Promise<PhotonOutcome>((resolve) => {
      this.pending.push(resolve);
    });
  }

  get inFlight(): number {
    return this.pending.length;
  }

  settle(index: number, outcome: PhotonOutcome): void {
    this.pending[index](outcome);
  }
}

function photonResult(name: string, lat: number, lng: number): Result {
  return { name, detail: "30449, Hannover, Niedersachsen", lat, lng, source: "photon" };
}

function flush(): Promise<void> {
  return vi.advanceTimersByTimeAsync(0).then(() => undefined);
}

function advance(ms: number): Promise<void> {
  return vi.advanceTimersByTimeAsync(ms).then(() => undefined);
}

interface Harness {
  controller: SearchController;
  photon: ManualPhoton;
  storage: MemoryStorage;
  states: SearchState[];
  loadPlaces: ReturnType<typeof vi.fn>;
  last(): SearchState;
}

function harness(loader?: PlacesLoader): Harness {
  const photon = new ManualPhoton();
  const storage = new MemoryStorage();
  const loadPlaces = vi.fn(loader ?? (() => Promise.resolve(PLACES_FILE)));
  const controller = new SearchController({
    loadPlaces: loadPlaces as unknown as PlacesLoader,
    photon,
    storage,
  });
  const states: SearchState[] = [];
  controller.subscribe((s) => states.push(s));
  return { controller, photon, storage, states, loadPlaces, last: () => states[states.length - 1] };
}

function offlineOf(state: SearchState): Result[] {
  return state.kind === "results" ? state.offline : [];
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("SearchController — Index-Lazy-Load", () => {
  it("lädt places.json NICHT beim Konstruieren", () => {
    const h = harness();
    expect(h.loadPlaces).not.toHaveBeenCalled();
    expect(h.controller.getState()).toEqual({
      kind: "idle",
      query: "",
      index: { kind: "unloaded" },
      recents: [],
    });
  });

  it("lädt beim ersten Bedarf und genau einmal", async () => {
    const h = harness();
    h.controller.setQuery("h");
    expect(h.loadPlaces).not.toHaveBeenCalled();

    h.controller.setQuery("ha");
    expect(h.loadPlaces).toHaveBeenCalledTimes(1);
    // Ladezustand ist sichtbar, solange die Datei unterwegs ist.
    expect(h.last().index).toEqual({ kind: "loading" });

    await flush();
    expect(h.controller.getState().index).toEqual({ kind: "ready", count: PLACES_FILE.places.length });

    h.controller.setQuery("han");
    h.controller.setQuery("hann");
    expect(h.loadPlaces).toHaveBeenCalledTimes(1);
  });

  it("Offline-Treffer erscheinen ohne Timer, sobald der Index da ist", async () => {
    const h = harness();
    h.controller.setQuery("hannover");
    expect(offlineOf(h.last())).toEqual([]);

    await flush();
    expect(offlineOf(h.last()).map((r) => r.name)).toContain("Hannover");
    // kein Timer nötig — der Debounce betrifft nur die Online-Quelle
    expect(h.photon.calls).toEqual([]);
  });

  it("nach geladenem Index liefert setQuery SYNCHRON Offline-Treffer", async () => {
    const h = harness();
    h.controller.setQuery("hannover");
    await flush();

    h.controller.setQuery("koeln");
    expect(offlineOf(h.controller.getState()).map((r) => r.name)).toEqual(["Köln"]);
  });

  it("Ladefehler ist ein sichtbarer Zustand, kein stilles Nichts", async () => {
    const h = harness(() => Promise.reject(new Error("places.json: HTTP 404")));
    h.controller.setQuery("hannover");
    await flush();
    expect(h.controller.getState().index).toEqual({
      kind: "error",
      message: "places.json: HTTP 404",
    });
  });

  it("unerwartetes Dateiformat ist ein Fehlerzustand", async () => {
    const h = harness(() => Promise.resolve({ nope: true } as never));
    h.controller.setQuery("hannover");
    await flush();
    expect(h.controller.getState().index.kind).toBe("error");
  });

  it("reloadIndex versucht es erneut", async () => {
    let attempt = 0;
    const h = harness(() => {
      attempt += 1;
      return attempt === 1 ? Promise.reject(new Error("weg")) : Promise.resolve(PLACES_FILE);
    });
    h.controller.setQuery("hannover");
    await flush();
    expect(h.controller.getState().index.kind).toBe("error");

    h.controller.reloadIndex();
    await flush();
    expect(h.controller.getState().index.kind).toBe("ready");
  });
});

describe("SearchController — Mindestlängen", () => {
  it("unter 2 Zeichen: idle, keine Quelle wird angefasst", () => {
    const h = harness();
    h.controller.setQuery("h");
    expect(h.last().kind).toBe("idle");
    expect(h.loadPlaces).not.toHaveBeenCalled();
    expect(h.photon.calls).toEqual([]);
  });

  it("2 Zeichen: offline ja, online idle", async () => {
    const h = harness();
    h.controller.setQuery("ha");
    await advance(DEBOUNCE_MS * 2);

    const state = h.controller.getState();
    expect(state.kind).toBe("results");
    expect(offlineOf(state).length).toBeGreaterThan(0);
    expect(state.kind === "results" && state.online).toEqual({ kind: "idle" });
    expect(h.photon.calls).toEqual([]);
  });

  it("3 Zeichen: online wird angefragt", async () => {
    const h = harness();
    h.controller.setQuery("han");
    await advance(DEBOUNCE_MS);
    expect(h.photon.calls).toEqual(["han"]);
  });
});

describe("SearchController — Debounce", () => {
  it("feuert erst nach 300 ms und nur einmal für schnelle Tippfolgen", async () => {
    const h = harness();
    h.controller.setQuery("han");
    await advance(100);
    h.controller.setQuery("hann");
    await advance(100);
    h.controller.setQuery("hannov");
    expect(h.photon.calls).toEqual([]);

    await advance(DEBOUNCE_MS - 1);
    expect(h.photon.calls).toEqual([]);

    await advance(1);
    expect(h.photon.calls).toEqual(["hannov"]);
  });

  it("während des Wartens ist der Online-Zustand 'loading'", async () => {
    const h = harness();
    h.controller.setQuery("hannover");
    const state = h.controller.getState();
    expect(state.kind === "results" && state.online).toEqual({ kind: "loading" });
  });

  it("clear stoppt den anstehenden Aufruf", async () => {
    const h = harness();
    h.controller.setQuery("hannover");
    h.controller.clear();
    await advance(DEBOUNCE_MS * 2);
    expect(h.photon.calls).toEqual([]);
    expect(h.controller.getState().kind).toBe("idle");
  });
});

describe("SearchController — Sequenz-Guard", () => {
  it("verwirft die langsame ALTE Antwort, die nach der neuen eintrifft", async () => {
    const h = harness();

    h.controller.setQuery("lange");
    await advance(DEBOUNCE_MS);
    expect(h.photon.calls).toEqual(["lange"]);

    h.controller.setQuery("lange laube");
    await advance(DEBOUNCE_MS);
    expect(h.photon.calls).toEqual(["lange", "lange laube"]);

    // Neue Antwort zuerst …
    h.photon.settle(1, { ok: true, results: [photonResult("Lange Laube", 52.375, 9.735)] });
    await flush();
    let state = h.controller.getState();
    expect(state.kind === "results" && state.online).toEqual({
      kind: "results",
      results: [photonResult("Lange Laube", 52.375, 9.735)],
    });

    // … dann trudelt die alte ein und darf nichts überschreiben.
    h.photon.settle(0, { ok: true, results: [photonResult("VERALTET", 1, 1)] });
    await flush();
    state = h.controller.getState();
    expect(state.kind === "results" && state.online).toEqual({
      kind: "results",
      results: [photonResult("Lange Laube", 52.375, 9.735)],
    });
  });

  it("verwirft auch einen alten FEHLER", async () => {
    const h = harness();
    h.controller.setQuery("lange");
    await advance(DEBOUNCE_MS);
    h.controller.setQuery("lange laube");
    await advance(DEBOUNCE_MS);

    h.photon.settle(1, { ok: true, results: [photonResult("Lange Laube", 52.375, 9.735)] });
    await flush();
    h.photon.settle(0, { ok: false, error: "server" });
    await flush();

    const state = h.controller.getState();
    expect(state.kind === "results" && state.online.kind).toBe("results");
  });
});

describe("SearchController — Fehlerzustände sind sichtbar", () => {
  it("timeout → online.error mit reason 'timeout'", async () => {
    const h = harness();
    h.controller.setQuery("lange laube");
    await advance(DEBOUNCE_MS);
    h.photon.settle(0, { ok: false, error: "timeout" });
    await flush();

    const state = h.controller.getState();
    expect(state.kind === "results" && state.online).toEqual({ kind: "error", reason: "timeout" });
  });

  it("server → online.error mit reason 'server'", async () => {
    const h = harness();
    h.controller.setQuery("lange laube");
    await advance(DEBOUNCE_MS);
    h.photon.settle(0, { ok: false, error: "server" });
    await flush();

    const state = h.controller.getState();
    expect(state.kind === "results" && state.online).toEqual({ kind: "error", reason: "server" });
  });

  it("offline → 'unavailable-offline', Offline-Treffer bleiben stehen", async () => {
    const h = harness();
    h.controller.setQuery("hannover");
    await advance(DEBOUNCE_MS);
    h.photon.settle(0, { ok: false, error: "offline" });
    await flush();

    const state = h.controller.getState();
    expect(state.kind).toBe("results");
    expect(state.kind === "results" && state.online).toEqual({ kind: "unavailable-offline" });
    expect(offlineOf(state).map((r) => r.name)).toContain("Hannover");
  });

  it("Online-Fehler bei leerer Offline-Sektion ist NICHT 'empty'", async () => {
    const h = harness();
    h.controller.setQuery("xyzzyq");
    await advance(DEBOUNCE_MS);
    h.photon.settle(0, { ok: false, error: "timeout" });
    await flush();

    const state = h.controller.getState();
    expect(state.kind).toBe("results");
    expect(offlineOf(state)).toEqual([]);
  });
});

describe("SearchController — empty", () => {
  it("beide Quellen leer und abgeschlossen → empty", async () => {
    const h = harness();
    h.controller.setQuery("xyzzyq");
    await advance(DEBOUNCE_MS);
    h.photon.settle(0, { ok: true, results: [] });
    await flush();

    const state = h.controller.getState();
    expect(state.kind).toBe("empty");
    expect(state.kind === "empty" && state.online).toEqual({ kind: "results", results: [] });
  });

  it("während der Index lädt, ist es NIE empty", () => {
    let release: (() => void) | null = null;
    const h = harness(
      () =>
        new Promise((resolve) => {
          release = () => resolve(PLACES_FILE);
        }),
    );
    h.controller.setQuery("xy");
    expect(h.controller.getState().kind).toBe("results");
    expect(h.controller.getState().index).toEqual({ kind: "loading" });
    expect(release).not.toBeNull();
  });
});

describe("SearchController — Merge/Dedupe", () => {
  it("Online-Treffer, den der Offline-Index schon zeigt, verschwindet", async () => {
    const h = harness();
    h.controller.setUserPos(HANNOVER);
    h.controller.setQuery("linden");
    await flush();

    expect(offlineOf(h.controller.getState()).map((r) => r.name)).toContain("Linden-Mitte");

    await advance(DEBOUNCE_MS);
    h.photon.settle(0, {
      ok: true,
      results: [
        photonResult("Linden-Mitte", 52.3663, 9.7218),
        photonResult("Lindener Marktplatz", 52.3661, 9.7229),
      ],
    });
    await flush();

    const state = h.controller.getState();
    const online = state.kind === "results" && state.online.kind === "results" ? state.online.results : [];
    expect(online.map((r) => r.name)).toEqual(["Lindener Marktplatz"]);
  });
});

describe("SearchController — Position", () => {
  it("setUserPos rankt die Offline-Treffer neu", async () => {
    const h = harness();
    h.controller.setQuery("linden");
    await flush();

    // Ohne Position entscheidet allein das Typ-Gewicht — der Treffer vor der
    // Haustür steht nicht oben.
    const withoutPos = offlineOf(h.controller.getState())[0];
    expect(withoutPos.detail).not.toContain("Hannover");

    h.controller.setUserPos(HANNOVER);
    expect(offlineOf(h.controller.getState())[0].name).toBe("Linden-Mitte");

    // Zurücknehmen stellt das positionslose Ranking wieder her.
    h.controller.setUserPos(null);
    expect(offlineOf(h.controller.getState())[0].name).toBe(withoutPos.name);
  });
});

describe("SearchController — Recents", () => {
  it("selectResult schreibt Recents, setzt zurück und liefert die Auswahl", async () => {
    const h = harness();
    h.controller.setQuery("hannover");
    await flush();

    const pick = offlineOf(h.controller.getState())[0];
    const returned = h.controller.selectResult(pick);
    expect(returned).toBe(pick);

    const state = h.controller.getState();
    expect(state.kind).toBe("idle");
    expect(state.kind === "idle" && state.recents).toEqual([pick]);
    expect(h.storage.getItem(RECENTS_KEY)).toBe(JSON.stringify([pick]));
  });

  it("Recents überleben eine neue Controller-Instanz auf demselben Storage", async () => {
    const h = harness();
    h.controller.setQuery("hannover");
    await flush();
    const pick = offlineOf(h.controller.getState())[0];
    h.controller.selectResult(pick);

    const fresh = new SearchController({
      loadPlaces: () => Promise.resolve(PLACES_FILE),
      photon: new ManualPhoton(),
      storage: h.storage,
    });
    const state = fresh.getState();
    expect(state.kind === "idle" && state.recents).toEqual([pick]);
  });
});

describe("SearchController — subscribe", () => {
  it("meldet beim Abonnieren nichts und nach unsubscribe nicht mehr", () => {
    const h = harness();
    const seen: SearchState[] = [];
    const off = h.controller.subscribe((s) => seen.push(s));
    expect(seen).toEqual([]);

    h.controller.setQuery("ha");
    expect(seen).toHaveLength(1);

    off();
    h.controller.setQuery("han");
    expect(seen).toHaveLength(1);
  });

  it("destroy stoppt Timer und Listener", async () => {
    const h = harness();
    h.controller.setQuery("hannover");
    h.controller.destroy();
    await advance(DEBOUNCE_MS * 2);
    expect(h.photon.calls).toEqual([]);
  });
});
