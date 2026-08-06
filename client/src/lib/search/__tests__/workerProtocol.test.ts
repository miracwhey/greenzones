import { describe, expect, it, vi } from "vitest";
import { PlacesWorkerCore, type WorkerResponse } from "../workerProtocol";
import { HANNOVER, PLACES_FILE } from "./fixtures";

function core(fetcher: (url: string) => Promise<typeof PLACES_FILE>) {
  const posted: WorkerResponse[] = [];
  const instance = new PlacesWorkerCore(
    (message) => posted.push(message),
    fetcher as unknown as (url: string) => Promise<typeof PLACES_FILE>,
  );
  return { instance, posted };
}

const okFetcher = () => Promise.resolve(PLACES_FILE);

/** Der Core hat keine Timer — ein paar Microtask-Runden reichen. */
async function flush(): Promise<void> {
  for (let i = 0; i < 3; i++) await Promise.resolve();
}

describe("PlacesWorkerCore — laden", () => {
  it("meldet ready mit der Anzahl Einträge", async () => {
    const fetcher = vi.fn(okFetcher);
    const { instance, posted } = core(fetcher);
    instance.handle({ type: "load", url: "https://app/places.json" });
    await flush();

    expect(fetcher).toHaveBeenCalledWith("https://app/places.json");
    expect(posted).toEqual([{ type: "ready", count: PLACES_FILE.places.length }]);
  });

  it("ein Ladefehler wird gemeldet, nicht verschluckt", async () => {
    const { instance, posted } = core(() => Promise.reject(new Error("places.json: HTTP 404")));
    instance.handle({ type: "load", url: "u" });
    await flush();
    expect(posted).toEqual([{ type: "error", message: "places.json: HTTP 404" }]);
  });

  it("unerwartetes Dateiformat ist ein Fehler", async () => {
    const { instance, posted } = core(() => Promise.resolve({ nope: true } as never));
    instance.handle({ type: "load", url: "u" });
    await flush();
    expect(posted).toEqual([{ type: "error", message: "places.json: unerwartetes Format" }]);
  });

  it("ein zweites load während des Ladens startet keinen zweiten Abruf", async () => {
    const fetcher = vi.fn(okFetcher);
    const { instance, posted } = core(fetcher);
    instance.handle({ type: "load", url: "u" });
    instance.handle({ type: "load", url: "u" });
    await flush();
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(posted).toHaveLength(1);
  });

  it("load auf den fertigen Index antwortet sofort ready (Retry-Pfad)", async () => {
    const fetcher = vi.fn(okFetcher);
    const { instance, posted } = core(fetcher);
    instance.handle({ type: "load", url: "u" });
    await flush();

    instance.handle({ type: "load", url: "u" });
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(posted).toEqual([
      { type: "ready", count: PLACES_FILE.places.length },
      { type: "ready", count: PLACES_FILE.places.length },
    ]);
  });
});

describe("PlacesWorkerCore — suchen", () => {
  it("antwortet mit derselben seq und rankt nach Position", async () => {
    const { instance, posted } = core(okFetcher);
    instance.handle({ type: "load", url: "u" });
    await flush();
    posted.length = 0;

    instance.handle({ type: "search", seq: 7, query: "linden", userPos: HANNOVER, limit: 3 });
    expect(posted).toHaveLength(1);
    const message = posted[0];
    expect(message.type).toBe("results");
    if (message.type !== "results") throw new Error("unerwartete Nachricht");
    expect(message.seq).toBe(7);
    expect(message.results[0].name).toBe("Linden-Mitte");
    expect(message.results.length).toBeLessThanOrEqual(3);
  });

  it("eine Suche vor dem Index hängt nie — leere Antwort mit derselben seq", () => {
    const { instance, posted } = core(okFetcher);
    instance.handle({ type: "search", seq: 1, query: "linden", userPos: null, limit: 5 });
    expect(posted).toEqual([{ type: "results", seq: 1, results: [] }]);
  });
});
