"""LOADALL atomic service token, validation and generated-image consistency."""
import unittest

from tools.microcode.compile_microcode import (
    ROOT, CompileError, compile_sources, encode, generate, emit,
)
from tools.microcode.audit_microcode import canonical_source, read_generated_words


NAME = 'zzzzzzzzzzzzzzzzzz_loadall.mc'


class LoadallMicrocodeTests(unittest.TestCase):
    def test_atomic_protocol(self):
        source = (ROOT / 'microcode/source' / NAME).read_text()
        program = compile_sources({NAME: source})
        self.assertEqual([encode(op) for op in program.operations], [172, 3])
        for changed in (
            source.replace('21', '20'),
            source.replace('    LOADALL\n', ''),
            source.replace('    END', ''),
            source.replace('    END', '    LOADALL\n    END'),
            source.replace('    END', '    COMMIT_FLAGS\n    END'),
        ):
            with self.subTest(source=changed), self.assertRaises(CompileError):
                compile_sources({NAME: changed})

    def test_existing_sequences_and_roundtrip(self):
        sources = {p.name: p.read_text() for p in (ROOT / 'microcode/source').glob('*.mc')}
        previous = compile_sources({n: s for n, s in sources.items() if n != NAME})
        current = compile_sources(sources)
        words = [encode(op) for op in current.operations]
        start = current.entries['LOADALL']
        self.assertEqual(words[start:start + 2], [172, 3])
        self.assertEqual(words[:start] + words[start + 2:],
                         [encode(op) for op in previous.operations])
        for name, address in previous.entries.items():
            self.assertEqual(current.entries[name], address + (2 if address >= start else 0))
        artifacts = generate(current)
        decoded = read_generated_words(artifacts['spk286_microcode_pkg.sv'],
                                       artifacts['spk286_microcode_rom.sv'])
        rebuilt = compile_sources({'canonical.mc': canonical_source(
            decoded, current.entries, current.labels, current.branch_targets)})
        self.assertEqual([encode(op) for op in rebuilt.operations], words)
        self.assertTrue(emit(artifacts, ROOT / 'microcode/generated', check=True))
