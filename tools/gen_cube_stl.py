#!/usr/bin/env python3
"""Generate a small ASCII STL test cube for end-to-end slicing checks.

Usage: python tools/gen_cube_stl.py
Writes: entry/src/main/resources/rawfile/models/cube.stl
"""

from __future__ import annotations

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = REPO_ROOT / "entry" / "src" / "main" / "resources" / "rawfile" / "models" / "cube.stl"
SIZE = 20.0

VERTICES = [
    (0.0, 0.0, 0.0),
    (SIZE, 0.0, 0.0),
    (SIZE, SIZE, 0.0),
    (0.0, SIZE, 0.0),
    (0.0, 0.0, SIZE),
    (SIZE, 0.0, SIZE),
    (SIZE, SIZE, SIZE),
    (0.0, SIZE, SIZE),
]

FACES = [
    (0, 3, 2), (0, 2, 1),  # bottom
    (4, 5, 6), (4, 6, 7),  # top
    (0, 1, 5), (0, 5, 4),  # front
    (1, 2, 6), (1, 6, 5),  # right
    (2, 3, 7), (2, 7, 6),  # back
    (3, 0, 4), (3, 4, 7),  # left
]


def main() -> int:
    lines = ["solid cube"]
    for a, b, c in FACES:
        lines.append("  facet normal 0 0 0")
        lines.append("    outer loop")
        for index in (a, b, c):
            x, y, z = VERTICES[index]
            lines.append(f"      vertex {x:.6f} {y:.6f} {z:.6f}")
        lines.append("    endloop")
        lines.append("  endfacet")
    lines.append("endsolid cube")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"Wrote {OUTPUT.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
