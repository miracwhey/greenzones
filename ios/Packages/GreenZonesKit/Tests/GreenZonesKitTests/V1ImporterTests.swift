import Foundation
import GRDB
import Testing
@testable import GreenZonesKit

/// Uebernahme des v1-Bestands (SPEC 4). Die Fixtures sind woertlich die JSON-
/// Formen aus `client/shot_spots.mjs` — dieselben Objekte, die der v1-Client in
/// `CapacitorStorage.gz_*` geschrieben hat.
@Suite("V1Importer — Uebernahme aus CapacitorStorage")
@MainActor
struct V1ImporterTests {
    /// s1 ist geteilt (zoneName + Teilnehmer + shareURL), s2 bleibt rein lokal —
    /// beide Welten stehen im Fixture.
    private let spotsJSON = """
    [
      {"id":"s1","name":"Unsere Bank","emoji":"🪑","lng":9.7354,"lat":52.3733,"createdAt":1000,
       "zoneName":"spot-s1","participantIds":["f1","f2"],"shareURL":"https://www.icloud.com/share/s1"},
      {"id":"s2","name":"Maschsee-Ecke","emoji":"🌳","lng":9.7408,"lat":52.3693,"createdAt":2000}
    ]
    """

    /// Marcel hat ein Zeichen, Tara nicht — beide Avatar-Faelle.
    private let friendsJSON = """
    [
      {"id":"f1","name":"Marcel","emoji":"🎧","color":"#7C5CFF","friendshipZone":"friend-f1"},
      {"id":"f2","name":"Tara","color":"#0A9B8E","friendshipZone":"friend-f2"}
    ]
    """

    private let invitesJSON = """
    [
      {"id":"i1","spotId":"s1","hostId":"me","time":1800000000000,"createdAt":900,"cancelled":false,
       "replies":[{"participantId":"f1","status":"in"},
                  {"participantId":"f2","status":"in","arrivalTime":1800003600000}]}
    ]
    """

