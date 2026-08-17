import CoreLocation
import Foundation
import os

/// Der Weg eines Snaps: Auslöser → Dateien → Bestand → Cloud → Vorschaubilder.
///
/// **Sofort lokal, Cloud holt auf.** Anders als bei Einladungen (die zuerst in
/// die Cloud gehen und ohne Netz abbrechen) ist ein Foto in dem Moment fertig,
/// in dem es aufgenommen wurde. Es lokal zu verweigern, weil gerade kein Netz
/// da ist, wäre albern — der Upload liegt deshalb in einer Outbox und wird
/// nachgeholt. Sichtbar bleibt der Zustand trotzdem: das Album zeigt „wartet
/// auf Upload", statt Vollzug vorzutäuschen.
@MainActor
@Observable
public final class SnapCoordinator {
    /// Letzte Meldung an den Nutzer (blameless) oder `nil`.
    public private(set) var error: String?
    /// Läuft gerade ein Upload?
    public private(set) var uploading = false

    @ObservationIgnored private let store: SnapStore
    @ObservationIgnored private let gateway: any CloudGateway
    @ObservationIgnored private let files: SnapFiles
    @ObservationIgnored private let clock: GZClock
    @ObservationIgnored private let logger = Logger(subsystem: "de.leonvalentin.greenzones",
                                                    category: "snaps")

    /// Schwanz der Upload-Kette: zwei parallele Läufe würden denselben Snap
    /// zweimal hochladen.
    @ObservationIgnored private var flushing: Task<Void, Never>?
    @ObservationIgnored private var loadingThumbs = false

    public init(store: SnapStore, gateway: any CloudGateway,
                files: SnapFiles = SnapFiles(), clock: GZClock = SystemClock()) {
        self.store = store
        self.gateway = gateway
        self.files = files
        self.clock = clock
    }

    public func clearError() { error = nil }

    // MARK: - Aufnehmen

    /// Aus den Kameradaten wird ein Snap: verkleinert, gedreht, ohne Position im
    /// Bild — und sofort im Bestand.
    @discardableResult
    public func capture(_ data: Data, at coordinate: CLLocationCoordinate2D,
                        spot: Spot?, scope: SnapScope) async throws -> Snap {
        let processed = try SnapPipeline.process(data)
        let id = UUID().uuidString
        let original = try files.writeOriginal(processed.original, id: id)
        let thumb = try files.writeThumb(processed.thumb, id: id)

        // Ohne geteilten Spot gibt es keine Spot-Zone — dann ist auch „nur
        // Freunde im Spot" nicht möglich; der Snap bleibt beim Spot, aber im
        // eigenen Feed.
        let effectiveScope: SnapScope = (scope == .spot && spot?.zoneName != nil) ? .spot : .feed
        let snap = Snap(id: id,
                        authorId: SELF_ID,
                        createdAt: clock.now,
                        lat: coordinate.latitude,
                        lng: coordinate.longitude,
                        spotId: spot?.id,
                        spotZone: spot?.zoneName,
                        spotName: spot?.name,
                        spotEmoji: spot?.emoji,
                        scope: effectiveScope,
                        thumbPath: thumb.path,
                        photoPath: original.path,
                        uploadState: .pending)
        try await store.save(snap)
        await flush()
        return snap
    }

    /// Nächster Spot innerhalb von 30 m (SPEC 10.1). Entscheidet, ob ein Snap an
    /// einen Spot gehört oder frei auf der Karte steht.
    public func captureContext(at coordinate: CLLocationCoordinate2D, spots: [Spot],
                               maxDistanceM: Double = 30) -> Spot? {
        spots
            .map { ($0, Geo.distanceM(coordinate, CLLocationCoordinate2D(latitude: $0.lat,
                                                                        longitude: $0.lng))) }
            .filter { $0.1 <= maxDistanceM }
            .min { $0.1 < $1.1 }?
            .0
    }

    // MARK: - Outbox

