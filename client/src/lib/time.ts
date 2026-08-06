/** Zeitfenster-Logik §5 Abs. 2 KCanG: Fußgängerzonen 7–20 Uhr. */

const debugHour = new URLSearchParams(window.location.search).get("hour");

export function currentHour(): number {
  return debugHour !== null ? parseInt(debugHour, 10) : new Date().getHours();
}

/** true = Fußgängerzonen-Verbot gerade aktiv. */
export function pedestrianBanActive(): boolean {
  const h = currentHour();
  return h >= 7 && h < 20;
}

/** "frei ab 20:00" / "verboten ab 7:00" — je nach aktuellem Zustand. */
export function pedestrianHint(): string {
  return pedestrianBanActive() ? "frei ab 20:00" : "verboten ab 7:00";
}
