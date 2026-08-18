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

    enum Mode { case view, hostTime, myTime, share, access, manage }

    @State private var mode: Mode = .view
    @State private var draft = Date()
    @State private var addTo: Set<String> = []
    /// Auswahl im Zugangs-Blatt — Startwert sind die heutigen
    /// Teilnehmer, damit Abwaehlen ueberhaupt moeglich ist.
    @State private var access: Set<String> = []
    /// Bandanfang einmal einfrieren — sonst wandert „Jetzt" unter dem Finger.
    @State private var now: Date?
    /// W5: Person, deren Entfernen gerade nachgefragt wird — aus dem Spot bzw.
    /// aus der Freundesliste. Zwei Zustaende, weil beide verschiedene Folgen
    /// haben und der Text sie benennen muss.
    @State private var removingFromSpot: Friend?
    @State private var removingFriend: Friend?

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
            case .access: accessSheet
            case .manage: manageSheet
            case .hostTime: hostTimeSheet
            case .myTime: myTimeSheet
            case .view: detailSheet
            }
        }
        .task { if now == nil { now = model.now } }
        // Shot-Schalter wie `GZ_ROUTE`: `GZ_SHARE_OPEN=1` faehrt das
        // Zugangs-Blatt direkt an, damit es fotografierbar ist — ohne ihn gaebe
        // es von diesem Blatt nur eine Behauptung.
        .task {
            guard spot.isMine,
                  let want = ProcessInfo.processInfo.environment["GZ_SHARE_OPEN"] else { return }
            switch want {
            case "1", "access":
                access = Set(spot.participantIds)
                mode = .access
            case "manage":
                mode = .manage
            default:
                break
            }
        }
        .task(id: spot.id) { await model.loadStatus(at: spot.coordinate) }
        // `.alert` statt `.confirmationDialog`: der schluckt unter iOS 26 den
        // Abbrechen-Knopf, wenn er aus einem Blatt heraus kommt.
        .alert("Aus Spot entfernen?", isPresented: Binding(get: { removingFromSpot != nil },
                                                          set: { if !$0 { removingFromSpot = nil } }),
               presenting: removingFromSpot) { friend in
            Button("Entfernen", role: .destructive) {
                removingFromSpot = nil
                let spotId = spot.id
                model.run { try await model.sync.removeSpotParticipant(spotId: spotId,
                                                                        userId: friend.id) }
            }
            Button("Abbrechen", role: .cancel) { removingFromSpot = nil }
        } message: { friend in
            Text("\(friendLabel(friend)) sieht „\(spot.name)“ dann nicht mehr — auch die Shots hier nicht. Ihr bleibt befreundet.")
        }
        .alert("Freund entfernen?", isPresented: Binding(get: { removingFriend != nil },
                                                        set: { if !$0 { removingFriend = nil } }),
               presenting: removingFriend) { friend in
            Button("Entfernen", role: .destructive) {
                removingFriend = nil
                model.run { try await model.sync.removeFriend(id: friend.id) }
            }
            Button("Abbrechen", role: .cancel) { removingFriend = nil }
        } message: { friend in
            Text("\(friendLabel(friend)) sieht eure gemeinsamen Spots dann nicht mehr, und du seine nicht. Zurück geht es nur über einen neuen Einladungs-Link.")
        }
    }

    // MARK: - Ansicht

    private var detailSheet: some View {
        CommunitySheet(estimate: 520) {
            // Der Name stand hier zweimal — als Titel UND in der Karte
            // darunter. Die Karte traegt ihn samt Status und Entfernung, also
            // ist sie die Ueberschrift.
            SPSpotCard(spot: spot, status: status, hour: hour, userCoordinate: userCoordinate)

            // Legal-Zeile zur Anker-Zeit: „Am Spot um 20:00 erlaubt". Der Bezug
            // ist JETZT, nicht die Anker-Zeit selbst — sonst stuende dort immer
            // „jetzt" (die Rastzone misst gegen den Bandanfang).
            if let invitation, let status,
               let line = spotLegalLine(status, at: invitation.time, base: frozenNow) {
                legalLine(line, warns: !spotAllowedAt(status, at: invitation.time))
            }

            // W5, Lock A: das Album steht ueber der Einladung — beim Oeffnen
            // gewinnt, was am Spot passiert ist, nicht der Verwaltungsteil.
            SnapAlbumSection(model: model, spot: spot)


            if spot.sharePending {
                SPNote(text: "Teilen wird nachgeholt, sobald du wieder Netz hast — lokal ist der Spot längst da.")
            }

            // Der Termin als EIN Block: Zeit, wer kommt, und der Weg ihn
            // abzusagen. Vorher lagen „Deine Zeit", „Wer kommt" und „Einladung
            // absagen" an drei Stellen, mit „Geteilt mit" dazwischen — man
            // musste den Termin aus dem Blatt zusammensuchen.
            if let invitation {
                SPSection(text: isHost ? "Dein Termin" : "\(hostName) lädt dich ein")
                SPTimeRow(text: "\(Tape.dayWord(invitation.time, now: frozenNow)) · \(Tape.fmtClock(invitation.time))",
                          action: isHost ? {
                              draft = invitation.time
                              mode = .hostTime
                          } : nil)

                let rows = rsvpEntries(invitation, friends: friends,
                                       participantIds: invitation.invitees(
                                           spotParticipants: spot.participantIds))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                    // Das Menue haengt an der Person, nicht an der Zeile:
                    // ohne bekannten Freund dahinter gaebe es nichts zu tun.
                    let friend = entry.friendId.flatMap { model.friends.friend(id: $0) }
                    SPRsvpRow(entry: entry, showDivider: index > 0,
                              onRemoveFromSpot: removeFromSpotAction(friend),
                              onRemoveFriend: removeFriendAction(friend))
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

            // W5 (Mockup, Zustand 4): Ein ungeteilter Spot ist eine Schublade
            // fuer mich allein — und seine Snaps verlassen das Geraet nicht.
            // Der Satz steht VOR den Aktionen, damit der Weg heraus (teilen
            // bzw. Freund einladen) direkt darunter liegt.
            if spot.isLocalOnly, spot.isMine {
                SPNote(text: "Nur für dich — dieser Spot ist mit niemandem geteilt. Deine Shots hier bleiben auf dem Gerät, bis du ihn teilst.")
            }

            actions

            // Sackgassen-Regel: ohne Freunde ist der Weg heraus der Link, und
            // ohne iCloud sagt der Hinweis, warum es gerade keinen gibt.
            if spot.isLocalOnly, friends.isEmpty {
                SPCloudHint(status: model.sync.state.status)
            }

            VStack(spacing: 0) {
                if let invitation, isHost {
                    SPGhost(title: "Einladung absagen", danger: true) {
                        model.run { try await model.sync.cancelInvitation(invitationId: invitation.id) }
                    }
                }
                // Alles Dauerhafte liegt hinter EINER benannten Zeile — nicht
                // hinter einem Zeichen, das man kennen muesste. „Wer sieht den
                // Spot" und „Spot entfernen" gehoeren nicht in den Blick, wenn
                // man nur nachsehen will, was hier los ist.
                SPGhost(title: "Spot verwalten") { mode = .manage }
                SPGhost(title: "Schließen") { model.closeSheet() }
            }
            .padding(.top, 14)
        }
    }

    /// „Aus Spot entfernen" gibt es nur fuer den Gastgeber und nur fuer
    /// Teilnehmer DIESES Spots — bei einem fremden Spot bin ich selbst Gast.
    private func removeFromSpotAction(_ friend: Friend?) -> (() -> Void)? {
        guard let friend, spot.isMine, spot.participantIds.contains(friend.id) else { return nil }
        return { removingFromSpot = friend }
    }

    /// Das Personen-Menue gehoert dem Gastgeber (Mockup, Zustand 2): in einem
    /// fremden Spot bin ich Gast und verwalte dort niemanden. „Freund entfernen"
    /// bleibt ueber die Freundesliste erreichbar — es gehoert nicht dem Spot.
    private func removeFriendAction(_ friend: Friend?) -> (() -> Void)? {
        guard let friend, spot.isMine else { return nil }
        return { removingFriend = friend }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 0) {
            if invitation == nil, spot.zoneName != nil {
                SPCTA(title: "Einladen", style: .blue) {
                    model.sheet = .invite(spotId: spot.id)
                }
            }
            // Der frueher hier stehende CTA („Mit Freunden teilen" /
            // „Weiteren Freunden geben") ist in die Sektion „Geteilt mit"
            // gewandert: er konnte nur hinzufuegen und trug bei einem noch
            // ungeteilten Spot ein anderes Wort als bei einem geteilten —
            // wer „einladen" suchte, fand ihn nicht. Ohne Freunde bleibt der
            // Weg unten (Link) der einzige, und der steht schon da.
            if spot.isMine, friends.isEmpty, !spot.isLocalOnly {
                SPCTA(title: "Freund einladen", style: .outline) {
                    model.sheet = .friends(intent: .invite)
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

    // MARK: - MOCKUP: „Wer sieht diesen Spot" (Variante A vs. B)

    /// Alles, was den Spot als Sache betrifft: wer ihn sieht, und ihn loswerden.
    ///
    /// Eigenes Blatt seit dem 18.08. (Leon: „Die Spot-Übersicht finde ich
    /// ziemlich überladen"). Im vollen Zustand standen elf Bloecke im
    /// Detail-Blatt, es lief in den Deckel und scrollte. Der Schnitt laeuft
    /// zwischen ANSEHEN (Ort, Bilder, Termin) und VERWALTEN — Verwaltung ist
    /// selten und gehoert nicht in den Weg dessen, der nur nachsehen will.
    private var manageSheet: some View {
        CommunitySheet(estimate: 420) {
            SPTitle(text: "Spot verwalten")
            SPSubtitle(text: spot.name)

            if spot.isMine, !friends.isEmpty {
                SPSection(text: "Geteilt mit")
                sharedWithSection
            } else if !spot.participantIds.isEmpty {
                // Fremder Spot: nur Anzeige, verwaltet wird er vom Gastgeber.
                SPSection(text: "Geteilt mit")
                participantChips(spot.participantIds)
            }

            if spot.isLocalOnly, spot.isMine {
                SPNote(text: "Nur für dich — dieser Spot ist mit niemandem geteilt. Deine Shots hier bleiben auf dem Gerät, bis du ihn teilst.")
            }
            if spot.isLocalOnly, friends.isEmpty {
                SPCloudHint(status: model.sync.state.status)
            }

            VStack(spacing: 0) {
                SPGhost(title: spot.isMine ? "Spot entfernen" : "Spot verlassen", danger: true) {
                    let id = spot.id
                    model.run { try await model.sync.removeSpot(spotId: id) }
                    model.closeSheet()
                }
                SPGhost(title: "Zurück") { mode = .view }
            }
            .padding(.top, 14)
        }
    }

    /// Die Runde des Spots — und der Weg, sie zu aendern.
    @ViewBuilder
    private var sharedWithSection: some View {
        if spot.participantIds.isEmpty {
            SPNote(text: "Noch mit niemandem geteilt.")
        } else {
            participantChips(spot.participantIds)
        }
        SPCTA(title: "Wer sieht diesen Spot", style: .outline) {
            access = Set(spot.participantIds)
            mode = .access
        }
    }

    /// Das Zugangs-Blatt: angehakt heisst „sieht den Spot". Abwaehlen ist hier
    /// eine Vormerkung; scharf wird sie erst mit „Übernehmen", und wer
    /// wegfaellt, wird vorher benannt.
    private var accessSheet: some View {
        let removed = spot.participantIds.filter { !access.contains($0) }
        let added = access.subtracting(spot.participantIds)
        return CommunitySheet(estimate: 460) {
            SPTitle(text: "Wer sieht „\(spot.name)“?")
            SPSubtitle(text: "Angehakte sehen den Spot dauerhaft auf ihrer Karte — mit allen Shots, die hier liegen.")
            SPChipRow(items: friends) { friend in
                SPChip(name: friendLabel(friend), emoji: friend.emoji,
                       color: SP.color(friend.color),
                       selected: access.contains(friend.id)) {
                    if access.remove(friend.id) == nil { access.insert(friend.id) }
                }
            }
            if removed.isEmpty {
                SPNote(text: "Der Spot liegt in eurem gemeinsamen iCloud-Bereich — nicht bei uns.")
            } else {
                SPNote(text: removalWarning(removed), tone: .no)
            }
            SPCTA(title: "Übernehmen", style: .blue,
                  enabled: !removed.isEmpty || !added.isEmpty) {
                applyAccess(added: Array(added), removed: removed)
            }
            SPGhost(title: "Zurück") { mode = .view }
        }
    }

    private func removalWarning(_ removed: [String]) -> String {
        let names = removed.map { id in
            friends.first { $0.id == id }.map(friendLabel) ?? "Freund"
        }
        let list = names.count == 1
            ? names[0]
            : names.dropLast().joined(separator: ", ") + " und " + (names.last ?? "")
        return "\(list) \(names.count == 1 ? "verliert" : "verlieren") den Zugang — auch zu den Shots hier. Ihr bleibt befreundet."
    }

    private func applyAccess(added: [String], removed: [String]) {
        let spotId = spot.id
        if !added.isEmpty {
            model.run { try await model.sync.shareSpot(spotId: spotId, friendIds: added) }
        }
        // Entfernen geht bewusst ZUERST in die Cloud (`removeSpotParticipant`):
        // lokal jemanden auszutragen, waehrend er weiter Zugriff hat, waere eine
        // Anzeige, die luegt. Anders als beim Loeschen eines eigenen Bildes ist
        // das hier keine Entscheidung ueber das eigene Geraet.
        for id in removed {
            model.run { try await model.sync.removeSpotParticipant(spotId: spotId, userId: id) }
        }
        mode = .view
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
