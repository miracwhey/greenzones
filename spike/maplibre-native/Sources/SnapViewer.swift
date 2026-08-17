import SwiftUI

struct SnapViewer: View {
    /// Spot-Album oder einzelner freier Snap.
    let source: SnapSource
    let startIndex: Int
    let store: MockStore
    /// Screenshot-Schalter: oeffnet den Melden-Dialog ueber denselben State,
    /// den das Kontextmenue setzt.
    var autoReport: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var dragY: CGFloat = 0
    @State private var reportTarget: Snap?
    @State private var routed = false

    init(source: SnapSource, startIndex: Int, store: MockStore, autoReport: Bool = false) {
        self.source = source
        self.startIndex = startIndex
        self.store = store
        self.autoReport = autoReport
        _index = State(initialValue: startIndex)
    }

    private var snaps: [Snap] { store.visibleSnaps(source) }

    private var current: Snap? {
        guard !snaps.isEmpty else { return nil }
        return snaps[min(max(index, 0), snaps.count - 1)]
    }

    /// Foto folgt dem Finger, der Grund blendet weg — Drag-nach-unten schliesst.
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
                Spacer(minLength: 0)
            }
            .opacity(dragY > 8 ? 0 : 1)
        }
        .statusBarHidden(true)
        // .alert statt .confirmationDialog: Letzterer verschluckt unter iOS 26
        // den Cancel-Button visuell (Screenshot-Beweis mock_report v1).
        .alert(
            "Snap melden?",
            isPresented: Binding(
                get: { reportTarget != nil },
                set: { if !$0 { reportTarget = nil } })
        ) {
            Button("Melden", role: .destructive) {
                if let snap = reportTarget {
                    withAnimation(GZ.spring) { store.hide(snap) }
                }
                reportTarget = nil
                if snaps.isEmpty { dismiss() }
            }
            Button("Abbrechen", role: .cancel) { reportTarget = nil }
        } message: {
            Text("Er wird für dich ausgeblendet und dem Spot-Host gemeldet.")
        }
        .onAppear(perform: applyAutoRoute)
    }

    @ViewBuilder
    private func photoPage(_ snap: Snap) -> some View {
        Group {
            if let image = GZ.photo(snap.photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.black
            }
        }
        .contextMenu {
            Button {
                reportTarget = snap
            } label: {
                Label("Melden…", systemImage: "flag")
            }
            // Loeschen nur der Autor (im Mockup: meine eigenen Snaps).
            if snap.author.isMe {
                Button(role: .destructive) {
                    withAnimation(GZ.spring) { store.delete(snap) }
                    if snaps.isEmpty { dismiss() }
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
            Text(current?.caption ?? "")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
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
                    dismiss()
                } else {
                    withAnimation(GZ.spring) { dragY = 0 }
                }
            }
    }

    private func applyAutoRoute() {
        guard autoReport, !routed else { return }
        routed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            reportTarget = current
        }
    }
}
