import AVFoundation
import CoreLocation
import GreenZonesKit
import SwiftUI

/// Zustand der Kamera fuer die Oberflaeche — die Session selbst liegt in der
/// `CameraEngine`, hier steht nur, was der Sucher zeigen muss.
@MainActor
@Observable
final class CameraController {
    enum Status: Equatable {
        case starting
        case ready
        /// Erlaubnis verweigert — die Einstellungen sind der Weg zurueck.
        case denied
        /// Kein Aufnahmegeraet (Simulator) oder Session kaputt.
        case unavailable
    }

    private(set) var status: Status = .starting
    private(set) var position: AVCaptureDevice.Position = .back
    var flashOn = false

    @ObservationIgnored let engine = CameraEngine()

    var hasFlash: Bool { engine.hasFlash }
    var canFlip: Bool { engine.canFlip }
    var isLive: Bool { status == .ready }

    func start() async {
        #if DEBUG
        // Fixture-Laeufe fragen nichts: im Simulator gibt es keine Kamera, aber
        // sehr wohl einen Systemdialog — und der steht dann im Beweisbild statt
        // der Oberflaeche. Dieselbe Regel wie beim Standort (SPEC 12).
        if DebugEnvironment.usesFixtures {
            status = .unavailable
            return
        }
        #endif
        guard await CameraEngine.requestAccess() else {
            status = .denied
            return
        }
        do {
            try await engine.start(position: position)
            status = .ready
        } catch {
            status = .unavailable
        }
    }

    func stop() { engine.stop() }

    /// Kamera wechseln. Klappt es nicht, bleibt die alte laufen.
    func flip() async {
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        do {
            try await engine.flip(to: next)
            position = next
        } catch {
            // Kein Wechsel ist besser als ein schwarzer Sucher.
        }
    }

    func capture() async -> Data? {
        guard status == .ready else { return nil }
        return try? await engine.capture(flash: flashOn)
    }
}

/// Sucher als Kameraschicht — kein SwiftUI-Ersatzbild: was hier steht, ist das,
/// was aufgenommen wird.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // Von `layerClass` garantiert.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// Kamera-Vollbild (SPEC 9/10): Sucher, Kontext-Chip, Sichtbarkeit, Auslöser.
///
/// Der Kontext entscheidet, wohin der Snap faellt: an einen Spot (≤ 30 m oder
/// aus dessen Blatt heraus geoeffnet) oder frei auf die Karte. Er wird beim
/// Erscheinen einmal bestimmt und friert dann ein — waehrend man zielt, soll
/// der Chip nicht unter der Hand wechseln.
struct SnapCameraView: View {
    let model: CommunityModel
    /// Aus dem Spot-Blatt geoeffnet: dieser Spot gilt, unabhaengig von der Naehe.
    let spotId: String?
    let userCoordinate: CLLocationCoordinate2D?

    @State private var controller = CameraController()
    @State private var scope: SnapScope = .feed
    @State private var flash = false
    @State private var shutterPressed = false
    @State private var busy = false
    @State private var context: Spot?
    @State private var resolved = false

    /// Nur ein geteilter Spot hat eine eigene Zone — ohne sie gaebe es fuer
    /// „nur im Spot" keinen Ort, an den der Snap koennte.
    private var canRestrictToSpot: Bool { context?.zoneName != nil }

