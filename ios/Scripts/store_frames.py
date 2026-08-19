#!/usr/bin/env python3
"""Baut aus den rohen Simulator-Aufnahmen die Store-Bilder (1320 x 2868).

Aufruf:  python3 ios/Scripts/store_frames.py [--out VERZEICHNIS]

Die Bilder werden direkt in Zielgroesse gezeichnet, nicht skaliert — Schrift
bleibt dadurch scharf. Quelle sind die Aufnahmen in `ios/shots/store/`, das
Ergebnis landet in `ios/shots/store-frames/`.

Zwei Auftritte, wie am 18.08. entworfen:

  A (hell)    Textzeile oben auf hellem Grund, Geraet unten angeschnitten.
  B (Vollbild) Aufnahme fuellt die Flaeche, Text unten im dunklen Verlauf.

Die Statusleiste der Aufnahme wird in BEIDEN Faellen abgeschnitten. Sie traegt
nichts bei, und in fuenf von sechs Aufnahmen schiebt sich das Kartenlabel
„ALTSTADT" hinter die Uhrzeit — abschneiden loest das, ein Rahmen wuerde es nur
verdecken.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1320, 2868
# Schnittkante oben: die Uhrzeit sitzt bei y=60..110, die Dynamic Island reicht
# bis y=190. Beides muss weg, die Suchleiste beginnt erst bei y=225.
STATUS_BAR = 205
SF = "/System/Library/Fonts/SFNS.ttf"

INK = (22, 33, 27)
INK_SOFT = (74, 90, 80)
GRAD_TOP = (238, 243, 236)
GRAD_BOTTOM = (219, 230, 220)


@dataclass(frozen=True)
class Frame:
    src: str
    style: str        # "A" oder "B"
    head: str
    sub: str
    crop_top: int = 0   # zusaetzlicher Schnitt oben, wenn die Aufnahme dort leer ist


# Die sechs Zeilen. Konsumneutral: sie beschreiben, was die App zeigt, nie was
# man tun soll (App Store Review 1.4.3).
FRAMES = [
    Frame("01_karte.png", "B", "Sofort sehen,\nob du darfst",
          "Rot, orange, frei — für deinen Ort zur aktuellen Stunde."),
    Frame("02_suche.png", "A", "Orte findest du\nohne Netz",
          "Parks, Seen, Plätze; der Index liegt in der App."),
    Frame("03_zugang.png", "A", "Du bestimmst,\nwer den Spot sieht",
          "Zugang ist eine Auswahl, keine Nebenwirkung."),
    Frame("04_termin.png", "A", "Sag, ab wann\ndu da bist",
          "Jeder antwortet mit seiner eigenen Zeit."),
    # Der Onboarding-Screen ist mittig gesetzt und traegt oben Leerraum; ein
    # knapper Schnitt holt ihn nach oben, ohne den Anschnitt unten zu verlieren.
    Frame("05_daten.png", "A", "Kein Server.\nKein Konto.",
          "Alles bleibt auf dem Gerät und in deiner iCloud.", crop_top=120),
    # A statt B: hier ist das Blatt das Argument, nicht die Kartenflaeche — ein
    # dunkles Band wuerde es mittendrin abschneiden.
    Frame("06_offline.png", "A", "Vorher sichern,\nunterwegs sehen",
          "20 km Karte für den Fall ohne Empfang."),
]


def font(size: int, weight: str) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(SF, size)
    f.set_variation_by_name(weight)
    return f


def vertical_gradient(size: tuple[int, int], top, bottom) -> Image.Image:
    """Verlauf ueber die volle Hoehe — als 1px-Spalte gezeichnet und gedehnt."""
    w, h = size
    strip = Image.new("RGB", (1, h))
    px = strip.load()
    for y in range(h):
        t = y / (h - 1)
        px[0, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return strip.resize((w, h), Image.BICUBIC)


def rounded_top(img: Image.Image, radius: int) -> Image.Image:
    """Rundet nur die beiden oberen Ecken ab (unten wird angeschnitten)."""
    mask = Image.new("L", img.size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, img.width - 1, img.height - 1 + radius),
                        radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def drop_shadow(size: tuple[int, int], radius: int, blur: int, spread: int):
    """Weicher Schatten unter der Aufnahme."""
    w, h = size
    layer = Image.new("RGBA", (w + 2 * blur, h + 2 * blur), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((blur - spread, blur - spread,
                         blur + w + spread, blur + h + spread),
                        radius=radius + spread, fill=(20, 30, 24, 70))
    return layer.filter(ImageFilter.GaussianBlur(blur / 2))


def text_block(draw: ImageDraw.ImageDraw, xy, head, sub, head_font, sub_font,
               head_fill, sub_fill, line_gap=1.06, block_gap=34):
    """Zeichnet Headline (mehrzeilig) plus Unterzeile, gibt Unterkante zurueck."""
    x, y = xy
    ascent, descent = head_font.getmetrics()
    line_h = round((ascent + descent) * line_gap)
    for line in head.split("\n"):
        draw.text((x, y), line, font=head_font, fill=head_fill)
        y += line_h
    y += block_gap
    a2, d2 = sub_font.getmetrics()
    for line in sub.split("\n"):
        draw.text((x, y), line, font=sub_font, fill=sub_fill)
        y += round((a2 + d2) * 1.24)
    return y


def build_a(shot: Image.Image, f: Frame) -> Image.Image:
    canvas = vertical_gradient((W, H), GRAD_TOP, GRAD_BOTTOM).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    margin = 118
    bottom = text_block(draw, (margin, 168), f.head, f.sub,
                        font(96, "Bold"), font(42, "Regular"), INK, INK_SOFT)

    # Aufnahme: volle Breite minus Rand, oben abgerundet, unten angeschnitten.
    shot = shot.crop((0, STATUS_BAR + f.crop_top, shot.width, shot.height))
    inset = 96
    target_w = W - 2 * inset
    scale = target_w / shot.width
    shot = shot.resize((target_w, round(shot.height * scale)), Image.LANCZOS)

    # Immer buendig mit der Unterkante: eine Aufnahme, die frei im Grund endet,
    # sieht aus wie ein Fehler, nicht wie ein Anschnitt.
    top = max(bottom + 96, H - shot.height)
    visible = H - top
    if shot.height > visible:
        shot = shot.crop((0, 0, shot.width, visible))

    radius = 46
    shadow = drop_shadow(shot.size, radius, blur=96, spread=6)
    canvas.alpha_composite(shadow, (inset - 96, top - 96 + 26))
    canvas.alpha_composite(rounded_top(shot, radius), (inset, top))

    # Feine Kontur — sonst verschwimmt ein heller Screen im hellen Grund.
    ImageDraw.Draw(canvas, "RGBA").rounded_rectangle(
        (inset, top, inset + shot.width - 1, top + shot.height - 1 + radius),
        radius=radius, outline=(20, 30, 24, 46), width=2)
    return canvas.convert("RGB")


def build_b(shot: Image.Image, f: Frame) -> Image.Image:
    """Aufnahme oben in voller Breite, darunter eine ruhige dunkle Flaeche.

    Der Text liegt NICHT auf dem Kartenbild: die App traegt unten selbst eine
    Statuszeile, und ein halbdurchsichtiges Band laesst sie durchscheinen. Das
    Bild endet deshalb ueber ihr, mit einem kurzen weichen Uebergang.
    """
    shot = shot.crop((0, STATUS_BAR + f.crop_top, shot.width, shot.height))
    scale = W / shot.width
    shot = shot.resize((W, round(shot.height * scale)), Image.LANCZOS)

    dark = (10, 16, 13)
    panel_h = 840                       # dunkle Flaeche unten
    fade_h = 260                        # weicher Uebergang darueber
    image_h = H - panel_h

    canvas = Image.new("RGBA", (W, H), dark + (255,))
    canvas.paste(shot.convert("RGBA").crop((0, 0, W, min(shot.height, image_h))), (0, 0))

    fade = Image.new("RGBA", (W, fade_h), (0, 0, 0, 0))
    fp = fade.load()
    for y in range(fade_h):
        alpha = round(255 * (y / (fade_h - 1)) ** 1.7)
        for x in range(W):
            fp[x, y] = dark + (alpha,)
    canvas.alpha_composite(fade, (0, image_h - fade_h))

    draw = ImageDraw.Draw(canvas)
    margin = 118
    head_f, sub_f = font(96, "Bold"), font(42, "Regular")
    ascent, descent = head_f.getmetrics()
    a2, d2 = sub_f.getmetrics()
    block = (round((ascent + descent) * 1.06) * len(f.head.split("\n"))
             + 34 + round((a2 + d2) * 1.24))
    top = image_h + (panel_h - block) // 2 - 30
    text_block(draw, (margin, top), f.head, f.sub, head_f, sub_f,
               (255, 255, 255), (188, 200, 192))
    return canvas.convert("RGB")


def main() -> None:
    root = Path(__file__).resolve().parents[1]      # ios/
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=root / "shots" / "store", type=Path)
    ap.add_argument("--out", default=root / "shots" / "store-frames", type=Path)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    for f in FRAMES:
        src = args.src / f.src
        shot = Image.open(src).convert("RGB")
        if (shot.width, shot.height) != (W, H):
            raise SystemExit(f"{src.name}: {shot.width}x{shot.height}, erwartet {W}x{H}")
        out = (build_a if f.style == "A" else build_b)(shot, f)
        if out.size != (W, H):
            raise SystemExit(f"{f.src}: Ergebnis {out.size}, erwartet {(W, H)}")
        dest = args.out / f.src
        out.save(dest, "PNG")
        print(f"{dest.name}  {f.style}  {dest.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
