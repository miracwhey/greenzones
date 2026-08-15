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
    private let clock: GZClock
    private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "status")

    private(set) var status: ZoneStatus?
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
        let migrations: [DBMigration] = []
        do {
            // Fixture-Laeufe (Screenshots) schreiben nichts auf die Platte.
            database = try fixtureCoordinate != nil
                ? AppDatabase.inMemory(migrations: migrations)
                : AppDatabase(path: AppDatabase.defaultPath(), migrations: migrations)
        } catch {
            // Ohne DB laeuft die App nicht sinnvoll — laut scheitern statt still leer.
            fatalError("App-DB startet nicht: \(error)")
        }
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
        StatusPresentation(status: status,
                           locating: location.state.isLocating,
                           denied: location.state == .denied,
                           hour: hour)
    }

    // MARK: - Lebenszyklus

    func start() {
        startTick()
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

    // MARK: - Status

    /// Wird bei jeder Standort-Aenderung aufgerufen; rechnet aber nur, wenn sich
    /// wirklich etwas geaendert hat (≥ 15 m oder noch gar kein Ergebnis).
    func locationChanged() {
        guard let coordinate = location.state.coordinate, let engine else { return }
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
