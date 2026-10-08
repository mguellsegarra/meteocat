#!/usr/bin/env python3
"""Offline context-stroke ownership; uv run --with shapely==2.2.0 python this-file --apply.
Only --apply changes packaged resources. Inputs are the saved pre-fix underlay and
unchanged canonical ICGC paths; no downloads, projection changes or simplification.
"""
import argparse
import base64
import copy
import hashlib
import json
import math
import re
import subprocess
from pathlib import Path
import xml.etree.ElementTree as ET

import shapely
from shapely.geometry import LineString, Point
from shapely.ops import nearest_points, unary_union

ROOT = Path(__file__).resolve().parents[2]
GEO = ROOT / 'Sources/MeteocatCore/Resources/Geography'
OUT = ROOT / 'Design/border-fix-20261007'
NS = '{http://www.w3.org/2000/svg}'
TOLERANCE = 2.30  # canonical pixels, not screen points or a physical accuracy claim
ROUNDING = 0.001
SAMPLE_STEP = 0.025
GROUP = re.compile(r'(<g id="context-boundaries"[^>]*>)(.*?)(</g>)', re.S)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def lines(d):
    # This derivation accepts only the actual absolute M/L/Z source vocabulary.
    assert set(re.findall('[a-zA-Z]', d)) <= {'M', 'L', 'Z'}
    result = []
    for sub in re.findall(r'M([^M]+)', d):
        values = [float(v) for v in re.findall(r'-?\d+(?:\.\d+)?', sub)]
        assert len(values) % 2 == 0
        points = list(zip(values[::2], values[1::2]))
        if 'Z' in sub and points[-1] != points[0]:
            points.append(points[0])
        assert len(points) >= 2
        result.append(LineString(points))
    return result

def parts(geometry):
    if geometry.is_empty:
        return []
    if geometry.geom_type == 'LineString':
        return [geometry]
    return [line for child in geometry.geoms for line in parts(child)
            if line.geom_type == 'LineString']

def path_data(items):
    return ''.join('M' + 'L'.join(f'{x:.3f},{y:.3f}' for x, y in line.coords)
                   for line in items)

def sampled_max(line, target):
    count = max(1, math.ceil(line.length / SAMPLE_STEP))
    return max(line.interpolate(i * line.length / count).distance(target)
               for i in range(count + 1))

