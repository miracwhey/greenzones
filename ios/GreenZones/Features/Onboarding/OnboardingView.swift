import SwiftUI

/// Vier Schritte vor der Karte: Zonen → Privatsphäre → Spots → Snaps.
///
/// Der Vorgänger war der v1-Bildschirm — eine Seite über Zonen und die
/// Standortfrage. Spots, Freunde und Snaps kamen darin nicht vor; wer die App
/// zum ersten Mal öffnete, wusste nicht, dass es sie gibt. Texte und Reihenfolge
/// sind am Mockup abgenommen (18.08.) und stehen hier wörtlich.
///
/// Berechtigungen bleiben im Kontext: hier wird nur der Standort gefragt, und
/// zwar erst nach dem Bildschirm, der ihn erklärt. Die Kamera fragt beim ersten
/// Auslösen, die Mitteilungen beim ersten Freund — beides bleibt, wo es ist.
///
/// Die zweite Hälfte des abgenommenen Konzepts gehört NICHT hierher: dieselbe
/// Aussage noch einmal an dem Ort, wo gehandelt wird — beim ersten Öffnen des
/// Freunde-Blatts, beim ersten Spot, beim ersten Auslösen. Zwei davon stehen
/// schon (Suchleiste, Info-Blatt), die übrigen kommen als eigener Block.
struct OnboardingView: View {
    /// Standort freigeben und schließen. Der Systemdialog erscheint danach.
    let onAllow: () -> Void
    /// Ohne Standort weiter — nur im ersten Schritt erreichbar.
    let onSkip: () -> Void
    /// Ist die Ortung schon erlaubt (Bestandsnutzer), gibt es nichts zu fragen:
    /// dann trägt der erste Schritt „Weiter" statt eines Knopfes, der einen
    /// Dialog verspricht, der nie kommt.
    var locationAlreadyAuthorized = false

    @State private var step = DebugEnvironment.onboardingStep
    @State private var busy = false

    private var steps: [Step] { Step.all }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                let current = steps[step]

                current.mark
                    .frame(width: 84, height: 84)
                    .padding(.bottom, 20)

