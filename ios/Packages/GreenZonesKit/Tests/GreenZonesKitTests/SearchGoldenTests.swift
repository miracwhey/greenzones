import CoreLocation
import Foundation
import GRDB
import Testing
@testable import GreenZonesKit

/// Golden-Queries gegen die ECHTE `places.sqlite` (164 909 Orte, von
/// `pipeline/build_places_sqlite.py` gebaut).
///
/// Die Fixture-Tests prüfen die Mechanik, diese hier prüfen die Antwort, die der
/// Nutzer bekommt — inklusive der Frage, ob Swift und Python dieselbe
/// Normalisierung schreiben und lesen.
///
/// Fehlt die Datei, schlägt die Suite fehl statt still zu überspringen: ein
/// grüner Lauf ohne Index wäre ein Beweis über nichts.
@Suite("Suche — Golden gegen die echte places.sqlite")
struct SearchGoldenTests {
    /// Nutzerposition der Goldens: Hannover (v1 `FALLBACK_CENTER`).
    static let hannover = CLLocationCoordinate2D(latitude: 52.3728, longitude: 9.7386)

    let index: PlacesIndex
    let count: Int

    init() async throws {
        let url = TestPaths.placesDatabase
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("""
                \(url.path) fehlt. Erzeugen mit:
                  python3 pipeline/build_places_sqlite.py
                (ios/Scripts/gen.sh macht das vor jedem xcodegen-Lauf.)
                """)
            throw PlacesIndexError.fileMissing(url.path)
        }
        index = PlacesIndex(url: url)
        count = try await index.load()
    }

    private func top(_ query: String, limit: Int = 3) async throws -> [String] {
        try await index.search(query, userPos: Self.hannover, limit: limit).map(\.name)
    }

    @Test("Der Index trägt den ganzen Bestand")
    func size() {
        #expect(count > 160_000, "nur \(count) Orte — places.json unvollständig gebaut?")
    }

    @Test("Swift normalisiert Zeichen für Zeichen wie die Pipeline")
    func normalizationMatchesPipeline() async throws {
        // Der Beweis, dass Index und Query dieselbe Sprache sprechen: die
        // Pipeline hat `norm_name` mit Python geschrieben, hier rechnet Swift
        // dasselbe aus 20 000 echten Namen nach. Weicht auch nur einer ab, ist
        // ein Ort mit dieser Schreibweise unauffindbar.
        let rows = try await index.rawRows(sql: """
            SELECT name, norm_name, city, state, norm_context FROM place
            WHERE id % 8 = 0 LIMIT 20000
            """)
        var mismatches: [String] = []
        for row in rows {
            let name: String = row["name"] ?? ""
            let normName: String = row["norm_name"] ?? ""
            if Normalize.apply(name) != normName {
                mismatches.append("\(name): swift=\(Normalize.apply(name)) py=\(normName)")
            }
            let city: String? = row["city"]
            let state: String = row["state"] ?? ""
            let context = [city, state].compactMap { $0 }.joined(separator: " ")
            let normContext: String = row["norm_context"] ?? ""
            if Normalize.apply(context) != normContext {
                mismatches.append("ctx \(context): swift=\(Normalize.apply(context)) py=\(normContext)")
            }
        }
        #expect(rows.count > 15_000, "zu wenige Stichproben: \(rows.count)")
        #expect(mismatches.isEmpty, "\(mismatches.count) Abweichungen, z. B. \(mismatches.prefix(3))")
    }

    @Test("Küchengarten → der Platz in Hannover")
    func kuechengarten() async throws {
        // In OSM heißt der Küchengarten in Hannover-Linden „Am Küchengarten"
        // (place=square). v1 liefert denselben Treffer auf Platz 1.
        #expect(try await top("Küchengarten").first == "Am Küchengarten")
    }

    @Test("Von-Alten-Garten — mit und ohne Bindestriche")
    func vonAltenGarten() async throws {
        #expect(try await top("Von-Alten-Garten").first == "Von-Alten-Garten")
        #expect(try await top("von alten garten").first == "Von-Alten-Garten")
    }

    @Test("Maschsee")
    func maschsee() async throws {
        #expect(try await top("Maschsee").first == "Maschsee")
    }

    @Test("hannover hbf → der Hauptbahnhof steht oben mit")
    func hannoverHbf() async throws {
        // „Hannover Hbf" existiert in OSM nicht, der Ort heißt „Hannover
        // Hauptbahnhof" — `hbf*` trifft ihn also nicht, AND läuft leer, OR
        // entscheidet. Auf Platz 1 steht dann die Stadt Hannover (Typ-Gewicht
        // 3,0 und 200 m entfernt). v1 verhält sich hier genauso; der Golden
        // prüft deshalb die Top-3, nicht Platz 1.
        let names = try await top("hannover hbf")
        #expect(names.contains("Hannover Hauptbahnhof"), "Top-3: \(names)")
        #expect(names.first == "Hannover")
    }

    @Test("linden → ein Linden-Ort in Hannover steht oben")
    func linden() async throws {
        let names = try await top("linden", limit: 6)
        #expect(names.first == "Hannover-Linden/Fischerhof", "Top-6: \(names)")
        // Mindestens zwei der ersten sechs gehören nach Hannover-Linden.
        let hannoverLinden = try await index
            .search("linden", userPos: Self.hannover, limit: 6)
            .filter { $0.detail.hasSuffix("· Hannover") }
        #expect(hannoverLinden.count >= 3, "nur \(hannoverLinden.count) Hannover-Treffer")
    }

    @Test("Ein Tippfehler in der Wortmitte findet trotzdem")
    func trigramOnRealData() async throws {
        #expect(try await top("aschsee").contains("Maschsee"))
    }

    @Test("Laufzeit: die Suche bleibt im Millisekundenbereich")
    func latency() async throws {
        // Aufwärmen — der erste Lauf zahlt Seiten-Cache.
        _ = try await index.search("masch", userPos: Self.hannover, limit: 6)
        var timings: [String: Double] = [:]
        for query in ["masch", "ha", "linden", "hannover hbf", "kuechengarten"] {
            let start = ContinuousClock.now
            for _ in 0..<5 {
                _ = try await index.search(query, userPos: Self.hannover, limit: 6)
            }
            let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e18 * 1000 / 5
            timings[query] = ms
        }
        // Kein enger Schwellwert: die Zahl steht im Report, der Test fängt nur
        // eine Größenordnung ab, die auf dem Gerät auffiele.
        for (query, ms) in timings.sorted(by: { $0.key < $1.key }) {
            print(String(format: "[latenz] %@: %.1f ms", query, ms))
            #expect(ms < 500, "\(query) braucht \(ms) ms")
        }
    }
}

extension PlacesIndex {
    /// Nur fuer Tests: Rohzugriff auf die geoeffnete Datei.
    func rawRows(sql: String) throws -> [Row] {
        guard let queue = openQueue else { throw PlacesIndexError.notLoaded }
        return try queue.read { db in try Row.fetchAll(db, sql: sql) }
    }
}
