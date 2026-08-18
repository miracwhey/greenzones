import CoreLocation
import MapLibre
import UIKit

// Pins liegen als MLNAnnotationView IN der Karte, nicht als SwiftUI-Overlay
// darueber: MapLibre positioniert sie in derselben Render-Passe wie die Tiles —
// damit schwenken sie framegenau mit, ohne Nachzieh-Lag eines separaten
// `convert(coordinate:)`-Overlays. (Uebernommen aus dem Spike.)

/// Was ein Spot-Pin ueber seinen Spot wissen muss.
///
/// W1 kennt noch keine Spots — die Struktur und der `pins:`-Weg stehen trotzdem,
/// damit W3/W5 nur noch Daten liefern muessen und die Karte nicht umgebaut wird.
struct SpotPinState: Equatable {
    let id: String
    let emoji: String
    /// Ring-Farbe: nah = ok-gruen, fern = ink-3.
    let isNear: Bool
    /// Bis zu 2 Fotos fuer den Faecher, neuestes zuerst (Variante A).
    let stackPhotos: [UIImage]
    /// Alle Snaps des Spots — der Rest steht als „+n"-Chip.
    let snapCount: Int
    /// Identitaet des vordersten Snaps — daran haengt die Wachstums-Animation.
    let frontSnapID: String?
    let latitude: Double
    let longitude: Double

    var hasSnaps: Bool { !stackPhotos.isEmpty }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func == (a: SpotPinState, b: SpotPinState) -> Bool {
        a.id == b.id && a.emoji == b.emoji && a.isNear == b.isNear
            && a.snapCount == b.snapCount && a.frontSnapID == b.frontSnapID
            && a.latitude == b.latitude && a.longitude == b.longitude
            && a.stackPhotos.count == b.stackPhotos.count
    }
}

/// Freier Snap ohne Spot — eigener Pin an der Aufnahme-Position.
struct FreeSnapPinState: Equatable {
    let id: String
    let photo: UIImage?
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func == (a: FreeSnapPinState, b: FreeSnapPinState) -> Bool {
        a.id == b.id && a.latitude == b.latitude && a.longitude == b.longitude
            && (a.photo === b.photo)
    }
}

// MARK: - Annotationen

final class SpotAnnotation: NSObject, MLNAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    let spotID: String

    init(state: SpotPinState) {
        coordinate = state.coordinate
        spotID = state.id
        super.init()
    }
}

final class FreeSnapAnnotation: NSObject, MLNAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    let snapID: String

    init(state: FreeSnapPinState) {
        coordinate = state.coordinate
        snapID = state.id
        super.init()
    }
}

final class PuckAnnotation: NSObject, MLNAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
}

// MARK: - Bausteine

/// Rundes Foto mit weissem Ring und weichem Schatten.
private func makeRoundPhotoView(size: CGFloat, ring: CGFloat = 2) -> UIImageView {
    let view = UIImageView(frame: CGRect(x: 0, y: 0, width: size, height: size))
    view.contentMode = .scaleAspectFill
    view.backgroundColor = GZ.uiInk3
    view.layer.cornerRadius = size / 2
    view.layer.masksToBounds = true
    view.layer.borderWidth = ring
    view.layer.borderColor = UIColor.white.cgColor
    return view
}

private func centeredRect(_ center: CGPoint, _ size: CGFloat) -> CGRect {
    CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
}

/// Glass-Chip („+n") in der Design-Sprache: ultraThin + 1-px-Stroke.
private func makeGlassChip(frame: CGRect, label: UILabel, corner: CGFloat) -> UIView {
    let chip = UIView(frame: frame)
    chip.layer.cornerRadius = corner
    chip.layer.cornerCurve = .continuous
    chip.layer.masksToBounds = true
    chip.layer.borderWidth = 1
    chip.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    blur.frame = chip.bounds
    blur.isUserInteractionEnabled = false
    chip.addSubview(blur)
    label.frame = chip.bounds
    label.textAlignment = .center
    chip.addSubview(label)
    return chip
}

