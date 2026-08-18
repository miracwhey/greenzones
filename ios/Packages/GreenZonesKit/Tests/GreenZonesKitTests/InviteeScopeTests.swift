import Foundation
import GRDB
import Testing
@testable import GreenZonesKit

/// Zwei Ebenen (Leon, 18.08.): wer den Spot dauerhaft sieht, ist eine
/// Eigenschaft des Spots — wen ein Termin meint, eine der Einladung. Man kann
/// fünf Kollegen am Spot haben und zwei davon einladen.
///
/// Der heikle Teil ist nicht das Auswählen, sondern der **Bestand**: alle
/// Einladungen, die vor dieser Änderung entstanden sind, haben keine Liste. Ein
/// Pflichtfeld hätte sie für niemanden mehr sichtbar gemacht.
@Suite("Einladungs-Kreis — Teilmenge der Spot-Runde")
@MainActor
struct InviteeScopeTests {
    private var epoch: Date { Date(epochMillis: 1_800_000_000_000) }

    private func invitation(_ inviteeIds: [String]) -> Invitation {
        Invitation(id: "i1", spotId: "s1", hostId: "host", time: epoch, createdAt: epoch,
                   cancelled: false, inviteeIds: inviteeIds)
    }

    @Test("Leere Liste heißt „alle Spot-Mitglieder“ — sonst verschwindet der Bestand")
    func emptyMeansEveryone() {
        let old = invitation([])
        let round = ["f1", "f2", "f3"]

        #expect(old.invitees(spotParticipants: round) == round)
        #expect(old.concerns("f3", spotParticipants: round))
    }

    @Test("Mit Auswahl zählt nur die Auswahl")
    func subsetExcludesTheRest() {
        let picked = invitation(["f1", "f2"])
        let round = ["f1", "f2", "f3"]

        #expect(picked.concerns("f1", spotParticipants: round))
        #expect(!picked.concerns("f3", spotParticipants: round),
                "f3 ist am Spot, aber nicht eingeladen")
    }

    @Test("Der Gastgeber ist immer gemeint — er hat eingeladen")
    func hostAlwaysConcerned() {
        let picked = invitation(["f1"])
        #expect(picked.concerns("host", spotParticipants: ["f1", "f2"]))
    }

    @Test("Die Auswahl überlebt Speichern und Neuöffnen")
    func roundTripsThroughTheDatabase() async throws {
        let path = tempDatabasePath()
        let database = try AppDatabase(path: path, migrations: CommunityMigrations.all)
        // Die Einladung hängt am Spot (Fremdschlüssel) — ohne ihn gibt es sie nicht.
        let spot = try await SpotStore(database).addSpot(name: "Unsere Bank", emoji: "🪑",
                                                          lng: 9.72, lat: 52.36)
        var draft = invitation(["f2", "f1"])
        draft.spotId = spot.id
        try await InviteStore(database).add(draft)

        let reader = InviteStore(try AppDatabase(path: path, migrations: CommunityMigrations.all))
        // Sortiert: die Menge ist die Aussage, nicht die Eingabereihenfolge.
        #expect(reader.invitation(id: "i1")?.inviteeIds == ["f1", "f2"])
    }

    /// Auf Leons Gerät liegt eine Datenbank mit `community_v1` und echten
    /// Einladungen. Der neue Schritt muss darauf aufsetzen, ohne sie anzufassen
    /// — und die Alt-Einladung muss danach weiter für alle gelten.
    @Test("Der neue Migrationsschritt setzt auf eine bestehende v1-Datenbank auf")
    func migrationKeepsExistingInvitations() async throws {
        let path = tempDatabasePath()
        let v1 = try #require(CommunityMigrations.all.first)
        #expect(v1.id == "community_v1")

        let before = try AppDatabase(path: path, migrations: [v1])
        let spots = SpotStore(before)
        let spot = try await spots.addSpot(name: "Unsere Bank", emoji: "🪑",
                                           lng: 9.72, lat: 52.36)
        // Die Alt-Zeile entsteht per SQL, nicht über den heutigen Store: der
        // schreibt inzwischen in `invitation_invitee`, die es unter v1 nicht
        // gibt. Über ihn geschrieben wäre das keine Zeile von damals, sondern
        // eine von heute — und der Aufstieg bliebe ungeprüft.
        let stamp = epoch.epochMillis
        try await before.writer.write { db in
            try db.execute(sql: """
                INSERT INTO invitation (id, spotId, hostId, time, createdAt, cancelled)
                VALUES (?, ?, ?, ?, ?, 0)
                """,
                arguments: ["alt", spot.id, "host", stamp, stamp])
        }

        let after = try AppDatabase(path: path, migrations: CommunityMigrations.all)
        let store = InviteStore(after)
        let old = try #require(store.invitation(id: "alt"))

        #expect(old.inviteeIds.isEmpty, "eine Alt-Einladung hat keine Liste")
        #expect(old.concerns("f9", spotParticipants: ["f9"]),
                "und gilt deshalb weiter für die ganze Runde")
    }

    @Test("Die Auswahl geht mit in die Cloud")
    func selectionReachesTheCloud() async throws {
        let gateway = FakeGateway()
        let database = try AppDatabase(path: nil, migrations: CommunityMigrations.all)
        let spots = SpotStore(database)
        let sync = SyncCoordinator(gateway: gateway, spots: spots, friends: FriendStore(database),
                                   invites: InviteStore(database), settings: SettingsStore(database))
        let spot = try await spots.addSpot(name: "Unsere Bank", emoji: "🪑", lng: 9.72, lat: 52.36)
        try await spots.setCloudState(id: spot.id,
                                      SpotCloudState(zoneName: "spot-s1", ownerId: SELF_ID,
                                                     participantIds: ["f1", "f2", "f3"]))

        let invitation = try await sync.invite(spotId: spot.id, time: epoch,
                                               inviteeIds: ["f1", "f2"])

        #expect(gateway.savedInvitees[invitation.id] == ["f1", "f2"])
    }
}
