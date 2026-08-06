/**
 * SearchController — der Such-Kern. UI-frei, keine React-Abhängigkeit.
 *
 * Ablauf pro Tastendruck:
 *  1. Offline-Index (lazy geladen, im Worker) antwortet in einem Roundtrip.
 *  2. Photon wird 300 ms debounced hinterhergeschickt.
 * Jede Antwort trägt die Sequenz ihres Query-Standes; ältere Antworten werden
 * verworfen. Fehler beider Quellen landen in einem sichtbaren State.
 */
import type { LngLat } from "../geo";
import { dedupeAgainstOffline } from "./merge";
import {
  LocalOfflineIndex,
  PLACES_URL,
  defaultPlacesLoader,
  type OfflineIndexSource,
  type PlacesLoader,
} from "./offline";
import { PhotonClient, type HttpTransport, type PhotonSource } from "./photon";
import { RecentsStore, type StorageLike } from "./recents";
import type { IndexState, OnlineState, Result, SearchState } from "./types";

export const MIN_QUERY_OFFLINE = 2;
export const MIN_QUERY_ONLINE = 3;
export const DEBOUNCE_MS = 300;
export const OFFLINE_LIMIT = 6;

export { PLACES_URL, defaultPlacesLoader };
export type { PlacesLoader };

export type StateListener = (state: SearchState) => void;

export interface SearchControllerOptions {
  /** Default: Index im aufrufenden Thread über `loadPlaces`. Produktion: WorkerOfflineIndex. */
  offline?: OfflineIndexSource;
  /** Wird nur benutzt, wenn `offline` nicht gesetzt ist. */
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

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export class SearchController {
  private listeners = new Set<StateListener>();

  private offlineSource: OfflineIndexSource;
  private photon: PhotonSource;
  private recentsStore: RecentsStore;
  private debounceMs: number;
  private offlineLimit: number;

  private query = "";
  private userPos: LngLat | null = null;
  private indexState: IndexState = { kind: "unloaded" };
  private offline: Result[] = [];
  private online: OnlineState = { kind: "idle" };

  /** Monoton steigend pro Query-Änderung — Sequenz-Guard für Photon. */
  private reqId = 0;
  /**
   * Eigene Sequenz für die Offline-Quelle: sie wird auch ohne Query-Änderung
   * neu befragt (setUserPos), und ihre Antworten sind seit dem Worker async.
   */
  private offlineSeq = 0;
  private offlinePending = false;
  private timer: ReturnType<typeof setTimeout> | null = null;
  /** Snapshot-Cache — `getState()` muss referenzstabil sein (useSyncExternalStore). */
  private snapshot: SearchState | null = null;

  constructor(options: SearchControllerOptions = {}) {
    this.offlineSource =
      options.offline ?? new LocalOfflineIndex(options.loadPlaces ?? defaultPlacesLoader());
    this.photon = options.photon ?? new PhotonClient({ transport: options.http });
    this.recentsStore = options.recents ?? new RecentsStore(options.storage);
    this.debounceMs = options.debounceMs ?? DEBOUNCE_MS;
    this.offlineLimit = options.offlineLimit ?? OFFLINE_LIMIT;
  }

  // ---------------------------------------------------------------- Zugriff

  /** Referenzstabil zwischen zwei Änderungen — der Store-Kontrakt von React. */
  getState(): SearchState {
    if (!this.snapshot) this.snapshot = this.buildState();
    return this.snapshot;
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

  /**
   * Index vorwärmen, sobald die App bereit ist — der Bau dauert Sekunden und
   * darf nicht erst beim ersten Tastendruck anfangen.
   */
  prewarm(): void {
    if (this.indexState.kind !== "unloaded") return;
    this.ensureIndex();
    this.emit();
  }

  setQuery(query: string): void {
    this.query = query;
    this.cancelTimer();
    // Jede Query-Änderung entwertet laufende Photon-Antworten.
    this.reqId += 1;

    const length = query.trim().length;

    if (length < MIN_QUERY_OFFLINE) {
      this.resetOffline();
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
    this.resetOffline();
    this.online = { kind: "idle" };
    this.emit();
  }

  /** Nach einem Index-Ladefehler erneut versuchen. */
  reloadIndex(): void {
    if (this.indexState.kind === "loading") return;
    this.indexState = { kind: "unloaded" };
    this.ensureIndex();
    this.emit();
  }

  destroy(): void {
    this.cancelTimer();
    this.reqId += 1;
    this.offlineSeq += 1;
    this.offlinePending = false;
    this.listeners.clear();
    this.offlineSource.dispose?.();
  }

  // ----------------------------------------------------------------- intern

  private cancelTimer(): void {
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  /** Lädt den Index beim ERSTEN Bedarf (oder per `prewarm`), nie beim Konstruieren. */
  private ensureIndex(): void {
    if (this.indexState.kind !== "unloaded") return;
    this.indexState = { kind: "loading" };

    this.offlineSource.load().then(
      (count) => {
        this.indexState = { kind: "ready", count };
        this.recomputeOffline();
        this.emit();
      },
      (err: unknown) => {
        this.indexState = { kind: "error", message: errorMessage(err) };
        this.emit();
      },
    );
  }

  private resetOffline(): void {
    this.offlineSeq += 1;
    this.offlinePending = false;
    this.offline = [];
  }

  /**
   * Fragt die Offline-Quelle. Die bisherigen Treffer bleiben währenddessen
   * stehen (kein Flackern), `offlinePending` verhindert ein verfrühtes "empty".
   */
  private recomputeOffline(): void {
    if (this.indexState.kind !== "ready" || this.query.trim().length < MIN_QUERY_OFFLINE) {
      this.resetOffline();
      return;
    }

    const seq = ++this.offlineSeq;
    this.offlinePending = true;

    this.offlineSource.search(this.query, this.userPos, this.offlineLimit).then(
      (results) => {
        if (seq !== this.offlineSeq) return;
        this.offlinePending = false;
        this.offline = results;
        this.emit();
      },
      (err: unknown) => {
        if (seq !== this.offlineSeq) return;
        // Eine gescheiterte Suche heißt: der Index ist weg. Das ist ein
        // sichtbarer Zustand mit Retry, kein leeres Ergebnis.
        this.offlinePending = false;
        this.offline = [];
        this.indexState = { kind: "error", message: errorMessage(err) };
        this.emit();
      },
    );
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

    // Solange eine Quelle noch arbeitet, ist "leer" eine Lüge — dann bleibt es
    // `results` mit leerer Offline-Sektion und sichtbarem Ladezustand.
    if (
      this.offline.length === 0 &&
      onlineSettledEmpty &&
      index.kind !== "loading" &&
      !this.offlinePending
    ) {
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
    this.snapshot = state;
    for (const listener of this.listeners) listener(state);
  }
}
