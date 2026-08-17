import SwiftUI
import UIKit

// MARK: - Warum nicht `.sheet`
//
// iOS 26 zeichnet jedes Systemsheet mit Teil-Hoehe schwebend: seitlich
// eingerueckt, rundum abgerundet, der Hintergrund scheint unter den Ecken durch.
// Nur ein Sheet ueber die volle Hoehe bleibt an den Kanten — dann aber nimmt
// UIKit die darunterliegende Ansicht aus der Hierarchie, und statt der Karte
// steht grauer Fensterhintergrund hinter dem Blatt. Beides ist nicht
// abschaltbar.
//
// Das Blatt liegt deshalb als eigene Ebene ueber der Karte: `gzSheet` bringt
// Verdunkelung, Einfahrt und Schliessen mit, `bottomSheetCard` formt den Inhalt
// zum kantenbuendigen Blatt. Was dabei vom System nachgebaut ist: Griff,
// Wischen nach unten, Tippen daneben und die Hoehe (gemessener Inhalt).

// MARK: - Praesentation

private struct SheetDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Schliessen-Aktion des umgebenden `gzSheet` — der Griff und die
    /// Verdunkelung rufen sie, der Inhalt kann sie mitbenutzen.
    var gzSheetDismiss: () -> Void {
        get { self[SheetDismissKey.self] }
        set { self[SheetDismissKey.self] = newValue }
    }
}

private struct SheetLayer<Sheet: View>: ViewModifier {
    let isActive: Bool
    let dismiss: () -> Void
    @ViewBuilder let sheet: () -> Sheet

    func body(content: Content) -> some View {
        ZStack {
            content
            if isActive {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .transition(.opacity)
                sheet()
                    .environment(\.gzSheetDismiss, dismiss)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    // `.container`, NICHT `.all`: das Blatt reicht bis unter den
                    // Home-Indikator, die Tastatur hebt es aber an.
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(GZ.sheetSpring, value: isActive)
    }
}

extension View {
    /// Blatt ueber diesem Inhalt, gesteuert von einem Schalter.
    func gzSheet<Sheet: View>(isPresented: Binding<Bool>,
                              @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(SheetLayer(isActive: isPresented.wrappedValue,
                            dismiss: { isPresented.wrappedValue = false },
                            sheet: content))
    }

    /// Blatt ueber diesem Inhalt, gesteuert von einem Wert. Der Inhalt wird nur
    /// gebaut, solange einer anliegt; beim Ausfahren zeigt das Blatt den letzten
    /// Wert weiter, damit es nicht mitten in der Bewegung leer wird.
    func gzSheet<Item: Identifiable & Equatable, Sheet: View>(
        item: Binding<Item?>,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        modifier(ItemSheetLayer(item: item.wrappedValue, dismiss: onDismiss, content: content))
    }
}

private struct ItemSheetLayer<Item: Identifiable & Equatable, Sheet: View>: ViewModifier {
    let item: Item?
    let dismiss: () -> Void
    @ViewBuilder let content: (Item) -> Sheet

    /// Letzter anliegender Wert — traegt das Blatt durch die Ausfahrt.
    @State private var shown: Item?

    func body(content wrapped: Content) -> some View {
        // Solange ein Wert anliegt, kommt der Inhalt aus IHM, nicht aus `shown`.
        //
        // Vorher hing er allein an `shown`, und das setzt `onChange` erst NACH
        // dem Render, in dem `isActive` true wurde: die Einfahrt lief mit einem
        // leeren Blatt (ohne Inhalt hat es keine Hoehe, also sieht man nichts),
        // und wenn der Inhalt kam, stand das Blatt schon oben. Es fuhr nicht
        // ein, es erschien. Gemessen bei 30-facher Zeitlupe — nach 60 ms stand
        // es voll da, waehrend das `isPresented`-Blatt zur selben Zeit noch
        // unter der Kante war.
        let current = item ?? shown
        return wrapped
            .modifier(SheetLayer(isActive: item != nil, dismiss: dismiss) {
                if let current {
                    content(current)
                }
            })
            .onChange(of: item) { _, new in
                if let new { shown = new }
            }
    }
}

// MARK: - Das Blatt

private struct BottomSheetCard: ViewModifier {
    /// Startwert fuer den ersten Frame, bis der Inhalt gemessen ist.
    let estimate: CGFloat
    /// Anteil der Bildschirmhoehe, den das Blatt hoechstens einnimmt.
    var maxHeightFraction: CGFloat = 0.86

    @Environment(\.gzSheetDismiss) private var dismiss
    @State private var measured: CGFloat?
    @GestureState private var drag: CGFloat = 0

    private static let grabberHeight: CGFloat = 18
    private static let cornerRadius: CGFloat = 22
    /// Ab hier ist die Wischgeste ein Schliessen, darunter faehrt das Blatt zurueck.
    private static let dismissThreshold: CGFloat = 90
    /// Luft zwischen letzter Zeile und Home-Indikator.
    private static let bottomBreathingRoom: CGFloat = 8
    static let identifier = "gz.sheet"

    private var cardHeight: CGFloat {
        let cap = SPScreen.height * maxHeightFraction
        let content = (measured ?? estimate) + Self.grabberHeight + Self.bottomBreathingRoom
        return min(content, cap) + SPScreen.bottomInset
    }

    func body(content: Content) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                grabber
                content
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeight.self, value: proxy.size.height)
                        }
                    }
            }
            // Der Home-Indikator-Rand gehoert zum Blatt, nicht zum Inhalt: die
            // letzte Zeile soll nicht auf dem Balken sitzen.
            .padding(.bottom, SPScreen.bottomInset + Self.bottomBreathingRoom)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ContentHeight.self) { height in
            guard height > 0 else { return }
            measured = height
        }
        .frame(height: cardHeight)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(.rect(topLeadingRadius: Self.cornerRadius,
                         topTrailingRadius: Self.cornerRadius,
                         style: .continuous))
        .offset(y: max(0, drag))
        // Der Bedienungstest misst an diesem Element, dass das Blatt an den
        // Kanten sitzt und auf Tippen und Wischen verschwindet.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
    }

    /// Griff und Wischflaeche. Die Geste haengt NUR hier: auf dem Inhalt wuerde
    /// sie mit dem Scrollen streiten und laengere Blaetter unbedienbar machen.
    private var grabber: some View {
        Capsule()
            .fill(GZ.ink.opacity(0.18))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: Self.grabberHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation.height }
                    .onEnded { value in
                        if value.translation.height > Self.dismissThreshold { dismiss() }
                    }
            )
            .accessibilityHidden(true)
    }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Formt diesen Inhalt zum kantenbuendigen Blatt: Griff, gemessene Hoehe,
    /// Deckel bei 86 % der Bildschirmhoehe, Ecken nur oben.
    func bottomSheetCard(estimate: CGFloat, maxHeightFraction: CGFloat = 0.86) -> some View {
        modifier(BottomSheetCard(estimate: estimate, maxHeightFraction: maxHeightFraction))
    }
}
