import AVFoundation
import GreenZonesKit
import SwiftUI

/// Der Scan-Leser: Session + QR-Metadaten, alles hinter EINER seriellen Queue
/// (dieselbe Disziplin wie `CameraEngine` — AVFoundation ist dort nicht
/// wiedereintrittsfest). Kein Foto-Ausgang: dieses Ding liest Codes, es nimmt
/// nichts auf und speichert nichts.
final class ScanEngine: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "de.leonvalentin.greenzones.scan")
    private let output = AVCaptureMetadataOutput()
    /// Erkannte Inhalte — geliefert auf der Scan-Queue, der Empfaenger hoppt
    /// selbst auf den Main-Actor.
    var onPayload: (@Sendable (String) -> Void)?

    func start() async throws {
        try await run { [self] in
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                       position: .back) else {
                throw CameraEngine.Failure.noDevice
            }
            session.beginConfiguration()
            session.sessionPreset = .high
            if session.inputs.isEmpty {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    throw CameraEngine.Failure.sessionFailed
                }
                session.addInput(input)
            }
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw CameraEngine.Failure.sessionFailed
                }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: queue)
                // Erst NACH addOutput — vorher kennt der Output keine Typen.
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Nach einem Fehlversuch weiterscannen — Session steht schon, nur anlaufen.
    func resume() {
        queue.async { [self] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func run(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension ScanEngine: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for case let object as AVMetadataMachineReadableCodeObject in metadataObjects {
            guard let value = object.stringValue, !value.isEmpty else { continue }
            onPayload?(value)
        }
    }
}

/// Zustand des Scanners fuer die Oberflaeche.
@MainActor
@Observable
final class ScanController {
    enum Camera: Equatable { case starting, live, denied, unavailable }
    enum Phase: Equatable {
        case scanning
        /// Gueltiger Code erkannt, Beitritt laeuft — die Kamera steht.
        case connecting
        case failed(String)
    }

    private(set) var camera: Camera = .starting
    private(set) var phase: Phase = .scanning
    /// Kurzer Hinweis auf einen fremden Code — verschwindet von selbst. Ohne
    /// ihn wirkte die App tot, wenn jemand den falschen Code anpeilt.
    private(set) var note: String?

    @ObservationIgnored let engine = ScanEngine()
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    /// Derselbe fremde Code soll nicht im Sekundentakt neu bemaengelt werden —
    /// er steht ja weiter im Bild. Zurueckgesetzt, wenn der Hinweis abgelaufen ist.
    @ObservationIgnored private var lastRejected: String?

    private let model: CommunityModel

    init(model: CommunityModel) {
        self.model = model
    }

    func start() async {
        #if DEBUG
        // Fixture-Laeufe fragen nichts und starten keine Session (Simulator hat
        // keine Kamera, aber einen Systemdialog — derselbe Grund wie bei der
        // Shot-Kamera). `GZ_SCAN_RESULT` speist stattdessen einen Treffer ein.
        if DebugEnvironment.usesFixtures {
            camera = .unavailable
            armDebugResult()
            return
        }
        #endif
        guard await CameraEngine.requestAccess() else {
            camera = .denied
            return
        }
        engine.onPayload = { [weak self] value in
            Task { @MainActor in self?.handle(value) }
        }
        do {
            try await engine.start()
            camera = .live
        } catch {
            camera = .unavailable
        }
    }

    func stop() { engine.stop() }

    /// Ein erkannter Inhalt — von der Kamera oder vom Debug-Schalter, derselbe Weg.
    func handle(_ payload: String) {
        guard phase == .scanning else { return }
        guard InviteLink.isShareURL(payload) else {
            reject(payload)
            return
        }
        // Einrasten: leichter Tick, Rahmen wird gruen, Kamera steht.
        GZ.haptic()
        withAnimation(GZ.microSpring) { phase = .connecting }
        engine.stop()
        Task { await accept(payload) }
    }

    private func accept(_ url: String) async {
        do {
            // Idempotent im Gateway — ein doppelt gescannter Code ist Erfolg.
            try await model.sync.gateway.acceptShare(urlString: url)
            // Der frische Freund soll sofort in der Liste stehen, und der
            // Profil-Schritt haengt am Bestand nach dem Refresh.
            await model.sync.refresh()
            GZ.hapticStatus(ok: true)
            model.notice("Ihr seid jetzt verbunden.")
            model.closeCover()
        } catch {
            GZ.hapticStatus(ok: false)
            withAnimation(GZ.microSpring) { phase = .failed(cloudMessage(error)) }
        }
    }

    /// Nach einem Fehlschlag: zurueck auf Anfang, Kamera laeuft wieder.
    func retry() {
        GZ.haptic()
        withAnimation(GZ.microSpring) { phase = .scanning }
        engine.resume()
    }

    private func reject(_ payload: String) {
        guard payload != lastRejected else { return }
        lastRejected = payload
        withAnimation(GZ.microSpring) { note = "Kein GreenZones-Code" }
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2200))
            guard !Task.isCancelled, let self else { return }
            withAnimation(GZ.microSpring) { self.note = nil }
            self.lastRejected = nil
        }
    }

    #if DEBUG
    private func armDebugResult() {
        guard let value = DebugEnvironment.scanResult else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(DebugEnvironment.uiSettle))
            self.handle(value)
        }
    }
    #endif
}

