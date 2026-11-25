#!/usr/bin/env python3
"""Draws the 404 Tunes logo and writes every platform's app icon.
Needs Pillow + numpy:  python3 tool/make_icons.py
"""
import math, os
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 4096          # master size; everything is downscaled from this for clean edges
K = S / 1024      # SVG units -> pixels


def gradient(size):
    a = np.array([0x2a, 0x14, 0x58], float)
    b = np.array([0x0b, 0x08, 0x20], float)
    y, x = np.mgrid[0:size, 0:size]
    t = ((x + y) / (2.0 * (size - 1)))[..., None]
    img = (a * (1 - t) + b * t).astype(np.uint8)
    return Image.fromarray(img, "RGB").convert("RGBA")


def note_mask(dx=0, dy=0, size=S, scale=1.0):
    """Alpha mask of the beamed double eighth note, optionally scaled about the canvas centre."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    f = size / 1024 * scale
    off = size / 2 - 512 * f  # keeps the centre fixed when scale != 1

    def P(x, y):
        return (off + (x + dx) * f, off + (y + dy) * f)

    def head(cx, cy):
        pts = []
        for i in range(120):
            t = 2 * math.pi * i / 120
            x, y = 100 * math.cos(t), 74 * math.sin(t)
            r = math.radians(-20)
            pts.append(P(cx + x * math.cos(r) - y * math.sin(r), cy + x * math.sin(r) + y * math.cos(r)))
        d.polygon(pts, fill=255)

    head(372, 716)
    head(672, 656)
    d.rectangle([P(436, 300), P(478, 710)], fill=255)
    d.rectangle([P(736, 240), P(778, 650)], fill=255)
    d.polygon([P(436, 300), P(778, 228), P(778, 338), P(436, 410)], fill=255)
    return m


def note_layer(size=S, scale=1.0, mono=False):
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if mono:
        layer.paste((255, 255, 255, 255), mask=note_mask(size=size, scale=scale))
        return layer
    gx = 18
    for dx, col in ((-gx, (255, 176, 32)), (gx, (0, 229, 160)), (0, (255, 255, 255))):
        layer.paste(col + (255,), mask=note_mask(dx=dx, size=size, scale=scale))
    # "Signal glitch" slice: a band of the white note shifted sideways.
    f = size / 1024 * scale
    top, bot = int(size / 2 + (488 - 512) * f), int(size / 2 + (560 - 512) * f)
    band = layer.crop((0, top, size, bot))
    layer.paste((0, 0, 0, 0), (0, top, size, bot))
    layer.alpha_composite(band, (int(46 * f), top))
    return layer


def rounded(size_px, radius_frac=230 / 1024):
    m = Image.new("L", (size_px, size_px), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size_px - 1, size_px - 1], radius=size_px * radius_frac, fill=255)
    return m


def full_icon(pad=0.0):
    """Rounded-square icon on transparent; pad = fraction of the canvas left empty on each side."""
    icon = gradient(S)
    icon.alpha_composite(note_layer())
    icon.putalpha(rounded(S))
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
    fg, mono = note_layer(scale=1.0), note_layer(mono=True)
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
        '    <color name="ic_launcher_background">#170D38</color>\n</resources>\n')

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
