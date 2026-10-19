# Paint one dark plaque per part: the persistent reference designator large
# (what the silkscreen will say), the part id small. Unreal imports these; it
# does not run Pillow. A plaque is re-rendered only when its text changes.

import json
import os

from PIL import Image, ImageDraw, ImageFont

CONTENT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENES = ("Boards/scene.json", "Boards/product/scene.json")
OUT = os.path.join(CONTENT, "Textures", "Labels")


def labels():
    """{part id: (refdes or '', id)} across the editable and product scenes."""
    found = {}
    for rel in SCENES:
        path = os.path.join(CONTENT, rel)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as handle:
            for body in json.load(handle):
                ident = body.get("id")
                if ident in ("pcb", "shield") or not ident:
                    continue
                refdes = body.get("refdes") or found.get(ident, ("", ident))[0]
                found[ident] = (refdes, ident)
    return dict(sorted(found.items()))


def ids():
    return list(labels())


def main():
    os.makedirs(OUT, exist_ok=True)
    big = ImageFont.truetype(r"C:\Windows\Fonts\arialbd.ttf", 72)
    small = ImageFont.truetype(r"C:\Windows\Fonts\arial.ttf", 34)
    for ident, (refdes, _) in labels().items():
        out = os.path.join(OUT, f"L_{ident}.png")
        stamp = os.path.join(OUT, f"L_{ident}.txt")
        text = f"{refdes}|{ident}"
        if os.path.isfile(out) and os.path.isfile(stamp):
            with open(stamp, encoding="utf-8") as handle:
                if handle.read() == text:
                    continue
        image = Image.new("RGB", (512, 128), (16, 18, 22))
        draw = ImageDraw.Draw(image)
        if refdes:
            draw.text((18, 14), refdes, fill=(255, 236, 170), font=big)
            draw.text((20, 90), ident, fill=(170, 176, 188), font=small)
        else:
            draw.text((18, 22), ident, fill=(255, 236, 170), font=big)
        image = image.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        image.save(out)
        with open(stamp, "w", encoding="utf-8") as handle:
            handle.write(text)
    print(f"labels {len(ids())}")


if __name__ == "__main__":
    main()
