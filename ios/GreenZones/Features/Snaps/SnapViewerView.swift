import GreenZonesKit
import SwiftUI

/// Vollbild eines Snaps (Port des Spike-Viewers, jetzt mit echtem Bestand).
///
/// Das Original kommt erst hier: im Album liegen nur Vorschaubilder, fremde
/// Originale laedt der Coordinator auf Zuruf nach. Solange es unterwegs ist,
/// steht die Vorschau gross — besser ein weiches Bild als ein leerer Rahmen.
struct SnapViewerView: View {
    let model: CommunityModel
    let source: SnapSource
    let startIndex: Int
    /// Screenshot-Schalter: faehrt den Ausblenden-Dialog ueber denselben Zustand an,
    /// den das Kontextmenue setzt.
    var autoHide: Bool = false

    @State private var index: Int
    @State private var dragY: CGFloat = 0
    @State private var hiding: Snap?
    @State private var deleting: Snap?
    @State private var originals: [String: UIImage] = [:]
    /// Das Original kam nicht — dann steht hier die Vorschau, und der Betrachter
    /// sagt es. Ein weiches Bild ohne Erklaerung sieht sonst nach schlechter
    /// Kamera aus statt nach fehlender Verbindung.
    @State private var missingOriginal = false
    @State private var routed = false

    init(model: CommunityModel, source: SnapSource, startIndex: Int, autoHide: Bool = false) {
        self.model = model
        self.source = source
        self.startIndex = startIndex
        self.autoHide = autoHide
        _index = State(initialValue: startIndex)
    }

    private var snaps: [Snap] { model.visibleSnaps(source) }

    private var current: Snap? {
        guard !snaps.isEmpty else { return nil }
        return snaps[min(max(index, 0), snaps.count - 1)]
    }

