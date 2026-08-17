import Foundation
@testable import GreenZonesKit

/// Der Fake steht EXAKT auf dem `CloudGateway`-Contract — keine erfundene
/// Methode, kein erfundenes Feld. Ein Mock mit eigener Form wuerde hier gruen
/// werden und auf dem Geraet scheitern.
final class FakeGateway: CloudGateway, @unchecked Sendable {
    var next: CloudSnapshot = .empty(status: .available)
    var account: CKAccountStatus = .available
    /// Methodenname → Fehler, den der naechste Aufruf wirft.
    var fails: [String: SyncError] = [:]
    private(set) var calls: [String] = []
    private(set) var offers: [(zoneName: String, friendshipZones: [String])] = []

    private func guardCall(_ name: String) throws {
        calls.append(name)
        if let error = fails[name] { throw error }
    }

    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }
    var offeredZones: [[String]] { offers.map(\.friendshipZones) }

    func accountStatus() async throws -> CKAccountStatus {
        try guardCall("accountStatus")
        return account
    }

    func fetchAll() async throws -> CloudSnapshot {
        try guardCall("fetchAll")
        return next
    }

    func createFriendInvite(displayName: String, emoji: String) async throws -> String {
        try guardCall("createFriendInvite")
        return "https://www.icloud.com/share/\(displayName)"
    }

    func setProfile(name: String, emoji: String) async throws {
        try guardCall("setProfile")
    }

    private(set) var removedFriends: [String] = []
    /// Hochgeladene Snaps in der Reihenfolge des Aufrufs.
    private(set) var uploadedSnaps: [String] = []
    private(set) var deletedSnaps: [String] = []
    private(set) var reportedSnaps: [String] = []
    /// Was `fetchThumbs` liefern soll — je Snap-Id.
    var thumbs: [String: Data] = [:]

    func uploadSnap(_ snap: Snap, original: URL, thumb: URL) async throws -> SnapUpload {
        try guardCall("uploadSnap")
        uploadedSnaps.append(snap.id)
        let zone = snap.scope == .spot ? (snap.spotZone ?? "spot-?") : "feed-me"
        return SnapUpload(zoneName: zone, recordName: snap.id)
    }

    func deleteSnap(zoneName: String, recordName: String) async throws {
        try guardCall("deleteSnap")
        deletedSnaps.append(recordName)
    }

    func reportSnap(zoneName: String, snapId: String, at date: Date) async throws {
        try guardCall("reportSnap")
        reportedSnaps.append(snapId)
    }

    func fetchThumbs(_ refs: [SnapAsset]) async throws -> [String: Data] {
        try guardCall("fetchThumbs")
        return thumbs.filter { key, _ in refs.contains { $0.snapId == key } }
    }

    func fetchOriginal(_ ref: SnapAsset) async throws -> Data {
        try guardCall("fetchOriginal")
        guard let data = thumbs[ref.snapId] else { throw SyncError.notFound }
        return data
    }

    func removeFriend(userID: String, friendshipZone: String) async throws {
        try guardCall("removeFriend")
        removedFriends.append(userID)
    }

    /// Wer aus welchem Spot genommen wurde — Zone und Person, damit ein Test
    /// nicht nur „irgendwas passierte" pruefen kann.
    private(set) var removedFromSpots: [(zoneName: String, userID: String)] = []

    func removeSpotParticipant(zoneName: String, userID: String) async throws {
        try guardCall("removeSpotParticipant")
        removedFromSpots.append((zoneName, userID))
    }

    func createSpotShare(_ spot: Spot) async throws -> SpotShare {
        try guardCall("createSpotShare")
        return SpotShare(zoneName: "spot-\(spot.id)",
                         shareURL: "https://www.icloud.com/share/\(spot.id)")
    }

    func offerSpotToFriends(zoneName: String, shareURL: String, spotName: String,
                            spotEmoji: String, friendshipZones: [String]) async throws {
        try guardCall("offerSpotToFriends")
        offers.append((zoneName, friendshipZones))
    }

    func deleteSpot(zoneName: String) async throws {
        try guardCall("deleteSpot")
    }

    func saveInvitation(spotZone: String, id: String, time: Date, createdAt: Date,
                        cancelled: Bool) async throws {
        try guardCall("saveInvitation")
    }

    func saveReply(spotZone: String, invitationId: String, status: ReplyStatus,
                   arrivalTime: Date?) async throws {
        try guardCall("saveReply")
    }

    func registerSubscriptions() async throws {
        try guardCall("registerSubscriptions")
    }

    func ensureNotificationPermission() async throws -> Bool {
        try guardCall("ensureNotificationPermission")
        return true
    }
}

