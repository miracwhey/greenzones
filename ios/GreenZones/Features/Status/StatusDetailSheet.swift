import GreenZonesKit
import SwiftUI

/// Detail-Sheet hinter dem Bar-Tap: Status-Kopf, Zonenliste, Fussnote.
/// Port von `StatusBar.tsx` (`.detail`) + `ZoneList.tsx`, Look aus `client/bar_detail.png`.
struct StatusDetailSheet: View {
    let presentation: StatusPresentation
    let status: ZoneStatus?
    let hour: Int
    let onClose: () -> Void

    /// Startwert fuer den ersten Frame — die echte Hoehe misst `fittedSheetDetent`.
    private var estimatedHeight: CGFloat {
        let rowCount: Int = {
            guard let status else { return 1 }
            var count = 0
            if status.ban.nearestM.isFinite { count += 1 }
            if status.time.nearestM.isFinite { count += 1 }
            return max(count, 1)
        }()
        return 110 + CGFloat(rowCount) * 62
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                StatusDot(kind: presentation.kind, color: presentation.color)
                    .padding(.leading, -5)
                    .padding(.trailing, -5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.title)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(GZ.ink)
                    Text("Dein Standort")
                        .font(.system(size: 12))
                        .foregroundStyle(GZ.ink2)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    VectorIcon.cross
                        .stroke(GZ.ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .frame(width: 11, height: 11)
                        .frame(width: 26, height: 26)
                        .background(GZ.ink.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details schließen")
            }
            .padding(.bottom, 12)

            Rectangle().fill(GZ.divider).frame(height: 1)

            ZoneListView(status: status, hour: hour)

            Text("Umkreis 2 km · Daten © OpenStreetMap · keine Rechtsberatung")
                .font(.system(size: 11))
                .foregroundStyle(GZ.ink3)
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .fittedSheetDetent(estimate: estimatedHeight)
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .presentationCornerRadius(22)
    }
}
