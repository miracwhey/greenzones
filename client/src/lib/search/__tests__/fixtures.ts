/** Kleine places.json-Fixture nach dem Contract von public/places.json. */
import type { Place, PlacesFile, Result } from "../types";
import type { StorageLike } from "../recents";

export const HANNOVER = { lat: 52.37, lng: 9.73 };

export const PLACES: Place[] = [
  { n: "Hannover", t: "city", s: "Niedersachsen", lat: 52.3745, lng: 9.7386 },
  { n: "Linden-Mitte", t: "suburb", s: "Niedersachsen", c: "Hannover", lat: 52.3663, lng: 9.7218 },
  { n: "Linden-Nord", t: "suburb", s: "Niedersachsen", c: "Hannover", lat: 52.3757, lng: 9.7169 },
  { n: "Linden", t: "village", s: "Hessen", lat: 50.5333, lng: 8.65 },
  // Störfälle aus den echten Daten — ohne sie prüft der Ranking-Test nichts:
  // Bahnhof mit c = "Linden" weit weg (Kontext-Doppelzählung) …
  { n: "Großen Linden", t: "station", s: "Hessen", c: "Linden", lat: 50.5283, lng: 8.662 },
  // … und ein langer Name, der den Suchbegriff nur enthält (Längennormalisierung).
  { n: "Stadtteilpark Linden-Süd", t: "park", s: "Niedersachsen", c: "Hannover", lat: 52.3605, lng: 9.7285 },
  { n: "München", t: "city", s: "Bayern", lat: 48.1372, lng: 11.5755 },
  { n: "Köln", t: "city", s: "Nordrhein-Westfalen", lat: 50.9384, lng: 6.9599 },
  { n: "Osnabrück", t: "town", s: "Niedersachsen", lat: 52.2719, lng: 8.0471 },
  { n: "Groß Buchholz", t: "quarter", s: "Niedersachsen", c: "Hannover", lat: 52.3897, lng: 9.7997 },
  { n: "Wülfel", t: "hamlet", s: "Niedersachsen", c: "Hannover", lat: 52.3346, lng: 9.7743 },
  // Aufenthalts-POIs
  { n: "Hannover Hbf", t: "station", s: "Niedersachsen", c: "Hannover", lat: 52.3767, lng: 9.7411 },
  { n: "Küchengarten", t: "square", s: "Niedersachsen", c: "Hannover", lat: 52.3679, lng: 9.7222 },
  { n: "Georgengarten", t: "park", s: "Niedersachsen", c: "Hannover", lat: 52.3853, lng: 9.7141 },
  { n: "Maschsee", t: "water", s: "Niedersachsen", c: "Hannover", lat: 52.3556, lng: 9.7444 },
  // Unbekannter Typ — muss trotzdem findbar und renderbar sein.
  { n: "Zukunftsort", t: "zukunft", s: "Niedersachsen", c: "Hannover", lat: 52.38, lng: 9.75 },
];

export const PLACES_FILE: PlacesFile = { v: 1, places: PLACES };

/** Photon-Antwort im FeatureCollection-Format. */
export function photonBody(
  features: Array<{
    name?: string;
    street?: string;
    postcode?: string;
    city?: string;
    county?: string;
    state?: string;
    lng: number;
    lat: number;
  }>,
): unknown {
  return {
    type: "FeatureCollection",
    features: features.map((f) => ({
      type: "Feature",
      geometry: { type: "Point", coordinates: [f.lng, f.lat] },
      properties: {
        ...(f.name === undefined ? {} : { name: f.name }),
        ...(f.street === undefined ? {} : { street: f.street }),
        ...(f.postcode === undefined ? {} : { postcode: f.postcode }),
        ...(f.city === undefined ? {} : { city: f.city }),
        ...(f.county === undefined ? {} : { county: f.county }),
        ...(f.state === undefined ? {} : { state: f.state }),
      },
    })),
  };
}

export function photonResult(partial: Partial<Result> & { name: string }): Result {
  return {
    detail: "",
    lng: 0,
    lat: 0,
    source: "photon",
    ...partial,
  };
}

/** In-Memory-Storage — Node hat kein localStorage. */
export class MemoryStorage implements StorageLike {
  map = new Map<string, string>();

  getItem(key: string): string | null {
    return this.map.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.map.set(key, value);
  }

  removeItem(key: string): void {
    this.map.delete(key);
  }
}
