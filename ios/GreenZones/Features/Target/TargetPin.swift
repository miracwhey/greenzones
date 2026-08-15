import CoreLocation
import MapLibre
import UIKit

/// Der Ziel-Pin des Ziel-Modus. Port des `TARGET_PIN_SVG` aus
/// `client/src/components/MapView.tsx` (30×40, Spitze unten).
///
/// Die Farben sind in beiden Schemata dieselben wie in v1 (dunkler Koerper,
/// weisser Rand): der Pin muss auf der hellen UND auf der dunklen Basemap als
/// Fremdkoerper lesbar bleiben — ein mitschwimmender Ton geht auf einer der
/// beiden Karten unter.
final class TargetAnnotation: NSObject, MLNAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
}

final class TargetPinView: MLNAnnotationView {
    static let reuseID = "gz.target"

    private static let stage = CGSize(width: 30, height: 40)
    /// Spitze des Pins — der eigentliche Ankerpunkt.
    private static let tipY: CGFloat = 39

    private let body = CAShapeLayer()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(origin: .zero, size: Self.stage)
        scalesWithViewingDistance = false
        isDraggable = false
        isEnabled = false
        isUserInteractionEnabled = false
        backgroundColor = .clear

        let path = UIBezierPath()
        path.move(to: CGPoint(x: 15, y: Self.tipY))
        path.addCurve(to: CGPoint(x: 3, y: 14),
                      controlPoint1: CGPoint(x: 15, y: Self.tipY),
                      controlPoint2: CGPoint(x: 3, y: 24.5))
        // UIKit misst Winkel mit y nach unten: von links (π) im Uhrzeigersinn
        // weiter zu 2π laeuft der Bogen ueber die Kuppe.
        path.addArc(withCenter: CGPoint(x: 15, y: 14), radius: 12,
                    startAngle: .pi, endAngle: 2 * .pi, clockwise: true)
        path.addCurve(to: CGPoint(x: 15, y: Self.tipY),
                      controlPoint1: CGPoint(x: 27, y: 24.5),
                      controlPoint2: CGPoint(x: 15, y: Self.tipY))
        path.close()

        body.path = path.cgPath
        body.fillColor = UIColor(red: 23 / 255, green: 25 / 255, blue: 28 / 255, alpha: 1).cgColor
        body.strokeColor = UIColor.white.cgColor
        body.lineWidth = 2
        body.shadowColor = UIColor.black.cgColor
        body.shadowOpacity = 0.35
        body.shadowRadius = 3
        body.shadowOffset = CGSize(width: 0, height: 3)
        layer.addSublayer(body)

        let hole = CAShapeLayer()
        hole.path = UIBezierPath(ovalIn: CGRect(x: 15 - 4.5, y: 14 - 4.5, width: 9, height: 9)).cgPath
        hole.fillColor = UIColor.white.cgColor
        layer.addSublayer(hole)

        // Anker ist die Spitze unten, nicht die Bildmitte.
        centerOffset = CGVector(dx: 0, dy: -(Self.tipY - Self.stage.height / 2))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
