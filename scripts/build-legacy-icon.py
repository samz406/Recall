#!/usr/bin/env python3
"""Export the opaque artwork to legacy ICNS sizes with one clean, consistent mask.

Requires Pillow. This only resamples and applies the platform enclosure; the
blue clock artwork itself is generated, not redrawn by this export script.
"""
import io
import struct
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parent.parent
art = Image.open(root / "Resources/AppIcon.icon/Assets/Recall.png").convert("RGB")
assert art.size == (1024, 1024)
chunks = []
representations = [
    (b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128),
    (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
    (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
]
exports = {}
for kind, size in representations:
    if size not in exports:
        # Supersample a standard centered enclosure: no shadows, alpha haze or backplate.
        scale = 4
        edge = size * scale
        radius = edge * 0.45
        mask = Image.new("L", (edge, edge))
        mask.putdata([
            255 if abs((x + 0.5 - edge / 2) / radius) ** 5
            + abs((y + 0.5 - edge / 2) / radius) ** 5 <= 1 else 0
            for y in range(edge) for x in range(edge)
        ])
        image = art.resize((size, size), Image.Resampling.LANCZOS).convert("RGBA")
        alpha = mask.resize((size, size), Image.Resampling.LANCZOS)
        image.putalpha(alpha.point([0 if value < 2 else value for value in range(256)]))
        out = io.BytesIO()
        image.save(out, format="PNG", optimize=True)
        exports[size] = out.getvalue()
    png = exports[size]
    chunks.append(kind + struct.pack(">I", len(png) + 8) + png)
body = b"".join(chunks)
(root / "Resources/AppIcon.icns").write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
print("Exported 11 consistent ICNS representations (16–1024 px).")
