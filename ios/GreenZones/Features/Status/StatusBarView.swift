import GreenZonesKit
import SwiftUI

/// 58-pt-Leiste unten: Punkt · Titel · getrennte Distanzen · Chevron.
/// Masse aus `client/src/App.css` (`.bar`), Look aus `client/bar_idle*.png`.
struct StatusBarView: View {
    let presentation: StatusPresentation
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 11) {
                StatusDot(kind: presentation.kind, color: presentation.color)
                    // Der Hof zaehlt optisch nicht zur Breite — 5 pt zuruecknehmen,
                    // damit der Text auf derselben Kante sitzt wie in v1.
                    .padding(.leading, -5)
                    .padding(.trailing, -5)

                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.title)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(GZ.ink)
                    if !presentation.subtitle.isEmpty {
                        Text(presentation.subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(GZ.ink2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(presentation.title)
                .transition(.opacity.combined(with: .offset(y: 3)))

                VectorIcon.chevronUp
                    .stroke(GZ.ink3, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 15)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 58)
            .frame(maxWidth: .infinity)
            .glassCard(cornerRadius: 18)
            .contentShape(.rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zonen-Details öffnen")
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .animation(GZ.spring, value: presentation.title)
    }
}
