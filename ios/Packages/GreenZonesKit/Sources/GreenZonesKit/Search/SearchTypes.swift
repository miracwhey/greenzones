import CoreLocation
import Foundation

/// Zwei Quellen, strikt getrennt — Port von `client/src/lib/search/types.ts`:
/// `place` = gebuendelter Offline-Ortsindex, `photon` = Geocoder online.
/// Es gibt KEINEN stillen Fallback: faellt eine Quelle aus, wird ihr Zustand
/// sichtbar gemacht, nie durch die andere kaschiert.
public enum ResultSource: String, Sendable, Equatable {
    case place
    case photon
}

/// Ein Suchtreffer, quellenunabhaengig renderbar.
public struct SearchResult: Sendable, Equatable {
    public let name: String
    /// Zweite Zeile: „Typ · Kontext" (place) bzw. „PLZ, Ort, Bundesland" (photon).
    public let detail: String
    public let lng: Double
    public let lat: Double
    public let source: ResultSource

    public init(name: String, detail: String, lng: Double, lat: Double, source: ResultSource) {
        self.name = name
        self.detail = detail
        self.lng = lng
        self.lat = lat
        self.source = source
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// Kontext-Zeile im Ziel-Modus (v1 `StatusBar.tsx` → `targetSub`).
    /// Beim Offline-Treffer ist das Typ-Praefix redundant (der Name steht ja
    /// daneben), der Kontext nicht.
    public var targetSubtitle: String {
        guard source == .place else { return detail.isEmpty ? name : detail }
        let context = detail.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
        return context.isEmpty ? name : "\(name) · \(context)"
    }
}

/// Typ-Gewichte, Labels und Naehe-Boost — Port von `client/src/lib/search/places.ts`.
public enum PlaceRanking {
    /// Ein Stadtteil ist als Sucheintrag mehr wert als ein Weiler gleichen Namens.
    public static let typeWeight: [String: Double] = [
        "city": 3,
        "town": 2.5,
        "station": 2.2,
        "village": 2,
        "square": 1.9,
        "suburb": 1.8,
        "quarter": 1.8,
        "neighbourhood": 1.8,
        "park": 1.8,
        "water": 1.7,
        "wood": 1.7,
        "hamlet": 1.2,
    ]

    public static let typeLabel: [String: String] = [
        "city": "Stadt",
        "town": "Stadt",
        "village": "Gemeinde",
        "hamlet": "Weiler",
        "suburb": "Stadtteil",
        "quarter": "Ortsteil",
        "neighbourhood": "Viertel",
        "station": "Bahnhof",
        "square": "Platz",
        "park": "Park",
        "water": "See",
        "wood": "Wald",
    ]

    /// Unbekannter Typ: nie verwerfen, nie abstuerzen — neutral einsortieren.
    public static let fallbackLabel = "Ort"
    public static let fallbackWeight = 1.5

    public static func label(for type: String) -> String {
        typeLabel[type] ?? fallbackLabel
    }

    public static func weight(for type: String) -> Double {
        typeWeight[type] ?? fallbackWeight
    }

    /// Naeher am Nutzer = relevanter. Bei 0 km ×1,6, bei 30 km ×1,3, bei 300 km ×1,05.
    public static func proximityBoost(user: CLLocationCoordinate2D,
                                      place: CLLocationCoordinate2D) -> Double {
        let km = Geo.distanceM(user, place) / 1000
        return 1 + 0.6 / (1 + km / 30)
    }
}

public extension Place {
    /// Detail-Zeile: Typ-Label + Kontext. Eltern-Gemeinde schlaegt Bundesland.
    var detail: String {
        let label = PlaceRanking.label(for: type)
        let context = city.isEmpty ? state : city
        return context.isEmpty ? label : "\(label) · \(context)"
    }

    var typeLabel: String { PlaceRanking.label(for: type) }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var searchResult: SearchResult {
        SearchResult(name: name, detail: detail, lng: lng, lat: lat, source: .place)
    }
}

// MARK: - Zustaende des Such-Kerns

/// Typisierter Photon-Fehler — nie ein stilles catch.
public enum PhotonErrorKind: String, Sendable, Equatable {
    case offline
    case timeout
    case server
}

/// Ergebnis eines Photon-Aufrufs. Wirft nicht, klassifiziert.
public enum PhotonOutcome: Sendable, Equatable {
    case ok([SearchResult])
    case failure(PhotonErrorKind)
}

/// Zustand der Online-Quelle innerhalb eines Such-States.
public enum OnlineState: Sendable, Equatable {
    /// Query zu kurz fuer online (< `minQueryOnline`) — kein Fehler.
    case idle
    case loading
    case results([SearchResult])
    /// Geraet ist offline — Adresssuche nicht verfuegbar.
    case unavailableOffline
    /// `reason` ist nie `.offline` — dafuer gibt es `unavailableOffline`.
    case error(PhotonErrorKind)
}

/// Ladezustand des Offline-Ortsindex (lazy).
public enum IndexState: Sendable, Equatable {
    case unloaded
    case loading
    case ready(count: Int)
    case error(message: String)
}

/// Gesamt-State. Jede Variante ist von der UI unterscheidbar renderbar:
/// `idle` → Recents · `results` → Offline-Sektion zuerst, danach Online gemaess
/// `online` · `empty` → beide Quellen abgeschlossen und leer. `index` steckt in
/// jeder Variante, damit ein Ladefehler des Ortsindex immer sichtbar ist.
public enum SearchState: Sendable, Equatable {
    case idle(query: String, index: IndexState, recents: [SearchResult])
    case results(query: String, index: IndexState, offline: [SearchResult], online: OnlineState)
    case empty(query: String, index: IndexState, online: OnlineState)

    public var query: String {
        switch self {
        case .idle(let query, _, _), .results(let query, _, _, _), .empty(let query, _, _):
            return query
        }
    }

    public var index: IndexState {
        switch self {
        case .idle(_, let index, _), .results(_, let index, _, _), .empty(_, let index, _):
            return index
        }
    }

    public var offlineResults: [SearchResult] {
        if case .results(_, _, let offline, _) = self { return offline }
        return []
    }

    public var online: OnlineState {
        switch self {
        case .idle: return .idle
        case .results(_, _, _, let online), .empty(_, _, let online): return online
        }
    }
}
