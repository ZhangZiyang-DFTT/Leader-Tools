"""Measure Resolve float EXRs independently of the Resolve script."""
import argparse
import json
from pathlib import Path

import av
import numpy as np
import tifffile

parser = argparse.ArgumentParser()
parser.add_argument('--renders', type=Path, required=True)
parser.add_argument('--report', type=Path, required=True)
args = parser.parse_args()
data = json.loads(args.renders.read_text())
report = {'resolveVersion': data['resolveVersion'], 'frames': []}
for item in data['frames']:
    with av.open(item['exr']) as c:
        frame = next(c.decode(video=0))
        rgb = frame.to_ndarray(format='gbrpf32le') * 1023
    h, w = item['height'], item['width']
    assert rgb.shape == (h, w, 3) and item['levels'] == 'Full'
    if item['source'].endswith('.tif'):
        image = tifffile.imread(item['source'])
        assert image.min() == 4100 and image.max() == 60218
        mask = np.all(image == 60218, axis=2)
        expected_black, expected_white = 4100/65535*1023, 60218/65535*1023
        black = rgb[np.all(image == 4100, axis=2)]
        white = rgb[mask]
        allowed = .002
    else:
        with av.open(item['source']) as c:
            frame = next(f for i, f in enumerate(c.decode(video=0)) if i == item.get('source_frame', 0))
            y = np.frombuffer(frame.planes[0], np.uint16).reshape(h, frame.planes[0].line_size//2)[:, :w]
        # Restrict sampling to interiors of neutral, flat blocks.
        def interior(code):
            mask = np.zeros((h, w), dtype=bool)
            for top in range(0, h - 31, 32):
                for left in range(0, w - 31, 32):
                    if np.all(y[top:top+32, left:left+32] == code):
                        mask[top+12:top+20, left+12:left+20] = True
            return mask
        black, white = rgb[interior(64)], rgb[interior(940)]
        factor = 1 if item['dctl'] else 64*1023/65535
        expected_black, expected_white = 64*factor, 940*factor
        allowed = .002
    assert black.size > 1000 and white.size > 1000
    black_error = float(np.abs(black - expected_black).max())
    white_error = float(np.abs(white - expected_white).max())
    assert black_error < allowed and white_error < allowed, (item, black_error, white_error)
    record = {'source': item['source'], 'dctl': item['dctl'],
              'black': float(np.median(black)), 'white': float(np.median(white)),
              'max_black_error': black_error, 'max_white_error': white_error}
    report['frames'].append(record)
    print(Path(item['exr']).parent.name, record['black'], record['white'])
assert len(report['frames']) == 10
report['status'] = 'PASS'
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
