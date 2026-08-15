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

    static let onboardedKey = "gz_onboarded"

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
        let migrations: [DBMigration] = SearchMigrations.all
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
        hour = GZTime.currentHour(clock)
        // Im Fixture-Lauf gibt es keinen Dialog und kein Onboarding — der
        // Screenshot soll die Karte zeigen, nicht die Erlaubnisfrage.
        onboarded = fixtureCoordinate != nil || UserDefaults.standard.bool(forKey: Self.onboardedKey)

        if let url = Bundle.main.url(forResource: "zones", withExtension: "pmtiles") {
            do {
                engine = try ZoneEngine(pmtilesURL: url)
            } catch {
                engineFailure = String(describing: error)
                logger.error("Zonen-Engine startet nicht: \(String(describing: error), privacy: .public)")
            }
        } else {
            engineFailure = "zones.pmtiles fehlt im Bundle"
            logger.error("zones.pmtiles fehlt im Bundle")
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
        // W2: Der Index wird vorgewaermt, nicht erst beim ersten Tastendruck
        // geoeffnet — sonst haengt der erste Buchstabe an einem Dateizugriff.
        search.prewarm()
        #if DEBUG
        applyDebugSearchFixtures()
        #endif
        // Solange das Onboarding steht, wird NICHT geortet — sonst stuende der
        // System-Dialog vor dem Bildschirm, der ihn erklaeren soll (v1:
        // `useLocation(onboarded)` laeuft erst nach dem Onboarding an).
        guard !shouldShowOnboarding else { return }
        location.start()
    }

    /// Erlaubnis wurde noch nie gefragt? Dann fragt sie das Onboarding, sonst
    /// laeuft die Ortung direkt weiter (v1: erteilte Permission = kein Onboarding).
    var shouldShowOnboarding: Bool {
        !onboarded && !location.isAuthorized
    }

    /// Beide Knoepfe starten die Ortung: `start()` fragt bei `notDetermined`
    /// selbst nach der Erlaubnis — wie `ensurePermission()` in v1.
    func finishOnboarding() {
        onboarded = true
        location.start()
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
