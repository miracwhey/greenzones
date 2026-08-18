import Foundation
import GRDB

/// Lokale Datenschicht fuer Spots · Freunde · Einladungen · Einstellungen.
/// Port von `client/src/lib/spots/store.ts` auf GRDB.
///
/// Drei Invarianten, an denen die UI haengt:
///  1. **Kanonischer Snapshot.** Die DB kennt keine Reihenfolge; gelesen wird
///     immer sortiert (`CommunityQueries`). „Derselbe Bestand" ist damit auch
///     dieselbe Liste — Voraussetzung fuer 2.
///  2. **Keine Scheinaenderung.** Ist der neue Bestand inhaltsgleich, wird weder
///     geschrieben noch die Version erhoeht noch die View benachrichtigt. Ein
///     `@Observable`-Setter feuert sonst bei JEDEM Sync, auch wenn sich nichts
///     geaendert hat.
///  3. **Serialisierte Schreiber.** GRDB laesst pro Datenbank genau einen
///     Schreiber zu — zwei parallele Vorgaenge koennen sich nicht gegenseitig
///     ueberschreiben (v1 musste das von Hand als Promise-Kette bauen).
///
/// Nach jedem eigenen Schreiben wird synchron nachgelesen, damit der Zustand im
/// selben Lauf stimmt; `ValueObservation` traegt zusaetzlich alles, was von
/// aussen kommt (anderer Store, Migration, Import).

@MainActor
/// Geteilt von allen Stores (Community wie Snaps): eine Beobachtung, eine
/// Fehlerbehandlung. Zwei Exemplare wuerden bei jeder Aenderung an GRDB
/// auseinanderlaufen.
final class StoreObserver {
    private var cancellable: AnyDatabaseCancellable?

    func start<T>(_ database: AppDatabase,
                  fetch: @escaping @Sendable (Database) throws -> T,
                  onChange: @escaping @MainActor (T) -> Void) where T: Sendable {
        cancellable = ValueObservation
            .tracking(fetch)
            .start(in: database.writer,
                   scheduling: .immediate,
                   onError: { _ in
                       // Ein Lesefehler darf die App nicht kippen: der Bestand
                       // bleibt der letzte gute, der naechste Schreibvorgang
                       // liest ohnehin neu.
                   },
                   onChange: { value in
                       MainActor.assumeIsolated { onChange(value) }
                   })
    }
}

// MARK: - Spots

/// Cloud-Anteil eines Spots — der lokale Kern (Name, Position) gehoert dem Nutzer.
/// `nil` heisst „unveraendert"; es gibt keinen Pfad, der ein Cloud-Feld gezielt
/// leeren muesste (der Spot wird dann entfernt, nicht entkoppelt).
public struct SpotCloudState: Sendable {
    public var zoneName: String?
    public var ownerId: String?
    public var participantIds: [String]?
    public var shareURL: String?
    public var sharePending: Bool?

    public init(zoneName: String? = nil, ownerId: String? = nil,
                participantIds: [String]? = nil, shareURL: String? = nil,
                sharePending: Bool? = nil) {
        self.zoneName = zoneName
        self.ownerId = ownerId
        self.participantIds = participantIds
        self.shareURL = shareURL
        self.sharePending = sharePending
    }
}

@MainActor
@Observable
public final class SpotStore {
    public private(set) var spots: [Spot] = []
    /// Zaehlt jede wirksame Mutation — macht „nichts passiert" pruefbar.
    public private(set) var version = 0

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let observer = StoreObserver()
    @ObservationIgnored private let clock: GZClock

    public init(_ database: AppDatabase, clock: GZClock = SystemClock()) {
        self.database = database
        self.clock = clock
        observer.start(database, fetch: CommunityQueries.spots) { [weak self] in
            self?.apply($0)
        }
    }

    public func spot(id: String) -> Spot? { spots.first { $0.id == id } }

