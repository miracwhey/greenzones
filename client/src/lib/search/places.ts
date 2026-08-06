/**
 * Offline-Ortsindex — MiniSearch über die gebundelte places.json.
 * Ranking = MiniSearch-Score × Typ-Gewicht × Nähe-Boost.
 */
import MiniSearch from "minisearch";
import { distanceM, type LngLat } from "../geo";
import { normalize } from "./normalize";
import type { KnownPlaceType, Place, Result } from "./types";

/** Ein Stadtteil ist als Sucheintrag mehr wert als ein Weiler gleichen Namens. */
export const TYPE_WEIGHT: Record<KnownPlaceType, number> = {
  city: 3,
  town: 2.5,
  station: 2.2,
  village: 2,
  square: 1.9,
  suburb: 1.8,
  quarter: 1.8,
  neighbourhood: 1.8,
  park: 1.8,
  water: 1.7,
  wood: 1.7,
  hamlet: 1.2,
};

export const TYPE_LABEL: Record<KnownPlaceType, string> = {
  city: "Stadt",
  town: "Stadt",
  village: "Gemeinde",
  hamlet: "Weiler",
  suburb: "Stadtteil",
  quarter: "Ortsteil",
  neighbourhood: "Viertel",
  station: "Bahnhof",
  square: "Platz",
  park: "Park",
  water: "See",
  wood: "Wald",
};

/** Unbekannter `t`-Wert: nie verwerfen, nie crashen — neutral einsortieren. */
export const FALLBACK_TYPE_LABEL = "Ort";
export const FALLBACK_TYPE_WEIGHT = 1.5;

export function typeLabel(t: string): string {
  return (TYPE_LABEL as Record<string, string | undefined>)[t] ?? FALLBACK_TYPE_LABEL;
}

export function typeWeight(t: string): number {
  return (TYPE_WEIGHT as Record<string, number | undefined>)[t] ?? FALLBACK_TYPE_WEIGHT;
}

/** Näher am Nutzer = relevanter. Bei 0 km ×1.6, bei 30 km ×1.3, bei 300 km ×1.05. */
export function proximityBoost(userPos: LngLat, place: LngLat): number {
  const km = distanceM(userPos, place) / 1000;
  return 1 + 0.6 / (1 + km / 30);
}

/** Detail-Zeile: Typ-Label + Kontext. Eltern-Gemeinde (`c`) schlägt Bundesland (`s`). */
export function placeDetail(p: Place): string {
  const label = typeLabel(p.t);
  const context = p.c ?? p.s;
  return context ? `${label} · ${context}` : label;
}

export function placeToResult(p: Place): Result {
  return { name: p.n, detail: placeDetail(p), lng: p.lng, lat: p.lat, source: "place" };
}

interface PlaceDoc {
  id: number;
  name: string;
  /** Eltern-Gemeinde + Bundesland — macht "linden hannover" auffindbar. */
  context: string;
}

/**
 * BM25 mit eingeschalteter Längennormalisierung (b = 0.7, MiniSearch-Default).
 * An 154k echten Orten gemessen: ohne sie schlagen lange Namen, die den
 * Suchbegriff nur enthalten ("Stadtteilpark Linden-Süd", "NeuLand Köln
 * (Gemeinschaftsgarten im Kölner Süden)"), den exakten kurzen Treffer.
 */
const BM25 = { k: 1.2, b: 0.7, d: 0.5 };

/**
 * Der Kontext (Eltern-Gemeinde + Bundesland) ist für die TREFFERMENGE da
 * ("linden hannover"), nicht für die Reihenfolge. Bei vollem Gewicht zählt ein
 * Term doppelt, sobald er in beiden Feldern steht — dann gewinnt der Bahnhof
 * "Großen Linden" (c = Linden, 218 km) gegen die Stadtteile vor der Haustür.
 */
const FIELD_BOOST = { name: 3, context: 0.2 };

export class PlaceIndex {
  private ms: MiniSearch<PlaceDoc>;
  private places: Place[];

  constructor(places: Place[]) {
    this.places = places;
    this.ms = new MiniSearch<PlaceDoc>({
      fields: ["name", "context"],
      idField: "id",
      // Index und Query laufen durch dieselbe Normalisierung.
      processTerm: (term) => {
        const t = normalize(term);
        return t.length > 0 ? t : null;
      },
    });
    this.ms.addAll(
      places.map((p, id) => ({
        id,
        name: p.n,
        context: [p.c, p.s].filter(Boolean).join(" "),
      })),
    );
  }

  get size(): number {
    return this.places.length;
  }

  /**
   * Synchrone Suche. `userPos` optional — ohne Position entscheidet allein
   * Textscore × Typ-Gewicht.
   */
  search(query: string, userPos: LngLat | null, limit: number): Result[] {
    const q = query.trim();
    if (q.length === 0) return [];

    // AND zuerst — es hält mehrwortige Queries scharf ("linden hannover").
    // Scheitert ein einzelner Term ("hannover hbf" gegen "Hannover
    // Hauptbahnhof"), wäre die Antwort sonst LEER statt nur unschärfer.
    let hits = this.searchWith(q, "AND");
    if (hits.length === 0) hits = this.searchWith(q, "OR");

    const scored = hits.map((hit) => {
      const place = this.places[hit.id as number];
      let score = hit.score * typeWeight(place.t);
      if (userPos) score *= proximityBoost(userPos, { lat: place.lat, lng: place.lng });
      return { place, score };
    });

    scored.sort((a, b) => b.score - a.score);
    return scored.slice(0, limit).map((s) => placeToResult(s.place));
  }

  private searchWith(query: string, combineWith: "AND" | "OR") {
    return this.ms.search(query, {
      prefix: true,
      fuzzy: 0.2,
      combineWith,
      boost: FIELD_BOOST,
      bm25: BM25,
    });
  }
}
