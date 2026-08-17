import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GreenZonesKit

/// Die drei Zusagen der Aufnahme-Verarbeitung (SPEC 10.2, Pflichtsuite laut
/// SPEC 12). Jede wird gegen die geschriebene Datei geprueft, nicht gegen den
/// Rueckgabewert der Funktion, die sie erzeugt hat.
@Suite("Snap-Verarbeitung — Groesse, Drehung, Position")
struct SnapPipelineTests {
    /// Ein Testfoto mit allem, was eine Kamera anhaengt: Groesse, Drehung, GPS.
    private func makeJPEG(width: Int, height: Int, orientation: Int, gps: Bool) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Zwei Felder, damit eine Drehung im Bildinhalt sichtbar waere.
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let image = context.makeImage()!

        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 52.3595,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 9.7400,
                kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any]
        }
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    @Test("Die Quelle bringt wirklich mit, was entfernt werden soll")
    func fixtureCarriesWhatWeStrip() throws {
        // Kontrollprobe: ohne sie koennte der GPS-Test gruen sein, weil die
        // Quelle nie GPS hatte.
        let data = try makeJPEG(width: 800, height: 600, orientation: 6, gps: true)
        let meta = try #require(SnapPipeline.metadata(of: data))
        #expect(meta.hasGPS)
        #expect(meta.orientation == 6)
    }

    @Test("Original: lange Kante hoechstens 1600 px")
    func originalIsCapped() throws {
        let data = try makeJPEG(width: 4032, height: 3024, orientation: 1, gps: false)
        let output = try SnapPipeline.process(data)
        let meta = try #require(SnapPipeline.metadata(of: output.original))
        #expect(meta.longEdge == SnapPipeline.originalMaxEdge)
        // Seitenverhaeltnis bleibt (4:3).
        #expect(abs(Double(meta.pixelWidth) / Double(meta.pixelHeight) - 4.0 / 3.0) < 0.01)
    }

    @Test("Thumb: lange Kante hoechstens 320 px")
    func thumbIsCapped() throws {
        let data = try makeJPEG(width: 4032, height: 3024, orientation: 1, gps: false)
        let output = try SnapPipeline.process(data)
        let meta = try #require(SnapPipeline.metadata(of: output.thumb))
        #expect(meta.longEdge == SnapPipeline.thumbMaxEdge)
    }

    @Test("Kleines Bild wird nicht kuenstlich vergroessert")
    func smallImageStaysSmall() throws {
        let data = try makeJPEG(width: 900, height: 600, orientation: 1, gps: false)
        let output = try SnapPipeline.process(data)
        let meta = try #require(SnapPipeline.metadata(of: output.original))
        #expect(meta.longEdge == 900)
    }

    @Test("Drehung steckt danach in den Pixeln, nicht im EXIF-Feld")
    func orientationIsBakedIn() throws {
        // Orientierung 6 = 90° gedreht: aus 800x600 muss 600x800 werden.
        let data = try makeJPEG(width: 800, height: 600, orientation: 6, gps: false)
        let output = try SnapPipeline.process(data)
        let meta = try #require(SnapPipeline.metadata(of: output.original))
        #expect(meta.orientation == 1, "EXIF-Drehung ist noch gesetzt")
        #expect(meta.pixelWidth == 600 && meta.pixelHeight == 800,
                "Kanten nicht getauscht — die Drehung wurde nicht angewandt")
    }

    @Test("Die Aufnahme-Position bleibt nicht im Bild")
    func gpsIsStripped() throws {
        let data = try makeJPEG(width: 1200, height: 900, orientation: 1, gps: true)
        let output = try SnapPipeline.process(data)
        let original = try #require(SnapPipeline.metadata(of: output.original))
        let thumb = try #require(SnapPipeline.metadata(of: output.thumb))
        #expect(!original.hasGPS)
        #expect(!thumb.hasGPS)
    }

    @Test("Unlesbare Daten scheitern laut statt still")
    func garbageFails() {
        #expect(throws: SnapPipeline.Failure.unreadable) {
            try SnapPipeline.process(Data([0x00, 0x01, 0x02, 0x03]))
        }
    }

    @Test("Ein 12-MP-Foto schrumpft auf Upload-Groesse")
    func outputIsSmallEnoughToUpload() throws {
        let data = try makeJPEG(width: 4032, height: 3024, orientation: 1, gps: true)
        let output = try SnapPipeline.process(data)
        // Kein Pixel-Vergleich, sondern die Groesse, die ueber die Leitung geht.
        #expect(output.original.count < 900_000)
        #expect(output.thumb.count < 60_000)
    }
}
