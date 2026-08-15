import Foundation
import GRDB
import Testing
@testable import GreenZonesKit

/// Port von `client/src/lib/search/__tests__/recents.test.ts` (9 Fälle) auf die
/// GRDB-Tabelle `recent_search` (SPEC 4).
@Suite("RecentsStore — zuletzt gewählte Ziele")
struct SearchRecentsTests {
    private func result(_ name: String, _ lat: Double = 52, _ lng: Double = 9) -> SearchResult {
        SearchResult(name: name, detail: "Stadt · Niedersachsen", lng: lng, lat: lat, source: .place)
    }

    @Test("startet leer")
    func startsEmpty() throws {
        let store = RecentsStore(database: try makeSearchDatabase())
        #expect(store.list().isEmpty)
    }

    @Test("persistiert und liest über eine neue Instanz zurück")
    func persists() throws {
        let database = try makeSearchDatabase()
        RecentsStore(database: database).add(result("Hannover", 52.37, 9.73))
        #expect(RecentsStore(database: database).list() == [result("Hannover", 52.37, 9.73)])
    }

    @Test("neuester zuerst")
    func newestFirst() throws {
        let store = RecentsStore(database: try makeSearchDatabase())
        store.add(result("A", 1, 1))
        store.add(result("B", 2, 2))
        #expect(store.list().map(\.name) == ["B", "A"])
    }

    @Test("dedupliziert über Name + Koordinate")
    func dedupes() throws {
        let store = RecentsStore(database: try makeSearchDatabase())
        store.add(result("Hannover", 52.37, 9.73))
        store.add(result("Linden", 52.36, 9.72))
        store.add(result("Hannover", 52.37, 9.73))
        #expect(store.list().map(\.name) == ["Hannover", "Linden"])
    }

    @Test("gleicher Name an anderer Koordinate bleibt ein eigener Eintrag")
    func sameNameOtherPlace() throws {
        let store = RecentsStore(database: try makeSearchDatabase())
        store.add(result("Linden", 52.3663, 9.7218))
        store.add(result("Linden", 50.5333, 8.65))
        #expect(store.list().count == 2)
    }

    @Test("kappt auf 5")
    func caps() throws {
        let store = RecentsStore(database: try makeSearchDatabase())
        for i in 0..<(RecentsStore.maxCount + 3) {
            store.add(result("P\(i)", Double(i), Double(i)))
        }
        #expect(store.list().count == RecentsStore.maxCount)
        #expect(store.list().first?.name == "P\(RecentsStore.maxCount + 2)")
    }

    @Test("kaputte Zeile ergibt eine kürzere Liste, keinen Absturz")
    func corruptRow() throws {
        let database = try makeSearchDatabase()
        let store = RecentsStore(database: database)
        store.add(result("OK", 1, 1))
        // Eine Zeile, die den Contract verletzt: unbekannte Quelle. v1 filtert
        // solche Einträge beim Lesen aus, statt die ganze Liste zu verlieren.
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO recent_search(key, name, detail, lat, lng, source, at)
                VALUES('kaputt|0.00000,0.00000', 'Kaputt', '', 0, 0, 'irgendwas', 999)
                """)
        }
        #expect(store.list() == [result("OK", 1, 1)])
    }

    @Test("clear leert die Liste")
    func clear() throws {
        let store = RecentsStore(database: try makeSearchDatabase())
        store.add(result("A", 1, 1))
        store.clear()
        #expect(store.list().isEmpty)
    }

    @Test("Identität ist Name + Koordinate auf 5 Nachkommastellen")
    func identity() {
        #expect(RecentsStore.identity(result(" Hannover ", 52.37, 9.73))
                == "hannover|52.37000,9.73000")
        #expect(RecentsStore.identity(result("Hannover", 52.37, 9.73))
                == RecentsStore.identity(result("HANNOVER", 52.37, 9.73)))
    }

    @Test("Quelle überlebt den Neustart — die Ziel-Bar formatiert danach")
    func keepsSource() throws {
        let database = try makeSearchDatabase()
        let photon = SearchResult(name: "Lange Laube", detail: "30159, Hannover, Niedersachsen",
                                  lng: 9.73, lat: 52.37, source: .photon)
        RecentsStore(database: database).add(photon)
        let reloaded = RecentsStore(database: database).list().first
        #expect(reloaded?.source == .photon)
        #expect(reloaded?.targetSubtitle == "30159, Hannover, Niedersachsen")
    }
}
