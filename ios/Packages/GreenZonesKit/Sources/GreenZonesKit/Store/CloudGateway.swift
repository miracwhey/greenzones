import Foundation

/// Die Flaeche, ueber die der `SyncCoordinator` mit CloudKit spricht.
/// Typisierter Port des Plugin-Contracts (`CloudKitSyncPlugin`, `definitions.ts`).
///
/// W3 kennt nur `NoCloudGateway`; den echten `CloudKitService` bringt W4 —
/// der Coordinator und alle Sheets bleiben dabei unveraendert.
public protocol CloudGateway: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    /// Kompletter Zustand. Verarbeitet dabei offene SpotOffers (Auto-Accept, idempotent).
    func fetchAll() async throws -> CloudSnapshot

    /// Legt Friendship-Zone + Share + eigenes Profile an und liefert die Einladungs-URL.
    func createFriendInvite(displayName: String, emoji: String) async throws -> String
    /// Aktualisiert den eigenen Profile-Record in allen Friendship-Zonen.
    /// Leeres `emoji` loescht das Zeichen.
    func setProfile(name: String, emoji: String) async throws

    /// Legt Spot-Zone + Spot-Record + Share an.
    func createSpotShare(_ spot: Spot) async throws -> SpotShare
    /// Stellt den Spot-Share bestehenden Freunden zu (SpotOffer in deren Friendship-Zonen).
    func offerSpotToFriends(zoneName: String, shareURL: String, spotName: String,
                            spotEmoji: String, friendshipZones: [String]) async throws
    /// Owner: Zone loeschen. Teilnehmer: Teilnahme beenden.
    func deleteSpot(zoneName: String) async throws

    /// Upsert Invitation (anlegen, Zeit aendern, absagen). Nur eigene Records.
    func saveInvitation(spotZone: String, id: String, time: Date, createdAt: Date,
                        cancelled: Bool) async throws
    /// Upsert der EIGENEN Reply zu einer Invitation.
    func saveReply(spotZone: String, invitationId: String, status: ReplyStatus,
                   arrivalTime: Date?) async throws

    /// Freundschaft beenden: Zone verlassen bzw. loeschen UND die Person aus
    /// allen eigenen Shares (Spots, Feed) entfernen. Zwei Netz-Phasen, jede fuer
    /// sich idempotent; ein Teilerfolg wirft, damit die UI ihn melden kann.
    ///
    /// Ob die Zone mir gehoert, schlaegt das Gateway selbst nach — ein
    /// mitgereichtes Flag waere ein zweiter Zustand neben der Datenbank.
    func removeFriend(userID: String, friendshipZone: String) async throws

    /// Jemanden aus EINEM eigenen Spot-Share nehmen, ohne die Freundschaft zu
    /// beenden. Idempotent: wer nicht (mehr) Teilnehmer ist, ist der Zielzustand.
    func removeSpotParticipant(zoneName: String, userID: String) async throws

    // MARK: - Snaps (W5)

    /// Laedt einen eigenen Snap hoch — in die Feed-Zone (alle Freunde) oder die
    /// Spot-Zone (nur deren Mitglieder). Idempotent ueber den recordName.
    func uploadSnap(_ snap: Snap, original: URL, thumb: URL) async throws -> SnapUpload
    /// Eigenen Snap loeschen; als Spot-Owner auch fremde in der eigenen Zone.
    func deleteSnap(zoneName: String, recordName: String) async throws
    /// Meldung zu einem Snap in dessen Zone ablegen. Kein Auto-Loeschen — der
    /// Autor sieht die Meldung, das Ausblenden passiert lokal.
    func reportSnap(zoneName: String, snapId: String, at date: Date) async throws
    /// Vorschaubilder nachladen (Batch); Rueckgabe je Snap-Id.
    func fetchThumbs(_ refs: [SnapAsset]) async throws -> [String: Data]
    /// Original eines einzelnen Snaps — erst beim Oeffnen im Viewer.
    func fetchOriginal(_ ref: SnapAsset) async throws -> Data

    /// CKDatabaseSubscriptions + Remote-Push-Registrierung. Idempotent.
    func registerSubscriptions() async throws
    /// Fragt einmalig nach der Mitteilungs-Erlaubnis. Schon entschieden → kein Dialog.
    func ensureNotificationPermission() async throws -> Bool
}

/// Wo ein hochgeladener Snap gelandet ist.
public struct SnapUpload: Equatable, Sendable {
    public let zoneName: String
    public let recordName: String

    public init(zoneName: String, recordName: String) {
        self.zoneName = zoneName
        self.recordName = recordName
    }
}

/// Adresse eines Snap-Assets: Zone plus recordName.
public struct SnapAsset: Equatable, Sendable {
    public let snapId: String
    public let zoneName: String
    public let recordName: String

