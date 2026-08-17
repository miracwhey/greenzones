import UIKit
import CoreLocation
import MapLibre

/// Was ein Spot-Pin ueber seinen Spot wissen muss. Aus dem Store abgeleitet, damit
/// SwiftUI-Diffing `updateUIView` ausloest, sobald ein Snap dazukommt.
struct SpotPinState: Equatable {
    let id: String
    let emoji: String
    let isNear: Bool
    /// Bis zu 3 Fotos fuer den Stack, neuester zuerst.
    let stackPhotos: [String]
    /// Alle Snaps des Spots — Variante A zeigt den Rest als „+n"-Chip.
    let snapCount: Int
    /// Identitaet des vordersten Snaps — daran haengt die Wachstums-Animation.
    let frontSnapID: UUID?
    let latitude: Double
    let longitude: Double

    var hasSnaps: Bool { !stackPhotos.isEmpty }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(spot: Spot, snaps: [Snap]) {
        id = spot.id
        emoji = spot.emoji
        isNear = spot.isNear
        stackPhotos = snaps.prefix(3).map(\.photo)
        snapCount = snaps.count
        frontSnapID = snaps.first?.id
        latitude = spot.coordinate.latitude
        longitude = spot.coordinate.longitude
    }
}

/// Freier Snap ohne Spot — eigener Pin an der Aufnahme-Position.
struct FreeSnapPinState: Equatable {
    let id: UUID
    let photo: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(free: FreeSnap) {
        id = free.id
        photo = free.snap.photo
        latitude = free.latitude
        longitude = free.longitude
    }
}

// MARK: - Annotationen
//
// Pins liegen als MLNAnnotationView IN der Karte, nicht als SwiftUI-Overlay
// darueber: MapLibre positioniert sie in derselben Render-Passe wie die Tiles —
// damit schwenken sie framegenau mit, ohne Nachzieh-Lag eines separaten
// `convert(coordinate:)`-Overlays.

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
    let snapID: UUID

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

/// Rundes Foto mit weissem Ring und weichem Schatten — der Grundstein beider
/// Snap-Pin-Formen. Kleine Kreise (≤22 pt) bekommen einen duenneren Ring, sonst
/// frisst der Rand das Foto auf.
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

/// Quadrat um einen Mittelpunkt — die Pin-Geometrie ist durchgehend zentriert
/// gedacht (der Annotation-Anker liegt in der Mitte der View).
private func centeredRect(_ center: CGPoint, _ size: CGFloat) -> CGRect {
    CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
}

/// Glass-Chip (Emoji oder „+n") in der Design-Sprache: ultraThin + 1-px-Stroke.
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

// MARK: - Spot-Pin

/// Drei Looks in einer View: `PinStyle.current` steht fuer den ganzen Lauf fest,
/// also baut `init` genau die Subviews der gewaehlten Variante.
///
/// Gemeinsame Buehne fuer alle Varianten: 84×72, Anker in der Mitte (42/36).
final class SpotPinView: MLNAnnotationView {
    static let reuseID = "gz.spot"

    private static let stageSize = CGSize(width: 84, height: 72)
    private static let anchor = CGPoint(x: 42, y: 36)
    /// Kollabierter Kreis (40) relativ zur gebauten Basis (44) — als Transform,
    /// damit der Uebergang federn kann statt zu springen.
    private static let collapsedCircleScale: CGFloat = 40.0 / 44.0

    /// Alles Sichtbare haengt hier drin: MapLibre fasst die `transform` der
    /// AnnotationView selbst an, eigene Animationen laufen deshalb eine Ebene tiefer.
    private let content = UIView()
    private let style = PinStyle.current

    // Emoji-Ebene: leerer Spot (alle Varianten), Anker-Pin (A), kollabierter Pin (C).
    private let circleGroup = UIView()
    private let circle = UIView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let emojiLabel = UILabel()
    /// Nur C: 16-pt-Foto-Dot am kollabierten Emoji-Kreis.
    private var dotHolder: UIView?
    private let dotPhoto = makeRoundPhotoView(size: 16, ring: 1.5)

    // Foto-Ebene: A = 2er-Faecher, B = ein Foto, C = 3er-Stack.
    private let photoGroup = UIView()
    private var photoHolders: [UIView] = []
    private var photoViews: [UIImageView] = []
    private let chipLabel = UILabel()
    private var emojiChip: UIView?
    private let countLabel = UILabel()
    private var countChip: UIView?

    private var isNear = true
    private var hasSnaps = false
    private var collapsed = false
    private var lastFrontSnapID: UUID?
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
        // Reihenfolge = z-Ordnung: bei A liegen die Foto-Kreise HINTER dem Emoji.
        content.addSubview(photoGroup)
        content.addSubview(circleGroup)

        // A ist der Emoji-Anker mit 40 pt, sonst der 44-pt-Kreis der Basis-Spec.
        buildCircle(diameter: style == .a ? 40 : 44)

