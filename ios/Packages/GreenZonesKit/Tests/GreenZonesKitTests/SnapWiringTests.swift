import CoreLocation
import Foundation
import Testing
@testable import GreenZonesKit

/// Welle 5, Teil 2: die Naehte zwischen Snaps und dem Rest.
///
/// Der `SyncCoordinator` kennt die Snaps nicht — er reicht den Snapshot durch.
/// Genau dieser Durchreichepunkt und die neue Spot-Teilnehmer-Pflege sind hier
/// der Prüfling; beides faellt sonst erst am Geraet auf.
@Suite("W5-Naehte — Snapshot-Hook, Spot-Teilnehmer, Zeitwort")
@MainActor
struct SnapWiringTests {

    // MARK: - Snapshot-Hook

    @Test("Der Hook laeuft NACH dem Merge und sieht den neuen Spot-Bestand")
    func hookRunsAfterMerge() async throws {
        let harness = try CommunityHarness()
        harness.gateway.next = snapshot(spots: [cloudSpot(zoneName: "spot-a", ownerUserID: ME)])

        // Die Zuordnung der Snaps laeuft ueber die Spot-Zonen. Liefe der Hook
        // vor `replaceAll`, saehe er den Bestand von vorhin — fremde Snaps
        // landeten dann in keinem Album.
        var spotsAtHookTime: [String] = []
        var deliveredSnaps: [String] = []
        harness.sync.onSnapshot = { snapshot in
            spotsAtHookTime = harness.spots.spots.compactMap(\.zoneName)
            deliveredSnaps = snapshot.snaps.map(\.id)
        }

        await harness.sync.refresh()

        #expect(spotsAtHookTime == ["spot-a"])
        #expect(deliveredSnaps.isEmpty)
    }

    @Test("Der Hook bekommt die Snaps des Snapshots")
    func hookCarriesSnaps() async throws {
        let harness = try CommunityHarness()
        harness.gateway.next = snapshot(
            spots: [cloudSpot(zoneName: "spot-a", ownerUserID: ME)],
            snaps: [CloudSnap(id: "snap-1", zoneName: "spot-a", authorUserID: TARA,
                              createdAt: Date(epochMillis: 1000), lat: 52.3, lng: 9.7,
                              inSpotZone: true)])

        var received: [String] = []
        harness.sync.onSnapshot = { received = $0.snaps.map(\.id) }
        await harness.sync.refresh()

        #expect(received == ["snap-1"])
    }

    @Test("Ohne Konto laeuft der Hook nicht — es gibt nichts zu uebernehmen")
    func noAccountSkipsHook() async throws {
        let harness = try CommunityHarness()
        harness.gateway.next = .empty(status: .noAccount)

        var calls = 0
        harness.sync.onSnapshot = { _ in calls += 1 }
        await harness.sync.refresh()

        #expect(calls == 0, "ein leerer Snapshot ohne Konto darf keinen Bestand anfassen")
    }

    // MARK: - Aus Spot entfernen (Mockup-Lock B)

    private func sharedSpot() -> Spot {
        Spot(id: "s1", name: "Unsere Bank", emoji: "🪑", lng: 9.72, lat: 52.36,
             createdAt: Date(epochMillis: 1000), zoneName: "spot-s1", ownerId: SELF_ID,
             participantIds: [TARA, MARCEL], shareURL: "https://www.icloud.com/share/s1")
    }

    @Test("Teilnehmer raus: erst die Zone, dann der lokale Bestand")
    func removeParticipantHitsCloudAndStore() async throws {
        let harness = try CommunityHarness()
        try await harness.spots.replaceAll([sharedSpot()])

        try await harness.sync.removeSpotParticipant(spotId: "s1", userId: TARA)

        #expect(harness.gateway.removedFromSpots.count == 1)
        #expect(harness.gateway.removedFromSpots.first?.zoneName == "spot-s1")
        #expect(harness.gateway.removedFromSpots.first?.userID == TARA)
        #expect(harness.spots.spot(id: "s1")?.participantIds == [MARCEL])
    }

    @Test("Scheitert die Cloud, bleibt die Person im Spot")
    func cloudFailureKeepsParticipant() async throws {
        let harness = try CommunityHarness()
        try await harness.spots.replaceAll([sharedSpot()])
        harness.gateway.fails["removeSpotParticipant"] = .network

        await #expect(throws: SyncError.network) {
            try await harness.sync.removeSpotParticipant(spotId: "s1", userId: TARA)
        }
        // Ehrlichkeitsregel: kein lokaler Zustand, der einen Vollzug behauptet.
        #expect(harness.spots.spot(id: "s1")?.participantIds == [MARCEL, TARA].sorted())
    }

    @Test("Im fremden Spot bin ich Gast — dort entfernt niemand")
    func guestCannotRemove() async throws {
        let harness = try CommunityHarness()
        var foreign = sharedSpot()
        foreign.ownerId = MARCEL
        try await harness.spots.replaceAll([foreign])

        try await harness.sync.removeSpotParticipant(spotId: "s1", userId: TARA)

        #expect(harness.gateway.count("removeSpotParticipant") == 0)
        #expect(harness.spots.spot(id: "s1")?.participantIds.contains(TARA) == true)
    }

    @Test("Wer gar nicht drin ist, loest keinen Netz-Aufruf aus")
    func unknownParticipantIsNoOp() async throws {
        let harness = try CommunityHarness()
        try await harness.spots.replaceAll([sharedSpot()])

        try await harness.sync.removeSpotParticipant(spotId: "s1", userId: "wer-auch-immer")

        #expect(harness.gateway.count("removeSpotParticipant") == 0)
    }

    // MARK: - Zeitwort der Kachel

    @Test("Kachel-Zeit: Uhrzeit heute, Wort gestern, Wochentag diese Woche, sonst Datum")
    func captionTimeShrinksWithAge() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // Mittwoch, 13.08.2025, 21:30 Ortszeit.
        let now = calendar.date(from: DateComponents(year: 2025, month: 8, day: 13,
                                                     hour: 21, minute: 30))!

        func when(_ minutesAgo: Int) -> String {
            snapWhen(now.addingTimeInterval(-Double(minutesAgo) * 60), now: now, calendar: calendar)
        }

        #expect(when(109) == "19:41", "heute: die Uhrzeit")
        #expect(when(24 * 60) == "gestern")
        // Vor vier Tagen war Samstag, der 9.8.
        #expect(when(4 * 24 * 60) == "Sa")
        // Vor acht Tagen faellt aus der Woche — dann das Datum.
        #expect(when(8 * 24 * 60) == "5.8.")
    }

    @Test("Eine Uhr, die vorgeht, macht aus dem Snap kein Datum in der Zukunft")
    func futureStampReadsAsNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ahead = now.addingTimeInterval(600)
        #expect(snapWhen(ahead, now: now) == Tape.fmtClock(ahead))
    }
}
