import Foundation
import CloudKit
import UIKit

/// Alle CloudKit-Zugriffe der App.
///
/// Pull-Snapshot: `fetchSnapshot()` liefert immer den kompletten Zustand. Change-Tokens werden
/// bewusst nicht persistiert — pro Zone wird mit `since: nil` ein Vollabzug geholt (Datenmengen
/// sind eine Handvoll Records). Deployment-Target ist iOS 15, also klassische CloudKit-Operationen,
/// kein CKSyncEngine.
final class CloudKitService {
    static let shared = CloudKitService()

    /// Feuert, wenn sich der Cloud-Zustand geändert haben kann: silent Push oder Share-Accept.
    static let cloudChangedNotification = Notification.Name("GreenZonesCloudChanged")

    private let container = CKContainer(identifier: CKSchema.containerID)
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase { container.sharedCloudDatabase }

    private init() {}

    // MARK: - Account

    static func statusName(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "noAccount"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "couldNotDetermine"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        @unknown default: return "couldNotDetermine"
        }
    }

    func accountStatusName() async throws -> String {
        Self.statusName(try await container.accountStatus())
    }

    /// Liefert die eigene userRecordID. Schreibpfade brauchen einen verfügbaren Account —
    /// ohne ihn gibt es nichts nachzuholen, also ehrlicher Abbruch statt stiller Warteschlange.
    @discardableResult
    private func requireAccount() async throws -> String {
        let status = try await container.accountStatus()
        guard status == .available else {
            throw SyncError(.noAccount, "iCloud ist gerade nicht verfügbar (\(Self.statusName(status))).")
        }
        return try await container.userRecordID().recordName
    }

    // MARK: - Snapshot

    func fetchSnapshot() async throws -> [String: Any] {
        let status = try await container.accountStatus()
        guard status == .available else {
            // Kein Account ist ein definierter Zustand, kein Fehler.
            return Self.emptySnapshot(status: Self.statusName(status))
        }
        let myID = try await container.userRecordID().recordName

        let privateZones = try await privateDB.allRecordZones()
        var sharedZones = try await sharedDB.allRecordZones()

        // Freundschafts-Zonen einmal lesen: sie tragen Profile, Freund-Identität und offene SpotOffers.
        var friendZones: [ZoneEntry] = []
        for zone in privateZones where zone.zoneID.zoneName.hasPrefix(CKSchema.friendZonePrefix) {
            friendZones.append(ZoneEntry(zone: zone, isMine: true))
        }
        for zone in sharedZones where zone.zoneID.zoneName.hasPrefix(CKSchema.friendZonePrefix) {
            friendZones.append(ZoneEntry(zone: zone, isMine: false))
        }

        var friendRecords: [[CKRecord]] = []
        for entry in friendZones {
            friendRecords.append(try await fetchAllRecords(in: entry.zone.zoneID, from: database(for: entry)))
        }

        if try await acceptPendingOffers(friendRecords: friendRecords,
                                         knownZones: privateZones + sharedZones) {
            sharedZones = try await sharedDB.allRecordZones()
        }

        var friends: [[String: Any]] = []
        for (index, entry) in friendZones.enumerated() {
            if let friend = await buildFriend(entry: entry, records: friendRecords[index], myID: myID) {
                friends.append(friend)
            }
        }

        var spotZones: [ZoneEntry] = []
        for zone in privateZones where zone.zoneID.zoneName.hasPrefix(CKSchema.spotZonePrefix) {
            spotZones.append(ZoneEntry(zone: zone, isMine: true))
        }
        for zone in sharedZones where zone.zoneID.zoneName.hasPrefix(CKSchema.spotZonePrefix) {
            spotZones.append(ZoneEntry(zone: zone, isMine: false))
        }

        var spots: [[String: Any]] = []
        var invitations: [[String: Any]] = []
        for entry in spotZones {
            let records = try await fetchAllRecords(in: entry.zone.zoneID, from: database(for: entry))
            guard let spotRecord = records.first(where: { $0.recordType == CKSchema.typeSpot }) else {
                continue
            }
            let share = await fetchZoneShare(entry.zone.zoneID, from: database(for: entry))
            spots.append(Self.spotDict(entry: entry, record: spotRecord, share: share, myID: myID))
            invitations.append(contentsOf: Self.invitationDicts(entry: entry, records: records, myID: myID))
        }

        return [
            "status": "available",
            "userID": myID,
            "friends": friends,
            "spots": spots,
            "invitations": invitations
        ]
    }

    private static func emptySnapshot(status: String) -> [String: Any] {
        [
            "status": status,
            "userID": "",
            "friends": [[String: Any]](),
            "spots": [[String: Any]](),
            "invitations": [[String: Any]]()
        ]
    }

    // MARK: - Freundschaften

    func createFriendInvite(displayName: String) async throws -> String {
        let myID = try await requireAccount()
        rememberDisplayName(displayName)

        let zoneID = CKRecordZone.ID(zoneName: CKSchema.friendZonePrefix + UUID().uuidString.lowercased(),
                                     ownerName: CKCurrentUserDefaultName)
        _ = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])

        // Zone-Sharing (iOS 15+): der Share deckt die ganze Zone ab — keine parent-Referenzen nötig.
        let share = CKShare(recordZoneID: zoneID)
        // Beitritt ausschließlich über die URL; es gibt kein Nutzerverzeichnis, das Teilnehmer auflösen könnte.
        share.publicPermission = .readWrite
        let savedShare = try await save(share: share, in: privateDB)

        let friendship = CKRecord(recordType: CKSchema.typeFriendship,
                                  recordID: CKRecord.ID(recordName: CKSchema.friendshipRecordName, zoneID: zoneID))
        friendship["createdAt"] = Date()
        let profile = CKRecord(recordType: CKSchema.typeProfile,
                               recordID: CKRecord.ID(recordName: CKSchema.profileRecordPrefix + myID, zoneID: zoneID))
        profile["name"] = displayName
        _ = try await privateDB.modifyRecords(saving: [friendship, profile], deleting: [],
                                              savePolicy: .allKeys, atomically: true)

        guard let url = savedShare.url?.absoluteString else {
            throw SyncError(.internalFailure, "iCloud hat keine Einladungs-Adresse geliefert.")
        }
        return url
    }

    func acceptShare(urlString: String, displayName: String) async throws {
        let myID = try await requireAccount()
        rememberDisplayName(displayName)
        guard let url = URL(string: urlString) else {
            throw SyncError(.notFound, "Dieser Einladungslink ist unvollständig.")
        }
        let metadata = try await shareMetadata(for: url)
        try await accept(metadata: metadata)
        try await writeOwnProfileIfFriendshipZone(metadata: metadata, displayName: displayName, myID: myID)
    }

    func setDisplayName(_ name: String) async throws {
        let myID = try await requireAccount()
        rememberDisplayName(name)

        for isMine in [true, false] {
            let database = isMine ? privateDB : sharedDB
            let records = try await database.allRecordZones()
                .filter { $0.zoneID.zoneName.hasPrefix(CKSchema.friendZonePrefix) }
                .map { zone -> CKRecord in
                    let record = CKRecord(recordType: CKSchema.typeProfile,
                                          recordID: CKRecord.ID(recordName: CKSchema.profileRecordPrefix + myID,
                                                                zoneID: zone.zoneID))
                    record["name"] = name
                    return record
                }
            guard !records.isEmpty else { continue }
            // Zonenübergreifend, deshalb nicht atomar: ein toter Freund darf die anderen nicht blockieren.
            _ = try await database.modifyRecords(saving: records, deleting: [],
                                                 savePolicy: .allKeys, atomically: false)
        }
    }

    // MARK: - Spots

    func createSpotShare(id: String, name: String, emoji: String,
                         lng: Double, lat: Double, createdAt: Double) async throws -> (zoneName: String, shareURL: String) {
        try await requireAccount()

        let zoneName = CKSchema.spotZonePrefix + id
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        _ = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])

        // Idempotent: ein zweiter Aufruf für denselben Spot darf den bestehenden Share nicht ersetzen,
        // sonst laufen bereits verteilte Links ins Leere.
        let share: CKShare
        if let existing = await fetchZoneShare(zoneID, from: privateDB) {
            share = existing
        } else {
            let fresh = CKShare(recordZoneID: zoneID)
            fresh.publicPermission = .readWrite
            share = try await save(share: fresh, in: privateDB)
        }

        let spot = CKRecord(recordType: CKSchema.typeSpot,
                            recordID: CKRecord.ID(recordName: CKSchema.spotRecordName, zoneID: zoneID))
        spot["name"] = name
        spot["emoji"] = emoji
        spot["lng"] = lng
        spot["lat"] = lat
        spot["createdAt"] = Date(millisSince1970: createdAt)
        _ = try await privateDB.modifyRecords(saving: [spot], deleting: [], savePolicy: .allKeys, atomically: true)

        guard let url = share.url?.absoluteString else {
            throw SyncError(.internalFailure, "iCloud hat keine Freigabe-Adresse geliefert.")
        }
        return (zoneName, url)
    }

    func offerSpotToFriends(zoneName: String, shareURL: String, spotName: String,
                            spotEmoji: String, friendshipZones: [String]) async throws {
        try await requireAccount()
        let index = try await zoneIndex()

        var byDatabase: [Bool: [CKRecord]] = [:]
        for friendshipZone in friendshipZones {
            guard let located = index[friendshipZone] else {
                throw SyncError(.notFound, "Diese Freundschaft liegt nicht mehr in iCloud.")
            }
            // recordName trägt die Ziel-Zone: der Empfänger erkennt ohne Netz-Roundtrip,
            // ob er den Share schon angenommen hat.
            let record = CKRecord(recordType: CKSchema.typeSpotOffer,
                                  recordID: CKRecord.ID(recordName: CKSchema.offerRecordPrefix + zoneName,
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
    }

    /// Owner: Zone löschen. Teilnehmer: Zone aus der shared DB entfernen = Teilnahme beenden.
    func deleteSpot(zoneName: String) async throws {
        try await requireAccount()
        guard let located = try await zoneIndex()[zoneName] else {
            throw SyncError(.notFound, "Diesen Spot gibt es in iCloud nicht mehr.")
        }
        _ = try await (located.isMine ? privateDB : sharedDB)
            .modifyRecordZones(saving: [], deleting: [located.zoneID])
    }

    // MARK: - Einladungen & Antworten

    func saveInvitation(spotZone: String, id: String, time: Double,
                        createdAt: Double, cancelled: Bool) async throws {
        try await requireAccount()
        guard let located = try await zoneIndex()[spotZone] else {
            throw SyncError(.notFound, "Dieser Spot liegt nicht mehr in iCloud.")
        }
        // hostId kommt aus creatorUserRecordID (Systemfeld) — kein eigenes Feld, nicht fälschbar.
        let record = CKRecord(recordType: CKSchema.typeInvitation,
                              recordID: CKRecord.ID(recordName: id, zoneID: located.zoneID))
        record["time"] = Date(millisSince1970: time)
        record["createdAt"] = Date(millisSince1970: createdAt)
        record["cancelled"] = cancelled ? 1 : 0
        _ = try await (located.isMine ? privateDB : sharedDB)
            .modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
    }

    func saveReply(spotZone: String, invitationId: String, status: String, arrivalTime: Double?) async throws {
        let myID = try await requireAccount()
        guard let located = try await zoneIndex()[spotZone] else {
            throw SyncError(.notFound, "Dieser Spot liegt nicht mehr in iCloud.")
        }
        let recordName = CKSchema.replyRecordPrefix + invitationId + "-" + myID
        let record = CKRecord(recordType: CKSchema.typeReply,
                              recordID: CKRecord.ID(recordName: recordName, zoneID: located.zoneID))
        record["invitationId"] = invitationId
        record["status"] = status
        if let arrivalTime = arrivalTime {
            record["arrivalTime"] = Date(millisSince1970: arrivalTime)
        }
        // .allKeys räumt eine zuvor gesetzte arrivalTime mit ab, wenn jetzt keine mehr genannt wird.
        _ = try await (located.isMine ? privateDB : sharedDB)
            .modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
    }

    // MARK: - Subscriptions & Push

    func registerSubscriptions() async throws {
        try await requireAccount()
        try await ensureDatabaseSubscription(id: CKSchema.privateSubscriptionID, in: privateDB)
        try await ensureDatabaseSubscription(id: CKSchema.sharedSubscriptionID, in: sharedDB)
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func ensureDatabaseSubscription(id: String, in database: CKDatabase) async throws {
        // Idempotent: eine doppelt angelegte Subscription-ID weist der Server ab.
        let existing = try await database.allSubscriptions()
        guard !existing.contains(where: { $0.subscriptionID == id }) else { return }

        let subscription = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        // Silent: die sichtbare Meldung baut der Client nach dem Fetch, mit korrektem Text.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
    }

    /// Silent-Push aus einer CKDatabaseSubscription → Refetch anstoßen.
    @discardableResult
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.notificationType == .database else {
            NSLog("[GreenZones] remote notification ignored (kein CKDatabaseNotification)")
            return false
        }
        NSLog("[GreenZones] cloudChanged via push (subscription: \(notification.subscriptionID ?? "-"))")
        postCloudChanged()
        return true
    }

    /// Share-Accept von außen (Universal Link). Die Annahme muss die App selbst ausführen.
    func handleAcceptedShare(_ metadata: CKShare.Metadata) {
        Task {
            do {
                try await self.accept(metadata: metadata)
                let myID = try await self.container.userRecordID().recordName
                let displayName = self.storedDisplayName()
                if !displayName.isEmpty {
                    try await self.writeOwnProfileIfFriendshipZone(metadata: metadata,
                                                                  displayName: displayName,
                                                                  myID: myID)
                }
            } catch {
                NSLog("[GreenZones] Share-Accept fehlgeschlagen: \(error.localizedDescription)")
            }
            self.postCloudChanged()
        }
    }

    func postCloudChanged() {
        NotificationCenter.default.post(name: Self.cloudChangedNotification, object: nil)
    }

    // MARK: - Zonen-Hilfen

    private struct ZoneEntry {
        let zone: CKRecordZone
        let isMine: Bool
    }

    private struct LocatedZone {
        let zoneID: CKRecordZone.ID
        let isMine: Bool
    }

    private func database(for entry: ZoneEntry) -> CKDatabase {
        entry.isMine ? privateDB : sharedDB
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

    /// Vollabzug einer Zone. `since: nil` liefert alle Records; der zurückgegebene Token wird
    /// nur innerhalb dieses Aufrufs zum Weiterblättern gebraucht, nie gespeichert.
    private func fetchAllRecords(in zoneID: CKRecordZone.ID, from database: CKDatabase) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        while true {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (_, modification) in result.modificationResultsByID {
                if case .success(let change) = modification {
                    records.append(change.record)
                }
            }
            token = result.changeToken
            if !result.moreComing { break }
        }
        return records
    }

    private func fetchZoneShare(_ zoneID: CKRecordZone.ID, from database: CKDatabase) async -> CKShare? {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        return try? await database.record(for: shareID) as? CKShare
    }

    private func save(share: CKShare, in database: CKDatabase) async throws -> CKShare {
        let result = try await database.modifyRecords(saving: [share], deleting: [],
                                                      savePolicy: .allKeys, atomically: true)
        guard let saveResult = result.saveResults[share.recordID] else {
            throw SyncError(.internalFailure, "iCloud hat die Freigabe nicht bestätigt.")
        }
        switch saveResult {
        case .success(let record):
            guard let saved = record as? CKShare else {
                throw SyncError(.internalFailure, "iCloud hat die Freigabe nicht bestätigt.")
            }
            return saved
        case .failure(let error):
            throw error
        }
    }

    // MARK: - Share-Annahme

    private func shareMetadata(for url: URL) async throws -> CKShare.Metadata {
        let results = try await container.shareMetadatas(for: [url])
        guard let result = results[url] ?? results.values.first else {
            throw SyncError(.notFound, "Zu diesem Link gibt es keine Einladung mehr.")
        }
        switch result {
        case .success(let metadata):
            return metadata
        case .failure(let error):
            throw error
        }
    }

    /// Idempotent: ein bereits angenommener Share ist Erfolg, kein Fehler — der Auto-Accept
    /// aus `fetchSnapshot` läuft bei jedem Durchgang erneut über dieselben SpotOffers.
    private func accept(metadata: CKShare.Metadata) async throws {
        guard metadata.participantStatus != .accepted else { return }
        let results = try await container.accept([metadata])
        guard let result = results[metadata] ?? results.values.first else { return }
        if case .failure(let error) = result {
            if let ckError = error as? CKError, ckError.code == .alreadyShared { return }
            throw error
        }
    }

    private func writeOwnProfileIfFriendshipZone(metadata: CKShare.Metadata,
                                                 displayName: String,
                                                 myID: String) async throws {
        let zoneID = metadata.share.recordID.zoneID
        guard zoneID.zoneName.hasPrefix(CKSchema.friendZonePrefix) else { return }
        // Jeder pflegt genau seinen Profile-Record — der recordName trägt den Schreiber.
        let profile = CKRecord(recordType: CKSchema.typeProfile,
                               recordID: CKRecord.ID(recordName: CKSchema.profileRecordPrefix + myID, zoneID: zoneID))
        profile["name"] = displayName
        _ = try await sharedDB.modifyRecords(saving: [profile], deleting: [],
                                             savePolicy: .allKeys, atomically: true)
    }

    /// SpotOffer = Transportkanal für Spot-Shares an bestehende Freunde. Ein Offer, dessen Ziel-Zone
    /// schon lokal bekannt ist, ist erledigt. Fehler beim Annehmen dürfen den Snapshot nicht kippen.
    private func acceptPendingOffers(friendRecords: [[CKRecord]], knownZones: [CKRecordZone]) async throws -> Bool {
        var known = Set(knownZones.map { $0.zoneID.zoneName })
        var acceptedAny = false

        for records in friendRecords {
            for record in records where record.recordType == CKSchema.typeSpotOffer {
                let name = record.recordID.recordName
                guard name.hasPrefix(CKSchema.offerRecordPrefix) else { continue }
                let targetZone = String(name.dropFirst(CKSchema.offerRecordPrefix.count))
                guard !known.contains(targetZone) else { continue }
                guard let urlString = record["spotShareURL"] as? String,
                      let url = URL(string: urlString) else { continue }
                do {
                    let metadata = try await shareMetadata(for: url)
                    try await accept(metadata: metadata)
                    known.insert(targetZone)
                    acceptedAny = true
                } catch {
                    NSLog("[GreenZones] SpotOffer \(targetZone) nicht angenommen: \(error.localizedDescription)")
                }
            }
        }
        return acceptedAny
    }

    // MARK: - Snapshot-Bausteine

    private func buildFriend(entry: ZoneEntry, records: [CKRecord], myID: String) async -> [String: Any]? {
        let friendID: String
        if entry.isMine {
            // Freund-Identität steht im Share; solange niemand beigetreten ist, gibt es keinen Freund.
            let share = await fetchZoneShare(entry.zone.zoneID, from: privateDB)
            guard let joined = share?.participants
                .filter({ $0.acceptanceStatus == .accepted })
                .compactMap({ $0.userIdentity.userRecordID?.recordName })
                .first(where: { $0 != myID && $0 != CKCurrentUserDefaultName }) else {
                return nil
            }
            friendID = joined
        } else {
            friendID = entry.zone.zoneID.ownerName
        }
        guard !friendID.isEmpty, friendID != CKCurrentUserDefaultName else { return nil }

        let profile = records.first { record in
            guard record.recordType == CKSchema.typeProfile else { return false }
            return Self.normalizedUser(record.creatorUserRecordID, myID: myID) == friendID
                || record.recordID.recordName == CKSchema.profileRecordPrefix + friendID
        }

        return [
            "userID": friendID,
            "name": profile?["name"] as? String ?? "",
            "friendshipZone": entry.zone.zoneID.zoneName,
            "isOwner": entry.isMine
        ]
    }

    private static func spotDict(entry: ZoneEntry, record: CKRecord, share: CKShare?, myID: String) -> [String: Any] {
        let participants = (share?.participants ?? [])
            .filter { $0.acceptanceStatus == .accepted }
            .compactMap { $0.userIdentity.userRecordID?.recordName }
            .filter { $0 != myID && $0 != CKCurrentUserDefaultName }

        return [
            "zoneName": entry.zone.zoneID.zoneName,
            "ownerUserID": entry.isMine ? "" : entry.zone.zoneID.ownerName,
            "isMine": entry.isMine,
            "name": record["name"] as? String ?? "",
            "emoji": record["emoji"] as? String ?? "",
            "lng": record["lng"] as? Double ?? 0,
            "lat": record["lat"] as? Double ?? 0,
            "createdAt": (record["createdAt"] as? Date)?.millisSince1970 ?? 0,
            "participantUserIDs": participants,
            "shareURL": entry.isMine ? (share?.url?.absoluteString ?? "") : ""
        ]
    }

    private static func invitationDicts(entry: ZoneEntry, records: [CKRecord], myID: String) -> [[String: Any]] {
        var repliesByInvitation: [String: [[String: Any]]] = [:]
        for record in records where record.recordType == CKSchema.typeReply {
            guard let invitationId = record["invitationId"] as? String else { continue }
            var reply: [String: Any] = [
                "participantUserID": normalizedUser(record.creatorUserRecordID, myID: myID),
                "status": record["status"] as? String ?? "out"
            ]
            if let arrival = record["arrivalTime"] as? Date {
                reply["arrivalTime"] = arrival.millisSince1970
            }
            repliesByInvitation[invitationId, default: []].append(reply)
        }

        return records.filter { $0.recordType == CKSchema.typeInvitation }.map { record in
            let id = record.recordID.recordName
            return [
                "id": id,
                "spotZone": entry.zone.zoneID.zoneName,
                "hostUserID": normalizedUser(record.creatorUserRecordID, myID: myID),
                "time": (record["time"] as? Date)?.millisSince1970 ?? 0,
                "createdAt": (record["createdAt"] as? Date)?.millisSince1970 ?? 0,
                "cancelled": ((record["cancelled"] as? Int) ?? 0) != 0,
                "replies": repliesByInvitation[id] ?? []
            ]
        }
    }

    /// In der eigenen privaten DB steht `__defaultOwner__` statt der echten ID — für den JS-Layer
    /// muss beides dieselbe Person sein.
    private static func normalizedUser(_ recordID: CKRecord.ID?, myID: String) -> String {
        guard let name = recordID?.recordName, name != CKCurrentUserDefaultName else { return myID }
        return name
    }

    // MARK: - Anzeigename

    private func rememberDisplayName(_ name: String) {
        guard !name.isEmpty else { return }
        UserDefaults.standard.set(name, forKey: CKSchema.displayNameDefaultsKey)
    }

    private func storedDisplayName() -> String {
        UserDefaults.standard.string(forKey: CKSchema.displayNameDefaultsKey) ?? ""
    }
}