    /// Neuer Spot am gewaehlten Punkt. Rein lokal, bis ihn jemand teilt.
    @discardableResult
    public func addSpot(name: String, emoji: String, lng: Double, lat: Double) async throws -> Spot {
        let spot = Spot(id: UUID().uuidString, name: name, emoji: emoji,
                        lng: lng, lat: lat, createdAt: clock.now.millisecondPrecision)
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO spot (id, name, emoji, lng, lat, createdAt, sharePending)
                VALUES (?, ?, ?, ?, ?, ?, 0)
                """,
                arguments: [spot.id, spot.name, spot.emoji, spot.lng, spot.lat,
                            spot.createdAt.epochMillis])
        }
        reload()
        return spot
    }

    /// Unbekannte id ist ein No-Op — Entfernen ist idempotent.
    /// Teilnehmer und Einladungen gehen per Fremdschluessel mit.
    public func removeSpot(id: String) async throws {
        guard spots.contains(where: { $0.id == id }) else { return }
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM spot WHERE id = ?", arguments: [id])
        }
        reload()
    }

    /// Cloud-Zustand eines Spots (Zone, Teilnehmer, Outbox-Flag). Unbekannte id
    /// ist ein No-Op: der Spot kann waehrend des Cloud-Writes entfernt worden sein.
    public func setCloudState(id: String, _ patch: SpotCloudState) async throws {
        guard let current = spot(id: id) else { return }
        var next = current
        if let value = patch.zoneName { next.zoneName = value }
        if let value = patch.ownerId { next.ownerId = value }
        if let value = patch.participantIds { next.participantIds = value.sorted() }
        if let value = patch.shareURL { next.shareURL = value }
        if let value = patch.sharePending { next.sharePending = value }
        guard next != current else { return }
        let updated = next
        let participants = updated.participantIds
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE spot SET zoneName = ?, ownerId = ?, shareURL = ?, sharePending = ?
                WHERE id = ?
                """,
                arguments: [updated.zoneName, updated.ownerId, updated.shareURL,
                            updated.sharePending ? 1 : 0, id])
            try db.execute(sql: "DELETE FROM spot_participant WHERE spotId = ?", arguments: [id])
            for userId in Set(participants).sorted() {
                try db.execute(sql: "INSERT INTO spot_participant (spotId, userId) VALUES (?, ?)",
                               arguments: [id, userId])
            }
        }
        reload()
    }

    /// Ersetzt den Bestand durch das Ergebnis eines Sync-Merges. Inhaltsgleich =
    /// keine Mutation.
    public func replaceAll(_ next: [Spot]) async throws {
        let canonical = SpotStore.canonical(next)
        guard canonical != spots else { return }
        try await database.writer.write { db in
            try CommunityQueries.write(db, spots: canonical)
        }
        reload()
    }

    nonisolated static func canonical(_ list: [Spot]) -> [Spot] {
        list.map { spot in
            var copy = spot
            copy.participantIds = Set(spot.participantIds).sorted()
            return copy
        }
        .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    private func reload() {
        guard let fresh = try? database.writer.read(CommunityQueries.spots) else { return }
        apply(fresh)
    }

    private func apply(_ fresh: [Spot]) {
        guard fresh != spots else { return }
        spots = fresh
        version += 1
    }
}

// MARK: - Freunde

/// Freunde entstehen ausschliesslich aus dem CloudKit-Sync (Freundesliste =
/// Menge der Friendship-Zonen). Geschrieben wird deshalb nur ueber `replaceAll`
/// aus dem Merge — es gibt keinen lokalen „Freund anlegen"-Pfad, der eine zweite
/// Quelle waere.
@MainActor
@Observable
public final class FriendStore {
    public private(set) var friends: [Friend] = []
    public private(set) var version = 0

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let observer = StoreObserver()

    public init(_ database: AppDatabase) {
        self.database = database
        observer.start(database, fetch: CommunityQueries.friends) { [weak self] in
            self?.apply($0)
        }
    }

    public func friend(id: String) -> Friend? { friends.first { $0.id == id } }

    public func replaceAll(_ next: [Friend]) async throws {
        let canonical = next.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        guard canonical != friends else { return }
        try await database.writer.write { db in
            try CommunityQueries.write(db, friends: canonical)
        }
        reload()
    }

    private func reload() {
        guard let fresh = try? database.writer.read(CommunityQueries.friends) else { return }
        apply(fresh)
    }

    private func apply(_ fresh: [Friend]) {
        guard fresh != friends else { return }
        friends = fresh
        version += 1
    }
}

// MARK: - Einladungen

public enum InviteStoreError: Error, Equatable {
    /// Lautlos schlucken hiesse: die Antwort/Zeitaenderung ist weg und niemand
    /// erfaehrt es. Die id kommt aus dem eigenen Bestand — fehlt sie, ist es ein Bug.
    case unknownInvitation(String)
}

@MainActor
@Observable
public final class InviteStore {
    public private(set) var invitations: [Invitation] = []
    public private(set) var version = 0

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let observer = StoreObserver()

    public init(_ database: AppDatabase) {
        self.database = database
        observer.start(database, fetch: CommunityQueries.invitations) { [weak self] in
            self?.apply($0)
        }
    }

    public func invitation(id: String) -> Invitation? { invitations.first { $0.id == id } }

    /// Aktive Einladung des Spots; bei mehreren die zuletzt erstellte.
    public func activeFor(spotId: String, now: Date) -> Invitation? {
        var best: Invitation?
        for invitation in invitations
        where invitation.spotId == spotId && invitationActive(invitation, now: now) {
            if best == nil || invitation.createdAt >= best!.createdAt { best = invitation }
        }
        return best
    }

    /// Uebernimmt eine fertige Einladung. Der Sync schreibt bei geteilten Spots
    /// zuerst in die Cloud und braucht dieselbe id auf beiden Seiten.
    public func add(_ invitation: Invitation) async throws {
        try await database.writer.write { db in
            try CommunityQueries.insert(db, invitation: invitation)
        }
        reload()
    }

