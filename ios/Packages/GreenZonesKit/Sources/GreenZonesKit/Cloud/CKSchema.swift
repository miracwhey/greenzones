import CloudKit
import Foundation

/// Zonen- und Record-Namen des CloudKit-Contracts (`docs/cloudkit-contract.md`,
/// Abschnitt „v2 — Neubau"). Port aus `client/ios/App/App/CloudKitSync/CloudKitSchema.swift`.
///
/// Der recordName kodiert ueberall den Schreiber (Profile, Reply) bzw. das Ziel
/// (SpotOffer, FeedOffer, Report), damit jeder Record genau einen Schreiber hat
/// und Upserts ohne Merge auskommen.
///
/// Diese Namen sind ein Vertrag mit bereits ausgelieferten v1-Geraeten: wer sie
/// aendert, schneidet Bestandsfreundschaften ab. Was hier steht, wird nur
/// ergaenzt, nie umbenannt.
public enum CKSchema {
    public static let containerID = "iCloud.de.leonvalentin.greenzones"

    public static let friendZonePrefix = "friend-"
    public static let spotZonePrefix = "spot-"
    /// v2: eigener Feed des Autors, zone-wide geteilt mit allen Freunden.
    public static let feedZonePrefix = "feed-"

    public static let offerRecordPrefix = "offer-"
    public static let profileRecordPrefix = "profile-"
    public static let replyRecordPrefix = "reply-"
    /// v2: `feedoffer-<userRecordID>` — je Person genau einer je Friendship-Zone.
    public static let feedOfferRecordPrefix = "feedoffer-"
    /// v2: `report-<snapId>-<userRecordID>` — je Meldendem genau einer je Snap.
    public static let reportRecordPrefix = "report-"

    public static let typeFriendship = "Friendship"
    public static let typeProfile = "Profile"
    public static let typeSpotOffer = "SpotOffer"
    public static let typeSpot = "Spot"
    public static let typeInvitation = "Invitation"
    public static let typeReply = "Reply"
    /// v2
    public static let typeFeedOffer = "FeedOffer"
    public static let typeFeed = "Feed"
    public static let typeSnap = "Snap"
    public static let typeReport = "Report"

    public static let friendshipRecordName = "friendship"
    public static let spotRecordName = "spot"
    public static let feedRecordName = "feed"

    /// CKQuerySubscription greift in der sharedCloudDatabase nicht — nur
    /// Datenbank-Subscriptions. v2 = sichtbarer Push (alert + mutable-content),
    /// den die Notification-Extension betextet. Die v1-IDs waren silent-only;
    /// Geraete mit v1 bekaemen nie ein Banner, deshalb werden sie beim
    /// Registrieren aktiv geloescht.
    public static let privateSubscriptionID = "gz-private-db-v2"
    public static let sharedSubscriptionID = "gz-shared-db-v2"
    public static let legacySubscriptionIDs = ["gz-private-db", "gz-shared-db"]

    // MARK: - Felder
    //
    // Der Vollabzug darf die Bilddaten NICHT mitziehen — sonst laedt jeder
    // Fetch saemtliche Fotos aller Freunde. CloudKit kann das nur ueber eine
    // Positivliste (`desiredKeys`), und eine Positivliste, die ein Feld
    // vergisst, verliert es still. Deshalb steht hier die einzige Liste, aus
    // der beide Seiten schoepfen: der Leser als `desiredKeys`, der Schreiber
    // beim Bauen des Records.

    public enum Field {
        public static let friendship = ["createdAt"]
        public static let profile = ["name", "emoji"]
        public static let spotOffer = ["spotShareURL", "spotName", "spotEmoji"]
        public static let feedOffer = ["feedShareURL"]
        public static let spot = ["name", "emoji", "lng", "lat", "createdAt"]
        // `inviteeIds`: wer bei DIESEM Termin gemeint ist (leer = alle
        // Spot-Mitglieder). Leser und Schreiber teilen sich diese eine
        // Liste — ein Feld, das nur einer von beiden kennt, kaeme nie an.
        public static let invitation = ["time", "createdAt", "cancelled", "inviteeIds"]
        public static let reply = ["invitationId", "status", "arrivalTime"]
        public static let feed = ["createdAt"]
        public static let report = ["snapId", "createdAt"]
        /// Snap ohne Bilder.
        public static let snap = ["createdAt", "lat", "lng", "spotZone", "spotName", "spotEmoji"]
        /// Die schweren Felder — nur auf Anforderung.
        public static let snapAssets = ["thumb", "photo"]

