import Foundation

/// Pfade der grossen Fixtures.
///
/// `zones.pmtiles` (61,7 MB) wird NICHT ins Testbundle kopiert — es gibt genau
/// eine Quelle (SPEC E6), und die liegt im Repo unter `client/public/`. Der Pfad
/// wird aus `#filePath` abgeleitet, nicht aus dem Arbeitsverzeichnis.
enum TestPaths {
    /// …/ios/Packages/GreenZonesKit/Tests/GreenZonesKitTests/TestSupport.swift
    static let repositoryRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GreenZonesKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // GreenZonesKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // <repo>
    }()

    static let zonesPMTiles = repositoryRoot
        .appendingPathComponent("client/public/zones.pmtiles")

    static let zoneVectors = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/zone_vectors.json")
}

/// Ein Vektor aus `zone_vectors.json` — das Urteil der v1-Engine an einem Punkt.
struct ZoneVector: Decodable {
    struct Layer: Decodable {
        let inside: Bool
        /// `null` im JSON = Infinity (keine Zone im Suchradius).
        let nearestM: Double?
    }

    let lat: Double
    let lng: Double
    let note: String
    let ban: Layer
    let time: Layer
}

struct ZoneVectorFile: Decodable {
    let count: Int
    let points: [ZoneVector]
}
