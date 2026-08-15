import SwiftUI

/// Onboarding. Texte woertlich aus `client/src/components/Onboarding.tsx`,
/// Masse aus `App.css` (`.onboarding`).
struct OnboardingView: View {
    let onAllow: () -> Void
    let onSkip: () -> Void

    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                mark
                    .frame(width: 84, height: 84)
                    .padding(.bottom, 20)

                Text("GreenZones")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.64)
                    .foregroundStyle(GZ.ink)

                Text("Wo Cannabis-Konsum draußen erlaubt ist — und wo nicht.")
                    .font(.system(size: 16))
                    .foregroundStyle(GZ.ink2)
                    .lineSpacing(3)
                    .padding(.top, 8)
                    .padding(.bottom, 28)

                VStack(alignment: .leading, spacing: 18) {
                    feature(icon: .check, color: GZ.ok, title: "Live-Status",
                            text: "Ein Blick: erlaubt oder verboten an deinem Standort.")
                    feature(icon: .banMark, color: GZ.ban, title: "Alle Schutzzonen",
                            text: "100 m um Schulen, Kitas, Spielplätze und Sportstätten.")
                    feature(icon: .clock, color: GZ.time, title: "Zeitfenster",
                            text: "Fußgängerzonen: verboten 7–20 Uhr, danach frei.")
                }

                Text("Orientierungshilfe auf Basis von OpenStreetMap-Daten — keine Rechtsberatung, ohne Gewähr auf Vollständigkeit. Maßgeblich ist §5 KCanG.")
                    .font(.system(size: 12))
                    .foregroundStyle(GZ.ink3)
                    .lineSpacing(3)
                    .padding(.top, 28)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                Button {
                    GZ.haptic()
                    busy = true
                    onAllow()
                } label: {
                    Text(busy ? "…" : "Standort freigeben")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(GZ.appBg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(GZ.ink, in: .rect(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button(action: onSkip) {
                    Text("Ohne Standort fortfahren")
                        .font(.system(size: 14))
                        .foregroundStyle(GZ.ink2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GZ.appBg)
    }

    /// Drei Ringe: Verbotszone (gestrichelt), Zeitfenster, erlaubter Kern.
    private var mark: some View {
        ZStack {
            Circle()
                .strokeBorder(GZ.ban.opacity(0.35),
                              style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
                .frame(width: 70, height: 70)
            Circle()
                .strokeBorder(GZ.time.opacity(0.55), lineWidth: 3)
                .frame(width: 45.5, height: 45.5)
            Circle()
                .fill(GZ.ok)
                .frame(width: 12.25, height: 12.25)
        }
    }

    private func feature(icon: VectorIcon, color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: .rect(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GZ.ink)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(GZ.ink2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
