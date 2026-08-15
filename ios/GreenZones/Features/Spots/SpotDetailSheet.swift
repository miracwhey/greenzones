import CoreLocation
import GreenZonesKit
import SwiftUI

/// Spot-Detail — Port von `SpotDetailSheet` aus `client/src/components/SpotSheets.tsx`.
///
/// Konzept v2.2: die Host-Zeit ist ein ANKER, jede Antwort traegt ihren eigenen
/// Zustand. Es gibt keinen Verhandlungs- oder Entscheidungs-Flow — niemandes
/// Zeit stellt sich durch die Antwort eines anderen um.
///
/// Sackgassen-Regel: ohne Freunde fuehrt das Sheet in den Freund-einladen-Flow,
/// nie in einen Bildschirm ohne Ausgang.
struct SpotDetailSheet: View {
    let model: CommunityModel
    let spot: Spot
    let userCoordinate: CLLocationCoordinate2D?
    let hour: Int

    enum Mode { case view, hostTime, myTime, share }

    @State private var mode: Mode = .view
    @State private var draft = Date()
    @State private var addTo: Set<String> = []
    /// Bandanfang einmal einfrieren — sonst wandert „Jetzt" unter dem Finger.
    @State private var now: Date?

    private var invitation: Invitation? { model.activeInvitation(spotId: spot.id) }
    private var status: ZoneStatus? { model.status(at: spot.coordinate) }
    private var friends: [Friend] { model.friends.friends }
    private var isHost: Bool { invitation?.hostId == SELF_ID }
    private var own: Reply? { invitation?.reply(of: SELF_ID) }
    private var shareable: [Friend] { model.shareable(spot) }
    private var frozenNow: Date { now ?? model.now }

    private var hostName: String {
        guard let invitation, !isHost else { return "" }
        return friends.first { $0.id == invitation.hostId }.map(friendLabel) ?? "Gastgeber"
    }

    /// Liegt der Anker schon in der Vergangenheit (Einladung laeuft aus), muss das
    /// Band bis zu ihm zurueckreichen — sonst waere die eigene Zeit nicht darstellbar.
    private var tapeBase: Date {
        guard let invitation else { return frozenNow }
        return min(invitation.time, frozenNow)
    }

    var body: some View {
        Group {
            switch mode {
            case .share: shareSheet
            case .hostTime: hostTimeSheet
            case .myTime: myTimeSheet
            case .view: detailSheet
            }
        }
        .task { if now == nil { now = model.now } }
        .task(id: spot.id) { await model.loadStatus(at: spot.coordinate) }
    }

    // MARK: - Ansicht

