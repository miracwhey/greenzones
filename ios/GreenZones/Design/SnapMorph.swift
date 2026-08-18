import SwiftUI

// MARK: - Ein Bild wandert von einem Rechteck ins andere
//
// Portiert aus dem abgenommenen Prototyp (`mockup/motion-v6.html`, Szenen B, C,
// E — dort heisst dieses Element „flier"). Die Regeln von dort gelten hier
// woertlich:
//
// 1. NIE Layout-Eigenschaften animieren. Breite und Hoehe pro Frame zu setzen
//    kostet Layout und Neuzeichnen; ein nicht-uniformes `scale` quetscht das
//    Foto. Deshalb: das Bild UNIFORM skalieren und den sichtbaren Ausschnitt
//    wandern lassen.
//
// 2. cover → contain ist ein AUSSCHNITTWECHSEL, kein Groessenwechsel. Die
//    Kachel zeigt einen Beschnitt, der Betrachter das ganze Bild. Beide Enden
//    rechnet deshalb DIESELBE Funktion (`CoverFrame`) — beim Ziel ist das
//    Rechteck genau das Seitenverhaeltnis des Bildes, dort faellt der Beschnitt
//    von selbst weg. Das Ziel ist die contain-Flaeche des Bildes, NICHT der
//    volle Schirm: sonst springt das Bild im Uebergabe-Frame.
//
// 3. Durchgehend EIN Element. Kein Umblenden zwischen Kachel und Vollbild —
//    die Quelle wird unsichtbar, dieses hier macht den ganzen Weg.

/// Ein Rechteck, in dem das Bild wie `object-fit: cover` sitzt — Kachel, Pin
/// oder (mit passendem Seitenverhaeltnis) die contain-Flaeche im Vollbild.
struct MorphRect: Equatable {
    var rect: CGRect
    var cornerRadius: CGFloat

    static func == (a: MorphRect, b: MorphRect) -> Bool {
        a.rect == b.rect && a.cornerRadius == b.cornerRadius
    }
}

/// Woher ein Morph startet: welches Bild, aus welchem Rechteck im Fenster.
/// Kommt von einer SwiftUI-Kachel ebenso wie von einer Karten-Annotation —
/// darum nur Geometrie, keine View-Referenz.
struct MorphOrigin: Equatable {
    let snapId: String
    let frame: MorphRect
}

/// Die abgeleitete Darstellung: das Bild in natuerlicher Groesse, verschoben,
/// uniform skaliert und in Bildkoordinaten beschnitten.
///
/// Interpoliert wird DIESE Form, nicht das Rechteck davor: der Prototyp
/// bewegt ebenfalls Transformation und Ausschnitt, und beides linear. Wuerde
/// man stattdessen das Rechteck interpolieren und den Rest daraus ableiten,
/// liefe der Massstab ueber eine andere Kurve als die Referenz.
private struct CoverFrame {
    var offset: CGPoint
    var scale: CGFloat
    /// Sichtbares Fenster in Bildkoordinaten (vor der Skalierung).
    var clip: CGRect
    /// Eckenradius, ebenfalls in Bildkoordinaten.
    var clipRadius: CGFloat

    init(image: CGSize, in target: MorphRect) {
        let iw = max(image.width, 1)
        let ih = max(image.height, 1)
        let s = max(target.rect.width / iw, target.rect.height / ih)
        let left = target.rect.minX + (target.rect.width - iw * s) / 2
        let top = target.rect.minY + (target.rect.height - ih * s) / 2
        offset = CGPoint(x: left, y: top)
        scale = s
        clip = CGRect(x: (target.rect.minX - left) / s,
                      y: (target.rect.minY - top) / s,
                      width: target.rect.width / s,
                      height: target.rect.height / s)
        clipRadius = target.cornerRadius / s
    }

    static func lerp(_ a: CoverFrame, _ b: CoverFrame, _ t: Double) -> CoverFrame {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(t) }
        var out = a
        out.offset = CGPoint(x: mix(a.offset.x, b.offset.x), y: mix(a.offset.y, b.offset.y))
        out.scale = mix(a.scale, b.scale)
        out.clip = CGRect(x: mix(a.clip.minX, b.clip.minX),
                          y: mix(a.clip.minY, b.clip.minY),
                          width: mix(a.clip.width, b.clip.width),
                          height: mix(a.clip.height, b.clip.height))
        out.clipRadius = mix(a.clipRadius, b.clipRadius)
        return out
    }
}

/// Beschnitt in Bildkoordinaten. Ein eigenes `Shape`, weil `clipShape` sonst
/// immer das ganze angebotene Rechteck nimmt — hier soll aber ein Fenster
/// INNERHALB des Bildes stehen bleiben.
private struct ImageWindow: Shape {
    var window: CGRect
    var radius: CGFloat

    func path(in _: CGRect) -> Path {
        Path(roundedRect: window, cornerRadius: radius, style: .continuous)
    }
}

/// Das fliegende Bild. `progress` 0 = Quelle, 1 = Ziel; die Feder bewegt genau
/// diesen einen Wert, alles andere ist daraus gerechnet.
struct SnapFlier: View, Animatable {
    let image: UIImage
    let from: MorphRect
    let to: MorphRect
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let size = image.size
        let frame = CoverFrame.lerp(CoverFrame(image: size, in: from),
                                    CoverFrame(image: size, in: to),
                                    progress)
        Image(uiImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .clipShape(ImageWindow(window: frame.clip, radius: frame.clipRadius))
            .scaleEffect(frame.scale, anchor: .topLeading)
            .offset(x: frame.offset.x, y: frame.offset.y)
            // Das Bild liegt in Fensterkoordinaten, nicht im Fluss der
            // umgebenden Ansicht: es startet bei (0,0) links oben und traegt
            // seine Lage selbst.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension MorphRect {
    /// Die contain-Flaeche eines Bildes in einer Zielflaeche: dasselbe
    /// Seitenverhaeltnis wie das Bild, zentriert, ohne Ecken.
    ///
    /// Das ist das Ziel jedes Morphs in den Betrachter — nicht `area` selbst.
    /// Der Betrachter zeigt sein Bild mit `scaledToFit` ueber dieselbe Flaeche,
    /// beide rechnen also dasselbe Rechteck aus.
    static func contain(image: CGSize, in area: CGRect) -> MorphRect {
        let iw = max(image.width, 1)
        let ih = max(image.height, 1)
        let s = min(area.width / iw, area.height / ih)
        let w = iw * s
        let h = ih * s
        return MorphRect(rect: CGRect(x: area.midX - w / 2, y: area.midY - h / 2,
                                      width: w, height: h),
                         cornerRadius: 0)
    }
}
