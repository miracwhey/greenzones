import Foundation
import GRDB

/// Migrationsschritte der Snaps (SPEC 4). Eigener Satz, damit die Composition
/// Root ihn wie Suche und Community einsammelt.
public enum SnapMigrations {
    public static let all: [DBMigration] = [
        DBMigration("snap.v1") { db in
            try db.create(table: "snap") { t in
                t.column("id", .text).primaryKey()
                t.column("authorId", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("lat", .double).notNull()
                t.column("lng", .double).notNull()
                // Kein Fremdschluessel auf `spot`: ein fremder Feed-Snap kann
                // einen Spot nennen, den ich (noch) nicht habe. Die Zuordnung
                // laeuft ueber `spotZone` und darf den Snap nicht kosten.
                t.column("spotId", .text)
                t.column("spotZone", .text)
                t.column("spotName", .text)
                t.column("spotEmoji", .text)
                t.column("scope", .text).notNull()
                t.column("zoneName", .text)
                t.column("recordName", .text)
                t.column("thumbPath", .text)
                t.column("photoPath", .text)
                t.column("uploadState", .text).notNull()
                t.column("hidden", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "snap_spot", on: "snap", columns: ["spotZone"])
            try db.create(index: "snap_created", on: "snap", columns: ["createdAt"])

            // Gemeldete fremde Snaps: der Report geht in die Cloud, die
            // Ausblendung ist lokal (`snap.hidden`). Diese Tabelle merkt sich,
            // was schon gemeldet wurde — ein zweiter Report derselben Person
            // waere derselbe Record, aber ein zweiter Netz-Aufruf.
            try db.create(table: "snap_report") { t in
                t.column("snapId", .text).primaryKey()
                t.column("createdAt", .integer).notNull()
            }
        },
        DBMigration("snap.v2") { db in
            // Auftraege fuer die Cloud, deren Snap lokal schon weg ist.
            //
            // Loeschen ging bis zum 18.08. zuerst in die Cloud: ohne Konto oder
            // Netz warf der Aufruf, und der Snap blieb liegen — der Knopf tat
            // dann nichts. Jetzt gilt die Entscheidung sofort auf dem Geraet,
            // und der Auftrag wartet hier, bis er durch ist. Dieselbe Regel wie
            // beim Upload, nur andersherum: nichts vortaeuschen, aber auch
            // nichts vom Netz abhaengig machen, was lokal entschieden ist.
            //
            // Der Auftrag ueberlebt den Snap absichtlich als eigene Zeile — an
            // einer geloeschten Zeile kann nichts mehr haengen.
            try db.create(table: "snap_deletion") { t in
                t.column("recordName", .text).primaryKey()
                t.column("zoneName", .text).notNull()
                t.column("queuedAt", .integer).notNull()
            }
        },
    ]
}

/// Ein wartender Loeschauftrag.
public struct SnapDeletion: Equatable, Sendable {
    public let zoneName: String
    public let recordName: String

    public init(zoneName: String, recordName: String) {
        self.zoneName = zoneName
        self.recordName = recordName
    }
}

extension Snap {
    init?(row: Row) {
        guard let id = dbString(row, "id"),
              let authorId = dbString(row, "authorId"),
              let createdAt = dbInt(row, "createdAt"),
              let lat = dbDouble(row, "lat"), let lng = dbDouble(row, "lng"),
              let scope = dbString(row, "scope").flatMap(SnapScope.init(rawValue:)),
              let state = dbString(row, "uploadState").flatMap(SnapUploadState.init(rawValue:))
        else { return nil }
        self.init(id: id,
                  authorId: authorId,
                  createdAt: Date(timeIntervalSince1970: Double(createdAt) / 1000),
                  lat: lat, lng: lng,
                  spotId: dbString(row, "spotId"),
                  spotZone: dbString(row, "spotZone"),
                  spotName: dbString(row, "spotName"),
                  spotEmoji: dbString(row, "spotEmoji"),
                  scope: scope,
                  zoneName: dbString(row, "zoneName"),
                  recordName: dbString(row, "recordName"),
                  thumbPath: dbString(row, "thumbPath"),
                  photoPath: dbString(row, "photoPath"),
                  uploadState: state,
                  hidden: dbInt(row, "hidden") == 1)
    }
}

public enum SnapQueries {
    // `@Sendable`, weil die Beobachtung die Funktion auf einen anderen Thread
    // reicht. Ohne die Markierung uebersetzt Swift 6 das in einen Fehler.
    @Sendable
    public static func snaps(_ db: Database) throws -> [Snap] {
        try Row.fetchAll(db, sql: "SELECT * FROM snap ORDER BY createdAt DESC, id")
            .compactMap(Snap.init(row:))
    }

    static func upsert(_ db: Database, snap: Snap) throws {
        try db.execute(sql: """
            INSERT INTO snap (id, authorId, createdAt, lat, lng, spotId, spotZone, spotName,
                              spotEmoji, scope, zoneName, recordName, thumbPath, photoPath,
                              uploadState, hidden)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                authorId = excluded.authorId, createdAt = excluded.createdAt,
                lat = excluded.lat, lng = excluded.lng, spotId = excluded.spotId,
                spotZone = excluded.spotZone, spotName = excluded.spotName,
                spotEmoji = excluded.spotEmoji, scope = excluded.scope,
                zoneName = excluded.zoneName, recordName = excluded.recordName,
                -- Die Dateipfade gehoeren dem Geraet: ein Merge aus der Cloud
                -- kennt sie nicht und darf einen geladenen Thumb nicht loeschen.
                thumbPath = COALESCE(excluded.thumbPath, snap.thumbPath),
                photoPath = COALESCE(excluded.photoPath, snap.photoPath),
                uploadState = excluded.uploadState,
                -- Ausblenden ist eine lokale Entscheidung; sie ueberlebt jeden Merge.
                hidden = MAX(excluded.hidden, snap.hidden)
            """,
            arguments: [snap.id, snap.authorId, Int(snap.createdAt.timeIntervalSince1970 * 1000),
                        snap.lat, snap.lng, snap.spotId, snap.spotZone, snap.spotName,
                        snap.spotEmoji, snap.scope.rawValue, snap.zoneName, snap.recordName,
                        snap.thumbPath, snap.photoPath, snap.uploadState.rawValue,
                        snap.hidden ? 1 : 0])
    }
}

public enum SnapStoreError: Error, Equatable {
    case unknownSnap(String)
}

/// Bestand aller Snaps — eigene wie fremde.
@MainActor
@Observable
public final class SnapStore {
    public private(set) var snaps: [Snap] = []

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let files: SnapFiles
    @ObservationIgnored private let observer = StoreObserver()

    public init(_ database: AppDatabase, files: SnapFiles = SnapFiles()) {
        self.database = database
        self.files = files
        observer.start(database, fetch: SnapQueries.snaps) { [weak self] in
            self?.apply($0)
        }
    }

    public func snap(id: String) -> Snap? { snaps.first { $0.id == id } }

    public func album(of spot: Spot) -> [Snap] { albumSnaps(snaps, spot: spot) }

    public var freePins: [Snap] { freeSnaps(snaps) }

    /// Snaps, deren Upload noch aussteht — Reihenfolge alt→neu, damit der
    /// erste Versuch dem ersten Foto gilt.
    public var outbox: [Snap] {
        snaps.filter { $0.isMine && $0.uploadState.isOutstanding }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ snap: Snap) async throws {
        try await database.writer.write { db in try SnapQueries.upsert(db, snap: snap) }
        reload()
    }

    public func saveAll(_ incoming: [Snap]) async throws {
        guard !incoming.isEmpty else { return }
        try await database.writer.write { db in
            for snap in incoming { try SnapQueries.upsert(db, snap: snap) }
        }
        reload()
    }

    public func setUploadState(id: String, _ state: SnapUploadState,
                               zoneName: String? = nil, recordName: String? = nil) async throws {
        guard var snap = snap(id: id) else { throw SnapStoreError.unknownSnap(id) }
        snap.uploadState = state
        if let zoneName { snap.zoneName = zoneName }
        if let recordName { snap.recordName = recordName }
        try await save(snap)
    }

    public func setThumbPath(id: String, _ path: String) async throws {
        guard var snap = snap(id: id) else { throw SnapStoreError.unknownSnap(id) }
        snap.thumbPath = path
        try await save(snap)
    }

    public func setPhotoPath(id: String, _ path: String) async throws {
        guard var snap = snap(id: id) else { throw SnapStoreError.unknownSnap(id) }
        snap.photoPath = path
        try await save(snap)
    }

    /// Ausblenden (melden oder selbst verbergen). Die Dateien bleiben liegen,
    /// bis der Snap wirklich geloescht wird — ein Melden soll nicht heimlich
    /// Daten vernichten, die noch gebraucht werden koennten.
    public func hide(id: String) async throws {
        guard var snap = snap(id: id) else { throw SnapStoreError.unknownSnap(id) }
        guard !snap.hidden else { return }
        snap.hidden = true
        try await save(snap)
    }

    /// Endgueltig weg: Zeile UND Dateien.
    public func remove(id: String) async throws {
        guard let snap = snap(id: id) else { return }
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM snap WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM snap_report WHERE snapId = ?", arguments: [id])
        }
        files.delete(snap)
        reload()
    }

    // MARK: - Wartende Loeschauftraege

    /// Loeschauftrag vormerken. Wird beim naechsten Durchlauf der Outbox an die
    /// Cloud gereicht und dort wieder gestrichen.
    public func queueDeletion(zoneName: String, recordName: String, at date: Date) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO snap_deletion (recordName, zoneName, queuedAt) VALUES (?, ?, ?)
                ON CONFLICT(recordName) DO NOTHING
                """, arguments: [recordName, zoneName, Int(date.timeIntervalSince1970 * 1000)])
        }
    }

    /// Auftraege alt→neu: der erste Versuch gilt der aeltesten Entscheidung.
    public func pendingDeletions() throws -> [SnapDeletion] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT recordName, zoneName FROM snap_deletion ORDER BY queuedAt, recordName
                """)
            .compactMap { row in
                guard let record = dbString(row, "recordName"),
                      let zone = dbString(row, "zoneName") else { return nil }
                return SnapDeletion(zoneName: zone, recordName: record)
            }
        }
    }

    public func clearDeletion(recordName: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM snap_deletion WHERE recordName = ?",
                           arguments: [recordName])
        }
    }

    /// Wurde dieser Snap von mir schon gemeldet?
    public func isReported(id: String) throws -> Bool {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM snap_report WHERE snapId = ?",
                             arguments: [id]) ?? 0 > 0
        }
    }

    public func markReported(id: String, at date: Date) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO snap_report (snapId, createdAt) VALUES (?, ?)
                ON CONFLICT(snapId) DO NOTHING
                """, arguments: [id, Int(date.timeIntervalSince1970 * 1000)])
        }
    }

    private func reload() {
        guard let fresh = try? database.writer.read(SnapQueries.snaps) else { return }
        apply(fresh)
    }

    private func apply(_ fresh: [Snap]) {
        guard fresh != snaps else { return }
        snaps = fresh
    }
}
