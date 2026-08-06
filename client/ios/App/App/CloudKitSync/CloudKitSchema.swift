import Foundation
import CloudKit

/// Zonen- und Record-Namen aus `docs/cloudkit-contract.md`.
/// Der recordName kodiert überall den Schreiber (Profile, Reply) bzw. das Ziel (SpotOffer),
/// damit jeder Record genau einen Schreiber hat und Upserts ohne Merge auskommen.
enum CKSchema {
    static let containerID = "iCloud.de.leonvalentin.greenzones"

    static let friendZonePrefix = "friend-"
    static let spotZonePrefix = "spot-"

    static let offerRecordPrefix = "offer-"
    static let profileRecordPrefix = "profile-"
    static let replyRecordPrefix = "reply-"

    static let typeFriendship = "Friendship"
    static let typeProfile = "Profile"
    static let typeSpotOffer = "SpotOffer"
    static let typeSpot = "Spot"
    static let typeInvitation = "Invitation"
    static let typeReply = "Reply"

    static let friendshipRecordName = "friendship"
    static let spotRecordName = "spot"

    /// CKQuerySubscription greift in der sharedCloudDatabase nicht — nur Datenbank-Subscriptions.
    static let privateSubscriptionID = "gz-private-db"
    static let sharedSubscriptionID = "gz-shared-db"

    /// Letzter bekannter Anzeigename. Nötig, weil ein von außen (Universal Link) angenommener
    /// Freundschafts-Share sein Profile schreiben muss, ohne dass der JS-Layer den Namen mitliefert.
    /// EIN Speicherort für beide Welten: derselbe UserDefaults-Eintrag, den der TS-Layer über
    /// Capacitor Preferences unter "gz_display_name" schreibt (Prefix "CapacitorStorage.").
    static let displayNameDefaultsKey = "CapacitorStorage.gz_display_name"
    static let profileEmojiDefaultsKey = "CapacitorStorage.gz_profile_emoji"
}

/// Fehler-Codes des Plugin-Contracts. Die TS-Seite mappt sie auf Nutzertext.
enum SyncErrorCode: String {
    case noAccount
    case network
    case notFound
    case conflict
    case internalFailure = "internal"
}

struct SyncError: Error {
    let code: SyncErrorCode
    let message: String

    init(_ code: SyncErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

enum CKErrorMapper {
    static func code(for error: Error) -> SyncErrorCode {
        if let syncError = error as? SyncError {
            return syncError.code
        }
        guard let ckError = error as? CKError else {
            return .internalFailure
        }
        switch ckError.code {
        case .networkUnavailable, .networkFailure:
            return .network
        case .unknownItem, .zoneNotFound:
            return .notFound
        case .serverRecordChanged:
            return .conflict
        case .notAuthenticated:
            return .noAccount
        case .partialFailure:
            // Der eigentliche Grund steckt im Teil-Fehler; der äußere Code sagt nichts aus.
            if let partial = ckError.partialErrorsByItemID?.values.first {
                return code(for: partial)
            }
            return .internalFailure
        default:
            return .internalFailure
        }
    }

    static func message(for error: Error) -> String {
        if let syncError = error as? SyncError {
            return syncError.message
        }
        if let ckError = error as? CKError,
           ckError.code == .partialFailure,
           let partial = ckError.partialErrorsByItemID?.values.first {
            return partial.localizedDescription
        }
        return error.localizedDescription
    }
}

extension Date {
    /// Der JS-Layer rechnet in Millisekunden seit 1970.
    init(millisSince1970: Double) {
        self.init(timeIntervalSince1970: millisSince1970 / 1000)
    }

    var millisSince1970: Double {
        timeIntervalSince1970 * 1000
    }
}
