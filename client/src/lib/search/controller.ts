/**
 * SearchController — der Such-Kern. UI-frei, keine React-Abhängigkeit.
 *
 * Ablauf pro Tastendruck:
 *  1. Offline-Index (lazy geladen) liefert SOFORT synchron seine Treffer.
 *  2. Photon wird 300 ms debounced hinterhergeschickt.
 * Jede Antwort trägt die Request-ID ihres Query-Standes; ältere Antworten
 * werden verworfen. Fehler beider Quellen landen in einem sichtbaren State.
 */
import type { LngLat } from "../geo";
import { dedupeAgainstOffline } from "./merge";
import { PlaceIndex } from "./places";
import { PhotonClient, type HttpTransport, type PhotonSource } from "./photon";
import { RecentsStore, type StorageLike } from "./recents";
import type {
  IndexState,
  OnlineState,
  PlacesFile,
  Result,
  SearchState,
} from "./types";

export const MIN_QUERY_OFFLINE = 2;
export const MIN_QUERY_ONLINE = 3;
export const DEBOUNCE_MS = 300;
export const OFFLINE_LIMIT = 6;
/** Relativ zur index.html — Capacitor serviert das Bundle unter capacitor://localhost. */
export const PLACES_URL = "places.json";

export type PlacesLoader = () => Promise<PlacesFile>;
export type StateListener = (state: SearchState) => void;

export interface SearchControllerOptions {
  /** Default: fetch auf PLACES_URL relativ zur aktuellen Seite. */
  loadPlaces?: PlacesLoader;
  /** Default: PhotonClient über CapacitorHttp. */
  photon?: PhotonSource;
  /** Wird nur benutzt, wenn `photon` nicht gesetzt ist. */
  http?: HttpTransport;
  recents?: RecentsStore;
  /** Wird nur benutzt, wenn `recents` nicht gesetzt ist. `null` = nicht persistieren. */
  storage?: StorageLike | null;
  debounceMs?: number;
  offlineLimit?: number;
}

