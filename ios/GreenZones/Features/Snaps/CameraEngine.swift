import AVFoundation
import Foundation
import os

/// Die Kamera selbst: Session, Ein- und Ausgang, Auslösen.
///
/// AVFoundation will seine Session auf einer eigenen Warteschlange konfiguriert
/// haben — `startRunning` blockiert, und die Konfiguration ist nicht
/// wiedereintrittsfest. Deshalb liegt hier alles hinter EINER seriellen Queue,
/// und nach aussen gibt es nur `async`-Aufrufe. Der `@unchecked Sendable`-Stempel
/// ist damit gedeckt: kein Feld wird ausserhalb dieser Queue angefasst.
final class CameraEngine: NSObject, @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// Kein Aufnahmegeraet — im Simulator der Normalfall.
        case noDevice
        case sessionFailed
        case captureFailed
    }

    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "de.leonvalentin.greenzones.camera")
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    /// Haelt den Delegate am Leben, bis das Foto da ist — AVFoundation haelt ihn
    /// nur schwach.
    private var pending: PhotoCapture?
    private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "snaps")

    /// Erlaubnis. Schon entschieden → kein zweiter Dialog.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    var hasFlash: Bool { device?.hasFlash ?? false }
    var canFlip: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    func start(position: AVCaptureDevice.Position = .back) async throws {
        try await run { [self] in
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                       position: position) else {
                throw Failure.noDevice
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            if let input { session.removeInput(input) }
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else {
                session.commitConfiguration()
                throw Failure.sessionFailed
            }
            session.addInput(newInput)
            input = newInput
            self.device = device
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw Failure.sessionFailed
                }
                session.addOutput(output)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Vorder-/Rueckkamera tauschen. Scheitert der Wechsel, bleibt die alte
    /// Kamera stehen — ein schwarzer Sucher waere schlimmer als kein Wechsel.
    func flip(to position: AVCaptureDevice.Position) async throws {
        try await start(position: position)
    }

    func capture(flash: Bool) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning else {
                    continuation.resume(throwing: Failure.captureFailed)
                    return
                }
                let settings = AVCapturePhotoSettings()
                // Blitz nur, wenn das Geraet einen hat — sonst wirft AVFoundation.
                settings.flashMode = (flash && device?.hasFlash == true) ? .on : .off
                let delegate = PhotoCapture { [weak self] result in
                    self?.pending = nil
                    continuation.resume(with: result)
                }
                pending = delegate
                output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// Arbeit auf der Kamera-Queue, Fehler zurueck zum Aufrufer.
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

/// Ein Auslöser, ein Delegate: AVFoundation meldet das fertige Foto genau
/// einmal, danach ist dieses Objekt fertig.
private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let finish: (Result<Data, Error>) -> Void

    init(finish: @escaping (Result<Data, Error>) -> Void) {
        self.finish = finish
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            finish(.failure(CameraEngine.Failure.captureFailed))
            return
        }
        finish(.success(data))
    }
}
