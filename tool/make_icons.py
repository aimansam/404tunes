#!/usr/bin/env python3
"""Draws the 404 Tunes logo and writes every platform's app icon.
Needs Pillow + numpy:  python3 tool/make_icons.py
"""
import math, os
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 3072          # master size; everything is downscaled from this for clean edges
K = S / 1024      # SVG units -> pixels


AMBER, MINT = (255, 176, 32), (0, 229, 160)
NOTE_TOP, NOTE_BOT = (255, 255, 255), (240, 234, 255)     # white with a faint lavender fall-off


def vgrad(size, top, bot, y0, y1):
    """Vertical colour ramp between rows y0 and y1 (clamped)."""
    t = np.clip((np.arange(size) - y0) / max(1.0, (y1 - y0)), 0, 1)[:, None, None]
    row = (np.array(top, float) * (1 - t) + np.array(bot, float) * t)
    img = np.broadcast_to(row, (size, size, 3)).astype(np.uint8)
    return Image.fromarray(np.ascontiguousarray(img), "RGB").convert("RGBA")


ORBS = [  # (x, y, radius, colour, alpha) in the 1024 box: faint light pooling at the bottom of a dark tile
    (260, 900, 320, (255, 120, 60), 60),
    (820, 900, 300, (120, 70, 255), 75),
    (780, 160, 260, (0, 200, 170), 30),
]


def orbs(size):
    small = size // 6
    k = small / 1024
    out = Image.new("RGBA", (small, small), (0, 0, 0, 0))
    for cx, cy, r, col, al in ORBS:
        l = Image.new("RGBA", (small, small), col + (0,))     # same colour at alpha 0: no dark fringe when blurred
        ImageDraw.Draw(l).ellipse([(cx - r) * k, (cy - r) * k, (cx + r) * k, (cy + r) * k], fill=col + (al,))
        out.alpha_composite(l.filter(ImageFilter.GaussianBlur(r * k * 0.5)))
    return out.resize((size, size), Image.BICUBIC)


def gradient(size):
    """Deep violet tile, lit from the upper left, with soft colour orbs behind where the glass sits."""
    y, x = np.mgrid[0:size, 0:size].astype(float)
    t = np.clip(np.sqrt((x - size * 0.28) ** 2 + (y - size * 0.18) ** 2) / (size * 1.15), 0, 1)[..., None]
    a, b = np.array([0x1d, 0x1b, 0x2a], float), np.array([0x04, 0x04, 0x07], float)
    bg = Image.fromarray((a * (1 - t) + b * t).astype(np.uint8), "RGB").convert("RGBA")
    bg.alpha_composite(orbs(size))
    return bg


def _mapper(size, scale):
    f = size / 1024 * scale
    off = size / 2 - 512 * f
    return f, (lambda x, y: (off + x * f, off + y * f))


def note_mask(dx=0, size=S, scale=1.0):
    """Beamed pair of eighth notes, with every corner softly rounded."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    f, P = _mapper(size, scale)

    def head(cx, cy):
        r, pts = math.radians(-22), []
        for i in range(160):
            t = 2 * math.pi * i / 160
            x, y = 104 * math.cos(t), 76 * math.sin(t)
            pts.append(P(cx + dx + x * math.cos(r) - y * math.sin(r), cy + x * math.sin(r) + y * math.cos(r)))
        d.polygon(pts, fill=255)

    head(368, 722)
    head(668, 662)
    for sx, y_top in ((434, 306), (734, 246)):       # stems
        d.rectangle([P(sx + dx, y_top), P(sx + 44 + dx, y_top + 420)], fill=255)
    d.polygon([P(434 + dx, 306), P(778 + dx, 232), P(778 + dx, 346), P(434 + dx, 420)], fill=255)  # beam
    # round the corners: blur, then cut at 50 %
    rad = max(1, int(9 * f))
    return m.filter(ImageFilter.GaussianBlur(rad)).point(lambda v: 255 if v >= 128 else 0)


def diag(size, hi, lo):
    """Diagonal alpha ramp: bright (hi) top-left to dim (lo) bottom-right, as an L image."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    t = (x + y) / (2.0 * (size - 1))
    return Image.fromarray(np.ascontiguousarray((hi + (lo - hi) * t).astype(np.uint8)), "L")


