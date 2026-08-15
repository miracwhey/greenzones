import GreenZonesKit
import SwiftUI

/// Freundesliste nach `mockup/community.html` (Szenario „friends"), mit dem
/// eigenen Profil als erster Zeile (`mockup/profile.html`, Variante A).
///
/// Freunde entstehen ausschliesslich ueber einen Einladungslink: kein
/// Verzeichnis, keine Kontakte, keine Handynummer. Das eigene Profil wohnt
/// dauerhaft hier — wer ueber einen Link beigetreten ist, hat noch keins und
/// findet an dieser Stelle den Weg dorthin, ohne dafuer selbst einladen zu muessen.
struct FriendsSheet: View {
    let model: CommunityModel
    /// Direkt im Profil-Schritt oeffnen (Absprung aus dem Spot-Detail ohne
    /// Freunde: `.invite`). `nil` = die Liste.
    let initialIntent: ProfileIntent?

    @State private var intent: ProfileIntent?
    @State private var seeded = false

    private var friends: [Friend] { model.friends.friends }
    private var shared: [Spot] {
        model.spots.spots.filter { $0.zoneName != nil || $0.sharePending }
    }
    private var profile: Profile { model.settings.profile }

    var body: some View {
        Group {
            if let intent {
                CommunitySheet(estimate: 700) {
                    ProfileEditor(model: model, intent: intent,
                                  onDone: { self.intent = nil },
                                  onCancel: { self.intent = nil })
                }
            } else {
                list
            }
        }
        .task {
            guard !seeded else { return }
            seeded = true
            // Der Absprung landet im Profil-Schritt (kein Cloud-Write beim Oeffnen).
            intent = initialIntent
        }
    }

    private var list: some View {
        CommunitySheet(estimate: 460) {
            SPTitle(text: "Freunde")
            SPSubtitle(text: friends.isEmpty
                ? "Noch niemand — teilt einen Link, dann seht ihr eure Spots gemeinsam."
                : "\(friends.count) \(friends.count == 1 ? "Freund" : "Freunde") · \(shared.count) \(shared.count == 1 ? "gemeinsamer Spot" : "gemeinsame Spots")")

            selfRow

            if !friends.isEmpty { SPSection(text: "Deine Freunde") }
            ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                SPMemberRow(friend: friend,
                            detail: sharedSpotsLine(spotNames(friend.id)),
                            showDivider: index > 0)
            }

            Button(action: { GZ.haptic(); intent = .invite }) {
                HStack(spacing: 8) {
                    SPIcon(kind: .share).stroked(GZ.accent, size: 17, width: 2)
                    Text("Freund hinzufügen — Link teilen")
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
            .padding(.bottom, 4)

            SPCloudHint(status: model.sync.state.status)
            SPGhost(title: "Schließen") { model.closeSheet() }
        }
    }

    /// Eigene Profilzeile ueber der Freundesliste (Variante A).
    private var selfRow: some View {
        let hasProfile = profile.isSet
        return Button(action: { GZ.haptic(); intent = .edit }) {
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
