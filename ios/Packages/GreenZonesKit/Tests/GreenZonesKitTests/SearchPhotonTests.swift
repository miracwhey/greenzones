import Foundation
import Testing
@testable import GreenZonesKit

/// Port von `client/src/lib/search/__tests__/photon.test.ts` (12 Fälle).
/// Die Antwort wird injiziert — kein Test fasst das Netz an.
@Suite("PhotonClient — URL, Mapping, Fehlerklassifikation")
struct SearchPhotonTests {
    /// Transport mit fester Antwort; merkt sich die Aufrufe.
    actor RecordingTransport: PhotonTransport {
        enum Reply: @unchecked Sendable {
            case response(status: Int, body: Data)
            case failure(any Error)
            case never
        }

        private let reply: Reply
        private(set) var calls: [(url: URL, timeout: TimeInterval)] = []

        init(_ reply: Reply) { self.reply = reply }

        func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, data: Data) {
            calls.append((url, timeout))
            switch reply {
            case .response(let status, let body): return (status, body)
            case .failure(let error): throw error
            case .never:
                // Nie antworten — das Rennen gegen die Uhr muss greifen.
                try await Task.sleep(for: .seconds(60))
                return (200, Data())
            }
        }
    }

    /// Photon-Antwort im FeatureCollection-Format (Port von `photonBody`).
    static func body(_ features: [[String: Any]]) -> Data {
        let collection: [String: Any] = [
            "type": "FeatureCollection",
            "features": features.map { feature -> [String: Any] in
                var properties = feature
                let lng = properties.removeValue(forKey: "lng") as? Double ?? 0
                let lat = properties.removeValue(forKey: "lat") as? Double ?? 0
                return ["type": "Feature",
                        "geometry": ["type": "Point", "coordinates": [lng, lat]],
                        "properties": properties]
            },
        ]
        return try! JSONSerialization.data(withJSONObject: collection)
    }

    private func client(_ reply: RecordingTransport.Reply, online: Bool = true,
                        timeout: TimeInterval = 5) -> (PhotonClient, RecordingTransport) {
        let transport = RecordingTransport(reply)
        return (PhotonClient(transport: transport, isOnline: { online }, timeout: timeout), transport)
    }

    // MARK: - URL

    @Test("baut die Deutschland-begrenzte URL und encodiert die Query")
    func url() {
        #expect(PhotonClient.url(for: "Lange Laube 1").absoluteString
                == "https://photon.komoot.io/api/?limit=5&lang=de&bbox=5.8,47.2,15.1,55.1&q=Lange%20Laube%201")
    }

    // MARK: - Erfolgsfall

    @Test("mappt Features auf Result (name/street, postcode + city/county + state)")
    func mapping() async {
        let data = Self.body([
            ["name": "Lange Laube", "postcode": "30159", "city": "Hannover",
             "state": "Niedersachsen", "lng": 9.73, "lat": 52.37],
            ["street": "Feldweg", "postcode": "31311", "county": "Region Hannover",
             "state": "Niedersachsen", "lng": 9.9, "lat": 52.4],
            ["postcode": "12345", "lng": 8.0, "lat": 50.0],
        ])
        let (client, _) = client(.response(status: 200, body: data))
        let outcome = await client.search("lange laube")
        #expect(outcome == .ok([
            SearchResult(name: "Lange Laube", detail: "30159, Hannover, Niedersachsen",
                         lng: 9.73, lat: 52.37, source: .photon),
            SearchResult(name: "Feldweg", detail: "31311, Region Hannover, Niedersachsen",
                         lng: 9.9, lat: 52.4, source: .photon),
            SearchResult(name: "Unbenannt", detail: "12345", lng: 8, lat: 50, source: .photon),
        ]))
    }

    @Test("Features ohne brauchbare Koordinate fallen raus, der Rest bleibt")
    func skipsBrokenFeature() async {
        let broken = #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Kaputt"}},{"type":"Feature","geometry":{"type":"Point","coordinates":[9.0,52.0]},"properties":{"name":"Heil"}}]}"#
        let (client, _) = client(.response(status: 200, body: Data(broken.utf8)))
        #expect(await client.search("x") == .ok([
            SearchResult(name: "Heil", detail: "", lng: 9, lat: 52, source: .photon),
        ]))
    }

    @Test("setzt den Timeout auf dem Transport")
    func timeoutPassed() async {
        let (client, transport) = client(.response(status: 200, body: Self.body([])))
        _ = await client.search("abc")
        #expect(await transport.calls.first?.timeout == PhotonClient.timeoutSeconds)
    }

    @Test("leere Antwort ist ein leeres Ergebnis, kein Fehler")
    func emptyOK() async {
        let (client, _) = client(.response(status: 200, body: Self.body([])))
        #expect(await client.search("abc") == .ok([]))
    }

    // MARK: - Fehlerklassifikation

    @Test("offline: feuert gar nicht erst")
    func offlineNoCall() async {
        let (client, transport) = client(.response(status: 200, body: Self.body([])), online: false)
        #expect(await client.search("hannover") == .failure(.offline))
        #expect(await transport.calls.isEmpty)
    }

    @Test("timeout: Antwort bleibt aus")
    func timeoutSilent() async {
        let (client, _) = client(.never, timeout: 0.05)
        #expect(await client.search("hannover") == .failure(.timeout))
    }

    @Test("timeout: Transport meldet selbst einen Timeout")
    func timeoutReported() async {
        let (client, _) = client(.failure(LocalizedStringError("Request timed out")))
        #expect(await client.search("hannover") == .failure(.timeout))
    }

    @Test("timeout: URLError.timedOut")
    func timeoutURLError() async {
        let (client, _) = client(.failure(URLError(.timedOut)))
        #expect(await client.search("hannover") == .failure(.timeout))
    }

    @Test("server: HTTP 500")
    func serverStatus() async {
        let (client, _) = client(.response(status: 500, body: Self.body([])))
        #expect(await client.search("hannover") == .failure(.server))
    }

    @Test("server: unparsbarer Body ist kein leeres Ergebnis")
    func serverUnparsable() async {
        let (client, _) = client(.response(status: 200, body: Data("<html>bad gateway</html>".utf8)))
        #expect(await client.search("hannover") == .failure(.server))
    }

    @Test("server: JSON ohne features")
    func serverNoFeatures() async {
        let (client, _) = client(.response(status: 200, body: Data(#"{"message":"nope"}"#.utf8)))
        #expect(await client.search("hannover") == .failure(.server))
    }

    @Test("offline: Netzwerkfehler des Transports")
    func offlineNetworkError() async {
        let (client, _) = client(.failure(LocalizedStringError("Failed to fetch")))
        #expect(await client.search("hannover") == .failure(.offline))
    }

    @Test("offline: URLError.notConnectedToInternet")
    func offlineURLError() async {
        let (client, _) = client(.failure(URLError(.notConnectedToInternet)))
        #expect(await client.search("hannover") == .failure(.offline))
    }

    @Test("server: unbekannter Fehler bleibt nicht still")
    func unknownError() async {
        let (client, _) = client(.failure(LocalizedStringError("boom")))
        #expect(await client.search("hannover") == .failure(.server))
    }
}
