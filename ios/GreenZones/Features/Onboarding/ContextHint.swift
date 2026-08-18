import GreenZonesKit
import SwiftUI

/// Dieselbe Aussage noch einmal dort, wo gehandelt wird.
///
/// Leon-Auftrag zum Onboarding (18.08.): die vier Schritte vor der Karte
/// erklären die Regeln einmal am Stück — wer sie dann drei Tage später zum
/// ersten Mal braucht, hat sie nicht mehr im Kopf. Also steht jede Aussage ein
/// zweites Mal an ihrer Handlungsstelle: im Freunde-Blatt, beim neuen Spot, in
/// der Kamera und am Album. **Einmalig** — beim ersten Erscheinen wird der
/// Hinweis vermerkt und kommt nie wieder.
///
/// Die Texte stehen hier und nur hier. Sie sagen dasselbe wie der jeweilige
/// Onboarding-Schritt und wie `docs/datenlandkarte.md`; wer sie ändert, muss
/// dort nachsehen — zwei Fassungen derselben Zusage wären eine Zusage zu viel.
enum ContextHint: String {
    /// Onboarding-Schritt „Orte, die euch gehören" → „Per Link einladen".
    case friends
    /// Schritt „Orte, die euch gehören" → „Nie deine Position".
    case newSpot = "newspot"
    /// Schritt „Bilder bleiben im Kreis" → „Kein Ort im Bild".
    case camera
    /// Schritt „Bilder bleiben im Kreis" → „Du bestimmst, wer ihn sieht".
    case album

    var text: String {
        switch self {
        case .friends:
            return "Freunde entstehen über einen Link — ohne Konto, ohne Adressbuch. Name und Zeichen liegen in eurer iCloud."
        case .newSpot:
            return "Geteilt wird der Ort des Spots — nie, wo du gerade bist."
        case .camera:
            return "Live aufgenommen, nie aus der Mediathek. Im Bild selbst steht kein Ort."
        case .album:
            return "Bilder sehen nur die Freunde, denen du sie gibst."
        }
    }
}

/// Zeigt einen `ContextHint` genau beim ersten Mal.
///
/// Der Vermerk wird beim Erscheinen geschrieben, die Sichtbarkeit aber aus
/// einem eigenen Zustand gespeist: sonst verschwände der Hinweis im selben
/// Augenblick wieder, in dem er sich abhakt.
struct ContextHintView: View {
    enum Style {
        /// Auf hellem Blattgrund, in der Optik von `SPNote`.
        case sheet
        /// Über der Kamera — heller Text auf dunklem Grund.
        case overlay
    }

    let hint: ContextHint
    let settings: SettingsStore
    var style: Style = .sheet

    @State private var visible: Bool?

    var body: some View {
        // `VStack`, nicht `Group`: solange `visible` noch nichts weiß, ist der
        // Inhalt leer — und ein leerer `Group` wird zu `EmptyView`, an der kein
        // `task` läuft. Der Hinweis hätte sich seinen eigenen Auslöser
        // weggerendert (im Bild gesehen: Blatt ohne Hinweis, obwohl frisch
        // installiert).
        VStack(spacing: 0) {
            if visible == true {
                switch style {
                case .sheet: sheetBody
                case .overlay: overlayBody
                }
            }
        }
        .task {
            guard visible == nil else { return }
            let unseen = !settings.seenHints.contains(hint.rawValue)
            withAnimation(GZ.elementSpring) { visible = unseen }
            if unseen { try? await settings.markHintSeen(hint.rawValue) }
        }
    }

    private var sheetBody: some View {
        HStack(alignment: .top, spacing: 10) {
            SPIcon(kind: .note).stroked(GZ.accent, size: 15, width: 1.9)
                .padding(.top, 1)
            // Die Marke sitzt am Text, nicht an der Huelle: ein VStack ohne
            // eigene Barrierefreiheits-Rolle taucht in der Hierarchie nicht auf,
            // und der Test suchte etwas, das es nie gab.
            Text(hint.text)
                .font(.system(size: 12.5))
                .foregroundStyle(GZ.ink2)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("gz.hint.\(hint.rawValue)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(GZ.accent.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        .padding(.bottom, 14)
    }

    private var overlayBody: some View {
        Text(hint.text)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("gz.hint.\(hint.rawValue)")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: 300)
    }
}
