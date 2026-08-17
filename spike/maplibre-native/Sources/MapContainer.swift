import SwiftUI
import MapLibre
import CoreLocation

/// v1-FALLBACK_CENTER (Hannover) + Zoom aus `MapView.tsx`.
private let kCenter = CLLocationCoordinate2D(latitude: 52.3728, longitude: 9.7386)
private let kZoom: Double = 14.2

/// Mockup-Kamera: der Start-Ausschnitt muss BEIDE Spot-Pins zeigen, sonst ist das
/// Anfass-Mockup beim Oeffnen leer. Statt eines geratenen Zooms wird auf die
/// Fixture-Punkte eingepasst (unten mehr Rand — dort sitzt das Sheet).
private let kFitPadding = UIEdgeInsets(top: 110, left: 64, bottom: 150, right: 64)

private let kBanColor = UIColor(red: 0xE5 / 255.0, green: 0x48 / 255.0, blue: 0x4D / 255.0, alpha: 1)
private let kTimeColor = UIColor(red: 0xF7 / 255.0, green: 0x6B / 255.0, blue: 0x15 / 255.0, alpha: 1)

struct MapContainer: UIViewRepresentable {
    let dark: Bool
    let timeActive: Bool
    let pins: [SpotPinState]
    let freePins: [FreeSnapPinState]
    let userCoordinate: CLLocationCoordinate2D
    let onSelectSpot: (String) -> Void
    let onSelectFreeSnap: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(dark: dark, timeActive: timeActive)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = URL(string: dark
            ? "https://tiles.openfreemap.org/styles/dark"
            : "https://tiles.openfreemap.org/styles/positron")!

        NSLog("[GZSpike] start dark=\(dark) timeActive=\(timeActive) hour=\(GZTime.currentHour()) pinStyle=\(PinStyle.current.rawValue) style=\(styleURL.absoluteString)")

        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        // ProMotion: ohne .maximum rendert die Karte 60 Hz, Gesten fühlen sich
        // gegen Apple Maps (120 Hz) hakelig an. Braucht zusätzlich den Plist-Key
        // CADisableMinimumFrameDurationOnPhone.
        mapView.preferredFramesPerSecond = .maximum
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = context.coordinator
        mapView.setCenter(kCenter, zoomLevel: kZoom, animated: false)

        context.coordinator.onSelectSpot = onSelectSpot
        context.coordinator.onSelectFreeSnap = onSelectFreeSnap
        context.coordinator.install(pins: pins, freePins: freePins, user: userCoordinate, on: mapView)
        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        context.coordinator.onSelectSpot = onSelectSpot
        context.coordinator.onSelectFreeSnap = onSelectFreeSnap
        // Neuer Snap → Foto-Stack am Spot-Pin und frische freie Pins ziehen nach.
        context.coordinator.refresh(pins: pins, freePins: freePins, on: uiView)
        context.coordinator.fitIfNeeded(on: uiView)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let dark: Bool
        private let timeActive: Bool
        private var probeScheduled = false
        // Strong: der Style hält den ObjC-Wrapper nicht am Leben, eine weak-Ref
        // war beim ersten Lauf zur Sondenzeit bereits nil.
        private var zoneSource: MLNVectorTileSource?

        var onSelectSpot: ((String) -> Void)?
        var onSelectFreeSnap: ((UUID) -> Void)?
        private var pins: [SpotPinState] = []
        private var freePins: [FreeSnapPinState] = []
        private var spotAnnotations: [String: SpotAnnotation] = [:]
        private var freeAnnotations: [UUID: FreeSnapAnnotation] = [:]
        /// Frisch aufgenommene freie Snaps — ihre View ploppt beim Erzeugen auf.
        private var pendingPopIn: Set<UUID> = []
        private var didFit = false
        /// Variante C: aktueller Zoom-Zustand der Pins (true = kollabiert).
        private var collapsed = false
        private var collapseApplied = false

        init(dark: Bool, timeActive: Bool) {
            self.dark = dark
            self.timeActive = timeActive
        }

        // MARK: Spot-Pins

