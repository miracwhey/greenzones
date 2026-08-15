import Foundation

/// Mathematik des Zeit-Bandes (TimeTape) und die Zeit-Texte darum herum.
/// Port von `client/src/lib/spots/timeFmt.ts` und der Maßstabs-Konstanten aus
/// `client/src/components/TimeTape.tsx`.
///
/// Rein und ohne UI: Snap, Rastzone und Anker sind ohne Render pruefbar — die
/// SwiftUI-Ansicht rechnet nichts selbst.
///
/// Uhrzeit-Format ohne fuehrende Null bei der Stunde („7:00", „20:00") — so wie
/// das abgenommene Mockup und `GZTime.pedestrianHint()` es schreiben.
public enum Tape {
    /// Snap-Raster: absolute Viertelstunden.
    public static let quarterMinutes = 15
    public static let quarter: TimeInterval = 15 * 60
    /// Band-Bereich: `minTime` … +36 h.
    public static let rangeMinutes: Double = 36 * 60
    public static let range: TimeInterval = 36 * 60 * 60
    /// Unter dieser Distanz zu `minTime` rastet das Band auf „Jetzt".
    public static let nowZoneMinutes: Double = 8
    public static let nowZone: TimeInterval = 8 * 60
    /// Band-Maßstab: 48 pt pro Stunde.
    public static let pointsPerMinute: Double = 48.0 / 60.0

    // MARK: - Bausteine