                Text(current.title)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(GZ.ink)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(current.lead.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 15.5))
                        .foregroundStyle(GZ.ink2)
                        .lineSpacing(3)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(current.rows.enumerated()), id: \.offset) { _, row in
                        feature(row)
                    }
                }
                .padding(.top, 26)

                if let foot = current.foot {
                    Text(foot)
                        .font(.system(size: 12))
                        .foregroundStyle(GZ.ink3)
                        .lineSpacing(3)
                        .padding(.top, 26)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Die Schritte wechseln als Ganzes: ein Blatt, das seinen Inhalt
            // tauscht, nicht vier Ansichten, die übereinander stehen.
            .id(step)
            .transition(.asymmetric(insertion: .offset(x: 26).combined(with: .opacity),
                                    removal: .offset(x: -26).combined(with: .opacity)))

            VStack(spacing: 6) {
                Button(action: advance) {
                    Text(busy ? "…" : primaryTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(GZ.appBg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(GZ.ink, in: .rect(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("gz.onboarding.primary")

                // „Später" gibt es nur, solange die Standortfrage offen ist.
                // In den Schritten danach gäbe es nichts zu überspringen —
                // sie sind zusammen so lang wie der eine Bildschirm vorher.
                if step == 0 && !locationAlreadyAuthorized {
                    Button(action: onSkip) {
                        Text("Später, erstmal umsehen")
                            .font(.system(size: 14))
                            .foregroundStyle(GZ.ink2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("gz.onboarding.skip")
                } else {
                    Color.clear.frame(height: 44)
                }

                pips
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GZ.appBg)
        .animation(GZ.elementSpring, value: step)
    }

    private var primaryTitle: String {
        if step == 0 { return locationAlreadyAuthorized ? "Weiter" : "Standort freigeben" }
        return step == steps.count - 1 ? "Los geht's" : "Weiter"
    }

    private func advance() {
        GZ.haptic()
        guard step < steps.count - 1 else {
            busy = true
            onAllow()
            return
        }
        // Der Systemdialog gehört ans Ende, nicht in die Mitte: sonst steht er
        // über Schritt 2 und verdeckt den Text, der ihn begründet hat. Deshalb
        // trägt `onAllow` beides — Erlaubnis fragen und schließen — und die
        // Zwischenschritte laufen ohne Seiteneffekt.
        step += 1
    }

    private var pips: some View {
        HStack(spacing: 5) {
            ForEach(0..<steps.count, id: \.self) { index in
                Capsule()
                    .fill(index == step ? GZ.ink2 : GZ.ink3.opacity(0.45))
                    .frame(width: index == step ? 16 : 5, height: 5)
            }
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    private func feature(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 14) {
            row.icon
                .stroke(row.color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)
                .frame(width: 36, height: 36)
                .background(row.color.opacity(0.12), in: .rect(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GZ.ink)
                Text(row.text)
                    .font(.system(size: 13))
                    .foregroundStyle(GZ.ink2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Inhalt

extension OnboardingView {
    fileprivate struct Row {
        let icon: AnyShape
        let color: Color
        let title: String
        let text: String
    }

    fileprivate struct Step {
        let title: String
        let lead: [String]
        let rows: [Row]
        var foot: String?
        let mark: AnyView

        static let all: [Step] = [zones, privacy, spots, snaps]

        /// 1 — die Karte. Erklärt die drei Farben, BEVOR nach dem Standort
        /// gefragt wird; der Systemdialog kommt erst nach dem Knopf.
        static let zones = Step(
            title: "Wo du gerade stehst",
            lead: ["Ein Blick genügt: erlaubt oder verboten, an deinem Ort, zu dieser Stunde."],
            rows: [
                Row(icon: AnyShape(VectorIcon.banMark), color: GZ.ban, title: "Rote Flächen",
                    text: "100 m um Schulen, Kitas, Spielplätze, Jugendtreffs und Sportstätten."),
                Row(icon: AnyShape(VectorIcon.clock), color: GZ.time, title: "Orange Flächen",
                    text: "Fußgängerzonen — verboten von 7 bis 20 Uhr, danach frei."),
                Row(icon: AnyShape(VectorIcon.check), color: GZ.ok, title: "Alles andere",
                    text: "Kein Verbot nach §5 KCanG."),
            ],
            foot: "Orientierungshilfe auf Basis von OpenStreetMap-Daten — keine Rechtsberatung, ohne Gewähr auf Vollständigkeit. Maßgeblich ist §5 KCanG.",
            mark: AnyView(ZonesMark()))

        /// 2 — das Versprechen, bevor zum ersten Mal etwas entsteht, das geteilt
        /// wird. Die zweite Zeile ist die unbequeme: Kartenbild und Adresssuche
        /// gehen an Dritte. Sie wegzulassen wäre der einfachere Bildschirm — und
        /// eine Lücke im Versprechen.
        static let privacy = Step(
            title: "Deine Daten bleiben deine",
            lead: ["GreenZones hat keinen Server. Spots, Freunde und Bilder liegen auf deinem Gerät und in deiner iCloud.",
                   "Kein Konto, keine Anmeldung, keine Werbung, keine Statistik über dich."],
            rows: [
                Row(icon: AnyShape(VectorIcon.check), color: GZ.ok, title: "Standort",
                    text: "Bleibt beim Anzeigen auf dem Gerät. Geteilt nur als Ort eines Spots oder Shots, den du selbst anlegst."),
                Row(icon: AnyShape(VectorIcon.globe), color: GZ.ink3, title: "Karte & Adressen",
                    text: "Das Kartenbild lädt von OpenFreeMap. Adressen sucht Komoot — nur wenn du danach fragst."),
            ],
            mark: AnyView(ShieldMark()))

        /// 3 — der Schritt, den es vorher gar nicht gab. Ohne ihn ist der
        /// Freunde-Knopf auf der Karte eine Funktion ohne Anlass.
        static let spots = Step(
            title: "Orte, die euch gehören",
            lead: ["Ein Spot ist ein Platz, den du mit Freunden teilst. Eure Bank, euer Park."],
            rows: [
                Row(icon: AnyShape(SPIcon(kind: .share)), color: GZ.accent, title: "Per Link einladen",
                    text: "Ohne Konto, ohne Adressbuch. Du schickst einen Link, fertig."),
                Row(icon: AnyShape(VectorIcon.clock), color: GZ.ok, title: "Termine mit Zeit",
                    text: "Sag, ab wann du da bist. Jeder antwortet mit seiner eigenen Zeit."),
                Row(icon: AnyShape(VectorIcon.banMark), color: GZ.ink3, title: "Nie deine Position",
                    text: "Geteilt wird der Ort des Spots — nicht, wo du gerade bist."),
            ],
            mark: AnyView(PinMark()))

        /// 4 — Fotos sind das Heikelste, was die App teilt. Deshalb steht die
        /// Sichtbarkeit hier und nicht erst im Auslöser.
        static let snaps = Step(
            title: "Bilder bleiben im Kreis",
            lead: ["Ein Shot entsteht live in der Kamera — nie aus deiner Mediathek."],
            rows: [
                Row(icon: AnyShape(VectorIcon.check), color: GZ.ok, title: "Landet, wo du bist",
                    text: "In der Nähe eines Spots gehört er dorthin, sonst wird er ein Pin auf der Karte."),
                Row(icon: AnyShape(SPIcon(kind: .share)), color: GZ.accent, title: "Du bestimmst, wer ihn sieht",
                    text: "Alle deine Freunde — oder nur die, die zum Spot gehören."),
                Row(icon: AnyShape(VectorIcon.banMark), color: GZ.ink3, title: "Kein Ort im Bild",
                    text: "Die Datei trägt weder Koordinate noch Gerätespur."),
            ],
            mark: AnyView(CameraMark()))
    }
}

// MARK: - Marken

/// Drei Ringe: Verbotszone (gestrichelt), Zeitfenster, erlaubter Kern.
private struct ZonesMark: View {
    var body: some View {
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
}

private struct ShieldMark: View {
    var body: some View {
        ZStack {
            ShieldShape()
                .stroke(GZ.ok, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            VectorIcon.check
                .stroke(GZ.ok, style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
                .frame(width: 26, height: 26)
                .offset(y: -2)
        }
        .frame(width: 66, height: 66)
    }
}

private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.5, y: h * 0.06))
        path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.22))
        path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.52))
        path.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.95),
                      control1: CGPoint(x: w * 0.88, y: h * 0.76),
                      control2: CGPoint(x: w * 0.72, y: h * 0.89))
        path.addCurve(to: CGPoint(x: w * 0.12, y: h * 0.52),
                      control1: CGPoint(x: w * 0.28, y: h * 0.89),
                      control2: CGPoint(x: w * 0.12, y: h * 0.76))
        path.addLine(to: CGPoint(x: w * 0.12, y: h * 0.22))
        path.closeSubpath()
        return path
    }
}

private struct PinMark: View {
    var body: some View {
        SPIcon(kind: .pin)
            .stroke(GZ.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .frame(width: 66, height: 66)
    }
}

private struct CameraMark: View {
    var body: some View {
        VectorIcon.camera
            .stroke(GZ.ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            .frame(width: 66, height: 66)
    }
}