def svg_file(name, viewbox, body, width=1200, height=800):
    x, y, w, h = viewbox
    text = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="{x} {y} {w} {h}"><rect x="{x}" y="{y}" width="{w}" '
            f'height="{h}" fill="#0F1114"/>{body}</svg>\n')
    (OUT / name).write_text(text)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--render', action='store_true', help='Rasterize diagnostic SVGs with installed ImageMagick')
    args = parser.parse_args()
    assert shapely.__version__ == '2.2.0', 'Use the pinned Shapely version.'
    original = (OUT / 'before/layer-under.svg').read_text()
    source_provenance = (OUT / 'before/context-provenance.json').read_bytes()
    canonical_bytes = (GEO / 'paths.svg').read_bytes()
    canonical_tree = ET.fromstring(canonical_bytes)
    canonical_path = canonical_tree.find(f".//{NS}path[@id='catalunya-outline']")
    outline = unary_union(lines(canonical_path.get('d')))
    # The buffer is only a stroke-exclusion derivation. It never clips fills.
    band = outline.buffer(TOLERANCE, quad_segs=32)
    source_group = ET.fromstring('<svg xmlns="http://www.w3.org/2000/svg">' +
                                 GROUP.search(original).group(0) + '</svg>')[0]
    stats = []
    new_d = {}
    for path in source_group:
        country = path.get('data-country')
        original_lines = lines(path.get('d'))
        retained = []
        connectors = []
        fully_removed = []
        for index, line in enumerate(original_lines):
            remaining = parts(line.difference(band))
            if not remaining:
                maximum = sampled_max(line, outline)
                # Lipschitz upper bound between dense samples.
                assert maximum + SAMPLE_STEP / 2 < TOLERANCE
                fully_removed.append({'subpath': index, 'length': line.length,
                                      'maxSampleDistance': maximum,
                                      'distanceUpperBound': maximum + SAMPLE_STEP / 2})
            for segment in remaining:
                points = list(segment.coords)
                # Reconnect each newly cut junction to the unchanged ICGC exterior.
                # Endpoints of source chains that were not cut stay byte-precision exact.
                for endpoint, original_endpoint in [(0, line.coords[0]), (-1, line.coords[-1])]:
                    point = Point(points[endpoint])
                    if point.distance(Point(original_endpoint)) > ROUNDING:
                        nearest = nearest_points(point, outline)[1]
                        connector = LineString([point, nearest])
                        assert connector.length <= TOLERANCE + ROUNDING
                        assert connector.difference(band.buffer(ROUNDING)).length < ROUNDING
                        connectors.append({'from': list(point.coords)[0],
                                           'to': list(nearest.coords)[0], 'length': connector.length})
                        if endpoint == 0:
                            points.insert(0, tuple(nearest.coords)[0])
                        else:
                            points.append(tuple(nearest.coords)[0])
                retained.append(LineString(points))
        new_d[country] = path_data(retained)
        for connector in connectors:
            rounded_endpoint = Point(*(round(v, 3) for v in connector['to']))
            assert rounded_endpoint.distance(outline) <= math.sqrt(2) * ROUNDING / 2
        source = unary_union(original_lines)
        derived = unary_union(lines(new_d[country]))
        removed = source.difference(derived.buffer(ROUNDING))
        added = derived.difference(source.buffer(ROUNDING))
        # Every changed stroke lies within the canonical exclusion band (rounding allowance).
        assert removed.difference(band.buffer(0.002)).length < 0.002
        assert added.difference(band.buffer(0.002)).length < 0.002
        # Every original context segment outside the band survives; no country-wide removal.
        far = source.difference(band.buffer(0.002))
        assert far.difference(derived.buffer(0.002)).length < 0.002
        assert derived.length > 20
        stats.append({'country': country, 'sourceSubpaths': len(original_lines),
                      'derivedSubpaths': len(retained), 'sourceLength': source.length,
                      'derivedLength': derived.length, 'removedLength': removed.length,
                      'fullyRemoved': fully_removed, 'junctionConnectors': connectors,
                      'unchangedOutsideBandLength': far.length})
    group_match = GROUP.search(original)
    new_body = group_match.group(2)
    for country, d in new_d.items():
        pattern = re.compile(r'(<path data-country="' + country + r'" d=")[^"]*(")')
        new_body, count = pattern.subn(lambda m: m.group(1) + d + m.group(2), new_body)
        assert count == 1
    derived_text = original[:group_match.start(2)] + new_body + original[group_match.end(2):]
    assert GROUP.sub('', derived_text) == GROUP.sub('', original)
    derived_tree = ET.fromstring(derived_text)
    derived_group = derived_tree.find(f".//{NS}g[@id='context-boundaries']")
    # Source format stays within Geography.SVGLoader's supported M/L vocabulary.
    assert all(set(re.findall('[a-zA-Z]', p.get('d'))) <= {'M', 'L'} for p in derived_group)
    for tree in [ET.fromstring(original), derived_tree]:
        assert tree.attrib == {'width': '680', 'height': '380', 'viewBox': '0 0 680 380',
                               'fill-rule': 'evenodd'}
    protected = {p.name: digest(p.read_bytes()) for p in sorted(GEO.iterdir())
                 if p.is_file() and p.name not in ['layer-under.svg', 'context-provenance.json']}
    provenance = json.loads(source_provenance)
    provenance['derivedContextStrokes'] = {
        'date': '2026-10-07', 'script': 'Scripts/Geography/derive-context-strokes.py',
        'sourceUnderlay': 'Design/border-fix-20261007/before/layer-under.svg',
        'sourceUnderlaySHA256': digest(original.encode()),
        'canonicalExterior': 'paths.svg#catalunya-outline',
        'canonicalPathsSHA256': digest(canonical_bytes),
        'outputUnderlaySHA256': digest(derived_text.encode()),
        'toleranceCanonicalPixels': TOLERANCE, 'roundingCanonicalPixels': ROUNDING,
        'method': 'Subtract a 2.30 canonical-pixel buffer of unchanged ICGC exterior from Natural Earth context strokes only; reconnect cut endpoints to nearest ICGC exterior within the same band. Keep every original context segment outside the band. No fill, terrain, comarca, bbox or projection changes.',
        'ownership': 'ICGC owns Catalunya exterior including shoreline; Natural Earth retains surrounding country borders and coast beyond local junction reconciliation.',
        'limitations': 'Presentation tolerance, not geographic accuracy. Short straight junction connectors reconcile independent generalization; original Natural Earth geometry and source provenance are saved. Offline SVG renders are not native alignment validation.',
        'shapelyVersion': shapely.__version__, 'geosVersion': shapely.geos_version_string,
    }
    provenance_text = json.dumps(provenance, indent=2, ensure_ascii=False) + '\n'
    (OUT / 'layer-under-derived.svg').write_text(derived_text)
    (OUT / 'context-provenance-derived.json').write_text(provenance_text)
    report = {'toleranceCanonicalPixels': TOLERANCE, 'samplingStepCanonicalPixels': SAMPLE_STEP,
              'protectedResourcesSHA256': protected, 'countries': stats,
              'checks': ['changes confined to canonical band', 'all source strokes outside band retained',
                         'fully removed subpaths dense distance upper bound within tolerance',
                         'all new junctions end on canonical ICGC', 'non-context underlay bytes identical',
                         'SVG extent and loader vocabulary unchanged', 'rounded junction endpoints within 0.000708 px of ICGC'],
              'sourceUnderlaySHA256': digest(original.encode()),
              'derivedUnderlaySHA256': digest(derived_text.encode())}
    (OUT / 'geometry-checks.json').write_text(json.dumps(report, indent=2) + '\n')
    # Identical affine/viewBox diagnostic pairs. Blue=context, white=ICGC exterior.
    for state, tree in [('before', ET.fromstring(original)), ('after', derived_tree)]:
        context = copy.deepcopy(tree.find(f".//{NS}g[@id='context-boundaries']"))
        context.set('stroke', '#56b8ff'); context.set('stroke-opacity', '1')
        outline_element = copy.deepcopy(canonical_path)
        outline_element.set('stroke', '#ffffff'); outline_element.set('stroke-opacity', '1')
        for name, box, width, height in [
            ('full', (0, 0, 680, 380), 1360, 760),
            ('west-valdaran', (215, 15, 50, 40), 600, 480),
            ('andorra', (299, 46, 49, 41), 735, 615),
            ('france-coast-junction', (480, 72, 32, 30), 640, 600),
            ('spain-coast-junction', (196, 347, 20, 33), 400, 660)]:
            context.set('stroke-width', '.3' if name == 'full' else '.13')
            outline_element.set('stroke-width', '.4' if name == 'full' else '.13')
            body = ET.tostring(context, encoding='unicode') + ET.tostring(outline_element, encoding='unicode')
            svg_file(f'{name}-{state}.svg', box, body, width, height)
        # Offline native-dark style approximation, unchanged terrain raster embedded.
        dark = copy.deepcopy(tree)
        for element in dark.iter():
            for key, before, after in [('fill', '#10151b', '#0F1114'),
                                       ('fill', '#181b20', '#17191D'),
                                       ('fill', '#1e2126', '#1C1E22')]:
                if element.get(key) == before: element.set(key, after)
        dark_context = dark.find(f".//{NS}g[@id='context-boundaries']")
        dark_context.set('stroke', '#FFFFFF'); dark_context.set('stroke-opacity', '.09')
        dark_context.set('stroke-width', '.6')
        # Native renderer uses a rectangular geographic clip, irrespective of source rx.
        dark.find(f'.//{NS}clipPath/{NS}rect').attrib.pop('rx', None)
        terrain = base64.b64encode((GEO / 'terrain-relief.png').read_bytes()).decode()
        terrain_image = f'<image width="680" height="380" href="data:image/png;base64,{terrain}"/>'
        boundaries = copy.deepcopy(canonical_tree)
        for element in boundaries.iter():
            if element.get('stroke') == 'currentColor':
                exterior = float(element.get('stroke-width', '0')) > 1
                element.set('stroke', '#FFFFFF'); element.set('stroke-opacity', '.24' if exterior else '.055')
                element.set('stroke-width', '.8' if exterior else '.5')
        body = ''.join(ET.tostring(e, encoding='unicode') for e in dark) + terrain_image
        body += ''.join(ET.tostring(e, encoding='unicode') for e in boundaries)
        svg_file(f'offline-dark-{state}.svg', (0, 0, 680, 380), body, 1360, 760)
        svg_file(f'offline-dark-west-valdaran-{state}.svg', (215, 15, 50, 40), body, 600, 480)
    if args.apply:
        # Fail closed if another owner changed either target after this derivation.
        assert (GEO / 'layer-under.svg').read_text() in [original, derived_text]
        assert (GEO / 'context-provenance.json').read_bytes() in [source_provenance, provenance_text.encode()]
        (GEO / 'layer-under.svg').write_text(derived_text)
        (GEO / 'context-provenance.json').write_text(provenance_text)
        assert {p.name: digest(p.read_bytes()) for p in sorted(GEO.iterdir())
                if p.name in protected} == protected
    if args.render:
        for svg in sorted(OUT.glob('*.svg')):
            if svg.name != 'layer-under-derived.svg':
                subprocess.run(['magick', '-background', 'none', str(svg), str(svg.with_suffix('.png'))], check=True)
    print(json.dumps({'applied': args.apply, 'outputSHA256': report['derivedUnderlaySHA256'],
                      'countries': [{k: v for k, v in item.items() if k not in ['fullyRemoved', 'junctionConnectors']}
                                    for item in stats]}, indent=2))

if __name__ == '__main__':
    main()
