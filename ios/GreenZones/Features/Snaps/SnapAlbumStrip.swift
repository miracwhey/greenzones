import GreenZonesKit
import SwiftUI

/// Album-Streifen im Spot-Blatt (Mockup `spot-sheet-v5`, von Leon abgenommen).
///
/// Reihenfolge im Blatt ist gelockt: Kopf · Legal-Zeile · **Album** ·
/// Einladung/„Wer kommt" · Teilnehmer · Aktionen. Das Album steht ueber der
/// Einladung, weil es beim Oeffnen zuerst gewinnen soll (Lock A).
///
/// Der blaue Snap-Knopf ist IMMER die erste Kachel und IMMER aktiv: aus dem
/// Blatt heraus ist die Aufnahme explizit an diesem Spot, egal wie weit weg man
/// gerade steht (Leon-Korrektur zum Naehe-Zwang).
struct SnapAlbumSection: View {
    let model: CommunityModel
    let spot: Spot

    private var snaps: [Snap] { model.album(of: spot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Zaehler in der Sektion (Lock D): ohne Wischen sichtbar, wie viel
            // da ist. Bei leerem Album waere „· 0" nur Buchhaltung.
            SPSection(text: snaps.isEmpty ? "Album" : "Album · \(snaps.count)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    SnapCTATile { model.openCamera(spotId: spot.id) }
                    if snaps.isEmpty {
                        // Einladung zum Anfangen, kein grauer Platzhalter-Kasten.
                        Text("Noch keine Snaps — sei die/der Erste.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(GZ.ink2)
                            .lineSpacing(3)
                            .frame(width: 232, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 2)
                    }
                    ForEach(Array(snaps.enumerated()), id: \.element.id) { index, snap in
                        SnapTileView(snap: snap,
                                     caption: model.snapCaption(snap),
                                     image: model.thumbs.image(id: snap.id))
                            // Lage melden statt herleiten: der Streifen
                            // scrollt, eine aus Index und Abstaenden gerechnete
                            // Position waere nach dem ersten Wischen falsch.
                            .background {
                                GeometryReader { proxy in
                                    let frame = proxy.frame(in: .global)
                                    Color.clear.onChange(of: frame, initial: true) { _, new in
                                        model.noteSnapRect(snap.id,
                                            MorphRect(rect: new,
                                                      cornerRadius: SnapTileView.cornerRadius))
                                    }
                                }
                            }
                            // Solange ihr Bild woanders ist, bleibt die Kachel
                            // leer — sonst laege dasselbe Foto zweimal da. Die
                            // Herkunft steht genau so lange, wie das gilt: vom
                            // Oeffnen bis zur Rueckkehr (das Vollbild ist auf
                            // dem Rueckweg schon fort und taugt nicht als Mass).
                            .opacity(model.morphSnapId == snap.id ? 0 : 1)
                            // Auch fuer VoiceOver: eine Kachel, deren Bild
                            // gerade im Vollbild liegt, ist keine Kachel. Der
                            // Bedienungstest misst daran, dass die Herkunft
                            // nach der Rueckkehr wirklich faellt — an der
                            // Deckkraft allein koennte er das nicht, ein
                            // unsichtbares Element bleibt trefferbar.
                            .accessibilityHidden(model.morphSnapId == snap.id)
                            .onTapGesture {
                                GZ.haptic()
                                model.openViewer(.spot(spotId: spot.id), index: index)
                            }
                            .transition(.asymmetric(insertion: .scale(scale: 0.55).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                }
                .padding(.vertical, 2)
            }
            // Der Streifen liegt kantenbuendig im Blatt: die letzte Kachel darf
            // beim Wischen unter den Rand laufen, sonst wirkt er beschnitten.
            .scrollClipDisabled()
            .animation(GZ.elementSpring, value: snaps.map(\.id))
        }
        // Schluessel mit Pfad, nicht nur mit Id: ein nachgeladener Thumb aendert
        // die Id-Liste nicht (siehe `RootView`).
        .task(id: snaps.map { "\($0.id)|\($0.thumbPath ?? "")" }) {
            await model.thumbs.load(snaps)
        }
    }
}

/// Erste Kachel des Streifens: der Weg zur Kamera.
struct SnapCTATile: View {
    let action: () -> Void

    var body: some View {
        Button(action: { GZ.haptic(); action() }) {
            VStack(spacing: 8) {
                // Ausloeser-Zeichen statt Kamera-Symbol: dasselbe Bild wie der
                // Knopf in der Kamera selbst.
                ZStack {
                    Circle().strokeBorder(Color.white, lineWidth: 2.2)
                        .frame(width: 22, height: 22)
                    Circle().fill(Color.white).frame(width: 13, height: 13)
                }
                Text("Snap")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 84, height: 112)
            .background(GZ.accent, in: .rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Snap aufnehmen")
        .accessibilityIdentifier("gz.snap.cta")
    }
}

/// Eine Album-Kachel: Bild, wer und wann — und die eine Marke, die etwas
/// aussagt, das man dem Bild nicht ansieht.
struct SnapTileView: View {
    let snap: Snap
    let caption: String
    let image: UIImage?

    /// Eine Quelle fuer den Eckenradius: die Kachel rundet damit, und der Morph
    /// startet mit demselben Wert. Zwei Zahlen liefen auseinander, sobald eine
    /// von beiden angefasst wird — sichtbar als Kante, die im ersten Frame springt.
    static let cornerRadius: CGFloat = 14

    /// Sichtbarkeits-Marke NUR auf fremden Kacheln (Lock C): sie sagt, WER den
    /// Snap sieht — bei eigenen weiss ich das selbst.
    private var showsAudience: Bool { !snap.isMine && snap.scope == .feed }
    /// Eigener Snap, dessen Upload noch aussteht. „wartet" statt stiller
    /// Vollzugs-Behauptung (SPEC 10.2).
    private var isWaiting: Bool { snap.isMine && snap.uploadState.isOutstanding }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 112)
            } else {
                // Bild noch nicht da: ruhige Flaeche statt Fehlbild. Der Snap
                // selbst ist echt, nur seine Vorschau fehlt noch.
                Rectangle().fill(SP.tile)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.68)],
                           startPoint: .center, endPoint: .bottom)
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
        }
        .frame(width: 84, height: 112)
        .overlay(alignment: .topTrailing) {
            if showsAudience {
                tileBadge("alle Freunde")
            } else if isWaiting {
                tileBadge("wartet")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(GZ.stroke, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(showsAudience ? "\(caption), alle Freunde"
                            : (isWaiting ? "\(caption), wartet auf Upload" : caption))
    }

    private func tileBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 19)
            .background(Color.black.opacity(0.62), in: .capsule)
            .padding(5)
    }
}
