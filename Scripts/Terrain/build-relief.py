#!/usr/bin/env python3
"""Build-time terrain preparation, never called by the native app.

Requires Pillow. Public terrain downloads are cached locally; --offline rebuilds
without network. The output shares the radar manifest's exact EPSG:3857 bbox.
"""
import argparse
import concurrent.futures
import hashlib
import io
import json
import math
from pathlib import Path
import urllib.request
from PIL import Image, ImageMath

ROOT = Path(__file__).resolve().parents[2]
GEO = ROOT / "Sources/MeteocatCore/Resources/Geography"
HALF = 20037508.342789244
ZOOM = 8
WIDTH, HEIGHT = 1360, 760

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=Path("/tmp/meteocat-terrain-z8"))
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    manifest_bytes = (GEO / "projection-manifest.json").read_bytes()
    bbox = json.loads(manifest_bytes)["bbox"]
    xmin, ymin, xmax, ymax = bbox
    span = HALF * 2 / 2**ZOOM
    x0, x1 = math.floor((xmin+HALF)/span), math.floor((xmax+HALF)/span)
    y0, y1 = math.floor((HALF-ymax)/span), math.floor((HALF-ymin)/span)

    def fetch(coordinate):
        x, y = coordinate
        url = f"https://elevation-tiles-prod.s3.amazonaws.com/terrarium/{ZOOM}/{x}/{y}.png"
        path = args.cache / f"{ZOOM}-{x}-{y}.png"
        if not path.exists():
            if args.offline:
                raise RuntimeError(f"Missing local terrain tile: {path}")
            with urllib.request.urlopen(url, timeout=25) as response:
                data = response.read(2 * 1024 * 1024 + 1)
            if len(data) > 2 * 1024 * 1024:
                raise RuntimeError("Oversized terrain tile")
            image = Image.open(io.BytesIO(data)); image.load()
            if image.size != (256, 256):
                raise RuntimeError("Unexpected terrain dimensions")
            path.write_bytes(data)
        data = path.read_bytes()
        image = Image.open(io.BytesIO(data)); image.load()
        if image.size != (256, 256):
            raise RuntimeError("Invalid cached terrain dimensions")
        return x, y, image.convert("RGB"), {"url": url, "sha256": hashlib.sha256(data).hexdigest()}

    grid = [(x,y) for y in range(y0,y1+1) for x in range(x0,x1+1)]
    mosaic = Image.new("RGB", ((x1-x0+1)*256, (y1-y0+1)*256))
    sources = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for x,y,image,provenance in pool.map(fetch, grid):
            mosaic.paste(image, ((x-x0)*256,(y-y0)*256)); sources.append(provenance)
    r,g,b = mosaic.split()
    elevation = ImageMath.lambda_eval(lambda a: a["r"]*256 + a["g"] + a["b"]/256 - 32768,
                                    r=r.convert("F"), g=g.convert("F"), b=b.convert("F"))
    # Pillow affine coordinates map destination pixel centres to source centres.
    sx = (xmax-xmin)/WIDTH/span*256
    sy = (ymax-ymin)/HEIGHT/span*256
    ox = (xmin-(x0*span-HALF))/span*256
    oy = ((HALF-y0*span)-ymax)/span*256
    elevation = elevation.transform((WIDTH,HEIGHT), Image.Transform.AFFINE,
                                    (sx,0,ox,0,sy,oy), Image.Resampling.BILINEAR)
    values = list(getattr(elevation, "get_flattened_data", elevation.getdata)())
    overlay = bytearray(WIDTH*HEIGHT*4)
    flat = math.sqrt(0.5)
    lights = [(-0.5,-0.5,flat), (-flat,0,flat), (0,-flat,flat)]
    for y in range(HEIGHT):
        latitude = math.atan(math.sinh((ymax-(y+0.5)/HEIGHT*(ymax-ymin))/6378137))
        dx = (xmax-xmin)/WIDTH*math.cos(latitude)
        dy = (ymax-ymin)/HEIGHT*math.cos(latitude)
        for x in range(WIDTH):
            i = y*WIDTH+x
            height = values[i]
            if height <= 0:
                continue  # No sea bathymetry shading.
            west, east = y*WIDTH+max(0,x-1), y*WIDTH+min(WIDTH-1,x+1)
            north, south = max(0,y-1)*WIDTH+x, min(HEIGHT-1,y+1)*WIDTH+x
            gx = (values[east]-values[west])/(dx*(2 if 0<x<WIDTH-1 else 1))*2
            gy = (values[south]-values[north])/(dy*(2 if 0<y<HEIGHT-1 else 1))*2
            length = math.sqrt(gx*gx+gy*gy+1)
            shade = sum((-gx*lx-gy*ly+lz)/length for lx,ly,lz in lights)/len(lights)
            delta = (shade-flat)*30*min(1,height/30)
            if delta >= 0:
                channel, alpha = 255, min(14,round(delta*255/227))
            else:
                channel, alpha = 0, min(96,round(-delta*255/28))
            overlay[i*4:i*4+4] = bytes((channel,channel,channel,alpha))
    output = GEO / "terrain-relief.png"
    Image.frombytes("RGBA",(WIDTH,HEIGHT),bytes(overlay)).save(output,optimize=True)
    provenance = {
        "dataset": "Mapzen Terrain Tiles, accessed 2026-10-07",
        "registry": "https://registry.opendata.aws/terrain-tiles/",
        "format_documentation": "https://github.com/tilezen/joerd/blob/master/docs/formats.md",
        "attribution_documentation": "https://github.com/tilezen/joerd/blob/master/docs/attribution.md",
        "attribution": "Terrain: Mapzen; Europe terrain data produced using Copernicus data and information funded by the European Union — EU-DEM layers; SRTM terrain data courtesy of NASA and the U.S. Geological Survey; Global ETOPO1 terrain data U.S. National Oceanic and Atmospheric Administration.",
        "crs": "EPSG:3857", "bbox": bbox, "size": [WIDTH,HEIGHT],
        "projection_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "processing": "Terrarium decoded to metres; bilinear reprojection to exact bbox; three-light hillshade with 2x vertical exaggeration, subdued monochrome alpha, sea elevations excluded. Presentation only.",
        "runtime_network": False, "tiles": sources
    }
    (GEO/"terrain-provenance.json").write_text(json.dumps(provenance,indent=2)+"\n")
    print(f"Generated {output}: {output.stat().st_size} bytes; {len(sources)} source tiles")

if __name__ == "__main__":
    main()
