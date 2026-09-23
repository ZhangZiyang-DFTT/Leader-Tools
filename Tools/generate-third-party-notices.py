"""Reproduce bundled notices from the pinned, unmodified LibTIFF archive."""
import argparse
import hashlib
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'Vendor/Source/tiff-4.7.1.tar.gz'
SHA256 = 'f698d94f3103da8ca7438d84e0344e453fe0ba3b7486e04c5bf7a9a3fabe9b69'


def generate():
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != SHA256:
        raise ValueError('LibTIFF archive checksum mismatch; audit before updating notices')
    groups = {}
    with tarfile.open(ARCHIVE, 'r:gz') as archive:
        license_text = archive.extractfile('tiff-4.7.1/LICENSE.md').read().decode('utf-8')
        for member in sorted(archive.getmembers(), key=lambda m: m.name):
            if not member.isfile() or not member.name.startswith('tiff-4.7.1/libtiff/'):
                continue
            if Path(member.name).suffix not in ('.c', '.h'):
                continue
            source = archive.extractfile(member).read().decode('utf-8')
            for block in re.findall(r'/\*.*?\*/', source, re.S):
                if re.search(r'copyright\s*(?:\(c\)|\u00a9)', block, re.I):
                    groups.setdefault(block, []).append(member.name)
    # Preserve distinct upstream text, including copyright-only acknowledgments.
    sections = [
        (ROOT / 'Resources/ThirdPartyNoticePreamble.txt').read_text(encoding='utf-8').rstrip(),
        'LIBTIFF 4.7.1 - UPSTREAM LICENSE.md\n\n' + license_text.rstrip(),
    ]
    for i, (notice, paths) in enumerate(groups.items(), 1):
        sections.append('LIBTIFF SOURCE NOTICE %d\nFiles:\n%s\n\n%s' %
                        (i, '\n'.join(paths), notice))
    sections.append('SYSTEM ZLIB - ACKNOWLEDGMENT\n\n' +
                    (ROOT / 'Resources/Licenses/zlib-1.2.12.txt').read_text(encoding='utf-8').rstrip())
    result = ('\n\n' + '=' * 72 + '\n\n').join(sections) + '\n'
    for required in ['Permission is hereby granted, free of charge', 'Copyright (c) 1996 Pixar',
                     'Copyright (c) 1997 Greg Ward Larson', 'Frank D. Cringle',
                     'The Regents of the University of California', 'Copyright (c) 2022 Even Rouault']:
        if required not in result:
            raise ValueError('Missing audited notice: ' + required)
    return result, len(groups)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Verify without writing files')
    args = parser.parse_args()
    text, count = generate()
    output = ROOT / 'Resources/ThirdPartyNotices.txt'
    if args.check:
        if output.read_text(encoding='utf-8') != text:
            raise SystemExit('Stale third-party notices; run Tools/generate-third-party-notices.py')
    else:
        output.write_text(text, encoding='utf-8')
    print('PASS: pinned LibTIFF license, %d distinct source notices, and system zlib notice' % count)