/// Scanner-Vollbild (`mockup/qr.html`, Szenarien „scan"/„scan-found"): dunkle
/// Ebene wie die Shot-Kamera, Sucher-Ecken, ein Satz Anleitung. Nimmt NUR
/// GreenZones-Einladungen an — fremde Codes loesen nichts aus.
struct CodeScannerView: View {
    let model: CommunityModel

    @State private var controller: ScanController

    init(model: CommunityModel) {
        self.model = model
        _controller = State(initialValue: ScanController(model: model))
    }

    private var frameColor: Color {
        controller.phase == .scanning ? Color.white.opacity(0.92) : GZ.ok
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
            }

            VStack(spacing: 26) {
                viewfinderFrame
                statusZone
                    .frame(minHeight: 64, alignment: .top)
            }
            .padding(.horizontal, 32)
        }
        .statusBarHidden(true)
        .environment(\.colorScheme, .dark)
        .task { await controller.start() }
        .onDisappear { controller.stop() }
    }

    // MARK: - Grund

    @ViewBuilder
    private var background: some View {
        Color.black
            .overlay {
                if controller.camera == .live {
                    CameraPreview(session: controller.engine.session)
                } else {
                    #if DEBUG
                    // Fixture-Grund nur im Debug — ein Beweisbild kann nichts
                    // zeigen, was die ausgelieferte App nicht baut.
                    if DebugEnvironment.usesFixtures, let image = SnapFixtures.image("snap3") {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .overlay(Color.black.opacity(0.45))
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

    /// Ehrlicher Zustand statt schwarzer Flaeche — und bei verweigerter
    /// Erlaubnis der direkte Weg in die Einstellungen.
    private var cameraNotice: some View {
        VStack(spacing: 12) {
            Text(controller.camera == .denied
                 ? "Kamera nicht freigegeben"
                 : (controller.camera == .starting ? "Kamera startet …" : "Keine Kamera verfügbar"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            if controller.camera == .denied {
                Text("Zum Scannen braucht GreenZones die Kamera — nur live, nichts wird gespeichert.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                Button {
                    GZ.haptic()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Einstellungen öffnen")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Chrome

    private var topBar: some View {
        ZStack {
            Text("Code scannen")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            HStack {
                Spacer(minLength: 0)
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
                .accessibilityLabel("Scanner schließen")
                .accessibilityIdentifier("gz.scanner.close")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var viewfinderFrame: some View {
        ScannerFrame()
            .stroke(frameColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 260, height: 260)
            .animation(GZ.microSpring, value: frameColor == GZ.ok)
    }

    /// Die eine Zone unter dem Rahmen — Anleitung, Hinweis, Fortschritt oder
    /// Fehler, nie zwei davon.
    @ViewBuilder
    private var statusZone: some View {
        switch controller.phase {
        case .connecting:
            pill {
                ProgressView().tint(.white)
                Text("Code erkannt — verbinde …")
            }
            .accessibilityIdentifier("gz.scanner.connecting")
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .failed(let message):
            VStack(spacing: 14) {
                Text(message)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.55),
                                in: .rect(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("gz.scanner.failed")
                Button(action: controller.retry) {
                    Text("Nochmal versuchen")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("gz.scanner.retry")
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .scanning:
            if let note = controller.note {
                pill { Text(note) }
                    .accessibilityIdentifier("gz.scanner.note")
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if controller.camera != .denied {
                Text("Richte die Kamera auf den Code deines Freundes.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
    }

    private func pill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 9) {
            content()
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 42)
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1) }
    }
}

/// Vier Sucher-Ecken, 30 pt lang, Radius 14 — die Form aus dem Mockup.
struct ScannerFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let arm: CGFloat = 30
        let radius: CGFloat = 14
        var path = Path()

        // Oben links.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // Oben rechts.
        path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // Unten rechts.
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        // Unten links.
        path.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))

        return path
    }
}
