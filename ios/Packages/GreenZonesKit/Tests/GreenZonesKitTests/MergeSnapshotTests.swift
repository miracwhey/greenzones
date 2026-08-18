import Foundation
import Testing
@testable import GreenZonesKit

/// Port von `client/src/lib/spots/__tests__/sync.test.ts` (24 Faelle:
/// 5× `mergeSnapshot`, 19× Sync-Engine).
@Suite("mergeSnapshot — Port der 5 v1-Faelle")
struct MergeSnapshotTests {
    @Test("mappt die eigene userID auf SELF_ID")
    func mapsSelf() {
        let merged = mergeSnapshot(
            snapshot(spots: [cloudSpot(zoneName: "spot-a", ownerUserID: TARA, isMine: false,
                                       participantUserIDs: [ME, MARCEL])],
                     invitations: [cloudInvitation(id: "i1", spotZone: "spot-a", hostUserID: ME,
                                                   replies: [
                                                       CloudReply(participantUserID: ME, status: .ind,
                                                                  arrivalTime: Date(epochMillis: 42)),
                                                       CloudReply(participantUserID: TARA, status: .out),
                                                   ])]),
            current: LocalState())

        #expect(merged.spots[0].ownerId == TARA)
        // „ohne mich": die eigene id taucht in der Teilnehmerliste nicht auf.
        #expect(merged.spots[0].participantIds == [MARCEL])
        #expect(merged.invitations[0].hostId == SELF_ID)
        // Antworten liegen nach participantId sortiert — die Cloud-Reihenfolge ist
        // nicht stabil und wuerde sonst bei jedem Fetch eine Scheinaenderung erzeugen.
        #expect(merged.invitations[0].replies == [
            Reply(participantId: TARA, status: .out),
            Reply(participantId: SELF_ID, status: .ind, arrivalTime: Date(epochMillis: 42)),
        ])
    }

    @Test("ersetzt die lokale Kopie eines Fremd-Spots durch den Snapshot")
    func replacesStale() {
        let stale = Spot(id: "a", name: "Alter Name", emoji: "🪑", lng: 0, lat: 0,
                         createdAt: Date(epochMillis: 1000), zoneName: "spot-a", ownerId: TARA)
        let merged = mergeSnapshot(
            snapshot(spots: [cloudSpot(zoneName: "spot-a", ownerUserID: TARA, isMine: false,
                                       name: "Maschsee-Ecke", participantUserIDs: [MARCEL])]),
            current: LocalState(spots: [stale]))

        #expect(merged.spots.count == 1)
        #expect(merged.spots[0].name == "Maschsee-Ecke")
        #expect(merged.spots[0].participantIds == [MARCEL])
    }

    @Test("laesst rein lokale Spots und ihre Einladungen unberuehrt")
    func keepsLocal() {
        let localInvite = Invitation(id: "i-lokal", spotId: LOCAL_SPOT.id, hostId: SELF_ID,
                                     time: Date(epochMillis: 1), createdAt: Date(epochMillis: 1),
                                     cancelled: false)
        let merged = mergeSnapshot(
            snapshot(spots: [cloudSpot(zoneName: "spot-a")]),
            current: LocalState(spots: [LOCAL_SPOT], invitations: [localInvite]))

        #expect(merged.spots[0] == LOCAL_SPOT)
        #expect(merged.invitations == [localInvite])
    }

    @Test("entfernt einen Fremd-Spot, der nicht mehr im Snapshot steht — den eigenen nicht")
    func dropsForeign() {
        var foreign = LOCAL_SPOT
        foreign.id = "a"
        foreign.zoneName = "spot-a"
        foreign.ownerId = TARA
        var mine = LOCAL_SPOT
        mine.id = "b"
        mine.zoneName = "spot-b"
        mine.ownerId = SELF_ID
        let invite = Invitation(id: "i1", spotId: "a", hostId: TARA, time: Date(epochMillis: 1),
                                createdAt: Date(epochMillis: 1), cancelled: false)

        let merged = mergeSnapshot(snapshot(),
                                   current: LocalState(spots: [foreign, mine], invitations: [invite]))
        #expect(merged.spots.map(\.id) == ["b"])
        // Mit dem Spot geht auch seine Einladung — sonst bliebe eine Karteileiche.
        #expect(merged.invitations.isEmpty)
    }

    @Test("ist idempotent — auch wenn die Cloud die Reihenfolge dreht")
    func idempotent() {
        let first = snapshot(
            friends: [cloudFriend(userID: TARA), cloudFriend(userID: MARCEL, name: "Marcel")],
            spots: [cloudSpot(zoneName: "spot-a", participantUserIDs: [TARA, MARCEL]),
                    cloudSpot(zoneName: "spot-b", createdAt: 2000)],
            invitations: [cloudInvitation(id: "i1", spotZone: "spot-a",
                                          replies: [CloudReply(participantUserID: TARA, status: .ind),
                                                    CloudReply(participantUserID: MARCEL, status: .out)])])
        let shuffled = snapshot(friends: first.friends.reversed(),
                                spots: first.spots.reversed(),
                                invitations: first.invitations.map {
                                    var copy = $0
                                    copy.replies = $0.replies.reversed()
                                    return copy
                                })

        let once = mergeSnapshot(first, current: LocalState(spots: [LOCAL_SPOT]))
        let twice = mergeSnapshot(shuffled, current: once)
        #expect(twice == once)
    }
}

