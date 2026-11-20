#!/usr/bin/env python3
"""Generate Android launcher icons from tools/icon_master.b64.

Runs in CI right after patch_android.py (see tools/scaffold_android.sh).
The master is the user's app icon (blue gradient, black "A", rounded
corners on white). We rebuild it as:
- legacy ic_launcher.png / ic_launcher_round.png per density, with the
  white corners replaced by transparency (rounded-rect / circle mask);
- an adaptive icon: flat background colour sampled from the artwork
  (#5093EA) + the rounded artwork as foreground, inset to the safe zone;
- mipmap-anydpi-v26 XMLs pointing at those.
"""
import base64
import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path("android/app/src/main/res")
MASTER = pathlib.Path("tools/icon_master.b64")
BG = (80, 147, 234, 255)  # sampled mid-blue of the artwork

img = Image.open(
    __import__("io").BytesIO(base64.b64decode(MASTER.read_text()))
).convert("RGB")
S = img.size[0]


def rounded(size, radius_frac=0.225, circle=False):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    if circle:
        d.ellipse([0, 0, size - 1, size - 1], fill=255)
    else:
        d.rounded_rectangle(
            [0, 0, size - 1, size - 1], radius=int(size * radius_frac), fill=255
        )
    out = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    out.putalpha(m)
    return out


DENS = {  # density dir -> legacy icon px (48dp)
    "mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192,
}
for dens, px in DENS.items():
    d = ROOT / f"mipmap-{dens}"
    d.mkdir(parents=True, exist_ok=True)
    rounded(px).save(d / "ic_launcher.png")
    rounded(px, circle=True).save(d / "ic_launcher_round.png")
    # adaptive foreground: 108dp canvas, artwork inset to ~78% (safe zone)
    fg_px = int(px * 108 / 48)
    canvas = Image.new("RGBA", (fg_px, fg_px), (0, 0, 0, 0))
    art = rounded(int(fg_px * 0.78))
    canvas.alpha_composite(art, ((fg_px - art.size[0]) // 2, (fg_px - art.size[1]) // 2))
    canvas.save(d / "ic_launcher_foreground.png")

anydpi = ROOT / "mipmap-anydpi-v26"
anydpi.mkdir(parents=True, exist_ok=True)
xml = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    "<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
    '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
    "</adaptive-icon>\n"
)
(anydpi / "ic_launcher.xml").write_text(xml, encoding="utf-8")
(anydpi / "ic_launcher_round.xml").write_text(xml, encoding="utf-8")

draw_dir = ROOT / "drawable"
draw_dir.mkdir(parents=True, exist_ok=True)
(draw_dir / "ic_launcher_background.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    "<shape xmlns:android=\"http://schemas.android.com/apk/res/android\" "
    'android:shape="rectangle">\n'
    '    <solid android:color="#5093EA"/>\n'
    "</shape>\n",
    encoding="utf-8",
)
# The flutter template ships a vector foreground with the same name in
# drawable/; it is unused once the anydpi XML points at the mipmaps, but
# remove it to avoid any duplicate-resource surprise.
for p in ROOT.glob("drawable*/ic_launcher_foreground.xml"):
    p.unlink()
print("make_icons: launcher icons generated")
