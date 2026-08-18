import CoreLocation
import GreenZonesKit
import SwiftUI

/// Suchfeld + Ergebnis-Overlay ueber dem `SearchController`.
/// Port von `client/src/components/SearchBar.tsx`, Masse aus `client/src/App.css`
/// (`.search*`), Look aus `client/ui_*.png`.
///
/// Die Sichtbarkeit des Overlays ist EIGENER State und haengt nicht am Fokus des
/// Feldes: in v1 hat der Blur-Timeout den Tap auf eine Zeile gefressen. Hier
/// schliesst nur Scrim, Auswahl oder das X — ein Tap auf eine Zeile kann
/// dazwischen nichts verlieren.
struct SearchBarView: View {
    let controller: SearchController
    /// Gewaehltes Ziel — fuellt das Feld und wird von aussen zurueckgesetzt.
    let selected: SearchResult?
    let userCoordinate: CLLocationCoordinate2D?
    let onSelect: (SearchResult) -> Void
    let onClear: () -> Void
    /// Nur fuer die Screenshot-Routen: Overlay offen starten, Query vorbelegt.
    /// Ohne Fokus — der Beweis-Shot soll die Liste zeigen, nicht die Tastatur.
    var initiallyOpen = false
    var initialQuery: String?

    @State private var text = ""
    @State private var open = false
    @FocusState private var focused: Bool

    /// v1: `max-height: calc(100% - safe-top - 320px)` — die Liste endet ueber
    /// der Tastatur.
    private static let keyboardReserve: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if open {
                    scrim
                }
                VStack(spacing: 8) {
                    field
                    if open {
                        panel(maxHeight: max(120, proxy.size.height - Self.keyboardReserve))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            guard initiallyOpen else { return }
            open = true
            if let initialQuery {
                text = initialQuery
                controller.setQuery(initialQuery)
                #if DEBUG
                // Die Adress-Routen zeigen, was NACH dem Druck steht. Ohne
                // diesen Anstoss faende der Shot nur noch das Angebot vor —
                // die Zustaende `loading`, `results`, `unavailableOffline` und
                // `error` waeren nicht mehr fotografierbar.
                if DebugEnvironment.route.autoSearchesOnline { controller.searchOnline() }
                #endif
            }
        }
        .onChange(of: selected) { _, new in
            // Das Feld zeigt den gewaehlten Ort; endet der Ziel-Modus, ist es leer.
            text = new?.name ?? ""
        }
    }

    // MARK: - Feld

    private var scrim: some View {
        Rectangle()
            .fill(GZ.scrim)
            .ignoresSafeArea()
            .contentShape(.rect)
            .onTapGesture { close() }
    }

    /// Nur das TIPPEN faehrt die Suche an. Ein `onChange(of: text)` wuerde auch
    /// dann feuern, wenn das Feld von aussen gefuellt wird (gewaehltes Ziel) —
    /// und damit Overlay und Query wieder aufmachen, die die Auswahl gerade
    /// geschlossen hat. v1 trennt das genauso: `onChange`-Handler vs. `setText`.
    private var typing: Binding<String> {
        Binding(get: { text },
                set: { value in
                    guard value != text else { return }
                    text = value
                    controller.setQuery(value)
                    open = true
                })
    }

