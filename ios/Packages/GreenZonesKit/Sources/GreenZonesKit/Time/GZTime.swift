import Foundation

/// Zeitquelle als Abhaengigkeit, nicht als globale Tatsache: Tests setzen die
/// Stunde, der Debug-Build kann sie ueberschreiben, Produktion nimmt die Systemuhr.
public protocol GZClock: Sendable {
    var now: Date { get }
}

/// Produktions-Uhr.
public struct SystemClock: GZClock {
    public init() {}
    public var now: Date { Date() }
}

/// Feste Uhr fuer Tests.
public struct FixedClock: GZClock {
    public let now: Date
    public init(_ now: Date) { self.now = now }
}

#if DEBUG
/// `GZ_HOUR` aus der Prozess-Umgebung — Pendant zu `?hour=` im Web-Client v1.
/// Verschiebt die Systemzeit auf die volle Wunschstunde DESSELBEN Tages, damit
/// nicht nur `banAtHour`, sondern auch alles Datumsbezogene stimmig bleibt.
public struct DebugClock: GZClock {
    public let hour: Int
    private let calendar: Calendar

    public init(hour: Int, calendar: Calendar = .current) {
        self.hour = hour
        self.calendar = calendar
    }

    /// `nil` = kein Override gesetzt; der Aufrufer nimmt dann die Systemuhr.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DebugClock? {
        guard let raw = environment["GZ_HOUR"], let hour = Int(raw), (0...23).contains(hour) else {
            return nil
        }
        return DebugClock(hour: hour)
    }

    public var now: Date {
        let real = Date()
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: real) ?? real
    }
}
#endif

/// Zeitfenster §5 Abs. 2 KCanG: Fussgaengerzonen 7–20 Uhr.
/// Port von `client/src/lib/time.ts`.
public enum GZTime {
    /// true = Fussgaengerzonen-Verbot gilt zur vollen Stunde `h`.
    public static func banAtHour(_ h: Int) -> Bool {
        h >= 7 && h < 20
    }

    public static func currentHour(_ clock: GZClock, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: clock.now)
    }

    public static func banActive(_ clock: GZClock, calendar: Calendar = .current) -> Bool {
        banAtHour(currentHour(clock, calendar: calendar))
    }

    /// „frei ab 20:00" / „verboten ab 7:00" — je nach aktuellem Zustand.
    public static func pedestrianHint(_ clock: GZClock, calendar: Calendar = .current) -> String {
        banActive(clock, calendar: calendar) ? "frei ab 20:00" : "verboten ab 7:00"
    }
}