    private var detailSheet: some View {
        CommunitySheet(estimate: 420) {
            SPTitle(text: spot.name)
            if let invitation {
                SPSubtitle(text: isHost
                    ? "Deine Einladung — \(Tape.dayWord(invitation.time, now: frozenNow).lowercased()) \(Tape.fmtClock(invitation.time))."
                    : "\(hostName) lädt dich ein — \(Tape.dayWord(invitation.time, now: frozenNow).lowercased()) \(Tape.fmtClock(invitation.time)).")
            }
            SPSpotCard(spot: spot, status: status, hour: hour, userCoordinate: userCoordinate)

            // Legal-Zeile zur Anker-Zeit: „Am Spot um 20:00 erlaubt". Der Bezug
            // ist JETZT, nicht die Anker-Zeit selbst — sonst stuende dort immer
            // „jetzt" (die Rastzone misst gegen den Bandanfang).
            if let invitation, let status,
               let line = spotLegalLine(status, at: invitation.time, base: frozenNow) {
                legalLine(line, warns: !spotAllowedAt(status, at: invitation.time))
            }

            if let invitation, isHost {
                SPSection(text: "Deine Zeit")
                SPTimeRow(text: "\(Tape.dayWord(invitation.time, now: frozenNow)) · \(Tape.fmtClock(invitation.time))") {
                    draft = invitation.time
                    mode = .hostTime
                }
            }

            if invitation == nil, !spot.participantIds.isEmpty {
                SPSection(text: "Geteilt mit")
                participantChips(spot.participantIds)
            }

            if spot.sharePending {
                SPNote(text: "Teilen wird nachgeholt, sobald du wieder Netz hast — lokal ist der Spot längst da.")
            }

            if let invitation {
                let rows = rsvpEntries(invitation, friends: friends,
                                       participantIds: spot.participantIds)
                if !rows.isEmpty {
                    SPSection(text: "Wer kommt")
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        SPRsvpRow(entry: entry, showDivider: index > 0)
                    }
                }
            }

            if let invitation, !isHost, own == nil {
                VStack(spacing: 0) {
                    SPCTA(title: "Bin dabei", style: .green) {
                        model.run { try await model.sync.reply(invitationId: invitation.id, status: .ind) }
                    }
                    SPCTA(title: "Ich komme um …", style: .outline) {
                        draft = invitation.time
                        mode = .myTime
                    }
                    SPGhost(title: "Kann nicht") {
                        model.run { try await model.sync.reply(invitationId: invitation.id, status: .out) }
                    }
                }
                .padding(.top, 14)
            }

            actions

            if spot.isLocalOnly, friends.isEmpty {
                SPNote(text: "Noch keine Freunde — teile einen Link, dann könnt ihr Spots teilen und euch einladen.")
                SPCloudHint(status: model.sync.state.status)
            }

            VStack(spacing: 0) {
                if let invitation, isHost {
                    SPGhost(title: "Einladung absagen", danger: true) {
                        model.run { try await model.sync.cancelInvitation(invitationId: invitation.id) }
                    }
                }
                SPGhost(title: spot.isMine ? "Spot entfernen" : "Spot verlassen", danger: true) {
                    let id = spot.id
                    model.run { try await model.sync.removeSpot(spotId: id) }
                    model.closeSheet()
                }
                SPGhost(title: "Schließen") { model.closeSheet() }
            }
            .padding(.top, 14)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 0) {
            if invitation == nil, spot.zoneName != nil {
                SPCTA(title: "Einladen", style: .blue) {
                    model.sheet = .invite(spotId: spot.id)
                }
            }
            if spot.isMine, !shareable.isEmpty {
                SPCTA(title: spot.zoneName != nil ? "Weiteren Freunden geben" : "Mit Freunden teilen",
                      style: spot.zoneName != nil ? .outline : .blue) {
                    addTo = Set(shareable.map(\.id))
                    mode = .share
                }
            }
            // Sackgassen-Regel: ohne Freunde fuehrt der Spot in den Einladen-Flow.
            if spot.isMine, spot.isLocalOnly, friends.isEmpty {
                SPCTA(title: "Freund einladen", style: .blue) {
                    model.sheet = .friends(intent: .invite)
                }
            }
        }
        .padding(.top, 14)
    }

    private func participantChips(_ ids: [String]) -> some View {
        // Anzeige statt Auswahl: die Einladung haengt am Spot, alle seine
        // Teilnehmer sehen sie. Eine Auswahl haette im Record kein Gegenstueck.
        SPChipRow(items: ids.map { IdentifiedString(id: $0) }) { item in
            let friend = friends.first { $0.id == item.id }
            SPChip(name: friend.map(friendLabel) ?? "Freund",
                   emoji: friend?.emoji,
                   color: SP.color(friend?.color),
                   selected: true,
                   onToggle: nil)
        }
    }

    private func legalLine(_ text: String, warns: Bool) -> some View {
        HStack(spacing: 7) {
            SPIcon(kind: .check).stroked(warns ? GZ.time : GZ.ok, size: 14, width: 2.6)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(warns ? GZ.time : GZ.ok)
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
    }

    // MARK: - Spot teilen

    private var shareSheet: some View {
        CommunitySheet(estimate: 380) {
            SPTitle(text: "Spot teilen")
            SPSubtitle(text: "Gewählte Freunde bekommen den Spot dauerhaft auf ihre Karte.")
            SPChipRow(items: shareable) { friend in
                SPChip(name: friendLabel(friend), emoji: friend.emoji,
                       color: SP.color(friend.color),
                       selected: addTo.contains(friend.id)) {
                    if addTo.remove(friend.id) == nil { addTo.insert(friend.id) }
                }
            }
            SPNote(text: "Der Spot liegt dann in eurem gemeinsamen iCloud-Bereich — nicht bei uns.")
            SPCTA(title: "Spot teilen", style: .blue, enabled: !addTo.isEmpty) {
                let ids = Array(addTo)
                let spotId = spot.id
                model.run { try await model.sync.shareSpot(spotId: spotId, friendIds: ids) }
                addTo = []
                mode = .view
            }
            SPGhost(title: "Zurück") { mode = .view }
        }
    }

    // MARK: - Zeiten

    private var hostTimeSheet: some View {
        CommunitySheet(estimate: 460) {
            if let invitation {
                SPTitle(text: "Zeit ändern")
                SPSubtitle(text: "Alle Eingeladenen sehen die neue Zeit.")
                tape(reference: invitation.time, label: "bisher")
                SPNote(text: "Zusagen bleiben bestehen — wer nicht mehr kann, meldet sich neu.")
                SPCTA(title: draft == invitation.time
                      ? "Neue Zeit senden"
                      : "Neue Zeit senden — \(Tape.fmtClock(draft))",
                      style: .blue) {
                    let time = draft
                    model.run {
                        try await model.sync.changeInvitationTime(invitationId: invitation.id,
                                                                  time: time)
                    }
                    mode = .view
                }
                SPGhost(title: "Zurück") { mode = .view }
            }
        }
    }

    private var myTimeSheet: some View {
        CommunitySheet(estimate: 480) {
            if let invitation {
                SPTitle(text: "Wann bist du da?")
                SPSubtitle(text: "\(hostName) ist ab \(Tape.fmtClock(invitation.time)) da — sag der Runde einfach deine Zeit.")
                tape(reference: invitation.time, label: "\(hostName) ab")
                SPNote(text: "Gilt als Zusage — für niemanden sonst ändert sich etwas.", tone: .ok)
                SPCTA(title: "Komme um \(Tape.fmtClock(draft))", style: .blue) {
                    let time = draft
                    model.run {
                        try await model.sync.reply(invitationId: invitation.id, status: .ind,
                                                   arrivalTime: time)
                    }
                    mode = .view
                }
                SPGhost(title: "Zurück") { mode = .view }
            }
        }
    }

    private func tape(reference: Date, label: String) -> some View {
        TimeTapeView(value: $draft,
                     base: tapeBase,
                     referenceTime: reference,
                     referenceLabel: label,
                     legalLine: { spotLegalLine(status, at: $0, base: tapeBase) },
                     legalWarns: { time in
                         guard let status else { return false }
                         return !spotAllowedAt(status, at: time)
                     })
    }
}

/// `ForEach` braucht Identitaet; nackte Strings haben keine.
struct IdentifiedString: Identifiable {
    let id: String
}
