import CoreLocation
import Foundation

/// Screenshot-Routen (SPEC 12). Nur `#if DEBUG` — im Release existiert der
/// Fixture-Pfad nicht, damit kein Beweisbild je einen Zustand zeigen kann, den
/// die ausgelieferte App nicht bauen kann.
enum DebugRoute: String {
    case map
    case statusDetail = "status_detail"
    case info
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
    #else
    static var usesFixtures: Bool { false }
    static var route: DebugRoute { .map }
    #endif
}
