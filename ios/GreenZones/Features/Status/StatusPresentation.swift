import GreenZonesKit
import SwiftUI

/// Was die Status-Bar sagt. Texte woertlich aus v1 `StatusBar.tsx` —
/// eine Umformulierung waere eine Rechtsaussage mit anderem Klang.
struct StatusPresentation {
    let kind: StatusKind
    let title: String
    let subtitle: String
    /// W2: zweite Zeile im Detail-Sheet — „Dein Standort" oder das Ziel.
    var contextLine: String = "Dein Standort"

    /// W2: Ziel-Modus — derselbe Status, nur an einem anderen Punkt gerechnet.
    /// Texte woertlich aus v1 `StatusBar.tsx`.
    init(target: SearchResult, status: ZoneStatus?, hour: Int) {
        kind = ZoneStatus.statusKind(status, hour: hour)
        title = status == nil ? "Ziel wird geprüft …"
                              : (kind == .ok ? "Am Ziel erlaubt" : "Am Ziel verboten")
        subtitle = target.targetSubtitle
        contextLine = target.targetSubtitle
    }

    init(status: ZoneStatus?, locating: Bool, denied: Bool, hour: Int) {
        kind = ZoneStatus.statusKind(status, hour: hour)

        if denied {
            title = "Standort nicht freigegeben"
            subtitle = "In den iOS-Einstellungen erlauben"
            return
        }
        guard !locating, let status else {
            title = "Standort wird ermittelt …"
            subtitle = ""
            return
        }
        switch kind {
        case .ban:
            title = "Hier verboten"
            subtitle = "Verbotszone · ganztägig"
        case .time:
            title = "Jetzt verboten"
            subtitle = "Fußgängerzone · frei ab 20:00"
        case .ok:
            title = "Hier erlaubt"
            var parts: [String] = []
            if status.ban.nearestM.isFinite {
                parts.append("Verbotszone \(Geo.formatDistanceM(status.ban.nearestM))")
            }
            if status.time.nearestM.isFinite {
                parts.append("Fußgängerzone \(Geo.formatDistanceM(status.time.nearestM))")
            }
            subtitle = parts.isEmpty ? "Keine Verbotszone im Umkreis von 2 km"
                                     : parts.joined(separator: " · ")
        case .wait:
            title = "Standort wird ermittelt …"
            subtitle = ""
        }
    }

    var color: Color {
        switch kind {
        case .ok: return GZ.ok
        case .ban: return GZ.ban
        case .time: return GZ.time
        case .wait: return GZ.ink3
        }
    }
}

/// Der farbige Punkt links: Haken / Kreuz / Spinner, mit 5-pt-Hof (v1 `.dot`).
struct StatusDot: View {
    let kind: StatusKind
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: size + 10, height: size + 10)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
            glyph
        }
        .frame(width: size + 10, height: size + 10)
        .animation(GZ.microSpring, value: kind)
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .ok:
            VectorIcon.check
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 15, height: 15)
        case .ban, .time:
            VectorIcon.cross
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 15, height: 15)
        case .wait:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(0.6)
        }
    }
}
