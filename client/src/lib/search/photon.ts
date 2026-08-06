/**
 * Photon-Geocoder (Straßen/Adressen) über CapacitorHttp.
 *
 * CapacitorHttp statt fetch: nativer Netzwerkpfad, umgeht die WKWebView-CORS-
 * Beschränkung. Im Web-Dev fällt CapacitorHttp intern auf fetch zurück.
 *
 * Der Client wirft nie — jeder Ausgang wird zu einem typisierten `PhotonOutcome`
 * klassifiziert (offline / timeout / server). Kein stilles catch.
 */
import { CapacitorHttp, type HttpOptions, type HttpResponse } from "@capacitor/core";
import type { PhotonErrorKind, PhotonOutcome, Result } from "./types";

export const PHOTON_URL = "https://photon.komoot.io/api/";
/** Deutschland-Box — Photon liefert sonst europaweit. */
export const PHOTON_BBOX = "5.8,47.2,15.1,55.1";
export const PHOTON_LIMIT = 5;
export const PHOTON_TIMEOUT_MS = 5000;

/** Injizierbar für Tests — die native Implementierung ist CapacitorHttp. */
export interface HttpTransport {
  request(options: HttpOptions): Promise<HttpResponse>;
}

export interface PhotonSource {
  search(query: string): Promise<PhotonOutcome>;
}

export interface PhotonClientOptions {
  transport?: HttpTransport;
  /** Default: `navigator.onLine`, wenn vorhanden. */
  isOnline?: () => boolean;
  timeoutMs?: number;
}

export function photonUrl(query: string): string {
  return (
    `${PHOTON_URL}?limit=${PHOTON_LIMIT}&lang=de&bbox=${PHOTON_BBOX}` +
    `&q=${encodeURIComponent(query)}`
  );
}

function defaultIsOnline(): boolean {
  if (typeof navigator === "undefined") return true;
  const online = (navigator as Navigator & { onLine?: boolean }).onLine;
  return online !== false;
}

const OFFLINE_RE = /network|offline|failed to fetch|load failed|unreachable|enotfound|econnrefused|dns/i;
const TIMEOUT_RE = /timeout|timed out|abort/i;

/** Photon-Feature → Result. Unverändertes Mapping des Wegwerf-SearchBar. */
function featureToResult(feature: unknown): Result | null {
  if (typeof feature !== "object" || feature === null) return null;
  const f = feature as { properties?: unknown; geometry?: unknown };
  const p = (typeof f.properties === "object" && f.properties !== null
    ? f.properties
    : {}) as Record<string, string | undefined>;
  const geometry = f.geometry as { coordinates?: unknown } | undefined;
  const coords = geometry?.coordinates;
  if (!Array.isArray(coords) || typeof coords[0] !== "number" || typeof coords[1] !== "number") {
    return null;
  }
  return {
    name: p.name ?? p.street ?? "Unbenannt",
    detail: [p.postcode, p.city ?? p.county, p.state].filter(Boolean).join(", "),
    lng: coords[0],
    lat: coords[1],
    source: "photon",
  };
}

/**
 * Body kann je nach Plattform bereits geparst (nativ, content-type json) oder
 * roher String sein. Unparsbarer Body ist ein Server-Fehler, kein leeres Ergebnis.
 */
function parseBody(data: unknown): { ok: true; value: unknown } | { ok: false } {
  if (typeof data === "string") {
    try {
      return { ok: true, value: JSON.parse(data) };
    } catch {
      return { ok: false };
    }
  }
  if (typeof data === "object" && data !== null) return { ok: true, value: data };
  return { ok: false };
}

export function classifyError(err: unknown, isOnline: () => boolean): PhotonErrorKind {
  if (!isOnline()) return "offline";
  const message = err instanceof Error ? err.message : String(err);
  if (TIMEOUT_RE.test(message)) return "timeout";
  if (OFFLINE_RE.test(message)) return "offline";
  return "server";
}

export class PhotonClient implements PhotonSource {
  private transport: HttpTransport;
  private isOnline: () => boolean;
  private timeoutMs: number;

  constructor(options: PhotonClientOptions = {}) {
    this.transport = options.transport ?? CapacitorHttp;
    this.isOnline = options.isOnline ?? defaultIsOnline;
    this.timeoutMs = options.timeoutMs ?? PHOTON_TIMEOUT_MS;
  }

  async search(query: string): Promise<PhotonOutcome> {
    // Ohne Netz gar nicht erst feuern — der Nutzer soll "offline" sehen,
    // nicht 5 s auf einen Timeout warten.
    if (!this.isOnline()) return { ok: false, error: "offline" };

    const raced = await this.requestWithTimeout(query);
    if (raced.kind === "timeout") return { ok: false, error: "timeout" };
    if (raced.kind === "rejected") {
      return { ok: false, error: classifyError(raced.error, this.isOnline) };
    }

    const res = raced.response;
    if (res.status < 200 || res.status >= 300) return { ok: false, error: "server" };

    const body = parseBody(res.data);
    if (!body.ok) return { ok: false, error: "server" };

    const features = (body.value as { features?: unknown }).features;
    if (!Array.isArray(features)) return { ok: false, error: "server" };

    const results: Result[] = [];
    for (const feature of features) {
      const mapped = featureToResult(feature);
      if (mapped) results.push(mapped);
    }
    return { ok: true, results };
  }

  /**
   * connect/readTimeout decken den nativen Pfad ab; das Rennen deckt den
   * Web-Fallback ab, wo fetch keinen eigenen Timeout kennt.
   */
  private requestWithTimeout(query: string): Promise<
    | { kind: "resolved"; response: HttpResponse }
    | { kind: "rejected"; error: unknown }
    | { kind: "timeout" }
  > {
    const options: HttpOptions = {
      url: photonUrl(query),
      method: "GET",
      headers: { Accept: "application/json" },
      connectTimeout: this.timeoutMs,
      readTimeout: this.timeoutMs,
      responseType: "json",
    };

    return new Promise((resolve) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        resolve({ kind: "timeout" });
      }, this.timeoutMs);

      const finish = (
        outcome:
          | { kind: "resolved"; response: HttpResponse }
          | { kind: "rejected"; error: unknown },
      ) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(outcome);
      };

      this.transport.request(options).then(
        (response) => finish({ kind: "resolved", response }),
        (error: unknown) => finish({ kind: "rejected", error }),
      );
    });
  }
}
