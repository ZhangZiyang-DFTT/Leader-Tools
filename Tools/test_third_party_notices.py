import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('notices', Path(__file__).with_name('generate-third-party-notices.py'))
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


class NoticeTests(unittest.TestCase):
    def test_reproducible_file(self):
        text, count = notices.generate()
        self.assertEqual(count, 19)
        self.assertEqual(text, (notices.ROOT / 'Resources/ThirdPartyNotices.txt').read_text(encoding='utf-8'))

    def test_upstream_license_preserved(self):
        text, _ = notices.generate()
        with tarfile.open(notices.ARCHIVE) as archive:
            original = archive.extractfile('tiff-4.7.1/LICENSE.md').read().decode('utf-8')
        self.assertIn(original.rstrip(), text)

    def test_file_level_notices(self):
        text, _ = notices.generate()
        for name in ['tif_hash_set.c', 'tif_hash_set.h', 'tif_lzw.c', 'tif_pixarlog.c', 'tif_fax3.c', 'tif_luv.c']:
            self.assertIn('tiff-4.7.1/libtiff/' + name, text)
        self.assertIn('Permission is hereby granted, free of charge', text)
        self.assertIn('Copyright (c) 1996 Pixar', text)
        self.assertIn('Jean-loup Gailly and Mark Adler', text)

    def test_tampered_archive_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'changed.tar.gz'
            archive.write_bytes(b'not the pinned upstream source')
            with patch.object(notices, 'ARCHIVE', archive):
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    notices.generate()


if __name__ == '__main__':
    unittest.main()