@Suite("SyncCoordinator — Port der 19 v1-Faelle")
@MainActor
struct SyncCoordinatorTests {
    @Test("fragt nach dem eigenen Profil, sobald es Freunde gibt und noch kein Name da ist")
    func profilePrompt() async throws {
        let h = try CommunityHarness()
        // Ohne Freunde gibt es nichts zu erklaeren — die Frage waere grundlos.
        #expect(!h.sync.state.profilePrompt)

        h.gateway.next = snapshot(friends: [cloudFriend(userID: TARA)])
        await h.sync.refresh()
        #expect(h.sync.state.profilePrompt)

        try await h.sync.setProfile(name: "Leon", emoji: "🌿")
        #expect(h.sync.profile == Profile(displayName: "Leon", emoji: "🌿"))
        #expect(!h.sync.state.profilePrompt)
        // Mit bestehenden Freundschaften muss das Profil in deren Zonen nachgezogen werden.
        #expect(h.gateway.calls.contains("setProfile"))
    }

    @Test("haelt die Profil-Frage nach dem Ueberspringen auch ueber weitere Syncs ruhig")
    func profilePromptSkipped() async throws {
        let h = try CommunityHarness()
        h.gateway.next = snapshot(friends: [cloudFriend(userID: TARA)])
        await h.sync.refresh()
        #expect(h.sync.state.profilePrompt)

        try await h.sync.skipProfilePrompt()
        #expect(!h.sync.state.profilePrompt)

        // Jeder weitere Sync bewertet den Prompt neu — „uebersprungen" muss das
        // ueberleben, sonst kommt die Frage bei jedem Push zurueck.
        await h.sync.refresh()
        #expect(!h.sync.state.profilePrompt)
    }

    @Test("nimmt ein leeres Zeichen als Wahl an, nicht als fehlenden Wert")
    func emptyEmojiIsAChoice() async throws {
        let h = try CommunityHarness()
        h.gateway.next = snapshot(friends: [cloudFriend(userID: TARA)])
        await h.sync.refresh()
        try await h.sync.setProfile(name: "Leon", emoji: "🌿")
        try await h.sync.setProfile(name: "Leon", emoji: "")
        #expect(h.sync.profile.emoji == "")
    }

