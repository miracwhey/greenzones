import GreenZonesKit
import SwiftUI

/// Der eigene Einladungs-Code (`mockup/qr.html`, Szenario „qr"): der Einladende
/// zeigt, der Freund scannt — der Link bleibt als zweiter Weg fuer alle, die
/// nicht zusammen sind. Code und Link sind DIESELBE CKShare-URL.
///
/// Die Einladung entsteht in iCloud, deshalb hat das Blatt drei ehrliche
/// Zustaende: entstehen, fertig, fehlgeschlagen (mit Weg zurueck). Die URL wird
/// EINMAL erzeugt und behalten — „Link teilen" nutzt dieselbe, ein erneutes
/// Oeffnen des Teilens erzeugt keine zweite Einladung.
struct InviteCodeView: View {
    let model: CommunityModel
    let name: String
    let emoji: String
    let onClose: () -> Void

    private enum Phase: Equatable {
        case creating
        case ready(url: String)
        case failed(message: String)
    }

    @State private var phase: Phase = .creating
    @State private var qr: CGImage?
    @State private var started = false

    private var isReady: Bool { if case .ready = phase { return true }; return false }

    var body: some View {
        Group {
            SPTitle(text: "Freund hinzufügen")
            SPSubtitle(text: "Dein Freund scannt den Code — dann seid ihr verbunden.")

            card
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            if isReady {
                (Text("Du lädst ein als ").foregroundStyle(GZ.ink2)
                    + Text(name).fontWeight(.semibold).foregroundStyle(GZ.ink))
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .transition(.opacity)

                shareLinkButton
                    .padding(.top, 14)
                    .transition(.opacity)
            }

            SPNote(text: "Code und Link sind dieselbe Einladung über iCloud. Wer sie annimmt, wird dein Freund — sonst sieht sie niemand.")

            SPGhost(title: "Schließen", action: onClose)
        }
        .task {
            guard !started else { return }
            started = true
            await create()
        }
    }

    // MARK: - Karte

    /// Weisse Karte in BEIDEN Schemata: ein QR-Code braucht hellen Grund, sonst
    /// scannt er schlecht — das ist Physik, kein Theme.
    private var card: some View {
        ZStack {
            switch phase {
            case .creating:
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(Color(white: 0.35))
                    Text("Der Code entsteht in iCloud …")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.35))
                }
                .transition(.opacity)
            case .ready:
                codeImage
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            case .failed(let message):
                VStack(spacing: 12) {
                    SPIcon(kind: .cross).stroked(GZ.ban, size: 22, width: 2.4)
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.25))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: retry) {
                        Text("Nochmal versuchen")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(GZ.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("gz.invite.retry")
                }
                .padding(.horizontal, 10)
                .transition(.opacity)
            }
        }
        .frame(width: 258, height: 258)
        .background(Color.white, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 17, y: 5)
    }

    @ViewBuilder
    private var codeImage: some View {
        if let qr {
            ZStack {
                // Nicht `decorative`: der Code IST der Inhalt dieser Karte —
                // und der Anker gehoert ans Element, nicht an den Container
                // (ein Container-Identifier verschluckt die Kinder im UI-Test).
                Image(qr, scale: 1, label: Text("Dein Einladungs-Code"))
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(14)
                    .accessibilityIdentifier("gz.invite.code")
                // Weisser Ring unter dem Zeichen — derselbe Anker wie im
                // Mockup; Stufe H des Codes deckt die Verdeckung (im Kit-Test
                // gegen genau diese Flaeche gemessen).
                Circle().fill(Color.white).frame(width: 61, height: 61)
                SPAvatar(name: name, emoji: emoji, color: GZ.accent, size: 54)
            }
        } else {
            // Sollte nie eintreten (der Generator kennt keinen Fehlerfall fuer
            // gueltige URLs) — aber ein leerer weisser Kasten waere eine Luege.
            Text("Der Code lässt sich nicht zeichnen — nimm den Link unten.")
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.25))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var shareLinkButton: some View {
        Button(action: shareLink) {
            HStack(spacing: 8) {
                SPIcon(kind: .share).stroked(GZ.ink, size: 17, width: 2)
                (Text("Link teilen").fontWeight(.semibold).foregroundStyle(GZ.ink)
                    + Text(" — wenn ihr nicht zusammen seid").foregroundStyle(GZ.ink2))
                    .font(.system(size: 14))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(SP.field, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(GZ.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("gz.invite.sharelink")
    }

    // MARK: - Entstehen

    private func create() async {
        #if DEBUG
        // Fixture-Laeufe haben keine Cloud: `invite_code` zeigt den fertigen
        // Code (echter Renderweg, feste URL), `invite_code_offline` den
        // ehrlichen Fehlerzustand — beides echte Zweige dieser View.
        if DebugEnvironment.usesFixtures {
            if DebugEnvironment.route == .inviteCodeOffline {
                show(failure: cloudMessage(SyncError.noAccount))
            } else {
                show(url: "https://www.icloud.com/share/0GreenZonesFixtureCode")
            }
            return
        }
        #endif
        do {
            let url = try await model.sync.inviteFriend(displayName: name, emoji: emoji)
            show(url: url)
        } catch {
            GZ.hapticStatus(ok: false)
            show(failure: cloudMessage(error))
        }
    }

    private func retry() {
        GZ.haptic()
        withAnimation(GZ.elementSpring) { phase = .creating }
        Task { await create() }
    }

    private func show(url: String) {
        qr = InviteLink.qrImage(for: url)
        withAnimation(GZ.elementSpring) { phase = .ready(url: url) }
    }

    private func show(failure message: String) {
        withAnimation(GZ.elementSpring) { phase = .failed(message: message) }
    }

    private func shareLink() {
        guard case .ready(let url) = phase else { return }
        GZ.haptic()
        ShareLinkPresenter.present(url: url, name: name)
    }
}
