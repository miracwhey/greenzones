import SwiftUI

/// Info-Sheet. Texte woertlich aus `client/src/components/InfoSheet.tsx`
/// inklusive der ODbL-Attribution — die ist eine Lizenzpflicht, keine Deko.
///
/// Der Abschnitt „Deine Daten" steht auf `docs/datenlandkarte.md` und sagt
/// dasselbe wie die Store-Angaben. Bis zum 18.08. hiess der einzige
/// Daten-Abschnitt „DATEN" und handelte von Kartenlizenzen — wer wissen wollte,
/// wohin seine Spots und Fotos gehen, fand hier die Antwort auf eine andere
/// Frage.
struct InfoSheetView: View {
    let onClose: () -> Void
    /// „Zuletzt gesucht" leeren. Der Verlauf lag seit W2 in der Datenbank, ohne
    /// dass ihn irgendein Weg in der App wieder losgeworden waere.
    var onClearRecents: (() -> Void)?
    /// Kartenbild fuer die Umgebung sichern. Ohne Standort gibt es keinen
    /// Mittelpunkt und damit kein Gebiet — dann bleibt der Abschnitt weg.
    var offline: OfflineMapStore?
    var onDownloadArea: (() -> Void)?

    @State private var recentsCleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Über GreenZones")
                .font(.system(size: 19, weight: .bold))
                .tracking(-0.19)
                .foregroundStyle(GZ.ink)
                .padding(.top, 4)
                .padding(.bottom, 14)

            section("RECHTSGRUNDLAGE") {
                Text("§5 Abs. 2 KCanG: Öffentlicher Konsum ist verboten in Sichtweite (100 m vom Eingangsbereich) von Schulen, Kinderspielplätzen, Kinder- und Jugendeinrichtungen sowie öffentlich zugänglichen Sportstätten — und in Fußgängerzonen zwischen 7 und 20 Uhr.")
            }
            section("DEINE DATEN") {
                Text("GreenZones hat keinen Server. Spots, Freunde, Termine und Snaps liegen auf deinem Gerät und in deiner iCloud — außer den Freunden, denen du sie gibst, kommt niemand daran.\n\nDein Standort wird nur geteilt, wenn du selbst einen Spot oder Snap anlegst; im Bild steht er nie. Das Kartenbild lädt von OpenFreeMap, Adressen sucht Komoot — und nur, wenn du es verlangst.")
            }
            clearRecentsRow
            offlineSection
            section("KEIN RECHTSRAT") {
                Text("Diese App ist eine Orientierungshilfe ohne Gewähr auf Richtigkeit oder Vollständigkeit. OpenStreetMap kennt nicht jede Einrichtung. Verantwortung bleibt bei dir.")
            }
            section("KARTE & LIZENZ") {
                dataParagraph
            }

            Button(action: onClose) {
                Text("Schließen")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GZ.appBg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(GZ.ink, in: .rect(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 12)
        // Groesser als vorher: „Deine Daten" ist dazugekommen. Der Wert ist die
        // Schaetzung fuer die Einfahrt, der Deckel begrenzt sie ohnehin.
        .bottomSheetCard(estimate: 700)
    }

    /// Der einzige Bestand, den man hier wirklich loswerden kann. Alles andere
    /// haengt an seinem Gegenstand (Snap loeschen, Spot entfernen, Freund
    /// entfernen) — ein zweiter Weg dorthin waere eine zweite Wahrheit.
    @ViewBuilder
    private var clearRecentsRow: some View {
        if let onClearRecents {
            Button {
                GZ.haptic()
                onClearRecents()
                withAnimation(GZ.microSpring) { recentsCleared = true }
            } label: {
                Text(recentsCleared ? "Suchverlauf gelöscht" : "Zuletzt gesucht löschen")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(recentsCleared ? GZ.ink3 : GZ.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(recentsCleared)
            .accessibilityIdentifier("gz.info.clearRecents")
            .padding(.bottom, 14)
        }
    }

    /// Kartenbild ohne Netz.
    ///
    /// Die Zonen liegen im Bundle und stehen ohne Empfang — das Kartenbild
    /// darunter kommt aus dem Netz. Wer unterwegs ohne Verbindung ist, sieht
    /// sonst farbige Flaechen auf grauem Grund. Hier laesst sich die Umgebung
    /// vorher sichern.
    @ViewBuilder
    private var offlineSection: some View {
        if let offline, let onDownloadArea {
            VStack(alignment: .leading, spacing: 4) {
                Text("KARTE OFFLINE")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.72)
                    .foregroundStyle(GZ.ink2)

                switch offline.state {
                case .none:
                    Text("Zonen und Ortssuche laufen immer ohne Netz — nur das Kartenbild lädt nach.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(GZ.ink)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onDownloadArea) {
                        Text("Umgebung sichern (20 km, ca. 70 MB)")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(GZ.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityIdentifier("gz.info.offlineDownload")

                case .downloading(let fraction, let bytes):
                    // Prozent UND Menge: der Anteil springt, weil die erwartete
                    // Zahl waehrend des Laufs noch steigt — die Megabyte
                    // wachsen dagegen stetig und zeigen, dass es laeuft.
                    ProgressView(value: fraction)
                        .tint(GZ.accent)
                        .padding(.top, 4)
                    Text("Lädt … \(Int(fraction * 100)) % · \(Self.megabytes(bytes))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(GZ.ink2)

                case .ready(let bytes):
                    Text("Umgebung gesichert · \(Self.megabytes(bytes)). Die Karte steht jetzt auch ohne Netz.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(GZ.ink)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { offline.removeAll() } label: {
                        Text("Gesicherte Karte löschen")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(GZ.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)

                case .failed(let message):
                    Text("Sichern fehlgeschlagen: \(message)")
                        .font(.system(size: 13.5))
                        .foregroundStyle(GZ.ban)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onDownloadArea) {
                        Text("Erneut versuchen")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(GZ.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 14)
        }
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb < 10 ? String(format: "%.1f MB", mb) : String(format: "%.0f MB", mb)
    }

    /// Die Quellen-Links sind Teil des Lizenztexts — als echte Links, nicht als
    /// blau gefaerbtes Wort ohne Ziel.
    private var dataParagraph: Text {
        Text("Zonen berechnet aus © ")
            + Text(.init("[OpenStreetMap](https://www.openstreetmap.org/copyright)"))
            + Text("-Daten (ODbL). Karte: ")
            + Text(.init("[OpenFreeMap](https://openfreemap.org)"))
            + Text(" · ")
            + Text(.init("[© OpenMapTiles](https://openmaptiles.org)"))
            + Text(". Die Zonen werden als 100-m-Umkreis um die gesamte Fläche der Schutzobjekte berechnet — im Zweifel großzügiger als das Gesetz.")
    }

    private func section(_ title: String, @ViewBuilder content: () -> Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.72)
                .foregroundStyle(GZ.ink2)
            content()
                .font(.system(size: 13.5))
                .foregroundStyle(GZ.ink)
                .lineSpacing(3)
                .tint(GZ.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 14)
    }
}
