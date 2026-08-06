import { describe, expect, it } from "vitest";
import { FALLBACK_TYPE_LABEL, FALLBACK_TYPE_WEIGHT, PlaceIndex, TYPE_WEIGHT, placeDetail, typeLabel, typeWeight } from "../places";
import { HANNOVER, PLACES } from "./fixtures";

const index = new PlaceIndex(PLACES);

describe("PlaceIndex — Ranking", () => {
  it("PFLICHTFALL: User in Hannover, 'linden' → Stadtteil vor Dorf in Hessen", () => {
    const hits = index.search("linden", HANNOVER, 6);
    const names = hits.map((h) => h.name);
    expect(names).toContain("Linden-Mitte");
    expect(names).toContain("Linden");
    expect(names.indexOf("Linden-Mitte")).toBeLessThan(names.indexOf("Linden"));
    expect(hits[0].name).toBe("Linden-Mitte");
    expect(hits[0].detail).toBe("Stadtteil · Hannover");
  });

  it("ohne Position gewinnt das Typ-Gewicht: Dorf vor Stadtteil", () => {
    const hits = index.search("linden", null, 6);
    const names = hits.map((h) => h.name);
    expect(names.indexOf("Linden")).toBeLessThan(names.indexOf("Linden-Mitte"));
  });

  it("Kontext-Treffer weit weg schlägt den Stadtteil vor der Haustür NICHT", () => {
    // "Großen Linden" ist ein Bahnhof in Hessen mit c = "Linden" — der Begriff
    // steht in Name UND Kontext. Volle Kontext-Gewichtung würde ihn nach oben
    // zählen, obwohl er 200+ km entfernt liegt.
    const names = index.search("linden", HANNOVER, 8).map((h) => h.name);
    expect(names.indexOf("Linden-Mitte")).toBeLessThan(names.indexOf("Großen Linden"));
    expect(names.indexOf("Linden-Nord")).toBeLessThan(names.indexOf("Großen Linden"));
  });

  it("langer Name, der den Begriff nur enthält, schlägt den exakten Treffer NICHT", () => {
    const names = index.search("linden", HANNOVER, 8).map((h) => h.name);
    expect(names.indexOf("Linden-Mitte")).toBeLessThan(names.indexOf("Stadtteilpark Linden-Süd"));
  });

  it("findet über die normalisierte Query (Umlaut-Schreibweisen)", () => {
    expect(index.search("münchen", null, 3)[0].name).toBe("München");
    expect(index.search("muenchen", null, 3)[0].name).toBe("München");
    expect(index.search("MUENCHEN", null, 3)[0].name).toBe("München");
  });

  it("findet per Prefix und fuzzy", () => {
    expect(index.search("hann", null, 3).map((r) => r.name)).toContain("Hannover");
    expect(index.search("osnabruck", null, 3).map((r) => r.name)).toContain("Osnabrück");
  });

  it("findet über den Kontext (Eltern-Gemeinde) und schließt fremde Orte aus", () => {
    const hits = index.search("linden hannover", null, 6);
    expect(hits.length).toBeGreaterThan(0);
    // Nur Einträge mit Hannover-Kontext, obwohl "Linden" auch in Hessen liegt.
    expect(hits.every((h) => h.detail.endsWith("· Hannover"))).toBe(true);
    expect(hits.map((h) => h.name)).toContain("Linden-Mitte");
    expect(hits.map((h) => h.name)).not.toContain("Linden");
    expect(hits.map((h) => h.name)).not.toContain("Großen Linden");
  });

  it("ein nicht passender Zusatzterm macht die Trefferliste nicht leer", () => {
    // "Hannover Hbf" existiert in den Daten als "Hannover Hbf", ein Nutzer
    // tippt aber auch "hannover bahnhof" — reines AND liefert dann nichts.
    const hits = index.search("hannover bahnhof", HANNOVER, 5);
    expect(hits.length).toBeGreaterThan(0);
    expect(hits.map((h) => h.name)).toContain("Hannover Hbf");
  });

  it("AND bleibt scharf, solange es Treffer gibt", () => {
    // Würde direkt auf OR ausgewichen, kämen hier auch die Hessen-Einträge mit.
    const hits = index.search("linden hannover", null, 8);
    expect(hits.every((h) => h.detail.endsWith("· Hannover"))).toBe(true);
  });

  it("respektiert das Limit", () => {
    expect(index.search("a", null, 2).length).toBeLessThanOrEqual(2);
  });

  it("liefert nichts für eine leere Query", () => {
    expect(index.search("   ", null, 5)).toEqual([]);
  });
});

