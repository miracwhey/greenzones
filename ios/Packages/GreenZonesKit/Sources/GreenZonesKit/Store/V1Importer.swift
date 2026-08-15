import Foundation
import GRDB

/// Uebernahme des v1-Bestands beim ersten Start des Neubaus (SPEC 4).
///
/// v1 (Capacitor) schrieb seine Listen als JSON in `UserDefaults` unter dem
/// Praefix `CapacitorStorage.`. Ohne diesen Import waeren alle rein lokalen
/// Spots weg — sie haben in der Cloud kein Gegenstueck und kaemen durch keinen
/// Sync zurueck. Recents und Onboarding duerfen verfallen.
///
/// Gelesen wird so nachsichtig wie v1 selbst (`parseSpot`, `parseFriend`,
/// `parseInvitation`): ein kaputter Eintrag faellt raus, nie der ganze Bestand;
/// ein kaputtes Cloud-Feld faellt raus, nie der Spot. Einmalig — der Marker
/// `setting.migratedV1` liegt in derselben Transaktion wie die Daten, ein
/// Abbruch mittendrin wiederholt also den ganzen Import statt ihn halb zu lassen.
public enum V1Importer {
    public static let storagePrefix = "CapacitorStorage."
    public static let spotsKey = "gz_spots"
    public static let invitesKey = "gz_invites"
    public static let friendsKey = "gz_friends"
    public static let displayNameKey = "gz_display_name"
    public static let profileEmojiKey = "gz_profile_emoji"
    public static let profileAskedKey = "gz_profile_asked"

    public struct Result: Equatable, Sendable {
        public var spots: Int
        public var friends: Int
        public var invitations: Int
        public var profile: Profile
        public var profileAsked: Bool
        /// false = war schon gelaufen, es wurde nichts angefasst.
        public var didRun: Bool
    }

