import CloudKit
import GreenZonesKit
import UserNotifications
import os

/// Betextet den sichtbaren CloudKit-Push (`mutable-content`) mit dem konkreten
/// Ereignis. Port von `client/ios/App/NotificationService/NotificationService.swift`,
/// erweitert um Snaps und die Feed-Zone (SPEC 7/11).
///
/// Eine `CKDatabaseNotification` sagt nur „in dieser Datenbank hat sich etwas
/// geaendert" — welche Records, steht nicht im Push. Die Extension zieht deshalb
/// die gz-Zonen der betroffenen Datenbank komplett und wertet als Ereignis, was
/// FRISCH ist und von JEMAND ANDEREM kommt. Change-Tokens werden bewusst nicht
/// gefuehrt: der Push kommt Sekunden nach der Aenderung, ein Zeitfenster reicht
/// und erspart der Extension jeden persistenten Zustand.
///
/// Scheitert irgendetwas (kein Netz, Timeout, kein Account), bleibt der neutrale
/// alertBody aus der Subscription stehen — nie ein stummes Verschlucken.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    /// Ohne diese Spur ist ein ausbleibendes Banner nicht zu unterscheiden von
    /// „Extension lief nie". Sie ist am Geraet ueber die Konsole lesbar.
    private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "nse")

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
        logger.info("Push empfangen (scope \(note.databaseScope.rawValue, privacy: .public))")
        Task { [logger] in
            await EventComposer(scope: note.databaseScope).compose(into: content)
            logger.info("Text: \(content.title.isEmpty ? "Fallback" : content.title, privacy: .public) — \(content.body, privacy: .public)")
            contentHandler(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Zeit ist um: der bis hier gebaute Inhalt geht raus — im Zweifel der
        // neutrale Text aus der Subscription, nie gar keiner.
        logger.info("Zeit abgelaufen, Zwischenstand geht raus")
        if let contentHandler, let content {
            contentHandler(content)
        }
    }
}

// MARK: - Ereignis-Findung

/// Aenderungen aelter als das gelten nicht mehr als Anlass dieses Pushes.
private let freshWindow: TimeInterval = 30 * 60
/// Record juenger als das = neu angelegt, nicht bearbeitet.
private let creationSlack: TimeInterval = 180

private struct FoundRecord {
    let record: CKRecord
    let zoneID: CKRecordZone.ID
}

private struct EventComposer {
    let scope: CKDatabase.Scope
    private let container = CKContainer(identifier: CKSchema.containerID)

    /// Ereignis-Rangfolge (SPEC 7): was den Empfaenger direkt betrifft, schlaegt
    /// Verwaltung. `FeedOffer`, `Feed` und `Report` stehen bewusst nicht drin —
    /// sie sind Infrastruktur und erzeugen nie ein Banner.
    private enum Kind: Int {
        case invitation = 0, spotOffer = 1, snap = 2, reply = 3, profile = 4
    }

    func compose(into content: UNMutableNotificationContent) async {
        guard scope == .private || scope == .shared else { return }
        guard let myID = try? await container.userRecordID().recordName else { return }
        let database = container.database(with: scope)

        guard let zones = try? await database.allRecordZones() else { return }
        var all: [FoundRecord] = []
        for zone in zones where CKZoneReader.isGreenZonesZone(zone.zoneID.zoneName) {
            guard let records = try? await CKZoneReader.fetchAllRecords(in: zone.zoneID, from: database) else {
                continue
            }
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
                case CKSchema.typeInvitation: return (.invitation, found)
                case CKSchema.typeSpotOffer: return (.spotOffer, found)
                case CKSchema.typeSnap: return (.snap, found)
                case CKSchema.typeReply: return (.reply, found)
                case CKSchema.typeProfile: return (.profile, found)
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
            // Nichts Banner-wuerdiges (z. B. Spot-Detail geaendert, FeedOffer,
            // Report): still in die Mitteilungsliste.
            content.interruptionLevel = .passive
            return
        }

        let names = NameResolver(container: container, myID: myID)
        let spot = all.first {
            $0.zoneID == found.zoneID && $0.record.recordID.recordName == CKSchema.spotRecordName
        }?.record

        switch kind {
        case .invitation:
            await composeInvitation(found, spot: spot, names: names, into: content)
        case .spotOffer:
            await composeSpotOffer(found, names: names, into: content)
        case .snap:
            await composeSnap(found, spot: spot, names: names, into: content)
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

    /// Snap (SPEC 7). Der Ort steht am Snap selbst (`spotName`, wenn er im Feed
    /// liegt) oder an der Spot-Zone, in der er liegt — beides ergibt denselben
    /// Titel, damit derselbe Snap nicht je nach Weg anders heisst.
    private func composeSnap(_ found: FoundRecord, spot: CKRecord?,
                             names: NameResolver, into content: UNMutableNotificationContent) async {
        let record = found.record
        let place = spotTitle(spot) ?? title(emoji: record["spotEmoji"] as? String,
                                             name: record["spotName"] as? String)
        let who = await names.displayName(for: record.creatorUserRecordID) ?? "Jemand"
        if let place {
            content.title = place
            content.body = "\(who) hat einen Snap gemacht"
        } else {
            content.title = "Neuer Snap"
            content.body = "\(who) hat einen Snap gemacht"
        }
    }

    private func composeReply(_ found: FoundRecord, spot: CKRecord?,
                              names: NameResolver, into content: UNMutableNotificationContent) async {
        let record = found.record
        content.title = spotTitle(spot) ?? "Antwort"
        let who = await names.displayName(for: record.creatorUserRecordID) ?? "Jemand"
        if (record["status"] as? String) == ReplyStatus.ind.rawValue {
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
            content.interruptionLevel = .passive
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
}

/// Loest eine userRecordID ueber die Profile-Records der Freundschafts-Zonen
/// auf. Profile liegen je nach Richtung der Freundschaft in der privaten ODER
/// der geteilten Datenbank — gesucht wird deshalb in beiden, gezielt per
/// Record-ID statt Vollabzug.
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
            let recordID = CKRecord.ID(recordName: CKSchema.profileRecordName(userID: userID), zoneID: zoneID)
            if let profile = try? await database.record(for: recordID),
               let name = profile["name"] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private func zones() async -> [(CKRecordZone.ID, CKDatabase)] {
        if let friendZones { return friendZones }
        var found: [(CKRecordZone.ID, CKDatabase)] = []
        for database in [container.privateCloudDatabase, container.sharedCloudDatabase] {
            let zones = (try? await database.allRecordZones()) ?? []
            for zone in zones where zone.zoneID.zoneName.hasPrefix(CKSchema.friendZonePrefix) {
                found.append((zone.zoneID, database))
            }
        }
        friendZones = found
        return found
    }
}
