import GreenZonesKit
import SwiftUI

/// Kartenebene mit Status-Bar, FAB-Gruppe und den beiden Sheets von W1.
struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = AppModel()
    @State private var routed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            MapContainer(dark: colorScheme == .dark,
                         timeActive: model.timeActive,
                         pins: [],
                         freePins: [],
                         userCoordinate: model.location.state.coordinate,
                         accuracyM: model.location.state.accuracyM,
                         recenterToken: model.recenterToken,
                         // W2: Ziel-Pin + Anflug.
                         target: model.target?.result.coordinate)
                .ignoresSafeArea()

            fabs
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 14)
                .padding(.bottom, 80)

            VStack(spacing: 10) {
                if model.location.state == .denied {
                    Text("Standort nicht freigegeben — Status zeigt nichts an. In den iOS-Einstellungen aktivieren.")
                        .font(.system(size: 13))
                        .foregroundStyle(GZ.ink2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 12, shadowRadius: 8, shadowOpacity: 0.10)
                        .padding(.horizontal, 14)
                }
                StatusBarView(presentation: model.presentation,
                              onTap: {
                                  GZ.haptic()
                                  model.detailOpen = true
                              },
                              // W2: X nur im Ziel-Modus.
                              onClearTarget: model.target == nil ? nil : {
                                  GZ.haptic()
                                  model.clearTarget()
                              })
            }

            // W2: Suchfeld + Overlay liegen ueber Karte, FABs und Status-Bar —
            // der Scrim muss alles darunter abdecken (v1 z-index 12/13).
            SearchBarView(controller: model.search,
                          selected: model.target?.result,
                          userCoordinate: model.location.state.coordinate,
                          onSelect: { model.selectTarget($0) },
                          onClear: { model.clearTarget() },
                          initiallyOpen: debugSearchOpen,
                          initialQuery: debugSearchQuery)
        }
        .background(GZ.appBg)
        .sheet(isPresented: $model.detailOpen) {
            StatusDetailSheet(presentation: model.presentation,
                              // W2: im Ziel-Modus zeigt das Sheet die Zonen am Ziel.
                              status: model.visibleStatus,
                              hour: model.hour) {
                model.detailOpen = false
            }
        }
        .sheet(isPresented: $model.infoOpen) {
            InfoSheetView { model.infoOpen = false }
        }
        .fullScreenCover(isPresented: .constant(model.shouldShowOnboarding)) {
            OnboardingView(onAllow: { model.finishOnboarding() },
                           onSkip: { model.finishOnboarding() })
        }
        .task { model.start() }
        .onChange(of: model.location.state) { _, _ in model.locationChanged() }
        .onAppear(perform: applyDebugRoute)
    }

    /// FAB-Gruppe rechts. W1 hat Zentrieren und Info; „Spot markieren", „Freunde"
    /// und der Plus-FAB kommen mit W3/W5 — kein Platzhalter, der nichts tut.
    private var fabs: some View {
        VStack(spacing: 10) {
            fab(icon: .locate, label: "Auf meinen Standort zentrieren") {
                model.recenter()
            }
            fab(icon: .info, label: "Info und Datenquellen") {
                GZ.haptic()
                model.infoOpen = true
            }
        }
    }

    private func fab(icon: VectorIcon, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon
                .stroke(GZ.ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 20)
                .frame(width: 44, height: 44)
                .glassCard(cornerRadius: 14, material: .ultraThinMaterial,
                           shadowRadius: 8, shadowOpacity: 0.10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// W2: Overlay-Zustand der Suchrouten. Ausserhalb von DEBUG immer aus.
    private var debugSearchOpen: Bool {
        #if DEBUG
        return DebugEnvironment.route.opensSearch
        #else
        return false
        #endif
    }

    private var debugSearchQuery: String? {
        #if DEBUG
        let route = DebugEnvironment.route
        return route == .searchResults || route == .searchOffline
            ? DebugEnvironment.fixtureQuery : nil
        #else
        return nil
        #endif
    }

    /// `GZ_ROUTE` faehrt beim Start denselben Zustand an, den die Taps setzen —
    /// kein Sonderrendering, nur derselbe State.
    private func applyDebugRoute() {
        #if DEBUG
        guard !routed else { return }
        routed = true
        let route = DebugEnvironment.route
        guard route != .map else { return }
        // Erst die Karte settlen lassen — sonst zeigt der Screenshot ein Sheet
        // ueber halb geladenen Tiles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            switch route {
            case .statusDetail, .targetDetail: model.detailOpen = true
            case .info: model.infoOpen = true
            // Suche und Ziel-Modus stehen schon: die Suche oeffnet ihr Overlay
            // selbst, das Ziel setzt `AppModel.start()`.
            case .map, .search, .searchResults, .searchOffline, .target: break
            }
        }
        #endif
    }
}
