"""Measure Legal TIFF code words and decoded ProRes flat black/white regions."""
import argparse
import csv
import json
from pathlib import Path

import av
import numpy as np
import tifffile

parser = argparse.ArgumentParser()
parser.add_argument("--batch", type=Path, required=True)
parser.add_argument("--stills", type=Path, required=True)
parser.add_argument("--report", type=Path, required=True)
args = parser.parse_args()
report = {"stills": [], "movies": []}
for path in sorted(args.stills.glob("legal_*.tif")):
    image = tifffile.imread(path)
    frame = int(path.stem.rsplit("_", 1)[1])
    assert image.min() == 4100 and image.max() == (4100 if frame == 193 else 60218)
    codes = np.unique(image).astype(np.uint32)
    q10 = np.rint(codes * 1023 / 65535).astype(np.uint32)
    assert np.array_equal(codes, (q10 * 65535 + 511) // 1023)
    assert np.all(image[:8, :8] == (60218 if frame == 192 else 4100))
    report["stills"].append({"file": path.name, "min": int(image.min()), "max": int(image.max())})
assert len(report["stills"]) == 112
manifest = json.loads((args.batch / "manifest.json").read_text())
assert manifest["settings"]["range"] == "video"
for seq in manifest["sequences"]:
    with (args.batch / seq["frameMap"]).open() as handle:
        rows = list(csv.DictReader(handle))
    black_samples = white_samples = maximum_error = 0
    with av.open(str(args.batch / seq["movie"])) as movie:
        for i, frame in enumerate(movie.decode(video=0)):
            y = np.frombuffer(frame.planes[0], np.uint16).reshape(
                frame.height, frame.planes[0].line_size // 2)[:, :frame.width]
            expected_corner = 940 if rows[i]["role"] == "twoPop" else 64
            assert np.all(y[:8, :8] == expected_corner), (seq["kind"], i, y[:8, :8])
            if i not in {0, 1, 21, 26, 47, 48, 68, 72, 73, 96, 192, 193, 239}:
                continue
            rgb = tifffile.imread(args.batch / seq["directory"] / rows[i]["filename"])
            h, w = frame.height // 8 * 8, frame.width // 8 * 8
            blocks = rgb[:h, :w].reshape(h//8, 8, w//8, 8, 3)
            minimum = blocks.min(axis=(1, 3, 4))
            maximum = blocks.max(axis=(1, 3, 4))
            decoded = y[:h, :w].reshape(h//8, 8, w//8, 8).transpose(0, 2, 1, 3)
            for code16, code10 in [(4100, 64), (60218, 940)]:
                flat = decoded[(minimum == code16) & (maximum == code16)]
                if flat.size:
                    error = int(np.abs(flat.astype(np.int32) - code10).max())
                    maximum_error = max(maximum_error, error)
                    assert error == 0, (seq["kind"], i, code10, error)
                    if code10 == 64:
                        black_samples += flat.size
                    else:
                        white_samples += flat.size
    assert black_samples > 0 and white_samples > 0
    report["movies"].append({"kind": seq["kind"], "black": 64, "white": 940,
                             "flat_black_pixels": black_samples, "flat_white_pixels": white_samples,
                             "maximum_flat_region_error": maximum_error})
report["status"] = "PASS"
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(f"PASS: {len(report['stills'])} Legal TIFF stills; ProRes black/white flat regions exactly 64/940")
