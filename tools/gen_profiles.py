#!/usr/bin/env python3
"""Generate a CuraEngine settings profile from Cura's setting definitions.

CuraEngine's `-j` file is not a flat key/value map: CommandLine::loadJSON() walks a Cura *definition
tree* (nested categories with `children` and leaf settings carrying `default_value`), then applies an
`overrides` map on top. CuraEngine aborts (Settings::get -> std::exit(2)) for any setting it asks for
that is absent, so the full definition tree is embedded here.

The extruder definition tree is deep-merged into the printer tree because CuraEngine creates the
extruder and mesh setting stacks with the global stack as their parent, so everything placed here is
inherited everywhere.

Usage:
    python tools/gen_profiles.py
Writes:
    entry/src/main/resources/rawfile/profiles/default.json
"""

from __future__ import annotations

import json
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CURA_DEFINITIONS = REPO_ROOT / "third_party" / "Cura" / "resources" / "definitions"
OUTPUT = REPO_ROOT / "entry" / "src" / "main" / "resources" / "rawfile" / "profiles" / "default.json"

# A small, self-consistent machine used for the first end-to-end slice.
OVERRIDES = {
    "machine_extruder_count": 1,
    "machine_width": 200,
    "machine_depth": 200,
    "machine_height": 200,
    "machine_heated_bed": True,
    "machine_center_is_zero": False,
    "machine_nozzle_size": 0.4,
    "adhesion_type": "skirt",
    "layer_height": 0.2,
    "layer_height_0": 0.2,
    "wall_thickness": 1.2,
    "infill_sparse_density": 20,
    "material_print_temperature": 200,
    "material_bed_temperature": 60,
    "speed_print": 50,
    "speed_travel": 120,
    "retraction_enable": True,
    "support_enable": False,
    "machine_start_gcode": "G28 ; home\nG1 Z15.0 F6000\nG92 E0\nG1 F200 E10\nG92 E0\n",
    "machine_end_gcode": "M104 S0\nM140 S0\nG91\nG1 E-2 F2700\nG1 Z1 F6000\nG90\nM84\n",
}


def deep_merge(base: dict, extra: dict) -> dict:
    for key, value in extra.items():
        if key in base and isinstance(base[key], dict) and isinstance(value, dict):
            deep_merge(base[key], value)
        else:
            base[key] = value
    return base


def main() -> int:
    if not CURA_DEFINITIONS.is_dir():
        print(f"Cura definitions not found at {CURA_DEFINITIONS}", file=sys.stderr)
        return 1

    with (CURA_DEFINITIONS / "fdmprinter.def.json").open("r", encoding="utf-8") as handle:
        printer = json.load(handle)
    with (CURA_DEFINITIONS / "fdmextruder.def.json").open("r", encoding="utf-8") as handle:
        extruder = json.load(handle)

    settings_tree = printer.get("settings", {})
    deep_merge(settings_tree, extruder.get("settings", {}))

    document = {
        "version": printer.get("version", 2),
        "settings": settings_tree,
        "overrides": OVERRIDES,
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=1)

    leaves = count_leaves(settings_tree)
    print(f"Wrote definition tree ({leaves} settings) + {len(OVERRIDES)} overrides to {OUTPUT.relative_to(REPO_ROOT)}")
    return 0


def count_leaves(node: dict) -> int:
    total = 0
    for value in node.values():
        if not isinstance(value, dict):
            continue
        if "children" in value and isinstance(value["children"], dict):
            total += count_leaves(value["children"])
        elif "default_value" in value or "value" in value:
            total += 1
    return total


if __name__ == "__main__":
    raise SystemExit(main())
