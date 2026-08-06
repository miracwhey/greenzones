/**
 * Zeit-Utilities für den Zeit-Band-Picker (TimeTape).
 * Rein und ohne DOM — die Band-Mathematik (Snap, Rastzone, Anker) liegt hier,
 * damit sie ohne Render getestet werden kann.
 *
 * Uhrzeit-Format ohne führende Null bei der Stunde ("7:00", "20:00") — so wie
 * das abgenommene Mockup und `pedestrianHint()` in lib/time.ts es schreiben.
 */
import { pedestrianBanAtHour } from "../time";
import type { ZoneStatus } from "../zones";

export const MIN_MS = 60_000;
export const QUARTER_MIN = 15;
export const QUARTER_MS = QUARTER_MIN * MIN_MS;
/** Band-Bereich: minTime … +36 h. */
export const TAPE_RANGE_MIN = 36 * 60;
export const TAPE_RANGE_MS = TAPE_RANGE_MIN * MIN_MS;
/** Unter dieser Distanz zu minTime rastet das Band auf „Jetzt". */
export const NOW_ZONE_MIN = 8;

/** Lokale Mitternacht des Tages, in dem `ms` liegt. */
function startOfDay(ms: number): number {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** Auf eine absolute Viertelstunde (:00/:15/:30/:45) legen — `round` bestimmt die Richtung. */
function toQuarter(ms: number, round: (n: number) => number): number {
  const d = new Date(ms);
  const mins = d.getMinutes() + (d.getSeconds() * 1000 + d.getMilliseconds()) / MIN_MS;
  const q = round(mins / QUARTER_MIN) * QUARTER_MIN;
  d.setMinutes(0, 0, 0);
  return d.getTime() + q * MIN_MS;
}

/** "20:00" — Uhrzeit ohne führende Null bei der Stunde. */
export function fmtClock(ms: number): string {
  const d = new Date(ms);
  return `${d.getHours()}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/** "Heute" | "Morgen" | "Übermorgen" — Kalendertage, nicht 24-h-Blöcke. */
export function dayWord(ms: number, now: number): string {
  const diff = Math.round((startOfDay(ms) - startOfDay(now)) / 86_400_000);
  if (diff <= 0) return "Heute";
  if (diff === 1) return "Morgen";
  return "Übermorgen";
}

/** "direkt los" | "in 25 Min" | "in 2 Std" | "in 2 Std 19 Min" */
export function relWord(ms: number, now: number): string {
  const min = Math.round((ms - now) / MIN_MS);
  if (min < 1) return "direkt los";
  const h = Math.floor(min / 60);
  const m = min % 60;
  if (h === 0) return `in ${m} Min`;
  if (m === 0) return `in ${h} Std`;
  return `in ${h} Std ${m} Min`;
}

/** Auf die nächstliegende absolute Viertelstunde runden (:07:30 → :15). */
export function snapToQuarter(ms: number): number {
  return toQuarter(ms, Math.round);
}

/** Nächste absolute Viertelstunde ab `ms` (bei exakter Viertelstunde: `ms` selbst). */
export function ceilToQuarter(ms: number): number {
  return toQuarter(ms, Math.ceil);
}

/**
 * Loslassen nach dem Ziehen: „Jetzt"-Rastzone oder absolute Viertelstunde,
 * immer innerhalb des Bandes.
 */
export function resolveTapeDrag(base: number, curMin: number): number {
  if (curMin < NOW_ZONE_MIN) return base;
  const snapped = snapToQuarter(base + curMin * MIN_MS);
  return Math.min(Math.max(snapped, base), base + TAPE_RANGE_MS);
}

export interface TapeAnchor {
  key: string;
  label: string;
  time: number;
}

/** Uhrzeit `hour`:00 am Tag `base + dayOffset` (lokal, DST-fest). */
function clockOnDay(base: number, dayOffset: number, hour: number): number {
  const d = new Date(base);
  d.setDate(d.getDate() + dayOffset);
  d.setHours(hour, 0, 0, 0);
  return d.getTime();
}

/**
 * Sprungmarken unterm Band. Ein Anker erscheint nur, wenn seine Zeit im Band
 * liegt — deckt „Heute Abend nur wenn 20:00 noch kommt" und „Morgen Abend nur
 * wenn es noch in die 36 h passt" mit derselben Regel ab.
 */
export function tapeAnchors(base: number): TapeAnchor[] {
  const max = base + TAPE_RANGE_MS;
  return [
    { key: "now", label: "Jetzt", time: base },
    { key: "tonight", label: "Heute Abend", time: clockOnDay(base, 0, 20) },
    { key: "tomorrow", label: "Morgen Abend", time: clockOnDay(base, 1, 20) },
  ].filter((a) => a.time >= base && a.time <= max);
}

/** Ist der Konsum an einem Spot mit diesem Zonen-Status zur Zeit `at` erlaubt? */
export function spotAllowedAt(status: ZoneStatus, at: Date): boolean {
  if (status.ban.inside) return false;
  if (status.time.inside && pedestrianBanAtHour(at.getHours())) return false;
  return true;
}