        func install(pins: [SpotPinState], freePins: [FreeSnapPinState],
                     user: CLLocationCoordinate2D, on mapView: MLNMapView) {
            self.pins = pins
            guard spotAnnotations.isEmpty else { return }
            // Puck zuerst: liegt damit unter Pin A, der nur 40 m entfernt sitzt.
            mapView.addAnnotation(PuckAnnotation(coordinate: user))
            for state in pins {
                let annotation = SpotAnnotation(state: state)
                spotAnnotations[state.id] = annotation
                mapView.addAnnotation(annotation)
            }
            syncFreePins(freePins, on: mapView, popIn: false)
            NSLog("[GZSpike] annotations installiert=\(mapView.annotations?.count ?? -1)")
        }

        func refresh(pins: [SpotPinState], freePins: [FreeSnapPinState], on mapView: MLNMapView) {
            self.pins = pins
            for state in pins {
                guard let annotation = spotAnnotations[state.id],
                      let view = mapView.view(for: annotation) as? SpotPinView else { continue }
                view.configure(state)
            }
            syncFreePins(freePins, on: mapView, popIn: true)
        }

        /// Freie Pins kommen und gehen zur Laufzeit (Aufnahme, Loeschen) — daher
        /// Abgleich statt Einmal-Installation.
        private func syncFreePins(_ states: [FreeSnapPinState], on mapView: MLNMapView, popIn: Bool) {
            freePins = states
            let ids = Set(states.map(\.id))

            for (id, annotation) in freeAnnotations where !ids.contains(id) {
                mapView.removeAnnotation(annotation)
                freeAnnotations[id] = nil
            }

            for state in states {
                if let annotation = freeAnnotations[state.id] {
                    (mapView.view(for: annotation) as? FreeSnapPinView)?.configure(state)
                    continue
                }
                let annotation = FreeSnapAnnotation(state: state)
                freeAnnotations[state.id] = annotation
                if popIn { pendingPopIn.insert(state.id) }
                mapView.addAnnotation(annotation)
                NSLog("[GZSpike] freier snap-pin ergaenzt id=\(state.id) popIn=\(popIn)")
            }
        }

