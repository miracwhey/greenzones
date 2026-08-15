import Foundation
import GRDB

/// Ein Migrationsschritt eines Features. Die Features (Suche, Community, Snaps)
/// bringen ihre Tabellen selbst mit; die Composition Root sammelt die Schritte
/// ein und uebergibt sie hier — so schreibt kein Feature an einer zentralen
/// Migrationsliste herum.
public struct DBMigration: Sendable {
    public let id: String
    public let up: @Sendable (Database) throws -> Void

    public init(_ id: String, up: @escaping @Sendable (Database) throws -> Void) {
        self.id = id
        self.up = up
    }
}

/// Die App-Datenbank (`greenzones.sqlite` in Application Support). Eine Instanz
/// pro Prozess; Tests nutzen `inMemory`.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// `path == nil` → In-Memory (Tests, Fixture-Laeufe).
    public init(path: String?, migrations: [DBMigration]) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        if let path {
            writer = try DatabasePool(path: path, configuration: config)
        } else {
            writer = try DatabaseQueue(configuration: config)
        }
        var migrator = DatabaseMigrator()
        for step in migrations {
            migrator.registerMigration(step.id, migrate: step.up)
        }
        try migrator.migrate(writer)
    }

    public static func inMemory(migrations: [DBMigration]) throws -> AppDatabase {
        try AppDatabase(path: nil, migrations: migrations)
    }

    /// Standardpfad der App-DB; legt das Verzeichnis an.
    public static func defaultPath() throws -> String {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil,
                                              create: true)
        return dir.appendingPathComponent("greenzones.sqlite").path
    }
}
