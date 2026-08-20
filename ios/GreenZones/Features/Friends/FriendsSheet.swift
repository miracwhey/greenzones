import GreenZonesKit
import SwiftUI

/// Freundesliste nach `mockup/community.html` (Szenario „friends"), mit dem
/// eigenen Profil als erster Zeile (`mockup/profile.html`, Variante A) und den
/// beiden Wegen zueinander aus `mockup/qr.html`: „Freund hinzufügen" zeigt den
/// eigenen Code, „Code scannen" tritt bei.
///
/// Freunde entstehen ausschliesslich ueber eine iCloud-Einladung — als Code vor
/// Ort oder als Link fuer alle, die nicht zusammen sind: kein Verzeichnis,
/// keine Kontakte, keine Handynummer. Das eigene Profil wohnt dauerhaft hier —
/// wer ueber einen Link beigetreten ist, hat noch keins und findet an dieser
/// Stelle den Weg dorthin, ohne dafuer selbst einladen zu muessen.
struct FriendsSheet: View {
    let model: CommunityModel
    /// Direkt im Profil-Schritt oeffnen (Absprung aus dem Spot-Detail ohne
    /// Freunde: `.invite`). `nil` = die Liste.
    let initialIntent: ProfileIntent?

    /// Die drei Gesichter des Blatts. Ein Zustand IM Blatt, kein Blattwechsel:
    /// der Inhalt geht mit der Blatt-Feder ineinander ueber, statt dass ein
    /// Blatt faellt und ein neues steigt.
    private enum Stage: Equatable {
        case list
        case editor(ProfileIntent)
        /// Der eigene Einladungs-Code (`InviteCodeView`) — Name und Zeichen
        /// reisen aus dem Editor mit, gespeichert wird erst mit der Einladung.
        case code(name: String, emoji: String)
    }

    @State private var stage: Stage = .list
    @State private var seeded = false
    /// Freund, dessen Entfernen gerade nachgefragt wird.
    @State private var removing: Friend?

    private var friends: [Friend] { model.friends.friends }
    private var shared: [Spot] {
        model.spots.spots.filter { $0.zoneName != nil || $0.sharePending }
    }
    private var profile: Profile { model.settings.profile }

    var body: some View {
        Group {
            switch stage {
            case .editor(let intent):
                CommunitySheet(estimate: 700) {
                    ProfileEditor(model: model, intent: intent,
                                  onDone: { show(.list) },
                                  onCancel: { show(.list) },
                                  onShowCode: { name, emoji in
                                      show(.code(name: name, emoji: emoji))
                                  })
                }
                .transition(.opacity)
            case .code(let name, let emoji):
                CommunitySheet(estimate: 620) {
                    InviteCodeView(model: model, name: name, emoji: emoji,
                                   onClose: { show(.list) })
                }
                .transition(.opacity)
            case .list:
                list
                    .transition(.opacity)
            }
        }
        .task {
            guard !seeded else { return }
            seeded = true
            // Der Absprung landet im Profil-Schritt (kein Cloud-Write beim Oeffnen).
            if let initialIntent { stage = .editor(initialIntent) }
            #if DEBUG
            // Screenshot-Route: direkt der Code-Schritt, mit dem Fixture-Profil.
            if DebugEnvironment.route == .inviteCode || DebugEnvironment.route == .inviteCodeOffline {
                stage = .code(name: profile.displayName, emoji: profile.emoji)
            }
            #endif
        }
    }

    /// Stage-Wechsel immer mit der Blatt-Feder: Inhalt UND Hoehe federn
    /// gemeinsam, nichts springt.
    private func show(_ next: Stage) {
        withAnimation(GZ.sheetSpring) { stage = next }
    }

