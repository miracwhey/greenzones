import Foundation
import Testing
@testable import GreenZonesKit

/// Port von `client/src/lib/search/__tests__/merge.test.ts` (6 Fälle).
@Suite("Merge — Online gegen Offline entdoppeln")
struct SearchMergeTests {
    let offline = [SearchResult(name: "Linden-Mitte", detail: "Stadtteil · Hannover",
                                lng: 9.7218, lat: 52.3663, source: .place)]

    private func online(_ name: String, _ lat: Double, _ lng: Double) -> SearchResult {
        SearchResult(name: name, detail: "30449, Hannover, Niedersachsen",
                     lng: lng, lat: lat, source: .photon)
    }

    @Test("wirft den Online-Treffer weg, wenn Name gleich und Distanz < 150 m")
    func dropsNearDuplicate() {
        // ~11 m nördlich
        let out = Merge.dedupeAgainstOffline(offline, [online("Linden-Mitte", 52.3664, 9.7218)])
        #expect(out.isEmpty)
    }

    @Test("normalisiert den Namensvergleich (Umlaute, Groß/Klein)")
    func normalizedNames() {
        let off = [SearchResult(name: "Wülfel", detail: "Weiler · Hannover",
                                lng: 9.7743, lat: 52.3346, source: .place)]
        #expect(Merge.dedupeAgainstOffline(off, [online("WUELFEL", 52.3346, 9.7743)]).isEmpty)
    }

    @Test("behält gleichnamige Treffer weiter weg als 150 m")
    func keepsFarDuplicate() {
        // ~1,1 km südlich
        let far = online("Linden-Mitte", 52.3563, 9.7218)
        #expect(Merge.dedupeAgainstOffline(offline, [far]) == [far])
    }

    @Test("behält Treffer mit anderem Namen an gleicher Stelle")
    func keepsOtherName() {
        let street = online("Falkenstraße", 52.3663, 9.7218)
        #expect(Merge.dedupeAgainstOffline(offline, [street]) == [street])
    }

    @Test("ohne Offline-Treffer bleibt die Online-Liste unverändert")
    func passthrough() {
        let list = [online("Irgendwas", 52, 9)]
        #expect(Merge.dedupeAgainstOffline([], list) == list)
    }

    @Test("Schwelle ist dokumentiert")
    func threshold() {
        #expect(Merge.dedupeDistanceM == 150)
    }
}
