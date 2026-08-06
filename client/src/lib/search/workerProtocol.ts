/**
 * Protokoll zwischen Main-Thread und Ortsindex-Worker.
 *
 * Die Logik steckt in `PlacesWorkerCore` — worker-frei und damit testbar.
 * `placesWorker.ts` ist nur die Hülle, die Nachrichten durchreicht.
 */
import type { LngLat } from "../geo";
import { fetchPlaces, isPlacesFile } from "./offline";
import { PlaceIndex } from "./places";
import type { PlacesFile, Result } from "./types";

export interface LoadRequest {
  type: "load";
  /** Vom Main-Thread aufgelöste URL — der Worker liegt in /assets/ und kann nicht relativ auflösen. */
  url: string;
}

export interface SearchRequest {
  type: "search";
  seq: number;
  query: string;
  userPos: LngLat | null;
  limit: number;
}

export type WorkerRequest = LoadRequest | SearchRequest;

export type WorkerResponse =
  | { type: "ready"; count: number }
  | { type: "error"; message: string }
  | { type: "results"; seq: number; results: Result[] };

export type PlacesFetcher = (url: string) => Promise<PlacesFile>;

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export class PlacesWorkerCore {
  private post: (message: WorkerResponse) => void;
  private fetchPlaces: PlacesFetcher;
  private index: PlaceIndex | null = null;
  private loading = false;

  constructor(post: (message: WorkerResponse) => void, fetcher: PlacesFetcher = fetchPlaces) {
    this.post = post;
    this.fetchPlaces = fetcher;
  }

  handle(request: WorkerRequest): void {
    if (request.type === "load") this.load(request.url);
    else this.search(request);
  }

  /** Idempotent: ein zweites `load` während des Ladens startet keinen zweiten Abruf. */
  private load(url: string): void {
    if (this.index) {
      this.post({ type: "ready", count: this.index.size });
      return;
    }
    if (this.loading) return;
    this.loading = true;

    this.fetchPlaces(url).then(
      (file) => {
        this.loading = false;
        if (!isPlacesFile(file)) {
          this.post({ type: "error", message: "places.json: unerwartetes Format" });
          return;
        }
        this.index = new PlaceIndex(file.places);
        this.post({ type: "ready", count: file.places.length });
      },
      (err: unknown) => {
        this.loading = false;
        this.post({ type: "error", message: errorMessage(err) });
      },
    );
  }

  /** Ohne Index nie hängen lassen — leere Antwort mit derselben `seq`. */
  private search(request: SearchRequest): void {
    const results = this.index
      ? this.index.search(request.query, request.userPos, request.limit)
      : [];
    this.post({ type: "results", seq: request.seq, results });
  }
}