        switch style {
        case .a: buildFan()
        case .b: buildSinglePhoto()
        case .c: buildStack(); buildCollapsedDot()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: Aufbau

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

    /// A: zwei 22-pt-Foto-Kreise, oben rechts aufgefaechert, hinter dem Emoji.
    private func buildFan() {
        let centers = [CGPoint(x: 58, y: 20), CGPoint(x: 68, y: 27)]
        // Rueckwaerts anlegen: Index 0 (neuester) landet oben auf dem Faecher.
        for index in stride(from: centers.count - 1, through: 0, by: -1) {
            let photo = makeRoundPhotoView(size: 22, ring: 1.5)
            let holder = makeShadowHolder(photo)
            holder.frame = centeredRect(centers[index], 22)
            photoGroup.addSubview(holder)
            photoHolders.insert(holder, at: 0)
            photoViews.insert(photo, at: 0)
        }
        // „+n" fuer alles jenseits der zwei gezeigten Fotos.
        countLabel.font = .preferredFont(forTextStyle: .caption2)
        countLabel.textColor = GZ.uiInk
        let chip = makeGlassChip(frame: CGRect(x: 46, y: 44, width: 24, height: 15),
                                 label: countLabel, corner: 7.5)
        // Ueber dem Emoji-Kreis, sonst verschwindet der Chip dahinter.
        content.addSubview(chip)
        countChip = chip
    }

    /// B: ein 30-pt-Foto (neuester Snap) + 18-pt-Emoji-Chip unten links.
    private func buildSinglePhoto() {
        let photo = makeRoundPhotoView(size: 30, ring: 2)
        let holder = makeShadowHolder(photo)
        holder.frame = centeredRect(Self.anchor, 30)
        photoGroup.addSubview(holder)
        photoHolders = [holder]
        photoViews = [photo]
        buildEmojiChip(size: 18, center: CGPoint(x: 31, y: 47), font: 10)
    }

    /// C: der bekannte 3er-Stack, nur leiser — 26 pt, 9 pt Versatz.
    private func buildStack() {
        let size: CGFloat = 26
        let offset: CGFloat = 9
        let startX = Self.anchor.x - (size + 2 * offset) / 2
        for index in stride(from: 2, through: 0, by: -1) {
            let photo = makeRoundPhotoView(size: size, ring: 2)
            let holder = makeShadowHolder(photo)
            holder.frame = CGRect(x: startX + CGFloat(index) * offset,
                                  y: Self.anchor.y - size / 2, width: size, height: size)
            photoGroup.addSubview(holder)
            // Index 0 = neuester: als Letztes in die Listen, Reihenfolge bleibt
            // damit „0 = vorne".
            photoHolders.insert(holder, at: 0)
            photoViews.insert(photo, at: 0)
        }
        buildEmojiChip(size: 16,
                       center: CGPoint(x: startX + 6, y: Self.anchor.y + size / 2 + 2),
                       font: 9)
    }

    private func buildEmojiChip(size: CGFloat, center: CGPoint, font: CGFloat) {
        chipLabel.font = .systemFont(ofSize: font)
        let chip = makeGlassChip(frame: centeredRect(center, size), label: chipLabel,
                                 corner: size / 2)
        photoGroup.addSubview(chip)
        emojiChip = chip
    }

    private func buildCollapsedDot() {
        let holder = makeShadowHolder(dotPhoto)
        holder.frame = centeredRect(CGPoint(x: 59, y: 19), 16)
        circleGroup.addSubview(holder)
        dotHolder = holder
    }

    // MARK: Zustand

    func configure(_ state: SpotPinState) {
        emojiLabel.text = state.emoji
        chipLabel.text = state.emoji
        isNear = state.isNear
        applyRingColor()
        hasSnaps = state.hasSnaps

        for (index, holder) in photoHolders.enumerated() {
            let photo = index < state.stackPhotos.count ? state.stackPhotos[index] : nil
            holder.isHidden = photo == nil
            photoViews[index].image = photo.flatMap { GZ.photo($0) }
        }
        dotPhoto.image = state.stackPhotos.first.flatMap { GZ.photo($0) }

        switch style {
        case .a:
            // Emoji IST der Pin: der Kreis bleibt, die Fotos sind nur Beiwerk.
            circleGroup.alpha = 1
            photoGroup.alpha = state.hasSnaps ? 1 : 0
            let rest = state.snapCount - photoHolders.count
            countChip?.isHidden = rest <= 0
            countLabel.text = "+\(max(rest, 0))"
        case .b:
            circleGroup.alpha = state.hasSnaps ? 0 : 1
            photoGroup.alpha = state.hasSnaps ? 1 : 0
        case .c:
            applyCollapse(animated: false)
        }

        // Neuer Snap am Spot: der vordere Thumbnail waechst herein — aber nicht
        // beim ersten Aufbau, sonst zappelt die Karte beim Start.
        let grew = configured && state.frontSnapID != nil && state.frontSnapID != lastFrontSnapID
        lastFrontSnapID = state.frontSnapID
        configured = true
        if grew { playStackGrow() }
    }

    /// Variante C: Karten-Zoom entscheidet ueber Stack oder Emoji-Kreis.
    func setCollapsed(_ value: Bool, animated: Bool) {
        guard style == .c, value != collapsed || !configured else { return }
        collapsed = value
        applyCollapse(animated: animated)
    }

    private func applyCollapse(animated: Bool) {
        guard style == .c else { return }
        // Ohne Snaps gibt es nichts zu kollabieren — der leere Pin IST der Kreis.
        let showCircle = collapsed || !hasSnaps
        let showDot = collapsed && hasSnaps
        let apply = {
            self.circleGroup.alpha = showCircle ? 1 : 0
            self.circleGroup.transform = showCircle ? .identity : CGAffineTransform(scaleX: 0.7, y: 0.7)
            self.photoGroup.alpha = showCircle ? 0 : 1
            self.photoGroup.transform = showCircle ? CGAffineTransform(scaleX: 0.7, y: 0.7) : .identity
            let scale = showDot ? Self.collapsedCircleScale : 1
            self.circle.transform = CGAffineTransform(scaleX: scale, y: scale)
            self.dotHolder?.alpha = showDot ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.4, delay: 0,
                           usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: apply)
        } else {
            apply()
        }
    }

