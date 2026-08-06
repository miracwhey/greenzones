/**
 * EINE Normalisierung für Index UND Query — sonst findet der Index nur, was
 * zufällig identisch getippt wurde. Wird als MiniSearch `processTerm` benutzt
 * und für den Merge-Dedupe.
 */

const UMLAUT: Record<string, string> = {
  "ä": "ae",
  "ö": "oe",
  "ü": "ue",
  "ß": "ss",
};

const COMBINING = /[\u0300-\u036f]/g;

/**
 * lowercase · trim · ä→ae ö→oe ü→ue ß→ss · restliche Diakritika entfernt
 * (é→e), damit NFC/NFD-Varianten derselben Schreibweise kollidieren.
 */
export function normalize(input: string): string {
  return input
    .normalize("NFC")
    .toLowerCase()
    .trim()
    .replace(/[äöüß]/g, (c) => UMLAUT[c])
    .normalize("NFD")
    .replace(COMBINING, "")
    .normalize("NFC");
}
