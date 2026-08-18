import GreenZonesKit
import SwiftUI

/// Zonenliste des Detail-Sheets. Port von `client/src/components/ZoneList.tsx` —
/// Texte, Reihenfolge (naechste Zone zuerst) und Badge woertlich.
struct ZoneListView: View {
    let status: ZoneStatus?
    let hour: Int

    private struct Row: Identifiable {
        let id: String
        let distance: Double
        let title: String
        let badge: String?
        let subtitle: String
        let icon: VectorIcon
        let color: Color
    }

    /// v1 `fmtDist`: 0 ist keine Distanz, sondern eine Aussage.
    private func formatted(_ m: Double) -> String {
        m == 0 ? "hier" : Geo.formatDistanceM(m)
    }

    private var rows: [Row] {
        guard let status else { return [] }
        var out: [Row] = []
        if status.ban.nearestM.isFinite {
            out.append(Row(id: "ban",
                           distance: status.ban.nearestM,
                           title: "Verbotszone",
                           badge: nil,
                           subtitle: "Schule, Kita, Spielplatz, Jugend- o. Sportstätte\n100 m · ganztägig",
                           icon: .lock,
                           color: GZ.ban))
        }
        if status.time.nearestM.isFinite {
            let banActive = GZTime.banAtHour(hour)
            out.append(Row(id: "time",
                           distance: status.time.nearestM,
                           title: "Fußgängerzone",
                           badge: banActive ? "JETZT VERBOTEN" : nil,
                           subtitle: "Verboten 7–20 Uhr · \(banActive ? "frei ab 20:00" : "verboten ab 7:00")",
                           icon: .clock,
                           color: GZ.time))
        }
        return out.sorted { $0.distance < $1.distance }
    }

    var body: some View {
        if status == nil {
            Text("Zonen werden geladen …")
                .font(.system(size: 13))
                .foregroundStyle(GZ.ink2)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if rows.isEmpty {
            Text("Keine Verbotszonen im Umkreis von 2 km.")
                .font(.system(size: 13))
                .foregroundStyle(GZ.ink2)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(GZ.divider).frame(height: 1)
                    }
                    zoneRow(row)
                }
            }
        }
    }

    private func zoneRow(_ row: Row) -> some View {
        HStack(spacing: 12) {
            row.icon
                .stroke(row.color, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .frame(width: 17, height: 17)
                .frame(width: 34, height: 34)
                .background(row.color.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.14)
                        .foregroundStyle(GZ.ink)
                    if let badge = row.badge {
                        Text(badge)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(GZ.time)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(GZ.time.opacity(0.12), in: .rect(cornerRadius: 5))
                    }
                }
                Text(row.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(GZ.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatted(row.distance))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(GZ.ink)
        }
        .padding(.vertical, 10)
    }
}
