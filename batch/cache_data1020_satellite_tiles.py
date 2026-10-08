"""Cache verified Esri World Imagery tiles for a numeric geographic extent.

Usage: python cache_data1020_satellite_tiles.py REQUEST.json
The request has cacheDir, bounds=[west,south,east,north], manifestPath,
and an optional zoom. No credentials and no receiver data leave this host.
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import json
import math
from pathlib import Path
import sys
import time
import urllib.request

SERVICE = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer"
ATTRIBUTION = "Source: Esri, Vantor, Earthstar Geographics, and the GIS User Community"


def get_bytes(url: str) -> bytes:
    error = None
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "DATA1020-research-map/1.0"})
            with urllib.request.urlopen(request, timeout=35) as response:
                if response.status != 200:
                    raise RuntimeError(f"HTTP {response.status}: {url}")
                return response.read()
        except Exception as exc:
            error = exc
            time.sleep(attempt + 0.5)
    raise RuntimeError(f"Cannot download imagery: {url}: {error}")


def tile_coordinates(lon: float, lat: float, zoom: int) -> tuple[float, float]:
    n = 2**zoom
    phi = math.radians(lat)
    return (lon + 180) / 360 * n, (1 - math.asinh(math.tan(phi)) / math.pi) / 2 * n


def main() -> None:
    request = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
    west, south, east, north = (float(x) for x in request["bounds"])
    assert -180 < west < east < 180 and -80 < south < north < 80
    zoom = request.get("zoom")
    if zoom is None:
        # About 1500 source pixels along the longer map dimension; bounded
        # to a few dozen tiles per experiment and suitable for 160-dpi PNG.
        left, top = tile_coordinates(west, north, 0)
        right, bottom = tile_coordinates(east, south, 0)
        zoom = max(6, min(17, math.ceil(math.log2(1500 / (256 * max(right-left,bottom-top))))))
    zoom = int(zoom)
    while True:
        left, top = tile_coordinates(west, north, zoom)
        right, bottom = tile_coordinates(east, south, zoom)
        x_min, y_min, x_max, y_max = math.floor(left), math.floor(top), math.floor(right), math.floor(bottom)
        if 256 * max(x_max-x_min+1,y_max-y_min+1) <= 2816:
            break
        zoom -= 1
    cache = Path(request["cacheDir"]).resolve()
    cache.mkdir(parents=True, exist_ok=True)

    def fetch(key: tuple[int, int]) -> dict:
        x, y = key
        path = cache / str(zoom) / str(y) / f"{x}.jpg"
        path.parent.mkdir(parents=True, exist_ok=True)
        data = path.read_bytes() if path.exists() else b""
        url = f"{SERVICE}/tile/{zoom}/{y}/{x}"
        if not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
            data = get_bytes(url)
            if not (data.startswith(b"\xff\xd8") and data.endswith(b"\xff\xd9")):
                raise RuntimeError(f"Expected a complete JPEG, received {len(data)} bytes from {url}")
            path.write_bytes(data)
        return {"x": x, "y": y, "z": zoom, "file": str(path), "url": url,
                "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    keys = [(x,y) for y in range(y_min,y_max+1) for x in range(x_min,x_max+1)]
    assert len(keys) <= 144, f"Unexpected tile count: {len(keys)}"
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        tiles = list(executor.map(fetch, keys))
    meta_path = cache / "service_metadata.json"
    if not meta_path.exists():
        meta = json.loads(get_bytes(SERVICE + "?f=json"))
        meta_path.write_text(json.dumps(meta,ensure_ascii=False,indent=2),encoding="utf-8")
    else:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
    result = {"service":SERVICE,"attribution":meta.get("copyrightText",ATTRIBUTION),
              "projection":"EPSG:3857 / Web Mercator", "zoom":zoom,
              "xMin":x_min,"xMax":x_max,"yMin":y_min,"yMax":y_max,
              "requestedBounds":request["bounds"], "tileCount":len(tiles),
              "tiles":tiles,"cachedAtUtc":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}
    target = Path(request["manifestPath"])
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
    print(json.dumps({"tileCount":len(tiles),"zoom":zoom,"manifest":str(target)}))


if __name__ == "__main__":
    main()
