import SwiftUI

// MARK: - Warum nicht `fullScreenCover`
//
// Gemessen am 17.08. mit einer Probe (matchedGeometryEffect, beide Varianten
// dieselbe 4-s-Animation, Screenshot bei 3,4 s): liegt das Ziel in einem
// `fullScreenCover`, steht es sofort in voller Groesse da — der Namespace
// traegt nicht ueber die Praesentationsgrenze. Dieselbe Probe als Ebene in
// derselben Hierarchie zeigt den Zwischenzustand, der Morph laeuft.
//
// Damit ist ein Vollbild, aus dem etwas hervorgehen soll (Album-Kachel →
// Betrachter, Karten-Pin → Betrachter), mit `fullScreenCover` nicht baubar.
// `gzFullLayer` legt es stattdessen als eigene Ebene ueber die App — dieselbe
// Entscheidung und derselbe Grund wie beim Blatt (siehe `BottomSheet.swift`).
//
// Was dabei selbst nachgebaut werden muss, weil es sonst das System mitbringt:
// der Deckel gegen Bedienung darunter (`allowsHitTesting`) und das Ausblenden
// des Inhalts fuer VoiceOver (`accessibilityHidden`).

private struct FullLayer<Cover: View>: ViewModifier {
    let isActive: Bool
    @ViewBuilder let cover: () -> Cover

    func body(content: Content) -> some View {
        ZStack {
            content
                // Ohne das bliebe die Karte unter dem Vollbild bedienbar und
                // fuer VoiceOver sichtbar — beides bringt `fullScreenCover` mit.
                .allowsHitTesting(!isActive)
                .accessibilityHidden(isActive)
            if isActive {
                // KEIN `ignoresSafeArea` hier: die Vollbilder brechen selbst und
                // gezielt aus (Sucher, schwarzer Grund), waehrend ihre Bedienung
                // in der Safe Area bleiben muss. Ein Deckel ueber alles schiebt
                // den Kontext-Chip unter die Dynamic Island und den Ausloeser
                // aus dem Schirm — im Bild gesehen, nicht hergeleitet.
                cover()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        // Der Grund kommt VOR dem Objekt (Choreografie des Prototyps): beim
        // Morph in den Betrachter waechst das Bild sonst ins Helle statt ins
        // fertige Dunkel. Dieselbe Feder wie das wandernde Bild, damit beide
        // eine Bewegung sind und nicht zwei.
        .animation(GZ.elementSpring, value: isActive)
    }
}

extension View {
    /// Vollbild ueber diesem Inhalt, gesteuert von einem Wert. Anders als
    /// `fullScreenCover` bleibt es in derselben View-Hierarchie — nur so kann
    /// ein `matchedGeometryEffect` von hier nach dort tragen.
    ///
    /// Der Inhalt wird nur gebaut, solange ein Wert anliegt; beim Ausblenden
    /// traegt die Ebene den letzten Wert weiter, damit sie nicht mitten in der
    /// Bewegung leer wird (wie `gzSheet(item:)`).
    func gzFullLayer<Item: Identifiable & Equatable, Cover: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Cover
    ) -> some View {
        modifier(FullLayerItem(item: item.wrappedValue, content: content))
    }
}

private struct FullLayerItem<Item: Identifiable & Equatable, Cover: View>: ViewModifier {
    let item: Item?
    @ViewBuilder let content: (Item) -> Cover

    @State private var shown: Item?

    func body(content wrapped: Content) -> some View {
        // Wie beim Blatt: solange ein Wert anliegt, kommt der Inhalt aus IHM.
        // `shown` traegt nur die Ausfahrt. Haengt der Inhalt allein an `shown`,
        // laeuft der Uebergang leer ab — `onChange` setzt den Wert erst nach dem
        // Render, in dem die Ebene aktiv wurde (in `BottomSheet.swift` gemessen).
        // Fuer einen Morph aus der Kachel heraus waere das toedlich: das Ziel
        // gaebe es im ersten Frame noch gar nicht.
        let current = item ?? shown
        return wrapped
            .modifier(FullLayer(isActive: item != nil) {
                if let current {
                    content(current)
                }
            })
            .onChange(of: item) { _, new in
                if let new { shown = new }
            }
    }
}
