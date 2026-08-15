import Foundation

/// Community-Datenmodell (Konzept v2.2, `docs/konzept-community-local-first.md`).
/// Port von `client/src/lib/spots/types.ts`.
///
/// Local-first: alles liegt in der App-DB; CloudKit ist die Transportschicht
/// darueber (`SyncCoordinator`) — jede Antwort bleibt ein eigener Record
/// (1 Record = 1 Schreiber).
///
/// Die Cloud-Felder sind durchweg OPTIONAL: ein persistierter Eintrag aus einer
/// aelteren App-Version muss ohne sie weiter lesbar sein (Kaltstart), und ein
/// Spot ohne `zoneName` ist per Definition rein lokal (Schublade A).

/// Eigene Identitaet im lokalen Bestand. Fremd-IDs sind CloudKit-userRecordIDs.
public let SELF_ID = "me"

public struct Spot: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var emoji: String
    public var lng: Double
    public var lat: Double
    public var createdAt: Date
    /// CloudKit-Zone `spot-<id>`; fehlt = nie geteilt, bleibt auf dem Geraet.
    public var zoneName: String?
    /// `SELF_ID` oder `userID` des Owners — nur gesetzt, solange der Spot geteilt ist.
    public var ownerId: String?
    /// Cloud-Wahrheit: akzeptierte Teilnehmer ohne mich. Vor der Cloud-Anlage:
    /// die gewaehlten Freunde.
    public var participantIds: [String]
    /// Share-URL des eigenen Spots — noetig, um ihn weiteren Freunden zuzustellen.
    public var shareURL: String?
    /// Cloud-Anlage steht noch aus (Outbox) — wird bei Netz/Resume nachgeholt.
    public var sharePending: Bool

    public init(id: String, name: String, emoji: String, lng: Double, lat: Double,
                createdAt: Date, zoneName: String? = nil, ownerId: String? = nil,
                participantIds: [String] = [], shareURL: String? = nil,
                sharePending: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.lng = lng
        self.lat = lat
        self.createdAt = createdAt
        self.zoneName = zoneName
        self.ownerId = ownerId
        self.participantIds = participantIds
        self.shareURL = shareURL
        self.sharePending = sharePending
    }

    /// Rein lokal = kein Gegenstueck in der Cloud (Schublade A).
    public var isLocalOnly: Bool { zoneName == nil }

    /// Ein Spot ohne Owner ist noch nie geteilt worden und gehoert damit mir.
    public var isMine: Bool { ownerId == nil || ownerId == SELF_ID }
}

public struct Friend: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Selbst gewaehltes Zeichen; leer/nil = keins, dann traegt der Avatar die Initiale.
    public var emoji: String?
    /// Avatar-Farbe (Hex), deterministisch aus der userID.
    public var color: String
    /// Friendship-Zone `friend-<uuid>` — Zustellweg fuer Spot-Angebote.
    public var friendshipZone: String?
    /// Feed-Zone des Gegenuebers (SPEC 7, gefuellt ab W4).
    public var feedZone: String?
    /// Blockiert: dessen Spots/Snaps bleiben ausgeblendet.
    public var blocked: Bool

    public init(id: String, name: String, emoji: String? = nil, color: String,
                friendshipZone: String? = nil, feedZone: String? = nil,
                blocked: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.color = color
        self.friendshipZone = friendshipZone
        self.feedZone = feedZone
        self.blocked = blocked
    }
}

public enum ReplyStatus: String, Equatable, Sendable {
    case ind = "in"
    case out
}

/// Antwort eines Eingeladenen — traegt den EIGENEN Zustand, nie einen Aenderungsantrag.
public struct Reply: Equatable, Sendable {
    public var participantId: String
    public var status: ReplyStatus
    /// Eigene Ankunftszeit — gesetzt bei „Ich komme um …".
    public var arrivalTime: Date?

    public init(participantId: String, status: ReplyStatus, arrivalTime: Date? = nil) {
        self.participantId = participantId
        self.status = status
        self.arrivalTime = arrivalTime
    }
}

