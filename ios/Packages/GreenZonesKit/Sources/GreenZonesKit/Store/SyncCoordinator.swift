import Foundation
import os

/// Sichtbarer Zustand des Sync. Port von `SyncState` aus `sync.ts`.
public struct SyncState: Equatable, Sendable {
    /// Kontostatus der letzten Pruefung; `nil` = noch nie gefragt („unknown").
    public var status: CKAccountStatus?
    /// true, sobald ein Snapshot verarbeitet wurde.
    public var loaded: Bool
    /// Es gibt Freunde, aber noch kein eigenes Profil, und der Nutzer wurde nach
    /// dem Beitritt noch nicht gefragt. Zustandsbasiert statt an das
    /// Accept-Ereignis gehaengt: nach einem Kaltstart ueber den Share-Link ist
    /// das Ereignis laengst verpufft, der Zustand aber noch da.
    public var profilePrompt: Bool
    /// Letzte Meldung an den Nutzer (blameless) oder `nil`.
    public var error: String?
    /// Spot-Shares, die noch in der Outbox liegen.
    public var pendingShares: Int

    public init(status: CKAccountStatus? = nil, loaded: Bool = false,
                profilePrompt: Bool = false, error: String? = nil, pendingShares: Int = 0) {
        self.status = status
        self.loaded = loaded
        self.profilePrompt = profilePrompt
        self.error = error
        self.pendingShares = pendingShares
    }

    public var available: Bool { status == .available }
}

/// Bindeglied zwischen Stores und Cloud (SPEC 3).
///
/// **Ehrlichkeitsregel (v1 bleibt):** Einladung, Antwort und Profil gehen ZUERST
/// in die Cloud und erst nach deren Bestaetigung in den lokalen Store. Ohne Netz
/// gibt es einen Abbruch mit Meldung — nie einen lokalen Zustand, der so tut, als
/// waere etwas gesendet. Einzige Ausnahme ist die Spot-Share-Anlage: sie ist laut
/// Konzept nachholbar und liegt als `sharePending` in der Outbox.
///
/// Das eigene Profil hat genau EINEN Speicher (`SettingsStore`); der Coordinator
/// spiegelt es nicht in seinen State, sondern reicht es durch — zwei Kopien
/// desselben Zustands waeren zwei Wahrheiten (Abweichung zu v1, wo `SyncState`
/// `displayName`/`emoji` mitfuehrt).
@MainActor
@Observable
public final class SyncCoordinator {
    public private(set) var state = SyncState()

    @ObservationIgnored public let gateway: any CloudGateway
    @ObservationIgnored private let spots: SpotStore
    @ObservationIgnored private let friends: FriendStore
    @ObservationIgnored private let invites: InviteStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let clock: GZClock
    @ObservationIgnored private let logger = Logger(subsystem: "de.leonvalentin.greenzones",
                                                    category: "cloud")

    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscribed = false
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var queued = false
    /// Schwanz der Outbox-Kette.
    @ObservationIgnored private var flushing: Task<Void, Never>?

    public init(gateway: any CloudGateway, spots: SpotStore, friends: FriendStore,
                invites: InviteStore, settings: SettingsStore, clock: GZClock = SystemClock()) {
        self.gateway = gateway
        self.spots = spots
        self.friends = friends
        self.invites = invites
        self.settings = settings
        self.clock = clock
    }

    /// Eigenes Profil — durchgereicht, nicht kopiert.
    public var profile: Profile { settings.profile }

    /// Meldung quittieren — sie ist ein Hinweis, kein Dauerzustand.
    public func clearError() { patch { $0.error = nil } }

    // MARK: - Lebenszyklus

    /// Start nach der lokalen Ladung: Kontostatus → erster Fetch.
    /// Mehrfachaufruf ist ein No-Op.
    public func start() async {
        guard !started else { return }
        started = true
        // Am lokalen Bestand bewerten, nicht erst nach einem gegluecken Fetch:
        // die Freunde von gestern liegen laengst auf dem Geraet, und ohne Netz
        // kaeme die Frage sonst gar nicht.
        evaluateProfilePrompt()
        maybeAskNotificationPermission()
        if let status = try? await gateway.accountStatus() {
            patch { $0.status = status }
        }
        await refresh()
    }

    /// Kompletten Zustand holen und mergen. Parallele Aufrufe laufen seriell.
    public func refresh() async {
        if let running {
            queued = true
            await running.value
            return
        }
        let task = Task { @MainActor in await self.fetchAndMerge() }
        running = task
        await task.value
        running = nil
        if queued {
            queued = false
            await refresh()
        }
    }