        /// Alles, was ein Vollabzug braucht: jedes Feld ausser den Bildern.
        public static let lightweight: [String] = {
            var seen = Set<String>()
            return (friendship + profile + spotOffer + feedOffer + spot + invitation
                    + reply + feed + report + snap).filter { seen.insert($0).inserted }
        }()
    }

    // MARK: - Abgeleitete Namen
    //
    // Jede Ableitung steht genau einmal hier: der Schreiber und der Leser eines
    // recordName duerfen nie zwei Meinungen ueber seine Form haben.

    public static func friendZoneName(_ uuid: String = UUID().uuidString) -> String {
        friendZonePrefix + uuid.lowercased()
    }

    public static func spotZoneName(spotId: String) -> String {
        spotZonePrefix + spotId
    }

    public static func feedZoneName(_ uuid: String = UUID().uuidString) -> String {
        feedZonePrefix + uuid.lowercased()
    }

    public static func profileRecordName(userID: String) -> String {
        profileRecordPrefix + userID
    }

    public static func offerRecordName(spotZone: String) -> String {
        offerRecordPrefix + spotZone
    }

    public static func feedOfferRecordName(userID: String) -> String {
        feedOfferRecordPrefix + userID
    }

    public static func replyRecordName(invitationId: String, userID: String) -> String {
        replyRecordPrefix + invitationId + "-" + userID
    }

    public static func reportRecordName(snapId: String, userID: String) -> String {
        reportRecordPrefix + snapId + "-" + userID
    }

    /// Ziel-Zone eines Offers aus seinem recordName. Der Empfaenger erkennt damit
    /// ohne Netz-Roundtrip, ob er den Share schon angenommen hat.
    public static func offeredZone(recordName: String) -> String? {
        guard recordName.hasPrefix(offerRecordPrefix) else { return nil }
        return String(recordName.dropFirst(offerRecordPrefix.count))
    }

    /// Spot-Id aus dem Zonennamen (`spot-<uuid>` → `<uuid>`).
    public static func spotId(zoneName: String) -> String {
        guard zoneName.hasPrefix(spotZonePrefix) else { return zoneName }
        return String(zoneName.dropFirst(spotZonePrefix.count))
    }
}

/// Uebersetzt CloudKit-Fehler in die Codes des Contracts. Port von
/// `CKErrorMapper` — inklusive der Regel, dass ein `partialFailure` nichts ueber
/// die Ursache sagt: die steht im Teil-Fehler.
public enum CKErrorMapper {
    public static func syncError(for error: Error) -> SyncError {
        if let mapped = error as? SyncError { return mapped }
        guard let ckError = error as? CKError else { return .cloudInternal }
        switch ckError.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return .network
        case .unknownItem, .zoneNotFound, .userDeletedZone:
            return .notFound
        case .serverRecordChanged:
            return .conflict
        case .notAuthenticated, .managedAccountRestricted:
            return .noAccount
        case .partialFailure:
            if let partial = ckError.partialErrorsByItemID?.values.first {
                return syncError(for: partial)
            }
            return .cloudInternal
        default:
            return .cloudInternal
        }
    }
}

/// Der Contract-Status zu einem CloudKit-Kontostatus.
///
/// Die beiden Typen heissen gleich: `CKAccountStatus` ist hier der Contract-Enum
/// aus `CloudSnapshot.swift`, in CloudKit der Systemtyp. In jeder Datei, die
/// CloudKit importiert, muessen beide deshalb ausgeschrieben werden.
func contractStatus(_ status: CloudKit.CKAccountStatus) -> GreenZonesKit.CKAccountStatus {
    switch status {
    case .available: return .available
    case .noAccount: return .noAccount
    case .restricted: return .restricted
    case .couldNotDetermine: return .couldNotDetermine
    case .temporarilyUnavailable: return .temporarilyUnavailable
    @unknown default: return .couldNotDetermine
    }
}
