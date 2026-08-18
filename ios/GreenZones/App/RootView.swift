import GreenZonesKit
import SwiftUI

/// Was die App ueber allem zeigen kann. Genau eines davon, nie zwei.
enum RootCover: Identifiable, Equatable {
    case onboarding
    case camera(spotId: String?)
    case viewer(source: SnapSource, index: Int, hide: Bool)

    var id: String {
        switch self {
        case .onboarding: return "onboarding"
        case .camera(let spotId): return "camera-\(spotId ?? "free")"
        case .viewer(let source, let index, let hide):
            return "viewer-\(source.key)-\(index)-\(hide)"
        }
    }
}

/// Kartenebene mit Status-Bar, FAB-Gruppe und den Sheets.
struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = AppModel()
    @State private var routed = false
    /// Stand des wandernden Bildes: 0 = in der Kachel, 1 = im Vollbild.
    @State private var morphProgress: Double = 0
    /// Herkunft DIESES Flugs, beim Start festgehalten. Ein Tap auf einen freien
    /// Pin zentriert die Karte — der Pin wandert also, waehrend das Bild
    /// unterwegs ist, und ein laufend nachgelesenes Rechteck zoege den Startpunkt
    /// mit. Fuer den Rueckweg wird neu gelesen: dann liegt der Pin woanders.
    @State private var morphFrom: MorphRect?

    // W3: die Community haengt am AppModel, die Views lesen sie hier heraus.
    private var community: CommunityModel { model.community }

    /// Vollbild-Vorrang: erst die Standort-Frage, dann Kamera/Betrachter.
    private var rootCover: RootCover? {
        if model.shouldShowOnboarding { return .onboarding }
        switch community.cover {
        case .camera(let spotId): return .camera(spotId: spotId)
        case .viewer(let source, let index, let hide):
            return .viewer(source: source, index: index, hide: hide)
        case nil: return nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapContainer(dark: colorScheme == .dark,
                         timeActive: model.timeActive,
                         pins: community.spotPins(user: model.location.state.coordinate),
                         // W5: freie Snaps stehen als eigene Pins auf der Karte.
                         freePins: community.freeSnapPins(),
                         userCoordinate: model.location.state.coordinate,
                         accuracyM: model.location.state.accuracyM,
                         recenterToken: model.recenterToken,
                         // W2: Ziel-Pin + Anflug.
                         target: model.target?.result.coordinate,
                         centerSink: community.mapCenter,
                         pinRectSink: community.mapPinRects,
                         // Sein Bild ist gerade unterwegs — der Pin zeigt sich
                         // erst, wenn es angekommen ist.
                         hiddenSnapId: community.morphInFlight ? community.morphSnapId : nil,
                         popInIsLanding: community.popInIsLanding,
                         popInSnapId: community.popInSnapId,
                         onSelectSpot: { community.sheet = .detail(spotId: $0) },
                         onSelectFreeSnap: { community.openViewer(.free(snapId: $0)) },
                         onPopInPlayed: { _ in community.consumePopIn() })
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

        }
        .animation(GZ.elementSpring, value: community.isPicking)
        .background(GZ.appBg)
        .gzSheet(isPresented: $model.detailOpen) {
            StatusDetailSheet(presentation: model.presentation,
                              // W2: im Ziel-Modus zeigt das Sheet die Zonen am Ziel.
                              status: model.visibleStatus,
                              hour: model.hour) {
                model.detailOpen = false
            }
        }
        .gzSheet(isPresented: $model.infoOpen) {
            InfoSheetView(onClose: { model.infoOpen = false },
                          onClearRecents: { model.search.clearRecents() },
                          offline: model.offlineMap,
                          // Ohne Standort gibt es keinen Mittelpunkt — dann
                          // bietet das Blatt das Sichern gar nicht erst an,
                          // statt einen Knopf zu zeigen, der nichts tut.
                          onDownloadArea: model.location.state.coordinate.map { center in
                              { model.offlineMap.download(around: center) }
                          })
        }
        // W3: genau EIN Community-Sheet (SheetState-Union wie v1).
        .gzSheet(item: Binding(get: { community.presentedSheet },
                               set: { if $0 == nil { community.closeSheet() } }),
                 onDismiss: { community.closeSheet() }) { route in
            communitySheet(route)
        }
        // W3-Toast (2600 ms), EINE Stelle fuer alle Blaetter — und zwar HINTER
        // den `gzSheet`-Modifiern: die sind eigene ZStack-Ebenen ueber der Karte,
        // kein Systemsheet, ein Overlay danach liegt also ueber dem Blatt.
        // Vorher lag er IM Blatt und damit auf dessen Kopf: bei Route `sent`
        // verdeckte er „Einladen" samt Unterzeile.
        // Ort wie v1 (`.sp-toast` / `.sp-toast.top`): bei offenem Blatt oben,
        // sonst unten ueber den FABs. Oben heisst hier direkt unter der Safe
        // Area — beim hoechsten Blatt (0.86 der Hoehe) reicht ein zweizeiliger
        // Toast gemessen bis auf dessen Griff, der Titel darunter bleibt frei.
        .overlay(alignment: sheetOpen ? .top : .bottom) {
            if let toast = community.toast {
                SPToast(text: toast)
                    .padding(sheetOpen ? .top : .bottom, sheetOpen ? 12 : 84)
                    // Unten haelt er die FAB-Spalte frei (Leon-Entscheid): ein
                    // langer Toast lief vorher unter dem Snap-FAB durch. Nach
                    // OBEN auszuweichen hilft nicht — direkt darueber steht der
                    // naechste FAB, und der uebernaechste darueber. Also endet
                    // er davor: 14 pt Rand plus 56 pt FAB plus Luft.
                    .padding(.trailing, sheetOpen ? 0 : 66)
            }
        }
        .animation(GZ.microSpring, value: community.toast)
        // EIN Vollbild fuer alles: Onboarding, Kamera und Betrachter. Das
        // Onboarding hat Vorrang: solange die Standort-Frage steht, gibt es
        // keine Kamera.
        //
        // Als eigene Ebene, nicht als `fullScreenCover`: aus der Album-Kachel
        // und dem Karten-Pin soll der Betrachter HERVORGEHEN, und ueber die
        // Grenze einer Systempraesentation traegt kein `matchedGeometryEffect`
        // (gemessen, Begruendung in `FullLayer.swift`). Nebenbei entfaellt der
        // alte Spike-Befund, dass zwei `fullScreenCover` an derselben View
        // einander ausschliessen.
        .gzFullLayer(item: Binding(get: { rootCover },
                                   set: { if $0 == nil { community.closeCover() } })) { cover in
            switch cover {
            case .onboarding:
                OnboardingView(onAllow: { model.finishOnboarding() },
                               onSkip: { model.finishOnboarding() },
                               locationAlreadyAuthorized: model.locationAlreadyAuthorized)
            case .camera(let spotId):
                SnapCameraView(model: community, spotId: spotId,
                               userCoordinate: model.location.state.coordinate)
            case .viewer(let source, let index, let hide):
                SnapViewerView(model: community, source: source, startIndex: index,
                               autoHide: hide)
            }
        }
        // Das wandernde Bild liegt UEBER dem Vollbild: es soll bis zum letzten
        // Frame sichtbar bleiben, auch wenn der Betrachter darunter schon steht.
        .overlay {
            // Der Flieger entsteht mit der HERKUNFT, nicht mit dem Flug: eine
            // View, die im selben Zug eingefuegt wird, in dem die Feder laeuft,
            // hat keinen Vorzustand — sie stuende sofort am Ziel. Im Bild
            // gesehen (dieselbe Falle wie beim Blatt). Sichtbar ist er nur
            // waehrend des Flugs, danach gehoert das Bild dem Betrachter.
            if let snapId = community.morphSnapId,
               let origin = morphFrom ?? community.snapRect(snapId),
               let image = community.thumbs.image(id: snapId) {
                SnapFlier(image: image,
                          from: origin,
                          to: morphTarget(for: image.size),
                          progress: morphProgress)
                    .opacity(community.morphInFlight ? 1 : 0)
            }
        }
        // Ein Wert steuert beide Richtungen: bei 0 sitzt das Bild in der Kachel,
        // bei 1 im Vollbild. Welche Richtung gemeint ist, sagt der Stand — beim
        // Oeffnen liegt er unten, beim Schliessen oben.
        .onChange(of: community.morphInFlight) { _, flying in
            guard flying, let snapId = community.morphSnapId else { return }
            morphFrom = community.snapRect(snapId)
            let opening = community.morphDirection == .toFullscreen
            // Der Flug aus dem Sucher faengt OBEN an: erst den Stand setzen,
            // damit der Flieger einen Vorzustand hat, und die Feder einen Frame
            // spaeter loslaufen lassen. Ohne die Pause entstuende er mitten in
            // der Animation und staende sofort am Ziel — genau der Fehler, der
            // beim Blatt und beim Betrachter schon zweimal drin war.
            if !opening, morphProgress < 1 {
                morphProgress = 1
                DispatchQueue.main.async {
                    withAnimation(GZ.elementSpring) { morphProgress = 0 }
                        completion: { community.morphReturned() }
                }
                return
            }
            withAnimation(GZ.elementSpring) {
                morphProgress = opening ? 1 : 0
            } completion: {
                if opening { community.morphArrived() } else { community.morphReturned() }
            }
        }
        // Ohne Herkunft gibt es keinen Weg — und der Stand muss unten liegen,
        // sonst liefe der naechste Morph rueckwaerts. Das passiert wirklich:
        // der Wisch nach unten schliesst ohne Rueckweg und laesst 1 stehen.
        .onChange(of: community.morphSnapId) { _, new in
            if new == nil {
                morphProgress = 0
                morphFrom = nil
            }
        }
        // Die Pins der Karte tragen Vorschaubilder: was noch nicht auf der
        // Platte liegt, wird hier nachgezogen. Der Schluessel traegt den PFAD,
        // nicht nur die Id — ein aus der Cloud nachgeladener Thumb aendert die
        // Id-Liste nicht, und der Pin bliebe sonst bis zur naechsten
        // Bestandsaenderung leer.
        .task(id: community.thumbKey) { await community.loadThumbs() }
        .task { model.start() }
        // W5: Der Snap-Weg hat einen eigenen Fehlerkanal (Upload, Nachladen).
        // Ohne diese Bruecke schriebe er still in eine Eigenschaft, die niemand
        // liest — die App saehe aus, als sei alles gut gegangen.
        .onChange(of: community.snapSync.error) { _, message in
            guard let message else { return }
            community.notice(message)
            community.snapSync.clearError()
        }
        .onChange(of: model.location.state) { _, _ in model.locationChanged() }
        .onAppear(perform: applyDebugRoute)
    }

    /// FAB-Gruppe rechts (v1-Reihenfolge: Spot markieren · Freunde · Zentrieren ·
    /// Info), darunter der Snap-FAB aus W5. Er sitzt unten und ist groesser: von
    /// hier aus entsteht etwas, die vier darueber verwalten nur (SPEC 9).
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
            snapFab
                .padding(.top, 4)
        }
    }

    /// W5: Snap-FAB. Blau gefuellt statt Glas — er ist die einzige Handlung
    /// hier, die etwas erschafft.
    ///
    /// Kamera statt Ausloeser-Ring (18.08., Leon am Geraet): der Ring stammt aus
    /// dem Spike-Mockup und sagt „jetzt ausloesen", der Knopf oeffnet aber erst
    /// den Sucher. Gezeichnet als `VectorIcon` wie alle Strich-Symbole der App —
    /// ein SF-Symbol an dieser einen Stelle wuerde als einziges aus der Reihe
    /// tanzen (andere Strichstaerke, andere Rundungen).
    private var snapFab: some View {
        Button(action: { community.openCamera() }) {
            VectorIcon.camera
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .frame(width: 26, height: 26)
                .frame(width: 56, height: 56)
            .background(GZ.accent, in: .circle)
            .shadow(color: GZ.accent.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Snap aufnehmen")
        .accessibilityIdentifier("gz.fab.snap")
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
        return route == .searchResults || route == .searchOffline || route == .searchOffer
            ? DebugEnvironment.fixtureQuery : nil
        #else
        return nil
        #endif
    }

    /// Das obere Ende des Weges. Der Betrachter zeigt das GANZE Bild, der Sucher
    /// einen formatfuellenden Ausschnitt ueber den ganzen Schirm — zwei
    /// verschiedene Flaechen. Mit der falschen spraenge das Foto im ersten Frame.
    private func morphTarget(for size: CGSize) -> MorphRect {
        switch community.morphTop {
        case .viewer:
            return .contain(image: size, in: SPScreen.contentBounds)
        case .viewfinder:
            return MorphRect(rect: SPScreen.bounds, cornerRadius: 0)
        }
    }

    /// Liegt gerade ein Blatt ueber der Karte? Entscheidet, wo der Toast steht.
    private var sheetOpen: Bool {
        community.presentedSheet != nil || model.detailOpen || model.infoOpen
    }

    /// W3: Inhalt des Community-Sheets. Der Toast liegt NICHT hier, sondern als
    /// Overlay ueber der ganzen Blatt-Ebene (siehe `body`).
    @ViewBuilder
    private func communitySheet(_ route: SheetRoute) -> some View {
        Group {
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
        }
    }

    /// `GZ_ROUTE` faehrt beim Start denselben Zustand an, den die Taps setzen —
    /// kein Sonderrendering, nur derselbe State.
    private func applyDebugRoute() {
        #if DEBUG
        guard !routed else { return }
        routed = true
        let route = DebugEnvironment.route
        // W2 liess hier alles ausser `map` durch, W3 nur `statusDetail` und
        // `info` — beim Zusammenlegen fiel `targetDetail` heraus und die Route
        // zeigte still die Karte ohne Sheet.
        guard route == .statusDetail || route == .targetDetail || route == .info else { return }
        // Erst die Karte settlen lassen — sonst zeigt der Screenshot ein Sheet
        // ueber halb geladenen Tiles. `GZ_UI_SETTLE` hebt die Wartezeit fuer
        // Bewegungsbilder an.
        DispatchQueue.main.asyncAfter(deadline: .now() + DebugEnvironment.uiSettle) {
            DebugEnvironment.motionGo()
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
