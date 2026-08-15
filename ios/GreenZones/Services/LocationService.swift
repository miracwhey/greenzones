import CoreLocation
import Foundation
import os

/// Live-Standort. Port der Zustaende aus v1 `client/src/lib/location.ts`
/// (`useLocation`) auf `CLLocationManager` — jede Stoerung bleibt sichtbar,
/// „locating" wird nie zur Dauer-Ausrede.
enum LocationState: Equatable {
    case idle
    case locating
    case ready(coordinate: CLLocationCoordinate2D, accuracyM: Double)
    case denied
    case error(String)

    var coordinate: CLLocationCoordinate2D? {
        if case .ready(let coordinate, _) = self { return coordinate }
        return nil
    }

    var accuracyM: Double {
        if case .ready(_, let accuracy) = self { return accuracy }
        return 50
    }

    /// v1: „wird ermittelt …" gilt fuer idle UND locating.
    var isLocating: Bool { self == .idle || self == .locating }

    static func == (lhs: LocationState, rhs: LocationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.locating, .locating), (.denied, .denied):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        case (.ready(let ca, let aa), .ready(let cb, let ab)):
            return ca.latitude == cb.latitude && ca.longitude == cb.longitude && aa == ab
        default:
            return false
        }
    }
}

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var state: LocationState = .idle

    private let manager = CLLocationManager()
    private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "location")
    private var started = false
    /// Fixture-Betrieb (`GZ_FIXTURES=1`): fester Punkt, kein Dialog, kein GPS.
    private let fixedCoordinate: CLLocationCoordinate2D?
    private let fixedAccuracyM: Double

    init(fixedCoordinate: CLLocationCoordinate2D? = nil, fixedAccuracyM: Double = 12) {
        self.fixedCoordinate = fixedCoordinate
        self.fixedAccuracyM = fixedAccuracyM
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Wie v1: erst ab 5 m Bewegung ein neues Ereignis.
        manager.distanceFilter = 5
    }

    /// Startet die Ortung. Idempotent — ein zweiter Aufruf ist ein No-Op.
    func start() {
        guard !started else { return }
        started = true

        if let fixedCoordinate {
            state = .ready(coordinate: fixedCoordinate, accuracyM: fixedAccuracyM)
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            state = .locating
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            state = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            state = .locating
            manager.startUpdatingLocation()
        @unknown default:
            state = .locating
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Erlaubnis aktiv anfragen (Onboarding-Knopf).
    func requestPermission() {
        guard fixedCoordinate == nil else { return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        start()
    }

    var isAuthorizationDetermined: Bool {
        fixedCoordinate != nil || manager.authorizationStatus != .notDetermined
    }

    var isAuthorized: Bool {
        if fixedCoordinate != nil { return true }
        return manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                if self.state == .denied || self.state == .idle { self.state = .locating }
                manager.startUpdatingLocation()
            case .denied, .restricted:
                manager.stopUpdatingLocation()
                self.state = .denied
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coordinate = last.coordinate
        // Negative Genauigkeit = ungueltige Messung; v1 fiel auf 50 m zurueck.
        let accuracy = last.horizontalAccuracy > 0 ? last.horizontalAccuracy : 50
        Task { @MainActor in
            self.state = .ready(coordinate: coordinate, accuracyM: accuracy)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in
            self.logger.error("Standort-Fehler: \(message, privacy: .public)")
            // Ein einzelner „unknown"-Fehler ist normal, solange noch keine Fixe
            // da ist — er darf einen bereits gueltigen Standort nicht loeschen.
            if denied {
                self.state = .denied
            } else if self.state.coordinate == nil {
                self.state = .error(message)
            }
        }
    }
}
