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
    /// Screenshot-Schalter: faehrt den Melden-Dialog ueber denselben Zustand an,
    /// den das Kontextmenue setzt.
    var autoReport: Bool = false

    @State private var index: Int
    @State private var dragY: CGFloat = 0
    @State private var reporting: Snap?
    @State private var deleting: Snap?
    @State private var originals: [String: UIImage] = [:]
    /// Das Original kam nicht — dann steht hier die Vorschau, und der Betrachter
    /// sagt es. Ein weiches Bild ohne Erklaerung sieht sonst nach schlechter
    /// Kamera aus statt nach fehlender Verbindung.
    @State private var missingOriginal = false
    @State private var routed = false

    init(model: CommunityModel, source: SnapSource, startIndex: Int, autoReport: Bool = false) {
        self.model = model
        self.source = source
        self.startIndex = startIndex
        self.autoReport = autoReport
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
            .offset(y: dragY)
            .scaleEffect(1 - min(max(dragY, 0) / 2600, 0.08))
            .highPriorityGesture(dismissDrag)

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
            .opacity(dragY > 8 ? 0 : 1)
        }
        .statusBarHidden(true)
        // `.alert` statt `.confirmationDialog`: Letzterer verschluckt unter
        // iOS 26 den Abbrechen-Knopf (Screenshot-Beweis aus dem Spike).
        .alert("Snap melden?", isPresented: Binding(get: { reporting != nil },
                                                    set: { if !$0 { reporting = nil } }),
               presenting: reporting) { snap in
            Button("Melden", role: .destructive) {
                reporting = nil
                report(snap)
            }
            Button("Abbrechen", role: .cancel) { reporting = nil }
        } message: { _ in
            Text("Er wird für dich ausgeblendet und in der geteilten Zone gemeldet.")
        }
        .alert("Snap löschen?", isPresented: Binding(get: { deleting != nil },
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
                 : "Der Snap verschwindet aus deinem Spot — auch beim Autor.")
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
            // Melden gehoert an den Snap, nicht an die Person (Lock B) — und nur
            // fremde Bilder lassen sich melden.
            if !snap.isMine {
                Button {
                    reporting = snap
                } label: {
                    Label("Melden…", systemImage: "flag")
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
            Button {
                model.closeCover()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Schließen")
            // Eigener Bezeichner: „Schließen" heisst auch der Ghost-Knopf im
            // Blatt darunter — ein Test wuerde sonst den falschen treffen.
            .accessibilityIdentifier("gz.viewer.close")
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

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                // Nur vertikal greifen — horizontal blaettert weiter der TabView.
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragY = max(value.translation.height, 0)
            }
            .onEnded { value in
                if value.translation.height > 130 || value.predictedEndTranslation.height > 320 {
                    model.closeCover()
                } else {
                    withAnimation(GZ.spring) { dragY = 0 }
                }
            }
    }

    // MARK: - Aktionen

    private func report(_ snap: Snap) {
        let source = source
        model.run {
            try await model.snapSync.report(snap)
            model.thumbs.forget(id: snap.id)
            // Der letzte Snap ist weg — dann gibt es hier nichts mehr zu sehen.
            if model.visibleSnaps(source).isEmpty { model.closeCover() }
        }
    }

    private func delete(_ snap: Snap) {
        let source = source
        model.run {
            try await model.snapSync.delete(snap)
            model.thumbs.forget(id: snap.id)
            if model.visibleSnaps(source).isEmpty { model.closeCover() }
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
        guard autoReport, !routed else { return }
        routed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            reporting = current
        }
        #endif
    }
}