/// Schatten muss AUSSERHALB der maskierten Bildebene liegen — deshalb traegt ihn
/// ein Container, nicht die ImageView selbst (`masksToBounds` wuerde ihn kappen).
private func makeShadowHolder(_ content: UIView) -> UIView {
    let holder = UIView(frame: content.frame)
    holder.layer.shadowColor = UIColor.black.cgColor
    holder.layer.shadowOpacity = 0.18
    holder.layer.shadowRadius = 5
    holder.layer.shadowOffset = CGSize(width: 0, height: 3)
    content.frame = holder.bounds
    holder.addSubview(content)
    return holder
}

// MARK: - Spot-Pin (Variante A, Leon-Wahl 15.08.)

/// Emoji-Anker: 40-pt-Emoji-Kreis vorn, zwei 22-pt-Foto-Kreise gefaechert
/// dahinter, „+n"-Chip fuer den Rest. Buehne 84×72, Anker in der Mitte.
final class SpotPinView: MLNAnnotationView {
    static let reuseID = "gz.spot"

    private static let stageSize = CGSize(width: 84, height: 72)
    private static let anchor = CGPoint(x: 42, y: 36)

    /// Alles Sichtbare haengt hier drin: MapLibre fasst die `transform` der
    /// AnnotationView selbst an, eigene Animationen laufen eine Ebene tiefer.
    private let content = UIView()
    private let circleGroup = UIView()
    private let circle = UIView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let emojiLabel = UILabel()

    private let photoGroup = UIView()
    private var photoHolders: [UIView] = []
    private var photoViews: [UIImageView] = []
    private let countLabel = UILabel()
    private var countChip: UIView?

    private var isNear = true
    private var lastFrontSnapID: String?
    private var configured = false

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(origin: .zero, size: Self.stageSize)
        // Kein Skalieren mit Neigung/Distanz — der Pin ist UI, kein Weltobjekt.
        scalesWithViewingDistance = false
        isDraggable = false
        backgroundColor = .clear
        content.frame = bounds
        addSubview(content)

        photoGroup.frame = bounds
        circleGroup.frame = bounds
        // Reihenfolge = z-Ordnung: die Foto-Kreise liegen HINTER dem Emoji.
        content.addSubview(photoGroup)
        content.addSubview(circleGroup)

        buildCircle(diameter: 40)
        buildFan()

