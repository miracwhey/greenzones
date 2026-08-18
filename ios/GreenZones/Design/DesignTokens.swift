import SwiftUI
import UIKit

// Design-Tokens 1:1 aus v1 `client/src/theme.css`.
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

    /// `--divider`: eine Spur leiser als `--stroke`.
    static let divider = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.07)
        : UIColor(gzHex: 0x17_191C).withAlphaComponent(0.06) })

    // Zonen-Farben der Karte (SPEC 5.6) — dieselben Werte wie oben, aber als
    // eigene Namen, damit der Karten-Code nicht ueber „ban == Statusfarbe" stolpert.
    static let uiZoneBan = uiBan
    static let uiZoneTime = uiTime

    // MARK: - Federn
    //
    // Drei Massen statt einer Kurve. Bis zum 18.08. trug ein einziger Wert
    // (0.40/0.85) Blatt, Kachel, Toast und Statuszeile gleichermassen — ein
    // Blatt wirkt damit nervoes und eine Marke traege, weil beide dieselbe Zeit
    // brauchen. Die Werte sind aus dem abgenommenen Prototyp (`mockup/motion-v6.html`,
    // Szene D stellt sie nebeneinander), nicht geschaetzt.
    //
    // Zuordnung: was gross ist und den Blick traegt, faellt unter `sheetSpring`;
    // was eine Strecke zuruecklegt (Kachel, Pin, Band, das wandernde Bild) unter
    // `elementSpring`; was nur an- oder umschaltet (Toast, Zaehler, Marke, ein
    // Druckpunkt) unter `microSpring`.

    /// Blatt — traeger, kein Nachwippen. Bottom-Sheets, Vollbild-Ruckfeder.
    static let sheetSpring = gzSpring(sheetFeder)

    /// Element — Kachel, Pin, Band, Morph. Die Feder der wandernden Dinge.
    static let elementSpring = gzSpring(elementFeder)

    /// Mikro — Toast, Zaehler, Marke, Druckpunkt. Kurz genug, um nicht zu warten.
    static let microSpring = gzSpring(microFeder)

    /// Die drei Federn als reine Zahlen. Von hier bedienen sich SwiftUI UND die
    /// UIKit-Ansichten der Karte — ein Pin, der seine eigene Feder mitbraechte,
    /// waere eine vierte, die niemand mitpflegt.
    ///
    /// Am Geraet gekuerzt (18.08., Leon: „Animationen insgesamt zu langsam").
    /// Vorher 0.52 / 0.36 / 0.22 — die Werte kamen aus dem Prototyp am
    /// Schreibtisch. Gekuerzt ist **nur** `response`, alle drei um denselben
    /// Faktor (~0.73): das Verhaeltnis der drei Massen zueinander bleibt, und
    /// weil `dampingFraction` unangetastet ist, ist es dieselbe Kurve auf einer
    /// gestauchten Zeitachse — schneller, nicht anders.
    typealias Feder = (response: Double, damping: Double)
    static let sheetFeder: Feder = (0.38, 0.90)
    static let elementFeder: Feder = (0.27, 0.82)
    static let microFeder: Feder = (0.16, 0.80)

    /// Dieselbe Feder fuer eine UIKit-Ansicht. `bounce` ist die Gegengroesse zur
    /// Daempfung: `spring(response:dampingFraction:)` und
    /// `animate(springDuration:bounce:)` beschreiben denselben gedaempften
    /// Oszillator, nur anders benannt. Die Zeitlupe gilt hier genauso — sonst
    /// waere die halbe Bewegung der Karte nicht fotografierbar.
    static func uiAnimate(_ feder: Feder, delay: Double = 0,
                          _ body: @escaping () -> Void,
                          completion: (() -> Void)? = nil) {
        UIView.animate(springDuration: feder.response * slowmo,
                       bounce: 1 - feder.damping,
                       delay: delay * slowmo,
                       options: [.allowUserInteraction],
                       animations: body) { _ in completion?() }
    }

    /// Zeitlupe fuer die Bildabnahme: `GZ_SLOWMO=<faktor>` dehnt jede Feder um
    /// diesen Faktor. Eine Feder mit `response × N` ist **dieselbe Kurve**, nur
    /// auf der Zeitachse gestreckt — `dampingFraction` bleibt, also auch die
    /// Form. Nur so ist Bewegung ueberhaupt fotografierbar: ein Screenshot
    /// trifft keine 120-ms-Marke, eine 1,2-s-Marke schon.
    ///
    /// Was die Zeitlupe NICHT beweist: die absolute Dauer. Die steht in den drei
    /// Werten oben und ist nur dort zu pruefen.
    static let slowmo: Double = {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["GZ_SLOWMO"].flatMap(Double.init) ?? 1
        return value > 0 ? value : 1
        #else
        return 1
        #endif
    }()

    private static func gzSpring(_ feder: Feder) -> Animation {
        .spring(response: feder.response * slowmo, dampingFraction: feder.damping)
    }

    /// `--shadow-1` / `--shadow-2` aus theme.css.
    static func shadow1<V: View>(_ view: V) -> some View {
        view.shadow(color: .black.opacity(0.10), radius: 8, y: 4)
    }

    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Statuswechsel wie v1 `hapticStatus`: Erfolg vs. Warnung.
    static func hapticStatus(ok: Bool) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(ok ? .success : .warning)
    }
}