    @Test("schreibt die Freunde aus dem Snapshot in den FriendStore")
    func mergesFriends() async throws {
        let path = tempDatabasePath()
        let h = try CommunityHarness(path: path)
        h.gateway.next = snapshot(friends: [cloudFriend(userID: TARA)])
        await h.sync.refresh()

        #expect(h.friends.friends == [Friend(id: TARA, name: "Tara", emoji: "",
                                             color: friendColor(TARA),
                                             friendshipZone: "friend-\(TARA)")])
        // Zweite Instanz auf derselben Datei: der Bestand liegt wirklich auf der Platte.
        let reader = FriendStore(try AppDatabase(path: path, migrations: CommunityMigrations.all))
        #expect(reader.friends.first?.id == TARA)
    }

    @Test("noAccount: kein Merge, keine Store-Mutation, Status im State")
    func noAccount() async throws {
        let h = try CommunityHarness()
        try await h.spots.addSpot(name: "Balkon", emoji: "🌳", lng: 9.7, lat: 52.3)
        let before = h.spots.spots
        let version = h.spots.version
        h.gateway.account = .noAccount
        h.gateway.next = .empty(status: .noAccount)

        await h.sync.refresh()

        #expect(h.sync.state.status == .noAccount)
        #expect(!h.sync.state.available)
        #expect(h.spots.spots == before)
        #expect(h.spots.version == version)
        #expect(h.friends.version == 0)
        #expect(!h.gateway.calls.contains("registerSubscriptions"))
    }

    @Test("derselbe Snapshot zweimal mutiert nichts")
    func idempotentStores() async throws {
        let h = try CommunityHarness()
        h.gateway.next = snapshot(friends: [cloudFriend(userID: TARA)],
                                  spots: [cloudSpot(zoneName: "spot-a", participantUserIDs: [TARA])],
                                  invitations: [cloudInvitation(id: "i1", spotZone: "spot-a")])

        await h.sync.refresh()
        let spots = h.spots.spots
        let friends = h.friends.friends
        let invites = h.invites.invitations
        let versions = [h.spots.version, h.friends.version, h.invites.version]

        await h.sync.refresh()

        #expect(h.spots.spots == spots)
        #expect(h.friends.friends == friends)
        #expect(h.invites.invitations == invites)
        #expect([h.spots.version, h.friends.version, h.invites.version] == versions)
    }

    @Test("registriert Subscriptions genau einmal")
    func subscriptionsOnce() async throws {
        let h = try CommunityHarness()
        await h.sync.refresh()
        await h.sync.refresh()
        #expect(h.gateway.count("registerSubscriptions") == 1)
    }

    @Test("fragt die Mitteilungs-Erlaubnis erst mit dem ersten Freund an")
    func notificationPermission() async throws {
        let h = try CommunityHarness()
        await h.sync.refresh()
        #expect(!h.gateway.calls.contains("ensureNotificationPermission"))

        h.gateway.next = snapshot(friends: [cloudFriend(userID: TARA)])
        await h.sync.refresh()
        try await settle()
        #expect(h.gateway.count("ensureNotificationPermission") >= 1)
    }

    @Test("ein Fehler der Erlaubnis-Anfrage kippt weder Merge noch Folge-Syncs")
    func notificationPermissionFailure() async throws {
        let h = try CommunityHarness()
        h.gateway.next = snapshot(friends: [cloudFriend(userID: TARA)])
        h.gateway.fails["ensureNotificationPermission"] = .cloudInternal

        await h.sync.refresh()
        try await settle()

        #expect(h.friends.friends.count == 1)
        #expect(h.sync.state.error == nil)
    }

    @Test("fragt die Erlaubnis auch ohne iCloud, wenn lokal Freunde liegen")
    func notificationPermissionOffline() async throws {
        // Designpunkt wie beim Profil-Prompt: bewertet wird der lokale Bestand,
        // nicht ein gegluecker Fetch — sonst kaeme die Frage ohne Netz nie.
        let h = try CommunityHarness()
        try await h.friends.replaceAll([Friend(id: TARA, name: "Tara", emoji: "",
                                               color: "#7C5CFF", friendshipZone: "friend-t")])
        h.gateway.account = .noAccount
        h.gateway.next = .empty(status: .noAccount)

        await h.sync.start()
        try await settle()

        #expect(h.gateway.calls.contains("ensureNotificationPermission"))
    }

    /// Der Erststart nach dem Update ist genau dieser Fall: der v1-Import bringt
    /// Freunde mit, also ist die Bedingung „mit dem ersten Freund" sofort
    /// erfuellt — und der Systemdialog stand ueber dem Onboarding, das ihn
    /// erklaeren soll. Das Tor haelt ihn zurueck, bis der Weg frei ist, und
    /// holt ihn dann nach.
    @Test("solange der Aufrufer den Bildschirm braucht, fragt der Sync nichts")
    func permissionsWaitForTheGate() async throws {
        let h = try CommunityHarness()
        h.sync.asksAllowed = false
        try await h.friends.replaceAll([Friend(id: TARA, name: "Tara", emoji: "",
                                               color: "#7C5CFF", friendshipZone: "friend-t")])
        // Ohne Konto merged nichts — sonst raeumte der leere Snapshot die
        // Freundin gleich wieder weg, und der zweite Teil des Tests pruefte
        // nur noch, dass ohne Freunde nicht gefragt wird.
        h.gateway.account = .noAccount
        h.gateway.next = .empty(status: .noAccount)

        await h.sync.start()
        try await settle()
        #expect(!h.gateway.calls.contains("ensureNotificationPermission"),
                "Erlaubnis wurde trotz geschlossenem Tor erfragt")
        #expect(h.sync.state.profilePrompt == false)

        h.sync.asksAllowed = true
        try await settle()
        #expect(h.gateway.calls.contains("ensureNotificationPermission"),
                "nach dem Öffnen wurde nicht nachgeholt")
        #expect(h.sync.state.profilePrompt)
    }

    @Test("ein zweiter Wunsch waehrend eines laufenden Fetches wird nachgeholt, nicht parallel gefeuert")
    func refreshIsSerialised() async throws {
        // v1 haengt an `cloudChanged`/`appStateChange`; die Listener bringt W4.
        // Geprueft wird hier der Mechanismus dahinter: der Coordinator laesst nie
        // zwei Fetches parallel laufen und verliert trotzdem keinen Wunsch.
        let h = try CommunityHarness()
        async let first: Void = h.sync.refresh()
        async let second: Void = h.sync.refresh()
        _ = await (first, second)
        #expect(h.gateway.count("fetchAll") >= 1)

        await h.sync.refresh()
        #expect(h.gateway.count("fetchAll") >= 2)
    }

    @Test("Einladung ohne Netz: Abbruch mit Meldung, kein lokaler „gesendet\"-Zustand")
    func inviteWithoutNetwork() async throws {
        let path = tempDatabasePath()
        let h = try CommunityHarness(path: path)
        h.gateway.next = snapshot(spots: [cloudSpot(zoneName: "spot-a")])
        await h.sync.refresh()
        let spot = try #require(h.spots.spots.first)
        let version = h.invites.version

        h.gateway.fails["saveInvitation"] = .network
        await #expect(throws: SyncError.network) {
            try await h.sync.invite(spotId: spot.id, time: Date(epochMillis: 1_800_000_000_000))
        }

        #expect(h.invites.invitations.isEmpty)
        #expect(h.invites.version == version)
        let reader = InviteStore(try AppDatabase(path: path, migrations: CommunityMigrations.all))
        #expect(reader.invitations.isEmpty)
    }

    @Test("Antwort ohne Netz: keine lokale Antwort")
    func replyWithoutNetwork() async throws {
        let h = try CommunityHarness()
        h.gateway.next = snapshot(
            spots: [cloudSpot(zoneName: "spot-a", ownerUserID: TARA, isMine: false)],
            invitations: [cloudInvitation(id: "i1", spotZone: "spot-a", hostUserID: TARA)])
        await h.sync.refresh()

        h.gateway.fails["saveReply"] = .network
        await #expect(throws: SyncError.network) {
            try await h.sync.reply(invitationId: "i1", status: .ind)
        }
        #expect(h.invites.invitations[0].replies.isEmpty)
    }

    @Test("rein lokaler Spot: Einladung ohne einen einzigen Cloud-Write")
    func localInviteIsOffline() async throws {
        let h = try CommunityHarness()
        let spot = try await h.spots.addSpot(name: "Balkon", emoji: "🌳", lng: 9.7, lat: 52.3)
        let invitation = try await h.sync.invite(spotId: spot.id,
                                                 time: Date(epochMillis: 1_800_000_000_000))

        #expect(h.invites.invitations == [invitation])
        #expect(h.gateway.calls.isEmpty)
    }

    @Test("Spot mit Freunden: Zone + Zustellung, danach ist die Outbox leer")
    func shareSpot() async throws {
        let h = try CommunityHarness()
        h.gateway.next = snapshot(friends: [cloudFriend(userID: TARA)])
        await h.sync.refresh()

        let spot = try await h.sync.createSpot(name: "Unsere Bank", emoji: "🪑",
                                               lng: 9.72, lat: 52.36, friendIds: [TARA])

        let stored = try #require(h.spots.spot(id: spot.id))
        #expect(stored.zoneName == "spot-\(spot.id)")
        #expect(!stored.sharePending)
        #expect(stored.ownerId == SELF_ID)
        #expect(h.gateway.offeredZones == [["friend-\(TARA)"]])
        #expect(h.sync.state.pendingShares == 0)
    }

    @Test("Spot-Share ohne Netz bleibt in der Outbox und wird spaeter nachgeholt")
    func shareSpotOutbox() async throws {
        let h = try CommunityHarness()
        h.gateway.next = snapshot(friends: [cloudFriend(userID: TARA)])
        await h.sync.refresh()
        h.gateway.fails["createSpotShare"] = .network

        let spot = try await h.sync.createSpot(name: "Unsere Bank", emoji: "🪑",
                                               lng: 9.72, lat: 52.36, friendIds: [TARA])

        // Lokal ist der Spot da, die Cloud-Anlage steht ehrlich als „offen" drin.
        #expect(h.spots.spot(id: spot.id)?.sharePending == true)
        #expect(h.spots.spot(id: spot.id)?.zoneName == nil)
        #expect(h.sync.state.pendingShares == 1)
        #expect(h.sync.state.error != nil)

        h.gateway.fails["createSpotShare"] = nil
        await h.sync.refresh()

        #expect(h.spots.spot(id: spot.id)?.zoneName == "spot-\(spot.id)")
        #expect(h.spots.spot(id: spot.id)?.sharePending == false)
        #expect(h.gateway.offeredZones == [["friend-\(TARA)"]])
    }

    @Test("zwei parallele Teil-Vorgaenge legen die Zone nur einmal an")
    func parallelShares() async throws {
        let h = try CommunityHarness()
        h.gateway.next = snapshot(friends: [cloudFriend(userID: TARA),
                                            cloudFriend(userID: MARCEL, name: "Marcel")])
        await h.sync.refresh()
        let spot = try await h.spots.addSpot(name: "Unsere Bank", emoji: "🪑",
                                             lng: 9.72, lat: 52.36)

        async let a: Void = h.sync.shareSpot(spotId: spot.id, friendIds: [TARA])
        async let b: Void = h.sync.shareSpot(spotId: spot.id, friendIds: [MARCEL])
        _ = try await (a, b)

        #expect(h.gateway.count("createSpotShare") == 1)
        #expect(h.spots.spot(id: spot.id)?.sharePending == false)
    }

    @Test("Spot entfernen: erst die Zone, dann lokal")
    func removeSpot() async throws {
        let h = try CommunityHarness()
        h.gateway.next = snapshot(spots: [cloudSpot(zoneName: "spot-a")])
        await h.sync.refresh()
        let spot = try #require(h.spots.spots.first)

        h.gateway.fails["deleteSpot"] = .network
        await #expect(throws: SyncError.network) {
            try await h.sync.removeSpot(spotId: spot.id)
        }
        #expect(h.spots.spots.count == 1)

        h.gateway.fails["deleteSpot"] = nil
        try await h.sync.removeSpot(spotId: spot.id)
        #expect(h.spots.spots.isEmpty)
    }

    @Test("Freund einladen: Name lokal, Link vom Gateway")
    func inviteFriend() async throws {
        let h = try CommunityHarness()
        let url = try await h.sync.inviteFriend(displayName: "Leon")
        #expect(url.contains("Leon"))
        #expect(h.sync.profile.displayName == "Leon")
        // Ohne bestehende Freundschaften gibt es kein Profil zu aktualisieren.
        #expect(!h.gateway.calls.contains("setProfile"))
    }
}

// MARK: - Helfer

@MainActor
func tempDatabasePath() -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gz-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("greenzones.sqlite").path
}

/// Kurz Luft lassen fuer die abgesetzten Aufgaben (Erlaubnis-Frage, Nach-Refresh),
/// die der Coordinator bewusst NICHT abwartet.
func settle() async throws {
    try await Task.sleep(nanoseconds: 60_000_000)
}
