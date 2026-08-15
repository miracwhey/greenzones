import CoreLocation
import Foundation
import GRDB
import os

/// Die Offline-Quelle des Such-Kerns — injizierbar wie Photon.
///
/// Async, weil die Suche NICHT auf dem Main-Thread laufen darf: `PlacesIndex`
/// ist ein Actor, jede Abfrage landet damit auf dem Cooperative Pool.
public protocol OfflineIndexSource: Sendable {
    /// Oeffnet den Index und liefert die Anzahl Eintraege. Ein Fehler lehnt ab
    /// (kein stilles Leer) — der Controller macht daraus einen sichtbaren State.
    func load() async throws -> Int
    /// Wird nur nach erfolgreichem `load()` aufgerufen.
    func search(_ query: String, userPos: CLLocationCoordinate2D?, limit: Int) async throws -> [SearchResult]
}

public enum PlacesIndexError: Error, CustomStringConvertible {
    case fileMissing(String)
    case notLoaded

    public var description: String {
        switch self {
        case .fileMissing(let path): return "places.sqlite fehlt: \(path)"
        case .notLoaded: return "Ortsindex ist nicht geladen"
        }
    }
}

/// Offline-Ortsindex ueber die gebuendelte `places.sqlite` (SPEC 8).
///
/// v1 baute den MiniSearch-Index ueber 164 909 Eintraege beim ersten
/// Tastendruck in einem Worker — Sekunden CPU, danach der ganze Bestand im
/// Speicher. Hier liegt der fertige FTS5-Index read-only im Bundle; „laden"
/// heisst nur noch: Datei oeffnen.
public actor PlacesIndex: OfflineIndexSource {
    /// Kandidaten aus SQL, bevor in Swift final sortiert wird (SPEC 8).
    public static let candidateLimit = 60
    /// Ab dieser Laenge greift der Trigram-Fallback (SPEC 8).
    public static let minTrigramLength = 3

    private let url: URL
    private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "search")
    private var queue: DatabaseQueue?

    /// Nur fuer Tests (`@testable`): der Golden-Test liest damit `norm_name`
    /// direkt und prueft, ob Swift und Python dieselbe Normalisierung schreiben.
    var openQueue: DatabaseQueue? { queue }

    public init(url: URL) {
        self.url = url
    }

    // MARK: - Laden

    public func load() throws -> Int {
        if let queue {
            return try queue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM place") ?? 0
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlacesIndexError.fileMissing(url.path)
        }
        var configuration = Configuration()
        // Die Datei liegt im App-Bundle: schreibend zu oeffnen scheitert dort,
        // und eine Kopie nach Caches waeren 36 MB doppelt.
        configuration.readonly = true
        // Distanz und Typ-Gewicht gehoeren in die Auswahl der Kandidaten, nicht
        // erst hinter sie — deshalb rechnet SQLite mit derselben Swift-Funktion,
        // die auch die Endsortierung benutzt.
        configuration.prepareDatabase { db in
            db.add(function: Self.boostFunction)
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM place") ?? 0
        }
        self.queue = queue
        logger.info("Ortsindex geoeffnet: \(count, privacy: .public) Orte")
        return count
    }

    // MARK: - Suche

    public func search(_ query: String, userPos: CLLocationCoordinate2D?,
                       limit: Int) throws -> [SearchResult] {
        guard let queue else { throw PlacesIndexError.notLoaded }
        let normalized = Normalize.apply(query)
        let terms = Normalize.terms(query)
        guard !terms.isEmpty else { return [] }

        var rows = try fetch(queue, match: Self.matchExpression(terms, joiner: "AND"),
                             table: .fullText, userPos: userPos)
        // AND haelt mehrwortige Queries scharf („linden hannover"). Scheitert ein
        // einzelner Term („hannover hbf" gegen „Hannover Hauptbahnhof"), waere die
        // Antwort sonst LEER statt nur unschaerfer.
        if rows.isEmpty, terms.count > 1 {
            rows = try fetch(queue, match: Self.matchExpression(terms, joiner: "OR"),
                             table: .fullText, userPos: userPos)
        }
        // Tippfehler-Fallback: Substring statt Wortanfang. Ersetzt MiniSearchs
        // `fuzzy 0.2` — faengt vertippte Wortmitten, aber keine ausgelassenen
        // Buchstaben („osnabruck" bleibt ohne Treffer, dokumentiert in SPEC 8).
        if rows.isEmpty, normalized.count >= Self.minTrigramLength {
            rows = try fetch(queue, match: Self.quoted(normalized),
                             table: .trigram, userPos: userPos)
        }

        let scored = rows.map { row -> (score: Double, place: Place) in
            var score = row.textScore * PlaceRanking.weight(for: row.place.type)
            if let userPos {
                score *= PlaceRanking.proximityBoost(user: userPos, place: row.place.coordinate)
            }
            return (score, row.place)
        }
        return scored
            // Gleichstand nach id: sonst haengt die Reihenfolge an der Laune des
            // Sortierverfahrens und der Screenshot zeigt jedes Mal etwas anderes.
            .sorted { $0.score == $1.score ? $0.place.id < $1.place.id : $0.score > $1.score }
            .prefix(limit)
            .map(\.place.searchResult)
    }

    // MARK: - SQL

    private enum IndexTable {
        case fullText
        case trigram
    }

    private struct ScoredRow {
        let place: Place
        let textScore: Double
    }

    /// `gz_boost(userLat, userLng, placeLat, placeLng)` — dieselbe Formel wie in
    /// Swift, damit Kandidatenwahl und Endsortierung nicht auseinanderlaufen.
    private static let boostFunction = DatabaseFunction("gz_boost", argumentCount: 4, pure: true) { values in
        guard let userLat = Double.fromDatabaseValue(values[0]),
              let userLng = Double.fromDatabaseValue(values[1]),
              let lat = Double.fromDatabaseValue(values[2]),
              let lng = Double.fromDatabaseValue(values[3]) else {
            // Ohne Nutzerposition entscheidet allein Textscore × Typ-Gewicht.
            return 1.0
        }
        return PlaceRanking.proximityBoost(
            user: CLLocationCoordinate2D(latitude: userLat, longitude: userLng),
            place: CLLocationCoordinate2D(latitude: lat, longitude: lng))
    }

    /// `CASE p.type WHEN 'city' THEN 3.0 … ELSE 1.5 END` aus denselben Gewichten,
    /// die auch Swift benutzt — die Tabelle steht genau einmal im Code.
    private static let typeWeightCase: String = {
        let cases = PlaceRanking.typeWeight
            .sorted { $0.key < $1.key }
            .map { "WHEN '\($0.key)' THEN \($0.value)" }
            .joined(separator: " ")
        return "CASE p.type \(cases) ELSE \(PlaceRanking.fallbackWeight) END"
    }()

    private static func sql(for table: IndexTable) -> String {
        let (name, bm25) = table == .fullText
            ? ("place_fts", "-bm25(place_fts, 3.0, 0.2)")
            : ("place_tri", "-bm25(place_tri)")
        return """
            SELECT * FROM (
              SELECT p.id AS id, p.name AS name, p.type AS type, p.state AS state,
                     p.city AS city, p.lat AS lat, p.lng AS lng,
                     \(bm25) AS text_score,
                     \(typeWeightCase) AS type_weight,
                     gz_boost(:userLat, :userLng, p.lat, p.lng) AS boost
              FROM \(name) JOIN place p ON p.id = \(name).rowid
              WHERE \(name) MATCH :match
            )
            ORDER BY text_score * type_weight * boost DESC
            LIMIT \(candidateLimit)
            """
    }

    private func fetch(_ queue: DatabaseQueue, match: String, table: IndexTable,
                       userPos: CLLocationCoordinate2D?) throws -> [ScoredRow] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: Self.sql(for: table), arguments: [
                "userLat": userPos?.latitude,
                "userLng": userPos?.longitude,
                "match": match,
            ])
            return rows.map { row in
                ScoredRow(place: Place(id: row["id"],
                                       name: row["name"] ?? "",
                                       type: row["type"] ?? "",
                                       state: row["state"] ?? "",
                                       city: row["city"] ?? "",
                                       lat: row["lat"] ?? 0,
                                       lng: row["lng"] ?? 0),
                          textScore: row["text_score"] ?? 0)
            }
        }
    }

    /// Jeder Term als Prefix-Phrase. Anfuehrungszeichen sind Pflicht: ein Term
    /// wie `and` waere sonst ein FTS5-Operator und nicht das gesuchte Wort.
    static func matchExpression(_ terms: [String], joiner: String) -> String {
        terms.map { "\(quoted($0))*" }.joined(separator: " \(joiner) ")
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
