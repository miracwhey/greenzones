/** Zeitfenster-Logik §5 Abs. 2 KCanG: Fußgängerzonen 7–20 Uhr. */

/** Debug-Override `?hour=` — erst beim Aufruf lesen, sonst bricht der Import ohne DOM. */
function debugHour(): string | null {
  return typeof window === "undefined" ? null : new URLSearchParams(window.location.search).get("hour");
}

export function currentHour(): number {
  const h = debugHour();
  return h !== null ? parseInt(h, 10) : new Date().getHours();
}

/** true = Fußgängerzonen-Verbot gilt zur vollen Stunde `h`. */
export function pedestrianBanAtHour(h: number): boolean {
  return h >= 7 && h < 20;
}

/** true = Fußgängerzonen-Verbot gerade aktiv. */
export function pedestrianBanActive(): boolean {
  return pedestrianBanAtHour(currentHour());
}

/** "frei ab 20:00" / "verboten ab 7:00" — je nach aktuellem Zustand. */
export function pedestrianHint(): string {
  return pedestrianBanActive() ? "frei ab 20:00" : "verboten ab 7:00";
}