public struct Invitation: Equatable, Sendable, Identifiable {
    public var id: String
    public var spotId: String
    /// `SELF_ID` fuer eigene Einladungen; Fremd-IDs kommen aus dem Cloud-Sync.
    public var hostId: String
    /// Anker-Zeit des Gastgebers — „ab 20:00", kein Vertrag.
    public var time: Date
    public var createdAt: Date
    public var cancelled: Bool
    public var replies: [Reply]

    public init(id: String, spotId: String, hostId: String, time: Date, createdAt: Date,
                cancelled: Bool, replies: [Reply] = []) {
        self.id = id
        self.spotId = spotId
        self.hostId = hostId
        self.time = time
        self.createdAt = createdAt
        self.cancelled = cancelled
        self.replies = replies
    }

    public func reply(of participantId: String) -> Reply? {
        replies.first { $0.participantId == participantId }
    }
}

/// Eigenes Profil: frei gewaehlter Name + optionales Zeichen. Kein Konto, kein
/// Verzeichnis — es liegt nur in den Friendship-Zonen der eigenen Freunde.
public struct Profile: Equatable, Sendable {
    public var displayName: String
    public var emoji: String

    public init(displayName: String = "", emoji: String = "") {
        self.displayName = displayName
        self.emoji = emoji
    }

    /// Ein leeres Zeichen ist eine gueltige Wahl — ein leerer Name ist ein Zustand.
    public var isSet: Bool { !displayName.isEmpty }
}

/// Einladung nach ihrem Zeitpunkt natuerlich auslaufen lassen (Konzept: „Client
/// blendet Vergangenes aus").
public let INVITATION_LINGER: TimeInterval = 2 * 60 * 60

public func invitationActive(_ invitation: Invitation, now: Date) -> Bool {
    !invitation.cancelled && now < invitation.time.addingTimeInterval(INVITATION_LINGER)
}

/// Anzeigename eines Freundes — ein noch leeres Profil ist ein Zustand, kein Fehler.
public func friendLabel(_ friend: Friend) -> String {
    let trimmed = friend.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Freund" : trimmed
}

/// Was im Avatar-Kreis steht: das gewaehlte Zeichen, sonst die Initiale des
/// Namens. Ohne beides bleibt der Kreis leer — dann traegt ihn das Personen-
/// Symbol, denn ein „F" von „Freund" behauptete einen Namen, den es nicht gibt.
public func avatarGlyph(name: String, emoji: String?) -> String {
    let sign = (emoji ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !sign.isEmpty { return sign }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "" }
    return String(first).uppercased()
}

public func avatarGlyph(_ friend: Friend) -> String {
    avatarGlyph(name: friend.name, emoji: friend.emoji)
}

/// Avatar-Farben aus dem Mockup — deterministisch aus der userID, damit ein
/// Merge nichts umfaerbt. Port von `friendColor()` in `sync.ts`, inklusive der
/// 32-Bit-Arithmetik von JavaScript (`>>> 0`).
public let FRIEND_COLORS = ["#7C5CFF", "#0A9B8E", "#0A84FF", "#F76B15", "#12A150", "#E5484D"]

public func friendColor(_ userID: String) -> String {
    var hash: UInt32 = 0
    // JS liest `charCodeAt` = UTF-16-Einheiten; alles andere waere bei Umlauten
    // eine andere Farbe als auf dem v1-Geraet.
    for unit in userID.utf16 {
        hash = hash &* 31 &+ UInt32(unit)
    }
    return FRIEND_COLORS[Int(hash % UInt32(FRIEND_COLORS.count))]
}

/// Zonen-Name `spot-<uuid>` → lokale Spot-id; beide Seiten leiten sie gleich ab.
public func localSpotId(_ zoneName: String) -> String {
    zoneName.hasPrefix("spot-") ? String(zoneName.dropFirst(5)) : zoneName
}
