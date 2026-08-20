import GreenZonesKit
import SwiftUI

/// Rolle des Profil-Editors — dieselbe Flaeche, drei Anlaesse.
enum ProfileIntent: Equatable {
    /// Aus der Freundesliste heraus: einrichten oder aendern.
    case edit
    /// Vorstufe zum Einladungslink: ohne Namen sieht der Empfaenger nichts von dir.
    case invite
    /// Direkt nach einem Beitritt ueber einen Link.
    case welcome(hostName: String?)

    /// Stabiler Schluessel fuer die Sheet-Identitaet.
    var key: String {
        switch self {
        case .edit: return "edit"
        case .invite: return "invite"
        case .welcome: return "welcome"
        }
    }
}

/// Profil = Anzeigename + optionales Zeichen (`mockup/profile.html`).
///
/// Beides ist frei waehlbar und liegt in den Friendship-Zonen der Freunde, mit
/// denen geteilt wurde — kein Konto, kein Verzeichnis, kein Server. Das Zeichen
/// ist bewusst ein Emoji und kein Foto: es kostet keinen CKAsset-Transfer in
/// einer geteilten Zone und verlangt keinen Kamera-Zugriff.
struct ProfileEditor: View {
    let model: CommunityModel
    let intent: ProfileIntent
    let onDone: () -> Void
    let onCancel: () -> Void
    /// Nur fuer `.invite`: weiter zum Code-Schritt (Name + Zeichen reisen mit,
    /// gespeichert wird erst dort — mit der Einladung, in EINEM Fehlerpfad).
    var onShowCode: ((String, String) -> Void)? = nil

    @State private var name = ""
    @State private var emoji = ""
    @State private var busy = false
    @State private var seeded = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var isWelcome: Bool { if case .welcome = intent { return true }; return false }
    private var isInvite: Bool { intent == .invite }

    private var title: String {
        if case .welcome(let host) = intent {
            return host.map { "Du bist mit \($0) verbunden" } ?? "Du bist verbunden"
        }
        return "Dein Profil"
    }

    var body: some View {
        Group {
            SPTitle(text: title)
            SPSubtitle(text: isWelcome
                ? "Ihr teilt ab jetzt Spots und Einladungen. Sag noch, wer du bist."
                : "Nur deine Freunde sehen das — es liegt in eurem gemeinsamen iCloud-Bereich.")

            VStack(spacing: 9) {
                SPAvatar(name: trimmed, emoji: emoji, color: GZ.accent, size: 104)
                Text(trimmed.isEmpty ? "Name eingeben — Zeichen ist freiwillig"
                                     : "So sehen dich deine Freunde")
                    .font(.system(size: 12.5))
                    .foregroundStyle(GZ.ink2)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 2)

            SPSection(text: "Name")
            SPTextField(placeholder: isWelcome ? "Wie sollen sie dich sehen?"
                                               : "Wie sollen dich deine Freunde nennen?",
                        accessibilityLabel: "Dein Anzeigename",
                        maxLength: 24,
                        text: $name)

            SPSection(text: "Zeichen")
            glyphGrid

            SPNote(text: isWelcome
                ? "Ohne Namen erscheinst du als „Freund“. Kannst du jederzeit nachholen."
                : "Kein Konto, kein Server: Name und Zeichen gehen nur an die Freunde, mit denen du geteilt hast.")

            SPCTA(title: isInvite ? "Weiter — Code zeigen" : "Speichern",
                  style: .blue, enabled: !busy && !trimmed.isEmpty, action: save)
            SPGhost(title: isWelcome ? "Überspringen" : "Abbrechen", action: skip)
        }
        .task {
            guard !seeded else { return }
            seeded = true
            name = model.settings.profile.displayName
            emoji = model.settings.profile.emoji
        }
    }

    /// Kantenlaenge der quadratischen Kacheln: 8 Spalten, 7 pt Luft dazwischen,
    /// exakt die Sheet-Innenbreite. `aspectRatio` allein reichte nicht — es misst
    /// den Text, nicht die Spalte, und machte aus den Kacheln Kreise.
    private var tileSide: CGFloat {
        max((SPScreen.sheetContentWidth - 7 * 7) / 8, 30)
    }

    /// Zeichen-Raster — gleiche Bauart wie die Spot-Emojis, nur mehr Auswahl.
    private var glyphGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 8),
                  spacing: 7) {
            ForEach(SpotEmoji.profile, id: \.self) { option in
                glyph(option) {
                    Text(option).font(.system(size: 19))
                }
            }
            glyph("") {
                Text("Ohne")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GZ.ink2)
                    // Lieber ueberstehen als abschneiden — „O…" waere kein Wort.
                    .fixedSize()
            }
        }
    }

    private func glyph<Content: View>(_ value: String,
                                      @ViewBuilder label: () -> Content) -> some View {
        let selected = emoji == value
        return Button(action: { GZ.haptic(); emoji = value }) {
            label()
                .frame(maxWidth: .infinity)
                .frame(height: tileSide)
                .background(selected ? GZ.accent.opacity(0.10) : SP.tile,
                            in: .rect(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(selected ? GZ.accent : GZ.stroke, lineWidth: 1.5)
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(GZ.accent.opacity(0.12), lineWidth: 3)
                            .padding(-1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.isEmpty ? "Zeichen Ohne" : "Zeichen \(value)")
    }

    private func save() {
        // Einladen speichert hier NICHTS: Profil und Einladung gehen im
        // Code-Schritt zusammen in die Cloud (`inviteFriend`) — sonst gaebe es
        // zwei Fehlerpfade fuer eine Handlung.
        if isInvite {
            onShowCode?(trimmed, emoji)
            return
        }
        busy = true
        let chosenName = trimmed
        let chosenEmoji = emoji
        Task {
            do {
                try await model.sync.setProfile(name: chosenName, emoji: chosenEmoji)
                onDone()
            } catch {
                model.notice(cloudMessage(error))
            }
            busy = false
        }
    }

    private func skip() {
        GZ.haptic()
        if isWelcome {
            model.run { try await model.sync.skipProfilePrompt() }
        }
        onCancel()
    }
}

/// Der Profil-Schritt direkt nach einem Beitritt. Er haengt am Zustand „Freunde
/// da, eigenes Profil leer", nicht am Accept-Ereignis: nach einem Kaltstart ueber
/// den Share-Link ist das Ereignis laengst vorbei, der Zustand aber noch da.
struct ProfilePromptSheet: View {
    let model: CommunityModel

    private var hostName: String? {
        guard model.friends.friends.count == 1 else { return nil }
        let label = friendLabel(model.friends.friends[0])
        return label == "Freund" ? nil : label
    }

    var body: some View {
        CommunitySheet(estimate: 700) {
            ProfileEditor(model: model,
                          intent: .welcome(hostName: hostName),
                          onDone: { model.closeSheet() },
                          onCancel: { model.closeSheet() })
        }
    }
}

/// Systemweites Teilen-Blatt fuer den Einladungslink.
@MainActor
enum ShareLinkPresenter {
    static func present(url: String, name: String) {
        guard let link = URL(string: url) else { return }
        let text = "\(name) teilt seine Spots mit dir."
        let controller = UIActivityViewController(activityItems: [text, link],
                                                  applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        // Abbruch im Teilen-Blatt ist keine Stoerung — der Link bleibt gueltig.
        controller.popoverPresentationController?.sourceView = root.view
        root.present(controller, animated: true)
    }
}
