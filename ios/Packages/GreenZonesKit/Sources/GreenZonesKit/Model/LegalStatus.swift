import Foundation

/// Zustand EINER Zonen-Ebene (`ban` oder `time`) an einem Punkt.
/// Port von `LayerStatus` aus `client/src/lib/zones.ts`.
public struct LayerStatus: Equatable, Sendable {
    public let inside: Bool
    /// Meter bis zur naechsten Zonenkante; `.infinity` wenn keine im Suchradius,
    /// `0` wenn `inside`.
    public let nearestM: Double

    public init(inside: Bool, nearestM: Double) {
        self.inside = inside
        self.nearestM = nearestM
    }

    public static let unknown = LayerStatus(inside: false, nearestM: .infinity)
}

/// Beide Ebenen zusammen — was die Status-Bar, die Zonenliste und (ab W3) der
/// Spot-Kontext lesen.
public struct ZoneStatus: Equatable, Sendable {
    public let ban: LayerStatus
    public let time: LayerStatus

    public init(ban: LayerStatus, time: LayerStatus) {
        self.ban = ban
        self.time = time
    }
}

/// Verdikt der Status-Bar. Port von `statusKind()` in `StatusBar.tsx`.
public enum StatusKind: String, Sendable {
    case ok
    case ban
    case time
    case wait
}

public extension ZoneStatus {
    /// `nil` = noch kein Ergebnis → `wait`. Die Reihenfolge ist bindend:
    /// ein ganztaegiges Verbot schlaegt das Zeitfenster.
    static func statusKind(_ status: ZoneStatus?, hour: Int) -> StatusKind {
        guard let status else { return .wait }
        if status.ban.inside { return .ban }
        if status.time.inside && GZTime.banAtHour(hour) { return .time }
        return .ok
    }
}

/// Ist der Konsum an einem Punkt mit diesem Zonen-Status zur Zeit `at` erlaubt?
/// Port von `spotAllowedAt()` aus `client/src/lib/spots/timeFmt.ts`.
public func spotAllowedAt(_ status: ZoneStatus, at date: Date,
                          calendar: Calendar = .current) -> Bool {
    if status.ban.inside { return false }
    if status.time.inside && GZTime.banAtHour(calendar.component(.hour, from: date)) { return false }
    return true
}

/// Rohtyp der Offline-Ortssuche (W2 fuellt ihn aus `places.sqlite`).
public struct Place: Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let type: String
    public let state: String
    public let city: String
    public let lat: Double
    public let lng: Double

    public init(id: Int64, name: String, type: String, state: String, city: String,
                lat: Double, lng: Double) {
        self.id = id
        self.name = name
        self.type = type
        self.state = state
        self.city = city
        self.lat = lat
        self.lng = lng
    }
}
