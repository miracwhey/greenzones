import CloudKit
import Foundation

/// Uebersetzung zwischen `Snap` und `CKRecord` — als reine Funktionen, damit
/// beide Richtungen ohne Netz pruefbar sind.
///
/// Der Bau steht hier und nicht im Gateway, weil die geschriebenen Feldnamen
/// dieselbe Quelle haben muessen wie die Positivliste des Vollabzugs
/// (`CKSchema.Field`). Sonst schreibt der eine ein Feld, das der andere nie
/// liest — und niemand merkt es, weil nichts scheitert.
public enum CKSnapRecord {
    public static func make(_ snap: Snap, zoneID: CKRecordZone.ID,
                            original: URL, thumb: URL) -> CKRecord {
        let record = CKRecord(recordType: CKSchema.typeSnap,
                              recordID: CKRecord.ID(recordName: snap.id, zoneID: zoneID))
        record["createdAt"] = snap.createdAt
        record["lat"] = snap.lat
        record["lng"] = snap.lng
        record["thumb"] = CKAsset(fileURL: thumb)
        record["photo"] = CKAsset(fileURL: original)
        // Nur der Feed-Snap traegt den Ort als Feld: in der Spot-Zone IST die
        // Zone der Spot, ein zweites Namensfeld koennte ihr widersprechen.
        if snap.scope == .feed {
            record["spotZone"] = snap.spotZone
            record["spotName"] = snap.spotName
            record["spotEmoji"] = snap.spotEmoji
        }
        return record
    }

    /// Aus einem Record des Vollabzugs (ohne Bilder) den Contract-Typ.
    /// `nil` = kein Snap oder unbrauchbar (fehlende Position).
    public static func parse(_ record: CKRecord, myID: String) -> CloudSnap? {
        guard record.recordType == CKSchema.typeSnap,
              let lat = record["lat"] as? Double,
              let lng = record["lng"] as? Double else { return nil }
        let zoneName = record.recordID.zoneID.zoneName
        let inSpotZone = zoneName.hasPrefix(CKSchema.spotZonePrefix)
        return CloudSnap(id: record.recordID.recordName,
                         zoneName: zoneName,
                         authorUserID: author(of: record, myID: myID),
                         createdAt: record["createdAt"] as? Date
                            ?? record.creationDate
                            ?? Date(timeIntervalSince1970: 0),
                         lat: lat, lng: lng,
                         spotZone: inSpotZone ? zoneName : record["spotZone"] as? String,
                         spotName: record["spotName"] as? String,
                         spotEmoji: record["spotEmoji"] as? String,
                         inSpotZone: inSpotZone)
    }

    /// In der eigenen privaten DB steht `__defaultOwner__` statt der echten Id.
    private static func author(of record: CKRecord, myID: String) -> String {
        guard let name = record.creatorUserRecordID?.recordName,
              name != CKCurrentUserDefaultName else { return myID }
        return name
    }
}
