"""Independent encoding and complete source/iteration/commit contracts."""
import json
from pathlib import Path
import tempfile
import unittest
from tools.microcode.compile_microcode import ROOT,CompileError,compile_sources,generate,emit
from tools.microcode.audit_microcode import canonical_source,read_generated_words,read_generated_branches
from tests.test_microcode_register_execution import standalone_catalog_words

class IoMicrocodeTests(unittest.TestCase):
    def test_literal_image_and_generated_roundtrip(self):
        # The historical phase-9 fixture includes SALC (723 words), while this
        # IO contract deliberately covers its pre-SALC predecessor (719). The
        # old *_sources.json is absent. Derive only the independently asserted
        # four-word suffix removal and catalog translation from frozen words,
        # not from the active .mc sources or generated candidate ROM.
        fixture=json.loads((ROOT/'tests/fixtures/microcode_phase9_loadall.json').read_text())
        migrated=standalone_catalog_words(self,fixture)
        self.assertEqual(len(migrated),723)
        self.assertEqual(fixture['entries']['LOAD_CARRY_BYTE'],719)
        self.assertEqual(migrated[719:],[30,172,54,3])
        expected=migrated[:719]
        entries={name:pc for name,pc in fixture['entries'].items() if name!='LOAD_CARRY_BYTE'}
        self.assertTrue(all(pc<719 for pc in fixture['labels'].values()))
        self.assertTrue(all(int(pc)<719 and target<719 for pc,target in fixture['branch_targets'].items()))
        sources={'pre_salc_format21.mc':canonical_source(expected,entries,fixture['labels'],
                    {int(k):v for k,v in fixture['branch_targets'].items()})}
        program=compile_sources(sources);artifacts=generate(program)
        words=read_generated_words(artifacts['spk286_microcode_pkg.sv'],artifacts['spk286_microcode_rom.sv']);branches=read_generated_branches(artifacts['spk286_microcode_pkg.sv'])
        self.assertEqual((program.format_version,program.word_width,program.address_width,len(words)),(21,8,10,719))
        self.assertEqual(list(words),expected);self.assertEqual(program.entries,entries);self.assertEqual(program.labels,fixture['labels'])
        self.assertEqual(branches,{435: 445, 437: 443, 442: 438, 576: 583, 582: 577, 584: 594, 593: 585, 595: 601, 600: 597, 602: 608, 607: 603, 609: 618, 617: 610, 635: 642, 641: 637, 643: 650, 649: 645, 651: 658, 657: 653, 659: 666, 665: 661})
        rebuilt=compile_sources({'canonical.mc':canonical_source(words,program.entries,program.labels,branches)})
        self.assertEqual([op.operation for op in rebuilt.operations],[op.operation for op in program.operations])
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)
            self.assertTrue(emit(artifacts,output,check=False))
            self.assertTrue(emit(artifacts,output,check=True))

    def test_missing_access_effects_or_changed_iteration_targets_are_rejected(self):
        source=(ROOT/'microcode/source/zzzzzzzzzzzzz_io.mc').read_text();compile_sources({'valid.mc':source});lines=source.splitlines()
        for index,line in enumerate(lines):
            if not line.startswith('    '):continue
            with self.subTest(index=index,line=line),self.assertRaises(CompileError):
                compile_sources({'missing.mc':'\n'.join(lines[:index]+lines[index+1:])})
        for changed in (source.replace('microcode_format 25','microcode_format 24'),source.replace('BRANCH_REPEAT_EMPTY done','BRANCH_REPEAT_EMPTY loop'),source.replace('BRANCH_REPEAT_CONTINUE loop','BRANCH_REPEAT_CONTINUE done'),source.replace('STEP_STRING_SOURCE','STEP_STRING_DEST')):
            with self.assertRaises(CompileError):compile_sources({'changed.mc':changed})