    /// Anker verschieben. Antworten BLEIBEN — sie tragen ihre eigene Zeit (v2.2).
    public func changeTime(id: String, time: Date) async throws {
        guard invitation(id: id) != nil else { throw InviteStoreError.unknownInvitation(id) }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE invitation SET time = ? WHERE id = ?",
                           arguments: [time.epochMillis, id])
        }
        reload()
    }

    public func cancel(id: String) async throws {
        guard invitation(id: id) != nil else { throw InviteStoreError.unknownInvitation(id) }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE invitation SET cancelled = 1 WHERE id = ?", arguments: [id])
        }
        reload()
    }

    /// Upsert pro participantId — jeder Teilnehmer hat genau eine Antwort.
    public func setReply(id: String, _ reply: Reply) async throws {
        guard invitation(id: id) != nil else { throw InviteStoreError.unknownInvitation(id) }
        try await database.writer.write { db in
            try CommunityQueries.upsert(db, invitationId: id, reply: reply)
        }
        reload()
    }

    public func replaceAll(_ next: [Invitation]) async throws {
        let canonical = InviteStore.canonical(next)
        guard canonical != invitations else { return }
        try await database.writer.write { db in
            try CommunityQueries.write(db, invitations: canonical)
        }
        reload()
    }

    nonisolated static func canonical(_ list: [Invitation]) -> [Invitation] {
        list.map { invitation in
            var copy = invitation
            copy.replies = invitation.replies.sorted { $0.participantId < $1.participantId }
            return copy
        }
        .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    private func reload() {
        guard let fresh = try? database.writer.read(CommunityQueries.invitations) else { return }
        apply(fresh)
    }

    private func apply(_ fresh: [Invitation]) {
        guard fresh != invitations else { return }
        invitations = fresh
        version += 1
    }
}

// MARK: - Einstellungen

/// Schluessel der `setting`-Tabelle. Die Namen bleiben nah an v1, damit der
/// Import eins zu eins uebersetzt.
public enum SettingKey {
    public static let displayName = "displayName"
    public static let emoji = "emoji"
    public static let profileAsked = "profileAsked"
    public static let migratedV1 = "migratedV1"
    /// Welche In-Kontext-Hinweise schon einmal dastanden — kommagetrennt in
    /// EINEM Feld statt ein Schluessel je Hinweis: die Menge ist eine Sache,
    /// und ein zweiter Ort waere eine zweite Wahrheit.
    public static let seenHints = "seenHints"
}

@MainActor
@Observable
public final class SettingsStore {
    public private(set) var profile = Profile()
    /// „Profil einrichten" nach einem Beitritt wurde beantwortet oder uebersprungen.
    public private(set) var profileAsked = false
    /// Hinweise, die der Nutzer schon gesehen hat. Das Onboarding erklaert die
    /// Regeln einmal am Stueck; hier steht, wo sie im Handeln noch einmal
    /// aufgetaucht sind — jede genau einmal.
    public private(set) var seenHints: Set<String> = []

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let observer = StoreObserver()

    public init(_ database: AppDatabase) {
        self.database = database
        observer.start(database, fetch: CommunityQueries.settings) { [weak self] in
            self?.apply($0)
        }
    }

    public func setProfile(_ profile: Profile) async throws {
        try await set([SettingKey.displayName: profile.displayName,
                       SettingKey.emoji: profile.emoji])
    }

    public func setProfileAsked(_ asked: Bool) async throws {
        try await set([SettingKey.profileAsked: asked ? "1" : "0"])
    }

    /// Einen Hinweis als gezeigt vermerken. Idempotent — der Aufrufer steht in
    /// einem `task`, der bei jedem Aufbau der Ansicht laeuft.
    public func markHintSeen(_ id: String) async throws {
        guard !seenHints.contains(id) else { return }
        let next = seenHints.union([id]).sorted().joined(separator: ",")
        try await set([SettingKey.seenHints: next])
    }

    public func value(_ key: String) -> String? {
        try? database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
        }
    }

    public func set(_ values: [String: String]) async throws {
        try await database.writer.write { db in
            for (key, value) in values {
                try db.execute(sql: """
                    INSERT INTO setting (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [key, value])
            }
        }
        reload()
    }

    private func reload() {
        guard let fresh = try? database.writer.read(CommunityQueries.settings) else { return }
        apply(fresh)
    }

    private func apply(_ fresh: [String: String]) {
        let next = Profile(displayName: fresh[SettingKey.displayName] ?? "",
                           emoji: fresh[SettingKey.emoji] ?? "")
        if next != profile { profile = next }
        let asked = fresh[SettingKey.profileAsked] == "1"
        if asked != profileAsked { profileAsked = asked }
        let hints = Set((fresh[SettingKey.seenHints] ?? "")
            .split(separator: ",")
            .map { String($0) }
            .filter { !$0.isEmpty })
        if hints != seenHints { seenHints = hints }
    }
}
