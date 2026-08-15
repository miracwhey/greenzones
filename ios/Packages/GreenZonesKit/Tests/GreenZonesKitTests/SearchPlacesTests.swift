import CoreLocation
import Foundation
import Testing
@testable import GreenZonesKit

/// Port von `client/src/lib/search/__tests__/places.test.ts` (19 Fälle) gegen
/// die Fixture als echte places.sqlite.
///
/// Eine Abweichung ist bekannt und in SPEC 8 vorgesehen: FTS5 kennt kein
/// `fuzzy 0.2`. Der Trigram-Fallback fängt vertippte Wortmitten (Substring),
/// aber keinen ausgelassenen Buchstaben — der Fall steht unten als eigener
/// Test mit dem, was der Port WIRKLICH kann.
@Suite("PlacesIndex — Ranking und Labels")
struct SearchPlacesTests {
    let index: PlacesIndex

    init() async throws {
        index = try await SearchFixture.makeIndex()
    }

    private func names(_ query: String, _ pos: CLLocationCoordinate2D?,
                       _ limit: Int = 6) async throws -> [String] {
        try await index.search(query, userPos: pos, limit: limit).map(\.name)
    }

    @Test("PFLICHTFALL: User in Hannover, 'linden' → Stadtteil vor Dorf in Hessen")
    func mandatoryLinden() async throws {
        let hits = try await index.search("linden", userPos: SearchFixture.hannover, limit: 6)
        let names = hits.map(\.name)
        #expect(names.contains("Linden-Mitte"))
        #expect(names.contains("Linden"))
        #expect(names.firstIndex(of: "Linden-Mitte")! < names.firstIndex(of: "Linden")!)
        #expect(hits.first?.name == "Linden-Mitte")
        #expect(hits.first?.detail == "Stadtteil · Hannover")
    }

    @Test("ohne Position gewinnt das Typ-Gewicht: Dorf vor Stadtteil")
    func withoutPosition() async throws {
        let names = try await names("linden", nil)
        #expect(names.firstIndex(of: "Linden")! < names.firstIndex(of: "Linden-Mitte")!)
    }

    @Test("Kontext-Treffer weit weg schlägt den Stadtteil vor der Haustür NICHT")
    func contextFarAway() async throws {
        // „Großen Linden" ist ein Bahnhof in Hessen mit c = „Linden" — der Begriff
        // steht in Name UND Kontext. Volle Kontext-Gewichtung würde ihn nach oben
        // zählen, obwohl er 200+ km entfernt liegt.
        let names = try await names("linden", SearchFixture.hannover, 8)
        #expect(names.firstIndex(of: "Linden-Mitte")! < names.firstIndex(of: "Großen Linden")!)
        #expect(names.firstIndex(of: "Linden-Nord")! < names.firstIndex(of: "Großen Linden")!)
    }

