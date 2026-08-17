import SwiftUI

/// Kamera und Viewer teilen sich EINE Praesentation: zwei `fullScreenCover` an
/// derselben View schliessen einander aus — die zweite gewinnt, die erste zuendet nie.
enum SnapCover: Identifiable, Equatable {
    case camera
    /// `report` faehrt den Melden-Dialog direkt an (Screenshot-Schalter). Der
    /// Wert reist IM Item mit — ein daneben liegender `@State` kaeme im
    /// Praesentations-Closure zu spaet an.
    case viewer(index: Int, report: Bool = false)

    var id: String {
        switch self {
        case .camera: return "camera"
        case .viewer(let index, let report): return "viewer-\(index)-\(report)"
        }
    }
}

struct SpotSheet: View {
    let spot: Spot
    let store: MockStore
    /// Screenshot-/Demo-Schalter: faehrt beim Erscheinen denselben Zustand an,
    /// den ein Tap setzen wuerde.
    var autoRoute: MockRoute = .map

    @State private var cover: SnapCover?
    @State private var routed = false

    private var snaps: [Snap] { store.visibleSnaps(spot.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                legalRow
                snapStrip
                participantsRow
                inviteFooter
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // v1 nutzt fuer das modale Blatt `--glass-strong`, nicht das duenne Glas
        // der Chips — sonst frisst die Karte darunter die Lesbarkeit.
        .presentationBackground(.regularMaterial)
        .overlay(alignment: .bottom) { toast }
        .fullScreenCover(item: $cover) { which in
            switch which {
            case .camera:
                // Aus dem Sheet ist der Snap immer explizit AN diesen Spot.
                SnapCamera(context: .spot(spot)) {
                    cover = nil
                    // Erst wenn das Cover zu ist, faellt die neue Kachel in den Strip —
                    // sonst laeuft die Feder hinter dem Vollbild ab und niemand sieht sie.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                        withAnimation(GZ.spring) { _ = store.addSnap(spotID: spot.id) }
                    }
                }
            case .viewer(let index, let report):
                SnapViewer(source: .spot(spot.id), startIndex: index,
                           store: store, autoReport: report)
            }
        }
        .onAppear(perform: applyAutoRoute)
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(spot.emoji).font(.system(size: 32))
            VStack(alignment: .leading, spacing: 3) {
                Text(spot.name)
                    .font(.headline)
                    .foregroundStyle(GZ.ink)
                Text("\(spot.participants.count) Freunde · \(spot.distanceLabel)")
                    .font(.caption)
                    .foregroundStyle(GZ.ink2)
            }
            Spacer(minLength: 0)
        }
    }

    /// Legal-Status in der v1-StatusBar-Aesthetik: Dot mit Glow-Ring, Titel 15/650,
    /// Sekundaerzeile 12 in ink-2.
    private var legalRow: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(GZ.ok.opacity(0.18))
                    .frame(width: 40, height: 40)
                Circle()
                    .fill(GZ.ok)
                    .frame(width: 30, height: 30)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.legalTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GZ.ink)
                Text(spot.legalSub)
                    .font(.system(size: 12))
                    .foregroundStyle(GZ.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .glassCard(radius: 18)
    }

    // MARK: Snap-Strip

    private var snapStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                snapCTA
                if snaps.isEmpty {
                    Text("Noch keine Snaps — sei die/der Erste.")
                        .font(.caption)
                        .foregroundStyle(GZ.ink2)
                        // Feste Breite + freie Hoehe: im horizontalen ScrollView
                        // wuerde der Satz sonst einzeilig abgeschnitten.
                        .frame(width: 250, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 2)
                }
                ForEach(Array(snaps.enumerated()), id: \.element.id) { index, snap in
                    SnapTile(snap: snap)
                        .onTapGesture { cover = .viewer(index: index) }
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.55).combined(with: .opacity),
                            removal: .opacity))
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Immer aktiv — der Naehe-Zwang ist gekippt (Leon-Korrektur). Aus dem Sheet
    /// heraus ist der Snap ein expliziter Spot-Snap, egal wie weit weg ich stehe.
    private var snapCTA: some View {
        Button {
            cover = .camera
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.white)
                Text("Snap")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 84, height: 112)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(GZ.accent)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Teilnehmer

    private var participantsRow: some View {
        HStack(spacing: 16) {
            ForEach(spot.participants) { person in
                participantChip(person)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func participantChip(_ person: Person) -> some View {
        let chip = VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(GZ.avatarColor(person.name))
                    .frame(width: 38, height: 38)
                Text(String(person.name.prefix(1)))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                Circle().strokeBorder(GZ.stroke, lineWidth: 1)
            }
            Text(person.isMe ? "Ich" : person.name)
                .font(.caption2)
                .foregroundStyle(GZ.ink2)
        }

        if person.isMe {
            chip
        } else {
            chip
                .contextMenu {
                    Button(role: .destructive) {
                        store.showToast("Im Mockup ohne Funktion")
                    } label: {
                        Label("Blockieren", systemImage: "hand.raised.fill")
                    }
                    // Sichtbar, weil ich diesen Spot hoste.
                    Button {
                        store.showToast("Im Mockup ohne Funktion")
                    } label: {
                        Label("Aus Spot entfernen", systemImage: "person.fill.badge.minus")
                    }
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.32).onEnded { _ in GZ.haptic() }
                )
        }
    }

    private var inviteFooter: some View {
        HStack {
            Spacer(minLength: 0)
            Label("Einladen", systemImage: "person.badge.plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GZ.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .glassCard(radius: 20, capsule: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var toast: some View {
        if let text = store.toast {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GZ.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassCard(radius: 18, capsule: true)
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func applyAutoRoute() {
        NSLog("[GZSpike] sheet onAppear autoRoute=\(autoRoute.rawValue) routed=\(routed)")
        guard !routed else { return }
        routed = true
        switch autoRoute {
        case .camera:
            after(0.7) { cover = .camera; NSLog("[GZSpike] cover=camera gesetzt") }
        case .viewer:
            after(0.7) { cover = .viewer(index: 0); NSLog("[GZSpike] cover=viewer gesetzt") }
        case .report:
            after(0.7) { cover = .viewer(index: 0, report: true); NSLog("[GZSpike] cover=report gesetzt") }
        default:
            break
        }
    }

    /// Cover erst nach der Sheet-Praesentation zeigen — zwei Praesentationen im
    /// selben Frame verschluckt SwiftUI.
    private func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - Kachel

struct SnapTile: View {
    let snap: Snap

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = GZ.photo(snap.photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 112)
            } else {
                Rectangle().fill(GZ.ink3.opacity(0.35))
            }
            LinearGradient(
                colors: [.clear, .black.opacity(0.68)],
                startPoint: .center, endPoint: .bottom)
            Text(snap.caption)
                .font(.caption2)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .frame(width: 84, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(GZ.stroke, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Glas

extension View {
    /// `.ultraThinMaterial` + 1-px-Stroke — die Glas-Sprache aus v1 `theme.css`.
    func glassCard(radius: CGFloat, capsule: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, capsule: capsule))
    }
}

private struct GlassCard: ViewModifier {
    let radius: CGFloat
    let capsule: Bool

    func body(content: Content) -> some View {
        if capsule {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(GZ.stroke, lineWidth: 1) }
        } else {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.strokeBorder(GZ.stroke, lineWidth: 1) }
        }
    }
}
