import SwiftUI

/// Info-Sheet. Texte woertlich aus `client/src/components/InfoSheet.tsx`
/// inklusive der ODbL-Attribution — die ist eine Lizenzpflicht, keine Deko.
struct InfoSheetView: View {
    let onClose: () -> Void

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
            section("DATEN") {
                dataParagraph
            }
            section("KEIN RECHTSRAT") {
                Text("Diese App ist eine Orientierungshilfe ohne Gewähr auf Richtigkeit oder Vollständigkeit. OpenStreetMap kennt nicht jede Einrichtung. Verantwortung bleibt bei dir.")
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
        .bottomSheetCard(estimate: 460)
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
