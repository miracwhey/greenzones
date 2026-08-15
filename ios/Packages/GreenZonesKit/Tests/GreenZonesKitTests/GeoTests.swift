import CoreLocation
import Testing
@testable import GreenZonesKit

@Suite("Geo — Port von client/src/lib/geo.ts")
struct GeoTests {
    /// Quadrat 0,001° × 0,001° um Hannover, im Uhrzeigersinn geschlossen.
    private let square: GZPolygon = [[
        9.740, 52.359,
        9.741, 52.359,
        9.741, 52.360,
        9.740, 52.360,
        9.740, 52.359,
    ]]

    @Test("distanceM: 0,001° Breite sind ~111,2 m")
    func distanceLatitude() {
        let a = CLLocationCoordinate2D(latitude: 52.359, longitude: 9.74)
        let b = CLLocationCoordinate2D(latitude: 52.360, longitude: 9.74)
        #expect(abs(Geo.distanceM(a, b) - 111.19) < 0.05)
    }

    @Test("distanceM ist symmetrisch und 0 auf sich selbst")
    func distanceSymmetry() {
        let a = CLLocationCoordinate2D(latitude: 52.3595, longitude: 9.74)
        let b = CLLocationCoordinate2D(latitude: 52.3745, longitude: 9.7386)
        #expect(Geo.distanceM(a, a) == 0)
        #expect(abs(Geo.distanceM(a, b) - Geo.distanceM(b, a)) < 1e-9)
    }

    @Test("formatDistanceM: de-DE mit Komma ab 1 km")
    func formatting() {
        #expect(Geo.formatDistanceM(0) == "0 m")
        #expect(Geo.formatDistanceM(45.4) == "45 m")
        #expect(Geo.formatDistanceM(649.6) == "650 m")
        #expect(Geo.formatDistanceM(999.4) == "999 m")
        #expect(Geo.formatDistanceM(1000) == "1,0 km")
        #expect(Geo.formatDistanceM(2149) == "2,1 km")
    }

    @Test("pointInPolygon trifft innen, verfehlt aussen")
    func inside() {
        #expect(Geo.pointInPolygon(CLLocationCoordinate2D(latitude: 52.3595, longitude: 9.7405),
                                   square))
        #expect(!Geo.pointInPolygon(CLLocationCoordinate2D(latitude: 52.3595, longitude: 9.7395),
                                    square))
    }

    @Test("Loch im Polygon zaehlt als aussen")
    func hole() {
        let hole: GZRing = [
            9.7404, 52.3594,
            9.7406, 52.3594,
            9.7406, 52.3596,
            9.7404, 52.3596,
            9.7404, 52.3594,
        ]
        let withHole: GZPolygon = [square[0], hole]
        let inHole = CLLocationCoordinate2D(latitude: 52.3595, longitude: 9.7405)
        #expect(Geo.pointInPolygon(inHole, square))
        #expect(!Geo.pointInPolygon(inHole, withHole))
    }

    @Test("distToPolygonEdgeM: 0 auf der Kante, Naeherung ausserhalb")
    func edgeDistance() {
        // Punkt genau auf der Suedkante.
        let onEdge = CLLocationCoordinate2D(latitude: 52.359, longitude: 9.7405)
        #expect(Geo.distToPolygonEdgeM(onEdge, square) < 0.001)

        // 0,0005° suedlich der Kante ≈ 55,6 m.
        let below = CLLocationCoordinate2D(latitude: 52.3585, longitude: 9.7405)
        #expect(abs(Geo.distToPolygonEdgeM(below, square) - 55.6) < 0.2)

        // Innenpunkte haben ebenfalls eine Kanten-Distanz > 0 (die Engine setzt
        // 0 erst ueber `inside`, nicht ueber die Distanz).
        let center = CLLocationCoordinate2D(latitude: 52.3595, longitude: 9.7405)
        #expect(Geo.distToPolygonEdgeM(center, square) > 30)
    }
}