        // Ring-Farbe haengt an dynamischen UIColors — bei Hell/Dunkel-Wechsel
        // muss sie neu aufgeloest werden (CGColor kennt keine Traits).
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SpotPinView, _) in
            view.applyRingColor()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func buildCircle(diameter: CGFloat) {
        circle.frame = centeredRect(Self.anchor, diameter)
        circle.layer.cornerRadius = diameter / 2
        circle.layer.cornerCurve = .continuous
        circle.layer.borderWidth = 2
        circle.layer.masksToBounds = true
        blur.frame = circle.bounds
        blur.isUserInteractionEnabled = false
        circle.addSubview(blur)
        emojiLabel.frame = circle.bounds
        emojiLabel.textAlignment = .center
        emojiLabel.font = .systemFont(ofSize: diameter / 2)
        circle.addSubview(emojiLabel)
        circleGroup.addSubview(circle)
    }

    /// Versatz zwischen zwei Fotos im Faecher. Um genau diesen Weg rutschen die
    /// vorhandenen zur Seite, wenn ein neuer dazukommt — eine eigene Zahl liefe
    /// vom Faecher weg, sobald jemand die Anordnung anfasst.
    private static let fanStep = CGSize(width: 10, height: 7)

    /// Zwei 22-pt-Foto-Kreise, oben rechts aufgefaechert.
    private func buildFan() {
        let centers = [CGPoint(x: 58, y: 20),
                       CGPoint(x: 58 + Self.fanStep.width, y: 20 + Self.fanStep.height)]
        // Rueckwaerts anlegen: Index 0 (neuester) landet oben auf dem Faecher.
        for index in stride(from: centers.count - 1, through: 0, by: -1) {
            let photo = makeRoundPhotoView(size: 22, ring: 1.5)
            let holder = makeShadowHolder(photo)
            holder.frame = centeredRect(centers[index], 22)
            photoGroup.addSubview(holder)
            photoHolders.insert(holder, at: 0)
            photoViews.insert(photo, at: 0)
        }
        countLabel.font = .preferredFont(forTextStyle: .caption2)
        countLabel.textColor = GZ.uiInk
        let chip = makeGlassChip(frame: CGRect(x: 46, y: 44, width: 24, height: 15),
                                 label: countLabel, corner: 7.5)
        // Ueber dem Emoji-Kreis, sonst verschwindet der Chip dahinter.
        content.addSubview(chip)
        countChip = chip
    }

    func configure(_ state: SpotPinState) {
        emojiLabel.text = state.emoji
        isNear = state.isNear
        applyRingColor()

        for (index, holder) in photoHolders.enumerated() {
            let photo = index < state.stackPhotos.count ? state.stackPhotos[index] : nil
            holder.isHidden = photo == nil
            photoViews[index].image = photo
        }

        // Emoji IST der Pin: der Kreis bleibt, die Fotos sind nur Beiwerk.
        circleGroup.alpha = 1
        photoGroup.alpha = state.hasSnaps ? 1 : 0
        let rest = state.snapCount - photoHolders.count
        countChip?.isHidden = rest <= 0
        countLabel.text = "+\(max(rest, 0))"

        // Neuer Snap am Spot: der vordere Thumbnail waechst herein — aber nicht
        // beim ersten Aufbau, sonst zappelt die Karte beim Start.
        //
        // Erst wenn sein BILD da ist. `configure` laeuft zweimal: einmal, sobald
        // der Snap im Bestand steht (Vorschau noch nicht geladen, der Halter
        // also versteckt), und nochmal, wenn das Bild kommt. Wurde die Id schon
        // beim ersten Mal abgehakt, lief die ganze Bewegung auf einem
        // unsichtbaren Halter ab, und beim zweiten Mal gab es nichts mehr zu
        // zeigen — im Bild gesehen: der neue Thumbnail stand sofort voll da.
        let hasFrontPhoto = state.stackPhotos.first != nil
        let grew = configured && hasFrontPhoto
            && state.frontSnapID != nil && state.frontSnapID != lastFrontSnapID
        if hasFrontPhoto || state.frontSnapID == nil { lastFrontSnapID = state.frontSnapID }
        configured = true
        if grew { playStackGrow() }
    }

    /// Ein Snap ist an diesem Spot dazugekommen (Szene A des abgenommenen
    /// Prototyps). Vier Teile, in dieser Ordnung:
    ///
    /// 1. Die vorhandenen Fotos machen PLATZ — sie rutschen um genau den
    ///    Versatz zur Seite, den der Faecher zwischen zwei Kacheln haelt. Ohne
    ///    das erscheint der Neue in einem fertigen Bild, statt sich einzureihen.
    /// 2. Der Neue kommt einen kurzen Weg: `.62 → 1` mit leichtem Fall liest
    ///    sich als Ankunft, ein Sprung aus dem Nichts (etwa `.15`) als Effekt.
    ///    Vorher startete er bei `.4` ohne Weg und ohne Deckkraft.
    /// 3. Der Pin nimmt den Stoss auf, leicht versetzt.
    /// 4. Der Zaehler quittiert ihn, nochmal versetzt.
    ///
    /// Sekundaerbewegungen laufen auf der Mikro-Feder: sie sind Antwort, nicht
    /// Hauptsache, und duerfen die Ankunft nicht ueberdauern.
    private func playStackGrow() {
        guard let front = photoHolders.first else { return }
        let shift = CGSize(width: Self.fanStep.width, height: Self.fanStep.height)

        for holder in photoHolders.dropFirst() where !holder.isHidden {
            holder.transform = CGAffineTransform(translationX: -shift.width, y: -shift.height)
            GZ.uiAnimate(GZ.elementFeder) { holder.transform = .identity }
        }

        front.alpha = 0
        front.transform = CGAffineTransform(translationX: 0, y: -5).scaledBy(x: 0.62, y: 0.62)
        GZ.uiAnimate(GZ.elementFeder) {
            front.alpha = 1
            front.transform = .identity
        }

        GZ.uiAnimate(GZ.microFeder, delay: 0.07) { [weak self] in
            self?.circleGroup.transform = CGAffineTransform(translationX: 0, y: -4)
        } completion: { [weak self] in
            GZ.uiAnimate(GZ.microFeder) { self?.circleGroup.transform = .identity }
        }

        if let chip = countChip, !chip.isHidden {
            GZ.uiAnimate(GZ.microFeder, delay: 0.12) {
                chip.transform = CGAffineTransform(scaleX: 1.22, y: 1.22)
            } completion: {
                GZ.uiAnimate(GZ.microFeder) { chip.transform = .identity }
            }
        }
    }

    fileprivate func applyRingColor() {
        circle.layer.borderColor = (isNear ? GZ.uiOk : GZ.uiInk3)
            .resolvedColor(with: traitCollection).cgColor
    }
}

