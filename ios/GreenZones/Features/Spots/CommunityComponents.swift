import CoreLocation
import GreenZonesKit
import SwiftUI
import UIKit

/// Bausteine der Community-Sheets — 1:1 die Klassen aus `client/src/components/spots.css`
/// (`.sp-*`), die ihrerseits aus `mockup/community.html` und `mockup/invite.html`
/// portiert sind. Alle Texte woertlich aus v1.

// MARK: - Farbwerte

/// Die CSS-Fuellungen liegen als `rgba(23,25,28,x)` (hell) bzw. `rgba(255,255,255,y)`
/// (dunkel) vor — als dynamische Farbe gebaut, damit kein Aufrufer das Schema
/// durchreichen muss.
func spFill(light: Double, dark: Double) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: dark)
        : UIColor(red: 23.0 / 255, green: 25.0 / 255, blue: 28.0 / 255, alpha: light) })
}

enum SP {
    static let field = spFill(light: 0.04, dark: 0.06)
    static let tile = spFill(light: 0.03, dark: 0.05)
    static let segment = spFill(light: 0.06, dark: 0.07)
    static let selfRow = spFill(light: 0.035, dark: 0.05)
    /// Farbe eines Freundes (Hex aus dem Merge) — unbekannt = ink-3.
    static func color(_ hex: String?) -> Color {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let value = UInt32(hex.dropFirst(), radix: 16) else { return GZ.ink3 }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Sheet-Rahmen

@MainActor
enum SPScreen {
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    static var height: CGFloat { keyWindow?.bounds.height ?? 844 }
    static var width: CGFloat { keyWindow?.bounds.width ?? 390 }
    static var bottomInset: CGFloat { keyWindow?.safeAreaInsets.bottom ?? 0 }
    static var topInset: CGFloat { keyWindow?.safeAreaInsets.top ?? 0 }

    /// Die ganze Fensterflaeche. Der Sucher der Kamera fuellt sie formatfuellend
    /// aus — dort faengt der Flug eines frisch aufgenommenen Snaps an.
    static var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// Die Flaeche zwischen den Systemraendern — dort zeichnet der Betrachter
    /// sein Bild, und dorthin zielt der Morph.
    ///
    /// Gemessen, nicht angenommen: ein `ignoresSafeArea` an der Seitenansicht
    /// des Betrachters aendert daran nichts (die Seitendarstellung haelt ihre
    /// eigenen Raender), das Bild sass im Beweisbild 42 px tiefer als die
    /// Schirmmitte — genau die halbe Differenz der beiden Systemraender. Waere
    /// hier die volle Fensterflaeche eingetragen, spraenge das Bild im
    /// Uebergabe-Frame um diese 42 px.
    static var contentBounds: CGRect {
        CGRect(x: 0, y: topInset, width: width, height: height - topInset - bottomInset)
    }
    /// Innenbreite der Sheets (18 pt Rand je Seite).
    static var sheetContentWidth: CGFloat { width - 36 }
}

/// Rahmen aller Community-Sheets: Innenabstaende und das kantenbuendige Blatt
/// (`bottomSheetCard`), das die Inhaltshoehe misst und bei 86 % der
/// Bildschirmhoehe deckelt — der Profil-Editor und „Spot markieren" sind laenger
/// als ein Telefon und scrollen ab dort im Blatt.
struct CommunitySheet<Content: View>: View {
    /// Startwert fuer den ersten Frame, bis die echte Hoehe gemessen ist.
    var estimate: CGFloat = 420
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .bottomSheetCard(estimate: estimate)
    }
}

// MARK: - Typografie

struct SPTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 19, weight: .bold))
            .tracking(-0.19)
            .foregroundStyle(GZ.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
}

struct SPSubtitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(GZ.ink2)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            .padding(.bottom, 14)
    }
}

struct SPSection: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.72)
            .foregroundStyle(GZ.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 8)
    }
}

