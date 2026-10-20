"""Fail the build if an installed app icon has opaque square corners."""
from pathlib import Path
import sys
from PIL import Image

root = Path(sys.argv[1] if len(sys.argv) > 1 else "Resources")
icons = sorted(root.glob("Icon*.png"))
if not icons:
    raise SystemExit("No application icons found")
failures = []
for path in icons:
    with Image.open(path) as source:
        image = source.convert("RGBA")
        w, h = image.size
        corners = ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))
        if any(image.getpixel(point)[3] > 10 for point in corners):
            failures.append(path.name + ": opaque corner")
        if image.getpixel((w // 2, h // 2))[3] < 200:
            failures.append(path.name + ": transparent center")
if failures:
    raise SystemExit("\n".join(failures))
print(f"Rounded icon corners verified: {len(icons)} sizes")
