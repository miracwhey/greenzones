import CoreLocation
import Foundation
import GRDB
@testable import GreenZonesKit

// Gemeinsames Gerüst der Such-Tests: die Fixture aus
// `client/src/lib/search/__tests__/fixtures.ts` als echte places.sqlite, plus
// die manuell aufloesbaren Quellen aus `controller.test.ts`.

extension TestPaths {
    /// DIESELBE DDL, die die Pipeline benutzt. Läge sie hier ein zweites Mal,
    /// könnte der Test eine Tabelle prüfen, die die App nie zu sehen bekommt.
    static let placesSchema = repositoryRoot.appendingPathComponent("pipeline/places_schema.sql")
    /// Die echte, von der Pipeline gebaute Datei (Bau-Erzeugnis, nicht im Git).
    static let placesDatabase = repositoryRoot
        .appendingPathComponent("ios/GreenZones/Resources/Generated/places.sqlite")
}

/// Ein Eintrag der v1-Fixture (`fixtures.ts`, 16 Orte).
struct FixturePlace {
    let name: String
    let type: String
    let state: String
    let city: String?
    let lat: Double
    let lng: Double
}

enum SearchFixture {
    static let hannover = CLLocationCoordinate2D(latitude: 52.37, longitude: 9.73)

    /// 1:1 aus `client/src/lib/search/__tests__/fixtures.ts` — inklusive der
    /// Störfälle („Großen Linden" mit c = Linden, „Stadtteilpark Linden-Süd"),
    /// ohne die der Ranking-Test nichts prüft.
    static let places: [FixturePlace] = [
        FixturePlace(name: "Hannover", type: "city", state: "Niedersachsen", city: nil, lat: 52.3745, lng: 9.7386),
        FixturePlace(name: "Linden-Mitte", type: "suburb", state: "Niedersachsen", city: "Hannover", lat: 52.3663, lng: 9.7218),
        FixturePlace(name: "Linden-Nord", type: "suburb", state: "Niedersachsen", city: "Hannover", lat: 52.3757, lng: 9.7169),
        FixturePlace(name: "Linden", type: "village", state: "Hessen", city: nil, lat: 50.5333, lng: 8.65),
        FixturePlace(name: "Großen Linden", type: "station", state: "Hessen", city: "Linden", lat: 50.5283, lng: 8.662),
        FixturePlace(name: "Stadtteilpark Linden-Süd", type: "park", state: "Niedersachsen", city: "Hannover", lat: 52.3605, lng: 9.7285),
        FixturePlace(name: "München", type: "city", state: "Bayern", city: nil, lat: 48.1372, lng: 11.5755),
        FixturePlace(name: "Köln", type: "city", state: "Nordrhein-Westfalen", city: nil, lat: 50.9384, lng: 6.9599),
        FixturePlace(name: "Osnabrück", type: "town", state: "Niedersachsen", city: nil, lat: 52.2719, lng: 8.0471),
        FixturePlace(name: "Groß Buchholz", type: "quarter", state: "Niedersachsen", city: "Hannover", lat: 52.3897, lng: 9.7997),
        FixturePlace(name: "Wülfel", type: "hamlet", state: "Niedersachsen", city: "Hannover", lat: 52.3346, lng: 9.7743),
        FixturePlace(name: "Hannover Hbf", type: "station", state: "Niedersachsen", city: "Hannover", lat: 52.3767, lng: 9.7411),
        FixturePlace(name: "Küchengarten", type: "square", state: "Niedersachsen", city: "Hannover", lat: 52.3679, lng: 9.7222),
        FixturePlace(name: "Georgengarten", type: "park", state: "Niedersachsen", city: "Hannover", lat: 52.3853, lng: 9.7141),
        FixturePlace(name: "Maschsee", type: "water", state: "Niedersachsen", city: "Hannover", lat: 52.3556, lng: 9.7444),
        FixturePlace(name: "Zukunftsort", type: "zukunft", state: "Niedersachsen", city: "Hannover", lat: 52.38, lng: 9.75),
    ]

