import SwiftUI
import CoreLocation
import UIKit

// MARK: - Design-Tokens (1:1 aus v1 `client/src/theme.css`)
//
// Als dynamische UIColor gebaut: hell/dunkel steckt im Token selbst, kein
// colorScheme-Durchreichen durch jede View — und die UIKit-Pin-Views (MapLibre)
// greifen auf dieselbe Quelle zu wie SwiftUI.

extension UIColor {
    fileprivate convenience init(gzHex hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }

    fileprivate static func gzDynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(gzHex: dark) : UIColor(gzHex: light) }
    }
}

enum GZ {
    // Statusfarben — in beiden Schemata identisch (v1: nicht im dark-Block).
    static let uiOk = UIColor(gzHex: 0x1D_B954)
    static let uiBan = UIColor(gzHex: 0xE5_484D)
    static let uiTime = UIColor(gzHex: 0xF7_6B15)
    static let uiAccent = UIColor(gzHex: 0x0A_84FF)

    static let uiInk = UIColor.gzDynamic(light: 0x17_191C, dark: 0xF2_F3F5)
    static let uiInk2 = UIColor.gzDynamic(light: 0x5A_616B, dark: 0xA7_ADB7)
    static let uiInk3 = UIColor.gzDynamic(light: 0x9A_A1AB, dark: 0x6B_7280)
    static let uiAppBg = UIColor.gzDynamic(light: 0xE8_EAED, dark: 0x13_1518)

    static let ok = Color(uiOk)
    static let ban = Color(uiBan)
    static let time = Color(uiTime)
    static let accent = Color(uiAccent)
    static let ink = Color(uiInk)
    static let ink2 = Color(uiInk2)
    static let ink3 = Color(uiInk3)
    static let appBg = Color(uiAppBg)

    /// `--stroke`: ink 8 % hell, weiss 8 % dunkel.
    static let uiStroke = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.08)
        : UIColor(gzHex: 0x17_191C).withAlphaComponent(0.08) }
    static let stroke = Color(uiStroke)

    /// Kamera-Grund (SPEC): `#0B0C0E`.
    static let camBg = Color(UIColor(gzHex: 0x0B_0C0E))

    /// Ein Motion-Wert fuer alles (SPEC).
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.85)

    static func haptic() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        gen.impactOccurred()
    }

    /// Fixture-Foto aus dem Bundle. Erst `named:` (Asset/Resource), dann der
    /// direkte Dateipfad — echte Fotos koennen als lose .jpg eingetauscht werden.
    static func photo(_ name: String) -> UIImage? {
        if let img = UIImage(named: name) { return img }
        if let path = Bundle.main.path(forResource: name, ofType: "jpg") {
            return UIImage(contentsOfFile: path)
        }
        return nil
    }

    /// Deterministische Avatar-Farbe aus dem Namen (gleicher Name = gleiche Farbe).
    static func avatarColor(_ name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.52, brightness: 0.78)
    }

    /// v1-Distanzformat, deutsch: "40 m" / "2,0 km".
    static func distance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        let km = meters / 1000
        return String(format: "%.1f km", km).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Modell

struct Person: Identifiable, Hashable {
    let id: String
    let name: String
    let isMe: Bool
}

struct Snap: Identifiable, Hashable {
    let id: UUID
    /// Dateiname ohne Endung — `snap1` … `snap4`.
    let photo: String
    let author: Person
    let ago: String

    init(id: UUID = UUID(), photo: String, author: Person, ago: String) {
        self.id = id
        self.photo = photo
        self.author = author
        self.ago = ago
    }

    var caption: String { "\(author.name) · \(ago)" }
}

struct Spot: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let coordinate: CLLocationCoordinate2D
    /// Fixture-Distanz zur User-Position (kein Rechnen, statisch laut SPEC).
    let distanceM: Double
    let participants: [Person]
    /// Legal-Zeile wie v1-StatusBar (statische Fixture-Werte).
    let legalTitle: String
    let legalSub: String

    /// Ring-Farbe des Spot-Pins: nah = ok-gruen, fern = ink-3.
    /// (Snappen selbst ist NICHT mehr an Naehe gebunden — Leon-Korrektur.)
    var isNear: Bool { distanceM <= 75 }
    /// Aufnahme-Ort entscheidet: naeher als das, landet ein Snap IM Spot.
    var withinCaptureRadius: Bool { distanceM <= Fixtures.captureRadiusM }
    var distanceLabel: String { GZ.distance(distanceM) }

    static func == (a: Spot, b: Spot) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Snap ohne Spot — eigener Pin an der Aufnahme-Position.
