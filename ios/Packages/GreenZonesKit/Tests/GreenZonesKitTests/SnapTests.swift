import Foundation
import Testing
@testable import GreenZonesKit

private func cloudSnap(_ id: String, zone: String, author: String, minutesAgo: Int = 0,
                       spotZone: String? = nil, inSpotZone: Bool = false) -> CloudSnap {
    CloudSnap(id: id, zoneName: zone, authorUserID: author,
              createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60),
              lat: 52.36, lng: 9.74, spotZone: spotZone, spotName: spotZone == nil ? nil : "Unsere Bank",
              spotEmoji: spotZone == nil ? nil : "🪑", inSpotZone: inSpotZone)
}

private func localSnap(_ id: String, author: String = SELF_ID, spotId: String? = nil,
                       spotZone: String? = nil, scope: SnapScope = .feed,
                       state: SnapUploadState = .done, hidden: Bool = false,
                       minutesAgo: Int = 0) -> Snap {
    Snap(id: id, authorId: author,
         createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60),
         lat: 52.36, lng: 9.74, spotId: spotId, spotZone: spotZone, scope: scope,
         zoneName: state == .done ? "feed-me" : nil,
         thumbPath: "/tmp/\(id)-thumb.jpg", photoPath: "/tmp/\(id).jpg",
         uploadState: state, hidden: hidden)
}

/// Das Album eines Spots ist eine Vereinigung: Snaps, die IN der Spot-Zone
/// liegen, und Feed-Snaps von Freunden, die an diesem Spot aufgenommen wurden
/// (SPEC 7). Die Verbindung laeuft ueber den Zonen-Namen — die lokale Spot-Id
/// kennt ein fremdes Geraet nicht.
@Suite("Snap-Album — Vereinigung ueber die Spot-Zone")
struct AlbumUnionTests {
    private let spot = Spot(id: "s1", name: "Unsere Bank", emoji: "🪑", lng: 9.74, lat: 52.36,
                            createdAt: Date(timeIntervalSince1970: 1_699_000_000),
                            zoneName: "spot-s1")

    @Test("Eigener Spot-Snap und fremder Feed-Snap landen im selben Album")
    func unionCoversBothPaths() {
        let all = [
            localSnap("a", spotId: "s1", scope: .spot, minutesAgo: 10),
            localSnap("b", author: "u2", spotZone: "spot-s1", minutesAgo: 5),
            localSnap("c"),
        ]
        let album = albumSnaps(all, spot: spot)
        #expect(album.map(\.id) == ["b", "a"], "neuester zuerst, freier Snap gehoert nicht dazu")
    }

    @Test("Ausgeblendete Snaps stehen weder im Album noch auf der Karte")
    func hiddenStaysOut() {
        let all = [localSnap("a", spotId: "s1", scope: .spot, hidden: true),
                   localSnap("frei", hidden: true)]
        #expect(albumSnaps(all, spot: spot).isEmpty)
        #expect(freeSnaps(all).isEmpty)
    }

    @Test("Ohne geteilte Zone zaehlt nur die lokale Zuordnung")
    func localOnlySpotUsesItsId() {
        let localSpot = Spot(id: "s2", name: "Bank am Kanal", emoji: "⭐️", lng: 9.7, lat: 52.3,
                             createdAt: Date(timeIntervalSince1970: 1_699_000_000))
        let all = [localSnap("a", spotId: "s2", scope: .spot),
                   localSnap("fremd", author: "u2", spotZone: "spot-anders")]
        #expect(albumSnaps(all, spot: localSpot).map(\.id) == ["a"])
    }

    @Test("Freie Snaps sind die ohne jeden Spot-Bezug")
    func freePinsAreSpotless() {
        let all = [localSnap("frei1", minutesAgo: 1), localSnap("frei2", minutesAgo: 9),
                   localSnap("amSpot", spotId: "s1", scope: .spot),
                   localSnap("fremdAmSpot", author: "u2", spotZone: "spot-s1")]
        #expect(freeSnaps(all).map(\.id) == ["frei1", "frei2"])
    }
}

@Suite("Snap-Merge — Cloud fuer fremde, Geraet fuer eigene")
struct SnapMergeTests {
    private func merge(_ cloud: [CloudSnap], _ local: [Snap]) -> SnapMerge {
        mergeSnaps(cloud, local: local, myUserID: "me") { zone in
            zone == "spot-s1" ? "s1" : nil
        }
    }

    @Test("Fremder Snap kommt an, mit Spot-Bezug aus der Zone")
    func foreignSnapArrives() {
        let result = merge([cloudSnap("x", zone: "feed-u2", author: "u2", spotZone: "spot-s1")], [])
        let snap = try! #require(result.upserts.first)
        #expect(snap.authorId == "u2")
        #expect(snap.spotId == "s1")
        #expect(snap.spotZone == "spot-s1")
        #expect(snap.scope == .feed)
        #expect(snap.uploadState == .done)
    }