    /// Baut eine places.sqlite mit der Produktions-DDL an einem temporären Pfad.
    static func makeDatabase(_ places: [FixturePlace] = places) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gz-places-\(UUID().uuidString).sqlite")
        let schema = try String(contentsOf: TestPaths.placesSchema, encoding: .utf8)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: schema)
            for (index, place) in places.enumerated() {
                let context = [place.city, place.state].compactMap { $0 }.joined(separator: " ")
                try db.execute(sql: """
                    INSERT INTO place(id, name, type, state, city, lat, lng, norm_name, norm_context)
                    VALUES(?,?,?,?,?,?,?,?,?)
                    """, arguments: [index, place.name, place.type, place.state, place.city,
                                     place.lat, place.lng,
                                     Normalize.apply(place.name), Normalize.apply(context)])
            }
            try db.execute(sql: "INSERT INTO place_fts(place_fts) VALUES('rebuild')")
            try db.execute(sql: "INSERT INTO place_tri(place_tri) VALUES('rebuild')")
        }
        return url
    }

    /// Geladener Index über die Fixture.
    static func makeIndex(_ places: [FixturePlace] = places) async throws -> PlacesIndex {
        let index = PlacesIndex(url: try makeDatabase(places))
        _ = try await index.load()
        return index
    }

    static func result(_ name: String, _ detail: String = "Stadtteil · Hannover",
                       lat: Double = 52.37, lng: Double = 9.72,
                       source: ResultSource = .place) -> SearchResult {
        SearchResult(name: name, detail: detail, lng: lng, lat: lat, source: source)
    }
}

// MARK: - Manuell aufloesbare Quellen (Port der Stubs aus controller.test.ts)

/// Photon-Stub mit manueller Aufloesung — erlaubt Antworten ausser der Reihe.
actor ManualPhoton: PhotonSource {
    private(set) var calls: [String] = []
    private var pending: [CheckedContinuation<PhotonOutcome, Never>] = []

    func search(_ query: String) async -> PhotonOutcome {
        calls.append(query)
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
    }

    var inFlight: Int { pending.count }

    /// `index` zählt in der Reihenfolge der Aufrufe, nicht der Antworten.
    func settle(_ index: Int, _ outcome: PhotonOutcome) {
        guard index < pending.count else { return }
        pending.remove(at: index).resume(returning: outcome)
    }
}

/// Photon-Stub, der eine feste Antwort liefert.
struct StubPhoton: PhotonSource {
    let outcome: PhotonOutcome
    func search(_ query: String) async -> PhotonOutcome { outcome }
}

/// Offline-Quelle mit manueller Aufloesung.
actor ManualOffline: OfflineIndexSource {
    private(set) var loads = 0
    private(set) var searches: [String] = []
    private var loadContinuations: [CheckedContinuation<Int, any Error>] = []
    private var searchContinuations: [CheckedContinuation<[SearchResult], any Error>] = []

    func load() async throws -> Int {
        loads += 1
        return try await withCheckedThrowingContinuation { continuation in
            loadContinuations.append(continuation)
        }
    }

    func search(_ query: String, userPos: CLLocationCoordinate2D?,
                limit: Int) async throws -> [SearchResult] {
        searches.append(query)
        return try await withCheckedThrowingContinuation { continuation in
            searchContinuations.append(continuation)
        }
    }

    func settleLoad(_ count: Int) {
        guard !loadContinuations.isEmpty else { return }
        loadContinuations.removeFirst().resume(returning: count)
    }

    func failLoad(_ error: any Error) {
        guard !loadContinuations.isEmpty else { return }
        loadContinuations.removeFirst().resume(throwing: error)
    }

    func settleSearch(_ index: Int, _ results: [SearchResult]) {
        guard index < searchContinuations.count else { return }
        let continuation = searchContinuations.remove(at: index)
        continuation.resume(returning: results)
    }

    func failSearch(_ index: Int, _ error: any Error) {
        guard index < searchContinuations.count else { return }
        let continuation = searchContinuations.remove(at: index)
        continuation.resume(throwing: error)
    }
}

// MARK: - Warten

enum TestWait {
    struct Timeout: Error, CustomStringConvertible {
        let note: String
        var description: String { "Bedingung nicht erreicht: \(note)" }
    }

    /// Wartet, bis die Bedingung gilt. Kein fester Sleep: der würde entweder
    /// bremsen oder auf einer langsamen Maschine flackern.
    @MainActor
    static func until(_ note: String, timeout: Duration = .seconds(5),
                      _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        throw Timeout(note: note)
    }

    /// Lässt anhängige Tasks laufen, ohne auf eine Bedingung zu warten.
    @MainActor
    static func settle(_ rounds: Int = 12) async {
        for _ in 0..<rounds {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// In-Memory-App-DB mit den Such-Migrationen.
func makeSearchDatabase() throws -> AppDatabase {
    try AppDatabase.inMemory(migrations: SearchMigrations.all)
}
