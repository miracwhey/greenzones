import CloudKit
import Foundation

/// Vollabzug einer Zone — geteilt zwischen App und Notification-Extension.
///
/// Beide brauchen dieselbe Leseart (SPEC 11: „Konstanten und `fetchAllRecords`
/// aus `GreenZonesKit`, kein Duplikat mehr"). Ein zweites, eigenes Exemplar in
/// der Extension driftet unbemerkt ab: sie laeuft nur bei Push, und ihr Fehler
/// sieht aus wie ein fehlender Push.
public enum CKZoneReader {
    /// `since: nil` liefert alle Records; der zurueckgegebene Token wird nur
    /// innerhalb dieses Aufrufs zum Weiterblaettern gebraucht, nie gespeichert.
    public static func fetchAllRecords(in zoneID: CKRecordZone.ID,
                                       from database: CKDatabase) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        while true {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (_, modification) in result.modificationResultsByID {
                if case .success(let change) = modification { records.append(change.record) }
            }
            token = result.changeToken
            if !result.moreComing { break }
        }
        return records
    }

    /// Zonen dieser App — alles andere im Container geht uns nichts an.
    public static func isGreenZonesZone(_ zoneName: String) -> Bool {
        zoneName.hasPrefix(CKSchema.friendZonePrefix)
            || zoneName.hasPrefix(CKSchema.spotZonePrefix)
            || zoneName.hasPrefix(CKSchema.feedZonePrefix)
    }
}
