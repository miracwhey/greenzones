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

    // W5: Snaps. Album, Kamera (frei und am Spot), Betrachter, Melden, freie
    // Pins — jede Route faehrt denselben Zustand an wie ein Tap.
    /// Karte mit freien Snap-Pins.
    case freesnap
    /// Kamera ohne Spot in Reichweite: Chip „Auf der Karte", kein Schalter.
    case camera
    /// Kamera aus dem Spot-Blatt: Kontext-Chip + Sichtbarkeits-Schalter.
    case cameraSpot = "camera_spot"
    case viewer
    /// Betrachter mit offenem Melden-Dialog.
    case report
    /// Bewegung B: Betrachter geht aus der Album-Kachel hervor. Eigene Route,
    /// weil `viewer` ihn ohne Blatt darunter oeffnet — dort gibt es keine
    /// Kachel, aus der etwas hervorgehen koennte, und die vorhandenen
    /// Beweisbilder sollen unveraendert bleiben.
    case viewerTile = "viewer_tile"
    /// Bewegung E: Betrachter geht aus dem freien Snap-Pin hervor. Der Pin
    /// TRAEGT das Foto bereits — es aufblenden zu lassen verschenkt genau den
    /// Zusammenhang, den er schon zeigt.
    case viewerPin = "viewer_pin"
    /// Der Rueckweg: Betrachter steht, dann schliesst er und das Bild faehrt in
    /// seine Kachel zurueck. Eigene Route, weil die Startmarke nur EINMAL faellt
    /// — sie gehoert hier ans Schliessen, nicht ans Oeffnen.
    case viewerTileBack = "viewer_tile_back"
    /// Bewegung A: ein Snap kommt am Spot dazu — der Faecher des Pins macht ihm
    /// Platz, der Pin nimmt den Stoss auf, der Zaehler quittiert.
    case spotSnap = "spot_snap"
    /// Bewegung C: Ausloeser → Karte. Das Bild verlaesst den Sucher und fliegt
    /// an seinen Platz, der Pin uebernimmt dort.
    case freeSnapLand = "free_snap_land"

    /// Routen, deren zu messender Uebergang NICHT der erste Zustandswechsel
    /// ist: `viewer_tile` oeffnet zuerst das Blatt und erst danach den
    /// Betrachter. Sie setzen die Startmarke selbst — sonst zaehlte das
    /// Bildwerkzeug ab dem Blatt und traefe den Morph nie.
    var announcesMotionItself: Bool {
        self == .viewerTile || self == .viewerTileBack || self == .spotSnap
            || self == .freeSnapLand
    }

    /// Alle Routen, die mit offener Suche starten.
    var opensSearch: Bool {
        self == .search || self == .searchResults || self == .searchOffline
    }

    /// Routen, die Snaps im Bestand brauchen.
    var needsSnaps: Bool {
        switch self {
        case .detail, .manage, .solo, .viewer, .viewerTile, .report, .camera, .cameraSpot,
             .freesnap, .viewerPin, .viewerTileBack, .spotSnap, .freeSnapLand, .mapSpots:
            return true
        default:
            return false
        }
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

    // MARK: - Bewegung fotografieren

    /// `GZ_UI_SETTLE=<s>`: wie lange die Karte stehen darf, bevor die Route
    /// ihren Zustand setzt. Default 2,2 s — genug fuer die Basemap-Tiles.
    ///
    /// Fuer Bewegungsbilder wird der Wert hochgesetzt: der Uebergang soll erst
    /// starten, wenn alles andere ruhig ist, sonst zeigt der Frame nicht die
    /// Feder, sondern nachladende Kacheln.
    static var uiSettle: Double {
        environment["GZ_UI_SETTLE"].flatMap(Double.init) ?? 2.2
    }

    /// Startmarke fuer `Scripts/frame.sh`. Das Skript kann den Moment der
    /// Ausloesung nicht aus der Prozessuhr ableiten — zwischen `simctl launch`
    /// und dem ersten Frame liegen unbestimmte Hunderte Millisekunden, und
    /// genau die waeren bei einer 400-ms-Bewegung der ganze Messfehler.
    /// Deshalb sagt die App selbst Bescheid, und das Skript zaehlt ab hier.
    ///
    /// Nur einmal: bei `status_detail` und `info` laufen beide Ausloese-Stellen
    /// (`RootView` und `CommunityFixtures`) — zwei Marken, und das Skript
    /// zaehlte ab der falschen.
    @MainActor
    static func motionGo() {
        guard !didAnnounceMotion else { return }
        didAnnounceMotion = true
        // Den Dehnfaktor mitschreiben: ohne ihn im Bild waere nicht zu
        // unterscheiden, ob ein Frame die Bewegung verpasst hat oder ob die
        // Zeitlupe gar nicht angekommen ist.
        NSLog("[GZ-MOTION] go slowmo=\(GZ.slowmo) settle=\(uiSettle)")
    }

    @MainActor private static var didAnnounceMotion = false

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
