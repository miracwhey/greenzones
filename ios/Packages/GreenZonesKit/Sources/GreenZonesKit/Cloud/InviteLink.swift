import CoreImage
import Foundation

/// Der Einladungs-Link als Ding: was als Einladung gilt und wie er zum Bild
/// wird. Code und Link sind DIESELBE CKShare-URL — der QR-Code ist nur ein
/// zweiter Transport, iCloud prueft den Beitritt in beiden Faellen.
public enum InviteLink {
    /// Nimmt der Scanner diesen Inhalt an? Nur die iCloud-Share-URLs, die
    /// `createFriendInvite`/`createSpotShare` liefern — alles andere loest
    /// nichts aus. Eine Kamera, die beliebige gescannte URLs oeffnet, waere
    /// ein Einfallstor, kein Feature.
    public static func isShareURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "www.icloud.com" || host == "icloud.com" else { return false }
        return components.path.hasPrefix("/share/") && components.path.count > "/share/".count
    }

    /// Der Link als QR-Bild, Stufe H: bis zu 30 % des Codes duerfen verdeckt
    /// oder unleserlich sein — das Zeichen in der Mitte kostet also keine
    /// Lesbarkeit (der Test verdeckt die Mitte und liest trotzdem).
    ///
    /// `samplingNearest` haelt die Module scharf: das Filter liefert 1 px je
    /// Modul, und die Standard-Interpolation malte beim Hochziehen Grau in die
    /// Kanten — ein QR aus Grautoenen scannt schlechter, je dunkler die Umgebung.
    public static func qrImage(for url: String, scale: CGFloat = 12) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
