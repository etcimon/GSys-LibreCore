# Paint one dark plaque per part id. Unreal imports these; it does not run Pillow.

import json
import os

from PIL import Image, ImageDraw, ImageFont

CONTENT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENES = ("Boards/scene.json", "Boards/product/scene.json")
OUT = os.path.join(CONTENT, "Textures", "Labels")


def ids():
    found = set()
    for rel in SCENES:
        path = os.path.join(CONTENT, rel)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as handle:
            for body in json.load(handle):
                if body.get("id") not in ("pcb", "shield"):
                    found.add(body["id"])
    return sorted(found)


def main():
    os.makedirs(OUT, exist_ok=True)
    font = ImageFont.truetype(r"C:\Windows\Fonts\arialbd.ttf", 72)
    for ident in ids():
        out = os.path.join(OUT, f"L_{ident}.png")
        if os.path.isfile(out):
            continue
        image = Image.new("RGB", (512, 128), (16, 18, 22))
        draw = ImageDraw.Draw(image)
        draw.text((18, 22), ident, fill=(255, 236, 170), font=font)
        image = image.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        image.save(out)
    print(f"labels {len(ids())}")


if __name__ == "__main__":
    main()
