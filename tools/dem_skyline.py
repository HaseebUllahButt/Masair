"""Raycast a 360-degree skyline from Terrarium DEM tiles.

usage: python3 -I dempano.py NAME LAT LON [eye_m] [near_km] [far_km] [zoom]
Prints tan(elevation) per 0.5 degree (720 samples) as JSON to NAME.json.
Tiles are cached in ./tiles/ (data only, decoded with PIL).
"""
import sys, os, math, json, concurrent.futures, urllib.request
from PIL import Image

name, lat0, lon0 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
eye = float(sys.argv[4]) if len(sys.argv) > 4 else 30.0
near = float(sys.argv[5]) * 1000 if len(sys.argv) > 5 else 3000.0
far = float(sys.argv[6]) * 1000 if len(sys.argv) > 6 else 45000.0
Z = int(sys.argv[7]) if len(sys.argv) > 7 else 12
R = 6371000.0
N = 2 ** Z
os.makedirs("tiles", exist_ok=True)


def tile_xy(lat, lon):
    x = (lon + 180.0) / 360.0 * N
    y = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * N
    return x, y


def offset(lat, lon, d, az):
    # flat-earth offset is fine at these ranges
    dlat = d * math.cos(az) / R
    dlon = d * math.sin(az) / (R * math.cos(math.radians(lat)))
    return lat + math.degrees(dlat), lon + math.degrees(dlon)


# bounding tiles
corners = [offset(lat0, lon0, far * 1.05, a) for a in (0, math.pi / 2, math.pi, 1.5 * math.pi)]
xs = [tile_xy(*c)[0] for c in corners]
ys = [tile_xy(*c)[1] for c in corners]
tx0, tx1 = int(min(xs)), int(max(xs))
ty0, ty1 = int(min(ys)), int(max(ys))
jobs = [(x, y) for x in range(tx0, tx1 + 1) for y in range(ty0, ty1 + 1)]


def fetch(xy):
    x, y = xy
    p = f"tiles/{Z}_{x}_{y}.png"
    if not os.path.exists(p):
        url = f"https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{Z}/{x}/{y}.png"
        for k in range(6):
            try:
                urllib.request.urlretrieve(url, p + ".part")
                os.replace(p + ".part", p)
                break
            except Exception:
                import time; time.sleep(1 + k)
    return xy, p


tiles = {}
with concurrent.futures.ThreadPoolExecutor(6) as ex:
    for xy, p in ex.map(fetch, jobs):
        tiles[xy] = Image.open(p).convert("RGB").load()


def elev(lat, lon):
    x, y = tile_xy(lat, lon)
    ix, iy = int(x), int(y)
    px = min(int((x - ix) * 256), 255)
    py = min(int((y - iy) * 256), 255)
    r, g, b = tiles[(ix, iy)][px, py]
    return r * 256 + g + b / 256.0 - 32768.0


h0 = elev(lat0, lon0) + eye
out = []
step = 25.0 if Z >= 12 else 50.0
for i in range(720):
    az = math.radians(i * 0.5)
    best = -1.0
    d = near
    while d < far:
        la, lo = offset(lat0, lon0, d, az)
        drop = d * d / (2 * R) * 0.87
        t = (elev(la, lo) - drop - h0) / d
        if t > best:
            best = t
        d += step * (1.0 + d / 15000.0)
    out.append(best)
json.dump({"name": name, "lat": lat0, "lon": lon0, "h0": h0, "tan": out}, open(name + ".json", "w"))
print(name, "h0=%.0f" % h0, "max tan %.3f min %.3f" % (max(out), min(out)), "tiles", len(jobs))
