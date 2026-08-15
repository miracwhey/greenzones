import Foundation
import GRDB

/// Migrationsschritte der Suche. Die Composition Root sammelt sie ein — kein
/// Feature schreibt an einer zentralen Migrationsliste herum (SPEC 3).
public enum SearchMigrations {
    public static let all: [DBMigration] = [
        DBMigration("search.v1") { db in
            try db.create(table: "recent_search") { table in
                // Identitaet = Name + Koordinate (SPEC 4). Als Primaerschluessel
                // statt als Nachtraeglich-Dedupe: derselbe Ort aus beiden Quellen
                // ist EIN Eintrag, ohne dass ein Aufrufer daran denken muss.
                table.column("key", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("detail", .text)
                table.column("lat", .double).notNull()
                table.column("lng", .double).notNull()
                // Nicht in der SPEC-4-Kernliste, aber noetig: die Ziel-Bar
                // formatiert die Kontextzeile je Quelle verschieden
                // (`SearchResult.targetSubtitle`). Ohne die Spalte bekaeme ein
                // wiedergewaehlter Adress-Treffer die falsche zweite Zeile.
                table.column("source", .text).notNull()
                table.column("at", .double).notNull()
            }
        },
    ]
}

/// Zuletzt gewaehlte Ziele — max 5, in der App-DB.
/// Port von `client/src/lib/search/recents.ts` (dort localStorage).
public final class RecentsStore: Sendable {
    public static let maxCount = 5

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Neuester zuerst. Eine kaputte Zeile ist ein DEFINIERTES Ergebnis
    /// („keine Recents"), kein verschluckter Fehler: die Liste ist Komfort,
    /// kein Datenbestand.
    public func list() -> [SearchResult] {
        let rows = (try? database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM recent_search ORDER BY at DESC LIMIT ?",
                             arguments: [Self.maxCount])
        }) ?? []
        return rows.compactMap(Self.result(from:))
    }

    @discardableResult
    public func add(_ result: SearchResult, at date: Date = Date()) -> [SearchResult] {
        try? database.writer.write { db in
            // Zwei Auswahlen in derselben Millisekunde haetten sonst dieselbe
            // Zeit — und damit keine Reihenfolge.
            let latest = try Double.fetchOne(db, sql: "SELECT max(at) FROM recent_search") ?? 0
            let at = max(date.timeIntervalSince1970, latest + 0.000_001)
            try db.execute(sql: """
                INSERT INTO recent_search(key, name, detail, lat, lng, source, at)
                VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(key) DO UPDATE SET
                    name = excluded.name, detail = excluded.detail,
                    lat = excluded.lat, lng = excluded.lng,
                    source = excluded.source, at = excluded.at
                """, arguments: [Self.identity(result), result.name, result.detail,
                                 result.lat, result.lng, result.source.rawValue, at])
            try db.execute(sql: """
                DELETE FROM recent_search WHERE key NOT IN
                    (SELECT key FROM recent_search ORDER BY at DESC LIMIT ?)
                """, arguments: [Self.maxCount])
        }
        return list()
    }

    public func clear() {
        try? database.writer.write { db in
            try db.execute(sql: "DELETE FROM recent_search")
        }
    }

    /// Identitaet = Name + Koordinate. Gleicher Ort aus beiden Quellen = ein Eintrag.
    static func identity(_ result: SearchResult) -> String {
        let name = result.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(format: "%@|%.5f,%.5f", name, result.lat, result.lng)
    }

    private static func result(from row: Row) -> SearchResult? {
        guard let name: String = row["name"], !name.isEmpty,
              let lat: Double = row["lat"], lat.isFinite,
              let lng: Double = row["lng"], lng.isFinite,
              let rawSource: String = row["source"],
              let source = ResultSource(rawValue: rawSource) else {
            return nil
        }
        return SearchResult(name: name, detail: row["detail"] ?? "",
                            lng: lng, lat: lat, source: source)
    }
}