        /// Einmalig, sobald die View eine echte Groesse hat: Ausschnitt so, dass
        /// beide Spots drin sind (`makeUIView` laeuft noch mit frame .zero).
        func fitIfNeeded(on mapView: MLNMapView) {
            guard !didFit, mapView.bounds.width > 1, pins.count > 1 else {
                NSLog("[GZSpike] fit uebersprungen didFit=\(didFit) w=\(mapView.bounds.width) pins=\(pins.count)")
                return
            }
            didFit = true
            // Diagnose-Override wie GZ_HOUR: fester Zoom auf die User-Position,
            // um Pin-Details zu pruefen, die im Startbild uebereinander liegen.
            if let raw = ProcessInfo.processInfo.environment["GZ_ZOOM"], let zoom = Double(raw) {
                mapView.setCenter(Fixtures.userCoordinate, zoomLevel: zoom, animated: false)
                NSLog("[GZSpike] GZ_ZOOM=\(zoom) auf User-Position")
                syncPinZoom(on: mapView)
                return
            }
            // Freie Pins zaehlen mit — sonst faellt einer aus dem Startbild.
            let lats = pins.map(\.latitude) + freePins.map(\.latitude)
            let lngs = pins.map(\.longitude) + freePins.map(\.longitude)
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lngs.min()!),
                ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lngs.max()!))
            mapView.setVisibleCoordinateBounds(bounds, edgePadding: kFitPadding, animated: false)
            NSLog("[GZSpike] fit auf \(pins.count) spots, zoom=\(mapView.zoomLevel)")
            syncPinZoom(on: mapView)
        }

        // MARK: Zoom-adaptive Pins (Variante C)

        /// Schmitt-Trigger statt harter Schwelle: einmal kollabiert bleibt der Pin
        /// bis 13,7 klein, einmal entfaltet bis 13,3 gross — dazwischen passiert
        /// nichts, sonst flackert der Uebergang beim Zoomen an der Schwelle.
        func syncPinZoom(on mapView: MLNMapView) {
            guard PinStyle.current == .c else { return }
            let zoom = mapView.zoomLevel
            let threshold = PinStyle.collapseZoom
            let hysteresis = PinStyle.collapseHysteresis
            let want: Bool
            if !collapseApplied {
                want = zoom < threshold
            } else if collapsed {
                want = zoom < threshold + hysteresis
            } else {
                want = zoom < threshold - hysteresis
            }
            guard !collapseApplied || want != collapsed else { return }
            let animated = collapseApplied
            collapsed = want
            collapseApplied = true
            NSLog("[GZSpike] pin-collapse=\(want) zoom=\(String(format: "%.2f", zoom)) animiert=\(animated)")
            for annotation in spotAnnotations.values {
                (mapView.view(for: annotation) as? SpotPinView)?.setCollapsed(want, animated: animated)
            }
            for annotation in freeAnnotations.values {
                (mapView.view(for: annotation) as? FreeSnapPinView)?.setCollapsed(want, animated: animated)
            }
        }

        /// Zustand fuer frisch erzeugte Views — vor dem ersten `syncPinZoom`
        /// entscheidet der aktuelle Zoom direkt.
        private func collapsedNow(_ mapView: MLNMapView) -> Bool {
            guard PinStyle.current == .c else { return false }
            return collapseApplied ? collapsed : mapView.zoomLevel < PinStyle.collapseZoom
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is PuckAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: PuckView.reuseID)
                    ?? PuckView(reuseIdentifier: PuckView.reuseID)
            }
            if let free = annotation as? FreeSnapAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: FreeSnapPinView.reuseID) as? FreeSnapPinView)
                    ?? FreeSnapPinView(reuseIdentifier: FreeSnapPinView.reuseID)
                if let state = freePins.first(where: { $0.id == free.snapID }) {
                    view.configure(state)
                }
                view.setCollapsed(collapsedNow(mapView), animated: false)
                if pendingPopIn.remove(free.snapID) != nil {
                    view.playPopIn()
                }
                return view
            }
            guard let spot = annotation as? SpotAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: SpotPinView.reuseID) as? SpotPinView)
                ?? SpotPinView(reuseIdentifier: SpotPinView.reuseID)
            if let state = pins.first(where: { $0.id == spot.spotID }) {
                view.configure(state)
            }
            view.setCollapsed(collapsedNow(mapView), animated: false)
            return view
        }

        /// Zoom aendert sich beim Pinchen (laufend) und am Gesten-Ende — beide
        /// Wege muessen die Pins nachziehen, sonst haengt der Look eine Geste zurueck.
        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            syncPinZoom(on: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            syncPinZoom(on: mapView)
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            false
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            // Sofort abwaehlen, sonst zuendet der zweite Tap auf denselben Pin nicht.
            mapView.deselectAnnotation(annotation, animated: false)
            if let spot = annotation as? SpotAnnotation {
                // Sheet oeffnet auf .medium (untere Haelfte) — der Pin faehrt in die
                // Mitte der freien oberen Haelfte, sonst verdeckt ihn das Sheet.
                focus(annotation.coordinate, bottomInset: mapView.bounds.height * 0.5, on: mapView)
                onSelectSpot?(spot.spotID)
            } else if let free = annotation as? FreeSnapAnnotation {
                focus(annotation.coordinate, bottomInset: 0, on: mapView)
                onSelectFreeSnap?(free.snapID)
            }
        }

        /// Tap = Karte faehrt zum Pin (Leon 15.08.), Zoom bleibt wie bei Apple Maps.
        /// `edgePadding` ist transient (siehe `cameraEdgeInsets`) — nichts bleibt
        /// als contentInset haengen, Logo/Attribution bleiben wo sie sind.
        private func focus(_ coordinate: CLLocationCoordinate2D, bottomInset: CGFloat, on mapView: MLNMapView) {
            let camera = mapView.camera
            camera.centerCoordinate = coordinate
            mapView.setCamera(camera,
                              withDuration: 0.45,
                              animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
                              edgePadding: UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0),
                              completionHandler: nil)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            NSLog("[GZSpike] style geladen, sources=\(style.sources.count) layers=\(style.layers.count)")

            guard let fileURL = Bundle.main.url(forResource: "zones", withExtension: "pmtiles") else {
                NSLog("[GZSpike] FEHLER zones.pmtiles nicht im Bundle")
                return
            }
            // `configurationURLString:` statt NSURL — der Header nennt genau diesen
            // Initializer für pmtiles-URLs, die NSURL auf iOS 17 falsch parst.
            let configString = "pmtiles://" + fileURL.absoluteString
            NSLog("[GZSpike] configurationURL=\(configString)")

            let source = MLNVectorTileSource(identifier: "zones", configurationURLString: configString)
            style.addSource(source)
            zoneSource = source

            let solidOpacity: Double = dark ? 0.22 : 0.16

            let banFill = MLNFillStyleLayer(identifier: "ban-fill", source: source)
            banFill.sourceLayerIdentifier = "ban"
            banFill.fillColor = NSExpression(forConstantValue: kBanColor)
            banFill.fillOpacity = NSExpression(forConstantValue: solidOpacity)
            style.addLayer(banFill)

            let banLine = MLNLineStyleLayer(identifier: "ban-line", source: source)
            banLine.sourceLayerIdentifier = "ban"
            banLine.lineColor = NSExpression(forConstantValue: kBanColor)
            banLine.lineWidth = NSExpression(forConstantValue: 1.6)
            banLine.lineOpacity = NSExpression(forConstantValue: 0.75)
            style.addLayer(banLine)

            let timeFill = MLNFillStyleLayer(identifier: "time-fill", source: source)
            timeFill.sourceLayerIdentifier = "time"
            timeFill.fillColor = NSExpression(forConstantValue: kTimeColor)
            timeFill.fillOpacity = NSExpression(forConstantValue: timeActive ? solidOpacity : 0.07)
            style.addLayer(timeFill)

            let timeLine = MLNLineStyleLayer(identifier: "time-line", source: source)
            timeLine.sourceLayerIdentifier = "time"
            timeLine.lineColor = NSExpression(forConstantValue: kTimeColor)
            timeLine.lineWidth = NSExpression(forConstantValue: 1.6)
            timeLine.lineDashPattern = NSExpression(forConstantValue: [2.2, 1.6])
            timeLine.lineOpacity = NSExpression(forConstantValue: timeActive ? 0.85 : 0.4)
            style.addLayer(timeLine)

            NSLog("[GZSpike] zonen-layer gesetzt, sources=\(style.sources.count) layers=\(style.layers.count)")
            // Hier hat die View erstmals eine echte Groesse — `updateUIView` laeuft
            // ohne State-Aenderung kein zweites Mal, der Fit haenge also am Style.
            fitIfNeeded(on: mapView)
            scheduleProbe(mapView)
        }

        /// Zusatz-Beweis neben dem Screenshot: kommen aus den pmtiles wirklich Features an?
        private func scheduleProbe(_ mapView: MLNMapView) {
            guard !probeScheduled else { return }
            probeScheduled = true
            for delay in [5.0, 12.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak mapView] in
                    guard let mv = mapView else { return }
                    let ban = mv.visibleFeatures(in: mv.bounds, styleLayerIdentifiers: ["ban-fill"])
                    let time = mv.visibleFeatures(in: mv.bounds, styleLayerIdentifiers: ["time-fill"])
                    // Zweite Sonde direkt an der Source: trennt „Tiles kommen nicht an"
                    // von „Tiles kommen an, Layer rendert nicht".
                    let srcBan = self?.zoneSource?.features(sourceLayerIdentifiers: ["ban"], predicate: nil).count ?? -1
                    let srcTime = self?.zoneSource?.features(sourceLayerIdentifiers: ["time"], predicate: nil).count ?? -1
                    NSLog("[GZSpike] probe t+\(Int(delay))s rendered ban=\(ban.count) time=\(time.count) | source ban=\(srcBan) time=\(srcTime)")
                }
            }
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            NSLog("[GZSpike] FEHLER mapViewDidFailLoadingMap: \(error.localizedDescription)")
        }

        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            NSLog("[GZSpike] mapViewDidFinishLoadingMap")
        }

        func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) {
            if fullyRendered {
                NSLog("[GZSpike] fullyRendered")
            }
        }

        func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
            NSLog("[GZSpike] idle")
            fitIfNeeded(on: mapView)
            syncPinZoom(on: mapView)
        }

        func mapViewRendererDidError(_ mapView: MLNMapView) {
            NSLog("[GZSpike] FEHLER mapViewRendererDidError")
        }
    }
}
