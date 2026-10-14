"""Write scripts/mtn_profiles.gd from the JSON panoramas tools/dem_skyline.py made.

usage (from a scratch folder holding the *.json files):
  python3 -I /path/to/tools/dem_skylines_gd.py /path/to/scripts/mtn_profiles.gd
"""
import json, sys

VIEWS = [
    ("fells", "Keswick, English Lake District"),
    ("giau", "Passo Giau, Dolomites"),
    ("cortina", "Cortina d'Ampezzo, Dolomites"),
    ("misurina", "Lago di Misurina, Tre Cime / Cadini"),
    ("zermatt", "Gornergrat, Matterhorn / Monte Rosa"),
    ("grindelwald", "Maennlichen, Eiger / Moench / Jungfrau"),
    ("chamonix", "Le Brevent, Mont Blanc massif"),
    ("banff", "Banff townsite, Canadian Rockies"),
]
out = sys.argv[1]
lines = [
    "class_name MtnProfiles",
    "## 360-degree horizon skylines raycast from real DEM elevation data",
    "## (Mapzen/Tilezen Terrarium tiles, zoom 12 — public-domain SRTM + EU-DEM +",
    "## national lidar, via the AWS open-data mirror). Regenerate with",
    "## tools/dem_skyline.py (one panorama per viewpoint) + tools/dem_skylines_gd.py.",
    "##",
    "## Terrain nearer than a few kilometres is skipped by the raycast: a valley",
    "## floor's own walls otherwise fill most of the ring as long flat-topped",
    "## slabs, and what the eye wants on a horizon is the distant crest line.",
    "## 720 samples (0.5 degree each), min..max of the panorama mapped to 0..255.",
    "##",
]
for key, label in VIEWS:
    d = json.load(open(key + ".json"))
    lines.append("##   %-11s - %s (%.3f,%.3f)" % (key, label, d["lat"], d["lon"]))
lines.append("")
for key, _ in VIEWS:
    t = json.load(open(key + ".json"))["tan"]
    lo, hi = min(t), max(t)
    v = [max(0, min(255, round((x - lo) / (hi - lo) * 255))) for x in t]
    lines.append("const %s_MAX_TAN := %.6f" % (key.upper(), hi))
    lines.append("const %s := [" % key.upper())
    for i in range(0, len(v), 24):
        lines.append("\t" + ", ".join(str(x) for x in v[i:i + 24]) + ",")
    lines.append("]")
    lines.append("")
lines.append("const ALL := {")
for key, _ in VIEWS:
    lines.append('\t"%s": {"profile": %s, "max_tan": %s_MAX_TAN},' % (key, key.upper(), key.upper()))
lines.append("}")
open(out, "w").write("\n".join(lines) + "\n")
