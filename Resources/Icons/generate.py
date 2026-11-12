#!/usr/bin/env python3
# Lynx logo made of battery cells: outline, cells and four color variants.
# Writes .icon sources for Icon Composer and the mark for the full-screen alert. Requires shapely.
# Don't run directly; use Resources/Icons/build-icons.sh.
import json
import pathlib
import shutil
from shapely.geometry import Polygon, box
from shapely.ops import unary_union

HERE = pathlib.Path(__file__).resolve().parent
WHITE, GREEN, INK = "#FFFFFF", "#30D158", "#0E0E10"

# Geometry on a 1000×1000 canvas, symmetric about x=500.
C = 500
B, G, T = 62, 18, 120              # outline thickness, gap, row height
R_OUT, R_IN, R_HOLE, R_CELL, R_TRI = 26, 10, 12, 14, 7
TOP_Y = 321
HALF = [(50, TOP_Y), (108, 186), (207, 186), (371, 597), (286, 824), (100, 879)]
TUFT = (138, 178, 100, 168)
WIDE = 500
NOSE, EYE, OUTER = (-24, 24), (42, 190), (208, WIDE)

MITRE = dict(join_style="mitre", mitre_limit=10)
raw = Polygon([(C + x, y) for x, y in HALF] + [(C - x, y) for x, y in reversed(HALF)])
head = raw.buffer(-R_OUT).buffer(R_OUT).buffer(R_IN).buffer(-R_IN)
hard = raw.buffer(-B, **MITRE)
opening = hard.buffer(-R_HOLE).buffer(R_HOLE).buffer(R_IN).buffer(-R_IN)
inside = hard.buffer(-G, **MITRE)
ROW_0 = TOP_Y + B + G


def row(i):
    y = ROW_0 + i * (T + G)
    return y, y + T


def cell(i, a, b):
    """Cell of row i from dx=a to dx=b, clipped by the outline. For a<0 a single one in the middle, otherwise a pair."""
    y0, y1 = row(i)
    boxes = [box(C + a, y0, C + b, y1)] if a < 0 else [box(C + a, y0, C + b, y1), box(C - b, y0, C - a, y1)]
    return [p.intersection(inside).buffer(-R_CELL).buffer(R_CELL) for p in boxes]


def parts(g):
    return [g] if g.geom_type == "Polygon" else list(g.geoms)


BORDER = [head.difference(opening)]
a, b, y0, y1 = TUFT
TUFTS = [box(x0, y0, x1, y1).buffer(-R_CELL).buffer(R_CELL) for x0, x1 in ((C + a, C + b), (C - b, C - a))]
TRIANGLES = parts(box(0, 0, 1000, ROW_0 - G).intersection(inside).buffer(-R_TRI).buffer(R_TRI))
SOLID = cell(0, -WIDE, WIDE) + cell(2, -WIDE, WIDE)
EYES = cell(1, *EYE)
EYE_ROW_REST = cell(1, *NOSE) + cell(1, *OUTER)
PLAIN_ROW = cell(1, -WIDE, WIDE)

# Variant: layers from top to bottom, (name, shapes, color). The first variant is baked into the app as the glass icon.
VARIANTS = {
    "green-eyes": [("eyes", EYES, GREEN), ("cells", SOLID + EYE_ROW_REST + TRIANGLES, WHITE), ("border", BORDER + TUFTS, WHITE)],
    "white-eyes": [("cells", SOLID + EYES + EYE_ROW_REST + TRIANGLES, WHITE), ("border", BORDER + TUFTS, WHITE)],
    "plain": [("cells", SOLID + PLAIN_ROW + TRIANGLES, WHITE), ("border", BORDER + TUFTS, WHITE)],
    "green-cells": [("cells", SOLID + PLAIN_ROW + TRIANGLES, GREEN), ("border", BORDER + TUFTS, WHITE)],
}

# Mark within a 1024 canvas: centered by its bounding box.
everything = unary_union(BORDER + TUFTS)
x0, y0, x1, y1 = everything.bounds
MARK_SCALE = 1.0
OFFSET_X, OFFSET_Y = 512 - (x0 + x1) / 2 * MARK_SCALE, 512 - (y0 + y1) / 2 * MARK_SCALE


def path_d(shapes, scale=MARK_SCALE, dx=OFFSET_X, dy=OFFSET_Y):
    def ring(r):
        return "M" + " ".join(f"{x * scale + dx:.1f},{y * scale + dy:.1f}" for x, y in list(r.coords)[:-1]) + "Z"
    out = ""
    for shape in shapes:
        for p in parts(shape.simplify(0.2)):
            if p.is_empty or p.area < 300:
                continue
            out += ring(p.exterior) + "".join(ring(i) for i in p.interiors)
    return out


def svg(shapes, fill):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<path fill="{fill}" fill-rule="evenodd" d="{path_d(shapes)}"/></svg>\n')


def write_icon(name, layers):
    root = HERE / f"{name}.icon"
    shutil.rmtree(root, ignore_errors=True)
    (root / "Assets").mkdir(parents=True)
    groups = []
    for layer, shapes, fill in layers:
        (root / "Assets" / f"{layer}.svg").write_text(svg(shapes, fill))
        groups.append({
            "layers": [{"image-name": f"{layer}.svg", "name": layer, "glass": True}],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.4},
        })
    doc = {
        # sRGB from Brand.ink
        "fill": {"solid": "srgb:0.05490,0.05490,0.06275,1.00000"},
        "groups": groups,
        "supported-platforms": {"squares": ["macOS"]},
    }
    (root / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")


for variant, layers in VARIANTS.items():
    write_icon(variant, layers)

# Single-color mark without background: for the full-screen alert on the sky scene.
(HERE.parent / "Marks" / "lynx-ink.svg").write_text(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 1000 1000">'
    f'<path fill="{INK}" fill-rule="evenodd" d="{path_d(BORDER + TUFTS + SOLID + EYES + EYE_ROW_REST + TRIANGLES, 1, 0, 11)}"/></svg>\n'
)
print("variants:", ", ".join(VARIANTS))
