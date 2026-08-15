import Foundation
import Testing
@testable import GreenZonesKit

/// Port von `client/src/components/__tests__/timeTape.test.tsx` (12 Faelle).
///
/// v1 prueft die Werte am gerenderten Markup (Track-Transform, Tick-Anzahl,
/// `opacity` der Flagge). Hier liegen genau diese Werte als reine Funktionen im
/// Kit — die SwiftUI-Ansicht verschiebt und zeichnet nur noch, sie rechnet
/// nichts. Damit prueft der Test dieselbe Groesse, nur eine Schicht tiefer.
@Suite("TimeTape — Band-Mathematik (Port der 12 v1-Faelle)")
struct TimeTapeMathTests {
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = y
        parts.month = mo
        parts.day = d
        parts.hour = h
        parts.minute = mi
        return Calendar.current.date(from: parts)!
    }

    private var base: Date { at(2026, 8, 6, 17, 41) }

    @Test("zeigt in der Rastzone 'Jetzt / direkt los'")
    func nowZoneReadout() {
        let readout = Tape.readout(current: base, base: base)
        #expect(readout.headline == "Jetzt")
        #expect(readout.relative == "direkt los")
        // Die Rastzone reicht bis 8 Minuten — danach kippt die Anzeige.
        #expect(Tape.readout(current: base.addingTimeInterval(7 * 60), base: base).headline == "Jetzt")
        #expect(Tape.readout(current: base.addingTimeInterval(9 * 60), base: base).headline != "Jetzt")
    }

    @Test("zeigt Tageswort, Uhrzeit und Relativzeile")
    func fullReadout() {
        let readout = Tape.readout(current: at(2026, 8, 6, 20, 0), base: base)
        #expect(readout.headline == "Heute · 20:00")
        #expect(readout.relative == "in 2 Std 19 Min")
    }

    @Test("verschiebt den Track um 48 pt pro Stunde")
    func trackOffset() {
        let value = at(2026, 8, 6, 18, 41)
        #expect(Tape.minutes(of: value, base: base) * Tape.pointsPerMinute == 48)
    }

    @Test("setzt Ticks auf absolute Viertelstunden und Stundenmarken")
    func tickGrid() {
        let ticks = Tape.ticks(base: base)
        // Erste Tick-Marke: 17:45, also 4 Min = 3,2 pt nach dem Bandanfang.
        #expect(abs(ticks[0].offset - 3.2) < 0.0001)
        // 17:45 … 5:30 (Bandende 5:41) = 144 Viertelstunden-Marken, davon 36 volle Stunden.
        #expect(ticks.count == 144)
        #expect(ticks.filter(\.isHour).count == 36)
    }

    @Test("gibt Mitternacht eine Tages-Pille")
    func dayLabels() {
        let labels = Tape.ticks(base: base).compactMap(\.dayLabel)
        #expect(labels == ["MORGEN", "ÜBERMORGEN"])
    }

    @Test("blendet die Referenz-Flagge erst ab 15 Min Abstand ein")
    func referenceFlag() {
        let reference = at(2026, 8, 6, 20, 0)
        #expect(!Tape.isReferenceVisible(current: at(2026, 8, 6, 20, 0), reference: reference))
        #expect(!Tape.isReferenceVisible(current: at(2026, 8, 6, 20, 14), reference: reference))
        #expect(Tape.isReferenceVisible(current: at(2026, 8, 6, 20, 15), reference: reference))
        #expect(Tape.isReferenceVisible(current: at(2026, 8, 6, 19, 45), reference: reference))
    }

    @Test("die Flagge sitzt an der Position ihrer Zeit")
    func referencePosition() {
        // 20:00 liegt 139 Min nach 17:41 → 139 · 0,8 pt.
        #expect(abs(Tape.offset(of: at(2026, 8, 6, 20, 0), base: base) - 139 * 0.8) < 0.0001)
        // Eine laufende Einladung darf links vom Bandanfang liegen — ungedeckelt.
        #expect(Tape.offset(of: at(2026, 8, 6, 17, 0), base: base) < 0)
    }

    @Test("die Legal-Zeile nennt in der Rastzone 'jetzt', sonst die Uhrzeit")
    func legalLineWording() {
        let free = ZoneStatus(ban: .unknown, time: .unknown)
        #expect(spotLegalLine(free, at: base, base: base) == "Am Spot jetzt erlaubt")
        #expect(spotLegalLine(free, at: at(2026, 8, 6, 20, 0), base: base) == "Am Spot um 20:00 erlaubt")
        #expect(spotLegalLine(nil, at: base, base: base) == nil)
    }

    @Test("die Legal-Zeile kippt mit der gewaehlten Uhrzeit")
    func legalLineFlips() {
        let pedestrian = ZoneStatus(ban: .unknown, time: LayerStatus(inside: true, nearestM: 0))
        #expect(spotLegalLine(pedestrian, at: at(2026, 8, 6, 19, 0), base: base)
            == "Am Spot um 19:00 verboten — Fußgängerzone bis 20 Uhr")
        #expect(spotLegalLine(pedestrian, at: at(2026, 8, 6, 20, 0), base: base)
            == "Am Spot um 20:00 erlaubt")
        let ban = ZoneStatus(ban: LayerStatus(inside: true, nearestM: 0), time: .unknown)
        #expect(spotLegalLine(ban, at: at(2026, 8, 6, 22, 0), base: base)
            == "Am Spot um 22:00 verboten — Verbotszone")
    }

    @Test("rendert die Chips aus tapeAnchors")
    func anchorChips() {
        let labels = Tape.anchors(base: base).map(\.label)
        #expect(labels == ["Jetzt", "Heute Abend", "Morgen Abend"])
    }

    @Test("laesst 'Heute Abend' weg, wenn 20:00 vorbei ist")
    func anchorChipsLate() {
        let late = at(2026, 8, 6, 21, 0)
        let labels = Tape.anchors(base: late).map(\.label)
        #expect(labels == ["Jetzt", "Morgen Abend"])
    }

    @Test("Anker-Ziel und Drag-Snap ergeben dieselbe Kontrakt-Zeit")
    func anchorMatchesDrag() {
        let evening = Tape.anchors(base: base).first { $0.id == "tonight" }
        #expect(evening?.time == at(2026, 8, 6, 20, 0))
        // dieselbe Zeit ueber den Zieh-Weg: 139 Min ab 17:41
        #expect(Tape.resolveTapeDrag(base: base, curMinutes: 139) == evening?.time)
    }
}
