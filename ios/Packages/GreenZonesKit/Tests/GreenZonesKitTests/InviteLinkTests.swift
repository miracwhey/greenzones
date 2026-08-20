import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import GreenZonesKit

@Suite("Einladungs-Link — was der Scanner annimmt, und der Code als Bild")
struct InviteLinkTests {
    // MARK: - Annahme-Regel

    @Test("Echte iCloud-Share-URLs gelten, mit und ohne www und Fragment")
    func acceptsShareURLs() {
        #expect(InviteLink.isShareURL("https://www.icloud.com/share/0aBcDeFgHiJkLmNoPqRsTuVwX"))
        #expect(InviteLink.isShareURL("https://icloud.com/share/0abc123"))
        #expect(InviteLink.isShareURL("https://www.icloud.com/share/0abc#Unsere_Bank"))
        // Ein Scanner liefert gelegentlich Whitespace drumherum.
        #expect(InviteLink.isShareURL("  https://www.icloud.com/share/0abc\n"))
        #expect(InviteLink.isShareURL("HTTPS://WWW.ICLOUD.COM/share/0abc"))
    }

    @Test("Alles andere loest nichts aus")
    func rejectsForeignContent() {
        // Falscher Host — auch wenn er iCloud im Namen traegt.
        #expect(!InviteLink.isShareURL("https://icloud.com.evil.de/share/0abc"))
        #expect(!InviteLink.isShareURL("https://evil.de/share/0abc"))
        #expect(!InviteLink.isShareURL("https://www.apple.com/share/0abc"))
        // Richtiger Host, falscher Pfad.
        #expect(!InviteLink.isShareURL("https://www.icloud.com/iclouddrive/0abc"))
        #expect(!InviteLink.isShareURL("https://www.icloud.com/share/"))
        #expect(!InviteLink.isShareURL("https://www.icloud.com"))
        // Kein HTTPS.
        #expect(!InviteLink.isShareURL("http://www.icloud.com/share/0abc"))
        #expect(!InviteLink.isShareURL("icloud.com/share/0abc"))
        // Kein Link.
        #expect(!InviteLink.isShareURL("WIFI:T:WPA;S:Eduroam;P:x;;"))
        #expect(!InviteLink.isShareURL("Hallo"))
        #expect(!InviteLink.isShareURL(""))
    }

    // MARK: - Code als Bild

    private let url = "https://www.icloud.com/share/0aBcDeFgHiJkLmNoPqRsTuVwX"

    private func decode(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    @Test("Der erzeugte Code traegt exakt die URL — hin und zurueck gelesen")
    func roundTrip() throws {
        let image = try #require(InviteLink.qrImage(for: url))
        #expect(image.width == image.height)
        #expect(decode(image) == [url])
    }

    @Test("Mit verdeckter Mitte bleibt der Code lesbar — das Zeichen darf dort sitzen")
    func readableWithCenterCovered() throws {
        let image = try #require(InviteLink.qrImage(for: url))
        // Das Zeichen im Blatt deckt ~24 % der Kantenlaenge — hier dieselbe
        // Flaeche als gefuellter Kreis, damit der Test die echte Verdeckung
        // misst und nicht eine mildere.
        let side = image.width
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: side, height: side,
                                             bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let diameter = CGFloat(side) * 0.24
        context.setFillColor(CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: (CGFloat(side) - diameter) / 2,
                                       y: (CGFloat(side) - diameter) / 2,
                                       width: diameter, height: diameter))
        let covered = try #require(context.makeImage())
        #expect(decode(covered) == [url])
    }

    @Test("Kontrollprobe: eine Verdeckung weit ueber Stufe H macht den Code unlesbar")
    func mutationProbeCoverTooMuch() throws {
        // Beweist, dass `decode` wirklich misst — ein Detektor, der auch das
        // noch laese, wuerde den Verdeckungs-Test oben wertlos machen.
        let image = try #require(InviteLink.qrImage(for: url))
        let side = image.width
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: side, height: side,
                                             bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1))
        let big = CGFloat(side) * 0.78
        context.fillEllipse(in: CGRect(x: (CGFloat(side) - big) / 2,
                                       y: (CGFloat(side) - big) / 2, width: big, height: big))
        let covered = try #require(context.makeImage())
        #expect(decode(covered).isEmpty)
    }
}