// MARK: - Freier Snap-Pin

final class FreeSnapPinView: MLNAnnotationView {
    static let reuseID = "gz.freesnap"

    static let stage = CGSize(width: 44, height: 50)
    /// Spitze des Stiels — der eigentliche Ankerpunkt des Pins.
    static let tipY: CGFloat = 44
    private static let photoSize: CGFloat = 32

    /// Wo das Foto im Pin sitzt. Der Morph in den Betrachter geht von genau
    /// dieser Flaeche aus — nicht von der Buehne, die auch den Stiel umfasst.
    static let photoFrame = CGRect(x: (stage.width - photoSize) / 2, y: 0,
                                   width: photoSize, height: photoSize)

    /// Dieselbe Flaeche, aber aus der Ankerposition gerechnet statt aus einer
    /// vorhandenen Ansicht gelesen. Ein frisch aufgenommener Snap fliegt aus dem
    /// Sucher an seinen Platz, bevor sein Pin ueberhaupt gezeichnet ist — waere
    /// die Rechnung an die Ansicht gebunden, gaebe es in genau dem Moment kein
    /// Ziel. Der Anker ist die Stielspitze.
    static func photoFrame(atAnchor point: CGPoint) -> CGRect {
        photoFrame.offsetBy(dx: point.x - stage.width / 2, dy: point.y - tipY)
    }

    private let content = UIView()
    private let photo = makeRoundPhotoView(size: 32, ring: 1.5)
    private let stem = CAShapeLayer()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(origin: .zero, size: Self.stage)
        scalesWithViewingDistance = false
        isDraggable = false
        backgroundColor = .clear
        // Anker ist die Stiel-Spitze unten, nicht die Bildmitte.
        centerOffset = CGVector(dx: 0, dy: -(Self.tipY - Self.stage.height / 2))

        content.frame = bounds
        addSubview(content)

