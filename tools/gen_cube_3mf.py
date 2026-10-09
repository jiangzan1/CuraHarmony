#!/usr/bin/env python3
"""Generate a minimal valid 3MF cube for testing the 3MF import path.

Writes a 20 mm cube (0..20 on each axis) as a 3MF package: [Content_Types].xml, _rels/.rels and
3D/3dmodel.model with one mesh. CuraEngine cannot read 3MF, so this file exercises the ArkTS
converter (unzip -> parse -> binary STL).
"""
from __future__ import annotations

import pathlib
import zipfile

OUT = pathlib.Path(r"E:\Users\jiangzan\cura\publish\test-cube.3mf")

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

CORNERS = [
    (0.0, 0.0, 0.0), (20.0, 0.0, 0.0), (20.0, 20.0, 0.0), (0.0, 20.0, 0.0),
    (0.0, 0.0, 20.0), (20.0, 0.0, 20.0), (20.0, 20.0, 20.0), (0.0, 20.0, 20.0),
]
FACES = [
    (0, 3, 2), (0, 2, 1), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
    (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7),
]


def main() -> int:
    vertices = "\n".join(
        f'<vertex x="{x}" y="{y}" z="{z}"/>' for x, y, z in CORNERS
    )
    triangles = "\n".join(
        f'<triangle v1="{a}" v2="{b}" v3="{c}"/>' for a, b, c in FACES
    )
    model = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<model unit="millimeter" xml:lang="en-US" '
        'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\n'
        '<resources>\n'
        '<object id="1" type="model">\n'
        '<mesh>\n<vertices>\n' + vertices + '\n</vertices>\n'
        '<triangles>\n' + triangles + '\n</triangles>\n'
        '</mesh>\n</object>\n</resources>\n'
        '<build>\n<item objectid="1"/>\n</build>\n'
        '</model>\n'
    )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", CONTENT_TYPES)
        zf.writestr("_rels/.rels", RELS)
        zf.writestr("3D/3dmodel.model", model)
    print(f"Wrote {OUT} ({OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
