import Foundation
import Testing
@testable import GreenZonesKit

/// Die abgeleiteten Record- und Zonen-Namen sind ein Vertrag mit bereits
/// ausgelieferten v1-Geraeten: Schreiber und Leser eines Namens duerfen nie zwei
/// Meinungen ueber seine Form haben. Diese Suite pinnt die Form — eine
/// Umbenennung schneidet Bestandsfreundschaften ab und muss auffallen.
@Suite("CloudKit — abgeleitete Namen")
struct CKSchemaTests {
    @Test("Profil, Angebot und Antwort tragen ihren Schreiber bzw. ihr Ziel")
    func namesCarryTheirSubject() {
        #expect(CKSchema.profileRecordName(userID: "_abc") == "profile-_abc")
        #expect(CKSchema.offerRecordName(spotZone: "spot-42") == "offer-spot-42")
        #expect(CKSchema.feedOfferRecordName(userID: "_abc") == "feedoffer-_abc")
        #expect(CKSchema.replyRecordName(invitationId: "inv1", userID: "_abc") == "reply-inv1-_abc")
        #expect(CKSchema.reportRecordName(snapId: "s1", userID: "_abc") == "report-s1-_abc")
    }

    @Test("Zonen-Namen und ihre Umkehrung passen zusammen")
    func zoneNamesRoundTrip() {
        let zone = CKSchema.spotZoneName(spotId: "abc-123")
        #expect(zone == "spot-abc-123")
        #expect(CKSchema.spotId(zoneName: zone) == "abc-123")
        #expect(CKSchema.feedZoneName("AB-CD").hasPrefix("feed-"))
        // Zonen-UUIDs sind klein geschrieben — v1 legt sie so an.
        #expect(CKSchema.feedZoneName("AB-CD") == "feed-ab-cd")
        #expect(CKSchema.friendZoneName("AB-CD") == "friend-ab-cd")
    }

    @Test("Aus dem Angebots-Namen faellt die Ziel-Zone")
    func offeredZoneIsReadableFromTheName() {
        #expect(CKSchema.offeredZone(recordName: "offer-spot-42") == "spot-42")
        // Ein Name ohne das Praefix ist kein Angebot — kein Rateversuch.
        #expect(CKSchema.offeredZone(recordName: "spot-42") == nil)
    }

    @Test("Die v1-Subscription-IDs bleiben als Altlast bekannt")
    func legacySubscriptionsStayKnown() {
        // Sie werden beim Registrieren geloescht; faellt die Liste weg, bekommen
        // v1-Geraete fuer immer einen zweiten, bannerlosen Push.
        #expect(CKSchema.legacySubscriptionIDs == ["gz-private-db", "gz-shared-db"])
        #expect(!CKSchema.legacySubscriptionIDs.contains(CKSchema.privateSubscriptionID))
        #expect(!CKSchema.legacySubscriptionIDs.contains(CKSchema.sharedSubscriptionID))
    }
}

/// Der Merge nimmt die Cloud als Wahrheit — mit Ausnahmen. `blocked` ist eine
/// rein lokale Entscheidung: die Cloud kennt sie nicht und wuerde sie bei jedem
/// Fetch zuruecksetzen.
@Suite("Merge — Feed-Zone und Blockieren")
struct MergeFeedAndBlockTests {
    private func snapshotFriend(feedZone: String = "") -> CloudSnapshot {
        CloudSnapshot(status: .available, userID: "me",
                      friends: [CloudFriend(userID: "u1", name: "Tara", emoji: "🌿",
                                            friendshipZone: "friend-1", isOwner: true,
                                            feedZone: feedZone)],
                      spots: [], invitations: [])
    }

    @Test("Feed-Zone aus dem Snapshot landet am Freund")
    func feedZoneArrives() {
        let merged = mergeSnapshot(snapshotFriend(feedZone: "feed-9"), current: LocalState())
        #expect(merged.friends.first?.feedZone == "feed-9")
    }

