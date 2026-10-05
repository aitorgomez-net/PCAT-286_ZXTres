"""Small reproducibility/packaging checks; not substitutes for CPU execution."""
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from research.pm_diag.build import build, com_boot_image


class BuildTests(unittest.TestCase):
    def test_build_reproducibility_and_images(self):
        nasm = os.environ.get('PM_DIAG_NASM', 'nasm')
        with tempfile.TemporaryDirectory(prefix='pm286-build-') as directory:
            root = Path(directory)
            first = build(root/'first', nasm)
            second = build(root/'second', nasm)
            self.assertEqual(first, second)
            for name in ('PM286', 'PMROM'):
                com = (root/'first'/f'{name}.COM').read_bytes()
                self.assertLess(len(com), 0xEF00)
                payload = (root/'first'/f'{name}.BIN').read_bytes()
                disk = (root/'first'/f'{name}.IMG').read_bytes()
                self.assertEqual(len(disk), 1474560)
                self.assertEqual(disk[510:512], b'\x55\xaa')
                self.assertEqual(disk[512:512+len(payload)], payload)
                self.assertFalse(any(disk[512+len(payload):]))
                self.assertEqual(hashlib.sha256(com).hexdigest(), first['files'][name+'.COM']['sha256'])
                relocated = root/f'{name}-relocated.IMG'
                com_boot_image(root/'first'/f'{name}.COM', relocated, nasm, 0x1379)
                self.assertEqual(relocated.read_bytes()[512:512+len(com)], com)
            self.assertNotEqual(first['files']['PM286.COM'], first['files']['PMROM.COM'])


if __name__ == '__main__':
    unittest.main()