def art_layer(size=S, scale=1.0, mono=False):
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gx = 11
    body = note_mask(0, size, scale)
    if mono:
        layer.paste((255, 255, 255, 255), mask=body)
        return layer
    f, P = _mapper(size, scale)
    small = size // 8
    shadow = note_mask(0, small, scale)
    shadow = ImageChops.offset(shadow, 0, small // 50).filter(ImageFilter.GaussianBlur(small / 45)).resize((size, size), Image.BICUBIC)
    shadow = ImageChops.subtract(shadow, body.filter(ImageFilter.MaxFilter(3)))   # nothing under the glass itself
    layer.paste((3, 1, 12, 110), mask=shadow.point(lambda v: v * 110 // 255))

    notes = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # glitch fringes: amber / mint only where they stick out past the glass
    notes.paste(AMBER + (205,), mask=ImageChops.subtract(note_mask(-gx, size, scale), body))
    notes.paste(MINT + (205,), mask=ImageChops.subtract(note_mask(gx, size, scale), body))
    # smoked glass body: a veil of white that is brightest at the top and fades to nearly clear
    ramp = np.clip((np.arange(size) - P(0, 230)[1]) / (P(0, 800)[1] - P(0, 230)[1]), 0, 1)
    vert = Image.fromarray(np.ascontiguousarray(np.broadcast_to((92 - 70 * ramp)[:, None], (size, size)).astype(np.uint8)), "L")
    notes.paste((235, 238, 255, 255), mask=ImageChops.multiply(body, vert))
    # soft inner glow hugging the edge
    glow_in = ImageChops.subtract(body, body.filter(ImageFilter.GaussianBlur(16 * f)))
    notes.paste((255, 255, 255, 255), mask=ImageChops.multiply(glow_in, diag(size, 120, 20)))
    # rim light: thin and crisp, strongest toward the light (top left), a faint cool bounce at the bottom right
    sigma = 6 * f / 2.05
    inner = body.filter(ImageFilter.GaussianBlur(sigma)).point(lambda v: 255 if v >= 250 else 0)
    rim = ImageChops.subtract(body, inner).filter(ImageFilter.GaussianBlur(max(1.0, f * 0.6)))
    notes.paste((255, 255, 255, 255), mask=ImageChops.multiply(rim, diag(size, 255, 85)))
    notes.paste((170, 190, 255, 255), mask=ImageChops.multiply(rim, diag(size, 0, 110)))
    # "Signal glitch": one horizontal band of the whole mark is nudged sideways.
    top, bot = int(P(0, 488)[1]), int(P(0, 560)[1])
    band = notes.crop((0, top, size, bot))
    notes.paste((0, 0, 0, 0), (0, top, size, bot))
    notes.alpha_composite(band, (int(46 * f), top))
    layer.alpha_composite(notes)
    return layer


def rounded(size_px, radius_frac=230 / 1024):
    m = Image.new("L", (size_px, size_px), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size_px - 1, size_px - 1], radius=size_px * radius_frac, fill=255)
    return m


def full_icon(pad=0.0):
    """Rounded-square icon on transparent; pad = fraction of the canvas left empty on each side."""
    icon = gradient(S)
    icon.alpha_composite(art_layer())
    icon.putalpha(rounded(S))
    edge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle([0, 0, S - 1, S - 1], radius=S * 230 / 1024, outline=(255, 255, 255, 52), width=S // 340)
    icon.alpha_composite(edge)
    if pad:
        inner = int(S * (1 - 2 * pad))
        out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        out.alpha_composite(icon.resize((inner, inner), Image.LANCZOS), (int(S * pad),) * 2)
        return out
    return icon


def save(img, path, size):
    path = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path)


def main():
    icon = full_icon()
    save(icon, "assets/branding/logo.png", 512)

    # Android: legacy (pre-8) launcher icons + adaptive icon layers.
    res = "android/app/src/main/res"
    for dens, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        save(icon, f"{res}/mipmap-{dens}/ic_launcher.png", px)
    fg, mono = art_layer(scale=1.0), art_layer(scale=1.0, mono=True)
    for dens, px in (("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)):
        save(fg, f"{res}/mipmap-{dens}/ic_launcher_foreground.png", px)
        save(mono, f"{res}/mipmap-{dens}/ic_launcher_monochrome.png", px)
    os.makedirs(f"{ROOT}/{res}/mipmap-anydpi-v26", exist_ok=True)
    open(f"{ROOT}/{res}/mipmap-anydpi-v26/ic_launcher.xml", "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
        '</adaptive-icon>\n')
    bg = gradient(S)
    for dens, px in (("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)):
        save(bg, f"{res}/mipmap-{dens}/ic_launcher_background.png", px)
    stale = f"{ROOT}/{res}/values/ic_launcher_background.xml"
    if os.path.exists(stale):
        os.remove(stale)

    # Windows .ico
    ico = icon.resize((256, 256), Image.LANCZOS)
    ico.save(f"{ROOT}/windows/runner/resources/app_icon.ico",
             sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

    # macOS: the system expects some transparent margin around the rounded square.
    mac = full_icon(pad=0.098)
    for px in (16, 32, 64, 128, 256, 512, 1024):
        save(mac, f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{px}.png", px)


if __name__ == "__main__":
    main()
