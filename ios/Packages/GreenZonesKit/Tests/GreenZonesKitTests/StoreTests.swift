import Foundation
import GRDB
import Testing
@testable import GreenZonesKit

/// Port des Kerns von `client/src/lib/spots/__tests__/store.test.ts` (31 Faelle):
/// Persistenz ueber das Neuoeffnen, Upsert je participantId, Idempotenz und die
/// Regel „ein kaputter Eintrag faellt raus, nie der ganze Bestand".
///
/// Getestet wird gegen eine ECHTE SQLite (GRDB), nicht gegen ein Store-Double —
/// ein Mock naehme genau die Schicht weg, deren Roundtrip hier bewiesen wird.
@Suite("Community-Stores (GRDB)")
@MainActor
struct StoreTests {
    private func database(_ path: String? = nil) throws -> AppDatabase {
        try AppDatabase(path: path, migrations: CommunityMigrations.all)
    }

    private var epoch: Date { Date(epochMillis: 1_800_000_000_000) }

    // MARK: SpotStore

    @Test("startet leer, wenn nichts gespeichert ist")
    func empty() throws {
        let store = SpotStore(try database())
        #expect(store.spots.isEmpty)
        #expect(store.version == 0)
    }

    @Test("persistiert und liest ueber eine neue Instanz zurueck")
    func persists() async throws {
        let path = tempDatabasePath()
        let writer = SpotStore(try database(path))
        let spot = try await writer.addSpot(name: "Unsere Bank", emoji: "🌳",
                                            lng: 9.7218, lat: 52.3663)
        #expect(!spot.id.isEmpty)

        let reader = SpotStore(try database(path))
        #expect(reader.spots.map(\.id) == [spot.id])
        #expect(reader.spots[0].name == "Unsere Bank")
        // Die Zeit ueberlebt den Roundtrip millisekundengenau (Epoch-ms in der DB).
        #expect(reader.spots[0].createdAt.epochMillis == spot.createdAt.epochMillis)
    }

    @Test("removeSpot loescht auch aus der Datenbank und ist idempotent")
    func removes() async throws {
        let path = tempDatabasePath()
        let writer = SpotStore(try database(path))
        let bank = try await writer.addSpot(name: "Unsere Bank", emoji: "🌳", lng: 9.72, lat: 52.36)
        let hbf = try await writer.addSpot(name: "Hbf", emoji: "🚉", lng: 9.7411, lat: 52.3767)

        try await writer.removeSpot(id: bank.id)
        #expect(writer.spots.map(\.id) == [hbf.id])

        let version = writer.version
        try await writer.removeSpot(id: "gibt-es-nicht")
        #expect(writer.version == version)

        let reader = SpotStore(try database(path))
        #expect(reader.spots.map(\.id) == [hbf.id])
    }