    private var list: some View {
        CommunitySheet(estimate: 500) {
            SPTitle(text: "Freunde")
            SPSubtitle(text: friends.isEmpty
                ? "Noch niemand — verbindet euch per Code oder Link, dann seht ihr eure Spots gemeinsam."
                : "\(friends.count) \(friends.count == 1 ? "Freund" : "Freunde") · \(shared.count) \(shared.count == 1 ? "gemeinsamer Spot" : "gemeinsame Spots")")

            ContextHintView(hint: .friends, settings: model.settings)

            selfRow

            if !friends.isEmpty { SPSection(text: "Deine Freunde") }
            ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                SPMemberRow(friend: friend,
                            detail: sharedSpotsLine(spotNames(friend.id)),
                            showDivider: index > 0,
                            onRemove: { removing = friend })
            }

            Button(action: { GZ.haptic(); show(.editor(.invite)) }) {
                HStack(spacing: 8) {
                    SPIcon(kind: .personAdd).stroked(GZ.accent, size: 18, width: 2)
                    Text("Freund hinzufügen")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(GZ.accent)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(GZ.accent.opacity(0.06), in: .rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(GZ.accent.opacity(0.45),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 14)

            // Der zweite Weg gehoert dem Beitretenden — eine ruhige Zeile, kein
            // zweiter Kasten (Mockup-Entscheid: das Blatt bleibt leicht).
            Button(action: { model.openScanner() }) {
                HStack(spacing: 7) {
                    Text("Eingeladen?")
                        .font(.system(size: 13.5))
                        .foregroundStyle(GZ.ink2)
                    SPIcon(kind: .scan).stroked(GZ.accent, size: 16, width: 2)
                    Text("Code scannen")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(GZ.accent)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("gz.friends.scan")
            .padding(.bottom, 2)

            SPCloudHint(status: model.sync.state.status)
            SPGhost(title: "Schließen") { model.closeSheet() }
        }
        // `.alert`, nicht `.confirmationDialog`: der schluckt unter iOS 26 den
        // Abbrechen-Knopf, wenn er aus einem Sheet heraus kommt.
        .alert("Freund entfernen?", isPresented: Binding(get: { removing != nil },
                                                        set: { if !$0 { removing = nil } }),
               presenting: removing) { friend in
            Button("Entfernen", role: .destructive) {
                removing = nil
                model.run { try await model.sync.removeFriend(id: friend.id) }
            }
            Button("Abbrechen", role: .cancel) { removing = nil }
        } message: { friend in
            Text("\(friendLabel(friend)) sieht eure gemeinsamen Spots dann nicht mehr, und du seine nicht. Zurück geht es nur über eine neue Einladung.")
        }
    }

    /// Eigene Profilzeile ueber der Freundesliste (Variante A).
    private var selfRow: some View {
        let hasProfile = profile.isSet
        return Button(action: { GZ.haptic(); show(.editor(.edit)) }) {
            HStack(spacing: 12) {
                SPAvatar(name: profile.displayName, emoji: profile.emoji,
                         color: GZ.accent, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hasProfile ? profile.displayName : "Profil einrichten")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(hasProfile ? GZ.ink : GZ.accent)
                    Text(hasProfile
                         ? "So sehen dich deine Freunde"
                         : (friends.count == 1
                            ? "\(friendLabel(friends[0])) sieht dich sonst nur als „Freund“"
                            : "Sonst stehst du bei den anderen nur als „Freund“"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(GZ.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Text(hasProfile ? "Ändern" : "›")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GZ.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(hasProfile ? SP.selfRow : GZ.accent.opacity(0.07),
                        in: .rect(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(hasProfile ? GZ.stroke : GZ.accent.opacity(0.4),
                                  style: hasProfile
                                      ? StrokeStyle(lineWidth: 1)
                                      : StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .buttonStyle(.plain)
    }

    private func spotNames(_ friendId: String) -> [String] {
        shared.filter { $0.participantIds.contains(friendId) }.map(\.name)
    }

    private func sharedSpotsLine(_ names: [String]) -> String {
        if names.isEmpty { return "Noch keine gemeinsamen Spots" }
        let word = names.count == 1 ? "gemeinsamer Spot" : "gemeinsame Spots"
        return "\(names.count) \(word) · \(names.joined(separator: ", "))"
    }
}
