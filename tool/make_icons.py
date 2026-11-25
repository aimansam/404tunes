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


def gradient(size):
    """Deep violet tile, lit from the upper left."""
    y, x = np.mgrid[0:size, 0:size].astype(float)
    t = np.clip(np.sqrt((x - size * 0.28) ** 2 + (y - size * 0.18) ** 2) / (size * 1.15), 0, 1)[..., None]
    a, b = np.array([0x3a, 0x1c, 0x7a], float), np.array([0x0a, 0x06, 0x1c], float)
    return Image.fromarray((a * (1 - t) + b * t).astype(np.uint8), "RGB").convert("RGBA")


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


def art_layer(size=S, scale=1.0, mono=False):
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gx = 14
    if mono:
        layer.paste((255, 255, 255, 255), mask=note_mask(0, size, scale))
        return layer
    # soft violet glow behind the note
    small = size // 8
    glow = note_mask(0, small, scale).filter(ImageFilter.GaussianBlur(small / 22)).resize((size, size), Image.BICUBIC)
    layer.paste((150, 90, 255, 80), mask=glow.point(lambda v: v * 80 // 255))
    shadow = note_mask(0, small, scale)
    shadow = ImageChops.offset(shadow, 0, small // 60).filter(ImageFilter.GaussianBlur(small / 60)).resize((size, size), Image.BICUBIC)
    layer.paste((4, 2, 14, 150), mask=shadow.point(lambda v: v * 150 // 255))
    f, P = _mapper(size, scale)
    ramp = vgrad(size, NOTE_TOP, NOTE_BOT, P(0, 230)[1], P(0, 800)[1])
    notes = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    notes.paste(AMBER + (255,), mask=note_mask(-gx, size, scale))
    notes.paste(MINT + (255,), mask=note_mask(gx, size, scale))
    notes.paste(ramp, mask=note_mask(0, size, scale))
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
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ramp_a = (np.clip(1 - np.arange(S) / (S * 0.55), 0, 1) ** 2 * 26).astype(np.uint8)
    sheen.putalpha(Image.fromarray(np.ascontiguousarray(np.broadcast_to(ramp_a[:, None], (S, S)))))
    white = Image.new("RGBA", (S, S), (255, 255, 255, 255))
    white.putalpha(sheen.getchannel("A"))
    icon.alpha_composite(white)
    icon.putalpha(rounded(S))
    edge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle([0, 0, S - 1, S - 1], radius=S * 230 / 1024, outline=(255, 255, 255, 34), width=S // 340)
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
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
        '</adaptive-icon>\n')
    open(f"{ROOT}/{res}/values/ic_launcher_background.xml", "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <color name="ic_launcher_background">#170B38</color>\n</resources>\n')

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