// MARK: - Hinweiszeile (.sp-note)

struct SPNote: View {
    enum Tone { case neutral, ok, no }

    let text: String
    var tone: Tone = .neutral

    private var icon: SPIcon.Kind {
        switch tone {
        case .neutral: return .note
        case .ok: return .check
        case .no: return .cross
        }
    }

    private var iconColor: Color {
        switch tone {
        case .neutral: return GZ.ink3
        case .ok: return GZ.ok
        case .no: return GZ.ban
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SPIcon(kind: icon).stroked(iconColor, size: 15, width: tone == .neutral ? 1.9 : 2.4)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(GZ.ink2)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

/// Ruhiger Hinweis auf den Kontostatus — Wortlaut aus dem Contract. Kein Modal,
/// kein Dauerbanner: die App bleibt ohne iCloud voll lokal nutzbar.
struct SPCloudHint: View {
    let status: CKAccountStatus?

    var body: some View {
        if let status, status != .available {
            SPNote(text: status == .noAccount
                   ? "Für Freunde & geteilte Spots bei iCloud anmelden — Einstellungen → [dein Name]."
                   : "iCloud antwortet gerade nicht — deine Spots bleiben lokal da.")
        }
    }
}

// MARK: - Knoepfe

struct SPCTA: View {
    enum Style { case dark, blue, green, outline }

    let title: String
    var style: Style = .dark
    var enabled: Bool = true
    let action: () -> Void

    private var background: Color {
        switch style {
        case .dark: return GZ.ink
        case .blue: return GZ.accent
        case .green: return GZ.ok
        case .outline: return GZ.accent.opacity(0.07)
        }
    }

    private var foreground: Color {
        switch style {
        case .dark: return GZ.appBg
        case .blue, .green: return .white
        case .outline: return GZ.accent
        }
    }

    var body: some View {
        Button(action: { if enabled { GZ.haptic(); action() } }) {
            Text(title)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(background, in: .rect(cornerRadius: 15, style: .continuous))
                .overlay {
                    if style == .outline {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(GZ.accent.opacity(0.4), lineWidth: 1.5)
                    }
                }
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.top, 9)
    }
}

struct SPGhost: View {
    let title: String
    var danger = false
    let action: () -> Void

    var body: some View {
        Button(action: { GZ.haptic(); action() }) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(danger ? GZ.ban : GZ.ink2)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Avatar

/// Avatar-Kreis: gewaehltes Zeichen, sonst Initiale des Namens. Ohne beides
/// bleibt er leer und traegt das Personen-Symbol — ein Buchstabe wuerde einen
/// Namen behaupten, den es noch nicht gibt.
struct SPAvatar: View {
    let name: String
    var emoji: String?
    var color: Color
    var size: CGFloat = 28

    private var glyph: String { avatarGlyph(name: name, emoji: emoji) }
    private var isEmoji: Bool { !(emoji ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack {
            if glyph.isEmpty {
                Circle()
                    .fill(spFill(light: 0.05, dark: 0.08))
                Circle()
                    .strokeBorder(GZ.ink3.opacity(0.55),
                                  style: StrokeStyle(lineWidth: size > 60 ? 3 : 1.5, dash: [4, 3]))
                SPIcon(kind: .person).stroked(GZ.ink3, size: size * 0.46, width: 1.7)
            } else {
                Circle().fill(color)
                Text(glyph)
                    .font(.system(size: isEmoji ? size * 0.55 : size * 0.39,
                                  weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if !glyph.isEmpty {
                Circle().strokeBorder(GZ.appBg.opacity(0.6), lineWidth: size > 60 ? 3 : 2)
            }
        }
    }
}

extension SPAvatar {
    init(friend: Friend, size: CGFloat = 28) {
        self.init(name: friend.name, emoji: friend.emoji,
                  color: SP.color(friend.color), size: size)
    }
}

// MARK: - Chips

struct SPChip: View {
    let name: String
    var emoji: String?
    var color: Color
    var selected: Bool
    /// `nil` = Anzeige statt Auswahl (Teilnehmer eines geteilten Spots).
    var onToggle: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 7) {
            SPAvatar(name: name, emoji: emoji, color: color, size: 22)
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? GZ.ink : GZ.ink2)
            if selected, onToggle != nil {
                SPIcon(kind: .check).stroked(GZ.accent, size: 14, width: 2.6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? GZ.accent.opacity(0.08) : SP.tile, in: .capsule)
        .overlay {
            Capsule().strokeBorder(selected ? GZ.accent : GZ.stroke, lineWidth: 1.5)
        }

        if let onToggle {
            Button(action: { GZ.haptic(); onToggle() }) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Umbruchfaehige Chip-Reihe (`.sp-chips`, `flex-wrap`).
struct SPChipRow<Item: Identifiable, Chip: View>: View {
    let items: [Item]
    @ViewBuilder let chip: (Item) -> Chip

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items) { chip($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Zeilenumbruch wie `flex-wrap: wrap` — SwiftUI hat dafuer nichts Fertiges.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var height: CGFloat = 0
        var width: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0
        var y: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, x + size.width > width {
                row.y = y
                rows.append(row)
                y += row.height + spacing
                row = Row()
                x = 0
            }
            row.indices.append(index)
            row.height = max(row.height, size.height)
            x += size.width + spacing
            row.width = x - spacing
        }
        if !row.indices.isEmpty {
            row.y = y
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Spot-Karte

/// `.spot-card` aus dem Mockup — ohne Stadtteil (dafuer gibt es keine Quelle).
struct SPSpotCard: View {
    let spot: Spot
    let status: ZoneStatus?
    let hour: Int
    let userCoordinate: CLLocationCoordinate2D?

    private var kind: StatusKind { ZoneStatus.statusKind(status, hour: hour) }
    private var isOK: Bool { kind == .ok }

    private var distance: String? {
        guard let userCoordinate else { return nil }
        return Geo.formatDistanceM(Geo.distanceM(userCoordinate, spot.coordinate))
    }

    var body: some View {
        HStack(spacing: 11) {
            Text(spot.emoji)
                .font(.system(size: 20))
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(GZ.stroke, lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GZ.ink)
                HStack(spacing: 0) {
                    if kind == .wait {
                        Text("Status wird geprüft …")
                            .font(.system(size: 12))
                            .foregroundStyle(GZ.ink2)
                    } else {
                        Text(isOK ? "Erlaubt" : "Verboten")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isOK ? GZ.ok : GZ.ban)
                    }
                    if let distance {
                        Text(" · \(distance) von dir")
                            .font(.system(size: 12))
                            .foregroundStyle(GZ.ink2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background((isOK || kind == .wait ? GZ.ok : GZ.ban).opacity(0.08),
                    in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((isOK || kind == .wait ? GZ.ok : GZ.ban).opacity(0.22), lineWidth: 1)
        }
        .padding(.top, 12)
    }
}

// MARK: - Zeilen

/// Zeit-Zeile mit Stift (Host).
struct SPTimeRow: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: { GZ.haptic(); action() }) {
            HStack(spacing: 10) {
                SPIcon(kind: .clock).stroked(GZ.ink2, size: 17)
                Text(text)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(GZ.ink)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    SPIcon(kind: .pencil).stroked(GZ.accent, size: 14, width: 2)
                    Text("Ändern")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GZ.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(SP.tile, in: .rect(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(GZ.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}

/// Eine Zeile in „Wer kommt".
///
/// W5 (Mockup-Lock B): der Gastgeber erreicht ueber „•••" genau zwei Wege —
/// jemanden aus DIESEM Spot nehmen, oder die Freundschaft ganz beenden. Melden
/// steht bewusst nicht hier: das gehoert an den Snap, nicht an die Person.
struct SPRsvpRow: View {
    let entry: RsvpEntry
    let showDivider: Bool
    var onRemoveFromSpot: (() -> Void)?
    var onRemoveFriend: (() -> Void)?

    private var hasMenu: Bool { onRemoveFromSpot != nil || onRemoveFriend != nil }

    var body: some View {
        VStack(spacing: 0) {
            if showDivider {
                Rectangle().fill(GZ.divider).frame(height: 1)
            }
            HStack(spacing: 10) {
                SPAvatar(name: entry.name, emoji: entry.emoji, color: entry.color)
                Text(entry.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(GZ.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(entry.text)
                    .font(.system(size: 12.5, weight: entry.tone == .attending ? .semibold : .medium))
                    .foregroundStyle(entry.tone == .attending ? GZ.ok : GZ.ink3)
                if hasMenu {
                    Menu {
                        if let onRemoveFromSpot {
                            Button("Aus Spot entfernen", action: onRemoveFromSpot)
                        }
                        if let onRemoveFriend {
                            Button("Freund entfernen", role: .destructive, action: onRemoveFriend)
                        }
                    } label: {
                        Text("•••")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(GZ.ink3)
                            .frame(width: 30, height: 34)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Mehr zu \(entry.name)")
                }
            }
            .padding(.vertical, 9)
        }
    }
}

/// Freundes-Zeile in der Liste.
///
/// Das Menue rechts traegt „Freund entfernen" (SPEC 7). Es steht sichtbar in
/// der Zeile statt hinter einer Wischgeste: eine Trennung muss auffindbar sein,
/// nicht erraten werden.
struct SPMemberRow: View {
    let friend: Friend
    let detail: String
    let showDivider: Bool
    var onRemove: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if showDivider {
                Rectangle().fill(GZ.divider).frame(height: 1)
            }
            HStack(spacing: 12) {
                SPAvatar(friend: friend, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friendLabel(friend))
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(GZ.ink)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(GZ.ink2)
                }
                Spacer(minLength: 0)
                if let onRemove {
                    Menu {
                        Button("Freund entfernen", role: .destructive, action: onRemove)
                    } label: {
                        Text("•••")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(GZ.ink3)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Mehr zu \(friendLabel(friend))")
                }
            }
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Eingaben

struct SPTextField: View {
    var leadingEmoji: String?
    let placeholder: String
    let accessibilityLabel: String
    var maxLength: Int?
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            if let leadingEmoji {
                Text(leadingEmoji).font(.system(size: 19))
            }
            TextField(placeholder, text: $text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GZ.ink)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .accessibilityLabel(accessibilityLabel)
                .onChange(of: text) { _, new in
                    if let maxLength, new.count > maxLength { text = String(new.prefix(maxLength)) }
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(SP.field, in: .rect(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(GZ.stroke, lineWidth: 1)
        }
    }
}

/// Segment „Mein Standort / Auf Karte wählen".
struct SPSegment: View {
    let titles: [String]
    @Binding var selection: Int
    var onSelect: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button(action: {
                    GZ.haptic()
                    selection = index
                    onSelect(index)
                }) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(selection == index ? GZ.ink : GZ.ink2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if selection == index {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(UIColor { $0.userInterfaceStyle == .dark
                                        ? UIColor(white: 1, alpha: 0.16) : .white }))
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(SP.segment, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Emoji-Wahl fuer den Spot (6er-Set) — dieselbe Bauart wie das Zeichen-Raster,
/// nur groesser.
struct SPEmojiPicker: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button(action: { GZ.haptic(); selection = option }) {
                    Text(option)
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .background(selection == option ? GZ.accent.opacity(0.08) : SP.tile,
                                    in: .rect(cornerRadius: 13, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(selection == option ? GZ.accent : GZ.stroke,
                                              lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Symbol \(option)")
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Toast

/// 2600 ms wie v1. Bei offenem Blatt sitzt er oben am Bildschirm — unten wuerde
/// er das Blatt (Eingabefeld, CTA) verdecken, im Blatt selbst dessen Kopf.
/// Platziert wird er in `RootView`, ueber der ganzen Blatt-Ebene.
struct SPToast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 58.0 / 255, green: 62.0 / 255, blue: 70.0 / 255, alpha: 0.95)
                : UIColor(red: 23.0 / 255, green: 25.0 / 255, blue: 28.0 / 255, alpha: 0.92) }),
                in: .capsule)
            .shadow(color: .black.opacity(0.35), radius: 15, y: 8)
            .padding(.horizontal, 14)
            .transition(.opacity.combined(with: .offset(y: 8)))
    }
}

// MARK: - „Wer kommt"

struct RsvpEntry: Identifiable {
    enum Tone { case attending, open }

    let id: String
    let name: String
    let emoji: String?
    let color: Color
    let text: String
    let tone: Tone
    /// userRecordID der Person, sofern es eine andere als ich ist — daran haengt
    /// das „•••"-Menue des Gastgebers. `nil` bei der eigenen Zeile.
    var friendId: String?
}

/// Antwort → Statuszeile. „Ich komme um 21:00" ist eine Zusage, keine Absage.
func replyState(_ reply: Reply?, isSelf: Bool) -> (text: String, tone: RsvpEntry.Tone) {
    guard let reply else { return ("offen", .open) }
    if reply.status == .out { return ("kann nicht", .open) }
    if let arrival = reply.arrivalTime {
        return ("\(isSelf ? "kommst" : "kommt") um \(Tape.fmtClock(arrival)) ✓", .attending)
    }
    return ("dabei ✓", .attending)
}

/// „Wer kommt": Gastgeber (falls fremd) · die echten Spot-Teilnehmer · eigene
/// Antwort. Teilnehmer ohne Antwort stehen auf „offen" — das ist ein Zustand,
/// kein Fehlen. Wer nur als Antwort auftaucht (Freundesliste noch nicht
/// synchronisiert), steht namenlos, aber sichtbar dabei.
func rsvpEntries(_ invitation: Invitation, friends: [Friend],
                 participantIds: [String]) -> [RsvpEntry] {
    var rows: [RsvpEntry] = []
    func known(_ id: String) -> Friend? { friends.first { $0.id == id } }
    func row(_ id: String, _ reply: Reply?) -> RsvpEntry {
        let friend = known(id)
        let state = replyState(reply, isSelf: false)
        return RsvpEntry(id: id,
                         name: friend.map(friendLabel) ?? "Freund",
                         emoji: friend?.emoji,
                         color: SP.color(friend?.color),
                         text: state.text,
                         tone: state.tone,
                         friendId: id)
    }

    var seen: Set<String> = [SELF_ID]
    if invitation.hostId != SELF_ID {
        let host = known(invitation.hostId)
        seen.insert(invitation.hostId)
        rows.append(RsvpEntry(id: "host-\(invitation.hostId)",
                              name: host.map(friendLabel) ?? "Gastgeber",
                              emoji: host?.emoji,
                              color: host.map { SP.color($0.color) } ?? GZ.accent,
                              text: "ab \(Tape.fmtClock(invitation.time)) · Gastgeber",
                              tone: .attending,
                              friendId: invitation.hostId))
    }
    for id in participantIds where !seen.contains(id) {
        seen.insert(id)
        rows.append(row(id, invitation.reply(of: id)))
    }
    if let own = invitation.reply(of: SELF_ID) {
        let state = replyState(own, isSelf: true)
        rows.append(RsvpEntry(id: "self", name: "Du", emoji: nil, color: GZ.accent,
                              text: state.text, tone: state.tone))
    }
    for reply in invitation.replies where !seen.contains(reply.participantId) {
        seen.insert(reply.participantId)
        rows.append(row(reply.participantId, reply))
    }
    return rows
}

// MARK: - Hilfen

extension Spot {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