    /// `didRun == false` heisst: der Marker stand schon, es wurde nichts geschrieben.
    @discardableResult
    public static func runIfNeeded(database: AppDatabase,
                                   defaults: UserDefaults = .standard) throws -> Result {
        let already = try database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?",
                                arguments: [SettingKey.migratedV1])
        }
        if already == "1" {
            return Result(spots: 0, friends: 0, invitations: 0, profile: Profile(),
                          profileAsked: false, didRun: false)
        }

        let spots = parseSpots(string(defaults, spotsKey))
        let friends = parseFriends(string(defaults, friendsKey))
        let knownSpotIds = Set(spots.map(\.id))
        // Eine Einladung ohne ihren Spot ist eine Karteileiche — und der
        // Fremdschluessel wuerde sie ohnehin ablehnen.
        let invitations = parseInvitations(string(defaults, invitesKey))
            .filter { knownSpotIds.contains($0.spotId) }
        let profile = Profile(displayName: string(defaults, displayNameKey) ?? "",
                              emoji: string(defaults, profileEmojiKey) ?? "")
        let asked = string(defaults, profileAskedKey) == "1"

        try database.writer.write { db in
            try CommunityQueries.write(db, spots: SpotStore.canonical(spots))
            try CommunityQueries.write(db, friends: friends)
            try CommunityQueries.write(db, invitations: InviteStore.canonical(invitations))
            var settings: [String: String] = [SettingKey.migratedV1: "1"]
            if !profile.displayName.isEmpty { settings[SettingKey.displayName] = profile.displayName }
            if !profile.emoji.isEmpty { settings[SettingKey.emoji] = profile.emoji }
            if asked { settings[SettingKey.profileAsked] = "1" }
            for (key, value) in settings {
                try db.execute(sql: """
                    INSERT INTO setting (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [key, value])
            }
        }

        return Result(spots: spots.count, friends: friends.count, invitations: invitations.count,
                      profile: profile, profileAsked: asked, didRun: true)
    }

    // MARK: - Rohwerte

    static func string(_ defaults: UserDefaults, _ key: String) -> String? {
        defaults.string(forKey: storagePrefix + key)
    }

    /// Korrupter Speicher ist ein DEFINIERTES Ergebnis (leerer Bestand), kein
    /// Absturz beim Kaltstart.
    static func array(_ raw: String?) -> [[String: Any]] {
        guard let raw, let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let list = parsed as? [Any]
        else { return [] }
        return list.compactMap { $0 as? [String: Any] }
    }

    // MARK: - Parser (Port von store.ts)

    static func parseSpots(_ raw: String?) -> [Spot] {
        array(raw).compactMap(parseSpot)
    }

    /// Cloud-Felder sind eine Ergaenzung, kein Existenzgrund: ist eines davon
    /// kaputt, faellt der Spot auf seinen lokalen Kern zurueck statt ganz zu
    /// verschwinden.
    static func parseSpot(_ dict: [String: Any]) -> Spot? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let emoji = dict["emoji"] as? String,
              let lng = number(dict["lng"]),
              let lat = number(dict["lat"]),
              let createdAt = number(dict["createdAt"])
        else { return nil }
        var spot = Spot(id: id, name: name, emoji: emoji, lng: lng, lat: lat,
                        createdAt: Date(epochMillis: Int64(createdAt)))
        guard optionalString(dict["zoneName"]),
              optionalString(dict["ownerId"]),
              optionalString(dict["shareURL"]),
              optionalBool(dict["sharePending"]),
              optionalStrings(dict["participantIds"])
        else { return spot }
        spot.zoneName = dict["zoneName"] as? String
        spot.ownerId = dict["ownerId"] as? String
        spot.shareURL = dict["shareURL"] as? String
        spot.sharePending = (dict["sharePending"] as? Bool) ?? false
        spot.participantIds = (dict["participantIds"] as? [String]) ?? []
        return spot
    }

    static func parseFriends(_ raw: String?) -> [Friend] {
        array(raw).compactMap(parseFriend)
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    static func parseFriend(_ dict: [String: Any]) -> Friend? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let color = dict["color"] as? String
        else { return nil }
        var friend = Friend(id: id, name: name, emoji: dict["emoji"] as? String, color: color)
        if optionalString(dict["friendshipZone"]) {
            friend.friendshipZone = dict["friendshipZone"] as? String
        }
        return friend
    }

    static func parseInvitations(_ raw: String?) -> [Invitation] {
        array(raw).compactMap(parseInvitation)
    }

    static func parseInvitation(_ dict: [String: Any]) -> Invitation? {
        guard let id = dict["id"] as? String,
              let spotId = dict["spotId"] as? String,
              let hostId = dict["hostId"] as? String,
              let time = number(dict["time"]),
              let createdAt = number(dict["createdAt"]),
              let cancelled = dict["cancelled"] as? Bool,
              let rawReplies = dict["replies"] as? [Any]
        else { return nil }
        // Eine kaputte Antwort darf nicht die ganze Einladung (= den Anker des
        // Gastgebers) mitnehmen — nur die Antwort faellt raus.
        let replies = rawReplies.compactMap { $0 as? [String: Any] }.compactMap(parseReply)
        return Invitation(id: id, spotId: spotId, hostId: hostId,
                          time: Date(epochMillis: Int64(time)),
                          createdAt: Date(epochMillis: Int64(createdAt)),
                          cancelled: cancelled, replies: replies)
    }

    static func parseReply(_ dict: [String: Any]) -> Reply? {
        guard let participantId = dict["participantId"] as? String,
              let raw = dict["status"] as? String,
              let status = ReplyStatus(rawValue: raw)
        else { return nil }
        if dict["arrivalTime"] != nil, number(dict["arrivalTime"]) == nil { return nil }
        return Reply(participantId: participantId, status: status,
                     arrivalTime: number(dict["arrivalTime"]).map { Date(epochMillis: Int64($0)) })
    }

    // MARK: - Typpruefungen (Pendant zu `optional()` in store.ts)

    /// `NSNumber` deckt auch Bool ab — ein `true` waere sonst die Zahl 1.
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    static func optionalString(_ value: Any?) -> Bool {
        value == nil || value is NSNull || value is String
    }

    static func optionalBool(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return true }
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func optionalStrings(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return true }
        guard let list = value as? [Any] else { return false }
        return list.allSatisfy { $0 is String }
    }
}