    @Test("Ohne Feed-Zone bleibt das Feld leer statt \"\"")
    func missingFeedZoneIsNil() {
        // Leerer String und „keine Zone" sind derselbe Zustand — in der DB steht
        // dafuer NULL, sonst braeuchte jeder Leser eine Sonderregel.
        let merged = mergeSnapshot(snapshotFriend(), current: LocalState())
        #expect(merged.friends.first?.feedZone == nil)
    }

    @Test("Blockiert ueberlebt den Fetch")
    func blockedSurvivesTheMerge() {
        let blocked = Friend(id: "u1", name: "Tara", color: "#111",
                             friendshipZone: "friend-1", blocked: true)
        let merged = mergeSnapshot(snapshotFriend(), current: LocalState(friends: [blocked]))
        #expect(merged.friends.first?.blocked == true)
    }

    @Test("Wer nie blockiert war, bleibt es auch nach dem Merge nicht")
    func unblockedStaysUnblocked() {
        let merged = mergeSnapshot(snapshotFriend(), current: LocalState())
        #expect(merged.friends.first?.blocked == false)
    }

    @Test("Zweimal derselbe Snapshot ergibt denselben Bestand")
    func mergeStaysIdempotent() {
        let blocked = Friend(id: "u1", name: "Tara", color: "#111",
                             friendshipZone: "friend-1", blocked: true)
        let once = mergeSnapshot(snapshotFriend(feedZone: "feed-9"),
                                 current: LocalState(friends: [blocked]))
        let twice = mergeSnapshot(snapshotFriend(feedZone: "feed-9"), current: once)
        #expect(once == twice)
    }
}

/// Freundschaft beenden ist ein Zwei-Phasen-Vorgang im Netz. Der lokale Block
/// muss auch dann stehen, wenn die Cloud nur teilweise durchkommt — sonst steht
/// jemand weiter in der Liste, den man gerade entfernt hat.
@Suite("SyncCoordinator — Freundschaft beenden")
@MainActor
struct RemoveFriendTests {
    private func makeCoordinator(gateway: FakeGateway) async throws -> (SyncCoordinator, FriendStore) {
        let database = try AppDatabase.inMemory(migrations: CommunityMigrations.all)
        let friends = FriendStore(database)
        try await friends.replaceAll([Friend(id: "u1", name: "Tara", color: "#111",
                                             friendshipZone: "friend-1")])
        let coordinator = SyncCoordinator(gateway: gateway,
                                          spots: SpotStore(database),
                                          friends: friends,
                                          invites: InviteStore(database),
                                          settings: SettingsStore(database))
        return (coordinator, friends)
    }

    @Test("Erst die Cloud, dann der lokale Block")
    func removesInCloudAndBlocksLocally() async throws {
        let gateway = FakeGateway()
        let (coordinator, friends) = try await makeCoordinator(gateway: gateway)

        try await coordinator.removeFriend(id: "u1")

        #expect(gateway.removedFriends == ["u1"])
        #expect(friends.friend(id: "u1")?.blocked == true)
    }

    @Test("Scheitert die Cloud, steht der Block trotzdem — und der Fehler kommt an")
    func blocksLocallyEvenWhenTheCloudFails() async throws {
        let gateway = FakeGateway()
        gateway.fails["removeFriend"] = .network
        let (coordinator, friends) = try await makeCoordinator(gateway: gateway)

        await #expect(throws: SyncError.network) {
            try await coordinator.removeFriend(id: "u1")
        }
        #expect(friends.friend(id: "u1")?.blocked == true)
    }

    @Test("Unbekannte Person: kein Netz-Aufruf")
    func unknownFriendIsNoOp() async throws {
        let gateway = FakeGateway()
        let (coordinator, _) = try await makeCoordinator(gateway: gateway)

        try await coordinator.removeFriend(id: "niemand")

        #expect(gateway.count("removeFriend") == 0)
    }
}