struct FreeSnap: Identifiable, Hashable {
    let id: UUID
    let snap: Snap
    let latitude: Double
    let longitude: Double

    init(id: UUID = UUID(), snap: Snap, latitude: Double, longitude: Double) {
        self.id = id
        self.snap = snap
        self.latitude = latitude
        self.longitude = longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Woher die im Viewer gezeigten Snaps kommen.
enum SnapSource: Equatable {
    case spot(String)
    case free(UUID)
}

/// Aufnahme-Kontext der Kamera — bestimmt Chip UND wohin der Snap faellt.
enum CameraContext: Equatable, Hashable {
    case spot(Spot)
    case free

    var chipEmoji: String {
        switch self {
        case .spot(let spot): return spot.emoji
        case .free: return "📍"
        }
    }

    var chipTitle: String {
        switch self {
        case .spot(let spot): return spot.name
        case .free: return "Neuer Snap hier"
        }
    }
}

enum Fixtures {
    static let me = Person(id: "leon", name: "Leon", isMe: true)
    static let tara = Person(id: "tara", name: "Tara", isMe: false)
    static let robert = Person(id: "robert", name: "Robert", isMe: false)

    /// Mockup-Schwelle: innerhalb landet ein Snap im Spot, sonst wird er ein
    /// freier Pin. Die Fixture-Distanz zu Spot A (40 m) liegt bewusst darueber —
    /// der Plus-FAB demonstriert damit den Frei-Pfad.
    static let captureRadiusM: Double = 30

    /// Blauer Puck — statisch, nahe Maschsee-Nordufer.
    static let userCoordinate = CLLocationCoordinate2D(latitude: 52.3595, longitude: 9.7400)

    static let spotA = Spot(
        id: "A",
        name: "Unsere Bank",
        emoji: "🌳",
        coordinate: CLLocationCoordinate2D(latitude: 52.3592, longitude: 9.7412),
        distanceM: 40,
        participants: [me, tara, robert],
        legalTitle: "Hier erlaubt",
        legalSub: "Fußgängerzone 480 m"
    )

    static let spotB = Spot(
        id: "B",
        name: "Küchengarten-Ecke",
        emoji: "☀️",
        coordinate: CLLocationCoordinate2D(latitude: 52.3712, longitude: 9.7135),
        distanceM: 2000,
        participants: [me, tara],
        legalTitle: "Hier erlaubt",
        legalSub: "Fußgängerzone 1,1 km"
    )

    static let spots = [spotA, spotB]

    /// Neuester zuerst — das Album ist die Reihenfolge, in der es gezeigt wird.
    static let snapsA: [Snap] = [
        Snap(photo: "snap1", author: tara, ago: "vor 2 Std"),
        Snap(photo: "snap2", author: me, ago: "vor 5 Std"),
        Snap(photo: "snap3", author: robert, ago: "gestern"),
        Snap(photo: "snap4", author: tara, ago: "vor 3 Tagen"),
    ]

    /// Freie Snaps ohne Spot — zeigen den Frei-Pin-Look auf der Karte.
    static let freeSnaps: [FreeSnap] = [
        FreeSnap(snap: Snap(photo: "snap3", author: tara, ago: "vor 1 Std"),
                 latitude: 52.3641, longitude: 9.7448),
        FreeSnap(snap: Snap(photo: "snap4", author: robert, ago: "gestern"),
                 latitude: 52.3555, longitude: 9.7365),
    ]
}

// MARK: - Zustand

@Observable
final class MockStore {
    var spots: [Spot] = Fixtures.spots
    private(set) var snaps: [String: [Snap]] = [
        Fixtures.spotA.id: Fixtures.snapsA,
        Fixtures.spotB.id: [],
    ]
    private(set) var freeSnaps: [FreeSnap] = Fixtures.freeSnaps
    /// Gemeldete Snaps — im Mockup real ausgeblendet.
    private(set) var hidden: Set<UUID> = []
    var toast: String?

    func visibleSnaps(_ spotID: String) -> [Snap] {
        (snaps[spotID] ?? []).filter { !hidden.contains($0.id) }
    }

    func visibleFreeSnaps() -> [FreeSnap] {
        freeSnaps.filter { !hidden.contains($0.snap.id) }
    }

    func visibleSnaps(_ source: SnapSource) -> [Snap] {
        switch source {
        case .spot(let spotID):
            return visibleSnaps(spotID)
        case .free(let id):
            return freeSnaps
                .filter { $0.id == id && !hidden.contains($0.snap.id) }
                .map(\.snap)
        }
    }

    /// Der Snap, den die Mockup-Kamera „aufnimmt".
    private func capturedSnap() -> Snap {
        Snap(photo: "snap2", author: Person(id: "leon", name: "Ich", isMe: true), ago: "Jetzt")
    }

    /// Auslöser mit Spot-Kontext: neuer Snap ganz vorn im Album.
    @discardableResult
    func addSnap(spotID: String) -> Snap {
        let snap = capturedSnap()
        snaps[spotID, default: []].insert(snap, at: 0)
        return snap
    }

    /// Auslöser ohne Spot: eigener Pin an der Aufnahme-Position.
    @discardableResult
    func addFreeSnap(at coordinate: CLLocationCoordinate2D) -> FreeSnap {
        let free = FreeSnap(snap: capturedSnap(),
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude)
        freeSnaps.append(free)
        return free
    }

    /// Kamera-Kontext aus dem Aufnahme-Ort — Spot nur innerhalb des Radius.
    func captureContext() -> CameraContext {
        if let spot = spots.first(where: { $0.withinCaptureRadius }) {
            return .spot(spot)
        }
        return .free
    }

    func hide(_ snap: Snap) {
        hidden.insert(snap.id)
    }

    func delete(_ snap: Snap) {
        for key in snaps.keys {
            snaps[key]?.removeAll { $0.id == snap.id }
        }
        freeSnaps.removeAll { $0.snap.id == snap.id }
    }

    func showToast(_ text: String) {
        toast = text
        let shown = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in
            guard let self, self.toast == shown else { return }
            withAnimation(GZ.spring) { self.toast = nil }
        }
    }
}

// MARK: - Pin-Look-Variante
//
// Leon: „die ueberlappenden Fotos dominieren zu sehr" — drei leisere Pin-Looks
// stehen zur Wahl, umschaltbar wie GZ_HOUR/GZ_MOCK ueber die Umgebung.
enum PinStyle: String {
    /// Emoji-Anker: 40-pt-Emoji-Kreis vorn, 2 kleine Foto-Kreise gefaechert dahinter.
    case a
    /// Ein-Foto: 30-pt-Foto-Kreis des neuesten Snaps + 18-pt-Emoji-Chip.
    case b
    /// Zoom-adaptiv: 26-pt-3er-Stack, unter Zoom 13,5 kollabiert zum Emoji-Kreis.
    case c

