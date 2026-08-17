import SwiftUI

/// Vollbild-Praesentation der Kartenebene. Eine einzige — zwei `fullScreenCover`
/// an derselben View schliessen einander aus.
enum RootCover: Identifiable, Equatable {
    case camera(context: CameraContext, autoTrigger: Bool)
    case freeViewer(id: UUID)

    var id: String {
        switch self {
        case .camera(let context, _): return "camera-\(context.chipTitle)"
        case .freeViewer(let id): return "free-\(id)"
        }
    }
}

/// Sheet-Ziel inklusive Startzustand. Die Route reist IM Item mit — als
/// separater `@State` daneben las das Praesentations-Closure noch den alten Wert.
struct SheetTarget: Identifiable, Equatable {
    let spot: Spot
    let route: MockRoute

    var id: String { spot.id }
}

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var store = MockStore()
    @State private var selected: SheetTarget?
    @State private var rootCover: RootCover?
    @State private var routed = false

    private var pins: [SpotPinState] {
        store.spots.map { SpotPinState(spot: $0, snaps: store.visibleSnaps($0.id)) }
    }

    private var freePins: [FreeSnapPinState] {
        store.visibleFreeSnaps().map(FreeSnapPinState.init)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MapContainer(
                dark: colorScheme == .dark,
                timeActive: GZTime.banActive(),
                pins: pins,
                freePins: freePins,
                userCoordinate: Fixtures.userCoordinate,
                onSelectSpot: { id in
                    guard let spot = store.spots.first(where: { $0.id == id }) else { return }
                    selected = SheetTarget(spot: spot, route: .map)
                },
                onSelectFreeSnap: { id in
                    rootCover = .freeViewer(id: id)
                }
            )
            .ignoresSafeArea()
            // Sheet haengt an der Karte, das Cover am ZStack: SwiftUI praesentiert
            // pro View nur eines — verschachtelt gehen beide gleichzeitig.
            .sheet(item: $selected) { target in
                SpotSheet(spot: target.spot, store: store, autoRoute: target.route)
            }

            plusFAB
        }
        .fullScreenCover(item: $rootCover) { which in
            switch which {
            case .camera(let context, let autoTrigger):
                SnapCamera(context: context, autoTrigger: autoTrigger) {
                    rootCover = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                        capture(context)
                    }
                }
            case .freeViewer(let id):
                SnapViewer(source: .free(id), startIndex: 0, store: store)
            }
        }
        .onAppear(perform: applyMockRoute)
    }

    /// Snappen geht ueberall: der Plus-Knopf oeffnet die Kamera, der Ort
    /// entscheidet danach ueber Spot-Album oder freien Pin.
    private var plusFAB: some View {
        Button {
            rootCover = .camera(context: store.captureContext(), autoTrigger: false)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(GZ.accent)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(GZ.stroke, lineWidth: 1) }
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 22)
    }

    private func capture(_ context: CameraContext) {
        withAnimation(GZ.spring) {
            switch context {
            case .spot(let spot):
                _ = store.addSnap(spotID: spot.id)
            case .free:
                _ = store.addFreeSnap(at: Fixtures.userCoordinate)
            }
        }
    }

    private func applyMockRoute() {
        guard !routed else { return }
        routed = true
        let route = MockRoute.fromEnvironment()

        // Erst die Karte settlen lassen — sonst zeigt der Screenshot ein Blatt
        // ueber halb geladenen Tiles.
        if route == .freesnap {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                rootCover = .camera(context: store.captureContext(), autoTrigger: true)
            }
            return
        }
        guard let spot = route.sheetSpot else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            selected = SheetTarget(spot: spot, route: route)
        }
    }
}
