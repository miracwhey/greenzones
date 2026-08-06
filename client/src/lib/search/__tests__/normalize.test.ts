import { describe, expect, it } from "vitest";
import { normalize } from "../normalize";

describe("normalize", () => {
  it("lowercased und trimmt", () => {
    expect(normalize("  Hannover  ")).toBe("hannover");
  });

  it("bildet Umlaute auf ae/oe/ue/ss ab", () => {
    expect(normalize("München")).toBe("muenchen");
    expect(normalize("Köln")).toBe("koeln");
    expect(normalize("Wülfel")).toBe("wuelfel");
    expect(normalize("Straße")).toBe("strasse");
    expect(normalize("ÄÖÜ")).toBe("aeoeue");
  });

  it("behandelt NFD-Umlaute wie NFC-Umlaute", () => {
    const nfc = "Osnabrück";
    const nfd = nfc.normalize("NFD");
    expect(nfd).not.toBe(nfc);
    expect(normalize(nfd)).toBe(normalize(nfc));
    expect(normalize(nfd)).toBe("osnabrueck");
  });

  it("entfernt sonstige Diakritika, ohne Umlaute zu treffen", () => {
    expect(normalize("Sélestat")).toBe("selestat");
    expect(normalize("Grün")).toBe("gruen");
  });
});
