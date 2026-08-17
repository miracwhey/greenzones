import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Aus einer Kamera-Aufnahme werden zwei Dateien (SPEC 10.2).
///
/// Drei Zusagen, jede einzeln getestet:
///  1. **Groesse** — Original hoechstens 1600 px an der langen Kante (JPEG q0.82),
///     Thumb 320 px. Ein 12-MP-Foto waere sonst 4 MB CKAsset pro Snap.
///  2. **Orientierung eingebrannt** — die Drehung steckt danach in den Pixeln,
///     nicht in einem EXIF-Feld. Wer das Feld ignoriert (und viele tun das),
///     zeigt das Bild sonst gekippt.
///  3. **Position raus** — das GPS-Feld wird nicht uebernommen. Der Aufnahmeort
///     steht im Record, wo er sichtbar und loeschbar ist; ein weitergereichtes
///     Foto traegt ihn nicht heimlich mit.
public enum SnapPipeline {
    public enum Failure: Error, Equatable {
        case unreadable
        case encodingFailed
    }

    public static let originalMaxEdge = 1600
    public static let thumbMaxEdge = 320
    public static let quality = 0.82

    public struct Output: Equatable, Sendable {
        public let original: Data
        public let thumb: Data
    }

    /// Beide Groessen aus denselben Quelldaten.
    public static func process(_ data: Data) throws -> Output {
        Output(original: try scaled(data, maxEdge: originalMaxEdge),
               thumb: try scaled(data, maxEdge: thumbMaxEdge))
    }

    /// Eine Groesse. Getrennt oeffentlich, damit der Thumb-Abruf fremder Snaps
    /// denselben Weg nimmt wie die eigene Aufnahme.
    public static func scaled(_ data: Data, maxEdge: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw Failure.unreadable
        }
        // `WithTransform` wendet die EXIF-Drehung auf die Pixel an; `Always`
        // erzwingt das Neuzeichnen auch dann, wenn die Datei ein eingebettetes
        // Vorschaubild mitbringt (das waere ungedreht und zu klein).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        return try encode(image)
    }

    private static func encode(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString,
                                                                 1, nil) else {
            throw Failure.encodingFailed
        }
        // Nur diese Felder werden geschrieben: keine GPS-, keine Geraete-, keine
        // Zeitstempel-Daten aus der Quelle. Was nicht uebernommen wird, kann
        // spaeter auch nicht auslaufen.
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return out as Data
    }

    /// Was in einer JPEG-Datei an Metadaten steht — die Pruefseite der Zusagen.
    public struct Metadata: Equatable, Sendable {
        public let pixelWidth: Int
        public let pixelHeight: Int
        /// EXIF-Orientierung; 1 = keine Drehung mehr noetig.
        public let orientation: Int
        public let hasGPS: Bool

        public var longEdge: Int { max(pixelWidth, pixelHeight) }
    }

    public static func metadata(of data: Data) -> Metadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = raw[kCGImagePropertyPixelWidth] as? Int,
              let height = raw[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return Metadata(pixelWidth: width,
                        pixelHeight: height,
                        orientation: raw[kCGImagePropertyOrientation] as? Int ?? 1,
                        hasGPS: raw[kCGImagePropertyGPSDictionary] != nil)
    }
}