    private func fetchAndMerge() async {
        let snapshot: CloudSnapshot
        do {
            snapshot = try await gateway.fetchAll()
        } catch {
            patch { $0.error = cloudMessage(error) }
            return
        }
        patch {
            $0.status = snapshot.status
            $0.loaded = true
            $0.error = nil
        }
        // Kein Konto ist ein definierter Zustand: nichts mergen, nichts loeschen —
        // der lokale Bestand bleibt exakt, wie er ist.
        guard snapshot.status == .available else { return }

        let merged = mergeSnapshot(snapshot, current: LocalState(spots: spots.spots,
                                                                 friends: friends.friends,
                                                                 invitations: invites.invitations))
        do {
            try await friends.replaceAll(merged.friends)
            try await spots.replaceAll(merged.spots)
            try await invites.replaceAll(merged.invitations)
        } catch {
            logger.error("Merge nicht geschrieben: \(String(describing: error), privacy: .public)")
        }
        evaluateProfilePrompt()

        if !subscribed {
            do {
                try await gateway.registerSubscriptions()
                subscribed = true
            } catch {
                // Push ist Komfort, kein Datenpfad — der naechste Fetch versucht es erneut.
            }
        }
        maybeAskNotificationPermission()
        await flushShares()
    }

    /// Mitteilungs-Erlaubnis erst erfragen, wenn es etwas mitzuteilen gibt: mit
    /// dem ersten Freund. Bewertet am LOKALEN Bestand (wie der Profil-Prompt).
    private func maybeAskNotificationPermission() {
        guard !friends.friends.isEmpty else { return }
        Task { [gateway] in
            // Ohne Erlaubnis bleibt alles nutzbar — es gibt nur keine Banner.
            _ = try? await gateway.ensureNotificationPermission()
        }
    }

    private func evaluateProfilePrompt() {
        let hasFriends = !friends.friends.isEmpty
        let prompt = hasFriends && !settings.profile.isSet && !settings.profileAsked
        patch { $0.profilePrompt = prompt }
    }

    // MARK: - Spots teilen

    /// Spot anlegen. Ohne gewaehlte Freunde bleibt er rein lokal; mit Freunden
    /// geht er in die Outbox und wird sofort (und sonst beim naechsten Fetch)
    /// zugestellt.
    @discardableResult
    public func createSpot(name: String, emoji: String, lng: Double, lat: Double,
                           friendIds: [String] = []) async throws -> Spot {
        let spot = try await spots.addSpot(name: name, emoji: emoji, lng: lng, lat: lat)
        if !friendIds.isEmpty { try await shareSpot(spotId: spot.id, friendIds: friendIds) }
        return spot
    }

    /// Bestehenden eigenen Spot (weiteren) Freunden zustellen.
    public func shareSpot(spotId: String, friendIds: [String]) async throws {
        guard let spot = spots.spot(id: spotId), !friendIds.isEmpty else { return }
        let participants = Array(Set(spot.participantIds).union(friendIds)).sorted()
        try await spots.setCloudState(id: spotId,
                                      SpotCloudState(ownerId: SELF_ID,
                                                     participantIds: participants,
                                                     sharePending: true))
        await flushShares()
    }

