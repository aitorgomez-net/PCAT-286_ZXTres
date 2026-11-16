# SPDX-License-Identifier: MIT
import json
import unittest
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, encode, generate
from tools.microcode.audit_microcode import canonical_source, read_generated_words

RESTORE_AUX, WRITE_BP, ALLOCATE_STACK, END = 95, 91, 108, 3


def expected_enter_commit_image(old):
    """H20: ENTER_FRAME commits SP (ALLOCATE_STACK) before BP."""
    words = old['words'].copy()
    position = old['entries']['ENTER_FRAME'] + 22
    assert words[position-1:position+3] == [RESTORE_AUX, WRITE_BP, ALLOCATE_STACK, END]
    words[position:position+2] = [ALLOCATE_STACK, WRITE_BP]
    branches = {int(pc): target for pc, target in old['branch_targets'].items()}
    return words, dict(old['entries']), dict(old['labels']), branches


class EnterCommitMicrocodeTests(unittest.TestCase):
    def test_current_image_swaps_only_the_enter_commit_order(self):
        old = json.loads((ROOT/'tests/fixtures/microcode_esc_boundary.json').read_text())
        words, entries, labels, branches = expected_enter_commit_image(old)
        program = compile_sources({p.name: p.read_text() for p in (ROOT/'microcode/source').glob('*.mc')})
        self.assertEqual([encode(op) for op in program.operations], words)
        self.assertEqual(program.entries, entries)
        self.assertEqual(program.labels, labels)
        self.assertEqual(program.branch_targets, branches)
        frozen = json.loads((ROOT/'tests/fixtures/microcode_enter_commit.json').read_text())
        self.assertEqual(frozen['words'], words)
        self.assertEqual(frozen['entries'], entries)
        generated = generate(program)
        emitted = read_generated_words(generated['spk286_microcode_pkg.sv'], generated['spk286_microcode_rom.sv'])
        rebuilt = compile_sources({'canonical.mc': canonical_source(emitted, entries, labels, branches)})
        self.assertEqual([encode(op) for op in rebuilt.operations], words)
        self.assertEqual(rebuilt.format_version, 27)

    def test_enter_accepts_only_the_two_commit_orders(self):
        source = (ROOT/'microcode/source/zzzzzzzzz_stack_frame.mc').read_text()
        checked = '    RESTORE_AUX -> TMP0\n    ALLOCATE_STACK\n    TMP0 -> BP\n    END'
        self.assertIn(checked, source)
        compile_sources({'checked.mc': source})
        compile_sources({'baseline.mc': source.replace(
            checked, '    RESTORE_AUX -> TMP0\n    TMP0 -> BP\n    ALLOCATE_STACK\n    END')})
        for broken in ('    RESTORE_AUX -> TMP0\n    ALLOCATE_STACK\n    END',
                       '    RESTORE_AUX -> TMP0\n    TMP0 -> BP\n    END',
                       '    ALLOCATE_STACK\n    RESTORE_AUX -> TMP0\n    TMP0 -> BP\n    END'):
            with self.assertRaises(CompileError):
                compile_sources({'broken.mc': source.replace(checked, broken)})


if __name__ == '__main__':
    unittest.main()