    /// Einmal gelesen — der Look ist fuer den ganzen Lauf fest, die Pin-Views
    /// bauen ihre Subviews danach.
    static let current = fromEnvironment()

    static func fromEnvironment() -> PinStyle {
        // Leon-Wahl 15.08.: Emoji-Anker ist der gelockte Look.
        guard let raw = ProcessInfo.processInfo.environment["GZ_PIN_STYLE"]?.lowercased(),
              let style = PinStyle(rawValue: raw) else { return .a }
        return style
    }

    /// Zoom-Schwelle und Hysterese der Variante C (gegen Flackern am Umschaltpunkt).
    static let collapseZoom: Double = 13.5
    static let collapseHysteresis: Double = 0.2
}

// MARK: - Screenshot-/Demo-Schalter
//
// `GZ_MOCK` faehrt beim Start denselben Zustand an, den die Taps setzen — kein
// Sonderrendering, nur derselbe State. Fuer die Beweis-Screenshots im Simulator.
enum MockRoute: String {
    case map
    case sheetNear = "sheet_near"
    case sheetFar = "sheet_far"
    case camera
    case viewer
    case report
    /// Plus-FAB → Kamera → Auslöser: Karte mit frischem freien Pin.
    case freesnap

    static func fromEnvironment() -> MockRoute {
        guard let raw = ProcessInfo.processInfo.environment["GZ_MOCK"],
              let route = MockRoute(rawValue: raw) else { return .map }
        return route
    }

    /// Spot, dessen Sheet beim Start geoeffnet wird — nil = Karte bleibt frei.
    var sheetSpot: Spot? {
        switch self {
        case .map, .freesnap: return nil
        case .sheetFar: return Fixtures.spotB
        default: return Fixtures.spotA
        }
    }
}