    /// Anfang der Stunde, in der `date` liegt — Pendant zu `d.setMinutes(0, 0, 0)`.
    static func startOfHour(_ date: Date, _ calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.era, .year, .month, .day, .hour], from: date)
        parts.minute = 0
        parts.second = 0
        parts.nanosecond = 0
        return calendar.date(from: parts) ?? date
    }

    /// Auf eine absolute Viertelstunde (:00/:15/:30/:45) legen — `round` bestimmt
    /// die Richtung.
    static func toQuarter(_ date: Date, _ calendar: Calendar,
                          round: (Double) -> Double) -> Date {
        let parts = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
        let minutes = Double(parts.minute ?? 0)
            + (Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1e9) / 60
        let quarters = round(minutes / Double(quarterMinutes)) * Double(quarterMinutes)
        return startOfHour(date, calendar).addingTimeInterval(quarters * 60)
    }

    /// Uhrzeit `hour`:00 am Tag `base + dayOffset` (lokal, DST-fest).
    static func clockOnDay(_ base: Date, dayOffset: Int, hour: Int,
                           _ calendar: Calendar) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: base) ?? base
        var parts = calendar.dateComponents([.era, .year, .month, .day], from: day)
        parts.hour = hour
        parts.minute = 0
        parts.second = 0
        parts.nanosecond = 0
        return calendar.date(from: parts) ?? day
    }

    // MARK: - Texte

    /// „20:00" — Uhrzeit ohne fuehrende Null bei der Stunde.
    public static func fmtClock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return "\(parts.hour ?? 0):" + String(format: "%02d", parts.minute ?? 0)
    }

    /// „Heute" | „Morgen" | „Übermorgen" — Kalendertage, nicht 24-h-Bloecke.
    public static func dayWord(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: date)
        let diff = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        if diff <= 0 { return "Heute" }
        if diff == 1 { return "Morgen" }
        return "Übermorgen"
    }

    /// „direkt los" | „in 25 Min" | „in 2 Std" | „in 2 Std 19 Min"
    public static func relWord(_ date: Date, now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
        if minutes < 1 { return "direkt los" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "in \(rest) Min" }
        if rest == 0 { return "in \(hours) Std" }
        return "in \(hours) Std \(rest) Min"
    }

    // MARK: - Snap

    /// Auf die naechstliegende absolute Viertelstunde runden (:07:30 → :15).
    public static func snapToQuarter(_ date: Date, calendar: Calendar = .current) -> Date {
        // JS `Math.round` rundet .5 nach oben; fuer die hier immer positiven
        // Werte ist `.toNearestOrAwayFromZero` dasselbe.
        toQuarter(date, calendar) { $0.rounded(.toNearestOrAwayFromZero) }
    }

    /// Naechste absolute Viertelstunde ab `date` (bei exakter Viertelstunde: `date` selbst).
    public static func ceilToQuarter(_ date: Date, calendar: Calendar = .current) -> Date {
        toQuarter(date, calendar) { $0.rounded(.up) }
    }

    /// Loslassen nach dem Ziehen: „Jetzt"-Rastzone oder absolute Viertelstunde,
    /// immer innerhalb des Bandes.
    public static func resolveTapeDrag(base: Date, curMinutes: Double,
                                       calendar: Calendar = .current) -> Date {
        if curMinutes < nowZoneMinutes { return base }
        let snapped = snapToQuarter(base.addingTimeInterval(curMinutes * 60), calendar: calendar)
        let upper = base.addingTimeInterval(range)
        return min(max(snapped, base), upper)
    }

    // MARK: - Anker

    public struct Anchor: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let time: Date
    }

    /// Sprungmarken unterm Band. Ein Anker erscheint nur, wenn seine Zeit im Band
    /// liegt — deckt „Heute Abend nur wenn 20:00 noch kommt" und „Morgen Abend
    /// nur wenn es noch in die 36 h passt" mit derselben Regel ab.
    public static func anchors(base: Date, calendar: Calendar = .current) -> [Anchor] {
        let upper = base.addingTimeInterval(range)
        let all = [
            Anchor(id: "now", label: "Jetzt", time: base),
            Anchor(id: "tonight", label: "Heute Abend",
                   time: clockOnDay(base, dayOffset: 0, hour: 20, calendar)),
            Anchor(id: "tomorrow", label: "Morgen Abend",
                   time: clockOnDay(base, dayOffset: 1, hour: 20, calendar)),
        ]
        return all.filter { $0.time >= base && $0.time <= upper }
    }

    // MARK: - Layout des Bandes

    /// Eine Marke im Band. `offset` ist der Abstand vom Bandanfang in Punkten —
    /// die Ansicht verschiebt nur noch, sie rechnet nicht.
    public struct Tick: Equatable, Sendable, Identifiable {
        public let id: Double
        public let offset: Double
        public let isHour: Bool
        /// Stundenzahl unter der Marke („18"), nur bei vollen Stunden.
        public let hourLabel: String?
        /// Tages-Pille im Band („MORGEN"), nur um Mitternacht.
        public let dayLabel: String?
    }

    /// Marken auf ABSOLUTEN Viertelstunden, nicht auf „base + k·15" — die
    /// Beschriftung soll runde Uhrzeiten nennen.
    public static func ticks(base: Date, calendar: Calendar = .current) -> [Tick] {
        var out: [Tick] = []
        let end = base.addingTimeInterval(range)
        var t = ceilToQuarter(base, calendar: calendar)
        while t <= end {
            let offset = t.timeIntervalSince(base) / 60 * pointsPerMinute
            let parts = calendar.dateComponents([.hour, .minute], from: t)
            let isHour = (parts.minute ?? 0) == 0
            let hour = parts.hour ?? 0
            out.append(Tick(id: offset,
                            offset: offset,
                            isHour: isHour,
                            hourLabel: isHour ? "\(hour)" : nil,
                            dayLabel: isHour && hour == 0
                                ? dayWord(t, now: base, calendar: calendar).uppercased()
                                : nil))
            t = t.addingTimeInterval(quarter)
        }
        return out
    }

    /// Minuten seit Bandanfang, immer im Band.
    public static func minutes(of date: Date, base: Date) -> Double {
        min(max(date.timeIntervalSince(base) / 60, 0), rangeMinutes)
    }

    /// Punkt-Position einer Zeit im Band (ungedeckelt — die Referenz-Flagge darf
    /// auch links vom Bandanfang liegen, wenn eine Einladung schon laeuft).
    public static func offset(of date: Date, base: Date) -> Double {
        date.timeIntervalSince(base) / 60 * pointsPerMinute
    }

    /// Die Referenz-Flagge erscheint erst, wenn sie nicht mehr unter dem Cursor
    /// klebt — sonst stuenden zwei Zeiten uebereinander.
    public static func isReferenceVisible(current: Date, reference: Date) -> Bool {
        abs(current.timeIntervalSince(reference)) >= Double(quarterMinutes) * 60
    }

    /// Grosse Anzeige ueber dem Band.
    public struct Readout: Equatable, Sendable {
        public let headline: String
        public let relative: String
    }

    public static func readout(current: Date, base: Date,
                               calendar: Calendar = .current) -> Readout {
        let inNowZone = minutes(of: current, base: base) < nowZoneMinutes
        if inNowZone { return Readout(headline: "Jetzt", relative: "direkt los") }
        return Readout(headline: "\(dayWord(current, now: base, calendar: calendar)) · "
                                 + fmtClock(current, calendar: calendar),
                       relative: relWord(current, now: base))
    }
}

/// Zeile unterm Band — der Legal-Status kippt mit der gewaehlten Uhrzeit.
/// In der „Jetzt"-Rastzone steht dort „jetzt", nicht die Uhrzeit: das Band zeigt
/// oben dasselbe. Port von `legalLineAt()` aus `SpotSheets.tsx`.
public func spotLegalLine(_ status: ZoneStatus?, at time: Date, base: Date,
                          calendar: Calendar = .current) -> String? {
    guard let status else { return nil }
    let when = time.timeIntervalSince(base) < Tape.nowZone
        ? "jetzt" : "um " + Tape.fmtClock(time, calendar: calendar)
    if spotAllowedAt(status, at: time, calendar: calendar) { return "Am Spot \(when) erlaubt" }
    if status.ban.inside { return "Am Spot \(when) verboten — Verbotszone" }
    return "Am Spot \(when) verboten — Fußgängerzone bis 20 Uhr"
}
