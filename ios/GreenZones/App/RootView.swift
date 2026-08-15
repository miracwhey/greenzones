import GreenZonesKit
import SwiftUI

/// Kartenebene mit Status-Bar, FAB-Gruppe und den Sheets.
struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = AppModel()
    @State private var routed = false

    // W3: die Community haengt am AppModel, die Views lesen sie hier heraus.
    private var community: CommunityModel { model.community }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapContainer(dark: colorScheme == .dark,
                         timeActive: model.timeActive,
                         pins: community.spotPins(user: model.location.state.coordinate),
                         freePins: [],
                         userCoordinate: model.location.state.coordinate,
                         accuracyM: model.location.state.accuracyM,
                         recenterToken: model.recenterToken,
                         // W2: Ziel-Pin + Anflug.
                         target: model.target?.result.coordinate,
                         centerSink: community.mapCenter,
                         onSelectSpot: { community.sheet = .detail(spotId: $0) })
                .ignoresSafeArea()

            // W3: Fadenkreuz des Pick-Modus liegt ueber der Karte, nicht darin —
            // es ist Bedienung, kein Kartenobjekt.
            if community.isPicking {
                PickCrosshair()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !community.isPicking {
                fabs
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 14)
                    .padding(.bottom, 80)
            }

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
            // der Scrim muss alles darunter abdecken (v1 z-index 12/13). Im
            // Pick-Modus raeumt sie das Feld wie die FABs: waehrend man den Punkt
            // setzt, ist die Karte das Werkzeug, nicht die Suche.
            if !community.isPicking {
                SearchBarView(controller: model.search,
                              selected: model.target?.result,
                              userCoordinate: model.location.state.coordinate,
                              onSelect: { model.selectTarget($0) },
                              onClear: { model.clearTarget() },
                              initiallyOpen: debugSearchOpen,
                              initialQuery: debugSearchQuery)
            }

            // W3: die Bestaetigungsleiste liegt UEBER der Status-Bar — deren
            // Platz geben im Pick-Modus die FABs frei, der Legal-Status bleibt
            // sichtbar (v1).
            if community.isPicking {
                PickOverlay(model: community)
            }

            // W3: Toast (2600 ms). Bei offenem Sheet liegt er im Sheet selbst —
            // hier waere er dahinter und damit unsichtbar.
            if let toast = community.toast, community.presentedSheet == nil {
                SPToast(text: toast)
                    .padding(.bottom, 84)
            }
        }
        .animation(GZ.spring, value: community.toast)
        .animation(GZ.spring, value: community.isPicking)
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
        // W3: genau EIN Community-Sheet (SheetState-Union wie v1).
        .sheet(item: Binding(get: { community.presentedSheet },
                             set: { if $0 == nil { community.closeSheet() } })) { route in
            communitySheet(route)
        }
        .fullScreenCover(isPresented: .constant(model.shouldShowOnboarding)) {
            OnboardingView(onAllow: { model.finishOnboarding() },
                           onSkip: { model.finishOnboarding() })
        }
        .task { model.start() }
        .onChange(of: model.location.state) { _, _ in model.locationChanged() }
        .onAppear(perform: applyDebugRoute)
    }

    /// FAB-Gruppe rechts (v1-Reihenfolge: Spot markieren · Freunde · Zentrieren ·
    /// Info). Der Plus-FAB fuer Snaps kommt mit W5 — kein Platzhalter, der nichts tut.
    private var fabs: some View {
        VStack(spacing: 10) {
            // W3
            fab(icon: SPIcon(kind: .spotAdd), tint: GZ.accent, label: "Spot markieren") {
                GZ.haptic()
                community.openNewSpot()
            }
            fab(icon: SPIcon(kind: .friends), tint: GZ.ink, label: "Freunde") {
                GZ.haptic()
                community.sheet = .friends(intent: nil)
            }
            fab(icon: VectorIcon.locate, tint: GZ.ink, label: "Auf meinen Standort zentrieren") {
                model.recenter()
            }
            fab(icon: VectorIcon.info, tint: GZ.ink, label: "Info und Datenquellen") {
                GZ.haptic()
                model.infoOpen = true
            }
        }
    }

    private func fab<S: Shape>(icon: S, tint: Color, label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon
                .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
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

    /// W3: Inhalt des Community-Sheets. Der Toast liegt hier mit drin — ein
    /// gescheiterter Cloud-Write meldet sich ueber dem offenen Sheet.
    @ViewBuilder
    private func communitySheet(_ route: SheetRoute) -> some View {
        ZStack(alignment: .top) {
            switch route {
            case .newspot, .pick:
                NewSpotSheet(model: community,
                             userCoordinate: model.location.state.coordinate,
                             hour: model.hour)
            case .detail(let spotId):
                if let spot = community.spot(id: spotId) {
                    SpotDetailSheet(model: community, spot: spot,
                                    userCoordinate: model.location.state.coordinate,
                                    hour: model.hour)
                }
            case .invite(let spotId):
                if let spot = community.spot(id: spotId) {
                    InviteSheet(model: community, spot: spot,
                                userCoordinate: model.location.state.coordinate,
                                hour: model.hour)
                }
            case .friends(let intent):
                FriendsSheet(model: community, initialIntent: intent)
            case .profilePrompt:
                ProfilePromptSheet(model: community)
            }

            if let toast = community.toast {
                SPToast(text: toast)
                    .padding(.top, 14)
            }
        }
        .animation(GZ.spring, value: community.toast)
    }

    /// `GZ_ROUTE` faehrt beim Start denselben Zustand an, den die Taps setzen —
    /// kein Sonderrendering, nur derselbe State.
    private func applyDebugRoute() {
        #if DEBUG
        guard !routed else { return }
        routed = true
        let route = DebugEnvironment.route
        guard route == .statusDetail || route == .info else { return }
        // Erst die Karte settlen lassen — sonst zeigt der Screenshot ein Sheet
        // ueber halb geladenen Tiles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            switch route {
            case .statusDetail, .targetDetail: model.detailOpen = true
            case .info: model.infoOpen = true
            // Alles andere steht schon, wenn dieser Block laeuft: die Suche
            // oeffnet ihr Overlay selbst, das Ziel setzt `AppModel.start()`, die
            // Community-Routen setzt `CommunityFixtures.seed`. Der Guard oben
            // laesst ohnehin nur `statusDetail` und `info` hier durch.
            default: break
            }
        }
        #endif
    }
}
