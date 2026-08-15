import Foundation
import Testing
@testable import GreenZonesKit

/// Port von `client/src/lib/search/__tests__/normalize.test.ts` (4 Fälle).
@Suite("Normalize — Port von v1")
struct SearchNormalizeTests {
    @Test("lowercased und trimmt")
    func lowercaseAndTrim() {
        #expect(Normalize.apply("  Hannover  ") == "hannover")
    }

    @Test("bildet Umlaute auf ae/oe/ue/ss ab")
    func umlauts() {
        #expect(Normalize.apply("München") == "muenchen")
        #expect(Normalize.apply("Köln") == "koeln")
        #expect(Normalize.apply("Wülfel") == "wuelfel")
        #expect(Normalize.apply("Straße") == "strasse")
        #expect(Normalize.apply("ÄÖÜ") == "aeoeue")
    }

    @Test("behandelt NFD-Umlaute wie NFC-Umlaute")
    func decomposedUmlauts() {
        let nfc = "Osnabrück"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(Array(nfd.unicodeScalars) != Array(nfc.unicodeScalars))
        #expect(Normalize.apply(nfd) == Normalize.apply(nfc))
        #expect(Normalize.apply(nfd) == "osnabrueck")
    }

    @Test("entfernt sonstige Diakritika, ohne Umlaute zu treffen")
    func diacritics() {
        #expect(Normalize.apply("Sélestat") == "selestat")
        #expect(Normalize.apply("Grün") == "gruen")
    }

    @Test("Terme trennen an allem, was kein Buchstabe und keine Ziffer ist")
    func terms() {
        #expect(Normalize.terms("Von-Alten-Garten") == ["von", "alten", "garten"])
        #expect(Normalize.terms("  linden   hannover ") == ["linden", "hannover"])
        #expect(Normalize.terms("   ").isEmpty)
        #expect(Normalize.terms("-/-").isEmpty)
    }
}
