#!/usr/bin/env bash
# Erzeugt die 4 Platzhalter-Snaps (900x1200, 3:4) fuer das Mockup.
# Echte Fotos ersetzen die Dateien spaeter unter gleichem Namen — ohne Codeaenderung.
# Duotone-Verlaeufe aus den v1-Tokens ok/time/accent/ink (client/src/theme.css).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Sources/Fixtures"
mkdir -p "$OUT"

# Echte Fotos schlagen Platzhalter: liegen alle vier schon da, wird NICHTS
# ueberschrieben. Erzwingen geht mit FORCE=1.
if [ "${FORCE:-0}" != "1" ] &&
   [ -f "$OUT/snap1.jpg" ] && [ -f "$OUT/snap2.jpg" ] &&
   [ -f "$OUT/snap3.jpg" ] && [ -f "$OUT/snap4.jpg" ]; then
    echo "[placeholder] snap1..4.jpg vorhanden — nichts erzeugt (FORCE=1 ueberschreibt)."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/gen.swift" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let W = 900, H = 1200

func rgb(_ hex: UInt32) -> [CGFloat] {
    [CGFloat((hex >> 16) & 0xFF) / 255.0,
     CGFloat((hex >> 8) & 0xFF) / 255.0,
     CGFloat(hex & 0xFF) / 255.0, 1.0]
}

// (Datei, Ton A, Ton B, Winkel des Verlaufs)
let specs: [(String, UInt32, UInt32, CGFloat)] = [
    ("snap1", 0x1DB954, 0x17191C, 0.35),   // ok -> ink
    ("snap2", 0xF76B15, 0x17191C, 0.75),   // time -> ink
    ("snap3", 0x0A84FF, 0x17191C, 0.15),   // accent -> ink
    ("snap4", 0x17191C, 0x1DB954, 0.60),   // ink -> ok (Richtung gedreht)
]

let dir = CommandLine.arguments[1]
let space = CGColorSpaceCreateDeviceRGB()

for (name, a, b, angle) in specs {
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("CGContext")
    }
    let ca = CGColor(colorSpace: space, components: rgb(a))!
    let cb = CGColor(colorSpace: space, components: rgb(b))!
    let grad = CGGradient(colorsSpace: space, colors: [ca, cb] as CFArray, locations: [0, 1])!

    let dx = cos(angle * .pi), dy = sin(angle * .pi)
    let len = CGFloat(max(W, H)) * 1.2
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: CGFloat(W) / 2 - dx * len / 2, y: CGFloat(H) / 2 - dy * len / 2),
                           end: CGPoint(x: CGFloat(W) / 2 + dx * len / 2, y: CGFloat(H) / 2 + dy * len / 2),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Weiches Licht oben — gibt der Kachel Tiefe statt flachem Farbfeld.
    let hi = CGGradient(colorsSpace: space,
                        colors: [CGColor(colorSpace: space, components: [1, 1, 1, 0.22])!,
                                 CGColor(colorSpace: space, components: [1, 1, 1, 0.0])!] as CFArray,
                        locations: [0, 1])!
    ctx.drawRadialGradient(hi,
                           startCenter: CGPoint(x: CGFloat(W) * 0.32, y: CGFloat(H) * 0.78), startRadius: 0,
                           endCenter: CGPoint(x: CGFloat(W) * 0.32, y: CGFloat(H) * 0.78), endRadius: CGFloat(W) * 0.85,
                           options: [])

    guard let img = ctx.makeImage() else { fatalError("makeImage") }
    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).jpg")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        fatalError("dest")
    }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize") }
    print("[placeholder] \(url.path)")
}
SWIFT

xcrun --sdk macosx swiftc -O "$TMP/gen.swift" -o "$TMP/gen"
"$TMP/gen" "$OUT"