    var body: some View {
        ZStack {
            viewfinder
            // Bedienung braucht einen Grund, auf dem sie steht: auf einem hellen
            // Motiv (Himmel, Wasser) verschwindet weisse Schrift sonst spurlos.
            // Zwei Verlaeufe, nur an den Kanten — das Bild in der Mitte bleibt
            // unangetastet.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 240)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if canRestrictToSpot { audiencePicker }
                bottomBar
            }
            // Das Chrome raeumt zuerst: gleich verlaesst das Bild den Sucher und
            // fliegt an seinen Platz auf der Karte — es soll nicht unter Knoepfen
            // wegfliegen, die noch dastehen. Die Verlaeufe bleiben: sie gehoeren
            // zum Sucher, nicht zur Bedienung, und verschwinden mit ihm.
            .opacity(busy ? 0 : 1)
            .animation(GZ.microSpring, value: busy)
            Color.white
                .opacity(flash ? 1 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .task {
            resolveContext()
            await controller.start()
        }
        .onDisappear { controller.stop() }
    }

    // MARK: - Sucher

    @ViewBuilder
    private var viewfinder: some View {
        ZStack {
            // Der Sucher haengt als Overlay an der Grundflaeche, nie umgekehrt:
            // `scaledToFill` meldet sonst die volle Bildbreite als Layoutgroesse,
            // blaeht den ZStack darueber auf und schiebt X, Blitz und
            // Kamerawechsel seitlich aus dem Schirm (Spike-Befund, hier zuerst
            // wieder eingebaut und im Bild aufgefallen).
            Color.black
                .overlay {
                    if controller.isLive {
                        CameraPreview(session: controller.engine.session)
                    } else {
                        #if DEBUG
                        // Fixture-Laeufe (Screenshots) haben im Simulator keine
                        // Kamera. Das Ersatzbild steht NUR dort — im Release
                        // existiert dieser Zweig nicht, ein Beweisbild kann also
                        // nichts zeigen, was die ausgelieferte App nicht baut.
                        if DebugEnvironment.usesFixtures, let image = SnapFixtures.image("snap2") {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .overlay(Color.black.opacity(0.14))
                        } else {
                            cameraNotice
                        }
                        #else
                        cameraNotice
                        #endif
                    }
                }
                .clipped()
                .ignoresSafeArea()
        }
    }

    /// Ehrlicher Zustand statt schwarzer Flaeche: warum kein Bild kommt und was
    /// dagegen hilft.
    private var cameraNotice: some View {
        VStack(spacing: 10) {
            Text(controller.status == .denied
                 ? "Kamera nicht freigegeben"
                 : (controller.status == .starting ? "Kamera startet …" : "Keine Kamera verfügbar"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            if controller.status == .denied {
                Text("In den iOS-Einstellungen für GreenZones erlauben.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Chrome

    private var topBar: some View {
        ZStack {
            contextChip
            HStack {
                Button {
                    model.closeCover()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kamera schließen")
                .accessibilityIdentifier("gz.camera.close")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var contextChip: some View {
        HStack(spacing: 8) {
            Text(context?.emoji ?? "📍")
            Text(context?.name ?? "Auf der Karte")
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1) }
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("gz.camera.context")
    }

    /// Sichtbarkeit — nur am geteilten Spot eine Frage. Default „Alle Freunde"
    /// (Leon-Lock): der Normalfall ist der Feed, die Einschraenkung die Ausnahme.
    private var audiencePicker: some View {
        HStack(spacing: 3) {
            audienceButton("Alle Freunde", value: .feed)
            audienceButton("Nur im Spot", value: .spot)
        }
        .padding(3)
        .background(Color.black.opacity(0.45), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .padding(.bottom, 16)
    }

    private func audienceButton(_ title: String, value: SnapScope) -> some View {
        Button(action: { GZ.haptic(); scope = value }) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(scope == value ? .black : .white)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background {
                    if scope == value {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack {
            flashButton
            Spacer(minLength: 0)
            shutter
            Spacer(minLength: 0)
            flipButton
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 26)
    }

    private var flashButton: some View {
        Button(action: { GZ.haptic(); controller.flashOn.toggle() }) {
            Image(systemName: controller.flashOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(controller.hasFlash ? 0.9 : 0.35))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!controller.hasFlash)
        .accessibilityLabel(controller.flashOn ? "Blitz aus" : "Blitz an")
    }

    private var flipButton: some View {
        Button(action: { GZ.haptic(); Task { await controller.flip() } }) {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(controller.canFlip ? 0.9 : 0.35))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!controller.canFlip)
        .accessibilityLabel("Kamera wechseln")
    }

    private var shutter: some View {
        Button(action: trigger) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 5)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(Color.white)
                    .frame(width: 58, height: 58)
                    .scaleEffect(shutterPressed ? 0.86 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("Auslösen")
        .accessibilityIdentifier("gz.camera.shutter")
    }

    // MARK: - Auslösen

    private func trigger() {
        guard !busy else { return }
        busy = true
        GZ.haptic()
        withAnimation(GZ.microSpring) { shutterPressed = true }
        withAnimation(.easeOut(duration: 0.06)) { flash = true }
        Task {
            let data = await captureData()
            withAnimation(.easeIn(duration: 0.14)) { flash = false }
            shutterPressed = false
            guard let data else {
                busy = false
                model.notice("Die Aufnahme hat nicht geklappt.")
                return
            }
            model.captureAndClose(data, at: userCoordinate, spot: context, scope: scope)
        }
    }

    private func captureData() async -> Data? {
        if let data = await controller.capture() { return data }
        #if DEBUG
        // Ohne Kamera (Simulator) liefert der Fixture-Lauf ein festes Bild —
        // damit laeuft der ECHTE Weg (Pipeline, Store, Outbox, Pin), nur die
        // Quelle ist eine andere.
        if DebugEnvironment.usesFixtures {
            return SnapFixtures.data(SnapFixtures.names[0])
        }
        #endif
        return nil
    }

    private func resolveContext() {
        guard !resolved else { return }
        resolved = true
        if let spotId, let spot = model.spot(id: spotId) {
            context = spot
        } else if let userCoordinate {
            context = model.snapSync.captureContext(at: userCoordinate, spots: model.spots.spots)
        }
        // „Nur im Spot" ist ohne geteilte Zone nicht darstellbar — dann bleibt
        // es beim Feed, statt eine Wahl anzubieten, die nichts bewirkt.
        scope = .feed
    }
}
