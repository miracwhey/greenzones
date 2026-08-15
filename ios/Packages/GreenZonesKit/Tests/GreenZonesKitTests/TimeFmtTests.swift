import Foundation
import Testing
@testable import GreenZonesKit

/// Port von `client/src/lib/spots/__tests__/timeFmt.test.ts` (19 Faelle).
/// Alles rechnet lokal, der Test ist damit zeitzonenunabhaengig.
@Suite("timeFmt — Port der 19 v1-Faelle")
struct TimeFmtTests {
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0,
                    _ s: Int = 0, _ ms: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = y
        parts.month = mo
        parts.day = d
        parts.hour = h
        parts.minute = mi
        parts.second = s
        parts.nanosecond = ms * 1_000_000
        return Calendar.current.date(from: parts)!
    }

    private func zone(ban: Bool, time: Bool) -> ZoneStatus {
        ZoneStatus(ban: LayerStatus(inside: ban, nearestM: ban ? 0 : 500),
                   time: LayerStatus(inside: time, nearestM: time ? 0 : 500))
    }

    // MARK: fmtClock (1)

    @Test("fmtClock schreibt Minuten zweistellig, Stunde ohne fuehrende Null")
    func fmtClock() {
        #expect(Tape.fmtClock(at(2026, 8, 6, 20, 0)) == "20:00")
        #expect(Tape.fmtClock(at(2026, 8, 6, 9, 5)) == "9:05")
        #expect(Tape.fmtClock(at(2026, 8, 6, 0, 0)) == "0:00")
    }

    // MARK: snapToQuarter (4)

    @Test("snapToQuarter rundet auf die naechstliegende absolute Viertelstunde")
    func snapRounds() {
        #expect(Tape.fmtClock(Tape.snapToQuarter(at(2026, 8, 6, 17, 7, 29))) == "17:00")
        #expect(Tape.fmtClock(Tape.snapToQuarter(at(2026, 8, 6, 17, 7, 30))) == "17:15")
        #expect(Tape.fmtClock(Tape.snapToQuarter(at(2026, 8, 6, 17, 22, 30))) == "17:30")
        #expect(Tape.fmtClock(Tape.snapToQuarter(at(2026, 8, 6, 17, 41))) == "17:45")
    }

    @Test("snapToQuarter laesst eine exakte Viertelstunde stehen und nullt Sekunden")
    func snapExact() {
        #expect(Tape.snapToQuarter(at(2026, 8, 6, 17, 15)) == at(2026, 8, 6, 17, 15))
        #expect(Tape.snapToQuarter(at(2026, 8, 6, 17, 15, 4, 250)) == at(2026, 8, 6, 17, 15))
    }

    @Test("snapToQuarter rollt ueber die volle Stunde")
    func snapRollover() {
        #expect(Tape.snapToQuarter(at(2026, 8, 6, 17, 53)) == at(2026, 8, 6, 18, 0))
        #expect(Tape.snapToQuarter(at(2026, 8, 6, 23, 55)) == at(2026, 8, 7, 0, 0))
    }

    @Test("snapToQuarter ist absolut, nicht relativ zu einem Startpunkt")
    func snapAbsolute() {
        // „minTime + k·15" ergaebe 17:56 — verlangt ist die runde Uhrzeit.
        let base = at(2026, 8, 6, 17, 41)
        #expect(Tape.fmtClock(Tape.snapToQuarter(base.addingTimeInterval(15 * 60))) == "18:00")
    }

    // MARK: ceilToQuarter (1)

    @Test("ceilToQuarter liefert die naechste Viertelstunde, exakte bleibt stehen")
    func ceil() {
        #expect(Tape.ceilToQuarter(at(2026, 8, 6, 17, 41)) == at(2026, 8, 6, 17, 45))
        #expect(Tape.ceilToQuarter(at(2026, 8, 6, 17, 45)) == at(2026, 8, 6, 17, 45))
        #expect(Tape.ceilToQuarter(at(2026, 8, 6, 17, 45, 0, 1)) == at(2026, 8, 6, 18, 0))
    }

    // MARK: dayWord (2)

    @Test("dayWord wechselt an Mitternacht, nicht nach 24 h")
    func dayWordMidnight() {
        let now = at(2026, 8, 6, 23, 50)
        #expect(Tape.dayWord(at(2026, 8, 6, 23, 59), now: now) == "Heute")
        #expect(Tape.dayWord(at(2026, 8, 7, 0, 10), now: now) == "Morgen")
        #expect(Tape.dayWord(at(2026, 8, 7, 23, 0), now: now) == "Morgen")
        #expect(Tape.dayWord(at(2026, 8, 8, 0, 5), now: now) == "Übermorgen")
    }

    @Test("dayWord nennt Vergangenes 'Heute'")
    func dayWordPast() {
        let now = at(2026, 8, 6, 23, 50)
        #expect(Tape.dayWord(at(2026, 8, 5, 12, 0), now: now) == "Heute")
    }

    // MARK: relWord (1)

    @Test("relWord kennt alle vier Formen")
    func relWord() {
        let now = at(2026, 8, 6, 17, 41)
        #expect(Tape.relWord(now, now: now) == "direkt los")
        #expect(Tape.relWord(now.addingTimeInterval(20), now: now) == "direkt los")
        #expect(Tape.relWord(at(2026, 8, 6, 18, 6), now: now) == "in 25 Min")
        #expect(Tape.relWord(at(2026, 8, 6, 19, 41), now: now) == "in 2 Std")
        #expect(Tape.relWord(at(2026, 8, 6, 20, 0), now: now) == "in 2 Std 19 Min")
    }

    // MARK: resolveTapeDrag (3)

    @Test("resolveTapeDrag rastet unter 8 Min auf 'Jetzt'")
    func dragNowZone() {
        let base = at(2026, 8, 6, 17, 41)
        #expect(Tape.resolveTapeDrag(base: base, curMinutes: 0) == base)
        #expect(Tape.resolveTapeDrag(base: base, curMinutes: 7.9) == base)
    }

    @Test("resolveTapeDrag snappt ab 8 Min auf die absolute Viertelstunde")
    func dragSnap() {
        let base = at(2026, 8, 6, 17, 41)
        #expect(Tape.resolveTapeDrag(base: base, curMinutes: 8) == at(2026, 8, 6, 17, 45))
        #expect(Tape.resolveTapeDrag(base: base, curMinutes: 139) == at(2026, 8, 6, 20, 0))
    }

    @Test("resolveTapeDrag bleibt im Band [minTime, +36 h]")
    func dragClamp() {
        let base = at(2026, 8, 6, 17, 41)
        let end = base.addingTimeInterval(36 * 3600)
        #expect(Tape.resolveTapeDrag(base: base, curMinutes: -5) == base)
        // 5:41 snappte auf 5:45 — das laege hinter dem Bandende, also gedeckelt.
        #expect(Tape.resolveTapeDrag(base: base, curMinutes: 36 * 60) == end)
        #expect(Tape.resolveTapeDrag(base: base, curMinutes: 40 * 60) == end)
    }

    // MARK: tapeAnchors (3)

    @Test("tapeAnchors zeigt alle drei, solange sie im Band liegen")
    func anchorsAll() {
        let base = at(2026, 8, 6, 10, 0)
        let anchors = Tape.anchors(base: base)
        #expect(anchors.map(\.label) == ["Jetzt", "Heute Abend", "Morgen Abend"])
        #expect(anchors[1].time == at(2026, 8, 6, 20, 0))
        #expect(anchors[2].time == at(2026, 8, 7, 20, 0))
    }

    @Test("tapeAnchors laesst 'Heute Abend' weg, wenn 20:00 vorbei ist")
    func anchorsTonight() {
        #expect(Tape.anchors(base: at(2026, 8, 6, 21, 0)).map(\.label) == ["Jetzt", "Morgen Abend"])
        // Punktgenau: 20:00 selbst zaehlt noch.
        #expect(Tape.anchors(base: at(2026, 8, 6, 20, 0)).map(\.label).contains("Heute Abend"))
        #expect(!Tape.anchors(base: at(2026, 8, 6, 20, 1)).map(\.label).contains("Heute Abend"))
    }

    @Test("tapeAnchors laesst 'Morgen Abend' weg, wenn es aus dem 36-h-Band faellt")
    func anchorsTomorrow() {
        #expect(Tape.anchors(base: at(2026, 8, 6, 3, 0)).map(\.label) == ["Jetzt", "Heute Abend"])
        #expect(Tape.anchors(base: at(2026, 8, 6, 8, 0)).map(\.label).contains("Morgen Abend"))
    }

    // MARK: pedestrianBanAtHour (1)

    @Test("Fussgaengerzonen-Verbot gilt 7 bis einschliesslich 19 Uhr")
    func pedestrian() {
        #expect(!GZTime.banAtHour(6))
        #expect(GZTime.banAtHour(7))
        #expect(GZTime.banAtHour(19))
        #expect(!GZTime.banAtHour(20))
        #expect(!GZTime.banAtHour(0))
    }

    // MARK: spotAllowedAt (3)

    @Test("spotAllowedAt oeffnet die Fussgaengerzone erst um 20 Uhr")
    func allowedPedestrian() {
        let status = zone(ban: false, time: true)
        #expect(spotAllowedAt(status, at: at(2026, 8, 6, 6, 59)))
        #expect(!spotAllowedAt(status, at: at(2026, 8, 6, 7, 0)))
        #expect(!spotAllowedAt(status, at: at(2026, 8, 6, 19, 59)))
        #expect(spotAllowedAt(status, at: at(2026, 8, 6, 20, 0)))
    }

    @Test("spotAllowedAt: das Bann-Polygon schlaegt immer durch")
    func allowedBan() {
        for hour in [3, 6, 7, 12, 19, 20, 23] {
            #expect(!spotAllowedAt(zone(ban: true, time: false), at: at(2026, 8, 6, hour, 0)))
            #expect(!spotAllowedAt(zone(ban: true, time: true), at: at(2026, 8, 6, hour, 0)))
        }
    }

    @Test("spotAllowedAt: ausserhalb jeder Zone immer erlaubt")
    func allowedFree() {
        for hour in [0, 7, 13, 19, 20] {
            #expect(spotAllowedAt(zone(ban: false, time: false), at: at(2026, 8, 6, hour, 0)))
        }
    }
}