    /// Wartende Uploads abarbeiten. Läuft seriell hinter dem vorherigen Lauf.
    public func flush() async {
        let previous = flushing
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.flushPending()
        }
        flushing = task
        await task.value
    }

    private func flushPending() async {
        let pending = store.outbox
        guard !pending.isEmpty else { return }
        uploading = true
        defer { uploading = false }

        for snap in pending {
            let original = files.originalURL(id: snap.id)
            let thumb = files.thumbURL(id: snap.id)
            guard files.exists(original.path), files.exists(thumb.path) else {
                // Datei weg (Cache geleert, Gerät voll): der Snap kann nie mehr
                // hochgehen. Das ist ein Endzustand, kein Wiederholungsfall.
                logger.error("Snap \(snap.id, privacy: .public): Datei fehlt, Upload aufgegeben")
                try? await store.setUploadState(id: snap.id, .failed)
                continue
            }
            do {
                try await store.setUploadState(id: snap.id, .uploading)
                let upload = try await gateway.uploadSnap(snap, original: original, thumb: thumb)
                try await store.setUploadState(id: snap.id, .done,
                                               zoneName: upload.zoneName,
                                               recordName: upload.recordName)
            } catch {
                try? await store.setUploadState(id: snap.id, .pending)
                // Kein Konto ist kein Fehler, sondern der lokale Normalfall
                // (SPEC 10.3): der Snap bleibt liegen, bis es einen Feed gibt.
                if (error as? SyncError) != .noAccount {
                    self.error = cloudMessage(error)
                }
                break
            }
        }
    }

    // MARK: - Empfangen

    /// Snaps aus dem Vollabzug übernehmen und fehlende Vorschaubilder holen.
    public func apply(_ snapshot: CloudSnapshot, spots: [Spot]) async {
        guard snapshot.status == .available else { return }
        let byZone = Dictionary(spots.compactMap { spot in
            spot.zoneName.map { ($0, spot.id) }
        }, uniquingKeysWith: { a, _ in a })

        let merge = mergeSnaps(snapshot.snaps, local: store.snaps, myUserID: snapshot.userID) {
            byZone[$0]
        }
        do {
            try await store.saveAll(merge.upserts)
            for id in merge.removals { try await store.remove(id: id) }
        } catch {
            logger.error("Snaps nicht geschrieben: \(String(describing: error), privacy: .public)")
        }
        await loadMissingThumbs()
    }

    /// Vorschaubilder aller sichtbaren Snaps, die noch keins auf der Platte
    /// haben. Das Original bleibt draußen — es kommt erst beim Öffnen.
    public func loadMissingThumbs() async {
        guard !loadingThumbs else { return }
        loadingThumbs = true
        defer { loadingThumbs = false }

        let missing = store.snaps.filter { snap in
            !snap.hidden && !files.exists(snap.thumbPath)
                && snap.zoneName != nil && snap.recordName != nil
        }
        guard !missing.isEmpty else { return }

        let refs = missing.compactMap { snap -> SnapAsset? in
            guard let zone = snap.zoneName, let record = snap.recordName else { return nil }
            return SnapAsset(snapId: snap.id, zoneName: zone, recordName: record)
        }
        do {
            let loaded = try await gateway.fetchThumbs(refs)
            for (id, data) in loaded {
                let url = try files.writeThumb(data, id: id)
                try await store.setThumbPath(id: id, url.path)
            }
        } catch {
            // Bilder sind nachladbar: ein Fehlschlag kostet einen Versuch, keine
            // Erinnerung. Der nächste Durchgang holt sie.
            logger.error("Vorschaubilder nicht geladen: \(String(describing: error), privacy: .public)")
        }
    }

    /// Original für den Viewer — eigenes von der Platte, fremdes aus dem Cache
    /// oder frisch geladen.
    public func original(of snap: Snap) async -> URL? {
        // Was schon auf der Platte liegt, gewinnt — unabhaengig davon, wer den
        // Snap gemacht hat. Ohne diese Zeile laedt ein fremdes Bild erneut aus
        // der Cloud, obwohl es daneben liegt (und im Fixture-Lauf bliebe der
        // Betrachter beim unscharfen Vorschaubild).
        if let path = snap.photoPath, files.exists(path) {
            return URL(fileURLWithPath: path)
        }
        if snap.isMine {
            let url = files.originalURL(id: snap.id)
            return files.exists(url.path) ? url : nil
        }
        let cached = files.remoteOriginalURL(id: snap.id)
        if files.exists(cached.path) { return cached }
        guard let zone = snap.zoneName, let record = snap.recordName else { return nil }
        do {
            let data = try await gateway.fetchOriginal(SnapAsset(snapId: snap.id, zoneName: zone,
                                                                 recordName: record))
            return try files.writeRemoteOriginal(data, id: snap.id)
        } catch {
            self.error = cloudMessage(error)
            return nil
        }
    }

    // MARK: - Löschen, Melden

    /// Eigenen Snap löschen — erst in der Cloud, dann lokal. Als Spot-Owner geht
    /// das auch für fremde Snaps in der eigenen Zone (Zone-Owner-Recht).
    public func delete(_ snap: Snap) async throws {
        if let zone = snap.zoneName, let record = snap.recordName {
            try await gateway.deleteSnap(zoneName: zone, recordName: record)
        }
        try await store.remove(id: snap.id)
    }

    /// Melden: lokal sofort ausblenden, Meldung in die Zone des Snaps legen.
    ///
    /// Die Reihenfolge ist Absicht — wer meldet, will das Bild **jetzt** nicht
    /// mehr sehen. Ob die Meldung rausging, ändert daran nichts.
    public func report(_ snap: Snap) async throws {
        try await store.hide(id: snap.id)
        guard let zone = snap.zoneName, !(try store.isReported(id: snap.id)) else { return }
        try await gateway.reportSnap(zoneName: zone, snapId: snap.id, at: clock.now)
        try await store.markReported(id: snap.id, at: clock.now)
    }

    /// Nur ausblenden, ohne Meldung.
    public func hide(_ snap: Snap) async throws {
        try await store.hide(id: snap.id)
    }
}
