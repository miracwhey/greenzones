import CoreLocation
import Foundation
import GreenZonesKit

/// Screenshot-Routen (SPEC 12). Nur `#if DEBUG` — im Release existiert der
/// Fixture-Pfad nicht, damit kein Beweisbild je einen Zustand zeigen kann, den
/// die ausgelieferte App nicht bauen kann.
enum DebugRoute: String {
    case map
    case statusDetail = "status_detail"
    case info
    // W2
    case search
    case searchResults = "search_results"
    case searchOffline = "search_offline"
    case target
    case targetDetail = "target_detail"

    // W3: Community. Jede Route faehrt denselben Zustand an, den auch die Taps
    // setzen — kein Sonderrendering, nur derselbe State auf einem Fixture-Bestand.
    case mapSpots = "map_spots"
    case newspot
    case pick
    case detail
    /// Erstnutzer: 0 Freunde, lokaler Spot → Detail muss in den
    /// Freund-einladen-Flow fuehren (keine Sackgasse).
    case solo
    case invite
    /// Einladung abgeschickt — in W3 ohne CloudKit der ehrliche Abbruch.
    case sent
    case manage
    case reply
    case friends
    case profile
    case profileEmpty = "profile_empty"
    case welcome

    /// Alle Routen, die mit offener Suche starten.
    var opensSearch: Bool {
        self == .search || self == .searchResults || self == .searchOffline
    }
}

enum DebugEnvironment {
    /// Position der Fixture-Laeufe: Maschsee-Nordufer, Hannover.
    static let fixtureCoordinate = CLLocationCoordinate2D(latitude: 52.3595, longitude: 9.7400)

    #if DEBUG
    private static let environment = ProcessInfo.processInfo.environment

    /// `GZ_FIXTURES=1`: fester Standort statt CLLocation, kein Berechtigungsdialog.
    static var usesFixtures: Bool { environment["GZ_FIXTURES"] == "1" }

    /// `GZ_ACCURACY=<m>`: Genauigkeit der Fixture-Position. Ohne den Schalter
    /// liegt sie bei 12 m — der Genauigkeits-Ring waere dann kleiner als die
    /// Sichtbarkeitsschwelle und im Screenshot nicht pruefbar.
    static var fixtureAccuracyM: Double {
        environment["GZ_ACCURACY"].flatMap(Double.init) ?? 12
    }

    static var route: DebugRoute {
        environment["GZ_ROUTE"].flatMap(DebugRoute.init(rawValue:)) ?? .map
    }

    // MARK: - W2: Suche im Screenshot

    /// Adress-Antwort der Suchroute — der Shot darf kein Netz brauchen.
    /// `search_offline` liefert stattdessen den Offline-Ausgang, damit der
    /// Stoerungs-Zustand ohne Flugmodus fotografierbar ist.
    static func photonSource() -> any PhotonSource {
        switch route {
        case .searchResults, .target, .targetDetail:
            return FixturePhoton(outcome: .ok(fixtureAddresses))
        case .searchOffline:
            return FixturePhoton(outcome: .failure(.offline))
        default:
            return PhotonClient()
        }
    }

    /// Erfundene Adressen in Hannover — keine echte Person, kein echtes Haus.
    static let fixtureAddresses: [SearchResult] = [
        SearchResult(name: "Maschstraße", detail: "30169, Hannover, Niedersachsen",
                     lng: 9.7392, lat: 52.3562, source: .photon),
        SearchResult(name: "Maschseepromenade", detail: "30169, Hannover, Niedersachsen",
                     lng: 9.7449, lat: 52.3521, source: .photon),
    ]

    /// Zwei Recents fuer die leere Suche.
    static let fixtureRecents: [SearchResult] = [
        SearchResult(name: "Maschsee", detail: "See · Hannover",
                     lng: 9.7444, lat: 52.3528, source: .place),
        SearchResult(name: "Von-Alten-Garten", detail: "Park · Hannover",
                     lng: 9.7114, lat: 52.3641, source: .place),
    ]

    /// Ziel der Routen `target` / `target_detail`.
    static let fixtureTarget = SearchResult(name: "Maschsee", detail: "See · Hannover",
                                            lng: 9.7444, lat: 52.3528, source: .place)

    /// Vorbelegte Query der Route `search_results` / `search_offline`.
    static let fixtureQuery = "masch"
    #else
    static var usesFixtures: Bool { false }
    static var route: DebugRoute { .map }
    static func photonSource() -> any PhotonSource { PhotonClient() }
    #endif
}

#if DEBUG
/// Photon-Ersatz fuer Screenshots: liefert immer denselben Ausgang, ohne Netz.
struct FixturePhoton: PhotonSource {
    let outcome: PhotonOutcome
    func search(_ query: String) async -> PhotonOutcome { outcome }
}
#endif
