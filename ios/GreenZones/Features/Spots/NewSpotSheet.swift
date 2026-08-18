import CoreLocation
import GreenZonesKit
import SwiftUI

/// „Spot markieren" — Port von `NewSpotSheet` aus `client/src/components/SpotSheets.tsx`,
/// Look aus `mockup/community.html` und `client/sp_shots/sp_newspot.png`.
///
/// Der Entwurf liegt im `CommunityModel`, nicht hier: „Auf Karte wählen" klappt
/// das Sheet weg, und Name, Symbol und Freundeswahl muessen diese Runde
/// ueberleben.
struct NewSpotSheet: View {
    @Bindable var model: CommunityModel
    let userCoordinate: CLLocationCoordinate2D?
    let hour: Int

    private var point: CLLocationCoordinate2D? {
        model.draft.source == 1 ? model.draft.picked : userCoordinate
    }

    private var status: ZoneStatus? { model.status(at: point) }
    private var canSave: Bool {
        point != nil && !model.draft.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        CommunitySheet(estimate: 620) {
            SPTitle(text: "Spot markieren")
            SPSubtitle(text: "Ein fester Ort für dich und deine Freunde — bleibt auf der Karte.")

            ContextHintView(hint: .newSpot, settings: model.settings)

            SPSection(text: "Name")
            SPTextField(leadingEmoji: model.draft.emoji,
                        placeholder: "Unsere Bank",
                        accessibilityLabel: "Name des Spots",
                        text: $model.draft.name)
            SPEmojiPicker(options: SpotEmoji.options, selection: $model.draft.emoji)

            SPSection(text: "Position")
            SPSegment(titles: ["Mein Standort", "Auf Karte wählen"],
                      selection: $model.draft.source) { index in
                if index == 1 { model.startPicking() }
            }

            pointNote

            if !model.friends.friends.isEmpty {
                SPSection(text: "Teilen mit")
                SPChipRow(items: model.friends.friends) { friend in
                    SPChip(name: friendLabel(friend), emoji: friend.emoji,
                           color: SP.color(friend.color),
                           selected: model.draft.shared.contains(friend.id)) {
                        if model.draft.shared.remove(friend.id) == nil {
                            model.draft.shared.insert(friend.id)
                        }
                    }
                }
                SPNote(text: "Nur geteilte Freunde sehen diesen Spot. Liegt im gemeinsamen iCloud-Bereich — nicht bei uns.")
            }

            SPCloudHint(status: model.sync.state.status)

            SPCTA(title: "Spot speichern", enabled: canSave, action: save)
            SPGhost(title: "Abbrechen") { model.closeSheet() }
        }
        .task(id: model.friends.friends.map(\.id)) {
            // Vorauswahl einmal: danach gehoert die Wahl dem Nutzer, sonst
            // setzte jeder Sync sie zurueck.
            guard !model.draft.seededShared else { return }
            model.draft.seededShared = true
            model.draft.shared = Set(model.friends.friends.map(\.id))
        }
        .task(id: pointKey) { await model.loadStatus(at: point) }
    }

    private var pointKey: String {
        point.map { "\($0.latitude),\($0.longitude)" } ?? ""
    }

    /// Status am gewaehlten Punkt — echte Werte aus der Zonen-Engine.
    @ViewBuilder
    private var pointNote: some View {
        if point == nil {
            SPNote(text: "Kein Standort — wähle den Punkt auf der Karte.")
        } else if let status {
            let kind = ZoneStatus.statusKind(status, hour: hour)
            if kind == .ok {
                let near = status.ban.nearestM.isFinite
                    ? "nächste Verbotszone \(Geo.formatDistanceM(status.ban.nearestM))"
                    : "keine Verbotszone im Umkreis von 2 km"
                SPNote(text: "Hier erlaubt · \(near) — Status wird am Spot gespeichert.", tone: .ok)
            } else {
                SPNote(text: kind == .ban
                       ? "Hier verboten · Verbotszone — Status wird am Spot gespeichert."
                       : "Jetzt verboten · Fußgängerzone bis 20 Uhr — Status wird am Spot gespeichert.",
                       tone: .no)
            }
        } else {
            SPNote(text: "Status wird geprüft …")
        }
    }

    private func save() {
        guard let point else { return }
        let name = model.draft.name.trimmingCharacters(in: .whitespaces)
        let emoji = model.draft.emoji
        let shared = Array(model.draft.shared)
        // Der Spot liegt sofort lokal; das Teilen holt der Sync notfalls nach
        // (Outbox) — deshalb blockiert das Speichern nicht auf dem Netz.
        model.run {
            try await model.sync.createSpot(name: name, emoji: emoji,
                                            lng: point.longitude, lat: point.latitude,
                                            friendIds: shared)
        }
        model.closeSheet()
    }
}

/// Bestaetigungsleiste des Pick-Modus — das Sheet ist weg, die Karte gehoert
/// dem Nutzer (`.sp-pickbar` + `.sp-cross`).
struct PickOverlay: View {
    let model: CommunityModel

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Position wählen")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(GZ.ink)
                    Text("Karte bewegen — der Punkt in der Mitte wird dein Spot.")
                        .font(.system(size: 12))
                        .foregroundStyle(GZ.ink2)
                }
                .padding(.bottom, 10)
                SPCTA(title: "Position bestätigen", style: .blue) { model.confirmPick() }
                SPGhost(title: "Abbrechen") { model.cancelPick() }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .glassCard(cornerRadius: 18)
            .padding(.horizontal, 14)
            .padding(.bottom, 80)
        }
    }
}

/// Fadenkreuz in der Kartenmitte.
struct PickCrosshair: View {
    var body: some View {
        SPIcon(kind: .crosshair)
            .stroke(GZ.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 54, height: 54)
            .overlay {
                Circle().fill(GZ.accent).frame(width: 4, height: 4)
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            .allowsHitTesting(false)
    }
}
