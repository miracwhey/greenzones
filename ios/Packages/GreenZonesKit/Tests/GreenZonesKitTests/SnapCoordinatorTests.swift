import CoreLocation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GreenZonesKit

/// Der Weg eines Snaps vom Auslöser bis in die Cloud. Geprüft wird der
/// Bestand, nicht der Rückgabewert: was in der Datenbank und auf der Platte
/// steht, ist der Zustand, den der Nutzer beim nächsten Start sieht.
@Suite("SnapCoordinator — Aufnahme, Outbox, Empfang")
@MainActor
struct SnapCoordinatorTests {
    private let hannover = CLLocationCoordinate2D(latitude: 52.3595, longitude: 9.7400)

    private func makeJPEG() throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func makeCoordinator(gateway: FakeGateway = FakeGateway())
        throws -> (SnapCoordinator, SnapStore, SnapFiles, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gz-coord-\(UUID().uuidString)", isDirectory: true)
        let files = SnapFiles(base: base)
        let database = try AppDatabase.inMemory(migrations: SnapMigrations.all)
        let store = SnapStore(database, files: files)
        let coordinator = SnapCoordinator(store: store, gateway: gateway, files: files,
                                          clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)))
        return (coordinator, store, files, base)
    }

    private func spot(shared: Bool) -> Spot {
        Spot(id: "s1", name: "Unsere Bank", emoji: "🪑", lng: 9.7400, lat: 52.3595,
             createdAt: Date(timeIntervalSince1970: 1_699_000_000),
             zoneName: shared ? "spot-s1" : nil)
    }

    @Test("Aufnahme liegt sofort im Bestand — mit beiden Dateien")
    func captureWritesEverythingLocally() async throws {
        let (coordinator, store, files, base) = try makeCoordinator()
        defer { try? FileManager.default.removeItem(at: base) }

        let snap = try await coordinator.capture(makeJPEG(), at: hannover, spot: nil, scope: .feed)

        #expect(store.snaps.count == 1)
        #expect(files.exists(files.originalURL(id: snap.id).path))
        #expect(files.exists(files.thumbURL(id: snap.id).path))
        #expect(snap.isFree, "ohne Spot steht der Snap frei auf der Karte")
    }

    @Test("Ohne Konto bleibt der Snap liegen — ohne Fehlermeldung")
    func noAccountKeepsItPendingQuietly() async throws {
        // NoCloudGateway ist der Zustand „kein CloudKit": Uploads lehnen ab.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gz-coord-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let files = SnapFiles(base: base)
        let database = try AppDatabase.inMemory(migrations: SnapMigrations.all)
        let store = SnapStore(database, files: files)
        let coordinator = SnapCoordinator(store: store, gateway: NoCloudGateway(), files: files)

        let snap = try await coordinator.capture(makeJPEG(), at: hannover, spot: nil, scope: .feed)

        #expect(store.snap(id: snap.id)?.uploadState == .pending)
        #expect(coordinator.error == nil, "kein Konto ist der Normalfall, keine Störung")
    }

    @Test("Mit Konto geht der Snap raus und gilt als fertig")
    func uploadMarksItDone() async throws {
        let gateway = FakeGateway()
        let (coordinator, store, _, base) = try makeCoordinator(gateway: gateway)
        defer { try? FileManager.default.removeItem(at: base) }

        let snap = try await coordinator.capture(makeJPEG(), at: hannover, spot: nil, scope: .feed)

        #expect(gateway.uploadedSnaps == [snap.id])
        #expect(store.snap(id: snap.id)?.uploadState == .done)
        #expect(store.snap(id: snap.id)?.zoneName == "feed-me")
        #expect(store.outbox.isEmpty)
    }

    @Test("Netzfehler: der Snap wartet weiter und die Meldung ist sichtbar")
    func networkFailureKeepsItInTheOutbox() async throws {
        let gateway = FakeGateway()
        gateway.fails["uploadSnap"] = .network
        let (coordinator, store, _, base) = try makeCoordinator(gateway: gateway)
        defer { try? FileManager.default.removeItem(at: base) }

        let snap = try await coordinator.capture(makeJPEG(), at: hannover, spot: nil, scope: .feed)

        #expect(store.snap(id: snap.id)?.uploadState == .pending)
        #expect(store.outbox.map(\.id) == [snap.id])
        #expect(coordinator.error != nil)
    }

    @Test("Nur Freunde im Spot braucht einen geteilten Spot")
    func spotScopeNeedsASharedSpot() async throws {
        let (coordinator, store, _, base) = try makeCoordinator()
        defer { try? FileManager.default.removeItem(at: base) }

        let shared = try await coordinator.capture(makeJPEG(), at: hannover,
                                                   spot: spot(shared: true), scope: .spot)
        let local = try await coordinator.capture(makeJPEG(), at: hannover,
                                                  spot: spot(shared: false), scope: .spot)

        #expect(store.snap(id: shared.id)?.scope == .spot)
        // Ein rein lokaler Spot hat keine Zone — „nur Freunde im Spot" gäbe es
        // dort nicht; der Snap bleibt im eigenen Feed, statt zu verschwinden.
        #expect(store.snap(id: local.id)?.scope == .feed)
    }

    @Test("Der nächste Spot in 30 m gewinnt, der weitere nicht")
    func captureContextPicksTheNearestSpot() throws {
        let (coordinator, _, _, base) = try makeCoordinator()
        defer { try? FileManager.default.removeItem(at: base) }

        let near = Spot(id: "nah", name: "Nah", emoji: "🪑", lng: 9.7400, lat: 52.35955,
                        createdAt: Date())           // ~6 m
        let mid = Spot(id: "mittel", name: "Mittel", emoji: "🌳", lng: 9.7402, lat: 52.3596,
                       createdAt: Date())            // ~15 m
        let far = Spot(id: "weit", name: "Weit", emoji: "⭐️", lng: 9.7420, lat: 52.3600,
                       createdAt: Date())            // ~150 m

        #expect(coordinator.captureContext(at: hannover, spots: [mid, near, far])?.id == "nah")
        #expect(coordinator.captureContext(at: hannover, spots: [far]) == nil)
    }

    @Test("Fremde Snaps aus dem Abzug kommen an, Vorschaubilder werden geholt")
    func snapshotBringsForeignSnapsAndThumbs() async throws {
        let gateway = FakeGateway()
        gateway.thumbs = ["fremd-1": Data("bild".utf8)]
        let (coordinator, store, files, base) = try makeCoordinator(gateway: gateway)
        defer { try? FileManager.default.removeItem(at: base) }

        let snapshot = CloudSnapshot(
            status: .available, userID: "me", friends: [], spots: [], invitations: [],
            snaps: [CloudSnap(id: "fremd-1", zoneName: "feed-u2", authorUserID: "u2",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                              lat: 52.36, lng: 9.74, spotZone: "spot-s1",
                              spotName: "Unsere Bank", spotEmoji: "🪑", inSpotZone: false)])

        await coordinator.apply(snapshot, spots: [spot(shared: true)])

        let stored = try #require(store.snap(id: "fremd-1"))
        #expect(stored.authorId == "u2")
        #expect(stored.spotId == "s1", "über die Zone dem lokalen Spot zugeordnet")
        #expect(files.exists(stored.thumbPath), "Vorschaubild nicht auf der Platte")
    }

    @Test("Melden blendet sofort aus und meldet genau einmal")
    func reportHidesFirstAndReportsOnce() async throws {
        let gateway = FakeGateway()
        let (coordinator, store, _, base) = try makeCoordinator(gateway: gateway)
        defer { try? FileManager.default.removeItem(at: base) }

        try await store.save(Snap(id: "fremd", authorId: "u2", createdAt: Date(),
                                  lat: 52.36, lng: 9.74, zoneName: "feed-u2",
                                  recordName: "fremd", uploadState: .done))
        let snap = try #require(store.snap(id: "fremd"))

        try await coordinator.report(snap)
        try await coordinator.report(snap)

        #expect(store.snap(id: "fremd")?.hidden == true)
        #expect(gateway.reportedSnaps == ["fremd"], "zweite Meldung darf nicht nochmal rausgehen")
    }

    @Test("Eigenen Snap löschen: erst die Cloud, dann Zeile und Dateien")
    func deleteRemovesEverywhere() async throws {
        let gateway = FakeGateway()
        let (coordinator, store, files, base) = try makeCoordinator(gateway: gateway)
        defer { try? FileManager.default.removeItem(at: base) }

        let snap = try await coordinator.capture(makeJPEG(), at: hannover, spot: nil, scope: .feed)
        let stored = try #require(store.snap(id: snap.id))
        try await coordinator.delete(stored)

        #expect(gateway.deletedSnaps == [snap.id])
        #expect(store.snap(id: snap.id) == nil)
        #expect(!files.exists(files.originalURL(id: snap.id).path))
    }
}
