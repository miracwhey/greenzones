import { afterEach, describe, expect, it, vi } from "vitest";
import type { HttpOptions, HttpResponse } from "@capacitor/core";
import { PHOTON_TIMEOUT_MS, PhotonClient, photonUrl, type HttpTransport } from "../photon";
import { photonBody } from "./fixtures";

function response(data: unknown, status = 200): HttpResponse {
  return { data, status, headers: {}, url: "https://photon.komoot.io/api/" };
}

function transportOf(impl: (o: HttpOptions) => Promise<HttpResponse>): HttpTransport {
  return { request: impl };
}

afterEach(() => {
  vi.useRealTimers();
});

describe("photonUrl", () => {
  it("baut die Deutschland-begrenzte URL und encodiert die Query", () => {
    expect(photonUrl("Lange Laube 1")).toBe(
      "https://photon.komoot.io/api/?limit=5&lang=de&bbox=5.8,47.2,15.1,55.1&q=Lange%20Laube%201",
    );
  });
});

describe("PhotonClient — Erfolgsfall", () => {
  it("mappt Features auf Result (name/street, postcode + city/county + state)", async () => {
    const transport = transportOf(async () =>
      response(
        photonBody([
          { name: "Lange Laube", postcode: "30159", city: "Hannover", state: "Niedersachsen", lng: 9.73, lat: 52.37 },
          { street: "Feldweg", postcode: "31311", county: "Region Hannover", state: "Niedersachsen", lng: 9.9, lat: 52.4 },
          { postcode: "12345", lng: 8, lat: 50 },
        ]),
      ),
    );
    const client = new PhotonClient({ transport, isOnline: () => true });
    const out = await client.search("lange laube");

    expect(out).toEqual({
      ok: true,
      results: [
        { name: "Lange Laube", detail: "30159, Hannover, Niedersachsen", lng: 9.73, lat: 52.37, source: "photon" },
        { name: "Feldweg", detail: "31311, Region Hannover, Niedersachsen", lng: 9.9, lat: 52.4, source: "photon" },
        { name: "Unbenannt", detail: "12345", lng: 8, lat: 50, source: "photon" },
      ],
    });
  });

  it("parst auch einen String-Body (nativer Pfad ohne json content-type)", async () => {
    const transport = transportOf(async () =>
      response(JSON.stringify(photonBody([{ name: "X", lng: 1, lat: 2 }]))),
    );
    const out = await new PhotonClient({ transport, isOnline: () => true }).search("x");
    expect(out.ok && out.results[0].name).toBe("X");
  });

  it("setzt connectTimeout und readTimeout", async () => {
    const seen: HttpOptions[] = [];
    const transport = transportOf(async (o) => {
      seen.push(o);
      return response(photonBody([]));
    });
    await new PhotonClient({ transport, isOnline: () => true }).search("abc");
    expect(seen[0].connectTimeout).toBe(PHOTON_TIMEOUT_MS);
    expect(seen[0].readTimeout).toBe(PHOTON_TIMEOUT_MS);
  });
});

describe("PhotonClient — Fehlerklassifikation", () => {
  it("offline: feuert gar nicht erst", async () => {
    const request = vi.fn();
    const client = new PhotonClient({ transport: { request }, isOnline: () => false });
    expect(await client.search("hannover")).toEqual({ ok: false, error: "offline" });
    expect(request).not.toHaveBeenCalled();
  });

  it("timeout: Antwort bleibt aus", async () => {
    vi.useFakeTimers();
    const transport = transportOf(() => new Promise<HttpResponse>(() => {}));
    const client = new PhotonClient({ transport, isOnline: () => true });
    const pending = client.search("hannover");
    await vi.advanceTimersByTimeAsync(PHOTON_TIMEOUT_MS);
    expect(await pending).toEqual({ ok: false, error: "timeout" });
  });

  it("timeout: Transport meldet selbst einen Timeout", async () => {
    const transport = transportOf(() => Promise.reject(new Error("Request timed out")));
    const client = new PhotonClient({ transport, isOnline: () => true });
    expect(await client.search("hannover")).toEqual({ ok: false, error: "timeout" });
  });

  it("server: HTTP 500", async () => {
    const transport = transportOf(async () => response({ features: [] }, 500));
    const client = new PhotonClient({ transport, isOnline: () => true });
    expect(await client.search("hannover")).toEqual({ ok: false, error: "server" });
  });

  it("server: unparsbarer Body ist kein leeres Ergebnis", async () => {
    const transport = transportOf(async () => response("<html>bad gateway</html>"));
    const client = new PhotonClient({ transport, isOnline: () => true });
    expect(await client.search("hannover")).toEqual({ ok: false, error: "server" });
  });

  it("server: JSON ohne features", async () => {
    const transport = transportOf(async () => response({ message: "nope" }));
    const client = new PhotonClient({ transport, isOnline: () => true });
    expect(await client.search("hannover")).toEqual({ ok: false, error: "server" });
  });

  it("offline: Netzwerkfehler des Transports", async () => {
    const transport = transportOf(() => Promise.reject(new TypeError("Failed to fetch")));
    const client = new PhotonClient({ transport, isOnline: () => true });
    expect(await client.search("hannover")).toEqual({ ok: false, error: "offline" });
  });

  it("server: unbekannter Fehler bleibt nicht still", async () => {
    const transport = transportOf(() => Promise.reject(new Error("boom")));
    const client = new PhotonClient({ transport, isOnline: () => true });
    expect(await client.search("hannover")).toEqual({ ok: false, error: "server" });
  });
});
