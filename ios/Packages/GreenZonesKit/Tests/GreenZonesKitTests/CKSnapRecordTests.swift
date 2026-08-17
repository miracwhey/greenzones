import CloudKit
import Foundation
import Testing
@testable import GreenZonesKit

/// Der Vollabzug holt Records ueber eine Positivliste (`desiredKeys`). Eine
/// Positivliste, die ein geschriebenes Feld nicht kennt, verliert es **still**:
/// kein Fehler, kein Log, das Feld ist beim Empfaenger einfach leer. Diese Suite
/// haelt Schreiber und Liste zusammen.
@Suite("Snap-Record — geschriebene Felder und Positivliste")
struct CKSnapRecordTests {
    private let zoneID = CKRecordZone.ID(zoneName: "feed-me", ownerName: CKCurrentUserDefaultName)
    private let spotZoneID = CKRecordZone.ID(zoneName: "spot-s1", ownerName: "u2")

    private func snap(scope: SnapScope) -> Snap {
        Snap(id: "snap-1", authorId: SELF_ID,
             createdAt: Date(timeIntervalSince1970: 1_700_000_000),
             lat: 52.36, lng: 9.74,
             spotId: "s1", spotZone: "spot-s1", spotName: "Unsere Bank", spotEmoji: "🪑",
             scope: scope)
    }

    private func urls() -> (original: URL, thumb: URL) {
        let dir = FileManager.default.temporaryDirectory
        return (dir.appendingPathComponent("o.jpg"), dir.appendingPathComponent("t.jpg"))
    }

    @Test("Jedes geschriebene Feld steht in der Positivliste — ausser den Bildern")
    func writtenFieldsAreInTheAllowList() {
        let (original, thumb) = urls()
        let record = CKSnapRecord.make(snap(scope: .feed), zoneID: zoneID,
                                       original: original, thumb: thumb)
        let assets = Set(CKSchema.Field.snapAssets)
        let allowed = Set(CKSchema.Field.lightweight)
        let missing = record.allKeys().filter { !assets.contains($0) && !allowed.contains($0) }
        #expect(missing.isEmpty, "nicht in der Liste, wird beim Abzug still verschwinden: \(missing)")
    }

    @Test("Die Bilder stehen NICHT in der Positivliste")
    func assetsAreExcluded() {
        // Sonst zoege jeder Vollabzug saemtliche Fotos aller Freunde herunter.
        for key in CKSchema.Field.snapAssets {
            #expect(!CKSchema.Field.lightweight.contains(key))
        }
    }

    @Test("Der Spot-Snap traegt den Ort nicht doppelt")
    func spotScopedSnapOmitsSpotFields() {
        let (original, thumb) = urls()
        let record = CKSnapRecord.make(snap(scope: .spot), zoneID: spotZoneID,
                                       original: original, thumb: thumb)
        // In der Spot-Zone IST die Zone der Spot; ein zweites Namensfeld koennte
        // ihr widersprechen.
        #expect(record["spotZone"] == nil)
        #expect(record["spotName"] == nil)
        #expect(record["thumb"] != nil)
    }

    @Test("Gelesen wird, was geschrieben wurde")
    func roundTripKeepsTheFacts() {
        let (original, thumb) = urls()
        let source = snap(scope: .feed)
        let record = CKSnapRecord.make(source, zoneID: zoneID, original: original, thumb: thumb)
        let parsed = try! #require(CKSnapRecord.parse(record, myID: "me"))

        #expect(parsed.id == source.id)
        #expect(parsed.zoneName == "feed-me")
        #expect(parsed.lat == source.lat)
        #expect(parsed.lng == source.lng)
        #expect(parsed.createdAt == source.createdAt)
        #expect(parsed.spotZone == "spot-s1")
        #expect(parsed.inSpotZone == false)
        // Ein Record ohne creatorUserRecordID ist meiner — so liest CloudKit die
        // eigene private Datenbank.
        #expect(parsed.authorUserID == "me")
    }

    @Test("Ein Snap in einer Spot-Zone gilt als Spot-Snap, egal was im Feld steht")
    func zoneDecidesTheScope() {
        let record = CKRecord(recordType: CKSchema.typeSnap,
                              recordID: CKRecord.ID(recordName: "x", zoneID: spotZoneID))
        record["lat"] = 52.36
        record["lng"] = 9.74
        record["spotZone"] = "spot-etwas-anderes"
        let parsed = try! #require(CKSnapRecord.parse(record, myID: "me"))
        #expect(parsed.inSpotZone)
        #expect(parsed.spotZone == "spot-s1", "die Zone gewinnt gegen das Feld")
    }

    @Test("Ohne Position ist es kein brauchbarer Snap")
    func snapWithoutCoordinateIsRejected() {
        let record = CKRecord(recordType: CKSchema.typeSnap,
                              recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        record["createdAt"] = Date()
        #expect(CKSnapRecord.parse(record, myID: "me") == nil)
    }

    @Test("Andere Record-Typen werden nicht als Snap gelesen")
    func otherTypesAreIgnored() {
        let record = CKRecord(recordType: CKSchema.typeSpot,
                              recordID: CKRecord.ID(recordName: "spot", zoneID: spotZoneID))
        record["lat"] = 52.36
        record["lng"] = 9.74
        #expect(CKSnapRecord.parse(record, myID: "me") == nil)
    }
}
