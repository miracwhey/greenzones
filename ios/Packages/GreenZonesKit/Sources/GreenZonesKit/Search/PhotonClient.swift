import Foundation

/// Photon-Geocoder (Strassen/Adressen). Port von `client/src/lib/search/photon.ts`.
///
/// Der Client wirft nie — jeder Ausgang wird zu einem typisierten `PhotonOutcome`
/// klassifiziert (offline / timeout / server). Kein stilles catch: die Suche darf
/// nicht so aussehen, als gaebe es die Adresse nicht, wenn nur das Netz fehlt.
public protocol PhotonSource: Sendable {
    func search(_ query: String) async -> PhotonOutcome
}

/// Injizierbar fuer Tests — die Produktions-Implementierung ist URLSession.
public protocol PhotonTransport: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, data: Data)
}

public struct URLSessionPhotonTransport: PhotonTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

public struct PhotonClient: PhotonSource {
    public static let baseURL = "https://photon.komoot.io/api/"
    /// Deutschland-Box — Photon liefert sonst europaweit.
    public static let bbox = "5.8,47.2,15.1,55.1"
    public static let limit = 5
    public static let timeoutSeconds: TimeInterval = 5

    private let transport: any PhotonTransport
    private let isOnline: @Sendable () -> Bool
    private let timeout: TimeInterval

    /// `isOnline` ist der Ersatz fuer `navigator.onLine` aus v1. Ohne Injektion
    /// wird gefeuert und die URLError-Klassifikation entscheidet — das kostet
    /// keinen Timeout, weil iOS ohne Route sofort ablehnt.
    public init(transport: any PhotonTransport = URLSessionPhotonTransport(),
                isOnline: @escaping @Sendable () -> Bool = { true },
                timeout: TimeInterval = PhotonClient.timeoutSeconds) {
        self.transport = transport
        self.isOnline = isOnline
        self.timeout = timeout
    }

    public static func url(for query: String) -> URL {
        // encodeURIComponent-Zeichenvorrat, damit die URL Zeichen fuer Zeichen
        // dieselbe ist wie in v1 (Leerzeichen → %20, nicht +).
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) ?? query
        return URL(string: "\(baseURL)?limit=\(limit)&lang=de&bbox=\(bbox)&q=\(encoded)")!
    }

    public func search(_ query: String) async -> PhotonOutcome {
        // Ohne Netz gar nicht erst feuern — der Nutzer soll „offline" sehen,
        // nicht 5 s auf einen Timeout warten.
        guard isOnline() else { return .failure(.offline) }

        switch await race(query) {
        case .timedOut:
            return .failure(.timeout)
        case .rejected(let error):
            return .failure(Self.classify(error, isOnline: isOnline))
        case .resolved(let status, let data):
            guard (200..<300).contains(status) else { return .failure(.server) }
            return Self.parse(data)
        }
    }

    // MARK: - Antwort

    /// Unparsbarer Body ist ein Server-Fehler, kein leeres Ergebnis.
    static func parse(_ data: Data) -> PhotonOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let features = root["features"] as? [Any] else {
            return .failure(.server)
        }
        var results: [SearchResult] = []
        for feature in features {
            if let mapped = featureToResult(feature) { results.append(mapped) }
        }
        return .ok(results)
    }

    /// Photon-Feature → Result. Unveraendertes Mapping aus v1.
    static func featureToResult(_ feature: Any) -> SearchResult? {
        guard let feature = feature as? [String: Any] else { return nil }
        let properties = feature["properties"] as? [String: Any] ?? [:]
        guard let geometry = feature["geometry"] as? [String: Any],
              let coordinates = geometry["coordinates"] as? [Any],
              coordinates.count >= 2,
              let lng = coordinates[0] as? Double,
              let lat = coordinates[1] as? Double else {
            return nil
        }
        func string(_ key: String) -> String? {
            (properties[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let name = string("name") ?? string("street") ?? "Unbenannt"
        let detail = [string("postcode"), string("city") ?? string("county"), string("state")]
            .compactMap { $0 }
            .joined(separator: ", ")
        return SearchResult(name: name, detail: detail, lng: lng, lat: lat, source: .photon)
    }

    // MARK: - Fehler

    private static let timeoutPattern = "timeout|timed out|abort"
    private static let offlinePattern =
        "network|offline|failed to fetch|load failed|unreachable|enotfound|econnrefused|dns"

    static func classify(_ error: any Error, isOnline: () -> Bool) -> PhotonErrorKind {
        guard isOnline() else { return .offline }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
                 .internationalRoamingOff:
                return .offline
            default:
                break
            }
        }
        // Reihenfolge wie v1: Timeout schlaegt Netz — „Request timed out" nennt
        // beides, ist aber ein Timeout.
        let message = (error as? LocalizedStringError)?.message ?? "\(error)"
        if matches(message, timeoutPattern) { return .timeout }
        if matches(message, offlinePattern) { return .offline }
        return .server
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Rennen gegen die Uhr

    private enum RaceOutcome: Sendable {
        case resolved(status: Int, data: Data)
        case rejected(any Error)
        case timedOut
    }

    /// `URLRequest.timeoutInterval` deckt den echten Netzweg ab; das Rennen deckt
    /// jeden injizierten Transport ab, der einfach nie antwortet.
    private func race(_ query: String) async -> RaceOutcome {
        let url = Self.url(for: query)
        let transport = self.transport
        let timeout = self.timeout
        return await withTaskGroup(of: RaceOutcome?.self) { group in
            group.addTask {
                do {
                    let (status, data) = try await transport.get(url, timeout: timeout)
                    return .resolved(status: status, data: data)
                } catch {
                    return .rejected(error)
                }
            }
            group.addTask {
                // Abgebrochener Schlaf ist KEIN Timeout — sonst meldete jede
                // fertige Antwort nebenbei noch einen Timeout.
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return nil }
                return .timedOut
            }
            for await outcome in group {
                if let outcome {
                    group.cancelAll()
                    return outcome
                }
            }
            return .timedOut
        }
    }
}

/// Fehler mit selbst gesetzter Meldung — die Tests portieren damit die
/// Klassifikation aus v1 („Failed to fetch", „Request timed out", „boom").
public struct LocalizedStringError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
