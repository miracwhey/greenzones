import UserNotifications
import CloudKit

/// Betextet den sichtbaren CloudKit-Push (`mutable-content`) mit dem konkreten Ereignis.
///
/// Eine CKDatabaseNotification sagt nur „in dieser Datenbank hat sich etwas geändert" —
/// welche Records, steht nicht im Push. Die Extension zieht deshalb die gz-Zonen der
/// betroffenen Datenbank komplett (Datenmengen sind eine Handvoll Records, wie in der App)
/// und wertet als Ereignis, was FRISCH ist und von JEMAND ANDEREM kommt. Change-Tokens
/// werden bewusst nicht geführt: der Push kommt Sekunden nach der Änderung, ein
/// Zeitfenster reicht und erspart der Extension jeden persistenten Zustand.
///
/// Scheitert irgendetwas (kein Netz, Timeout, kein Account), bleibt der neutrale
/// alertBody aus der Subscription stehen — nie ein stummes Verschlucken.
class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
              let note = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo)
                as? CKDatabaseNotification else {
            contentHandler(request.content)
            return
        }
        self.content = content
        NSLog("[GreenZones-NSE] Push empfangen (scope \(note.databaseScope.rawValue))")
        Task {
            await EventComposer(scope: note.databaseScope).compose(into: content)
            NSLog("[GreenZones-NSE] Text: \(content.title.isEmpty ? "Fallback" : content.title) — \(content.body)")
            contentHandler(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let content = content {
            contentHandler(content)
        }
    }
}

// MARK: - Ereignis-Findung

private let containerID = "iCloud.de.leonvalentin.greenzones"
private let friendZonePrefix = "friend-"
private let spotZonePrefix = "spot-"
private let profileRecordPrefix = "profile-"
private let spotRecordName = "spot"

/// Änderungen älter als das gelten nicht mehr als Anlass dieses Pushes.
private let freshWindow: TimeInterval = 30 * 60
/// Record jünger als das = neu angelegt, nicht bearbeitet.
private let creationSlack: TimeInterval = 180

private struct FoundRecord {
    let record: CKRecord
    let zoneID: CKRecordZone.ID
}

private struct EventComposer {
    let scope: CKDatabase.Scope
    private let container = CKContainer(identifier: containerID)

    /// Ereignis-Rangfolge: was den Empfänger direkt betrifft, schlägt Verwaltung.
    private enum Kind: Int {
        case invitation = 0, spotOffer = 1, reply = 2, profile = 3
    }

    func compose(into content: UNMutableNotificationContent) async {
        guard scope == .private || scope == .shared else { return }
        guard let myID = try? await container.userRecordID().recordName else { return }
        let database = container.database(with: scope)

        guard let zones = try? await database.allRecordZones() else { return }
        var all: [FoundRecord] = []
        for zone in zones {
            let name = zone.zoneID.zoneName
            guard name.hasPrefix(friendZonePrefix) || name.hasPrefix(spotZonePrefix) else { continue }
            guard let records = try? await fetchAllRecords(in: zone.zoneID, from: database) else { continue }
            all.append(contentsOf: records.map { FoundRecord(record: $0, zoneID: zone.zoneID) })
        }

        let now = Date()
        let fresh = all.filter { found in
            guard let modified = found.record.modificationDate,
                  now.timeIntervalSince(modified) < freshWindow else { return false }
            return !isMe(found.record.lastModifiedUserRecordID, myID: myID)
        }

        let event = fresh
            .compactMap { found -> (Kind, FoundRecord)? in
                switch found.record.recordType {
                case "Invitation": return (.invitation, found)
                case "SpotOffer": return (.spotOffer, found)
                case "Reply": return (.reply, found)
                case "Profile": return (.profile, found)
                default: return nil
                }
            }
            .sorted { a, b in
                a.0.rawValue != b.0.rawValue
                    ? a.0.rawValue < b.0.rawValue
                    : (a.1.record.modificationDate ?? .distantPast) > (b.1.record.modificationDate ?? .distantPast)
            }
            .first

        guard let (kind, found) = event else {
            // Nichts Banner-würdiges (z. B. Spot-Detail geändert): still in die Mitteilungsliste.
            if #available(iOS 15.0, *) { content.interruptionLevel = .passive }
            return
        }

        let names = NameResolver(container: container, myID: myID)
        let spot = all.first {
            $0.zoneID == found.zoneID && $0.record.recordID.recordName == spotRecordName
        }?.record

        switch kind {
        case .invitation:
            await composeInvitation(found, spot: spot, names: names, into: content)
        case .spotOffer:
            await composeSpotOffer(found, names: names, into: content)
        case .reply:
            await composeReply(found, spot: spot, names: names, into: content)
        case .profile:
            composeProfile(found, into: content)
        }
        content.threadIdentifier = found.zoneID.zoneName
        content.sound = .default
    }

