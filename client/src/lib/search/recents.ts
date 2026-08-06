/**
 * Zuletzt gewählte Ziele — max 5, persistent in localStorage.
 * Storage ist injizierbar (Tests, Node), In-Memory-Cache hält die
 * Listen-Referenz stabil, damit React nicht bei jedem Render neu diffed.
 */
import type { Result } from "./types";

export const RECENTS_KEY = "gz_recents";
export const RECENTS_MAX = 5;

export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

function defaultStorage(): StorageLike | null {
  return typeof localStorage === "undefined" ? null : localStorage;
}

function isResult(value: unknown): value is Result {
  if (typeof value !== "object" || value === null) return false;
  const r = value as Partial<Result>;
  return (
    typeof r.name === "string" &&
    typeof r.detail === "string" &&
    typeof r.lng === "number" &&
    typeof r.lat === "number" &&
    (r.source === "place" || r.source === "photon")
  );
}

/** Identität = Name + Koordinate. Gleicher Ort aus beiden Quellen = ein Eintrag. */
function identity(r: Result): string {
  return `${r.name.trim().toLowerCase()}|${r.lat.toFixed(5)},${r.lng.toFixed(5)}`;
}

export class RecentsStore {
  private storage: StorageLike | null;
  private cache: Result[] | null = null;

  constructor(storage?: StorageLike | null) {
    this.storage = storage === undefined ? defaultStorage() : storage;
  }

  list(): Result[] {
    if (this.cache) return this.cache;
    this.cache = this.read();
    return this.cache;
  }

  /** Neuester zuerst, Duplikate raus, auf RECENTS_MAX gekappt. */
  add(result: Result): Result[] {
    const id = identity(result);
    const next = [result, ...this.list().filter((r) => identity(r) !== id)].slice(0, RECENTS_MAX);
    this.cache = next;
    this.storage?.setItem(RECENTS_KEY, JSON.stringify(next));
    return next;
  }

  clear(): void {
    this.cache = [];
    this.storage?.removeItem(RECENTS_KEY);
  }

  private read(): Result[] {
    const raw = this.storage?.getItem(RECENTS_KEY);
    if (!raw) return [];
    // Korrupter Eintrag ist ein DEFINIERTES Ergebnis ("keine Recents"),
    // kein verschluckter Fehler: die Liste ist Komfort, kein Datenbestand.
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return [];
    }
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isResult).slice(0, RECENTS_MAX);
  }
}
