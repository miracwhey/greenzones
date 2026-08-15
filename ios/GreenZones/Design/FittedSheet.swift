import SwiftUI
import UIKit

/// Sheet-Hoehe = Inhaltshoehe.
///
/// Ein fester Rasterwert stimmt nur fuer einen Zeilenumbruch: „Schule, Kita,
/// Spielplatz o. Sportstätte · 100 m · ganztägig" bricht je nach Geraetebreite
/// ein- oder zweizeilig um, und die Zonenliste hat null bis zwei Zeilen. Der
/// Inhalt wird deshalb gemessen, nicht geschaetzt — `estimate` ist nur der
/// Startwert fuer den ersten Frame.
private struct SheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FittedSheetDetent: ViewModifier {
    let estimate: CGFloat
    @State private var contentHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height)
                }
            }
            .onPreferenceChange(SheetHeightKey.self) { height in
                guard height > 0 else { return }
                contentHeight = height
            }
            // `.height` meint die GESAMTE Sheet-Hoehe inklusive Home-Indikator.
            .presentationDetents([.height((contentHeight ?? estimate) + SafeArea.bottomInset)])
    }
}

extension View {
    func fittedSheetDetent(estimate: CGFloat) -> some View {
        modifier(FittedSheetDetent(estimate: estimate))
    }
}

@MainActor
enum SafeArea {
    /// Home-Indikator-Rand des aktiven Fensters.
    static var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }
}
