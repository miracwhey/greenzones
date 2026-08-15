// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GreenZonesKit",
    // macOS ist kein Ziel-Betriebssystem der App, aber die Test-Suite laeuft
    // damit ohne Simulator (`swift test`) — die Zonen-Fixture ist 61,7 MB und
    // wird als Host-Pfad gelesen, nicht ins Testbundle kopiert.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GreenZonesKit", targets: ["GreenZonesKit"]),
    ],
    dependencies: [
        // SQLite fuer App-DB (Stores, Outbox) und die gebuendelte places.sqlite (FTS5).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "GreenZonesKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "GreenZonesKitTests",
            dependencies: ["GreenZonesKit"],
            resources: [.copy("Fixtures/zone_vectors.json")]
        ),
    ]
)
