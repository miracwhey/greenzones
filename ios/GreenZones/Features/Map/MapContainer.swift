import CoreLocation
import MapLibre
import SwiftUI
import os

/// v1-FALLBACK_CENTER (Hannover) + Zoom aus `MapView.tsx`.
private let kFallbackCenter = CLLocationCoordinate2D(latitude: 52.3728, longitude: 9.7386)
private let kInitialZoom: Double = 14.2
/// „Auf Standort zentrieren" und Suchtreffer fahren auf Zoom 15 (v1).
private let kFocusZoom: Double = 15

/// Vollbild-Karte: Basemap + Zonen-Layer + Pins + Puck.
///
/// Uebernommen aus `spike/maplibre-native/Sources/MapContainer.swift` mit den
/// Pflicht-Fixes aus SPEC 5: Hell/Dunkel-Wechsel zur Laufzeit, Zeitfenster-Flip
/// ohne Neustart, abgleichende statt einmalige Pins, echter Puck mit korrekt
/// gerechnetem Genauigkeits-Ring, Folgen-Modus.
struct MapContainer: UIViewRepresentable {
    let dark: Bool
    let timeActive: Bool
    /// W1 liefert hier immer `[]` — die Schnittstelle steht schon fuer W3/W5.
    let pins: [SpotPinState]
    let freePins: [FreeSnapPinState]
    let userCoordinate: CLLocationCoordinate2D?
    let accuracyM: Double
    /// Zaehler statt Boolean: derselbe FAB-Tap zweimal muss zweimal fahren.
    let recenterToken: Int
    /// W2: Ziel-Modus — Pin an dieser Stelle, Karte fliegt hin. `nil` = kein Ziel.
    var target: CLLocationCoordinate2D?
    /// W3: Pick-Modus liest hierueber den Kartenmittelpunkt. Kein Zustand in der
    /// Karte — nur eine Leseschliesse, die sie eintraegt.
    var centerSink: MapCenterSink?
    /// W6: Lage der freien Snap-Pins auf dem Schirm — Herkunft des Morphs.
    var pinRectSink: MapPinRectSink?
    /// W5: GENAU dieser Pin ploppt auf — der gerade aufgenommene. Alles andere
    /// erscheint ruhig: beim Start liegt der ganze Bestand an, und eine Karte,
    /// auf der zwanzig Pins gleichzeitig hereinspringen, zappelt nur.
    var popInSnapId: String?
    var onSelectSpot: (String) -> Void = { _ in }
    var onSelectFreeSnap: (String) -> Void = { _ in }
    /// Der Sprung ist gelaufen — das Modell kann das Ereignis abhaken.
    var onPopInPlayed: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(dark: dark, timeActive: timeActive)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: Coordinator.styleURL(dark: dark))
        // ProMotion: ohne .maximum rendert die Karte 60 Hz, Gesten fuehlen sich
        // gegen Apple Maps (120 Hz) hakelig an. Braucht zusaetzlich den Plist-Key
        // CADisableMinimumFrameDurationOnPhone.
        mapView.preferredFramesPerSecond = .maximum
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = context.coordinator
        mapView.setCenter(userCoordinate ?? kFallbackCenter, zoomLevel: kInitialZoom, animated: false)

        // MapLibre-Pflicht: Logo und Attribution bleiben sichtbar — aber ueber
        // der Status-Bar (58 pt + 10 pt Abstand), nicht darunter wie in v1.
        // Der Attributions-Knopf zieht nach links neben das Logo: rechts unten
        // sitzt die FAB-Gruppe, dort verschwaende er hinter dem Info-Knopf.
        mapView.logoViewMargins = CGPoint(x: 8, y: 80)
        mapView.attributionButtonPosition = .bottomLeft
        mapView.attributionButtonMargins = CGPoint(x: 100, y: 84)

        context.coordinator.attach(to: mapView, pins: pins, freePins: freePins,
                                   user: userCoordinate, accuracyM: accuracyM)
        // W3
        centerSink?.read = { [weak mapView] in mapView?.centerCoordinate }
        // W6: Woher der Betrachter hervorgeht, wenn ein freier Pin ihn oeffnet.
        // Auf Nachfrage statt laufend gemeldet: die Lage aendert sich mit jeder
        // Kamerabewegung, und gebraucht wird sie zweimal — Hin- und Rueckweg.
        pinRectSink?.read = { [weak mapView, weak coordinator = context.coordinator] id in
            guard let mapView, let coordinator else { return nil }
            return coordinator.photoRect(ofFreeSnap: id, in: mapView)
        }
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectSpot = onSelectSpot
        coordinator.onSelectFreeSnap = onSelectFreeSnap
        coordinator.onPopInPlayed = onPopInPlayed
        coordinator.popInSnapId = popInSnapId
        coordinator.applyAppearance(dark: dark, on: mapView)
        coordinator.applyTimeActive(timeActive, on: mapView)
        coordinator.syncPins(pins, on: mapView)
        coordinator.syncFreePins(freePins, on: mapView)
        coordinator.updateUser(userCoordinate, accuracyM: accuracyM, on: mapView)
        // W2: vor dem Recenter — beendet der Nutzer den Ziel-Modus, faehrt die
        // Karte im selben Durchlauf zurueck auf seinen Standort.
        coordinator.syncTarget(target, on: mapView)
        coordinator.applyRecenter(token: recenterToken, on: mapView)
    }

    static func dismantleUIView(_ mapView: MLNMapView, coordinator: Coordinator) {
        mapView.delegate = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "map")

        private var dark: Bool
        private var timeActive: Bool
        /// Strong: der Style haelt den ObjC-Wrapper nicht am Leben, eine weak-Ref
        /// war beim ersten Lauf zur Sondenzeit bereits nil.
        private var zoneSource: MLNVectorTileSource?

        var onSelectSpot: ((String) -> Void)?
        var onSelectFreeSnap: ((String) -> Void)?
        var onPopInPlayed: ((String) -> Void)?
        /// W5: der eine frisch aufgenommene Snap, dessen Pin aufploppen soll.
        var popInSnapId: String?

        private var pins: [SpotPinState] = []
        private var freePins: [FreeSnapPinState] = []
        private var spotAnnotations: [String: SpotAnnotation] = [:]
        private var freeAnnotations: [String: FreeSnapAnnotation] = [:]
        /// Frisch aufgenommene freie Snaps — ihre View ploppt beim Erzeugen auf.
        private var pendingPopIn: Set<String> = []

        /// W2: Ziel-Pin des Ziel-Modus.
        private var targetAnnotation: TargetAnnotation?
        private var target: CLLocationCoordinate2D?
        /// Ziel, das gesetzt wurde, bevor die Karte stand — die Fahrt wird
        /// nachgeholt, sobald der Style geladen ist.
        private var pendingTargetFly: CLLocationCoordinate2D?

        private var puckAnnotation: PuckAnnotation?
        private var userCoordinate: CLLocationCoordinate2D?
        private var accuracyM: Double = 50
        /// Karte folgt dem Nutzer, bis er selbst schwenkt (v1 `followUser`).
        private var follow = true
        private var recenterToken = 0
        private var didCenterOnFirstFix = false

        init(dark: Bool, timeActive: Bool) {
            self.dark = dark
            self.timeActive = timeActive
        }

        static func styleURL(dark: Bool) -> URL {
            URL(string: dark
                ? "https://tiles.openfreemap.org/styles/dark"
                : "https://tiles.openfreemap.org/styles/positron")!
        }

        // MARK: - Erstbestueckung

        func attach(to mapView: MLNMapView, pins: [SpotPinState], freePins: [FreeSnapPinState],
                    user: CLLocationCoordinate2D?, accuracyM: Double) {
            self.pins = pins
            self.freePins = freePins
            self.accuracyM = accuracyM
            userCoordinate = user
            // Puck zuerst: liegt damit unter allen Pins.
            if let user {
                let puck = PuckAnnotation(coordinate: user)
                puckAnnotation = puck
                mapView.addAnnotation(puck)
                didCenterOnFirstFix = true
            }
            for state in pins {
                let annotation = SpotAnnotation(state: state)
                spotAnnotations[state.id] = annotation
                mapView.addAnnotation(annotation)
            }
            for state in freePins {
                let annotation = FreeSnapAnnotation(state: state)
                freeAnnotations[state.id] = annotation
                mapView.addAnnotation(annotation)
            }
        }

        // MARK: - Hell/Dunkel (SPEC 5.1)

        /// Der Spike fror das Schema beim Start ein. Hier wechselt die Style-URL,
        /// und `didFinishLoading` legt Source und Layer im NEUEN Style erneut an.
        func applyAppearance(dark newValue: Bool, on mapView: MLNMapView) {
            guard newValue != dark else { return }
            dark = newValue
            zoneSource = nil
            mapView.styleURL = Self.styleURL(dark: newValue)
            logger.info("Basemap gewechselt: dark=\(newValue, privacy: .public)")
        }

        // MARK: - Zeitfenster (SPEC 5.1)

        /// Stundenwechsel 7/20 Uhr ohne App-Neustart: nur die Deckkraft zieht nach,
        /// die Layer bleiben stehen.
        func applyTimeActive(_ newValue: Bool, on mapView: MLNMapView) {
            guard newValue != timeActive else { return }
            timeActive = newValue
            updateTimeOpacity(in: mapView.style)
            logger.info("Zeitfenster aktiv: \(newValue, privacy: .public)")
        }

        private func updateTimeOpacity(in style: MLNStyle?) {
            guard let style else { return }
            let solid: Double = dark ? 0.22 : 0.16
            (style.layer(withIdentifier: "time-fill") as? MLNFillStyleLayer)?.fillOpacity =
                NSExpression(forConstantValue: timeActive ? solid : 0.07)
            (style.layer(withIdentifier: "time-line") as? MLNLineStyleLayer)?.lineOpacity =
                NSExpression(forConstantValue: timeActive ? 0.85 : 0.4)
        }

        // MARK: - Pins (SPEC 5.2)

        /// Abgleich statt Einmal-Installation: Spots kommen und gehen zur Laufzeit.
        func syncPins(_ states: [SpotPinState], on mapView: MLNMapView) {
            guard states != pins else { return }
            pins = states
            let ids = Set(states.map(\.id))

            for (id, annotation) in spotAnnotations where !ids.contains(id) {
                mapView.removeAnnotation(annotation)
                spotAnnotations[id] = nil
            }
            for state in states {
                if let annotation = spotAnnotations[state.id] {
                    if annotation.coordinate.latitude != state.latitude
                        || annotation.coordinate.longitude != state.longitude {
                        annotation.coordinate = state.coordinate
                    }
                    (mapView.view(for: annotation) as? SpotPinView)?.configure(state)
                    continue
                }
                let annotation = SpotAnnotation(state: state)
                spotAnnotations[state.id] = annotation
                mapView.addAnnotation(annotation)
            }
        }

        func syncFreePins(_ states: [FreeSnapPinState], on mapView: MLNMapView) {
            guard states != freePins else { return }
            freePins = states
            let ids = Set(states.map(\.id))

            for (id, annotation) in freeAnnotations where !ids.contains(id) {
                mapView.removeAnnotation(annotation)
                freeAnnotations[id] = nil
            }
            for state in states {
                if let annotation = freeAnnotations[state.id] {
                    if annotation.coordinate.latitude != state.latitude
                        || annotation.coordinate.longitude != state.longitude {
                        annotation.coordinate = state.coordinate
                    }
                    (mapView.view(for: annotation) as? FreeSnapPinView)?.configure(state)
                    continue
                }
                let annotation = FreeSnapAnnotation(state: state)
                freeAnnotations[state.id] = annotation
                // Nur der gerade aufgenommene Snap springt herein. Der Bestand
                // beim Start erscheint ruhig — sonst zappelt die ganze Karte.
                if state.id == popInSnapId { pendingPopIn.insert(state.id) }
                mapView.addAnnotation(annotation)
            }
        }

        // MARK: - Puck (SPEC 5.3)

        func updateUser(_ coordinate: CLLocationCoordinate2D?, accuracyM: Double,
                        on mapView: MLNMapView) {
            self.accuracyM = accuracyM
            guard let coordinate else { return }
            let moved = userCoordinate.map {
                $0.latitude != coordinate.latitude || $0.longitude != coordinate.longitude
            } ?? true
            userCoordinate = coordinate

            if let puck = puckAnnotation {
                if moved { puck.coordinate = coordinate }
            } else {
                let puck = PuckAnnotation(coordinate: coordinate)
                puckAnnotation = puck
                mapView.addAnnotation(puck)
            }
            updateAccuracyRing(on: mapView)

            // Erste Fixe: hart hinspringen statt hinfliegen — sonst startet die
            // App mit einer Fahrt quer durch die Stadt.
            if !didCenterOnFirstFix {
                didCenterOnFirstFix = true
                mapView.setCenter(coordinate, zoomLevel: kInitialZoom, animated: false)
                return
            }
            if moved, follow {
                mapView.setCenter(coordinate, animated: true)
            }
        }

        /// Genauigkeit in Metern → Radius in Punkten, ueber die echte Projektion
        /// der Karte. Muss bei jedem Zoom neu gerechnet werden.
        private func updateAccuracyRing(on mapView: MLNMapView) {
            guard let puck = puckAnnotation,
                  let view = mapView.view(for: puck) as? PuckView,
                  let coordinate = userCoordinate else { return }
            let metersPerPoint = mapView.metersPerPoint(atLatitude: coordinate.latitude)
            guard metersPerPoint > 0 else { return }
            view.setAccuracyRadius(CGFloat(accuracyM / metersPerPoint))
        }

        // MARK: - Ziel-Modus (W2)

        /// Ziel gesetzt → Pin steht und die Karte fliegt hin; Ziel weg → Pin weg.
        /// Der Vergleich laeuft ueber die Koordinate, nicht ueber ein Token:
        /// derselbe Ort zweimal gewaehlt ist derselbe Kartenausschnitt (v1).
        func syncTarget(_ coordinate: CLLocationCoordinate2D?, on mapView: MLNMapView) {
            guard target?.latitude != coordinate?.latitude
                    || target?.longitude != coordinate?.longitude else { return }
            target = coordinate

            guard let coordinate else {
                if let annotation = targetAnnotation { mapView.removeAnnotation(annotation) }
                targetAnnotation = nil
                return
            }

            // Im Ziel-Modus gehoert die Karte dem Ziel — ein GPS-Update darf den
            // Ausschnitt nicht wegziehen (v1 `followUser.current = false`).
            follow = false
            if let annotation = targetAnnotation {
                annotation.coordinate = coordinate
            } else {
                let annotation = TargetAnnotation(coordinate: coordinate)
                targetAnnotation = annotation
                mapView.addAnnotation(annotation)
            }

            // Solange der Style nicht geladen ist, verpufft die Fahrt: die
            // Kamera wird beim Style-Aufbau neu gesetzt. Dann erst nach
            // `didFinishLoading` fliegen — sonst steht das Ziel im Screenshot
            // ausserhalb der Bildmitte, obwohl der Pin richtig sitzt.
            if mapView.style == nil || mapView.bounds.width == 0 {
                pendingTargetFly = coordinate
                logger.info("Ziel gesetzt (Fahrt wartet auf den Style)")
            } else {
                flyToTarget(coordinate, on: mapView)
            }
        }

        /// v1: `flyTo({ zoom: 15, offset: [0, -60] })`. `edgePadding` unten hebt
        /// den Punkt um die HALBE Einrueckung — 120 pt ergeben die 60 pt.
        private func flyToTarget(_ coordinate: CLLocationCoordinate2D, on mapView: MLNMapView) {
            let altitude = MLNAltitudeForZoomLevel(kFocusZoom, 0, coordinate.latitude,
                                                   mapView.bounds.size)
            let camera = MLNMapCamera(lookingAtCenter: coordinate, altitude: altitude,
                                      pitch: 0, heading: 0)
            mapView.setCamera(camera,
                              withDuration: 0.9,
                              animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
                              edgePadding: UIEdgeInsets(top: 0, left: 0, bottom: 120, right: 0),
                              completionHandler: nil)
            logger.info("Ziel angeflogen")
        }

        // MARK: - Kamera

        func applyRecenter(token: Int, on mapView: MLNMapView) {
            guard token != recenterToken else { return }
            recenterToken = token
            follow = true
            guard let coordinate = userCoordinate else { return }
            let camera = mapView.camera
            camera.centerCoordinate = coordinate
            mapView.setCamera(camera, withDuration: 0.6,
                              animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
                              completionHandler: nil)
            mapView.setZoomLevel(kFocusZoom, animated: true)
        }

        /// Tap = Karte faehrt zum Pin (Leon 15.08.), Zoom bleibt wie bei Apple Maps.
        /// `edgePadding` ist transient — nichts bleibt als contentInset haengen,
        /// Logo/Attribution bleiben wo sie sind.
        private func focus(_ coordinate: CLLocationCoordinate2D, bottomInset: CGFloat,
                           on mapView: MLNMapView) {
            let camera = mapView.camera
            camera.centerCoordinate = coordinate
            mapView.setCamera(camera,
                              withDuration: 0.45,
                              animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
                              edgePadding: UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0),
                              completionHandler: nil)
        }

        // MARK: - MLNMapViewDelegate

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is PuckAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: PuckView.reuseID) as? PuckView)
                    ?? PuckView(reuseIdentifier: PuckView.reuseID)
                return view
            }
            // W2: Ziel-Pin.
            if annotation is TargetAnnotation {
                return (mapView.dequeueReusableAnnotationView(withIdentifier: TargetPinView.reuseID) as? TargetPinView)
                    ?? TargetPinView(reuseIdentifier: TargetPinView.reuseID)
            }
            if let free = annotation as? FreeSnapAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: FreeSnapPinView.reuseID) as? FreeSnapPinView)
                    ?? FreeSnapPinView(reuseIdentifier: FreeSnapPinView.reuseID)
                if let state = freePins.first(where: { $0.id == free.snapID }) {
                    view.configure(state)
                }
                if pendingPopIn.remove(free.snapID) != nil {
                    view.playPopIn()
                    // Quittung erst im naechsten Durchlauf: waehrend SwiftUI
                    // gerade aktualisiert, waere das Setzen eines Zustands ein
                    // Schreibzugriff mitten im Zeichnen.
                    let id = free.snapID
                    DispatchQueue.main.async { [weak self] in self?.onPopInPlayed?(id) }
                }
                return view
            }
            guard let spot = annotation as? SpotAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: SpotPinView.reuseID) as? SpotPinView)
                ?? SpotPinView(reuseIdentifier: SpotPinView.reuseID)
            if let state = pins.first(where: { $0.id == spot.spotID }) {
                view.configure(state)
            }
            return view
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            false
        }

        /// Fotoflaeche eines freien Pins in Fensterkoordinaten — dasselbe
        /// Bezugssystem, in dem die Album-Kacheln ihre Lage melden.
        /// `nil`, wenn der Pin gerade nicht auf dem Schirm ist: dann gibt es
        /// keine Herkunft, und der Betrachter blendet ehrlich auf.
        @MainActor
        func photoRect(ofFreeSnap id: String, in mapView: MLNMapView) -> MorphRect? {
            guard let annotation = freeAnnotations[id],
                  let view = mapView.view(for: annotation) else { return nil }
            let inWindow = view.convert(FreeSnapPinView.photoFrame, to: nil)
            guard inWindow.width > 0 else { return nil }
            return MorphRect(rect: inWindow, cornerRadius: inWindow.width / 2)
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

        /// Der Nutzer schwenkt selbst → Folgen aus, bis er „Zentrieren" drueckt.
        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason,
                     animated: Bool) {
            let gestures: MLNCameraChangeReason = [
                .gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn, .gestureZoomOut,
                .gestureOneFingerZoom, .gestureTilt,
            ]
            if !reason.intersection(gestures).isEmpty, follow {
                follow = false
                logger.debug("Folgen beendet (Geste)")
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            // Der Genauigkeits-Ring haengt am Zoom, nicht nur an der Genauigkeit.
            updateAccuracyRing(on: mapView)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            installZoneLayers(in: style)
            updateAccuracyRing(on: mapView)
            // W2: Ziel, das vor dem Style gesetzt wurde, jetzt anfliegen.
            if let pending = pendingTargetFly {
                pendingTargetFly = nil
                flyToTarget(pending, on: mapView)
            }
        }

        /// Zonen-Layer exakt mit den v1-Werten (SPEC 5.6). Laeuft bei JEDEM
        /// Style-Laden — auch nach dem Hell/Dunkel-Wechsel.
        private func installZoneLayers(in style: MLNStyle) {
            guard let fileURL = Bundle.main.url(forResource: "zones", withExtension: "pmtiles") else {
                logger.error("zones.pmtiles nicht im Bundle")
                return
            }
            // `configurationURLString:` statt NSURL — der Header nennt genau diesen
            // Initializer fuer pmtiles-URLs, die NSURL auf iOS 17 falsch parst.
            let source = MLNVectorTileSource(identifier: "zones",
                                             configurationURLString: "pmtiles://" + fileURL.absoluteString)
            style.addSource(source)
            zoneSource = source

            let solidOpacity: Double = dark ? 0.22 : 0.16

            let banFill = MLNFillStyleLayer(identifier: "ban-fill", source: source)
            banFill.sourceLayerIdentifier = "ban"
            banFill.fillColor = NSExpression(forConstantValue: GZ.uiZoneBan)
            banFill.fillOpacity = NSExpression(forConstantValue: solidOpacity)
            style.addLayer(banFill)

            let banLine = MLNLineStyleLayer(identifier: "ban-line", source: source)
            banLine.sourceLayerIdentifier = "ban"
            banLine.lineColor = NSExpression(forConstantValue: GZ.uiZoneBan)
            banLine.lineWidth = NSExpression(forConstantValue: 1.6)
            banLine.lineOpacity = NSExpression(forConstantValue: 0.75)
            style.addLayer(banLine)

            let timeFill = MLNFillStyleLayer(identifier: "time-fill", source: source)
            timeFill.sourceLayerIdentifier = "time"
            timeFill.fillColor = NSExpression(forConstantValue: GZ.uiZoneTime)
            timeFill.fillOpacity = NSExpression(forConstantValue: timeActive ? solidOpacity : 0.07)
            style.addLayer(timeFill)

            let timeLine = MLNLineStyleLayer(identifier: "time-line", source: source)
            timeLine.sourceLayerIdentifier = "time"
            timeLine.lineColor = NSExpression(forConstantValue: GZ.uiZoneTime)
            timeLine.lineWidth = NSExpression(forConstantValue: 1.6)
            timeLine.lineDashPattern = NSExpression(forConstantValue: [2.2, 1.6])
            timeLine.lineOpacity = NSExpression(forConstantValue: timeActive ? 0.85 : 0.4)
            style.addLayer(timeLine)

            logger.info("Zonen-Layer gesetzt (dark=\(self.dark, privacy: .public), timeActive=\(self.timeActive, privacy: .public))")
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            logger.error("Karte laedt nicht: \(error.localizedDescription, privacy: .public)")
        }
    }
}
