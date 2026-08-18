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

    /// Ausblenden ist eine Entscheidung ueber das eigene Geraet und darf an
    /// nichts haengen, was das Netz braucht. Bis zum 18.08. stand daneben ein
    /// „Melden", das einen Record in die Zone des Gemeldeten schrieb — ohne
    /// Konto warf es, und gelesen hat ihn nie jemand. Der Test haelt fest, dass
    /// ein Gateway, das bei JEDEM Aufruf wirft, am Ausblenden nichts aendert.
    @Test("Ausblenden trägt ohne Konto und ohne Netz")
    func hideWorksWithoutTheCloud() async throws {
        let gateway = FakeGateway()
        gateway.failEverything = true
        let (coordinator, store, _, base) = try makeCoordinator(gateway: gateway)
        defer { try? FileManager.default.removeItem(at: base) }

        try await store.save(Snap(id: "fremd", authorId: "u2", createdAt: Date(),
                                  lat: 52.36, lng: 9.74, zoneName: "feed-u2",
                                  recordName: "fremd", uploadState: .done))
        let snap = try #require(store.snap(id: "fremd"))

        try await coordinator.hide(snap)
        try await coordinator.hide(snap)

        #expect(store.snap(id: "fremd")?.hidden == true)
        // Kein einziger Aufruf, egal welcher: Ausblenden geht niemanden ausser
        // mich an. Ein Test auf eine EINZELNE Methode waere hier wertlos —
        // `reportSnap` gibt es nicht mehr, die Zahl bliebe immer 0.
        #expect(gateway.calls.isEmpty, "Ausblenden hat die Cloud angefasst: \(gateway.calls)")
    }

    @Test("Eigenen Snap löschen: Zeile, Dateien und der Cloud-Record")
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
        #expect(try store.pendingDeletions().isEmpty, "erledigter Auftrag muss gestrichen sein")
    }

    /// Leons Fall am Gerät: er will ein Bild loswerden. Ohne Konto ging der
    /// alte Weg (erst Cloud, dann lokal) im ersten Schritt zu Bruch — der Snap
    /// blieb liegen, der Knopf tat nichts. Jetzt ist er sofort weg, und die
    /// Zusage „auch bei allen anderen" wartet als Auftrag.
    @Test("Ohne Konto ist der Snap trotzdem sofort weg — der Auftrag wartet")
    func deleteWorksOfflineAndQueuesTheCloudPart() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gz-coord-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let files = SnapFiles(base: base)
        let database = try AppDatabase.inMemory(migrations: SnapMigrations.all)
        let store = SnapStore(database, files: files)
        let coordinator = SnapCoordinator(store: store, gateway: NoCloudGateway(), files: files)

        try await store.save(Snap(id: "mein", authorId: SELF_ID, createdAt: Date(),
                                  lat: 52.36, lng: 9.74, zoneName: "feed-me",
                                  recordName: "mein", uploadState: .done))
        try await coordinator.delete(try #require(store.snap(id: "mein")))

        #expect(store.snap(id: "mein") == nil, "lokal muss er sofort weg sein")
        #expect(try store.pendingDeletions().map(\.recordName) == ["mein"])
        #expect(coordinator.error == nil, "kein Konto ist der Normalfall, keine Störung")
    }

    @Test("Der wartende Auftrag geht raus, sobald die Cloud wieder da ist")
    func queuedDeletionRunsOnTheNextFlush() async throws {
        let gateway = FakeGateway()
        gateway.fails["deleteSnap"] = .network
        let (coordinator, store, _, base) = try makeCoordinator(gateway: gateway)
        defer { try? FileManager.default.removeItem(at: base) }

        try await store.save(Snap(id: "mein", authorId: SELF_ID, createdAt: Date(),
                                  lat: 52.36, lng: 9.74, zoneName: "feed-me",
                                  recordName: "mein", uploadState: .done))
        try await coordinator.delete(try #require(store.snap(id: "mein")))
        #expect(gateway.deletedSnaps.isEmpty)
        #expect(try store.pendingDeletions().count == 1, "der Auftrag darf nicht verfallen")

        gateway.fails.removeValue(forKey: "deleteSnap")
        await coordinator.flush()

        #expect(gateway.deletedSnaps == ["mein"])
        #expect(try store.pendingDeletions().isEmpty)
    }

    /// Auf Leons Gerät liegt eine Datenbank, die `snap.v1` schon hinter sich
    /// hat und Snaps enthält. Der neue Schritt muss darauf aufsetzen, ohne den
    /// Bestand anzufassen — sonst startet die App nach dem Update entweder
    /// nicht mehr oder steht ohne Bilder da. Deshalb mit einer Datei-DB in zwei
    /// Öffnungen geprüft, nicht mit einer frischen im Speicher: nur so gibt es
    /// überhaupt ein „vorher".
    @Test("Der neue Migrationsschritt setzt auf eine bestehende v1-Datenbank auf")
    func migrationAddsToAnExistingDatabase() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("gz-migration-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let v1 = try #require(SnapMigrations.all.first)
        #expect(v1.id == "snap.v1")
        let before = try AppDatabase(path: path, migrations: [v1])
        let oldStore = SnapStore(before, files: SnapFiles())
        try await oldStore.save(Snap(id: "alt", authorId: SELF_ID, createdAt: Date(),
                                     lat: 52.36, lng: 9.74, uploadState: .done))

        // Zweite Öffnung mit dem vollen Satz — der Aufstieg, den das Update macht.
        let after = try AppDatabase(path: path, migrations: SnapMigrations.all)
        let store = SnapStore(after, files: SnapFiles())

        #expect(store.snap(id: "alt") != nil, "der Bestand hat den Aufstieg nicht überlebt")
        #expect(try store.pendingDeletions().isEmpty)
        try await store.queueDeletion(zoneName: "feed-me", recordName: "alt", at: Date())
        #expect(try store.pendingDeletions().map(\.recordName) == ["alt"],
                "die neue Tabelle steht nach dem Aufstieg nicht bereit")
    }

    /// Der Abzug ist älter als die Entscheidung. Ohne den offenen Auftrag legt
    /// `mergeSnaps` den gelöschten Snap als Neuzugang wieder an — er ist lokal
    /// keine bekannte eigene Zeile mehr, also greift „eigene folgen dem Gerät"
    /// nicht. Das Bild wäre nach dem nächsten Sync zurück.
    @Test("Ein Abzug holt einen gelöschten Snap mit offenem Auftrag nicht zurück")
    func snapshotDoesNotResurrectADeletedSnap() async throws {
        let gateway = FakeGateway()
        gateway.fails["deleteSnap"] = .network
        let (coordinator, store, _, base) = try makeCoordinator(gateway: gateway)
        defer { try? FileManager.default.removeItem(at: base) }

        try await store.save(Snap(id: "mein", authorId: SELF_ID, createdAt: Date(),
                                  lat: 52.36, lng: 9.74, zoneName: "feed-me",
                                  recordName: "mein", uploadState: .done))
        try await coordinator.delete(try #require(store.snap(id: "mein")))

        let cloud = CloudSnap(id: "mein", zoneName: "feed-me", authorUserID: "me",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                              lat: 52.36, lng: 9.74, spotZone: nil,
                              spotName: nil, spotEmoji: nil, inSpotZone: false)
        await coordinator.apply(CloudSnapshot(status: .available, userID: "me", friends: [],
                                              spots: [], invitations: [], snaps: [cloud]),
                                spots: [])

        #expect(store.snap(id: "mein") == nil, "der Abzug hat den gelöschten Snap zurückgeholt")
    }
}