    private func playStackGrow() {
        guard let front = photoHolders.first else { return }
        front.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        UIView.animate(withDuration: 0.45, delay: 0,
                       usingSpringWithDamping: 0.85, initialSpringVelocity: 0.5,
                       options: [.allowUserInteraction]) {
            front.transform = .identity
        }
    }

    /// Ring: ok-gruen wenn nah, ink-3 wenn fern.
    private func applyRingColor() {
        circle.layer.borderColor = (isNear ? GZ.uiOk : GZ.uiInk3)
            .resolvedColor(with: traitCollection).cgColor
    }

    /// Ring-Farbe haengt an dynamischen UIColors — bei Hell/Dunkel-Wechsel neu setzen.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyRingColor()
    }
}

// MARK: - Freier Snap-Pin

final class FreeSnapPinView: MLNAnnotationView {
    static let reuseID = "gz.freesnap"

    private static let stage = CGSize(width: 44, height: 50)
    /// Spitze des Stiels — der eigentliche Ankerpunkt des Pins.
    private static let tipY: CGFloat = 44
    private static let photoSize: CGFloat = 32
    /// Variante C unter der Schwelle: 22 statt 32 pt.
    private static let collapsedScale: CGFloat = 22.0 / 32.0

    private let content = UIView()
    private let photo = makeRoundPhotoView(size: 32, ring: 1.5)
    private let stem = CAShapeLayer()
    private var collapsed = false

    private var baseTransform: CGAffineTransform {
        collapsed ? CGAffineTransform(scaleX: Self.collapsedScale, y: Self.collapsedScale) : .identity
    }

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

        // Schrumpfen muss um die Stiel-Spitze passieren, sonst wandert der Pin
        // beim Zoom-Wechsel von seinem Ankerpunkt weg.
        content.layer.anchorPoint = CGPoint(x: 0.5, y: Self.tipY / Self.stage.height)
        content.layer.position = CGPoint(x: Self.stage.width / 2, y: Self.tipY)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ state: FreeSnapPinState) {
        photo.image = GZ.photo(state.photo)
    }

    /// Variante C: unter der Zoom-Schwelle schrumpft der freie Pin mit.
    func setCollapsed(_ value: Bool, animated: Bool) {
        guard PinStyle.current == .c, value != collapsed else { return }
        collapsed = value
        if animated {
            UIView.animate(withDuration: 0.4, delay: 0,
                           usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.content.transform = self.baseTransform
            }
        } else {
            content.transform = baseTransform
        }
    }

    /// Frisch aufgenommen: der Pin ploppt an der Aufnahme-Position auf.
    func playPopIn() {
        let base = baseTransform
        content.transform = base.scaledBy(x: 0.15, y: 0.15)
        UIView.animate(withDuration: 0.5, delay: 0,
                       usingSpringWithDamping: 0.85, initialSpringVelocity: 0.6,
                       options: [.allowUserInteraction]) {
            self.content.transform = base
        }
    }
}

// MARK: - Puck

final class PuckView: MLNAnnotationView {
    static let reuseID = "gz.puck"

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        scalesWithViewingDistance = false
        isDraggable = false
        isEnabled = false
        backgroundColor = GZ.uiAccent
        layer.cornerRadius = 11
        layer.borderWidth = 3
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = GZ.uiAccent.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
