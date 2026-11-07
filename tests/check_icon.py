"""Catch incorrectly scaled ICNS layers before packaging."""
from pathlib import Path
import subprocess
import sys
import tempfile
from PIL import Image

with tempfile.TemporaryDirectory(prefix="PhotoWorkbench-icons-") as folder:
    iconset = Path(folder) / "AppIcon.iconset"
    subprocess.run(["iconutil", "-c", "iconset", sys.argv[1], "-o", str(iconset)], check=True)
    layers = list(iconset.glob("*.png"))
    for path in layers:
        image = Image.open(path).convert("RGBA")
        left, top, right, bottom = image.getchannel("A").getbbox()
        width, height = image.size
        assert right-left >= width*.85 and bottom-top >= height*.85, f"Icon too small: {path.name}"
        assert abs(left+right-width) <= width*.05 and abs(top+bottom-height) <= height*.05, f"Icon not centered: {path.name}"
    print(f"Icon checks passed: {len(layers)} layers")