    private func defaults(_ values: [String: String]) -> UserDefaults {
        let name = "gz-v1-import-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        for (key, value) in values {
            defaults.set(value, forKey: V1Importer.storagePrefix + key)
        }
        return defaults
    }

    private func database(_ path: String? = nil) throws -> AppDatabase {
        try AppDatabase(path: path, migrations: CommunityMigrations.all)
    }

    @Test("uebernimmt Spots, Freunde, Einladungen und das Profil")
    func imports() throws {
        let db = try database()
        let defaults = defaults([
            V1Importer.spotsKey: spotsJSON,
            V1Importer.friendsKey: friendsJSON,
            V1Importer.invitesKey: invitesJSON,
            V1Importer.displayNameKey: "Leon",
            V1Importer.profileEmojiKey: "🌿",
        ])

        let result = try V1Importer.runIfNeeded(database: db, defaults: defaults)
        #expect(result.didRun)
        #expect(result.spots == 2)
        #expect(result.friends == 2)
        #expect(result.invitations == 1)

        let spots = SpotStore(db)
        #expect(spots.spots.map(\.id) == ["s1", "s2"])
        #expect(spots.spots[0].zoneName == "spot-s1")
        #expect(spots.spots[0].participantIds == ["f1", "f2"])
        #expect(spots.spots[0].shareURL == "https://www.icloud.com/share/s1")
        // Rein lokal — ohne den Import waere genau dieser Spot weg.
        #expect(spots.spots[1].zoneName == nil)
        #expect(spots.spots[1].name == "Maschsee-Ecke")

        let friends = FriendStore(db)
        #expect(friends.friends.map(\.name) == ["Marcel", "Tara"])
        #expect(friends.friends[0].emoji == "🎧")
        #expect(friends.friends[1].emoji == nil)

        let invites = InviteStore(db)
        #expect(invites.invitations.count == 1)
        #expect(invites.invitations[0].time == Date(epochMillis: 1_800_000_000_000))
        #expect(invites.invitations[0].replies.map(\.participantId) == ["f1", "f2"])
        #expect(invites.invitations[0].replies[1].arrivalTime
            == Date(epochMillis: 1_800_003_600_000))

        let settings = SettingsStore(db)
        #expect(settings.profile == Profile(displayName: "Leon", emoji: "🌿"))
    }

    @Test("laeuft genau einmal — ein spaeter geloeschter Spot kommt nicht zurueck")
    func runsOnce() async throws {
        let path = tempDatabasePath()
        let defaults = defaults([V1Importer.spotsKey: spotsJSON])

        #expect(try V1Importer.runIfNeeded(database: database(path), defaults: defaults).didRun)

        let db = try database(path)
        let spots = SpotStore(db)
        try await spots.removeSpot(id: "s2")
        #expect(spots.spots.map(\.id) == ["s1"])

        let second = try V1Importer.runIfNeeded(database: db, defaults: defaults)
        #expect(!second.didRun)
        #expect(SpotStore(try database(path)).spots.map(\.id) == ["s1"])
    }

    @Test("korrupter Speicher ergibt leeren Bestand statt Absturz")
    func corruptStorage() throws {
        let db = try database()
        let defaults = defaults([
            V1Importer.spotsKey: "{nope",
            V1Importer.friendsKey: "{\"friends\":[]}",
            V1Importer.invitesKey: "[",
        ])
        let result = try V1Importer.runIfNeeded(database: db, defaults: defaults)
        #expect(result.didRun)
        #expect(result.spots == 0)
        #expect(SpotStore(db).spots.isEmpty)
    }

    @Test("ein kaputter Eintrag faellt raus, nicht die ganze Liste")
    func partialList() throws {
        let db = try database()
        let raw = """
        [{"id":"kaputt"},null,"text",
         {"id":"gut","name":"Unsere Bank","emoji":"🌳","lng":9.72,"lat":52.36,"createdAt":1}]
        """
        let result = try V1Importer.runIfNeeded(database: db,
                                                defaults: defaults([V1Importer.spotsKey: raw]))
        #expect(result.spots == 1)
        #expect(SpotStore(db).spots.map(\.id) == ["gut"])
    }

    @Test("ein kaputtes Cloud-Feld verwirft das Feld, nicht den Spot")
    func brokenCloudField() throws {
        let db = try database()
        let raw = """
        [{"id":"s1","name":"Unsere Bank","emoji":"🌳","lng":9.72,"lat":52.36,"createdAt":1,
          "zoneName":7,"participantIds":["f1"],"sharePending":true}]
        """
        _ = try V1Importer.runIfNeeded(database: db, defaults: defaults([V1Importer.spotsKey: raw]))
        let spot = try #require(SpotStore(db).spots.first)
        #expect(spot.name == "Unsere Bank")
        #expect(spot.zoneName == nil)
        #expect(spot.participantIds.isEmpty)
        #expect(!spot.sharePending)
    }

    @Test("eine kaputte Antwort faellt raus, die Einladung bleibt")
    func brokenReply() throws {
        let db = try database()
        let invites = """
        [{"id":"i1","spotId":"s1","hostId":"me","time":5,"createdAt":4,"cancelled":false,
          "replies":[{"participantId":"f1","status":"in"},{"participantId":"f3"},{"status":"in"}]}]
        """
        _ = try V1Importer.runIfNeeded(database: db, defaults: defaults([
            V1Importer.spotsKey: spotsJSON, V1Importer.invitesKey: invites,
        ]))
        let store = InviteStore(db)
        #expect(store.invitations.count == 1)
        #expect(store.invitations[0].replies.map(\.participantId) == ["f1"])
    }

    @Test("eine Einladung ohne ihren Spot wird nicht uebernommen")
    func orphanInvitation() throws {
        let db = try database()
        let invites = """
        [{"id":"i1","spotId":"weg","hostId":"me","time":5,"createdAt":4,"cancelled":false,"replies":[]}]
        """
        let result = try V1Importer.runIfNeeded(database: db, defaults: defaults([
            V1Importer.spotsKey: spotsJSON, V1Importer.invitesKey: invites,
        ]))
        #expect(result.invitations == 0)
        #expect(InviteStore(db).invitations.isEmpty)
    }

    @Test("uebernimmt die beantwortete Profil-Frage, damit sie nicht erneut kommt")
    func profileAsked() throws {
        let db = try database()
        _ = try V1Importer.runIfNeeded(database: db, defaults: defaults([
            V1Importer.friendsKey: friendsJSON,
            V1Importer.profileAskedKey: "1",
        ]))
        #expect(SettingsStore(db).profileAsked)
    }

    @Test("leerer Speicher: Marker steht trotzdem, der Import wiederholt sich nicht")
    func emptyStorage() throws {
        let db = try database()
        let result = try V1Importer.runIfNeeded(database: db, defaults: defaults([:]))
        #expect(result.didRun)
        #expect(result.spots == 0)
        let second = try V1Importer.runIfNeeded(database: db, defaults: defaults([:]))
        #expect(!second.didRun)
    }
}
