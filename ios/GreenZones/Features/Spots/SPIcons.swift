import SwiftUI

/// Strich-Symbole der Community-Sheets — dieselben SVG-Pfade wie in v1
/// (`SpotSheets.tsx`, `App.tsx`). `VectorIcon` aus W1 kann nur Linienzuege und
/// Kreise; die Pin-, Glocken- und Personen-Symbole brauchen Bezier-Kurven,
/// deshalb ein eigener Shape statt gerader Naeherungen.
///
/// Bezugsraster ist wie in v1 die 24×24-viewBox (Fadenkreuz: 54×54).
struct SPIcon: Shape {
    enum Kind {
        /// Kreis mit „!" — der Hinweis-Punkt der `.sp-note`-Zeilen.
        case note
        case check
        case cross
        case pin
        case share
        case bell
        case clock
        case pencil
        /// Personen-Silhouette im leeren Avatar.
        case person
        /// FAB „Freunde".
        case friends
        /// FAB „Spot markieren" (Pin mit Plus).
        case spotAdd
        /// Fadenkreuz im Pick-Modus (viewBox 54).
        case crosshair
    }

    let kind: Kind

    private var viewBox: CGFloat { kind == .crosshair ? 54 : 24 }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / viewBox
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        var path = Path()

        switch kind {
        case .note:
            path.addEllipse(in: CGRect(x: 3.5 * s, y: 3.5 * s, width: 17 * s, height: 17 * s))
            path.move(to: p(12, 8))
            path.addLine(to: p(12, 13))
            path.move(to: p(12, 16.2))
            path.addLine(to: p(12, 16.5))

        case .check:
            path.move(to: p(4.5, 12.5))
            path.addLine(to: p(9.5, 17.5))
            path.addLine(to: p(19.5, 6.5))

        case .cross:
            path.move(to: p(6, 6))
            path.addLine(to: p(18, 18))
            path.move(to: p(18, 6))
            path.addLine(to: p(6, 18))

        case .pin, .spotAdd:
            // Tropfen: Bogen ueber dem Kopf, zwei Kurven auf die Spitze.
            path.move(to: p(12, 21))
            path.addCurve(to: p(5.5, 11), control1: p(8.4, 17.4), control2: p(5.5, 13.7))
            path.addArc(center: p(12, 11), radius: 6.5 * s,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addCurve(to: p(12, 21), control1: p(18.5, 13.7), control2: p(15.6, 17.4))
            path.closeSubpath()
            if kind == .spotAdd {
                path.move(to: p(12, 8))
                path.addLine(to: p(12, 14))
                path.move(to: p(9, 11))
                path.addLine(to: p(15, 11))
            } else {
                path.addEllipse(in: CGRect(x: (12 - 2.4) * s, y: (10.5 - 2.4) * s,
                                           width: 4.8 * s, height: 4.8 * s))
            }

        case .share:
            path.move(to: p(12, 15))
            path.addLine(to: p(12, 4))
            path.move(to: p(8, 7.5))
            path.addLine(to: p(12, 3.5))
            path.addLine(to: p(16, 7.5))
            path.move(to: p(5, 12))
            path.addLine(to: p(5, 19))
            path.addLine(to: p(19, 19))
            path.addLine(to: p(19, 12))

        case .bell:
            path.move(to: p(6, 9))
            path.addArc(center: p(12, 9), radius: 6 * s,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addCurve(to: p(20, 15), control1: p(18, 13.4), control2: p(19.2, 15))
            path.addLine(to: p(4, 15))
            path.addCurve(to: p(6, 9), control1: p(4.8, 15), control2: p(6, 13.4))
            path.move(to: p(10, 20))
            path.addQuadCurve(to: p(14, 20), control: p(12, 21.6))

        case .clock:
            path.addEllipse(in: CGRect(x: 3.5 * s, y: 3.5 * s, width: 17 * s, height: 17 * s))
            path.move(to: p(12, 7.5))
            path.addLine(to: p(12, 12))
            path.addLine(to: p(15, 14))

        case .pencil:
            path.move(to: p(4, 20))
            path.addLine(to: p(8, 20))
            path.addLine(to: p(19.5, 8.5))
            path.addCurve(to: p(16.5, 5.5), control1: p(20.7, 7.3), control2: p(19.4, 4.4))
            path.addLine(to: p(5, 17))
            path.closeSubpath()

        case .person:
            path.addEllipse(in: CGRect(x: 8 * s, y: 4 * s, width: 8 * s, height: 8 * s))
            path.move(to: p(4.5, 20.5))
            path.addCurve(to: p(12, 14.5), control1: p(5.7, 16.5), control2: p(8.5, 14.5))
            path.addCurve(to: p(19.5, 20.5), control1: p(15.5, 14.5), control2: p(18.3, 16.5))

        case .friends:
            path.addEllipse(in: CGRect(x: (9.5 - 3.4) * s, y: (8.5 - 3.4) * s,
                                       width: 6.8 * s, height: 6.8 * s))
            path.move(to: p(3.5, 19.5))
            path.addCurve(to: p(9.5, 14.5), control1: p(3.5, 16.4), control2: p(6.2, 14.5))
            path.addCurve(to: p(15.5, 19.5), control1: p(12.8, 14.5), control2: p(15.5, 16.4))
            path.move(to: p(16, 5.6))
            path.addCurve(to: p(16, 12.2), control1: p(18.3, 6.4), control2: p(18.3, 11.4))
            path.move(to: p(17.5, 14.9))
            path.addCurve(to: p(20.9, 19.5), control1: p(19.5, 15.5), control2: p(20.9, 17.1))

        case .crosshair:
            path.addEllipse(in: CGRect(x: 14 * s, y: 14 * s, width: 26 * s, height: 26 * s))
            path.move(to: p(27, 2)); path.addLine(to: p(27, 12))
            path.move(to: p(27, 42)); path.addLine(to: p(27, 52))
            path.move(to: p(2, 27)); path.addLine(to: p(12, 27))
            path.move(to: p(42, 27)); path.addLine(to: p(52, 27))
        }
        return path
    }
}

extension SPIcon {
    /// Standard-Darstellung: Kontur in `color`, Groesse `size`.
    func stroked(_ color: Color, size: CGFloat, width: CGFloat = 1.9) -> some View {
        stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}