    public init(snapId: String, zoneName: String, recordName: String) {
        self.snapId = snapId
        self.zoneName = zoneName
        self.recordName = recordName
    }
}

public struct SpotShare: Equatable, Sendable {
    public let zoneName: String
    public let shareURL: String

    public init(zoneName: String, shareURL: String) {
        self.zoneName = zoneName
        self.shareURL = shareURL
    }
}

/// Fehler-Codes des Contracts (v1: `reject(message, code)`).
public enum SyncError: Error, Equatable, Sendable {
    case noAccount
    case network
    case notFound
    case conflict
    case cloudInternal
}

/// Nutzertext zu einem Sync-Fehler — benennt Netz/Konto, nie den Nutzer.
/// Ein unbekannter Fehler bleibt ehrlich vage statt eine Ursache zu erfinden.
/// Wortlaut aus v1 `cloudMessage()`.
public func cloudMessage(_ error: Error) -> String {
    switch error as? SyncError {
    case .noAccount:
        return "Ohne iCloud-Konto geht das nicht raus — die App bleibt lokal nutzbar."
    case .network:
        return "Kein Netz — es ist nichts rausgegangen. Sobald du wieder online bist, nochmal."
    case .notFound:
        return "Der geteilte Bereich ist nicht mehr da."
    case .conflict:
        return "Da war jemand schneller — kurz neu laden und nochmal."
    case .cloudInternal:
        return "iCloud antwortet gerade nicht. Später nochmal probieren."
    case nil:
        return "Hat nicht geklappt — nichts wurde gesendet."
    }
}

/// Der Zustand „kein CloudKit" — ehrlich, ohne Fake-Erfolg.
///
/// Bis W4 hat die App keinen CloudKit-Pfad. Statt Schreibvorgaenge lokal so
/// aussehen zu lassen, als waeren sie rausgegangen, lehnt dieses Gateway sie ab
/// (`noAccount`) und liefert einen leeren Snapshot mit `couldNotDetermine` —
/// exakt das Verhalten, das v1 im Web-Stub zeigt. Lokale Spots und ihre
/// Einladungen funktionieren dadurch voll; geteilte melden ehrlich, dass nichts
/// gesendet wurde.
public struct NoCloudGateway: CloudGateway {
    public init() {}

    public func accountStatus() async throws -> CKAccountStatus { .couldNotDetermine }
    public func fetchAll() async throws -> CloudSnapshot { .empty(status: .couldNotDetermine) }

    public func createFriendInvite(displayName: String, emoji: String) async throws -> String {
        throw SyncError.noAccount
    }

    public func setProfile(name: String, emoji: String) async throws { throw SyncError.noAccount }

    public func createSpotShare(_ spot: Spot) async throws -> SpotShare { throw SyncError.noAccount }

    public func offerSpotToFriends(zoneName: String, shareURL: String, spotName: String,
                                   spotEmoji: String, friendshipZones: [String]) async throws {
        throw SyncError.noAccount
    }

    public func deleteSpot(zoneName: String) async throws { throw SyncError.noAccount }

    public func saveInvitation(spotZone: String, id: String, time: Date, createdAt: Date,
                               cancelled: Bool) async throws {
        throw SyncError.noAccount
    }

    public func saveReply(spotZone: String, invitationId: String, status: ReplyStatus,
                          arrivalTime: Date?) async throws {
        throw SyncError.noAccount
    }

    public func removeFriend(userID: String, friendshipZone: String) async throws {
        throw SyncError.noAccount
    }

    public func removeSpotParticipant(zoneName: String, userID: String) async throws {
        throw SyncError.noAccount
    }

    public func uploadSnap(_ snap: Snap, original: URL, thumb: URL) async throws -> SnapUpload {
        throw SyncError.noAccount
    }

    public func deleteSnap(zoneName: String, recordName: String) async throws {
        throw SyncError.noAccount
    }

    public func reportSnap(zoneName: String, snapId: String, at date: Date) async throws {
        throw SyncError.noAccount
    }

    /// Kein Fehler, sondern die Wahrheit: ohne Cloud gibt es nichts nachzuladen.
    /// Ein Wurf wuerde den Album-Aufbau bei jedem Durchlauf stoeren.
    public func fetchThumbs(_ refs: [SnapAsset]) async throws -> [String: Data] { [:] }

    public func fetchOriginal(_ ref: SnapAsset) async throws -> Data { throw SyncError.noAccount }

    public func registerSubscriptions() async throws { throw SyncError.noAccount }

    /// Kein Fehler: „keine Erlaubnis" ist ohne Container der ehrliche
    /// Normalzustand, nicht eine Stoerung (v1-Web-Stub).
    public func ensureNotificationPermission() async throws -> Bool { false }
}
