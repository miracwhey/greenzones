import SwiftUI

/// Mockup-Kamera: KEIN AVFoundation. Der „Sucher" ist ein Fixture-Foto —
/// Stellvertreter fuer die Live-Preview, damit der Auslöse-Moment beurteilbar ist.
struct SnapCamera: View {
    /// Bestimmt den Chip UND wohin der Snap faellt (Spot-Album vs. freier Pin).
    let context: CameraContext
    /// Screenshot-Schalter: drueckt den Auslöser ueber denselben Pfad wie ein Finger.
    var autoTrigger: Bool = false
    let onCapture: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var flash = false
    @State private var shutterPressed = false
    @State private var triggered = false

    var body: some View {
        ZStack {
            // Der Sucher haengt als Overlay am Grund-Color: `scaledToFill` meldet
            // sonst seine volle Bildbreite als Layout-Groesse, blaeht den ZStack
            // auf und schiebt X und Ghost-Buttons seitlich aus dem Schirm.
            GZ.camBg
                .overlay {
                    if let image = GZ.photo("snap2") {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                // Leichte Abdunklung — Sucher, nicht Bildergalerie.
                .overlay(Color.black.opacity(0.14))
                .clipped()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }

            Color.white
                .opacity(flash ? 1 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .onAppear {
            guard autoTrigger, !triggered else { return }
            triggered = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { trigger() }
        }
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 8) {
                Text(context.chipEmoji)
                Text(context.chipTitle)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1) }
            .environment(\.colorScheme, .dark)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var bottomBar: some View {
        HStack {
            ghostButton("bolt.fill")
            Spacer(minLength: 0)
            shutter
            Spacer(minLength: 0)
            ghostButton("arrow.triangle.2.circlepath.camera.fill")
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 26)
    }

    private var shutter: some View {
        Button {
            trigger()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 5)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(Color.white)
                    .frame(width: 58, height: 58)
                    .scaleEffect(shutterPressed ? 0.86 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func ghostButton(_ symbol: String) -> some View {
        // Nur Optik — im Mockup ohne Funktion.
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.white.opacity(0.14)))
    }

    private func trigger() {
        GZ.haptic()
        withAnimation(GZ.spring) { shutterPressed = true }
        withAnimation(.easeOut(duration: 0.06)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeIn(duration: 0.14)) { flash = false }
            shutterPressed = false
            onCapture()
        }
    }
}
