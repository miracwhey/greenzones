import CoreLocation
import GreenZonesKit
import SwiftUI

/// „Einladen" — Port von `InviteSheet` aus `client/src/components/SpotSheets.tsx`,
/// Look aus `mockup/invite.html` und `client/sp_shots/sp_invite.png`.
///
/// Die Einladung geht erst raus, dann in den lokalen Bestand. Scheitert der
/// Cloud-Write, bleibt das Sheet offen und es gibt KEINE lokale Einladung — ein
/// fluechtiger Termin wird ehrlich abgebrochen, nie nachgeliefert.
struct InviteSheet: View {
    let model: CommunityModel
    let spot: Spot
    let userCoordinate: CLLocationCoordinate2D?
    let hour: Int

    /// Bandanfang einmal einfrieren — sonst wandert „Jetzt" unter dem Finger.
    @State private var now: Date?
    @State private var time = Date()
    @State private var sending = false
    /// Wen dieser Termin meint. Vorausgewaehlt ist die ganze Runde — der
    /// haeufige Fall bleibt ein Tipp, das Abwaehlen ist die Ausnahme.
    @State private var chosen: Set<String> = []
    @State private var seeded = false

    private var status: ZoneStatus? { model.status(at: spot.coordinate) }
    private var frozenNow: Date { now ?? model.now }
    private var isNow: Bool { time.timeIntervalSince(frozenNow) < Tape.nowZone }

    private var names: [String] {
        chosen.sorted().map { id in
            model.friends.friends.first { $0.id == id }.map(friendLabel) ?? "Freund"
        }
    }

    /// Ohne Angehakte gibt es niemanden zu fragen. Nur wenn der Spot ueberhaupt
    /// keine Runde hat, ist „einladen" trotzdem sinnvoll: die Einladung wartet
    /// dann auf die, die spaeter beitreten.
    private var canSend: Bool { !chosen.isEmpty || spot.participantIds.isEmpty }

    var body: some View {
        CommunitySheet(estimate: 640) {
            SPTitle(text: "Einladen")
            SPSubtitle(text: "Verabrede dich an eurem Spot — egal, wo du gerade bist.")
            SPSpotCard(spot: spot, status: status, hour: hour, userCoordinate: userCoordinate)

            SPSection(text: "Wann")
            TimeTapeView(value: $time,
                         base: frozenNow,
                         legalLine: { spotLegalLine(status, at: $0, base: frozenNow) },
                         legalWarns: { candidate in
                             guard let status else { return false }
                             return !spotAllowedAt(status, at: candidate)
                         })

            // Bis zum 18.08. stand hier eine Reihe fester Chips: die Einladung
            // hing am Spot und ging damit zwangslaeufig an ALLE, die ihn sehen.
            // Leon: „Ich kann fuenf Kollegen haben und davon zwei einladen
            // wollen." Wer den Spot dauerhaft sieht, bleibt eine Eigenschaft
            // des Spots — wen ich heute frage, gehoert dem Termin.
            SPSection(text: "Wer")
            if spot.participantIds.isEmpty {
                SPNote(text: "Noch niemand hat den Spot angenommen — die Einladung wartet dort auf sie.")
            } else {
                SPChipRow(items: spot.participantIds.map { IdentifiedString(id: $0) }) { item in
                    let friend = model.friends.friends.first { $0.id == item.id }
                    SPChip(name: friend.map(friendLabel) ?? "Freund",
                           emoji: friend?.emoji,
                           color: SP.color(friend?.color),
                           selected: chosen.contains(item.id)) {
                        if chosen.remove(item.id) == nil { chosen.insert(item.id) }
                    }
                }
            }

            // „bekommen Bescheid", nicht „nur sie sehen es": die Einladung liegt
            // in der geteilten Spot-Zone, und ein Share deckt die ganze Zone ab.
            // Was hier steht, muss halten, was die Technik hergibt.
            SPNote(text: "Nur die Angehakten bekommen Bescheid. Geteilt wird der Spot — nie dein Live-Standort.")

            SPCTA(title: isNow ? "Jetzt einladen" : "Für \(Tape.fmtClock(time)) einladen",
                  style: .blue, enabled: !sending && canSend, action: send)
            SPGhost(title: "Abbrechen") { model.closeSheet() }
        }
        .task {
            if now == nil {
                now = model.now
                time = model.now
            }
            // Einmal vorbelegen, danach gehoert die Auswahl dem Nutzer — sonst
            // stellt ein Neuzeichnen sein Abwaehlen zurueck.
            if !seeded {
                seeded = true
                chosen = Set(spot.participantIds)
            }
        }
        .task(id: spot.id) { await model.loadStatus(at: spot.coordinate) }
    }

    private func send() {
        sending = true
        let at = isNow ? model.now : time
        let label = isNow ? "jetzt" : "für \(Tape.fmtClock(time))"
        let receivers = names
        let invitees = chosen.sorted()
        let spotId = spot.id
        Task {
            do {
                try await model.sync.invite(spotId: spotId, time: at, inviteeIds: invitees)
                model.notice("Einladung \(label)"
                             + (receivers.isEmpty ? "" : " · \(receivers.joined(separator: ", "))"))
                model.closeSheet()
            } catch {
                sending = false
                model.notice(cloudMessage(error))
            }
        }
    }
}