    /// Foto folgt dem Finger, der Grund blendet weg — Ziehen nach unten schliesst.
    private var backdropOpacity: Double {
        1 - min(Double(max(dragY, 0)) / 420.0, 0.55)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backdropOpacity).ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(snaps.enumerated()), id: \.element.id) { position, snap in
                    photoPage(snap)
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // KEIN `ignoresSafeArea` hier: die Seitendarstellung haelt ihre
            // eigenen Raender, das Bild sitzt zwischen den Systemraendern. Genau
            // diese Flaeche ist `SPScreen.contentBounds`, und dorthin zielt der
            // Morph — im Bild nachgemessen, nicht angenommen.
            .offset(y: dragY)
            .scaleEffect(1 - min(max(dragY, 0) / 2600, 0.08))
            .highPriorityGesture(dismissDrag)
            // Solange das Bild noch unterwegs ist, gehoert es dem Flieger.
            .opacity(model.morphInFlight ? 0 : 1)

            VStack(spacing: 0) {
                topBar
                if missingOriginal {
                    Text("Original nicht geladen — du siehst die Vorschau.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.45), in: .capsule)
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            // Chrome kommt NACH dem Bild und geht VOR ihm (Choreografie des
            // abgenommenen Prototyps): waehrend das Foto noch fliegt, wuerde
            // eine Kopfzeile ueber halbem Weg den Blick vom Bild wegziehen.
            .opacity(dragY > 8 || model.morphInFlight ? 0 : 1)
            .animation(GZ.microSpring, value: model.morphInFlight)
        }
        .statusBarHidden(true)
        // `.alert` statt `.confirmationDialog`: Letzterer verschluckt unter
        // iOS 26 den Abbrechen-Knopf (Screenshot-Beweis aus dem Spike).
        .alert("Bild ausblenden?", isPresented: Binding(get: { hiding != nil },
                                                    set: { if !$0 { hiding = nil } }),
               presenting: hiding) { snap in
            Button("Ausblenden", role: .destructive) {
                hiding = nil
                hide(snap)
            }
            // Der zweite Weg gehoert hierher, nicht drei Blaetter weiter in die
            // Freundesliste: wer ein Bild wegnimmt, meint oft nicht das Bild.
            if let name = authorName(snap) {
                Button("Ausblenden und \(name) entfernen", role: .destructive) {
                    hiding = nil
                    hide(snap)
                    model.run { try await model.sync.removeFriend(id: snap.authorId) }
                }
            }
            Button("Abbrechen", role: .cancel) { hiding = nil }
        } message: { snap in
            Text(authorName(snap).map {
                "Das Bild verschwindet dauerhaft für dich — auch nach dem nächsten Abgleich. Wer gar nichts mehr von \($0) sehen will, entfernt \($0)."
            } ?? "Das Bild verschwindet dauerhaft für dich.")
        }
        .alert("Bild löschen?", isPresented: Binding(get: { deleting != nil },
                                                     set: { if !$0 { deleting = nil } }),
               presenting: deleting) { snap in
            Button("Löschen", role: .destructive) {
                deleting = nil
                delete(snap)
            }
            Button("Abbrechen", role: .cancel) { deleting = nil }
        } message: { snap in
            Text(snap.isMine
                 ? "Das Bild verschwindet auch bei allen, die es sehen konnten."
                 : "Das Bild verschwindet aus deinem Spot — auch beim Autor.")
        }
        .task(id: current?.id) { await loadOriginal() }
        .onAppear(perform: applyAutoRoute)
    }

    @ViewBuilder
    private func photoPage(_ snap: Snap) -> some View {
        Group {
            if let image = originals[snap.id] ?? model.thumbs.image(id: snap.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.black
            }
        }
        .contextMenu {
            // Ausblenden gehoert an den Snap, nicht an die Person (Lock B) — und
            // nur fremde Bilder lassen sich ausblenden. Das eigene loescht man.
            if !snap.isMine {
                Button {
                    hiding = snap
                } label: {
                    Label("Ausblenden…", systemImage: "eye.slash")
                }
            }
            if model.canDelete(snap) {
                Button(role: .destructive) {
                    deleting = snap
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.32).onEnded { _ in GZ.haptic() }
        )
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text(current.map(model.snapCaption) ?? "")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let current, current.isMine, current.uploadState.isOutstanding {
                Text("wartet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(Color.white.opacity(0.16), in: .capsule)
            }
            Spacer(minLength: 0)
            // Die beiden Wege am Bild stehen sichtbar in der Kopfzeile. Bis zum
            // 18.08. gab es sie NUR im Kontextmenue des Fotos (langer Druck) —
            // Leon am Geraet: er hatte einen Snap gemacht, drueckte auf das Bild
            // und fand keinen Weg, es wieder loszuwerden. Eine Handlung, die man
            // nur findet, wenn man sie schon kennt, gibt es fuer den Benutzer
            // nicht. Das Kontextmenue bleibt als zweiter, gewohnter Weg.
            if let current {
                if !current.isMine {
                    chromeButton(icon: "eye.slash", label: "Bild ausblenden",
                                 identifier: "gz.viewer.hide") { hiding = current }
                }
                if model.canDelete(current) {
                    chromeButton(icon: "trash", label: "Bild löschen",
                                 identifier: "gz.viewer.delete") { deleting = current }
                }
            }
            chromeButton(icon: "xmark", label: "Schließen",
                         // Eigener Bezeichner: „Schließen" heisst auch der
                         // Ghost-Knopf im Blatt darunter — ein Test wuerde sonst
                         // den falschen treffen.
                         identifier: "gz.viewer.close") { model.closeCover() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    /// Runder Knopf der Kopfzeile — dieselbe Groesse und dasselbe Glas fuer
    /// alle drei, damit keiner wichtiger aussieht als der andere.
    private func chromeButton(icon: String, label: String, identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            GZ.haptic()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                // Nur vertikal greifen — horizontal blaettert weiter der TabView.
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragY = max(value.translation.height, 0)
            }
            .onEnded { value in
                if value.translation.height > 130 || value.predictedEndTranslation.height > 320 {
                    // Kein Rueckweg in die Kachel: der Finger hat das Bild
                    // gerade woanders hingezogen, ein Sprung zurueck an den
                    // Ausgangsort waere ein zweiter, widersprechender Weg.
                    model.dismissCover()
                } else {
                    withAnimation(GZ.sheetSpring) { dragY = 0 }
                }
            }
    }

    // MARK: - Aktionen

    /// Name des Autors, solange er als Freund bekannt ist. Fehlt er (fremder
    /// Snap aus einem geteilten Spot, dessen Autor nicht mein Freund ist), gibt
    /// es niemanden zu entfernen — dann bleibt es beim Ausblenden.
    private func authorName(_ snap: Snap) -> String? {
        guard !snap.isMine else { return nil }
        return model.friends.friend(id: snap.authorId)?.name
    }

    private func hide(_ snap: Snap) {
        let source = source
        model.run {
            try await model.snapSync.hide(snap)
            model.thumbs.forget(id: snap.id)
            // Der letzte Snap ist weg — dann gibt es hier nichts mehr zu sehen.
            // Das Bild ist fort — es gaebe keine Kachel mehr, in die es
            // zurueckfliegen koennte.
            if model.visibleSnaps(source).isEmpty { model.dismissCover() }
        }
    }

    private func delete(_ snap: Snap) {
        let source = source
        model.run {
            try await model.snapSync.delete(snap)
            model.thumbs.forget(id: snap.id)
            // Das Bild ist fort — es gaebe keine Kachel mehr, in die es
            // zurueckfliegen koennte.
            if model.visibleSnaps(source).isEmpty { model.dismissCover() }
        }
    }

    /// Original des sichtbaren Snaps holen — eigenes von der Platte, fremdes
    /// aus dem Cache oder frisch aus der Zone.
    private func loadOriginal() async {
        guard let snap = current else { return }
        if originals[snap.id] != nil {
            missingOriginal = false
            return
        }
        guard let url = await model.snapSync.original(of: snap) else {
            missingOriginal = true
            return
        }
        let path = url.path
        let data = await Task.detached(priority: .userInitiated) {
            FileManager.default.contents(atPath: path)
        }.value
        guard let data, let image = UIImage(data: data) else {
            missingOriginal = true
            return
        }
        originals[snap.id] = image
        missingOriginal = false
    }

    private func applyAutoRoute() {
        #if DEBUG
        guard autoHide, !routed else { return }
        routed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            hiding = current
        }
        #endif
    }
}