    @Test("ein kaputter Eintrag faellt raus statt den Start zu kippen")
    func corruptRowIsDropped() throws {
        let db = try database()
        // SQLite ist dynamisch typisiert: Text in einer REAL-Spalte ist erlaubt.
        // So ein Spot ist nicht lesbar — er faellt raus, der gute bleibt.
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO spot (id, name, emoji, lng, lat, createdAt, sharePending)
                VALUES ('kaputt', 'Kaputt', '🌳', 'nicht-numerisch', 52.3, 1, 0)
                """)
            try db.execute(sql: """
                INSERT INTO spot (id, name, emoji, lng, lat, createdAt, sharePending)
                VALUES ('gut', 'Unsere Bank', '🌳', 9.72, 52.36, 2, 0)
                """)
        }
        let store = SpotStore(db)
        #expect(store.spots.map(\.id) == ["gut"])
    }

    @Test("Snapshot und Version bleiben stehen, bis wirklich etwas mutiert")
    func stableSnapshot() async throws {
        let store = SpotStore(try database())
        let empty = store.spots
        #expect(store.version == 0)

        let spot = try await store.addSpot(name: "Unsere Bank", emoji: "🌳", lng: 9.72, lat: 52.36)
        #expect(store.spots != empty)
        let version = store.version
        #expect(version == 1)

        // No-Op darf weder schreiben noch die Version erhoehen.
        try await store.removeSpot(id: "gibt-es-nicht")
        #expect(store.version == version)

        try await store.removeSpot(id: spot.id)
        #expect(store.version == version + 1)
    }

    @Test("setCloudState schreibt nur bei echter Aenderung, unbekannte id ist ein No-Op")
    func cloudState() async throws {
        let store = SpotStore(try database())
        let spot = try await store.addSpot(name: "Unsere Bank", emoji: "🌳", lng: 9.72, lat: 52.36)
        let version = store.version

        try await store.setCloudState(id: spot.id,
                                      SpotCloudState(zoneName: "spot-\(spot.id)",
                                                     participantIds: ["f1"]))
        #expect(store.version == version + 1)
        #expect(store.spot(id: spot.id)?.zoneName == "spot-\(spot.id)")
        #expect(store.spot(id: spot.id)?.participantIds == ["f1"])

        try await store.setCloudState(id: spot.id,
                                      SpotCloudState(zoneName: "spot-\(spot.id)",
                                                     participantIds: ["f1"]))
        #expect(store.version == version + 1)

        // Unbekannte id ist ein No-Op (der Spot kann inzwischen entfernt sein).
        try await store.setCloudState(id: "gibt-es-nicht", SpotCloudState(sharePending: true))
        #expect(store.version == version + 1)
    }

    @Test("replaceAll ist bei inhaltsgleicher Liste eine Nulloperation")
    func replaceAllNoop() async throws {
        let store = SpotStore(try database())
        try await store.addSpot(name: "Unsere Bank", emoji: "🌳", lng: 9.72, lat: 52.36)
        let before = store.spots
        let version = store.version

        try await store.replaceAll(before)
        #expect(store.spots == before)
        #expect(store.version == version)

        try await store.replaceAll([])
        #expect(store.spots.isEmpty)
        #expect(store.version == version + 1)
    }

    // MARK: FriendStore

    @Test("FriendStore bekommt seinen Bestand ueber replaceAll aus dem Sync")
    func friendsReplaceAll() async throws {
        let path = tempDatabasePath()
        let store = FriendStore(try database(path))
        #expect(store.friends.isEmpty)
        let tara = Friend(id: "f1", name: "Tara", color: "#0A9B8E", friendshipZone: "friend-1")
        try await store.replaceAll([tara])

        let reader = FriendStore(try database(path))
        #expect(reader.friends == [tara])
    }

    @Test("FriendStore filtert kaputte Zeilen und laesst die gute stehen")
    func friendsCorrupt() throws {
        let db = try database()
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO friend (id, name, color, blocked) VALUES ('f1', 'Tara', '#0A9B8E', 0)")
            // `name` als Blob mit ungueltigem UTF-8: nicht als String lesbar → Zeile faellt raus.
            try db.execute(sql: "INSERT INTO friend (id, name, color, blocked) VALUES ('f2', X'FFFE', '#7C5CFF', 0)")
        }
        let store = FriendStore(db)
        #expect(store.friends.map(\.id) == ["f1"])
    }

    // MARK: invitationActive

    @Test("invitationActive: aktiv bis Anker + LINGER, abgesagt nie")
    func activeWindow() {
        let time = epoch
        let base = Invitation(id: "i1", spotId: "s1", hostId: SELF_ID, time: time,
                              createdAt: time.addingTimeInterval(-3600), cancelled: false)
        #expect(invitationActive(base, now: time.addingTimeInterval(-60)))
        #expect(invitationActive(base, now: time.addingTimeInterval(INVITATION_LINGER - 0.001)))
        #expect(!invitationActive(base, now: time.addingTimeInterval(INVITATION_LINGER)))
        #expect(!invitationActive(base, now: time.addingTimeInterval(INVITATION_LINGER + 1)))

        var cancelled = base
        cancelled.cancelled = true
        #expect(!invitationActive(cancelled, now: time.addingTimeInterval(-60)))
    }

    // MARK: InviteStore

    private func seeded(_ path: String? = nil) async throws -> (AppDatabase, SpotStore, InviteStore) {
        let db = try database(path)
        let spots = SpotStore(db)
        let invites = InviteStore(db)
        try await spots.replaceAll([
            Spot(id: "s1", name: "Unsere Bank", emoji: "🪑", lng: 9.72, lat: 52.36,
                 createdAt: Date(epochMillis: 1)),
            Spot(id: "s2", name: "Maschsee-Ecke", emoji: "🌳", lng: 9.74, lat: 52.37,
                 createdAt: Date(epochMillis: 2)),
        ])
        return (db, spots, invites)
    }

    private func invitation(_ id: String, spot: String, time: Date, createdAt: Int64,
                            cancelled: Bool = false, replies: [Reply] = []) -> Invitation {
        Invitation(id: id, spotId: spot, hostId: SELF_ID, time: time,
                   createdAt: Date(epochMillis: createdAt), cancelled: cancelled, replies: replies)
    }

    @Test("activeFor waehlt bei mehreren aktiven die neueste")
    func activeForNewest() async throws {
        let (_, _, invites) = try await seeded()
        try await invites.replaceAll([
            invitation("alt", spot: "s1", time: epoch, createdAt: 100),
            invitation("neu", spot: "s1", time: epoch.addingTimeInterval(60), createdAt: 300),
            invitation("mittel", spot: "s1", time: epoch, createdAt: 200),
        ])
        #expect(invites.activeFor(spotId: "s1", now: epoch)?.id == "neu")
    }

    @Test("activeFor ignoriert abgesagte, abgelaufene und fremde Spots")
    func activeForFilters() async throws {
        let (_, _, invites) = try await seeded()
        try await invites.replaceAll([
            invitation("aktiv", spot: "s1", time: epoch, createdAt: 100),
            invitation("abgesagt", spot: "s1", time: epoch, createdAt: 900, cancelled: true),
            invitation("alt", spot: "s1", time: epoch.addingTimeInterval(-INVITATION_LINGER),
                       createdAt: 800),
            invitation("fremd", spot: "s2", time: epoch, createdAt: 999),
        ])
        #expect(invites.activeFor(spotId: "s1", now: epoch)?.id == "aktiv")
        #expect(invites.activeFor(spotId: "s2", now: epoch)?.id == "fremd")
        #expect(invites.activeFor(spotId: "s3", now: epoch) == nil)
        #expect(invites.activeFor(spotId: "s1", now: epoch.addingTimeInterval(INVITATION_LINGER)) == nil)
    }

    @Test("setReply macht ein Upsert pro participantId — auch ueber das Neuoeffnen")
    func replyUpsert() async throws {
        let path = tempDatabasePath()
        let (_, _, invites) = try await seeded(path)
        let inv = invitation("i1", spot: "s1", time: epoch, createdAt: 1)
        try await invites.add(inv)

        let tara = Reply(participantId: "f1", status: .ind,
                         arrivalTime: epoch.addingTimeInterval(3600))
        let marcel = Reply(participantId: "f2", status: .ind)
        try await invites.setReply(id: inv.id, tara)
        try await invites.setReply(id: inv.id, marcel)
        try await invites.setReply(id: inv.id, Reply(participantId: "f1", status: .out))

        let replies = invites.invitations[0].replies
        #expect(replies.count == 2)
        #expect(replies[0] == Reply(participantId: "f1", status: .out))
        #expect(replies[1] == marcel)

        let db = try database(path)
        _ = SpotStore(db)
        let reader = InviteStore(db)
        #expect(reader.invitations[0].replies == replies)
    }

    @Test("changeTime verschiebt nur den Anker — Antworten bleiben unveraendert")
    func changeTimeKeepsReplies() async throws {
        let (_, _, invites) = try await seeded()
        let inv = invitation("i1", spot: "s1", time: epoch, createdAt: 1)
        try await invites.add(inv)
        let tara = Reply(participantId: "f1", status: .ind,
                         arrivalTime: epoch.addingTimeInterval(3600))
        try await invites.setReply(id: inv.id, tara)

        try await invites.changeTime(id: inv.id, time: epoch.addingTimeInterval(1800))

        let after = invites.invitations[0]
        #expect(after.time == epoch.addingTimeInterval(1800))
        #expect(after.replies == [tara])
    }

    @Test("cancel beendet die Einladung — der Spot bleibt unberuehrt")
    func cancel() async throws {
        let (_, spots, invites) = try await seeded()
        let inv = invitation("i1", spot: "s1", time: epoch, createdAt: 1)
        try await invites.add(inv)
        try await invites.cancel(id: inv.id)

        #expect(invites.activeFor(spotId: "s1", now: epoch) == nil)
        #expect(invites.invitations[0].cancelled)
        #expect(spots.spot(id: "s1") != nil)
    }

    @Test("meldet eine unbekannte id und bleibt danach benutzbar")
    func unknownId() async throws {
        let (_, _, invites) = try await seeded()
        let reply = Reply(participantId: "f1", status: .ind)
        await #expect(throws: InviteStoreError.unknownInvitation("weg")) {
            try await invites.setReply(id: "weg", reply)
        }
        await #expect(throws: InviteStoreError.unknownInvitation("weg")) {
            try await invites.changeTime(id: "weg", time: epoch)
        }
        await #expect(throws: InviteStoreError.unknownInvitation("weg")) {
            try await invites.cancel(id: "weg")
        }

        let inv = invitation("i1", spot: "s1", time: epoch, createdAt: 1)
        try await invites.add(inv)
        #expect(invites.activeFor(spotId: "s1", now: epoch)?.id == "i1")
    }

    @Test("verwirft kaputte Antworten, nicht die ganze Einladung")
    func corruptReply() async throws {
        let db = try database()
        let spots = SpotStore(db)
        try await spots.replaceAll([Spot(id: "s1", name: "Unsere Bank", emoji: "🪑",
                                         lng: 9.72, lat: 52.36, createdAt: Date(epochMillis: 1))])
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO invitation (id, spotId, hostId, time, createdAt, cancelled)
                VALUES ('i1', 's1', 'me', 1800000000000, 1, 0)
                """)
            try db.execute(sql: """
                INSERT INTO reply (invitationId, participantId, status, arrivalTime)
                VALUES ('i1', 'f1', 'in', NULL)
                """)
            // Unbekannter Status: das ist keine Antwort — sie faellt raus.
            try db.execute(sql: """
                INSERT INTO reply (invitationId, participantId, status, arrivalTime)
                VALUES ('i1', 'f3', 'vielleicht', NULL)
                """)
        }
        let invites = InviteStore(db)
        #expect(invites.invitations.count == 1)
        #expect(invites.invitations[0].replies.map(\.participantId) == ["f1"])
    }

    @Test("mit dem Spot gehen Einladung, Antworten und Teilnehmer — der Fremdschluessel haelt die Regel")
    func cascade() async throws {
        let (db, spots, invites) = try await seeded()
        try await spots.setCloudState(id: "s1", SpotCloudState(participantIds: ["f1"]))
        try await invites.add(invitation("i1", spot: "s1", time: epoch, createdAt: 1))
        try await invites.setReply(id: "i1", Reply(participantId: "f1", status: .ind))
        try await invites.add(invitation("i2", spot: "s2", time: epoch, createdAt: 2))
        #expect(invites.invitations.count == 2)

        try await spots.removeSpot(id: "s1")

        // Direkt an der Datenbank geprueft: die Regel steht im Schema, nicht in
        // der Erinnerung eines Schreibpfads.
        let counts = try await db.writer.read { db in
            (invitations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM invitation WHERE spotId = 's1'") ?? -1,
             replies: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reply WHERE invitationId = 'i1'") ?? -1,
             participants: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spot_participant WHERE spotId = 's1'") ?? -1,
             rest: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM invitation") ?? -1)
        }
        #expect(counts.invitations == 0)
        #expect(counts.replies == 0)
        #expect(counts.participants == 0)
        #expect(counts.rest == 1)
    }

    // MARK: SettingsStore

    @Test("SettingsStore haelt Profil und Profil-Frage ueber das Neuoeffnen")
    func settings() async throws {
        let path = tempDatabasePath()
        let store = SettingsStore(try database(path))
        #expect(store.profile == Profile())
        #expect(!store.profileAsked)

        try await store.setProfile(Profile(displayName: "Leon", emoji: "🌿"))
        try await store.setProfileAsked(true)

        let reader = SettingsStore(try database(path))
        #expect(reader.profile == Profile(displayName: "Leon", emoji: "🌿"))
        #expect(reader.profileAsked)
    }
}
