/**
 * Zusammenführung der beiden Quellen. Die Sektionen bleiben getrennt (Offline
 * zuerst) — hier wird nur die Online-Liste um das bereinigt, was der
 * Offline-Index schon zeigt.
 */
import { distanceM } from "../geo";
import { normalize } from "./normalize";
import type { Result } from "./types";

/** Gleicher Name + weniger als das = derselbe Ort. */
export const DEDUPE_DISTANCE_M = 150;

function sameSpot(a: Result, b: Result): boolean {
  if (normalize(a.name) !== normalize(b.name)) return false;
  return distanceM(a, b) < DEDUPE_DISTANCE_M;
}

/** Online-Treffer, die kein Offline-Treffer bereits abdeckt. */
export function dedupeAgainstOffline(offline: Result[], online: Result[]): Result[] {
  if (offline.length === 0) return online;
  return online.filter((o) => !offline.some((f) => sameSpot(f, o)));
}
