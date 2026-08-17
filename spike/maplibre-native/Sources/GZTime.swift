import Foundation

/// Port von `client/src/lib/time.ts` — Zeitfenster §5 Abs. 2 KCanG: 7–20 Uhr.
enum GZTime {
    /// Debug-Override `GZ_HOUR` — Pendant zu `?hour=` im Web-Client v1.
    static func currentHour() -> Int {
        if let raw = ProcessInfo.processInfo.environment["GZ_HOUR"], let h = Int(raw) {
            return h
        }
        return Calendar.current.component(.hour, from: Date())
    }

    /// true = Fußgängerzonen-Verbot gilt zur vollen Stunde `h`.
    static func banAtHour(_ h: Int) -> Bool {
        h >= 7 && h < 20
    }

    static func banActive() -> Bool {
        banAtHour(currentHour())
    }
}
