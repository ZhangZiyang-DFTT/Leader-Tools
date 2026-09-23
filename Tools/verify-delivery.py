"""Independent TIFF / ProRes release QA. Not required by the application."""
import argparse
import csv
import json
import wave
from fractions import Fraction
from pathlib import Path

import av
import imagecodecs
import numpy as np
import tifffile


def nearest(value):
    return (value.numerator * 2 + value.denominator) // (value.denominator * 2)


def timecode(frame, nominal):
    sec, ff = divmod(frame, nominal)
    return f"{sec // 3600:02}:{sec // 60 % 60:02}:{sec % 60:02}:{ff:0{3 if nominal > 100 else 2}}"


def role(index, kind, nominal):
    count = nominal * 10
    scaled = lambda f: (f * nominal + 12) // 24
    if kind == "tail":
        if index == 0:
            return "tailTriangle"
        if index == nominal * 2 - 1:
            return "twoPop"
        if index == count - 1:
            return "endTitle"
        relative = index - nominal * 8
        if relative < 0:
            return "black"
        return "titleCard" if relative < scaled(20) else "reelCard" if relative < scaled(25) else "notesCard"
    if index == 0:
        return "headLabel"
    if index < scaled(21):
        return "titleCard"
    if index < scaled(26):
        return "reelCard"
    if index < nominal * 2:
        return "notesCard"
    if index == nominal * 2:
        return "pictureStart"
    if index == count - 1:
        return "headTriangle"
    if index > nominal * 8:
        return "black"
    if index == nominal * 8:
        return "twoPop"
    for reference, label in [(144, "soundStart")]:
        if index == count - scaled(reference):
            return label
    return "countdown"


def wave_samples(path):
    with wave.open(str(path), "rb") as wav:
        assert wav.getnchannels() == 1 and wav.getframerate() == 48000 and wav.getsampwidth() == 3
        data = np.frombuffer(wav.readframes(wav.getnframes()), np.uint8).reshape(-1, 3).astype(np.int32)
        values = data[:, 0] | (data[:, 1] << 8) | (data[:, 2] << 16)
        return (values << 8).astype(np.int32)


def check_audio(values, count, cue, fps):
    samples = nearest(Fraction(count * 48000, 1) / fps)
    start = nearest(Fraction(cue * 48000, 1) / fps)
    end = nearest(Fraction((cue + 1) * 48000, 1) / fps)
    assert len(values) == samples, (len(values), samples)
    assert np.all(values[:start] == 0) and np.all(values[end:] == 0), "audio outside pop"
    assert values[start:end].max() > 0 and values[start:end].min() < 0
    expected = np.rint(np.sin(np.arange(end - start) * 2 * np.pi * 1000 / 48000) * 0.1 * 8388607).astype(np.int32) << 8
    assert np.max(np.abs(values[start:end].astype(np.int64) - expected.astype(np.int64))) <= 256


