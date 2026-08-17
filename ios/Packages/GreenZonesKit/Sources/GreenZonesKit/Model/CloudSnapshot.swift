import Foundation

/// Contract-Typen des CloudKit-Sync — typisierter Port von
/// `client/src/lib/cloudkit/definitions.ts` (Quelle: `docs/cloudkit-contract.md`).
///
/// Diese Datei ist die gemeinsame Flaeche zwischen `CloudGateway` (ab W4 der
/// echte CloudKitService) und dem Merge. Deshalb stehen hier NUR Typen — keine
/// Hilfsfunktionen, kein Default-Verhalten.

public enum CKAccountStatus: String, Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable
}

public struct CloudFriend: Equatable, Sendable {
    /// `CKRecord.ID.recordName` des Gegenuebers.
    public var userID: String
    /// Aus dessen Profile-Record; "" wenn (noch) keins da.
    public var name: String
    /// Gewaehltes Zeichen; "" = keins, dann traegt der Avatar die Initiale.
    public var emoji: String
    /// Zonen-Name `friend-<uuid>`.
    public var friendshipZone: String
    /// true = ich habe die Freundschaft angelegt.
    public var isOwner: Bool
    /// Zonen-Name `feed-<uuid>` des Gegenuebers, "" solange sein Feed nicht
    /// angenommen ist (v1-Bestand vor dem ersten Fetch mit v2).
    public var feedZone: String

    public init(userID: String, name: String, emoji: String, friendshipZone: String,
                isOwner: Bool, feedZone: String = "") {
        self.userID = userID
        self.name = name
        self.emoji = emoji
        self.friendshipZone = friendshipZone
        self.isOwner = isOwner
        self.feedZone = feedZone
    }
}

public struct CloudSpot: Equatable, Sendable {
    /// `spot-<uuid>`.
    public var zoneName: String
    /// "" wenn ich selbst Owner bin.
    public var ownerUserID: String
    public var isMine: Bool
    public var name: String
    public var emoji: String
    public var lng: Double
    public var lat: Double
    public var createdAt: Date
    /// Akzeptierte Teilnehmer ohne mich.
    public var participantUserIDs: [String]
    /// Nur gefuellt wenn `isMine`.
    public var shareURL: String

    public init(zoneName: String, ownerUserID: String, isMine: Bool, name: String,
                emoji: String, lng: Double, lat: Double, createdAt: Date,
                participantUserIDs: [String], shareURL: String) {
        self.zoneName = zoneName
        self.ownerUserID = ownerUserID
        self.isMine = isMine
        self.name = name
        self.emoji = emoji
        self.lng = lng
        self.lat = lat
        self.createdAt = createdAt
        self.participantUserIDs = participantUserIDs
        self.shareURL = shareURL
    }
}

public struct CloudReply: Equatable, Sendable {
    public var participantUserID: String
    public var status: ReplyStatus
    public var arrivalTime: Date?

    public init(participantUserID: String, status: ReplyStatus, arrivalTime: Date? = nil) {
        self.participantUserID = participantUserID
        self.status = status
        self.arrivalTime = arrivalTime
    }
}

public struct CloudInvitation: Equatable, Sendable {
    /// `recordName`.
    public var id: String
    public var spotZone: String
    /// `creatorUserRecordID`; eigener Record → eigene userID (der Merge mappt auf `SELF_ID`).
    public var hostUserID: String
    public var time: Date
    public var createdAt: Date
    public var cancelled: Bool
    public var replies: [CloudReply]

    public init(id: String, spotZone: String, hostUserID: String, time: Date,
                createdAt: Date, cancelled: Bool, replies: [CloudReply]) {
        self.id = id
        self.spotZone = spotZone
        self.hostUserID = hostUserID
        self.time = time
        self.createdAt = createdAt
        self.cancelled = cancelled
        self.replies = replies
    }
}

/// Ein Snap, wie ihn der Vollabzug liefert — ohne Bilddaten. Die Assets holt
/// `fetchThumbs` nach (SPEC 7: `desiredKeys` ohne `thumb`/`photo`, sonst zieht
/// jeder Fetch alle Fotos aller Freunde).
public struct CloudSnap: Equatable, Sendable {
    /// `recordName` — bei fremden Snaps die Id des Autors-Geraets.
    public var id: String
    /// Zone, in der der Record liegt.
    public var zoneName: String
    public var authorUserID: String
    public var createdAt: Date
    public var lat: Double
    public var lng: Double
    /// Nur bei Feed-Snaps gesetzt, die an einem Spot aufgenommen wurden.
    public var spotZone: String?
    public var spotName: String?
    public var spotEmoji: String?
    /// `true`, wenn der Record in einer Spot-Zone liegt („nur Freunde im Spot").
    public var inSpotZone: Bool

    public init(id: String, zoneName: String, authorUserID: String, createdAt: Date,
                lat: Double, lng: Double, spotZone: String? = nil, spotName: String? = nil,
                spotEmoji: String? = nil, inSpotZone: Bool) {
        self.id = id
        self.zoneName = zoneName
        self.authorUserID = authorUserID
        self.createdAt = createdAt
        self.lat = lat
        self.lng = lng
        self.spotZone = spotZone
        self.spotName = spotName
        self.spotEmoji = spotEmoji
        self.inSpotZone = inSpotZone
    }
}

public struct CloudSnapshot: Equatable, Sendable {
    public var status: CKAccountStatus
    /// "" wenn `status != .available`.
    public var userID: String
    public var friends: [CloudFriend]
    public var spots: [CloudSpot]
    public var invitations: [CloudInvitation]
    public var snaps: [CloudSnap]

    public init(status: CKAccountStatus, userID: String, friends: [CloudFriend],
                spots: [CloudSpot], invitations: [CloudInvitation], snaps: [CloudSnap] = []) {
        self.status = status
        self.userID = userID
        self.friends = friends
        self.spots = spots
        self.invitations = invitations
        self.snaps = snaps
    }

    /// Leerer Snapshot mit Status — genau die Form, die `fetchAll` ohne Konto liefert.
    public static func empty(status: CKAccountStatus) -> CloudSnapshot {
        CloudSnapshot(status: status, userID: "", friends: [], spots: [], invitations: [], snaps: [])
    }
}
