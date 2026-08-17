import GreenZonesKit
import SwiftUI

/// Zeit-Band-Picker („TimeTape") — Port von `client/src/components/TimeTape.tsx`
/// und `TimeTape.css`, die ihrerseits aus `mockup/invite.html` kommen.
///
/// Das Band laeuft unter einem festen Cursor in der Mitte durch, gesnappt wird
/// auf absolute Viertelstunden. Gerechnet wird nichts hier: Marken, Positionen,
/// Rastzone und Anker kommen aus `Tape` im Kit (dort auch getestet).
struct TimeTapeView: View {
    /// Gewaehlte Zeit; gehoert dem Aufrufer.
    @Binding var value: Date
    /// Bandanfang.
    let base: Date
    /// Referenzzeit fuer die Flagge im Band (z. B. die bisherige Zeit).
    var referenceTime: Date?
    /// Text vor der Referenz-Uhrzeit, z. B. „Leon ab".
    var referenceLabel: String?
    /// Status-Zeile unterm Band; `nil` blendet die Zeile aus.
    var legalLine: ((Date) -> String?)?
    /// Am Spot verboten → die Zeile kippt auf Orange.
    var legalWarns: (Date) -> Bool = { _ in false }

    @State private var dragMinutes: Double?

    private static let tapeHeight: CGFloat = 74
    private static let bleed: CGFloat = 18

    private var valueMinutes: Double { Tape.minutes(of: value, base: base) }
    private var currentMinutes: Double { dragMinutes ?? valueMinutes }
    private var current: Date { base.addingTimeInterval(currentMinutes * 60) }
    private var ticks: [Tape.Tick] { Tape.ticks(base: base) }
    private var anchors: [Tape.Anchor] { Tape.anchors(base: base) }

    var body: some View {
        VStack(spacing: 0) {
            readout
            tape
            anchorRow
            legal
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    // MARK: Anzeige

    private var readout: some View {
        let text = Tape.readout(current: current, base: base)
        return VStack(spacing: 3) {
            Text(text.headline)
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .tracking(-0.6)
                .foregroundStyle(GZ.ink)
            Text(text.relative)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(GZ.ink2)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
    }

    // MARK: Band

    private var tape: some View {
        GeometryReader { proxy in
            let center = proxy.size.width / 2
            ZStack(alignment: .topLeading) {
                track
                    .offset(x: center - currentMinutes * Tape.pointsPerMinute)
                    .animation(dragMinutes == nil ? GZ.elementSpring : nil, value: currentMinutes)
                needle.offset(x: center - 1.5)
            }
            .frame(width: proxy.size.width, height: Self.tapeHeight, alignment: .topLeading)
            // Kanten weich auslaufen lassen: als Maske auf dem Inhalt, nicht als
            // Farbverlauf auf die Sheet-Farbe — ueber `.regularMaterial` gaebe es
            // die passende Deckfarbe gar nicht.
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            )
            .contentShape(Rectangle())
            .gesture(drag(pointsPerMinute: Tape.pointsPerMinute))
        }
        .frame(height: Self.tapeHeight)
        .padding(.horizontal, -Self.bleed)
        .padding(.top, 10)
    }

    private var track: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ticks) { tick in
                tickMark(tick)
            }
            if let referenceTime {
                referenceFlag(referenceTime)
                    .offset(x: Tape.offset(of: referenceTime, base: base))
                    .opacity(Tape.isReferenceVisible(current: current, reference: referenceTime) ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: currentMinutes)
            }
        }
        .frame(height: Self.tapeHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func tickMark(_ tick: Tape.Tick) -> some View {
        let height: CGFloat = tick.isHour ? 22 : 12
        Capsule()
            .fill(GZ.ink.opacity(tick.isHour ? 0.32 : 0.18))
            .frame(width: 1.5, height: height)
            .offset(x: tick.offset - 0.75, y: Self.tapeHeight - 26 - height)

        if let label = tick.hourLabel {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(GZ.ink3)
                .fixedSize()
                .frame(width: 40)
                .offset(x: tick.offset - 20, y: Self.tapeHeight - 21)
        }
        if let day = tick.dayLabel {
            Text(day)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(GZ.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(GZ.accent.opacity(0.09), in: .capsule)
                .fixedSize()
                .frame(width: 120)
                .offset(x: tick.offset - 60, y: 2)
        }
    }

    private func referenceFlag(_ time: Date) -> some View {
        VStack(spacing: 0) {
            Text("\(referenceLabel ?? "bisher") \(Tape.fmtClock(time))")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(GZ.ink2)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(GZ.ink.opacity(0.08), in: .capsule)
                .overlay { Capsule().strokeBorder(GZ.stroke, lineWidth: 1) }
            Rectangle()
                .fill(GZ.ink.opacity(0.25))
                .frame(width: 1.5, height: 10)
        }
        .fixedSize()
        .frame(width: 200)
        .offset(x: -100, y: 3)
    }

    /// Fixer Cursor in der Mitte — 3-pt-Balken mit 4-pt-Hof (v1 `box-shadow`).
    private var needle: some View {
        Capsule()
            .fill(GZ.accent)
            .frame(width: 3, height: Self.tapeHeight - 6 - 18)
            .background {
                Capsule()
                    .fill(GZ.accent.opacity(0.14))
                    .padding(-4)
            }
            .offset(y: 6)
    }

    private func drag(pointsPerMinute: Double) -> some Gesture {
        // `translation` ist immer der Weg seit dem Aufsetzen — der Startwert ist
        // deshalb der gebundene Wert, nicht der laufende Zwischenstand.
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                let moved = -gesture.translation.width / pointsPerMinute
                dragMinutes = min(max(valueMinutes + moved, 0), Tape.rangeMinutes)
            }
            .onEnded { _ in
                let released = dragMinutes ?? valueMinutes
                dragMinutes = nil
                commit(Tape.resolveTapeDrag(base: base, curMinutes: released))
            }
    }

    private func commit(_ time: Date) {
        guard time != value else { return }
        GZ.haptic()
        value = time
    }

    // MARK: Anker und Legal-Zeile

    private var anchorRow: some View {
        HStack(spacing: 8) {
            ForEach(anchors) { anchor in
                Button(action: { commit(anchor.time) }) {
                    Text(anchor.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GZ.ink2)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(SP.tile, in: .capsule)
                        .overlay { Capsule().strokeBorder(GZ.stroke, lineWidth: 1) }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var legal: some View {
        if let legalLine, let text = legalLine(current) {
            let color = legalWarns(current) ? GZ.time : GZ.ok
            HStack(spacing: 7) {
                SPIcon(kind: .check).stroked(color, size: 14, width: 2.6)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 11)
        }
    }
}
