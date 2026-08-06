/**
 * Offline-Quelle des Such-Kerns — injizierbar wie Photon.
 *
 * Der Index-Bau über ~160k Einträge kostet auf dem iPhone Sekunden. Deshalb ist
 * die Quelle ASYNC: die Produktions-Implementierung (`workerIndex.ts`) hält den
 * Index in einem Web Worker, der Main-Thread bleibt flüssig. Die Suche selbst
 * bleibt gefühlt sofort (<20 ms), es ist nur ein postMessage-Roundtrip.
 *
 * `LocalOfflineIndex` baut denselben Index im aufrufenden Thread — für Tests
 * und für jeden Kontext ohne Worker.
 */
import type { LngLat } from "../geo";
import { PlaceIndex } from "./places";
import type { PlacesFile, Result } from "./types";

/** Relativ zur index.html — Capacitor serviert das Bundle unter capacitor://localhost. */
export const PLACES_URL = "places.json";

export type PlacesLoader = () => Promise<PlacesFile>;

export function isPlacesFile(value: unknown): value is PlacesFile {
  return (
    typeof value === "object" &&
    value !== null &&
    Array.isArray((value as PlacesFile).places)
  );
}

/** Absolute URL der places.json, abgeleitet aus der aktuellen Seite — nie hartkodiert. */
export function placesHref(url: string = PLACES_URL): string {
  return new URL(url, window.location.href).href;
}

/** Default-Loader. Greift erst beim Aufruf auf `window` zu — Node-sicher. */
export function defaultPlacesLoader(url: string = PLACES_URL): PlacesLoader {
  return () => fetchPlaces(placesHref(url));
}

/** Roher Datei-Abruf. Ein HTTP-Fehler ist ein Fehler, kein leerer Index. */
export async function fetchPlaces(href: string): Promise<PlacesFile> {
  const res = await fetch(href);
  if (!res.ok) throw new Error(`places.json: HTTP ${res.status}`);
  return (await res.json()) as PlacesFile;
}

export interface OfflineIndexSource {
  /**
   * Baut den Index und liefert die Anzahl Einträge. Der Controller ruft das
   * höchstens einmal pro Ladeversuch auf; ein Fehler lehnt ab (kein stilles Leer).
   */
  load(): Promise<number>;
  /** Wird nur nach erfolgreichem `load()` aufgerufen. */
  search(query: string, userPos: LngLat | null, limit: number): Promise<Result[]>;
  dispose?(): void;
}

/** Index im aufrufenden Thread. Blockiert beim Bau — nicht für den Main-Thread. */
export class LocalOfflineIndex implements OfflineIndexSource {
  private loadPlaces: PlacesLoader;
  private index: PlaceIndex | null = null;

  constructor(loadPlaces: PlacesLoader) {
    this.loadPlaces = loadPlaces;
  }

  async load(): Promise<number> {
    const file = await this.loadPlaces();
    if (!isPlacesFile(file)) throw new Error("places.json: unerwartetes Format");
    this.index = new PlaceIndex(file.places);
    return file.places.length;
  }

  search(query: string, userPos: LngLat | null, limit: number): Promise<Result[]> {
    if (!this.index) return Promise.resolve([]);
    return Promise.resolve(this.index.search(query, userPos, limit));
  }
}
