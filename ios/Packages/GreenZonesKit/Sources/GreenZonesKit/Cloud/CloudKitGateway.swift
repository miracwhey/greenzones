import CloudKit
import Foundation
import os
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Der echte CloudKit-Zugang (SPEC 7 + 11). Port von
/// `client/ios/App/App/CloudKitSync/CloudKitService.swift` — typisiert statt
/// `[String: Any]`, ohne Capacitor-Bruecke, mit den v2-Ergaenzungen Feed-Zone,
/// `FeedOffer` und `removeFriend`.
///
/// **Vollabzug statt Change-Tokens:** pro Zone `recordZoneChanges(since: nil)`.
/// Die Datenmengen sind eine Handvoll Records je Zone; ein persistierter Token
/// waere ein zweiter Zustand, der mit dem lokalen Bestand auseinanderlaufen
/// kann. Bleibt so bis Snaps (W5) das Volumen aendern.
///
/// **Ein Actor:** CloudKit-Typen (`CKRecord`, `CKShare`) sind nicht `Sendable`.
/// Sie bleiben deshalb vollstaendig hier drin; nach aussen gehen nur die
/// Contract-Typen aus `CloudSnapshot.swift`.
public actor CloudKitGateway: CloudGateway {
    private let container: CKContainer
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase { container.sharedCloudDatabase }
    private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "cloudkit")

    /// Letzter bekannter eigener Anzeigename. Ein von aussen (Universal Link)
    /// angenommener Freundschafts-Share muss sein Profile schreiben koennen,
    /// ohne dass jemand den Namen mitliefert.
    private let profileMemory: ProfileMemory

    public init(containerID: String = CKSchema.containerID,
                defaults: UserDefaults = .standard) {
        self.container = CKContainer(identifier: containerID)
        self.profileMemory = ProfileMemory(defaults: defaults)
    }

    // MARK: - Konto

    public func accountStatus() async throws -> CKAccountStatus {
        contractStatus(try await container.accountStatus())
    }

    /// Liefert die eigene userRecordID. Schreibpfade brauchen einen verfuegbaren
    /// Account — ohne ihn gibt es nichts nachzuholen, also ehrlicher Abbruch
    /// statt stiller Warteschlange.
    @discardableResult
    private func requireAccount() async throws -> String {
        let status = contractStatus(try await container.accountStatus())
        guard status == .available else { throw SyncError.noAccount }
        return try await container.userRecordID().recordName
    }

    // MARK: - Vollabzug

    public func fetchAll() async throws -> CloudSnapshot {
        let status = contractStatus(try await container.accountStatus())
        guard status == .available else {
            // Kein Konto ist ein definierter Zustand, kein Fehler.
            return .empty(status: status)
        }
        do {
            return try await fetchSnapshot()
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    private func fetchSnapshot() async throws -> CloudSnapshot {
        let myID = try await container.userRecordID().recordName

        var privateZones = try await privateDB.allRecordZones()
        var sharedZones = try await sharedDB.allRecordZones()

        // Eigener Feed: einmalig anlegen (idempotent wie der Spot-Share). Ohne
        // ihn koennte ab W5 niemand Snaps von mir sehen — die Zone muss stehen,
        // bevor der erste FeedOffer sie ankuendigt.
        let feed = try await ensureFeedZone(privateZones: privateZones)
        if feed.created { privateZones = try await privateDB.allRecordZones() }

        var friendZones = zones(withPrefix: CKSchema.friendZonePrefix,
                                private: privateZones, shared: sharedZones)
        var friendRecords = try await records(of: friendZones)

        // Offene Angebote (Spot UND Feed) annehmen. Danach liegen neue Zonen in
        // der shared DB — die Freundes-Zonen selbst aendern sich dabei nicht.
        if try await acceptPendingOffers(friendRecords: friendRecords,
                                         knownZones: privateZones + sharedZones) {
            sharedZones = try await sharedDB.allRecordZones()
        }

        // Eigenen FeedOffer in jede Friendship-Zone legen, die ihn noch nicht
        // hat. Damit bekommen auch Bestandsfreundschaften aus v1 den Feed, ohne
        // dass jemand etwas neu einrichten muss.
        if try await publishFeedOffers(feedShareURL: feed.shareURL, myID: myID,
                                       zones: friendZones, records: friendRecords) {
            friendZones = zones(withPrefix: CKSchema.friendZonePrefix,
                                private: privateZones, shared: sharedZones)
            friendRecords = try await records(of: friendZones)
        }

        var friends: [CloudFriend] = []
        for (index, entry) in friendZones.enumerated() {
            guard let friend = await buildFriend(entry: entry,
                                                 records: friendRecords[index],
                                                 myID: myID,
                                                 sharedZones: sharedZones) else { continue }
            friends.append(friend)
        }

        let spotZones = zones(withPrefix: CKSchema.spotZonePrefix,
                              private: privateZones, shared: sharedZones)
        var spots: [CloudSpot] = []
        var invitations: [CloudInvitation] = []
        var snaps: [CloudSnap] = []
        for entry in spotZones {
            let records = try await lightRecords(in: entry)
            snaps.append(contentsOf: records.compactMap { CKSnapRecord.parse($0, myID: myID) })
            guard let spotRecord = records.first(where: { $0.recordType == CKSchema.typeSpot }) else {
                continue
            }
            let share = await fetchZoneShare(entry.zoneID, from: database(for: entry))
            spots.append(Self.spot(entry: entry, record: spotRecord, share: share, myID: myID))
            invitations.append(contentsOf: Self.invitations(entry: entry, records: records, myID: myID))
        }

        // Feeds: der eigene und die angenommenen der Freunde. Sie tragen nur
        // Snaps (und den Feed-Marker), deshalb genuegt ein Durchgang.
        for entry in zones(withPrefix: CKSchema.feedZonePrefix,
                           private: privateZones, shared: sharedZones) {
            let records = try await lightRecords(in: entry)
            snaps.append(contentsOf: records.compactMap { CKSnapRecord.parse($0, myID: myID) })
        }

        return CloudSnapshot(status: .available, userID: myID, friends: friends,
                             spots: spots, invitations: invitations, snaps: snaps)
    }

    // MARK: - Freundschaften

    public func createFriendInvite(displayName: String, emoji: String) async throws -> String {
        let myID = try await requireAccount()
        profileMemory.remember(name: displayName, emoji: emoji)

        do {
            let zoneID = CKRecordZone.ID(zoneName: CKSchema.friendZoneName(),
                                         ownerName: CKCurrentUserDefaultName)
            _ = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])

            // Zone-Sharing: der Share deckt die ganze Zone ab — keine
            // parent-Referenzen noetig. Beitritt ausschliesslich ueber die URL;
            // es gibt kein Nutzerverzeichnis, das Teilnehmer aufloesen koennte.
            let share = CKShare(recordZoneID: zoneID)
            share.publicPermission = .readWrite
            let savedShare = try await save(share: share, in: privateDB)

            let friendship = CKRecord(recordType: CKSchema.typeFriendship,
                                      recordID: CKRecord.ID(recordName: CKSchema.friendshipRecordName,
                                                            zoneID: zoneID))
            friendship["createdAt"] = Date()
            _ = try await privateDB.modifyRecords(saving: [friendship, profileRecord(name: displayName,
                                                                                     emoji: emoji,
                                                                                     userID: myID,
                                                                                     zoneID: zoneID)],
                                                  deleting: [], savePolicy: .allKeys, atomically: true)

            guard let url = savedShare.url?.absoluteString else { throw SyncError.cloudInternal }
            return url
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    public func setProfile(name: String, emoji: String) async throws {
        let myID = try await requireAccount()
        profileMemory.remember(name: name, emoji: emoji)

        do {
            for isMine in [true, false] {
                let database = isMine ? privateDB : sharedDB
                let records = try await database.allRecordZones()
                    .filter { $0.zoneID.zoneName.hasPrefix(CKSchema.friendZonePrefix) }
                    .map { profileRecord(name: name, emoji: emoji, userID: myID, zoneID: $0.zoneID) }
                guard !records.isEmpty else { continue }
                // Zonenuebergreifend, deshalb nicht atomar: eine tote Zone darf
                // die anderen nicht blockieren.
                _ = try await database.modifyRecords(saving: records, deleting: [],
                                                     savePolicy: .allKeys, atomically: false)
            }
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    /// Freundschaft beenden (SPEC 7). Zwei Netz-Phasen, jede fuer sich idempotent:
    ///  (a) die Friendship-Zone verlassen bzw. loeschen,
    ///  (b) die Person aus allen eigenen Shares (Spots + Feed) entfernen.
    ///
    /// Phase (b) laeuft auch, wenn (a) scheitert — sonst bliebe jemand, den man
    /// gerade entfernt hat, weiter in den eigenen Spots. Der erste Fehler wird
    /// am Ende geworfen, damit die UI den Teilerfolg ehrlich melden kann.
    public func removeFriend(userID: String, friendshipZone: String) async throws {
        try await requireAccount()
        var firstFailure: Error?

        do {
            // Wo die Zone liegt, sagt die Datenbank: in der privaten habe ich
            // die Freundschaft angelegt (loeschen), in der geteilten bin ich
            // Gast (Teilnahme beenden). Eine schon verschwundene Zone ist kein
            // Fehler, sondern das Ziel.
            if let located = try await zoneIndex()[friendshipZone] {
                _ = try await (located.isMine ? privateDB : sharedDB)
                    .modifyRecordZones(saving: [], deleting: [located.zoneID])
            }
        } catch {
            if CKErrorMapper.syncError(for: error) != .notFound { firstFailure = error }
        }

        do {
            try await removeParticipant(userID: userID)
        } catch {
            if firstFailure == nil { firstFailure = error }
        }

        if let firstFailure { throw CKErrorMapper.syncError(for: firstFailure) }
    }

    /// Aus jedem eigenen Zone-Share (Spots und Feed) austragen.
    private func removeParticipant(userID: String) async throws {
        var lastError: Error?
        for zone in try await privateDB.allRecordZones() {
            let name = zone.zoneID.zoneName
            guard name.hasPrefix(CKSchema.spotZonePrefix) || name.hasPrefix(CKSchema.feedZonePrefix) else {
                continue
            }
            guard let share = await fetchZoneShare(zone.zoneID, from: privateDB) else { continue }
            guard let participant = share.participants.first(where: {
                $0.userIdentity.userRecordID?.recordName == userID
            }) else { continue }
            do {
                share.removeParticipant(participant)
                _ = try await privateDB.modifyRecords(saving: [share], deleting: [],
                                                      savePolicy: .allKeys, atomically: true)
            } catch {
                logger.error("Teilnehmer nicht aus \(name, privacy: .public) entfernt: \(String(describing: error), privacy: .public)")
                lastError = error
            }
        }
        if let lastError { throw lastError }
    }

    /// Aus EINEM eigenen Spot-Share austragen. Die Freundschaft bleibt — nur der
    /// Zugang zu dieser Zone endet. Wer nicht (mehr) drinsteht, ist der
    /// Zielzustand, kein Fehler.
    public func removeSpotParticipant(zoneName: String, userID: String) async throws {
        try await requireAccount()
        do {
            // Nur eigene Zonen: in einem fremden Spot bin ich Gast und kann
            // niemanden austragen. `zoneIndex` sagt, wem die Zone gehoert.
            guard let located = try await zoneIndex()[zoneName], located.isMine,
                  let share = await fetchZoneShare(located.zoneID, from: privateDB) else { return }
            guard let participant = share.participants.first(where: {
                $0.userIdentity.userRecordID?.recordName == userID
            }) else { return }
            share.removeParticipant(participant)
            _ = try await privateDB.modifyRecords(saving: [share], deleting: [],
                                                  savePolicy: .allKeys, atomically: true)
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    // MARK: - Spots

    public func createSpotShare(_ spot: Spot) async throws -> SpotShare {
        try await requireAccount()
        do {
            let zoneName = CKSchema.spotZoneName(spotId: spot.id)
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
            _ = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])

            // Idempotent: ein zweiter Aufruf fuer denselben Spot darf den
            // bestehenden Share nicht ersetzen, sonst laufen bereits verteilte
            // Links ins Leere.
            let share = try await ensureZoneShare(zoneID)

            let record = CKRecord(recordType: CKSchema.typeSpot,
                                  recordID: CKRecord.ID(recordName: CKSchema.spotRecordName, zoneID: zoneID))
            record["name"] = spot.name
            record["emoji"] = spot.emoji
            record["lng"] = spot.lng
            record["lat"] = spot.lat
            record["createdAt"] = spot.createdAt
            _ = try await privateDB.modifyRecords(saving: [record], deleting: [],
                                                  savePolicy: .allKeys, atomically: true)

            guard let url = share.url?.absoluteString else { throw SyncError.cloudInternal }
            return SpotShare(zoneName: zoneName, shareURL: url)
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    public func offerSpotToFriends(zoneName: String, shareURL: String, spotName: String,
                                   spotEmoji: String, friendshipZones: [String]) async throws {
        try await requireAccount()
        do {
            let index = try await zoneIndex()
            var byDatabase: [Bool: [CKRecord]] = [:]
            for friendshipZone in friendshipZones {
                guard let located = index[friendshipZone] else { throw SyncError.notFound }
                let record = CKRecord(recordType: CKSchema.typeSpotOffer,
                                      recordID: CKRecord.ID(recordName: CKSchema.offerRecordName(spotZone: zoneName),
                                                            zoneID: located.zoneID))
                record["spotShareURL"] = shareURL
                record["spotName"] = spotName
                record["spotEmoji"] = spotEmoji
                byDatabase[located.isMine, default: []].append(record)
            }
            for (isMine, records) in byDatabase {
                _ = try await (isMine ? privateDB : sharedDB)
                    .modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
            }
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    public func deleteSpot(zoneName: String) async throws {
        try await requireAccount()
        do {
            guard let located = try await zoneIndex()[zoneName] else { throw SyncError.notFound }
            _ = try await (located.isMine ? privateDB : sharedDB)
                .modifyRecordZones(saving: [], deleting: [located.zoneID])
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    // MARK: - Einladungen und Antworten

    public func saveInvitation(spotZone: String, id: String, time: Date, createdAt: Date,
                               cancelled: Bool) async throws {
        try await requireAccount()
        do {
            guard let located = try await zoneIndex()[spotZone] else { throw SyncError.notFound }
            // hostId kommt aus `creatorUserRecordID` (Systemfeld) — kein eigenes
            // Feld, nicht faelschbar.
            let record = CKRecord(recordType: CKSchema.typeInvitation,
                                  recordID: CKRecord.ID(recordName: id, zoneID: located.zoneID))
            record["time"] = time
            record["createdAt"] = createdAt
            record["cancelled"] = cancelled ? 1 : 0
            _ = try await (located.isMine ? privateDB : sharedDB)
                .modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    public func saveReply(spotZone: String, invitationId: String, status: ReplyStatus,
                          arrivalTime: Date?) async throws {
        let myID = try await requireAccount()
        do {
            guard let located = try await zoneIndex()[spotZone] else { throw SyncError.notFound }
            let record = CKRecord(recordType: CKSchema.typeReply,
                                  recordID: CKRecord.ID(recordName: CKSchema.replyRecordName(invitationId: invitationId,
                                                                                             userID: myID),
                                                        zoneID: located.zoneID))
            record["invitationId"] = invitationId
            record["status"] = status.rawValue
            record["arrivalTime"] = arrivalTime
            // `.allKeys` raeumt eine zuvor gesetzte arrivalTime mit ab, wenn
            // jetzt keine mehr genannt wird.
            _ = try await (located.isMine ? privateDB : sharedDB)
                .modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    // MARK: - Feed (SPEC 7)

    private struct FeedZone {
        let zoneName: String
        let shareURL: String
        let created: Bool
    }

    /// Eigene Feed-Zone samt Share. Idempotent: eine vorhandene Zone wird nie
    /// ersetzt, sonst liefen verteilte `FeedOffer` ins Leere.
    @discardableResult
    private func ensureFeedZone(privateZones: [CKRecordZone]) async throws -> FeedZone {
        if let existing = privateZones.first(where: { $0.zoneID.zoneName.hasPrefix(CKSchema.feedZonePrefix) }) {
            let share = try await ensureZoneShare(existing.zoneID)
            return FeedZone(zoneName: existing.zoneID.zoneName,
                            shareURL: share.url?.absoluteString ?? "",
                            created: false)
        }

        let zoneID = CKRecordZone.ID(zoneName: CKSchema.feedZoneName(), ownerName: CKCurrentUserDefaultName)
        _ = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let share = try await ensureZoneShare(zoneID)

        let feed = CKRecord(recordType: CKSchema.typeFeed,
                            recordID: CKRecord.ID(recordName: CKSchema.feedRecordName, zoneID: zoneID))
        feed["createdAt"] = Date()
        _ = try await privateDB.modifyRecords(saving: [feed], deleting: [],
                                              savePolicy: .allKeys, atomically: true)

        return FeedZone(zoneName: zoneID.zoneName,
                        shareURL: share.url?.absoluteString ?? "",
                        created: true)
    }

    /// Den eigenen Feed in jeder Friendship-Zone ankuendigen, die ihn noch nicht
    /// kennt. Liefert `true`, wenn etwas geschrieben wurde.
    private func publishFeedOffers(feedShareURL: String, myID: String,
                                   zones: [ZoneEntry], records: [[CKRecord]]) async throws -> Bool {
        guard !feedShareURL.isEmpty else { return false }
        let recordName = CKSchema.feedOfferRecordName(userID: myID)

        var byDatabase: [Bool: [CKRecord]] = [:]
        for (index, entry) in zones.enumerated() {
            let mine = records[index].first {
                $0.recordType == CKSchema.typeFeedOffer && $0.recordID.recordName == recordName
            }
            // Gleiche URL = nichts zu tun. Ein Schreibvorgang pro Fetch waere
            // eine Dauerlast auf jeder Freundschaft.
            if let mine, mine["feedShareURL"] as? String == feedShareURL { continue }
            let record = CKRecord(recordType: CKSchema.typeFeedOffer,
                                  recordID: CKRecord.ID(recordName: recordName, zoneID: entry.zoneID))
            record["feedShareURL"] = feedShareURL
            byDatabase[entry.isMine, default: []].append(record)
        }

        guard !byDatabase.isEmpty else { return false }
        for (isMine, records) in byDatabase {
            _ = try await (isMine ? privateDB : sharedDB)
                .modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
        }
        return true
    }

    // MARK: - Snaps (W5)

    /// Ein Snap-Record traegt zwei Assets. Er liegt in der Feed-Zone (alle
    /// Freunde) oder in der Spot-Zone (nur deren Mitglieder) — die Zone IST die
    /// Sichtbarkeit, es gibt kein Feld dafuer.
    public func uploadSnap(_ snap: Snap, original: URL, thumb: URL) async throws -> SnapUpload {
        try await requireAccount()
        do {
            let zoneName = try await zoneForUpload(snap)
            guard let located = try await zoneIndex()[zoneName] else { throw SyncError.notFound }

            let record = CKSnapRecord.make(snap, zoneID: located.zoneID,
                                           original: original, thumb: thumb)
            _ = try await (located.isMine ? privateDB : sharedDB)
                .modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
            return SnapUpload(zoneName: zoneName, recordName: snap.id)
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    /// Zielzone eines Snaps. „Nur Freunde im Spot" braucht die Spot-Zone; alles
    /// andere geht in den eigenen Feed, der beim ersten Fetch angelegt wurde.
    private func zoneForUpload(_ snap: Snap) async throws -> String {
        if snap.scope == .spot, let zone = snap.spotZone { return zone }
        let feed = try await ensureFeedZone(privateZones: try await privateDB.allRecordZones())
        return feed.zoneName
    }

    public func deleteSnap(zoneName: String, recordName: String) async throws {
        try await requireAccount()
        do {
            guard let located = try await zoneIndex()[zoneName] else { return }
            _ = try await (located.isMine ? privateDB : sharedDB)
                .modifyRecords(saving: [],
                               deleting: [CKRecord.ID(recordName: recordName, zoneID: located.zoneID)],
                               savePolicy: .allKeys, atomically: true)
        } catch {
            // Schon weg = Ziel erreicht.
            let mapped = CKErrorMapper.syncError(for: error)
            if mapped != .notFound { throw mapped }
        }
    }

    public func reportSnap(zoneName: String, snapId: String, at date: Date) async throws {
        let myID = try await requireAccount()
        do {
            guard let located = try await zoneIndex()[zoneName] else { throw SyncError.notFound }
            let record = CKRecord(recordType: CKSchema.typeReport,
                                  recordID: CKRecord.ID(recordName: CKSchema.reportRecordName(snapId: snapId,
                                                                                              userID: myID),
                                                        zoneID: located.zoneID))
            record["snapId"] = snapId
            record["createdAt"] = date
            _ = try await (located.isMine ? privateDB : sharedDB)
                .modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    public func fetchThumbs(_ refs: [SnapAsset]) async throws -> [String: Data] {
        try await fetchAssets(refs, key: "thumb")
    }

    public func fetchOriginal(_ ref: SnapAsset) async throws -> Data {
        let result = try await fetchAssets([ref], key: "photo")
        guard let data = result[ref.snapId] else { throw SyncError.notFound }
        return data
    }

    /// Assets in Stapeln von hoechstens 20 holen (SPEC 7). Fehlt ein einzelner
    /// Record, faellt nur er aus — die anderen kommen an.
    private func fetchAssets(_ refs: [SnapAsset], key: String) async throws -> [String: Data] {
        guard !refs.isEmpty else { return [:] }
        var out: [String: Data] = [:]
        do {
            let index = try await zoneIndex()
            for batch in stride(from: 0, to: refs.count, by: 20).map({ start in
                Array(refs[start..<min(start + 20, refs.count)])
            }) {
                var byDatabase: [Bool: [CKRecord.ID]] = [:]
                var idBySnap: [CKRecord.ID: String] = [:]
                for ref in batch {
                    guard let located = index[ref.zoneName] else { continue }
                    let recordID = CKRecord.ID(recordName: ref.recordName, zoneID: located.zoneID)
                    byDatabase[located.isMine, default: []].append(recordID)
                    idBySnap[recordID] = ref.snapId
                }
                for (isMine, ids) in byDatabase {
                    let results = try await (isMine ? privateDB : sharedDB)
                        .records(for: ids, desiredKeys: [key])
                    for (recordID, result) in results {
                        guard case .success(let record) = result,
                              let asset = record[key] as? CKAsset,
                              let url = asset.fileURL,
                              let data = try? Data(contentsOf: url),
                              let snapId = idBySnap[recordID] else { continue }
                        out[snapId] = data
                    }
                }
            }
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
        return out
    }

    // MARK: - Subscriptions und Push

    public func registerSubscriptions() async throws {
        try await requireAccount()
        do {
            try await ensureDatabaseSubscription(id: CKSchema.privateSubscriptionID, in: privateDB)
            try await ensureDatabaseSubscription(id: CKSchema.sharedSubscriptionID, in: sharedDB)
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
        #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        #endif
    }

    private func ensureDatabaseSubscription(id: String, in database: CKDatabase) async throws {
        let existing = try await database.allSubscriptions()
        // Alte silent-only-Subscriptions abraeumen — sie wuerden pro Aenderung
        // einen zweiten, bannerlosen Push erzeugen und blieben sonst fuer immer
        // registriert.
        let stale = existing.map(\.subscriptionID).filter { CKSchema.legacySubscriptionIDs.contains($0) }
        guard !existing.contains(where: { $0.subscriptionID == id }) else {
            if !stale.isEmpty { _ = try await database.modifySubscriptions(saving: [], deleting: stale) }
            return
        }

        let subscription = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        // Sichtbar + mutable: die Notification-Extension ersetzt den Text nach
        // einem Fetch durch das konkrete Ereignis. Stirbt sie, zeigt iOS diesen
        // neutralen Fallback.
        info.alertBody = "Neues von deinen Freunden"
        info.shouldSendMutableContent = true
        // Zusaetzlich content-available, damit die laufende App im Hintergrund
        // nachlaedt.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: stale)
    }

    /// Fragt einmalig nach der Mitteilungs-Erlaubnis. Der Systemstatus IST der
    /// Zustand — kein eigenes Flag: `notDetermined` heisst nie gefragt, alles
    /// andere ist entschieden.
    public func ensureNotificationPermission() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    // MARK: - Share-Annahme

    /// Einladungs-Link annehmen (Freund oder Spot). Idempotent.
    public func acceptShare(urlString: String) async throws {
        let myID = try await requireAccount()
        guard let url = URL(string: urlString) else { throw SyncError.notFound }
        do {
            let metadata = try await shareMetadata(for: url)
            try await accept(metadata: metadata)
            try await writeOwnProfileIfFriendshipZone(zoneID: metadata.share.recordID.zoneID, myID: myID)
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    /// Von aussen angenommener Share (Universal Link, Kaltstart wie laufend).
    /// Die Annahme muss die App selbst ausfuehren.
    public func acceptShare(metadata: CKShare.Metadata) async throws {
        let myID = try await requireAccount()
        do {
            try await accept(metadata: metadata)
            try await writeOwnProfileIfFriendshipZone(zoneID: metadata.share.recordID.zoneID, myID: myID)
        } catch {
            throw CKErrorMapper.syncError(for: error)
        }
    }

    private func shareMetadata(for url: URL) async throws -> CKShare.Metadata {
        let results = try await container.shareMetadatas(for: [url])
        guard let result = results[url] ?? results.values.first else { throw SyncError.notFound }
        switch result {
        case .success(let metadata): return metadata
        case .failure(let error): throw error
        }
    }

    /// Idempotent: ein bereits angenommener Share ist Erfolg, kein Fehler — der
    /// Auto-Accept aus `fetchSnapshot` laeuft bei jedem Durchgang erneut ueber
    /// dieselben Offers.
    private func accept(metadata: CKShare.Metadata) async throws {
        guard metadata.participantStatus != .accepted else { return }
        let results = try await container.accept([metadata])
        guard let result = results[metadata] ?? results.values.first else { return }
        if case .failure(let error) = result {
            if let ckError = error as? CKError, ckError.code == .alreadyShared { return }
            throw error
        }
    }

    /// Ohne Namen wird kein Profil geschrieben: ein leerer Record sagt dem
    /// Gegenueber nichts. Die App fragt nach dem Beitritt danach, und
    /// `setProfile` traegt ihn dann in alle Freundschafts-Zonen nach.
    private func writeOwnProfileIfFriendshipZone(zoneID: CKRecordZone.ID, myID: String) async throws {
        guard zoneID.zoneName.hasPrefix(CKSchema.friendZonePrefix) else { return }
        let name = profileMemory.name
        guard !name.isEmpty else { return }
        _ = try await sharedDB.modifyRecords(saving: [profileRecord(name: name,
                                                                    emoji: profileMemory.emoji,
                                                                    userID: myID,
                                                                    zoneID: zoneID)],
                                             deleting: [], savePolicy: .allKeys, atomically: true)
    }

    /// `SpotOffer`/`FeedOffer` = Transportkanal fuer Zone-Shares an bestehende
    /// Freunde. Ein Offer, dessen Ziel-Zone schon lokal bekannt ist, ist
    /// erledigt. Fehler beim Annehmen duerfen den Snapshot nicht kippen.
    private func acceptPendingOffers(friendRecords: [[CKRecord]],
                                     knownZones: [CKRecordZone]) async throws -> Bool {
        var known = Set(knownZones.map(\.zoneID.zoneName))
        var acceptedAny = false

        for records in friendRecords {
            for record in records {
                let urlKey: String
                let targetZone: String?
                switch record.recordType {
                case CKSchema.typeSpotOffer:
                    urlKey = "spotShareURL"
                    targetZone = CKSchema.offeredZone(recordName: record.recordID.recordName)
                case CKSchema.typeFeedOffer:
                    // Der Feed-Offer traegt die Ziel-Zone nicht im Namen (der
                    // kodiert den Schreiber). Ob er erledigt ist, entscheidet
                    // deshalb der Accept-Versuch selbst — er ist idempotent.
                    urlKey = "feedShareURL"
                    targetZone = nil
                default:
                    continue
                }
                if let targetZone, known.contains(targetZone) { continue }
                guard let urlString = record[urlKey] as? String, let url = URL(string: urlString) else {
                    continue
                }
                do {
                    let metadata = try await shareMetadata(for: url)
                    let zoneName = metadata.share.recordID.zoneID.zoneName
                    guard !known.contains(zoneName) else { continue }
                    try await accept(metadata: metadata)
                    known.insert(zoneName)
                    if let targetZone { known.insert(targetZone) }
                    acceptedAny = true
                } catch {
                    logger.error("Angebot nicht angenommen: \(String(describing: error), privacy: .public)")
                }
            }
        }
        return acceptedAny
    }

    // MARK: - Zonen-Hilfen

    private struct ZoneEntry {
        let zoneID: CKRecordZone.ID
        let isMine: Bool
    }

    private func database(for entry: ZoneEntry) -> CKDatabase { entry.isMine ? privateDB : sharedDB }

    private func zones(withPrefix prefix: String,
                       private privateZones: [CKRecordZone],
                       shared sharedZones: [CKRecordZone]) -> [ZoneEntry] {
        privateZones.filter { $0.zoneID.zoneName.hasPrefix(prefix) }
            .map { ZoneEntry(zoneID: $0.zoneID, isMine: true) }
        + sharedZones.filter { $0.zoneID.zoneName.hasPrefix(prefix) }
            .map { ZoneEntry(zoneID: $0.zoneID, isMine: false) }
    }

    private func records(of zones: [ZoneEntry]) async throws -> [[CKRecord]] {
        var out: [[CKRecord]] = []
        for entry in zones {
            out.append(try await lightRecords(in: entry))
        }
        return out
    }

    /// Vollabzug einer Zone OHNE die Bilddaten. Gilt fuer alle Zonen, nicht nur
    /// fuer die mit Snaps: eine Ausnahme waere die Stelle, an der die naechste
    /// Zone mit Assets durchrutscht.
    private func lightRecords(in entry: ZoneEntry) async throws -> [CKRecord] {
        try await CKZoneReader.fetchRecords(in: entry.zoneID, from: database(for: entry),
                                            desiredKeys: CKSchema.Field.lightweight)
    }

    private struct LocatedZone {
        let zoneID: CKRecordZone.ID
        let isMine: Bool
    }

    private func zoneIndex() async throws -> [String: LocatedZone] {
        var index: [String: LocatedZone] = [:]
        for zone in try await privateDB.allRecordZones() {
            index[zone.zoneID.zoneName] = LocatedZone(zoneID: zone.zoneID, isMine: true)
        }
        for zone in try await sharedDB.allRecordZones() where index[zone.zoneID.zoneName] == nil {
            index[zone.zoneID.zoneName] = LocatedZone(zoneID: zone.zoneID, isMine: false)
        }
        return index
    }

    private func fetchZoneShare(_ zoneID: CKRecordZone.ID, from database: CKDatabase) async -> CKShare? {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        return try? await database.record(for: shareID) as? CKShare
    }

    /// Share der Zone — vorhandener zuerst, sonst ein neuer mit URL-Beitritt.
    private func ensureZoneShare(_ zoneID: CKRecordZone.ID) async throws -> CKShare {
        if let existing = await fetchZoneShare(zoneID, from: privateDB) { return existing }
        let fresh = CKShare(recordZoneID: zoneID)
        fresh.publicPermission = .readWrite
        return try await save(share: fresh, in: privateDB)
    }

    private func save(share: CKShare, in database: CKDatabase) async throws -> CKShare {
        let result = try await database.modifyRecords(saving: [share], deleting: [],
                                                      savePolicy: .allKeys, atomically: true)
        guard let saveResult = result.saveResults[share.recordID] else { throw SyncError.cloudInternal }
        switch saveResult {
        case .success(let record):
            guard let saved = record as? CKShare else { throw SyncError.cloudInternal }
            return saved
        case .failure(let error):
            throw error
        }
    }

    private func profileRecord(name: String, emoji: String, userID: String,
                               zoneID: CKRecordZone.ID) -> CKRecord {
        // Jeder pflegt genau seinen Profile-Record — der recordName traegt den
        // Schreiber.
        let record = CKRecord(recordType: CKSchema.typeProfile,
                              recordID: CKRecord.ID(recordName: CKSchema.profileRecordName(userID: userID),
                                                    zoneID: zoneID))
        record["name"] = name
        record["emoji"] = emoji
        return record
    }

    // MARK: - Snapshot-Bausteine

    private func buildFriend(entry: ZoneEntry, records: [CKRecord], myID: String,
                             sharedZones: [CKRecordZone]) async -> CloudFriend? {
        let friendID: String
        if entry.isMine {
            // Freund-Identitaet steht im Share; solange niemand beigetreten ist,
            // gibt es keinen Freund.
            let share = await fetchZoneShare(entry.zoneID, from: privateDB)
            guard let joined = share?.participants
                .filter({ $0.acceptanceStatus == .accepted })
                .compactMap({ $0.userIdentity.userRecordID?.recordName })
                .first(where: { $0 != myID && $0 != CKCurrentUserDefaultName }) else { return nil }
            friendID = joined
        } else {
            friendID = entry.zoneID.ownerName
        }
        guard !friendID.isEmpty, friendID != CKCurrentUserDefaultName else { return nil }

        let profile = records.first { record in
            guard record.recordType == CKSchema.typeProfile else { return false }
            return Self.normalizedUser(record.creatorUserRecordID, myID: myID) == friendID
                || record.recordID.recordName == CKSchema.profileRecordName(userID: friendID)
        }

        // Feed-Zone des Gegenuebers: die angenommene `feed-`-Zone in der shared
        // DB, die ihm gehoert. Der `FeedOffer` traegt nur die Share-URL — welche
        // Zone daraus wurde, weiss erst die Datenbank nach dem Accept.
        let feedZone = sharedZones.first {
            $0.zoneID.zoneName.hasPrefix(CKSchema.feedZonePrefix) && $0.zoneID.ownerName == friendID
        }?.zoneID.zoneName ?? ""

        return CloudFriend(userID: friendID,
                           name: profile?["name"] as? String ?? "",
                           emoji: profile?["emoji"] as? String ?? "",
                           friendshipZone: entry.zoneID.zoneName,
                           isOwner: entry.isMine,
                           feedZone: feedZone)
    }

    private static func spot(entry: ZoneEntry, record: CKRecord, share: CKShare?,
                             myID: String) -> CloudSpot {
        let participants = (share?.participants ?? [])
            .filter { $0.acceptanceStatus == .accepted }
            .compactMap { $0.userIdentity.userRecordID?.recordName }
            .filter { $0 != myID && $0 != CKCurrentUserDefaultName }

        return CloudSpot(zoneName: entry.zoneID.zoneName,
                         ownerUserID: entry.isMine ? "" : entry.zoneID.ownerName,
                         isMine: entry.isMine,
                         name: record["name"] as? String ?? "",
                         emoji: record["emoji"] as? String ?? "",
                         lng: record["lng"] as? Double ?? 0,
                         lat: record["lat"] as? Double ?? 0,
                         createdAt: record["createdAt"] as? Date ?? Date(timeIntervalSince1970: 0),
                         participantUserIDs: participants,
                         shareURL: entry.isMine ? (share?.url?.absoluteString ?? "") : "")
    }

    private static func invitations(entry: ZoneEntry, records: [CKRecord],
                                    myID: String) -> [CloudInvitation] {
        var repliesByInvitation: [String: [CloudReply]] = [:]
        for record in records where record.recordType == CKSchema.typeReply {
            guard let invitationId = record["invitationId"] as? String else { continue }
            let status = ReplyStatus(rawValue: record["status"] as? String ?? "") ?? .out
            repliesByInvitation[invitationId, default: []].append(
                CloudReply(participantUserID: normalizedUser(record.creatorUserRecordID, myID: myID),
                           status: status,
                           arrivalTime: record["arrivalTime"] as? Date))
        }

        return records.filter { $0.recordType == CKSchema.typeInvitation }.map { record in
            let id = record.recordID.recordName
            return CloudInvitation(id: id,
                                   spotZone: entry.zoneID.zoneName,
                                   hostUserID: normalizedUser(record.creatorUserRecordID, myID: myID),
                                   time: record["time"] as? Date ?? Date(timeIntervalSince1970: 0),
                                   createdAt: record["createdAt"] as? Date ?? Date(timeIntervalSince1970: 0),
                                   cancelled: ((record["cancelled"] as? Int) ?? 0) != 0,
                                   replies: repliesByInvitation[id] ?? [])
        }
    }

    /// In der eigenen privaten DB steht `__defaultOwner__` statt der echten ID —
    /// fuer den Merge muss beides dieselbe Person sein.
    private static func normalizedUser(_ recordID: CKRecord.ID?, myID: String) -> String {
        guard let name = recordID?.recordName, name != CKCurrentUserDefaultName else { return myID }
        return name
    }
}

/// Eigener Anzeigename und Zeichen ausserhalb der App-DB.
///
/// Warum nicht der `SettingsStore`: den Profile-Record schreibt auch der
/// Share-Accept aus dem Kaltstart, bevor die Datenbank offen ist. Es sind
/// dieselben `UserDefaults`-Schluessel wie in v1 — ein Update erbt damit den
/// Namen, den der Nutzer dort gesetzt hat.
private struct ProfileMemory {
    static let nameKey = "CapacitorStorage.gz_display_name"
    static let emojiKey = "CapacitorStorage.gz_profile_emoji"

    let defaults: UserDefaults

    var name: String { defaults.string(forKey: Self.nameKey) ?? "" }
    var emoji: String { defaults.string(forKey: Self.emojiKey) ?? "" }

    /// Das Zeichen wird auch leer geschrieben — „Ohne" ist eine Wahl, kein
    /// fehlender Wert.
    func remember(name: String, emoji: String) {
        if !name.isEmpty { defaults.set(name, forKey: Self.nameKey) }
        defaults.set(emoji, forKey: Self.emojiKey)
    }
}