    @Test("langer Name, der den Begriff nur enthält, schlägt den exakten Treffer NICHT")
    func longNameLoses() async throws {
        let names = try await names("linden", SearchFixture.hannover, 8)
        #expect(names.firstIndex(of: "Linden-Mitte")!
                < names.firstIndex(of: "Stadtteilpark Linden-Süd")!)
    }

    @Test("findet über die normalisierte Query (Umlaut-Schreibweisen)")
    func normalizedQuery() async throws {
        #expect(try await names("münchen", nil, 3).first == "München")
        #expect(try await names("muenchen", nil, 3).first == "München")
        #expect(try await names("MUENCHEN", nil, 3).first == "München")
    }

    @Test("findet per Prefix")
    func prefix() async throws {
        #expect(try await names("hann", nil, 3).contains("Hannover"))
    }

    @Test("findet über den Kontext (Eltern-Gemeinde) und schließt fremde Orte aus")
    func contextSearch() async throws {
        let hits = try await index.search("linden hannover", userPos: nil, limit: 6)
        #expect(!hits.isEmpty)
        // Nur Einträge mit Hannover-Kontext, obwohl „Linden" auch in Hessen liegt.
        #expect(hits.allSatisfy { $0.detail.hasSuffix("· Hannover") })
        #expect(hits.map(\.name).contains("Linden-Mitte"))
        #expect(!hits.map(\.name).contains("Linden"))
        #expect(!hits.map(\.name).contains("Großen Linden"))
    }

    @Test("ein nicht passender Zusatzterm macht die Trefferliste nicht leer")
    func andFallsBackToOr() async throws {
        // „Hannover Hbf" existiert in den Daten, ein Nutzer tippt aber auch
        // „hannover bahnhof" — reines AND liefert dann nichts.
        let names = try await names("hannover bahnhof", SearchFixture.hannover, 5)
        #expect(!names.isEmpty)
        #expect(names.contains("Hannover Hbf"))
    }

    @Test("AND bleibt scharf, solange es Treffer gibt")
    func andStaysSharp() async throws {
        let hits = try await index.search("linden hannover", userPos: nil, limit: 8)
        #expect(hits.allSatisfy { $0.detail.hasSuffix("· Hannover") })
    }

    @Test("respektiert das Limit")
    func limit() async throws {
        #expect(try await index.search("a", userPos: nil, limit: 2).count <= 2)
    }

    @Test("liefert nichts für eine leere Query")
    func emptyQuery() async throws {
        #expect(try await index.search("   ", userPos: nil, limit: 5).isEmpty)
    }

    @Test("Längennormalisierung: der exakte Name schlägt den langen Namen")
    func lengthNormalization() async throws {
        // Gleicher Typ, gleiche Koordinate, gleicher Kontext — der EINZIGE
        // Unterschied ist die Namenslänge. Der lange Name steht bewusst zuerst
        // im Index.
        let index = try await SearchFixture.makeIndex([
            FixturePlace(name: "Stadtteilpark Alter Hafen", type: "park", state: "Niedersachsen",
                         city: "Hannover", lat: 52.37, lng: 9.73),
            FixturePlace(name: "Hafen", type: "park", state: "Niedersachsen",
                         city: "Hannover", lat: 52.37, lng: 9.73),
        ])
        let names = try await index.search("hafen", userPos: SearchFixture.hannover, limit: 5)
            .map(\.name)
        #expect(names == ["Hafen", "Stadtteilpark Alter Hafen"])
    }

    @Test("findet den Platz 'Küchengarten' mit Label 'Platz · Hannover'")
    func square() async throws {
        let hits = try await index.search("küchengarten", userPos: SearchFixture.hannover, limit: 5)
        #expect(hits.first?.name == "Küchengarten")
        #expect(hits.first?.detail == "Platz · Hannover")
        #expect(hits.first?.source == .place)
    }

    @Test("findet See, Park und Bahnhof mit ihren Labels")
    func poiLabels() async throws {
        let pos = SearchFixture.hannover
        #expect(try await index.search("maschsee", userPos: pos, limit: 5).first?.detail == "See · Hannover")
        #expect(try await index.search("georgengarten", userPos: pos, limit: 5).first?.detail == "Park · Hannover")
        #expect(try await index.search("hbf", userPos: pos, limit: 5).first?.detail == "Bahnhof · Hannover")
    }

    @Test("Typ-Gewichte der POIs stehen wie spezifiziert")
    func typeWeights() {
        #expect(PlaceRanking.typeWeight["station"] == 2.2)
        #expect(PlaceRanking.typeWeight["square"] == 1.9)
        #expect(PlaceRanking.typeWeight["park"] == 1.8)
        #expect(PlaceRanking.typeWeight["water"] == 1.7)
    }

    @Test("unbekannter Typ: verwirft den Eintrag nicht und fällt auf 'Ort' zurück")
    func unknownType() async throws {
        let hits = try await index.search("zukunftsort", userPos: SearchFixture.hannover, limit: 5)
        #expect(hits.first?.name == "Zukunftsort")
        #expect(hits.first?.detail == "Ort · Hannover")
    }

    @Test("unbekannter Typ nutzt das Fallback-Gewicht")
    func fallbackWeight() {
        #expect(PlaceRanking.weight(for: "zukunft") == PlaceRanking.fallbackWeight)
        #expect(PlaceRanking.label(for: "zukunft") == PlaceRanking.fallbackLabel)
    }

    @Test("placeDetail stellt die Eltern-Gemeinde vor das Bundesland")
    func detailPrefersCity() {
        let place = Place(id: 1, name: "Linden-Mitte", type: "suburb", state: "Niedersachsen",
                          city: "Hannover", lat: 0, lng: 0)
        #expect(place.detail == "Stadtteil · Hannover")
    }

    @Test("placeDetail nimmt das Bundesland, wenn keine Gemeinde da ist")
    func detailFallsBackToState() {
        let place = Place(id: 1, name: "Hannover", type: "city", state: "Niedersachsen",
                          city: "", lat: 0, lng: 0)
        #expect(place.detail == "Stadt · Niedersachsen")
    }

    // MARK: - Dokumentierte Abweichung zu MiniSearch `fuzzy 0.2`

    @Test("Trigram-Fallback fängt vertippte Wortmitten (Substring)")
    func trigramFallback() async throws {
        // Kein Wortanfang-Treffer möglich — erst der Trigram-Index findet das.
        #expect(try await names("schsee", SearchFixture.hannover, 5).contains("Maschsee"))
        #expect(try await names("uenchen", SearchFixture.hannover, 5).contains("München"))
    }

    @Test("ABWEICHUNG: ein ausgelassener Buchstabe bleibt ohne Treffer")
    func fuzzyGap() async throws {
        // v1 (MiniSearch `fuzzy 0.2`) fand „osnabruck" → Osnabrück. Der
        // Trigram-Index sucht Teilzeichenketten: „osnabruck" kommt in
        // „osnabrueck" nicht vor. SPEC 8 nennt das als bewusste Abweichung.
        #expect(try await names("osnabruck", nil, 3).isEmpty)
        // Der Weg dahin bleibt offen: der Nutzer tippt weiter, und der Prefix
        // greift wieder.
        #expect(try await names("osnabr", nil, 3).contains("Osnabrück"))
    }

    @Test("Trigram greift erst ab 3 Zeichen")
    func trigramMinimum() async throws {
        // Zwei Zeichen ohne Prefix-Treffer bleiben leer statt zu raten.
        #expect(try await names("xq", nil, 5).isEmpty)
    }
}