/// Glas-Flaeche der Design-Sprache: Material + 1-px-Kontur + weicher Schatten.
/// `.regularMaterial` fuer Flaechen (Bar, Sheets), `.ultraThinMaterial` fuer
/// Chips und FABs (SPEC 9).
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat
    var material: Material = .regularMaterial
    var shadowRadius: CGFloat = 16
    var shadowOpacity: Double = 0.14

    func body(content: Content) -> some View {
        content
            .background(material, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(GZ.stroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: 8)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat,
                   material: Material = .regularMaterial,
                   shadowRadius: CGFloat = 16,
                   shadowOpacity: Double = 0.14) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, material: material,
                           shadowRadius: shadowRadius, shadowOpacity: shadowOpacity))
    }
}

/// Strich-Symbole aus v1 (die SVG-Pfade der Komponenten), damit der Look nicht
/// ueber SF-Symbole driftet. `viewBox` ist bei allen 24×24.
struct VectorIcon: Shape {
    /// Segmente in viewBox-Koordinaten; jedes Segment ist ein eigener Linienzug.
    let segments: [[CGPoint]]
    /// Kreise (Mittelpunkt + Radius) in viewBox-Koordinaten.
    var circles: [(CGPoint, CGFloat)] = []

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        for segment in segments {
            guard let first = segment.first else { continue }
            path.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
            for point in segment.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale))
            }
        }
        for (center, radius) in circles {
            path.addEllipse(in: CGRect(x: (center.x - radius) * scale,
                                       y: (center.y - radius) * scale,
                                       width: radius * 2 * scale,
                                       height: radius * 2 * scale))
        }
        return path
    }
}

extension VectorIcon {
    /// „M4.5 12.5l5 5 10-11"
    static let check = VectorIcon(segments: [[CGPoint(x: 4.5, y: 12.5),
                                              CGPoint(x: 9.5, y: 17.5),
                                              CGPoint(x: 19.5, y: 6.5)]])
    /// „M6 6l12 12M18 6L6 18"
    static let cross = VectorIcon(segments: [[CGPoint(x: 6, y: 6), CGPoint(x: 18, y: 18)],
                                             [CGPoint(x: 18, y: 6), CGPoint(x: 6, y: 18)]])
    /// „m6 14 6-6 6 6"
    static let chevronUp = VectorIcon(segments: [[CGPoint(x: 6, y: 14),
                                                  CGPoint(x: 12, y: 8),
                                                  CGPoint(x: 18, y: 14)]])
    /// Schloss der Verbotszone: „M4 10h16v9H4zM8 10V7a4 4 0 0 1 8 0v3"
    /// (Buegel als Polygonzug angenaehert — bei 17 pt nicht unterscheidbar).
    static let lock = VectorIcon(segments: [
        [CGPoint(x: 4, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 20, y: 19),
         CGPoint(x: 4, y: 19), CGPoint(x: 4, y: 10)],
        [CGPoint(x: 8, y: 10), CGPoint(x: 8, y: 7), CGPoint(x: 8.6, y: 5.4),
         CGPoint(x: 10.2, y: 4.2), CGPoint(x: 12, y: 3.8), CGPoint(x: 13.8, y: 4.2),
         CGPoint(x: 15.4, y: 5.4), CGPoint(x: 16, y: 7), CGPoint(x: 16, y: 10)],
    ])
    /// Uhr der Fussgaengerzone: Kreis + Zeiger.
    static let clock = VectorIcon(
        segments: [[CGPoint(x: 12, y: 7.5), CGPoint(x: 12, y: 12), CGPoint(x: 15, y: 14)]],
        circles: [(CGPoint(x: 12, y: 12), 8.5)])
    /// Zielkreuz des Zentrieren-FAB.
    static let locate = VectorIcon(
        segments: [[CGPoint(x: 12, y: 3), CGPoint(x: 12, y: 5)],
                   [CGPoint(x: 12, y: 19), CGPoint(x: 12, y: 21)],
                   [CGPoint(x: 3, y: 12), CGPoint(x: 5, y: 12)],
                   [CGPoint(x: 19, y: 12), CGPoint(x: 21, y: 12)]],
        circles: [(CGPoint(x: 12, y: 12), 6)])
    /// „i" im Kreis.
    static let info = VectorIcon(
        segments: [[CGPoint(x: 12, y: 11), CGPoint(x: 12, y: 16)]],
        circles: [(CGPoint(x: 12, y: 12), 8.5), (CGPoint(x: 12, y: 7.6), 0.55)])
    /// Verbots-Kreis mit Schraegstrich (Onboarding).
    static let banMark = VectorIcon(
        segments: [[CGPoint(x: 6, y: 6), CGPoint(x: 18, y: 18)]],
        circles: [(CGPoint(x: 12, y: 12), 8.5)])
    /// Kamera des Snap-FAB: Gehaeuse mit Sucherbuckel, Objektiv als Kreis.
    /// Der Buckel ist ein Polygonzug — `VectorIcon` kennt nur Linien und
    /// Ellipsen; bei 24 pt und rundem Linienabschluss ist die fehlende Rundung
    /// nicht zu sehen (im Bild geprueft).
    static let camera = VectorIcon(
        segments: [[CGPoint(x: 3, y: 7.5), CGPoint(x: 8.5, y: 7.5), CGPoint(x: 10, y: 5),
                    CGPoint(x: 14, y: 5), CGPoint(x: 15.5, y: 7.5), CGPoint(x: 21, y: 7.5),
                    CGPoint(x: 21, y: 19), CGPoint(x: 3, y: 19), CGPoint(x: 3, y: 7.5)]],
        circles: [(CGPoint(x: 12, y: 13.25), 3.6)])
}
