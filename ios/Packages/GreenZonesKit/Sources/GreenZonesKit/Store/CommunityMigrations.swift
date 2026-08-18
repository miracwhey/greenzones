import Foundation
import GRDB

/// Tabellen des Community-Features (SPEC 4). Das Feature bringt seine
/// Migrationsschritte selbst mit; die Composition Root sammelt sie ein.
///
/// Zeiten liegen als **Epoch-Millisekunden** (INTEGER) in der DB — dasselbe Maß,
/// das v1 in seinen JSON-Bestand geschrieben hat. Der `V1Importer` kann die
/// Werte damit ohne Umrechnung uebernehmen.
///
/// Die Fremdschluessel sind Absicht, nicht Zierde: eine Einladung ohne ihren
/// Spot ist eine Karteileiche (v1-Merge-Regel „mit dem Spot geht auch seine
/// Einladung"), eine Antwort ohne ihre Einladung ebenso. `ON DELETE CASCADE`
/// macht daraus eine Eigenschaft des Schemas statt einer Regel, an die sich
/// jeder Schreibpfad erinnern muss.
public enum CommunityMigrations {
    public static let all: [DBMigration] = [
        DBMigration("community_v1") { db in
            try db.create(table: "spot") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("emoji", .text).notNull()
                t.column("lng", .double).notNull()
                t.column("lat", .double).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("zoneName", .text)
                t.column("ownerId", .text)
                t.column("shareURL", .text)
                t.column("sharePending", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "spot_participant") { t in
                t.column("spotId", .text).notNull()
                    .references("spot", onDelete: .cascade)
                t.column("userId", .text).notNull()
                t.primaryKey(["spotId", "userId"])
            }

            try db.create(table: "friend") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("emoji", .text)
                t.column("color", .text).notNull()
                t.column("friendshipZone", .text)
                // Feed-Zone und Blockieren gehoeren ab W4/W5 dazu (SPEC 7); die
                // Spalten stehen jetzt, damit spaeter keine Datenmigration noetig ist.
                t.column("feedZone", .text)
                t.column("blocked", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "invitation") { t in
                t.column("id", .text).primaryKey()
                t.column("spotId", .text).notNull()
                    .references("spot", onDelete: .cascade)
                t.column("hostId", .text).notNull()
                t.column("time", .integer).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("cancelled", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "invitation_spot", on: "invitation", columns: ["spotId"])

            try db.create(table: "reply") { t in
                t.column("invitationId", .text).notNull()
                    .references("invitation", onDelete: .cascade)
                t.column("participantId", .text).notNull()
                t.column("status", .text).notNull()
                t.column("arrivalTime", .integer)
                t.primaryKey(["invitationId", "participantId"])
            }

            try db.create(table: "setting") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        },
        DBMigration("community_v2") { db in
            // Wer bei DIESEM Termin gemeint ist (Leon, 18.08.): die Spot-Runde
            // ist dauerhaft, die Einladung gilt einer Teilmenge davon.
            //
            // Eigene Tabelle wie `spot_participant` — dasselbe Muster fuer
            // dieselbe Sache. Eine LEERE Menge heisst „alle Spot-Mitglieder";
            // so bleiben die Einladungen lesbar, die vor dieser Migration
            // entstanden sind (siehe `Invitation.invitees(spotParticipants:)`).
            try db.create(table: "invitation_invitee") { t in
                t.column("invitationId", .text).notNull()
                    .references("invitation", onDelete: .cascade)
                t.column("userId", .text).notNull()
                t.primaryKey(["invitationId", "userId"])
            }
        },
    ]
}

// MARK: - Zeit an der DB-Grenze

extension Date {
    /// Epoch-Millisekunden — das Maß, in dem v1 gespeichert hat.
    var epochMillis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(epochMillis: Int64) {
        self.init(timeIntervalSince1970: Double(epochMillis) / 1000)
    }

