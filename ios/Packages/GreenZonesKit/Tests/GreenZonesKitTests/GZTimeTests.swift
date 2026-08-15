import Foundation
import Testing
@testable import GreenZonesKit

@Suite("GZTime + Verdikt — Port von time.ts / StatusBar.tsx / timeFmt.ts")
struct GZTimeTests {
    private func date(hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 6
        components.hour = hour
        components.minute = 0
        return Calendar.current.date(from: components)!
    }

    @Test("Zeitfenster 7 ≤ h < 20")
    func window() {
        #expect(!GZTime.banAtHour(6))
        #expect(GZTime.banAtHour(7))
        #expect(GZTime.banAtHour(19))
        #expect(!GZTime.banAtHour(20))
        #expect(!GZTime.banAtHour(23))
    }

    @Test("Uhr ist injizierbar — kein Griff auf die Systemzeit")
    func injectedClock() {
        #expect(GZTime.currentHour(FixedClock(date(hour: 12))) == 12)
        #expect(GZTime.banActive(FixedClock(date(hour: 12))))
        #expect(!GZTime.banActive(FixedClock(date(hour: 22))))
        #expect(GZTime.pedestrianHint(FixedClock(date(hour: 12))) == "frei ab 20:00")
        #expect(GZTime.pedestrianHint(FixedClock(date(hour: 22))) == "verboten ab 7:00")
    }

    #if DEBUG
    @Test("GZ_HOUR wird nur aus einem gueltigen Wert gelesen")
    func debugClock() {
        #expect(DebugClock.fromEnvironment([:]) == nil)
        #expect(DebugClock.fromEnvironment(["GZ_HOUR": "nope"]) == nil)
        #expect(DebugClock.fromEnvironment(["GZ_HOUR": "24"]) == nil)
        let clock = DebugClock.fromEnvironment(["GZ_HOUR": "22"])
        #expect(clock?.hour == 22)
        #expect(GZTime.currentHour(clock!) == 22)
        #expect(!GZTime.banActive(clock!))
    }
    #endif

    @Test("statusKind: ban schlaegt time, time nur im Zeitfenster")
    func verdict() {
        let outside = ZoneStatus(ban: .unknown, time: .unknown)
        let inBan = ZoneStatus(ban: LayerStatus(inside: true, nearestM: 0), time: .unknown)
        let inTime = ZoneStatus(ban: .unknown, time: LayerStatus(inside: true, nearestM: 0))
        let inBoth = ZoneStatus(ban: LayerStatus(inside: true, nearestM: 0),
                                time: LayerStatus(inside: true, nearestM: 0))

        #expect(ZoneStatus.statusKind(nil, hour: 12) == .wait)
        #expect(ZoneStatus.statusKind(outside, hour: 12) == .ok)
        #expect(ZoneStatus.statusKind(inBan, hour: 12) == .ban)
        #expect(ZoneStatus.statusKind(inBan, hour: 22) == .ban)
        #expect(ZoneStatus.statusKind(inTime, hour: 12) == .time)
        #expect(ZoneStatus.statusKind(inTime, hour: 22) == .ok)
        #expect(ZoneStatus.statusKind(inBoth, hour: 22) == .ban)
    }

    @Test("spotAllowedAt an den Fensterraendern")
    func allowed() {
        let inTime = ZoneStatus(ban: .unknown, time: LayerStatus(inside: true, nearestM: 0))
        #expect(spotAllowedAt(inTime, at: date(hour: 6)))
        #expect(!spotAllowedAt(inTime, at: date(hour: 7)))
        #expect(!spotAllowedAt(inTime, at: date(hour: 19)))
        #expect(spotAllowedAt(inTime, at: date(hour: 20)))

        let inBan = ZoneStatus(ban: LayerStatus(inside: true, nearestM: 0), time: .unknown)
        for hour in 0...23 {
            #expect(!spotAllowedAt(inBan, at: date(hour: hour)))
        }

        let free = ZoneStatus(ban: .unknown, time: .unknown)
        for hour in 0...23 {
            #expect(spotAllowedAt(free, at: date(hour: hour)))
        }
    }
}
