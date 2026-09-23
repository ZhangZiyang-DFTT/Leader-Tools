"""Run with ResolvePython. Isolated project; restore the user's project in finally.

Requires Resolve Studio with the bundled DCTL installed in its LUT directory.
The test writes single-frame RGB float EXRs, never gallery TIFF screenshots.
"""
import argparse
import json
import shutil
import time
from pathlib import Path

import DaVinciResolveScript as d

parser = argparse.ArgumentParser()
parser.add_argument('--stills', type=Path, required=True)
parser.add_argument('--batch', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=True)
r = d.scriptapp('Resolve')
assert r, 'Resolve scripting connection unavailable'
pm = r.GetProjectManager()
original = pm.GetCurrentProject().GetName()
assert pm.SaveProject()
p = pm.CreateProject('LeaderTools_115_Readback_' + str(int(time.time())))
assert p
results = {'resolveVersion': r.GetVersionString(), 'project': p.GetName(), 'frames': []}
try:
    assert p.SetSetting('colorScienceMode', 'davinciYRGB')
    assert p.SetSetting('colorSpaceTimeline', 'Rec.709 (Scene)')
    assert p.SetSetting('timelineFrameRate', '24')
    assert p.RefreshLUTList()
    mp = p.GetMediaPool()

    def render(source, name, width, height, dctl=False, source_frame=0):
        assert p.SetSetting('timelineResolutionWidth', str(width))
        assert p.SetSetting('timelineResolutionHeight', str(height))
        clips = mp.ImportMedia([str(source.resolve())])
        assert clips, source
        clip = clips[0]
        assert clip.SetClipProperty('Data Level', 'Full')
        t = mp.CreateTimelineFromClips(name, [{'mediaPoolItem': clip}])
        assert t and p.SetCurrentTimeline(t)
        assert t.SetCurrentTimecode(t.GetStartTimecode())
        if dctl:
            assert t.GetCurrentVideoItem().GetNodeGraph().SetLUT(1, 'LeaderTools_Resolve_Full_ProRes_Q10.dctl')
        assert p.SetCurrentRenderFormatAndCodec('exr', 'RGBFloatZIP')
        out = root / name
        out.mkdir(exist_ok=False)
        start = t.GetStartFrame() + source_frame
        assert p.SetRenderSettings({'SelectAllFrames': False, 'MarkIn': start, 'MarkOut': start,
            'TargetDir': str(out), 'CustomName': 'readback', 'ExportVideo': True, 'ExportAudio': False,
            'FormatWidth': width, 'FormatHeight': height})
        job = p.AddRenderJob()
        assert job and p.StartRendering([job])
        deadline = time.monotonic() + 120
        while p.IsRenderingInProgress():
            assert time.monotonic() < deadline, 'Resolve render timed out'
            time.sleep(.3)
        status = p.GetRenderJobStatus(job)
        assert status['JobStatus'] == 'Complete', status
        files = list(out.glob('*.exr'))
        assert len(files) == 1
        record = {'source': str(source), 'exr': str(files[0]), 'dctl': dctl,
                  'width': width, 'height': height, 'levels': clip.GetClipProperty('Data Level'),
                  'source_frame': source_frame}
        results['frames'].append(record)
        print(name, 'rendered', flush=True)

    for source in sorted(args.stills.glob('legal_*_0.tif')):
        size = source.stem.split('_')[1]
        w, h = map(int, size.split('x'))
        # A unique non-numbered filename prevents image-sequence auto-grouping.
        still = root / ('Head_' + size + '_Still.tif')
        shutil.copyfile(source, still)
        render(still, 'TIFF_' + size, w, h)
    assert len(results['frames']) == 8
    manifest = json.loads((args.batch / 'manifest.json').read_text(encoding='utf-8'))
    seq = next(s for s in manifest['sequences'] if s['kind'] == 'head')
    movie = args.batch / seq['movie']
    size = manifest['settings']['resolution']
    for dctl in [False, True]:
        render(movie, 'MOV_' + ('Corrected' if dctl else 'Native'), size['width'], size['height'], dctl,
               seq['cueIndexZeroBased'])
    (root / 'resolve-renders.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
finally:
    pm.SaveProject()
    assert pm.LoadProject(original), 'Could not restore original Resolve project'
