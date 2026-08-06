/**
 * Such-Kern — Typen. UI-frei, keine React-Abhängigkeit.
 *
 * Zwei Quellen, strikt getrennt:
 *  - "place"  → gebundelter Offline-Ortsindex (places.json)
 *  - "photon" → Photon-Geocoder online (Straßen/Adressen)
 * Es gibt KEINEN stillen Fallback: fällt eine Quelle aus, wird ihr Zustand
 * sichtbar gemacht, nie durch die andere Quelle kaschiert.
 */

/**
 * Bekannte Ortstypen aus places.json — Siedlungen (OSM `place=*`) plus
 * Aufenthalts-POIs (Bahnhof/Platz/Park/See), nach denen Nutzer real suchen.
 */
export type KnownPlaceType =
  | "city"
  | "town"
  | "village"
  | "hamlet"
  | "suburb"
  | "quarter"
  | "neighbourhood"
  | "station"
  | "square"
  | "park"
  | "water"
  | "wood";

/**
 * `t` ist bewusst offen: ein künftiger Typ in places.json darf den Client nicht
 * crashen lassen und den Eintrag nicht verschlucken — er fällt auf Label "Ort"
 * und ein neutrales Gewicht zurück.
 */
export type PlaceType = KnownPlaceType | (string & {});

/** Ein Eintrag aus places.json. Kurze Keys — die Datei wird gebundelt. */
export interface Place {
  /** Name */
  n: string;
  /** Typ */
  t: PlaceType;
  /** Bundesland */
  s: string;
  /** Optionale Eltern-Gemeinde (Stadtteile) */
  c?: string;
  lat: number;
  lng: number;
}

/** Contract von public/places.json. */
export interface PlacesFile {
  v: number;
  places: Place[];
}

export type ResultSource = "place" | "photon";

/** Ein Suchtreffer, quellenunabhängig renderbar. */
export interface Result {
  name: string;
  /** Zweite Zeile: Typ + Kontext (place) bzw. PLZ/Ort/Bundesland (photon). */
  detail: string;
  lng: number;
  lat: number;
  source: ResultSource;
}

/** Typisierter Photon-Fehler — nie ein stilles catch. */
export type PhotonErrorKind = "offline" | "timeout" | "server";

/** Ergebnis eines Photon-Aufrufs. Wirft nicht, klassifiziert. */
export type PhotonOutcome =
  | { ok: true; results: Result[] }
  | { ok: false; error: PhotonErrorKind };

/** Zustand der Online-Quelle innerhalb eines Such-States. */
export type OnlineState =
  /** Query zu kurz für online (< MIN_QUERY_ONLINE) — kein Fehler. */
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "results"; results: Result[] }
  /** Gerät ist offline — Adresssuche nicht verfügbar. */
  | { kind: "unavailable-offline" }
  | { kind: "error"; reason: Exclude<PhotonErrorKind, "offline"> };

/** Ladezustand des Offline-Ortsindex (lazy). */
export type IndexState =
  | { kind: "unloaded" }
  | { kind: "loading" }
  | { kind: "ready"; count: number }
  | { kind: "error"; message: string };

/**
 * Gesamt-State. Jede Variante ist von der UI unterscheidbar renderbar:
 *  - idle    → Recents (oder nichts)
 *  - results → Offline-Sektion zuerst, danach die Online-Sektion gemäß `online`
 *  - empty   → beide Quellen abgeschlossen und leer
 * `index` ist in jeder Variante enthalten, damit der Ortsindex-Ladezustand
 * (und ein Ladefehler) immer sichtbar gemacht werden kann.
 */
export type SearchState =
  | { kind: "idle"; query: string; index: IndexState; recents: Result[] }
  | {
      kind: "results";
      query: string;
      index: IndexState;
      offline: Result[];
      online: OnlineState;
    }
  | { kind: "empty"; query: string; index: IndexState; online: OnlineState };