def verify_movie(path, sequence, settings, rows, fps, nominal):
    count = nominal * 10
    w, h = settings["resolution"]["width"], settings["resolution"]["height"]
    with av.open(str(path)) as container:
        assert len(container.streams.video) == 1
        stream = container.streams.video[0]
        assert stream.codec_context.name == "prores" and stream.codec_context.profile == "HQ"
        assert stream.codec_context.format.name == "yuv422p10le"
        assert stream.average_rate == fps and stream.frames == count
        assert Fraction(stream.duration) * stream.time_base == Fraction(count, 1) / fps
        if nominal <= 60:
            assert stream.metadata["timecode"] == sequence["startTimecode"]
        frame_count = 0
        for i, frame in enumerate(container.decode(stream)):
            assert frame.width == w and frame.height == h and frame.format.name == "yuv422p10le"
            assert Fraction(frame.pts) * frame.time_base == Fraction(i, 1) / fps
            assert frame.colorspace == 1 and frame.color_range == 1
            if rows[i]["role"] == "black":
                y = np.frombuffer(frame.planes[0], np.uint16).reshape(h, frame.planes[0].line_size // 2)[:, :w]
                assert np.max(np.abs(y.astype(np.int32) - 64)) <= 2, (path, i, int(y.min()), int(y.max()))
            frame_count += 1
        assert frame_count == count
    with av.open(str(path)) as container:
        tracks = [s for s in container.streams if s.type == "data"]
        assert len(tracks) == 1, "missing timecode track"
        packets = [bytes(p) for p in container.demux(tracks[0]) if p.size]
        assert len(packets) == 1 and len(packets[0]) == 4
        assert int.from_bytes(packets[0], "big", signed=True) == sequence["startFrame"]
    if settings["audio"]:
        with av.open(str(path)) as container:
            assert len(container.streams.audio) == 1
            track = container.streams.audio[0]
            assert track.codec_context.name == "pcm_s24le" and track.codec_context.sample_rate == 48000
            values = np.concatenate([f.to_ndarray().ravel() for f in container.decode(track)])
            check_audio(values, count, sequence["cueIndexZeroBased"], fps)
    else:
        with av.open(str(path)) as container:
            assert not container.streams.audio
    return dict(file=str(path), codec="ProRes 422 HQ", pixel_format="yuv422p10le", frames=count,
                fps=str(fps), start_timecode=sequence["startTimecode"])


def verify_batch(path):
    manifest = json.loads(path.read_text())
    assert manifest["version"] == "1.1.5" and manifest["status"] == "complete", path
    root, settings = path.parent, manifest["settings"]
    fps = Fraction(settings["rate"]["numerator"], settings["rate"]["denominator"])
    nominal = nearest(fps)
    count = nominal * 10
    assert abs(manifest["actualDurationSeconds"] - float(Fraction(count, 1) / fps)) < 1e-9
    w, h = settings["resolution"]["width"], settings["resolution"]["height"]
    assert settings["storage"] == "compatible16"
    bits = 16
    low10, high10 = (0, 1023) if settings["range"] == "full" else (64, 940)
    low, high = (0, 65535) if settings["range"] == "full" else (4100, 60218)
    results = []
    for seq in manifest["sequences"]:
        with (root / seq["frameMap"]).open(newline="") as file:
            rows = list(csv.DictReader(file))
        assert len(rows) == count == seq["frameCount"]
        start = seq["reel"] * nominal * 3600 - (count if seq["kind"] == "head" else 0)
        cue = nominal * 8 if seq["kind"] == "head" else nominal * 2 - 1
        assert seq["startFrame"] == start and seq["startTimecode"] == timecode(start, nominal)
        assert seq["cueIndexZeroBased"] == cue
        assert seq["cueAudioSample48k"] == nearest(Fraction(cue * 48000, 1) / fps)
        black = 0
        maximum_unique = 0
        for i, row in enumerate(rows):
            assert int(row["index_zero_based"]) == i and int(row["absolute_frame"]) == start + i
            assert row["timecode"] == timecode(start + i, nominal)
            assert row["role"] == role(i, seq["kind"], nominal), (seq, i, row)
            if not seq.get("directory"):
                continue
            file = root / seq["directory"] / row["filename"]
            assert file.name.endswith(f".{start+i:08d}.tif")
            assert f"_R{seq['reel']:02d}_{seq['kind'].upper()}_" in file.name
            with tifffile.TiffFile(file) as tiff:
                assert len(tiff.pages) == 1
                page = tiff.pages[0]
                assert tuple(page.tags["BitsPerSample"].value) == (bits, bits, bits)
                assert page.photometric == 2 and page.planarconfig == 1
                assert page.tags["Orientation"].value == 1 and page.samplesperpixel == 3
                assert "InterColorProfile" in page.tags and row["timecode"] in page.description
                image = page.asarray()
                assert image.shape == (h, w, 3) and image.dtype == np.uint16
                assert low <= image.min() <= image.max() <= high
                expected_corner = high if row["role"] == "twoPop" else low
                assert np.all(image[:8, :8] == expected_corner), "background must use exact range endpoint"
                assert round(low * 1023 / 65535) == low10
                assert round(high * 1023 / 65535) == high10
                if row["role"] not in ("black", "notesCard"):
                    assert np.any(np.all(image == low, axis=2)), "missing solid minimum black"
                    assert np.any(np.all(image == high, axis=2)), "missing solid maximum white"
                if row["role"] in ("countdown", "twoPop"):
                    expected = high if row["role"] == "twoPop" else low
                    assert np.all(image[0, 0] == expected), "only 2-pop may invert the canvas"
                    if settings["accent"]:
                        rgb = image.astype(np.int32)
                        margin = (high-low) * 0.04
                        assert np.any((rgb[:,:,0] > rgb[:,:,1]+margin) & (rgb[:,:,1] > rgb[:,:,2]+margin)), "orange frame digit missing"
                        assert not np.any(rgb[:,:,2] > rgb[:,:,0]+margin), "orange frame digit turned blue"
                    dw = w / h * 1080
                    radius = min(195, dw*0.125)
                    x = dw*0.195
                    scale = settings["scale"]
                    def px(v): return int((dw/2 + (v-dw/2)*scale)*h/1080)
                    def py(v): return int((540 + (v-540)*scale)*h/1080)
                    center = 360 + radius + 110
                    block = image[py(center-23):py(center+23),px(x-radius):px(x+radius)]
                    assert block.size
                    scaled = lambda f: (f * nominal + 12) // 24
                    sync_frames = {count-scaled(172), count-scaled(170), count-scaled(164)}
                    has_label = np.ptp(block) > (high-low)*0.2
                    assert has_label == (seq["kind"] == "head" and i in sync_frames), \
                        "sound indicator must appear on exactly one frame at each original position"
                if row["role"] == "black":
                    assert np.all(image == low)
                    black += 1
                if row["role"] in ("headTriangle", "tailTriangle"):
                    lit = np.any(image > low, axis=2)
                    ys = np.flatnonzero(lit.any(axis=1))
                    assert len(ys) > h // 4
                    a = ys[0] + (ys[-1] - ys[0]) // 4
                    b = ys[0] + (ys[-1] - ys[0]) * 3 // 4
                    down = np.ptp(np.flatnonzero(lit[a])) > np.ptp(np.flatnonzero(lit[b]))
                    assert down == (row["role"] == "headTriangle")
                if i in (nominal * 3 + 1, cue, count - 1):
                    codes = np.unique(image).astype(np.uint32)
                    maximum_unique = max(maximum_unique, len(codes))
                    q10 = np.rint(codes * 1023 / 65535).astype(np.uint32)
                    assert np.array_equal(codes, (q10 * 65535 + 511) // 1023)
        if seq.get("directory"):
            files = list((root / seq["directory"]).glob("*.tif"))
            assert len(files) == count and maximum_unique > 256
        if settings["audio"]:
            wave_name = seq["frameMap"].removesuffix("_frames.csv") + "_SYNC.wav"
            check_audio(wave_samples(root / wave_name), count, cue, fps)
        movie = verify_movie(root / seq["movie"], seq, settings, rows, fps, nominal) if seq.get("movie") else None
        results.append(dict(reel=seq["reel"], kind=seq["kind"], frames=count, tiff_bits=bits if seq.get("directory") else None,
                            unique_codes=maximum_unique, black_frames=black, movie=movie))
        print(f"PASS R{seq['reel']:02} {seq['kind']} {fps} {w}x{h}: {count} frames, TIFF={bool(seq.get('directory'))}, MOV={bool(movie)}", flush=True)
    actual_bytes = sum(p.stat().st_size for p in root.rglob("*") if p.is_file())
    assert actual_bytes == manifest["bytesWritten"], (actual_bytes, manifest["bytesWritten"])
    return dict(batch=str(root), bytes=actual_bytes, sequences=results)


parser = argparse.ArgumentParser()
parser.add_argument("--root", type=Path, action="append", required=True)
parser.add_argument("--report", type=Path, required=True)
args = parser.parse_args()
batches = [verify_batch(p) for root in args.root for p in sorted(root.rglob("manifest.json")) if ".partial" not in str(p)]
assert batches
report = dict(status="PASS", decoders=dict(tifffile=tifffile.__version__, imagecodecs=imagecodecs.__version__, av=av.__version__),
              batches=batches, sequence_frames=sum(s["frames"] for b in batches for s in b["sequences"]))
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(f"PASS: {report['sequence_frames']} sequence frames, every requested TIFF/MOV decoded.")