/// Stores + Coordinator ueber einer echten (In-Memory-)SQLite — die
/// Persistenz-Schicht bleibt im Test drin. Ein Mock-Store wuerde genau die
/// Schicht wegnehmen, deren Roundtrip hier bewiesen werden soll.
@MainActor
struct CommunityHarness {
    let database: AppDatabase
    let spots: SpotStore
    let friends: FriendStore
    let invites: InviteStore
    let settings: SettingsStore
    let gateway: FakeGateway
    let sync: SyncCoordinator

    init(clock: GZClock = SystemClock(), path: String? = nil) throws {
        database = try AppDatabase(path: path, migrations: CommunityMigrations.all)
        spots = SpotStore(database, clock: clock)
        friends = FriendStore(database)
        invites = InviteStore(database)
        settings = SettingsStore(database)
        gateway = FakeGateway()
        sync = SyncCoordinator(gateway: gateway, spots: spots, friends: friends,
                               invites: invites, settings: settings, clock: clock)
    }
}

// MARK: - Contract-Bausteine (Pendant zu den Fabriken in sync.test.ts)

let ME = "_me001"
let TARA = "_tara01"
let MARCEL = "_marcel1"

func cloudSpot(zoneName: String, ownerUserID: String = "", isMine: Bool = true,
               name: String = "Unsere Bank", emoji: String = "🪑",
               lng: Double = 9.7218, lat: Double = 52.3663,
               createdAt: Int64 = 1000, participantUserIDs: [String] = [],
               shareURL: String = "") -> CloudSpot {
    CloudSpot(zoneName: zoneName, ownerUserID: ownerUserID, isMine: isMine, name: name,
              emoji: emoji, lng: lng, lat: lat, createdAt: Date(epochMillis: createdAt),
              participantUserIDs: participantUserIDs, shareURL: shareURL)
}

func cloudInvitation(id: String, spotZone: String, hostUserID: String = ME,
                     time: Int64 = 1_800_000_000_000, createdAt: Int64 = 900,
                     cancelled: Bool = false, replies: [CloudReply] = []) -> CloudInvitation {
    CloudInvitation(id: id, spotZone: spotZone, hostUserID: hostUserID,
                    time: Date(epochMillis: time), createdAt: Date(epochMillis: createdAt),
                    cancelled: cancelled, replies: replies)
}

func cloudFriend(userID: String, name: String = "Tara", emoji: String = "",
                 isOwner: Bool = true) -> CloudFriend {
    CloudFriend(userID: userID, name: name, emoji: emoji,
                friendshipZone: "friend-\(userID)", isOwner: isOwner)
}

func snapshot(status: CKAccountStatus = .available, userID: String = ME,
              friends: [CloudFriend] = [], spots: [CloudSpot] = [],
              invitations: [CloudInvitation] = [],
              snaps: [CloudSnap] = []) -> CloudSnapshot {
    CloudSnapshot(status: status, userID: userID, friends: friends, spots: spots,
                  invitations: invitations, snaps: snaps)
}

let LOCAL_SPOT = Spot(id: "lokal-1", name: "Balkon", emoji: "🌳", lng: 9.7, lat: 52.3,
                      createdAt: Date(epochMillis: 500))
