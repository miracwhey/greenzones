import CoreLocation
import GreenZonesKit
import SwiftUI
import os

/// Composition Root: haelt Uhr, Standort und Zonen-Engine zusammen und leitet
/// daraus den Legal-Status ab. Views beobachten nur, sie rechnen nicht.
@MainActor
@Observable
final class AppModel {
    /// Standort ≥ 15 m bewegt → neu rechnen (v1 `App.tsx`).
    private static let recomputeDistanceM: Double = 15
    /// Zeit-Tick fuers Zeitfenster (v1: 30 s).
    private static let tickSeconds: UInt64 = 30

    let location: LocationService
    /// App-DB. Jedes Feature traegt seine Migrationsschritte in `migrations` ein.
    let database: AppDatabase
    /// W2: Such-Kern (Offline-Index + Photon + Recents).
    let search: SearchController
    // W3: Community (Spots, Einladungen, Freunde, Profil) — eigenes Modell,
    // damit die Composition Root nicht zum Sammelbecken wird.
    let community: CommunityModel
    private let clock: GZClock
    private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "status")

    private(set) var status: ZoneStatus?

    /// W2: Ziel-Modus — der gewaehlte Ort und sein Zonen-Status.
    struct Target: Equatable {
        let result: SearchResult
        var status: ZoneStatus?
    }

    private(set) var target: Target?
    /// Aktuelle Stunde aus der Uhr — traegt Zeitfenster-Farbe UND Verdikt.
    private(set) var hour: Int
    /// Engine fehlt = die pmtiles sind nicht im Bundle. Sichtbar, nicht still.
    private(set) var engineFailure: String?

    var onboarded: Bool {
        didSet { UserDefaults.standard.set(onboarded, forKey: Self.onboardedKey) }
    }

    var detailOpen = false
    var infoOpen = false
    /// Zaehler statt Boolean: derselbe FAB-Tap zweimal muss zweimal fahren.
    private(set) var recenterToken = 0

    private var engine: ZoneEngine?
    private var lastEvaluated: CLLocationCoordinate2D?
    private var statusTask: Task<Void, Never>?
    private var targetTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var previousKind: StatusKind = .wait
    private var cloudObserver: (any NSObjectProtocol)?

    /// Der Schluessel traegt die Fassung des Onboardings, nicht nur ein „schon
    /// gesehen".
    ///
    /// Vorher hiess er `gz_onboarded` und die Frage lautete zusaetzlich „ist die
    /// Ortung noch ungefragt?" — wer sie erlaubt hatte, sah nie ein Onboarding.
    /// Build 4 ersetzt die TestFlight-App unter derselben Bundle-ID, dort ist
    /// die Erlaubnis laengst erteilt: die vier neuen Schritte waeren bei
    /// niemandem angekommen, der die App schon hat. Mit der Fassung im Namen
    /// bekommt jeder das neue Onboarding einmal, und der naechste Umbau kann es
    /// genauso.
    static let onboardedKey = "gz_onboarded_v2"

    init() {
        #if DEBUG
        clock = DebugClock.fromEnvironment() ?? SystemClock()
        let fixtureCoordinate: CLLocationCoordinate2D? = DebugEnvironment.usesFixtures
            ? DebugEnvironment.fixtureCoordinate : nil
        let fixtureAccuracy = DebugEnvironment.fixtureAccuracyM
        #else
        clock = SystemClock()
        let fixtureCoordinate: CLLocationCoordinate2D? = nil
        let fixtureAccuracy: Double = 12
        #endif
        location = LocationService(fixedCoordinate: fixtureCoordinate, fixedAccuracyM: fixtureAccuracy)
        // Migrationsschritte der Features — Reihenfolge = Registrierungsreihenfolge.
        // W2: `SearchMigrations.all` bringt `recent_search` mit.
        // W3: `CommunityMigrations.all` bringt Spots/Freunde/Einladungen mit.
        // W5: `SnapMigrations.all` bringt `snap` und `snap_report` mit.
        let migrations: [DBMigration] = SearchMigrations.all + CommunityMigrations.all
            + SnapMigrations.all
        do {
            // Fixture-Laeufe (Screenshots) schreiben nichts auf die Platte.
            database = try fixtureCoordinate != nil
                ? AppDatabase.inMemory(migrations: migrations)
                : AppDatabase(path: AppDatabase.defaultPath(), migrations: migrations)
        } catch {
            // Ohne DB laeuft die App nicht sinnvoll — laut scheitern statt still leer.
            fatalError("App-DB startet nicht: \(error)")
        }
        #if DEBUG
        // Recents VOR dem Controller schreiben — er liest sie beim Bauen seines
        // ersten Zustands, ein spaeterer Eintrag kaeme im Screenshot nicht an.
        if DebugEnvironment.route.opensSearch {
            let store = RecentsStore(database: database)
            for recent in DebugEnvironment.fixtureRecents.reversed() { store.add(recent) }
        }
        #endif
        // W2: Such-Kern. Der Index liegt read-only im Bundle; fehlt er, macht der
        // Controller daraus einen sichtbaren Zustand mit „Erneut versuchen".
        let placesURL = Bundle.main.url(forResource: "places", withExtension: "sqlite")
            ?? URL(fileURLWithPath: "/places.sqlite")
        search = SearchController(offline: PlacesIndex(url: placesURL),
                                  photon: DebugEnvironment.photonSource(),
                                  recents: RecentsStore(database: database))

        // W3: v1-Bestand einmalig uebernehmen (SPEC 4) — VOR den Stores, sonst
        // stuende der erste Frame leer da. Ohne diesen Schritt waeren alle rein
        // lokalen Spots weg; ein Fehler kippt den Start nicht, der Marker bleibt
        // dann ungesetzt und der naechste Start versucht es erneut.
        if fixtureCoordinate == nil {
            do {
                _ = try V1Importer.runIfNeeded(database: database)
            } catch {
                Logger(subsystem: "de.leonvalentin.greenzones", category: "store")
                    .error("v1-Import fehlgeschlagen: \(String(describing: error), privacy: .public)")
            }
        }
        hour = GZTime.currentHour(clock)
        // Im Fixture-Lauf gibt es keinen Dialog und kein Onboarding — der
        // Screenshot soll die Karte zeigen, nicht die Erlaubnisfrage.
        onboarded = fixtureCoordinate != nil || UserDefaults.standard.bool(forKey: Self.onboardedKey)

        var startedEngine: ZoneEngine?
        if let url = Bundle.main.url(forResource: "zones", withExtension: "pmtiles") {
            do {
                startedEngine = try ZoneEngine(pmtilesURL: url)
            } catch {
                engineFailure = String(describing: error)
                logger.error("Zonen-Engine startet nicht: \(String(describing: error), privacy: .public)")
            }
        } else {
            engineFailure = "zones.pmtiles fehlt im Bundle"
            logger.error("zones.pmtiles fehlt im Bundle")
        }
        engine = startedEngine

        // W3: Community. Der Zonen-Status einzelner Punkte (Spot, gewaehlte
        // Position) kommt aus derselben Engine wie die Status-Bar — eine Quelle.
        // Die Closure haelt die Engine direkt, nicht `self`: waehrend `init` ist
        // `self` noch nicht vollstaendig.
        let engineForPoints = startedEngine
        // W5: Fixture-Laeufe legen ihre Bilder in ein eigenes, verwerfbares
        // Verzeichnis — ein Screenshot-Lauf darf den echten Bestand nicht
        // anfassen (dieselbe Regel wie die In-Memory-DB darueber).
        let snapFiles = fixtureCoordinate != nil
            ? SnapFiles(base: FileManager.default.temporaryDirectory
                .appendingPathComponent("gz-fixture-snaps", isDirectory: true))
            : SnapFiles()
        community = CommunityModel(database: database, gateway: GZCloud.gateway, clock: clock,
                                   files: snapFiles) { coordinate in
            guard let engineForPoints else { return nil }
            return await engineForPoints.status(at: coordinate)
        }
    }

    var timeActive: Bool { GZTime.banAtHour(hour) }

    var presentation: StatusPresentation {
        // W2: im Ziel-Modus gilt der Status des Ziels, nicht der des Standorts.
        if let target {
            return StatusPresentation(target: target.result, status: target.status, hour: hour)
        }
        return StatusPresentation(status: status,
                                  locating: location.state.isLocating,
                                  denied: location.state == .denied,
                                  hour: hour)
    }

    /// W2: Status, den das Detail-Sheet und die Zonenliste zeigen.
    var visibleStatus: ZoneStatus? { target?.status ?? status }

    // MARK: - Lebenszyklus

    func start() {
        startTick()
        // Dasselbe Prinzip wie bei der Ortung unten, nur fuer alles, was der
        // Sync von sich aus verlangen wuerde: solange das Onboarding steht,
        // fragt niemand sonst etwas. Beim Erststart mit v1-Bestand bringt der
        // Import Freunde mit, und ohne dieses Tor stuende die
        // Mitteilungs-Erlaubnis Sekundenbruchteile spaeter ueber dem ersten
        // Schritt — im Bild gesehen.
        community.sync.asksAllowed = !shouldShowOnboarding
        // W2: Der Index wird vorgewaermt, nicht erst beim ersten Tastendruck
        // geoeffnet — sonst haengt der erste Buchstabe an einem Dateizugriff.
        search.prewarm()
        // W3: Fixture-Laeufe fahren den Bestand selbst; der Sync wuerde ihn nur
        // mit einem leeren Snapshot bewerten und den Screenshot verwaessern.
        #if DEBUG
        applyDebugSearchFixtures()
        if DebugEnvironment.usesFixtures {
            CommunityFixtures.seed(community, route: DebugEnvironment.route, clock: clock)
        } else {
            Task { await community.sync.start() }
            startSnapOutbox()
        }
        #else
        Task { await community.sync.start() }
        startSnapOutbox()
        #endif
        observeCloudChanges()
        // Solange das Onboarding steht, wird NICHT geortet — sonst stuende der
        // System-Dialog vor dem Bildschirm, der ihn erklaeren soll (v1:
        // `useLocation(onboarded)` laeuft erst nach dem Onboarding an).
        guard !shouldShowOnboarding else { return }
        location.start()
    }

    /// W5: Ein Snap, der beim letzten Mal nicht rausging (kein Netz, App
    /// beendet), liegt in der Outbox. Ohne diesen Anstoss beim Start bliebe er
    /// dort liegen, bis zufaellig ein neuer Snap entsteht.
    private func startSnapOutbox() {
        Task { await community.snapSync.flush() }
    }

    /// Push und angenommene Einladungen sagen nur „da hat sich was geaendert" —
    /// was, holt der naechste Vollabzug. Die Beobachtung laeuft mit dem Modell:
    /// stirbt es, endet auch sie.
    private func observeCloudChanges() {
        guard cloudObserver == nil else { return }
        cloudObserver = NotificationCenter.default.addObserver(forName: GZCloud.changed,
                                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.community.sync.refresh() }
        }
    }

    /// Das Onboarding haengt allein daran, ob DIESE Fassung schon gelaufen ist.
    ///
    /// Vorher stand hier zusaetzlich `&& !location.isAuthorized` — eine erteilte
    /// Ortungserlaubnis unterdrueckte es. Das passte, solange das Onboarding nur
    /// die Standortfrage war; jetzt erklaert es Spots, Freunde und Snaps, und
    /// die haben mit der Ortung nichts zu tun.
    var shouldShowOnboarding: Bool { !onboarded }

    /// Steht die Erlaubnis schon, gibt es im ersten Schritt nichts zu fragen —
    /// der Knopf heisst dann „Weiter" statt „Standort freigeben".
    var locationAlreadyAuthorized: Bool { location.isAuthorized }

    /// Beide Knoepfe starten die Ortung: `start()` fragt bei `notDetermined`
    /// selbst nach der Erlaubnis — wie `ensurePermission()` in v1.
    func finishOnboarding() {
        onboarded = true
        location.start()
        // Jetzt ist der Bildschirm frei: was der Sync zurueckgehalten hat
        // (Mitteilungs-Erlaubnis, Profil-Aufforderung), darf kommen.
        community.sync.asksAllowed = true
    }

    func recenter() {
        GZ.haptic()
        recenterToken += 1
    }

    // MARK: - Ziel-Modus (W2)

    /// Suchtreffer gewaehlt: Pin setzen, Karte hinfliegen lassen, Status am Ziel
    /// rechnen. Der Ziel-Status kommt aus derselben Engine wie der Standort-Status
    /// — nur an einem anderen Punkt (SPEC E6).
    func selectTarget(_ result: SearchResult) {
        target = Target(result: result, status: nil)
        evaluateTarget()
    }

    /// Ziel verlassen: Pin weg, Feld leer, Karte zurueck auf den Standort (v1
    /// `clearTarget` → `gz:recenter`).
    func clearTarget() {
        guard target != nil else { return }
        targetTask?.cancel()
        target = nil
        // Ohne Haptik: das X hat schon eine gegeben, ein zweiter Schlag waere
        // ein anderes Ereignis als in v1.
        recenterToken += 1
    }

    #if DEBUG
    /// W2: Fixture-Zustaende der Screenshot-Routen — dieselben Setter, die auch
    /// ein Tap benutzt, kein Sonderrendering.
    private func applyDebugSearchFixtures() {
        let route = DebugEnvironment.route
        if route == .target || route == .targetDetail {
            selectTarget(DebugEnvironment.fixtureTarget)
        }
    }
    #endif

    private func evaluateTarget() {
        guard let engine, let coordinate = target?.result.coordinate else { return }
        let pending = target?.result
        targetTask?.cancel()
        targetTask = Task { [weak self] in
            let result = await engine.status(at: coordinate)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.target?.result == pending else { return }
                self.target?.status = result
            }
        }
    }

    // MARK: - Status

    /// Wird bei jeder Standort-Aenderung aufgerufen; rechnet aber nur, wenn sich
    /// wirklich etwas geaendert hat (≥ 15 m oder noch gar kein Ergebnis).
    func locationChanged() {
        guard let coordinate = location.state.coordinate, let engine else { return }
        // W2: Das Offline-Ranking der Suche kennt die Nutzerposition (v1 App.tsx).
        search.setUserPos(coordinate)
        if let last = lastEvaluated,
           status != nil,
           Geo.distanceM(last, coordinate) < Self.recomputeDistanceM {
            return
        }
        lastEvaluated = coordinate
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            let result = await engine.status(at: coordinate)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.apply(result)
            }
        }
    }

    private func apply(_ newStatus: ZoneStatus) {
        status = newStatus
        let kind = ZoneStatus.statusKind(newStatus, hour: hour)
        // Haptik nur beim echten Wechsel, nie beim Warten (v1-Regel).
        if kind != previousKind, kind != .wait {
            if previousKind != .wait { GZ.hapticStatus(ok: kind == .ok) }
            previousKind = kind
        }
        logger.info("Status: \(kind.rawValue, privacy: .public) ban=\(newStatus.ban.nearestM) time=\(newStatus.time.nearestM)")
    }

    /// Zeitfenster-Flip (7/20 Uhr) ohne App-Neustart — derselbe Takt wie v1.
    private func startTick() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
                guard let self else { return }
                let now = GZTime.currentHour(self.clock)
                if now != self.hour {
                    self.hour = now
                    // W2: Das Verdikt am Ziel kippt mit der Stunde genauso wie
                    // das am Standort — beide neu bewerten (v1 App.tsx).
                    self.evaluateTarget()
                    // Das Verdikt kann kippen, ohne dass sich der Ort bewegt hat.
                    if let status = self.status {
                        let kind = ZoneStatus.statusKind(status, hour: now)
                        if kind != self.previousKind, kind != .wait {
                            if self.previousKind != .wait { GZ.hapticStatus(ok: kind == .ok) }
                            self.previousKind = kind
                        }
                    }
                }
            }
        }
    }
}
