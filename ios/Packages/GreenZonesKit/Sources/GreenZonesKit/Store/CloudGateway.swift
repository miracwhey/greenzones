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

    /// CKDatabaseSubscriptions + Remote-Push-Registrierung. Idempotent.
    func registerSubscriptions() async throws
    /// Fragt einmalig nach der Mitteilungs-Erlaubnis. Schon entschieden → kein Dialog.
    func ensureNotificationPermission() async throws -> Bool
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

    public func registerSubscriptions() async throws { throw SyncError.noAccount }

    /// Kein Fehler: „keine Erlaubnis" ist ohne Container der ehrliche
    /// Normalzustand, nicht eine Stoerung (v1-Web-Stub).
    public func ensureNotificationPermission() async throws -> Bool { false }
}