        // Stiel zuerst: liegt unter dem Foto.
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 16, y: 26))
        path.addLine(to: CGPoint(x: 28, y: 26))
        path.addLine(to: CGPoint(x: 22, y: Self.tipY))
        path.close()
        stem.path = path.cgPath
        stem.fillColor = UIColor.white.cgColor
        stem.shadowColor = UIColor.black.cgColor
        stem.shadowOpacity = 0.18
        stem.shadowRadius = 3
        stem.shadowOffset = CGSize(width: 0, height: 2)
        content.layer.addSublayer(stem)

        let holder = makeShadowHolder(photo)
        holder.frame = CGRect(x: (Self.stage.width - Self.photoSize) / 2, y: 0,
                              width: Self.photoSize, height: Self.photoSize)
        content.addSubview(holder)

        // Wachsen/Schrumpfen muss um die Stiel-Spitze passieren, sonst wandert
        // der Pin von seinem Ankerpunkt weg.
        content.layer.anchorPoint = CGPoint(x: 0.5, y: Self.tipY / Self.stage.height)
        content.layer.position = CGPoint(x: Self.stage.width / 2, y: Self.tipY)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ state: FreeSnapPinState) {
        photo.image = state.photo
    }

    /// Frisch aufgenommen: der Pin ploppt an der Aufnahme-Position auf.
    /// Der Pin setzt sich. Zwei Faelle, ein Aufruf:
    ///
    /// - **Nach einem Flug** (`landing`): das Bild ist gerade aus dem Sucher
    ///   hierher gewandert und uebergibt. Ein Sprung aus dem Nichts waere hier
    ///   falsch — das Foto steht bereits in voller Groesse da, es waere eine
    ///   zweite Ankunft fuer dasselbe Bild. Bleibt ein kurzer Federstoss, der
    ///   die Landung quittiert.
    ///
    ///   Der Prototyp laesst hier zusaetzlich den Stiel nachwachsen. Drei
    ///   Anlaeufe (Layer-Transform mit und ohne eigene Bounds, mit Anker am
    ///   Stielansatz) kamen im Bild nie an — 40 ms nach der Landung stand er
    ///   jedesmal voll da. Statt den Effekt stehen zu lassen und Wirkung zu
    ///   behaupten, ist er hier NICHT drin.
    /// - **Ohne Flug**: der Pin kommt aus dem Nichts (etwa weil die Stelle beim
    ///   Ausloesen ausserhalb des Schirms lag) und springt wie bisher herein.
    func playPopIn(landing: Bool = false) {
        if landing {
            content.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
            GZ.uiAnimate(GZ.microFeder) { [weak self] in
                self?.content.transform = .identity
            }
            return
        }
        content.transform = CGAffineTransform(scaleX: 0.15, y: 0.15)
        GZ.uiAnimate(GZ.elementFeder) { [weak self] in
            self?.content.transform = .identity
        }
    }
}

// MARK: - Puck

/// Blauer Standort-Punkt mit Genauigkeits-Ring.
///
/// Der Ring ist ECHT: sein Radius kommt aus `MLNMapView.metersPerPoint(atLatitude:)`,
/// nicht aus einer nachgerechneten Kachelformel (v1 rechnete mit 256er-Kacheln
/// und lag dadurch um Faktor 2 daneben — SPEC 15).
final class PuckView: MLNAnnotationView {
    static let reuseID = "gz.puck"

    /// Buehne so gross wie der groesste erlaubte Ring (v1-Deckel: 120 pt Radius).
    static let maxRingRadius: CGFloat = 120
    private static let coreSize: CGFloat = 22

    private let ring = UIView()
    private let core = UIView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        let stage = Self.maxRingRadius * 2
        frame = CGRect(x: 0, y: 0, width: stage, height: stage)
        scalesWithViewingDistance = false
        isDraggable = false
        isEnabled = false
        isUserInteractionEnabled = false
        backgroundColor = .clear

        ring.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
        ring.center = CGPoint(x: stage / 2, y: stage / 2)
        ring.backgroundColor = GZ.uiAccent.withAlphaComponent(0.08)
        ring.layer.borderColor = GZ.uiAccent.withAlphaComponent(0.25).cgColor
        ring.layer.borderWidth = 1
        ring.isUserInteractionEnabled = false
        ring.alpha = 0
        addSubview(ring)

        core.frame = CGRect(x: 0, y: 0, width: Self.coreSize, height: Self.coreSize)
        core.center = CGPoint(x: stage / 2, y: stage / 2)
        core.backgroundColor = GZ.uiAccent
        core.layer.cornerRadius = Self.coreSize / 2
        core.layer.borderWidth = 3
        core.layer.borderColor = UIColor.white.cgColor
        core.layer.shadowColor = GZ.uiAccent.cgColor
        core.layer.shadowOpacity = 0.45
        core.layer.shadowRadius = 6
        core.layer.shadowOffset = .zero
        addSubview(core)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// `radiusPoints` = Genauigkeit in Punkten der aktuellen Projektion.
    /// Unter 14 pt bleibt der Ring aus (v1-Regel) — sonst klebt er am Kern.
    func setAccuracyRadius(_ radiusPoints: CGFloat) {
        let radius = min(Self.maxRingRadius, max(0, radiusPoints))
        let size = radius * 2
        ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ring.center = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.layer.cornerRadius = radius
        ring.alpha = radius > 14 ? 1 : 0
    }
}