describe("PlaceIndex — Längennormalisierung", () => {
  it("der exakte Name schlägt den langen Namen, der den Begriff nur enthält", () => {
    // Gleicher Typ, gleiche Koordinate, gleicher Kontext — der EINZIGE
    // Unterschied ist die Namenslänge. Der lange Name steht bewusst zuerst im
    // Index: ohne Längennormalisierung wären beide Scores gleich und die
    // Einfügereihenfolge würde entscheiden.
    const idx = new PlaceIndex([
      { n: "Stadtteilpark Alter Hafen", t: "park", s: "Niedersachsen", c: "Hannover", lat: 52.37, lng: 9.73 },
      { n: "Hafen", t: "park", s: "Niedersachsen", c: "Hannover", lat: 52.37, lng: 9.73 },
    ]);
    expect(idx.search("hafen", HANNOVER, 5).map((r) => r.name)).toEqual([
      "Hafen",
      "Stadtteilpark Alter Hafen",
    ]);
  });
});

describe("PlaceIndex — Aufenthalts-POIs", () => {
  it("findet den Platz 'Küchengarten' mit Label 'Platz · Hannover'", () => {
    const hits = index.search("küchengarten", HANNOVER, 5);
    expect(hits[0].name).toBe("Küchengarten");
    expect(hits[0].detail).toBe("Platz · Hannover");
    expect(hits[0].source).toBe("place");
  });

  it("findet See, Park und Bahnhof mit ihren Labels", () => {
    expect(index.search("maschsee", HANNOVER, 5)[0].detail).toBe("See · Hannover");
    expect(index.search("georgengarten", HANNOVER, 5)[0].detail).toBe("Park · Hannover");
    expect(index.search("hbf", HANNOVER, 5)[0].detail).toBe("Bahnhof · Hannover");
  });

  it("Typ-Gewichte der POIs stehen wie spezifiziert", () => {
    expect(TYPE_WEIGHT.station).toBe(2.2);
    expect(TYPE_WEIGHT.square).toBe(1.9);
    expect(TYPE_WEIGHT.park).toBe(1.8);
    expect(TYPE_WEIGHT.water).toBe(1.7);
  });
});

describe("PlaceIndex — unbekannter Typ", () => {
  it("verwirft den Eintrag nicht und fällt auf 'Ort' zurück", () => {
    const hits = index.search("zukunftsort", HANNOVER, 5);
    expect(hits[0].name).toBe("Zukunftsort");
    expect(hits[0].detail).toBe("Ort · Hannover");
  });

  it("nutzt das Fallback-Gewicht", () => {
    expect(typeWeight("zukunft")).toBe(FALLBACK_TYPE_WEIGHT);
    expect(typeLabel("zukunft")).toBe(FALLBACK_TYPE_LABEL);
  });
});

describe("placeDetail", () => {
  it("stellt die Eltern-Gemeinde vor das Bundesland", () => {
    expect(
      placeDetail({ n: "Linden-Mitte", t: "suburb", s: "Niedersachsen", c: "Hannover", lat: 0, lng: 0 }),
    ).toBe("Stadtteil · Hannover");
  });

  it("nimmt das Bundesland, wenn keine Gemeinde da ist", () => {
    expect(placeDetail({ n: "Hannover", t: "city", s: "Niedersachsen", lat: 0, lng: 0 })).toBe(
      "Stadt · Niedersachsen",
    );
  });
});
