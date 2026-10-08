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

# Kingroon KP3S: 180 x 180 x 180 mm build volume, Marlin flavour.
OVERRIDES = {
    "machine_extruder_count": 1,
    "machine_width": 180,
    "machine_depth": 180,
    "machine_height": 180,
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
    "machine_start_gcode": (
        "G28 ; home all axes\n"
        "M117 Purge extruder\n"
        "G92 E0 ; reset extruder\n"
        "G1 Z1.0 F3000 ; move z up little to prevent scratching of surface\n"
        "G1 X2 Y20 Z0.3 F5000.0 ; move to start-line position\n"
        "G1 X2 Y175.0 Z0.3 F1500.0 E15 ; draw 1st line\n"
        "G1 X2 Y175.0 Z0.4 F5000.0 ; move to side a little\n"
        "G1 X2 Y20 Z0.4 F1500.0 E30 ; draw 2nd line\n"
        "G92 E0 ; reset extruder\n"
        "G1 Z1.0 F3000 ; move z up little to prevent scratching of surface\n"
    ),
    "machine_end_gcode": (
        "G91; relative positioning\n"
        "G1 Z1.0 F3000 ; move z up little to prevent scratching of print\n"
        "G90; absolute positioning\n"
        "G1 X0 Y200 F1000 ; prepare for part removal\n"
        "M104 S0; turn off extruder\n"
        "M140 S0 ; turn off bed\n"
        "G1 X0 Y300 F1000 ; prepare for part removal\n"
        "M84 ; disable motors\n"
        "M106 S0 ; turn off fan\n"
    ),
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
