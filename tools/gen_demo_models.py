#!/usr/bin/env python3
"""Generate demo models (STL + 3MF) for the recording / review self-test file.

Writes to publish/demo-models:
  demo-cube.stl / demo-cube.3mf          20 mm cube
  demo-cylinder.stl / demo-cylinder.3mf  40 mm diameter, 20 mm tall cylinder
Both formats describe identical geometry, so the recording can show STL and 3MF imports side by side.
"""
from __future__ import annotations

import math
import pathlib
import struct
import zipfile

OUT_DIR = pathlib.Path(r"E:\Users\jiangzan\cura\publish\demo-models")

CUBE_CORNERS = [
    (0.0, 0.0, 0.0), (20.0, 0.0, 0.0), (20.0, 20.0, 0.0), (0.0, 20.0, 0.0),
    (0.0, 0.0, 20.0), (20.0, 0.0, 20.0), (20.0, 20.0, 20.0), (0.0, 20.0, 20.0),
]
CUBE_FACES = [
    (0, 3, 2), (0, 2, 1), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
    (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7),
]


def cylinder(radius: float, height: float, segments: int) -> tuple[list, list]:
    verts: list[tuple[float, float, float]] = []
    for i in range(segments):
        angle = 2.0 * math.pi * i / segments
        x = radius * math.cos(angle)
        y = radius * math.sin(angle)
        verts.append((x, y, 0.0))
        verts.append((x, y, height))
    bottom_center = len(verts)
    verts.append((0.0, 0.0, 0.0))
    top_center = len(verts)
    verts.append((0.0, 0.0, height))

    faces: list[tuple[int, int, int]] = []
    for i in range(segments):
        n = (i + 1) % segments
        b0, t0, b1, t1 = i * 2, i * 2 + 1, n * 2, n * 2 + 1
        faces.append((b0, b1, t1))
        faces.append((b0, t1, t0))
        faces.append((bottom_center, b1, b0))
        faces.append((top_center, t0, t1))
    return verts, faces


def normal(a, b, c) -> tuple[float, float, float]:
    ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
    vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
    nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    length = math.sqrt(nx * nx + ny * ny + nz * nz)
    if length <= 1e-12:
        return (0.0, 0.0, 0.0)
    return (nx / length, ny / length, nz / length)


def write_stl(path: pathlib.Path, verts: list, faces: list) -> None:
    with path.open("wb") as handle:
        handle.write(b"\0" * 80)
        handle.write(struct.pack("<I", len(faces)))
        for a, b, c in faces:
            nx, ny, nz = normal(verts[a], verts[b], verts[c])
            data = [nx, ny, nz]
            for index in (a, b, c):
                data.extend(verts[index])
            handle.write(struct.pack("<12fH", *data, 0))


CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
</Types>
"""

RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>
"""


def write_3mf(path: pathlib.Path, verts: list, faces: list) -> None:
    vertices = "\n".join(f'<vertex x="{x}" y="{y}" z="{z}"/>' for x, y, z in verts)
    triangles = "\n".join(f'<triangle v1="{a}" v2="{b}" v3="{c}"/>' for a, b, c in faces)
    model = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<model unit="millimeter" xml:lang="en-US" '
        'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\n'
        '<resources>\n<object id="1" type="model">\n<mesh>\n'
        '<vertices>\n' + vertices + '\n</vertices>\n'
        '<triangles>\n' + triangles + '\n</triangles>\n'
        '</mesh>\n</object>\n</resources>\n'
        '<build>\n<item objectid="1"/>\n</build>\n</model>\n'
    )
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", CONTENT_TYPES)
        zf.writestr("_rels/.rels", RELS)
        zf.writestr("3D/3dmodel.model", model)


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    models = {
        "demo-cube": (CUBE_CORNERS, CUBE_FACES),
        "demo-cylinder": cylinder(20.0, 20.0, 64),
    }
    for name, (verts, faces) in models.items():
        stl_path = OUT_DIR / f"{name}.stl"
        mf_path = OUT_DIR / f"{name}.3mf"
        write_stl(stl_path, verts, faces)
        write_3mf(mf_path, verts, faces)
        print(f"{stl_path.name}: {stl_path.stat().st_size} bytes, {len(faces)} triangles")
        print(f"{mf_path.name}: {mf_path.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
