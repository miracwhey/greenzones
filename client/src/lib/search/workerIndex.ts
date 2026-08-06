/**
 * Main-Thread-Seite des Ortsindex-Workers.
 *
 * Der Index-Bau (~160k Einträge) läuft komplett im Worker; hier landen nur
 * postMessage-Roundtrips. Fehler werden nie verschluckt: ein toter Worker lehnt
 * den laufenden Ladevorgang UND alle offenen Suchen ab — der Controller macht
 * daraus einen sichtbaren Index-Fehlerzustand mit Retry.
 */
import type { LngLat } from "../geo";
import { placesHref, type OfflineIndexSource } from "./offline";
import type { Result } from "./types";
import type { WorkerRequest, WorkerResponse } from "./workerProtocol";

type Settle<T> = { resolve: (value: T) => void; reject: (reason: Error) => void };

export class WorkerOfflineIndex implements OfflineIndexSource {
  private url: string;
  private worker: Worker | null = null;
  private loadSettle: Settle<number> | null = null;
  private pending = new Map<number, Settle<Result[]>>();
  private seq = 0;

  /** URL wird aus der aktuellen Seite abgeleitet — nie absolut hartkodiert. */
  constructor(url: string = placesHref()) {
    this.url = url;
  }

  load(): Promise<number> {
    const worker = this.ensureWorker();
    return new Promise<number>((resolve, reject) => {
      this.loadSettle = { resolve, reject };
      worker.postMessage({ type: "load", url: this.url } satisfies WorkerRequest);
    });
  }

  search(query: string, userPos: LngLat | null, limit: number): Promise<Result[]> {
    const worker = this.worker;
    // Ohne Worker gibt es keinen Index — der Controller ruft search() erst nach
    // erfolgreichem load() auf, dieser Zweig ist reine Absicherung.
    if (!worker) return Promise.reject(new Error("Ortsindex nicht geladen"));

    const seq = ++this.seq;
    return new Promise<Result[]>((resolve, reject) => {
      this.pending.set(seq, { resolve, reject });
      worker.postMessage({ type: "search", seq, query, userPos, limit } satisfies WorkerRequest);
    });
  }

  dispose(): void {
    this.worker?.terminate();
    this.worker = null;
    this.failAll(new Error("Ortsindex beendet"));
  }

  private ensureWorker(): Worker {
    if (this.worker) return this.worker;
    const worker = new Worker(new URL("./placesWorker.ts", import.meta.url), { type: "module" });
    worker.onmessage = (event: MessageEvent<WorkerResponse>) => this.receive(event.data);
    worker.onerror = () => {
      // Toter Worker: nächster Versuch bekommt eine frische Instanz.
      this.worker?.terminate();
      this.worker = null;
      this.failAll(new Error("Ortsindex-Worker abgestürzt"));
    };
    this.worker = worker;
    return worker;
  }

  private receive(message: WorkerResponse): void {
    if (message.type === "ready") {
      this.loadSettle?.resolve(message.count);
      this.loadSettle = null;
      return;
    }
    if (message.type === "error") {
      this.loadSettle?.reject(new Error(message.message));
      this.loadSettle = null;
      return;
    }
    const settle = this.pending.get(message.seq);
    if (!settle) return;
    this.pending.delete(message.seq);
    settle.resolve(message.results);
  }

  private failAll(error: Error): void {
    this.loadSettle?.reject(error);
    this.loadSettle = null;
    for (const settle of this.pending.values()) settle.reject(error);
    this.pending.clear();
  }
}
