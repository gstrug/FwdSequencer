#!/usr/bin/env python3
"""Make the AppMark image set from the app icon.

The empty song list shows the app's own icon. An icon in an asset catalog cannot be
loaded by name at runtime, so a separate image set holds its own copies, at the three
screen scales for a 112pt square.

Run this after changing the app icon, or the two drift apart:

    python3 Tools/make_app_mark.py
"""
from pathlib import Path
from PIL import Image

POINTS = 112
HERE = Path(__file__).resolve().parent.parent
SOURCE = HERE / "FwdSequencer/Assets.xcassets/AppIcon.appiconset/1024.png"
TARGET = HERE / "FwdSequencer/Assets.xcassets/AppMark.imageset"

def main() -> None:
    icon = Image.open(SOURCE).convert("RGB")
    TARGET.mkdir(parents=True, exist_ok=True)
    images = []
    for scale in (1, 2, 3):
        name = f"AppMark{'' if scale == 1 else f'@{scale}x'}.png"
        side = POINTS * scale
        icon.resize((side, side), Image.LANCZOS).save(TARGET / name, optimize=True)
        images.append(f'''    {{
      "filename" : "{name}",
      "idiom" : "universal",
      "scale" : "{scale}x"
    }}''')
    (TARGET / "Contents.json").write_text(
        '{\n  "images" : [\n' + ",\n".join(images) +
        '\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
    )
    print(f"wrote {TARGET.relative_to(HERE)} at {POINTS}pt")

if __name__ == "__main__":
    main()