    @Test("Snap aus einer Spot-Zone gilt als Spot-Snap")
    func snapInSpotZoneIsScopedToSpot() {
        let result = merge([cloudSnap("y", zone: "spot-s1", author: "u2", inSpotZone: true)], [])
        let snap = try! #require(result.upserts.first)
        #expect(snap.scope == .spot)
        #expect(snap.spotZone == "spot-s1")
        #expect(snap.spotId == "s1")
    }

    @Test("Fremder Snap, der aus der Cloud verschwindet, faellt raus")
    func foreignSnapDisappears() {
        let result = merge([], [localSnap("weg", author: "u2")])
        #expect(result.removals == ["weg"])
    }

    @Test("Eigener Snap in der Outbox ueberlebt einen leeren Snapshot")
    func ownPendingSnapSurvives() {
        // Genau der Fall nach dem Ausloesen: lokal da, in der Cloud noch nicht.
        let result = merge([], [localSnap("neu", state: .pending)])
        #expect(result.removals.isEmpty)
        #expect(result.upserts.isEmpty)
    }

    @Test("Der eigene Snap gilt als hochgeladen, sobald er im Abzug steht")
    func ownSnapBecomesDone() {
        let local = localSnap("neu", state: .pending)
        let result = merge([cloudSnap("neu", zone: "feed-me", author: "me")], [local])
        let snap = try! #require(result.upserts.first)
        #expect(snap.uploadState == .done)
        #expect(snap.zoneName == "feed-me")
        // Die Dateien des Geraets bleiben unangetastet.
        #expect(snap.thumbPath == local.thumbPath)
        #expect(snap.photoPath == local.photoPath)
    }

    @Test("Ausblenden und geladene Bilder ueberleben den Merge")
    func localDecisionsSurvive() {
        let local = localSnap("x", author: "u2", hidden: true)
        let result = merge([cloudSnap("x", zone: "feed-u2", author: "u2")], [local])
        if let snap = result.upserts.first {
            #expect(snap.hidden)
            #expect(snap.thumbPath == local.thumbPath)
        }
    }

    @Test("Zweimal derselbe Abzug schreibt nichts mehr")
    func mergeIsIdempotent() {
        let cloud = [cloudSnap("x", zone: "feed-u2", author: "u2", spotZone: "spot-s1")]
        let first = merge(cloud, [])
        let second = merge(cloud, first.upserts)
        #expect(second.isEmpty, "zweiter Lauf haette geschrieben: \(second)")
    }
}

@Suite("SnapStore — Bestand, Outbox, Ausblenden")
@MainActor
struct SnapStoreTests {
    private func makeStore() throws -> (SnapStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gz-snaps-\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.inMemory(migrations: SnapMigrations.all)
        return (SnapStore(database, files: SnapFiles(base: base)), base)
    }

    @Test("Gespeicherter Snap steht im Bestand, neuester zuerst")
    func savedSnapsAreOrdered() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try await store.save(localSnap("alt", minutesAgo: 30))
        try await store.save(localSnap("neu", minutesAgo: 1))
        #expect(store.snaps.map(\.id) == ["neu", "alt"])
    }

    @Test("Outbox fuehrt nur eigene, unfertige Snaps — alt zuerst")
    func outboxHoldsOwnUnfinished() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try await store.save(localSnap("fertig", state: .done))
        try await store.save(localSnap("wartet", state: .pending, minutesAgo: 2))
        try await store.save(localSnap("abgebrochen", state: .uploading, minutesAgo: 5))
        try await store.save(localSnap("fremd", author: "u2", state: .pending))
        #expect(store.outbox.map(\.id) == ["abgebrochen", "wartet"])
    }

    @Test("Ausblenden bleibt, ein Merge hebt es nicht auf")
    func hidingSurvivesUpsert() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try await store.save(localSnap("x", author: "u2"))
        try await store.hide(id: "x")
        // Derselbe Snap kommt erneut aus der Cloud — ohne Kenntnis von `hidden`.
        try await store.save(localSnap("x", author: "u2"))
        #expect(store.snap(id: "x")?.hidden == true)
    }

    @Test("Löschen raeumt Zeile und Dateien")
    func removeDeletesFiles() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = SnapFiles(base: base)
        let url = try files.writeOriginal(Data("bild".utf8), id: "x")
        try await store.save(localSnap("x"))
        #expect(FileManager.default.fileExists(atPath: url.path))

        try await store.remove(id: "x")
        #expect(store.snap(id: "x") == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path), "Datei blieb liegen")
    }

    @Test("Melden wird genau einmal vermerkt")
    func reportIsRecordedOnce() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try await store.save(localSnap("x", author: "u2"))
        #expect(try store.isReported(id: "x") == false)
        try await store.markReported(id: "x", at: Date(timeIntervalSince1970: 1))
        try await store.markReported(id: "x", at: Date(timeIntervalSince1970: 2))
        #expect(try store.isReported(id: "x"))
    }
}