    /// Auf Millisekunden gekuerzt. `Date()` traegt Mikrosekunden, die DB nicht —
    /// ohne diese Kuerzung waere ein frisch erzeugter Wert nach dem Roundtrip
    /// ein ANDERER, und „inhaltsgleich" traefe nie zu (Endlos-Schreiben im Merge).
    var millisecondPrecision: Date { Date(epochMillis: epochMillis) }
}

// MARK: - Lesen: ein kaputter Eintrag faellt raus, nie der ganze Bestand

/// Nachsichtiges Lesen: GRDBs `row["x"] as T?` dekodiert mit `try!` und stuerzt
/// bei einem Typfehler ab. SQLite ist aber dynamisch typisiert — in einer
/// REAL-Spalte kann Text stehen. Ueber `fromDatabaseValue` wird daraus ein `nil`
/// und damit eine verworfene Zeile statt eines Absturzes beim Start.
func dbString(_ row: Row, _ column: String) -> String? {
    String.fromDatabaseValue(row[column])
}

func dbDouble(_ row: Row, _ column: String) -> Double? {
    Double.fromDatabaseValue(row[column])
}

func dbInt(_ row: Row, _ column: String) -> Int64? {
    Int64.fromDatabaseValue(row[column])
}

extension Spot {
    /// `nil` = Zeile verwerfen. Ein kaputter Spot faellt raus, statt den Start
    /// der App zu kippen.
    init?(row: Row, participantIds: [String]) {
        guard let id = dbString(row, "id"),
              let name = dbString(row, "name"),
              let emoji = dbString(row, "emoji"),
              let lng = dbDouble(row, "lng"),
              let lat = dbDouble(row, "lat"),
              let createdAt = dbInt(row, "createdAt")
        else { return nil }
        self.init(id: id,
                  name: name,
                  emoji: emoji,
                  lng: lng,
                  lat: lat,
                  createdAt: Date(epochMillis: createdAt),
                  zoneName: dbString(row, "zoneName"),
                  ownerId: dbString(row, "ownerId"),
                  participantIds: participantIds,
                  shareURL: dbString(row, "shareURL"),
                  sharePending: dbInt(row, "sharePending") == 1)
    }
}

extension Friend {
    init?(row: Row) {
        guard let id = dbString(row, "id"),
              let name = dbString(row, "name"),
              let color = dbString(row, "color")
        else { return nil }
        self.init(id: id,
                  name: name,
                  emoji: dbString(row, "emoji"),
                  color: color,
                  friendshipZone: dbString(row, "friendshipZone"),
                  feedZone: dbString(row, "feedZone"),
                  blocked: dbInt(row, "blocked") == 1)
    }
}

extension Reply {
    /// Eine Antwort mit unbekanntem Status ist keine Antwort — sie faellt raus,
    /// nicht die Einladung (v1 `parseReply`).
    init?(row: Row) {
        guard let participantId = dbString(row, "participantId"),
              let raw = dbString(row, "status"),
              let status = ReplyStatus(rawValue: raw)
        else { return nil }
        self.init(participantId: participantId,
                  status: status,
                  arrivalTime: dbInt(row, "arrivalTime").map { Date(epochMillis: $0) })
    }
}

extension Invitation {
    init?(row: Row, replies: [Reply], inviteeIds: [String] = []) {
        guard let id = dbString(row, "id"),
              let spotId = dbString(row, "spotId"),
              let hostId = dbString(row, "hostId"),
              let time = dbInt(row, "time"),
              let createdAt = dbInt(row, "createdAt")
        else { return nil }
        self.init(id: id,
                  spotId: spotId,
                  hostId: hostId,
                  time: Date(epochMillis: time),
                  createdAt: Date(epochMillis: createdAt),
                  cancelled: dbInt(row, "cancelled") == 1,
                  replies: replies,
                  inviteeIds: inviteeIds)
    }
}

// MARK: - Fetch (kanonische Reihenfolge)

/// Die DB kennt keine Reihenfolge — die Listen kommen deshalb IMMER kanonisch
/// sortiert heraus. Nur so ist „derselbe Bestand zweimal" auch dieselbe Liste,
/// und der Vergleich vor dem Schreiben kann Scheinaenderungen erkennen.
public enum CommunityQueries {
    public static func spots(_ db: Database) throws -> [Spot] {
        var participants: [String: [String]] = [:]
        let rows = try Row.fetchAll(db, sql: "SELECT spotId, userId FROM spot_participant ORDER BY userId")
        for row in rows {
            guard let spotId = dbString(row, "spotId"), let userId = dbString(row, "userId") else { continue }
            participants[spotId, default: []].append(userId)
        }
        return try Row.fetchAll(db, sql: "SELECT * FROM spot ORDER BY createdAt, id")
            .compactMap { Spot(row: $0, participantIds: participants[dbString($0, "id") ?? ""] ?? []) }
    }