    /// Outbox abarbeiten. Laeuft seriell hinter allen laufenden Fluessen — zwei
    /// parallele Laeufe wuerden denselben Spot beide als „ohne Zone" lesen und
    /// die Zone zweimal anlegen.
    private func flushShares() async {
        let previous = flushing
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.flushPending()
        }
        flushing = task
        await task.value
    }

    /// Zone + Share anlegen, danach den Freunden zustellen.
    private func flushPending() async {
        for spot in spots.spots where spot.sharePending {
            do {
                try await pushShare(spot)
            } catch {
                // Kein Netz/kein Konto: der Spot bleibt in der Outbox, lokal ist er laengst da.
                patch { $0.error = cloudMessage(error) }
                break
            }
        }
        let pending = spots.spots.filter(\.sharePending).count
        patch { $0.pendingShares = pending }
    }

    private func pushShare(_ spot: Spot) async throws {
        var zoneName = spot.zoneName
        var shareURL = spot.shareURL
        if zoneName == nil || shareURL == nil {
            let created = try await gateway.createSpotShare(spot)
            zoneName = created.zoneName
            shareURL = created.shareURL
            try await spots.setCloudState(id: spot.id,
                                          SpotCloudState(zoneName: created.zoneName,
                                                         ownerId: SELF_ID,
                                                         shareURL: created.shareURL))
        }
        guard let zoneName, let shareURL else { return }
        let zones = friendshipZones(of: spot.participantIds)
        if !zones.isEmpty {
            try await gateway.offerSpotToFriends(zoneName: zoneName, shareURL: shareURL,
                                                 spotName: spot.name, spotEmoji: spot.emoji,
                                                 friendshipZones: zones)
        }
        try await spots.setCloudState(id: spot.id, SpotCloudState(sharePending: false))
    }

    private func friendshipZones(of friendIds: [String]) -> [String] {
        friendIds.compactMap { friends.friend(id: $0)?.friendshipZone }
    }

    /// Owner loescht die Zone, Teilnehmer beendet die Teilnahme — beides erst in der Cloud.
    public func removeSpot(spotId: String) async throws {
        if let zone = spots.spot(id: spotId)?.zoneName {
            try await gateway.deleteSpot(zoneName: zone)
        }
        try await spots.removeSpot(id: spotId)
    }

    // MARK: - Einladungen

    /// Einladung anlegen — bei geteiltem Spot erst in der Cloud, dann lokal.
    @discardableResult
    public func invite(spotId: String, time: Date) async throws -> Invitation {
        let invitation = Invitation(id: UUID().uuidString, spotId: spotId, hostId: SELF_ID,
                                    time: time.millisecondPrecision,
                                    createdAt: clock.now.millisecondPrecision, cancelled: false)
        try await mirror(invitation)
        try await invites.add(invitation)
        return invitation
    }

    public func changeInvitationTime(invitationId: String, time: Date) async throws {
        guard var invitation = invites.invitation(id: invitationId) else {
            throw InviteStoreError.unknownInvitation(invitationId)
        }
        invitation.time = time
        try await mirror(invitation)
        try await invites.changeTime(id: invitationId, time: time)
    }

    public func cancelInvitation(invitationId: String) async throws {
        guard var invitation = invites.invitation(id: invitationId) else {
            throw InviteStoreError.unknownInvitation(invitationId)
        }
        invitation.cancelled = true
        try await mirror(invitation)
        try await invites.cancel(id: invitationId)
    }

    /// Eigene Antwort — „Ich komme um …" ist eine Zusage mit eigener Zeit.
    public func reply(invitationId: String, status: ReplyStatus,
                      arrivalTime: Date? = nil) async throws {
        guard let invitation = invites.invitation(id: invitationId) else {
            throw InviteStoreError.unknownInvitation(invitationId)
        }
        if let zone = spots.spot(id: invitation.spotId)?.zoneName {
            try await gateway.saveReply(spotZone: zone, invitationId: invitationId,
                                        status: status, arrivalTime: arrivalTime)
            Task { await self.refresh() }
        }
        try await invites.setReply(id: invitationId,
                                   Reply(participantId: SELF_ID, status: status,
                                         arrivalTime: arrivalTime))
    }

    private func mirror(_ invitation: Invitation) async throws {
        guard let zone = spots.spot(id: invitation.spotId)?.zoneName else { return }
        try await gateway.saveInvitation(spotZone: zone, id: invitation.id,
                                         time: invitation.time, createdAt: invitation.createdAt,
                                         cancelled: invitation.cancelled)
        Task { await self.refresh() }
    }

    // MARK: - Profil und Freunde

    /// Eigenes Profil festhalten und, sofern es schon Freundschaften gibt, deren
    /// Profile-Records nachziehen. Ein leeres Zeichen ist die Wahl „Ohne", kein
    /// Fehlwert: es wird geschrieben und loescht ein frueher gewaehltes.
    public func setProfile(name: String, emoji: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let unchanged = trimmed == settings.profile.displayName && emoji == settings.profile.emoji
        // Auch unveraendert muss die Frage als beantwortet gelten, sonst kommt sie wieder.
        try await markProfileAsked()
        guard !unchanged else { return }
        try await settings.setProfile(Profile(displayName: trimmed, emoji: emoji))
        if !friends.friends.isEmpty {
            try await gateway.setProfile(name: trimmed, emoji: emoji)
        }
    }

    /// „Später"/„Überspringen": die Frage ruht, das Profil bleibt ueber die
    /// Freundesliste erreichbar.
    public func skipProfilePrompt() async throws {
        try await markProfileAsked()
    }

    private func markProfileAsked() async throws {
        try await settings.setProfileAsked(true)
        patch { $0.profilePrompt = false }
    }

    /// Einladungs-Link fuer einen neuen Freund; der Aufrufer schickt ihn uebers Share-Sheet.
    public func inviteFriend(displayName: String, emoji: String? = nil) async throws -> String {
        let sign = emoji ?? settings.profile.emoji
        try await setProfile(name: displayName, emoji: sign)
        let url = try await gateway.createFriendInvite(displayName: settings.profile.displayName,
                                                       emoji: settings.profile.emoji)
        Task { await self.refresh() }
        return url
    }

    // MARK: - State

    private func patch(_ change: (inout SyncState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
    }
}
