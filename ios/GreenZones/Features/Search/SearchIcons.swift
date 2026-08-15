import SwiftUI

// Die Strich-Symbole der Suche — dieselben SVG-Pfade wie v1 `SearchBar.tsx`,
// damit der Look nicht ueber SF-Symbole driftet (W1-Regel). Zwei davon haben
// echte Kurven; `VectorIcon` kann nur Linien und Kreise, deshalb stehen sie
// hier als eigene Shapes statt als grob genaeherte Polygonzuege.

// W2: zwei Flaechenwerte, die es vor der Suche nicht gab — Werte aus
// `client/src/App.css` (`.scrim`, `.search .clear`), Aufbau wie die Tokens in
// `Design/DesignTokens.swift`.
extension GZ {
    /// Backdrop hinter der offenen Suche: deckt Status-Bar, FABs und Sheets mit ab.
    static let scrim = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0, alpha: 0.32)
        : UIColor(red: 23 / 255, green: 25 / 255, blue: 28 / 255, alpha: 0.18) })

    /// Fuellung der grauen Chips (X im Suchfeld). Auf dunklem Glas umgekehrt.
    static let chipFill = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.22)
        : UIColor(red: 23 / 255, green: 25 / 255, blue: 28 / 255, alpha: 0.14) })
}

extension VectorIcon {
    /// Ausrufezeichen im Kreis (Ortsverzeichnis-Fehler): „circle r=8.5",
    /// „M12 7.5V13", Punkt bei (12, 16.2).
    static let warning = VectorIcon(
        segments: [[CGPoint(x: 12, y: 7.5), CGPoint(x: 12, y: 13)]],
        circles: [(CGPoint(x: 12, y: 12), 8.5), (CGPoint(x: 12, y: 16.2), 0.5)])

    /// Lupe: „circle cx=11 cy=11 r=7" + „m20 20-3.8-3.8".
    static let lens = VectorIcon(
        segments: [[CGPoint(x: 20, y: 20), CGPoint(x: 16.2, y: 16.2)]],
        circles: [(CGPoint(x: 11, y: 11), 7)])

    /// Haus (Adress-Treffer): „M4 20h16M6 20V6.5L12 3l6 3.5V20M10 20v-4h4v4".
    static let address = VectorIcon(segments: [
        [CGPoint(x: 4, y: 20), CGPoint(x: 20, y: 20)],
        [CGPoint(x: 6, y: 20), CGPoint(x: 6, y: 6.5), CGPoint(x: 12, y: 3),
         CGPoint(x: 18, y: 6.5), CGPoint(x: 18, y: 20)],
        [CGPoint(x: 10, y: 20), CGPoint(x: 10, y: 16), CGPoint(x: 14, y: 16),
         CGPoint(x: 14, y: 20)],
    ])
}

/// Karten-Nadel des Orts-Treffers (v1: `M12 21s-6.5-5.2-6.5-10a6.5 6.5 0 0 1 13 0…`
/// plus Loch bei (12, 10.6)). Die Flanken sind Quadratkurven — als Polygonzug
/// bekaeme die Nadel bei 15 pt sichtbare Ecken.
struct PlacePinIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * scale, y: y * scale)
        }
        var path = Path()
        let tip = point(12, 21)
        path.move(to: tip)
        path.addQuadCurve(to: point(5.5, 10.6), control: point(6.6, 17.6))
        path.addArc(center: point(12, 10.6), radius: 6.5 * scale,
                    startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        path.addQuadCurve(to: tip, control: point(17.4, 17.6))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: (12 - 2.3) * scale, y: (10.6 - 2.3) * scale,
                                   width: 4.6 * scale, height: 4.6 * scale))
        return path
    }
}

/// Durchgestrichene Funkwellen („Kein Internet"). Die drei Boegen sind
/// Quadratkurven mit derselben Pfeilhoehe wie die SVG-Arcs in v1.
struct NoNetIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * scale, y: y * scale)
        }
        var path = Path()
        // Sehne 20 bei r 15 → Pfeilhoehe 3,8; die Kontrolle liegt doppelt so hoch.
        path.move(to: point(2, 8.5))
        path.addQuadCurve(to: point(22, 8.5), control: point(12, 0.86))
        path.move(to: point(5.5, 12.5))
        path.addQuadCurve(to: point(18.5, 12.5), control: point(12, 7.7))
        path.move(to: point(9, 16.2))
        path.addQuadCurve(to: point(15, 16.2), control: point(12, 14.2))
        path.move(to: point(4, 4))
        path.addLine(to: point(20, 20))
        return path
    }
}