    public static func friends(_ db: Database) throws -> [Friend] {
        try Row.fetchAll(db, sql: "SELECT * FROM friend ORDER BY name, id")
            .compactMap(Friend.init(row:))
    }

    public static func invitations(_ db: Database) throws -> [Invitation] {
        var replies: [String: [Reply]] = [:]
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM reply ORDER BY participantId")
        for row in rows {
            guard let invitationId = dbString(row, "invitationId"), let reply = Reply(row: row) else { continue }
            replies[invitationId, default: []].append(reply)
        }
        var invitees: [String: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM invitation_invitee ORDER BY userId") {
            guard let invitationId = dbString(row, "invitationId"),
                  let userId = dbString(row, "userId") else { continue }
            invitees[invitationId, default: []].append(userId)
        }
        return try Row.fetchAll(db, sql: "SELECT * FROM invitation ORDER BY createdAt, id")
            .compactMap { row in
                let id = dbString(row, "id") ?? ""
                return Invitation(row: row, replies: replies[id] ?? [],
                                  inviteeIds: invitees[id] ?? [])
            }
    }

    public static func settings(_ db: Database) throws -> [String: String] {
        var out: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, value FROM setting") {
            guard let key = dbString(row, "key"), let value = dbString(row, "value") else { continue }
            out[key] = value
        }
        return out
    }

    // MARK: Schreiben

    static func write(_ db: Database, spots: [Spot]) throws {
        try db.execute(sql: "DELETE FROM spot")
        for spot in spots {
            try db.execute(sql: """
                INSERT INTO spot (id, name, emoji, lng, lat, createdAt, zoneName, ownerId, shareURL, sharePending)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [spot.id, spot.name, spot.emoji, spot.lng, spot.lat,
                            spot.createdAt.epochMillis, spot.zoneName, spot.ownerId,
                            spot.shareURL, spot.sharePending ? 1 : 0])
            for userId in Set(spot.participantIds).sorted() {
                try db.execute(sql: "INSERT INTO spot_participant (spotId, userId) VALUES (?, ?)",
                               arguments: [spot.id, userId])
            }
        }
    }

    static func write(_ db: Database, friends: [Friend]) throws {
        try db.execute(sql: "DELETE FROM friend")
        for friend in friends {
            try db.execute(sql: """
                INSERT INTO friend (id, name, emoji, color, friendshipZone, feedZone, blocked)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [friend.id, friend.name, friend.emoji, friend.color,
                            friend.friendshipZone, friend.feedZone, friend.blocked ? 1 : 0])
        }
    }

    static func write(_ db: Database, invitations: [Invitation]) throws {
        try db.execute(sql: "DELETE FROM invitation")
        for invitation in invitations {
            try insert(db, invitation: invitation)
        }
    }

    static func insert(_ db: Database, invitation: Invitation) throws {
        try db.execute(sql: """
            INSERT INTO invitation (id, spotId, hostId, time, createdAt, cancelled)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [invitation.id, invitation.spotId, invitation.hostId,
                        invitation.time.epochMillis, invitation.createdAt.epochMillis,
                        invitation.cancelled ? 1 : 0])
        for reply in invitation.replies {
            try upsert(db, invitationId: invitation.id, reply: reply)
        }
        try writeInvitees(db, invitationId: invitation.id, userIds: invitation.inviteeIds)
    }

    /// Eingeladene einer Einladung setzen (erst raeumen, dann schreiben — die
    /// Menge ist die Wahrheit, nicht die Summe aller je geschriebenen Zeilen).
    static func writeInvitees(_ db: Database, invitationId: String, userIds: [String]) throws {
        try db.execute(sql: "DELETE FROM invitation_invitee WHERE invitationId = ?",
                       arguments: [invitationId])
        for userId in Set(userIds).sorted() {
            try db.execute(sql: """
                INSERT INTO invitation_invitee (invitationId, userId) VALUES (?, ?)
                """, arguments: [invitationId, userId])
        }
    }

    static func upsert(_ db: Database, invitationId: String, reply: Reply) throws {
        try db.execute(sql: """
            INSERT INTO reply (invitationId, participantId, status, arrivalTime)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(invitationId, participantId)
            DO UPDATE SET status = excluded.status, arrivalTime = excluded.arrivalTime
            """,
            arguments: [invitationId, reply.participantId, reply.status.rawValue,
                        reply.arrivalTime?.epochMillis])
    }
}
