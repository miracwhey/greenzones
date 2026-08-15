import Foundation
import GRDB
import Testing
@testable import GreenZonesKit

/// Die App setzt ihre Migrationsliste aus den Feature-Saetzen zusammen
/// (`SearchMigrations.all + CommunityMigrations.all`). Jeder Satz ist fuer sich
/// getestet — die Naht dazwischen war es nicht: doppelte Bezeichner lassen den
/// Migrator scheitern, und ein Feature, das eine fremde Tabelle voraussetzt,
/// faellt nur in dieser Kombination auf. Beide Faelle wuerden erst beim
/// Kaltstart auf dem Geraet auffliegen, wo `AppModel` mit `fatalError` abbricht.
@Suite("Migrationen — beide Feature-Saetze in EINER Datenbank")
struct MigrationCompositionTests {
    private var combined: [DBMigration] { SearchMigrations.all + CommunityMigrations.all }

    @Test("Bezeichner sind ueber die Saetze hinweg eindeutig")
    func identifiersAreUnique() {
        let ids = combined.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Kaltstart legt die Tabellen beider Features an")
    func coldStartCreatesEveryTable() throws {
        let database = try AppDatabase.inMemory(migrations: combined)
        let tables = ["recent_search", "spot", "spot_participant",
                      "friend", "invitation", "reply", "setting"]
        let missing = try database.writer.read { db in
            try tables.filter { try !db.tableExists($0) }
        }
        #expect(missing.isEmpty, "Tabellen fehlen: \(missing.joined(separator: ", "))")
    }

    /// Reihenfolge-Probe: eine Datenbank, die nur die Community-Schritte kennt
    /// (Stand des W3-Worktrees), muss den davor registrierten Suchschritt
    /// nachtragen, statt den Start zu kippen.
    @Test("Nachtrag: bestehende Datenbank ohne den Suchschritt migriert weiter")
    func lateRegisteredStepIsAppliedToExistingDatabase() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("gz-migrate-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try AppDatabase(path: path, migrations: CommunityMigrations.all)
        let upgraded = try AppDatabase(path: path, migrations: combined)

        let (hasRecents, hasSpots) = try upgraded.writer.read { db in
            (try db.tableExists("recent_search"), try db.tableExists("spot"))
        }
        #expect(hasRecents)
        #expect(hasSpots)
    }
}