/** Default-Loader. Greift erst beim Aufruf auf `window` zu — Node-sicher. */
export function defaultPlacesLoader(url: string = PLACES_URL): PlacesLoader {
  return async () => {
    const href = new URL(url, window.location.href).href;
    const res = await fetch(href);
    if (!res.ok) throw new Error(`places.json: HTTP ${res.status}`);
    return (await res.json()) as PlacesFile;
  };
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function isPlacesFile(value: unknown): value is PlacesFile {
  return (
    typeof value === "object" &&
    value !== null &&
    Array.isArray((value as PlacesFile).places)
  );
}

export class SearchController {
  private listeners = new Set<StateListener>();

  private loadPlaces: PlacesLoader;
  private photon: PhotonSource;
  private recentsStore: RecentsStore;
  private debounceMs: number;
  private offlineLimit: number;

  private query = "";
  private userPos: LngLat | null = null;
  private index: PlaceIndex | null = null;
  private indexState: IndexState = { kind: "unloaded" };
  private offline: Result[] = [];
  private online: OnlineState = { kind: "idle" };

  /** Monoton steigend pro Query-Änderung — Sequenz-Guard für Photon. */
  private reqId = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(options: SearchControllerOptions = {}) {
    this.loadPlaces = options.loadPlaces ?? defaultPlacesLoader();
    this.photon = options.photon ?? new PhotonClient({ transport: options.http });
    this.recentsStore = options.recents ?? new RecentsStore(options.storage);
    this.debounceMs = options.debounceMs ?? DEBOUNCE_MS;
    this.offlineLimit = options.offlineLimit ?? OFFLINE_LIMIT;
  }

  // ---------------------------------------------------------------- Zugriff

  getState(): SearchState {
    return this.buildState();
  }

  /**
   * Meldet KEINEN Zustand synchron beim Abonnieren (useSyncExternalStore-
   * Kontrakt) — den aktuellen Stand liefert `getState()`.
   */
  subscribe(listener: StateListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  // ---------------------------------------------------------------- Aktionen

  setQuery(query: string): void {
    this.query = query;
    this.cancelTimer();
    // Jede Query-Änderung entwertet laufende Photon-Antworten.
    this.reqId += 1;

    const length = query.trim().length;

    if (length < MIN_QUERY_OFFLINE) {
      this.offline = [];
      this.online = { kind: "idle" };
      this.emit();
      return;
    }

    this.ensureIndex();
    this.recomputeOffline();

    if (length >= MIN_QUERY_ONLINE) {
      this.online = { kind: "loading" };
      const id = this.reqId;
      const pending = query;
      this.timer = setTimeout(() => {
        this.timer = null;
        void this.runPhoton(pending, id);
      }, this.debounceMs);
    } else {
      this.online = { kind: "idle" };
    }

    this.emit();
  }

  setUserPos(pos: LngLat | null): void {
    this.userPos = pos;
    // Nur das Offline-Ranking hängt an der Position — Photon bleibt gültig.
    this.recomputeOffline();
    this.emit();
  }

  /** Schreibt den Treffer in die Recents, setzt die Suche zurück, liefert ihn. */
  selectResult(result: Result): Result {
    this.recentsStore.add(result);
    this.clear();
    return result;
  }

  clear(): void {
    this.query = "";
    this.cancelTimer();
    this.reqId += 1;
    this.offline = [];
    this.online = { kind: "idle" };
    this.emit();
  }

  /** Nach einem Index-Ladefehler erneut versuchen. */
  reloadIndex(): void {
    if (this.indexState.kind === "loading") return;
    this.index = null;
    this.indexState = { kind: "unloaded" };
    this.ensureIndex();
    this.emit();
  }

  destroy(): void {
    this.cancelTimer();
    this.reqId += 1;
    this.listeners.clear();
  }

  // ----------------------------------------------------------------- intern

  private cancelTimer(): void {
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  /** Lädt places.json beim ERSTEN Bedarf, nie beim Konstruieren. */
  private ensureIndex(): void {
    if (this.indexState.kind !== "unloaded") return;
    this.indexState = { kind: "loading" };

    this.loadPlaces().then(
      (file) => {
        if (!isPlacesFile(file)) {
          this.indexState = { kind: "error", message: "places.json: unerwartetes Format" };
          this.emit();
          return;
        }
        this.index = new PlaceIndex(file.places);
        this.indexState = { kind: "ready", count: file.places.length };
        this.recomputeOffline();
        this.emit();
      },
      (err: unknown) => {
        this.indexState = { kind: "error", message: errorMessage(err) };
        this.emit();
      },
    );
  }

  private recomputeOffline(): void {
    if (!this.index || this.query.trim().length < MIN_QUERY_OFFLINE) {
      this.offline = [];
      return;
    }
    this.offline = this.index.search(this.query, this.userPos, this.offlineLimit);
  }

  private async runPhoton(query: string, id: number): Promise<void> {
    const outcome = await this.photon.search(query);
    // Sequenz-Guard: langsame Antwort eines älteren Query-Standes verwerfen.
    if (id !== this.reqId) return;

    if (outcome.ok) {
      this.online = { kind: "results", results: outcome.results };
    } else if (outcome.error === "offline") {
      this.online = { kind: "unavailable-offline" };
    } else {
      this.online = { kind: "error", reason: outcome.error };
    }
    this.emit();
  }

  private buildState(): SearchState {
    const query = this.query;
    const index = this.indexState;

    if (query.trim().length < MIN_QUERY_OFFLINE) {
      return { kind: "idle", query, index, recents: this.recentsStore.list() };
    }

    const online = this.dedupedOnline();
    const onlineSettledEmpty =
      online.kind === "idle" || (online.kind === "results" && online.results.length === 0);

    // Solange der Index lädt, ist "leer" eine Lüge — dann bleibt es `results`
    // mit leerer Offline-Sektion und sichtbarem `index.kind === "loading"`.
    if (this.offline.length === 0 && onlineSettledEmpty && index.kind !== "loading") {
      return { kind: "empty", query, index, online };
    }

    return { kind: "results", query, index, offline: this.offline, online };
  }

  private dedupedOnline(): OnlineState {
    if (this.online.kind !== "results") return this.online;
    return { kind: "results", results: dedupeAgainstOffline(this.offline, this.online.results) };
  }

  private emit(): void {
    const state = this.buildState();
    for (const listener of this.listeners) listener(state);
  }
}