    private func composeInvitation(_ found: FoundRecord, spot: CKRecord?,
                                   names: NameResolver, into content: UNMutableNotificationContent) async {
        let record = found.record
        content.title = spotTitle(spot) ?? "Einladung"
        let host = await names.displayName(for: record.creatorUserRecordID)
        let cancelled = ((record["cancelled"] as? Int) ?? 0) != 0
        if cancelled {
            content.body = host.map { "\($0) hat abgesagt" } ?? "Die Einladung wurde abgesagt"
            return
        }
        let time = (record["time"] as? Date).map(timeText)
        let isNew = record.modificationDate.flatMap { modified in
            record.creationDate.map { modified.timeIntervalSince($0) < creationSlack }
        } ?? true
        switch (isNew, host, time) {
        case (true, .some(let host), .some(let time)): content.body = "\(host) lädt ein — \(time)"
        case (true, .some(let host), nil): content.body = "\(host) lädt ein"
        case (true, nil, .some(let time)): content.body = "Einladung — \(time)"
        case (true, nil, nil): content.body = "Du bist eingeladen"
        case (false, let host, .some(let time)): content.body = "\(host.map { "\($0): n" } ?? "N")eue Zeit — \(time)"
        case (false, let host, nil): content.body = "\(host.map { "\($0) hat d" } ?? "D")ie Einladung geändert"
        }
    }

    private func composeSpotOffer(_ found: FoundRecord, names: NameResolver,
                                  into content: UNMutableNotificationContent) async {
        let record = found.record
        content.title = title(emoji: record["spotEmoji"] as? String,
                              name: record["spotName"] as? String) ?? "Neuer Spot"
        let sender = await names.displayName(for: record.creatorUserRecordID)
        content.body = sender.map { "\($0) teilt einen Spot mit dir" } ?? "Ein Freund teilt einen Spot mit dir"
    }

    private func composeReply(_ found: FoundRecord, spot: CKRecord?,
                              names: NameResolver, into content: UNMutableNotificationContent) async {
        let record = found.record
        content.title = spotTitle(spot) ?? "Antwort"
        let who = await names.displayName(for: record.creatorUserRecordID) ?? "Jemand"
        if (record["status"] as? String) == "in" {
            if let arrival = record["arrivalTime"] as? Date {
                content.body = "\(who) kommt um \(timeText(arrival))"
            } else {
                content.body = "\(who) ist dabei"
            }
        } else {
            content.body = "\(who) kann nicht"
        }
    }

    private func composeProfile(_ found: FoundRecord, into content: UNMutableNotificationContent) {
        let record = found.record
        let isNew = record.modificationDate.flatMap { modified in
            record.creationDate.map { modified.timeIntervalSince($0) < creationSlack }
        } ?? false
        guard isNew, let name = record["name"] as? String, !name.isEmpty else {
            if #available(iOS 15.0, *) { content.interruptionLevel = .passive }
            return
        }
        content.title = "Neuer Freund"
        let emoji = (record["emoji"] as? String) ?? ""
        content.body = emoji.isEmpty
            ? "\(name) ist deiner Einladung gefolgt"
            : "\(emoji) \(name) ist deiner Einladung gefolgt"
    }

    // MARK: Bausteine

    private func spotTitle(_ spot: CKRecord?) -> String? {
        title(emoji: spot?["emoji"] as? String, name: spot?["name"] as? String)
    }

    private func title(emoji: String?, name: String?) -> String? {
        let parts = [emoji, name].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return "heute \(formatter.string(from: date))"
        }
        if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "HH:mm"
            return "morgen \(formatter.string(from: date))"
        }
        formatter.dateFormat = "EE HH:mm"
        return formatter.string(from: date)
    }

    private func isMe(_ recordID: CKRecord.ID?, myID: String) -> Bool {
        // nil = Herkunft unbekannt → kein Banner auf Verdacht.
        guard let name = recordID?.recordName else { return true }
        return name == myID || name == CKCurrentUserDefaultName
    }

    private func fetchAllRecords(in zoneID: CKRecordZone.ID,
                                 from database: CKDatabase) async throws -> [CKRecord] {
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
}

/// Löst eine userRecordID über die Profile-Records der Freundschafts-Zonen auf.
/// Profile liegen je nach Richtung der Freundschaft in der privaten ODER der geteilten
/// Datenbank — gesucht wird deshalb in beiden, gezielt per Record-ID statt Vollabzug.
private final class NameResolver {
    private let container: CKContainer
    private let myID: String
    private var cache: [String: String?] = [:]
    private var friendZones: [(CKRecordZone.ID, CKDatabase)]?

    init(container: CKContainer, myID: String) {
        self.container = container
        self.myID = myID
    }

    func displayName(for recordID: CKRecord.ID?) async -> String? {
        guard let name = recordID?.recordName, name != myID, name != CKCurrentUserDefaultName else {
            return nil
        }
        if let cached = cache[name] { return cached }
        let resolved = await resolve(name)
        cache[name] = resolved
        return resolved
    }

    private func resolve(_ userID: String) async -> String? {
        for (zoneID, database) in await zones() {
            let recordID = CKRecord.ID(recordName: profileRecordPrefix + userID, zoneID: zoneID)
            if let profile = try? await database.record(for: recordID),
               let name = profile["name"] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private func zones() async -> [(CKRecordZone.ID, CKDatabase)] {
        if let friendZones = friendZones { return friendZones }
        var found: [(CKRecordZone.ID, CKDatabase)] = []
        for database in [container.privateCloudDatabase, container.sharedCloudDatabase] {
            let zones = (try? await database.allRecordZones()) ?? []
            for zone in zones where zone.zoneID.zoneName.hasPrefix(friendZonePrefix) {
                found.append((zone.zoneID, database))
            }
        }
        friendZones = found
        return found
    }
}