    private var field: some View {
        HStack(spacing: 8) {
            VectorIcon.lens
                .stroke(GZ.ink2, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 16)

            TextField("Ort oder Adresse suchen", text: typing)
                .font(.system(size: 15))
                .foregroundStyle(GZ.ink)
                .tint(GZ.accent)
                .focused($focused)
                .submitLabel(.search)
                // Die Taste trug ihre Lupe schon, tat aber nichts. Jetzt loest
                // sie genau das aus, was der Knopf in der Liste auch tut — wer
                // „Suchen" drueckt, meint die Adresssuche.
                .onSubmit { controller.searchOnline() }
                .autocorrectionDisabled()
                .onChange(of: focused) { _, isFocused in
                    if isFocused { open = true }
                }

            if !text.isEmpty {
                Button(action: clear) {
                    VectorIcon.cross
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                        .frame(width: 9, height: 9)
                        .frame(width: 18, height: 18)
                        .background(GZ.chipFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche zurücksetzen")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .glassCard(cornerRadius: 13, shadowRadius: 8, shadowOpacity: 0.10)
    }

    // MARK: - Overlay

    @ViewBuilder
    private func panel(maxHeight: CGFloat) -> some View {
        let state = controller.state
        if hasContent(state) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if case .error = state.index {
                        indexErrorNote
                    }
                    if case .idle(_, _, let recents) = state, !recents.isEmpty {
                        section("Zuletzt gesucht")
                        ForEach(Array(recents.enumerated()), id: \.offset) { _, result in
                            row(result, icon: AnyView(clockIcon), distance: nil)
                        }
                    }
                    if case .results(_, let index, let offline, let online) = state {
                        if !offline.isEmpty || index == .loading {
                            section("Orte")
                            if offline.isEmpty {
                                note { AnyView(spinner) } text: { "Orte laden…" }
                            } else {
                                ForEach(Array(offline.enumerated()), id: \.offset) { _, result in
                                    row(result, icon: AnyView(placeIcon), distance: distance(to: result))
                                }
                            }
                        }
                        onlineBlocks(online)
                    }
                    if case .empty = state {
                        emptyNote
                    }
                }
                .padding(.vertical, 5)
            }
            .scrollDismissesKeyboard(.interactively)
            // Die Liste ist so hoch wie ihr Inhalt und hoechstens `maxHeight` —
            // ohne `fixedSize` nimmt sich eine ScrollView immer alles, und zwei
            // Recents stuenden in einer halbseitigen leeren Flaeche.
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .glassCard(cornerRadius: 16, shadowRadius: 22, shadowOpacity: 0.18)
        }
    }

    /// Die Online-Sektion macht jeden Zustand ihrer Quelle sichtbar.
    @ViewBuilder
    private func onlineBlocks(_ online: OnlineState) -> some View {
        switch online {
        // `idle` heisst: Query zu kurz fuer die Adresssuche — kein Fehler, keine Sektion.
        case .idle:
            EmptyView()
        // Angebot statt Automatik: die Adresssuche fragt einen fremden Dienst,
        // also fragt sie vorher hier nach. Der Knopf sagt, wohin es geht — „im
        // Internet suchen" waere eine Auskunft ueber die Technik, nicht ueber
        // den Empfaenger.
        case .offerable:
            section("Adressen & Straßen")
            Button {
                GZ.haptic()
                controller.searchOnline()
            } label: {
                HStack(spacing: 10) {
                    addressIcon
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Nach Adressen suchen")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(GZ.accent)
                        Text("Fragt Komoot — nur mit diesem Wort")
                            .font(.system(size: 11.5))
                            .foregroundStyle(GZ.ink3)
                    }
                    Spacer(minLength: 0)
                    // Ohne Pfeil sieht die Zeile aus wie die Ortstreffer
                    // darueber und liest sich als Hinweis statt als Handlung.
                    VectorIcon.chevronRight
                        .stroke(GZ.ink3, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 7, height: 12)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("gz.search.online")
        case .loading:
            section("Adressen & Straßen")
            note { AnyView(spinner) } text: { "Adressen laden…" }
        case .unavailableOffline:
            section("Adressen & Straßen")
            note { AnyView(noNetIcon) } text: { "Kein Internet — Ortssuche funktioniert trotzdem" }
        case .error(let reason):
            section("Adressen & Straßen")
            note { AnyView(noNetIcon) } text: {
                reason == .timeout
                    ? "Adressen antworten nicht — Ortssuche funktioniert trotzdem"
                    : "Adressen gerade gestört — Ortssuche funktioniert trotzdem"
            }
        case .results(let results):
            if !results.isEmpty {
                section("Adressen & Straßen")
                ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                    row(result, icon: AnyView(addressIcon), distance: nil)
                }
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.74)
            .foregroundStyle(GZ.ink2)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ result: SearchResult, icon: AnyView, distance: String?) -> some View {
        Button {
            pick(result)
        } label: {
            HStack(spacing: 12) {
                icon
                    .frame(width: 15, height: 15)
                    .frame(width: 30, height: 30)
                    .background(GZ.divider, in: .rect(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(result.name)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.14)
                        .foregroundStyle(GZ.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !result.detail.isEmpty {
                        Text(result.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(GZ.ink2)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let distance {
                    Text(distance)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(GZ.ink2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(SearchRowButtonStyle())
    }

    private func note(icon: () -> AnyView, text: () -> String) -> some View {
        HStack(spacing: 10) {
            icon()
                .frame(width: 15, height: 15)
            Text(text())
                .font(.system(size: 12.5))
                .foregroundStyle(GZ.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var indexErrorNote: some View {
        HStack(spacing: 10) {
            VectorIcon.warning
                .stroke(GZ.ink2, style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
                .frame(width: 15, height: 15)
            Text("Ortsverzeichnis nicht geladen")
                .font(.system(size: 12.5))
                .foregroundStyle(GZ.ink2)
            Spacer(minLength: 0)
            Button("Erneut versuchen") { controller.reloadIndex() }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(GZ.accent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var emptyNote: some View {
        VStack(spacing: 3) {
            Text("Nichts gefunden")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GZ.ink)
            Text("Prüfe die Schreibweise oder such nach\n„Straße Stadt“, z. B. „Limmerstraße Hannover“")
                .font(.system(size: 12.5))
                .foregroundStyle(GZ.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 24)
    }

    // MARK: - Bausteine

    private var placeIcon: some View {
        PlacePinIcon()
            .stroke(GZ.ink2, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
    }

    private var addressIcon: some View {
        VectorIcon.address
            .stroke(GZ.ink2, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
    }

    private var clockIcon: some View {
        VectorIcon.clock
            .stroke(GZ.ink2, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
    }

    private var noNetIcon: some View {
        NoNetIcon()
            .stroke(GZ.ink2, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
    }

    private var spinner: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .tint(GZ.ink2)
    }

    // MARK: - Logik

    private func hasContent(_ state: SearchState) -> Bool {
        if case .error = state.index { return true }
        switch state {
        case .idle(_, _, let recents):
            return !recents.isEmpty
        case .empty:
            return true
        case .results(_, let index, let offline, let online):
            if !offline.isEmpty || index == .loading { return true }
            switch online {
            case .idle: return false
            case .results(let list): return !list.isEmpty
            default: return true
            }
        }
    }

    private func distance(to result: SearchResult) -> String? {
        guard let userCoordinate else { return nil }
        return Geo.formatDistanceM(Geo.distanceM(userCoordinate, result.coordinate))
    }

    private func pick(_ result: SearchResult) {
        GZ.haptic()
        controller.selectResult(result)
        text = result.name
        close()
        onSelect(result)
    }

    private func clear() {
        GZ.haptic()
        controller.clear()
        text = ""
        close()
        onClear()
    }

    private func close() {
        open = false
        focused = false
    }
}

/// Zeilen-Highlight wie `.search-row:active` in v1.
private struct SearchRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? GZ.divider : Color.clear)
    }
}
