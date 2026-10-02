#!/usr/bin/env python3
"""Check Quartus's actual synchronous-ROM image against the frozen CPU contract."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def require(condition, message):
    if not condition:
        raise ValueError(message)


def analyze_compiled_image(run):
    """Recheck the actual mapped image and return its source-linked receipt."""
    run = Path(run).resolve()
    work = run/'work'
    contract = work/'vendor/spk286/tests/fixtures/microcode_esc_boundary.json'
    golden = json.loads(contract.read_text())
    words = golden['words']
    require(golden['address_width'] == 10 and golden['word_width'] == 8,
            'Unexpected independent contract dimensions')
    require(len(words) == 743 and all(type(v) is int and 0 < v < 256 for v in words),
            'Unexpected independent contract words')
    images = list((work/'db').glob('*spk286_microcode_sync_rom*.hdl.mif'))
    require(len(images) == 1, 'Expected one actual compiled synchronous-ROM image')
    image = images[0]
    source = image.read_text()
    for pattern in (r'WIDTH\s*=\s*9;', r'DEPTH\s*=\s*1024;',
                    r'ADDRESS_RADIX\s*=\s*UNS;', r'DATA_RADIX\s*=\s*BIN;'):
        require(re.search(pattern, source), 'Unexpected Quartus MIF dimensions/radix')
    entries = re.findall(r'^\s*(\d+)\s*:\s*([01]{9})\s*;\s*$', source, re.M)
    values = {int(address):int(value,2) for address,value in entries}
    require(len(entries) == 1024 and set(values) == set(range(1024)), 'Incomplete/duplicate ROM initialization')
    for address in range(1024):
        expected = (256 | words[address]) if address < len(words) else 0
        require(values[address] == expected, f'Compiled ROM mismatch at {address}')
    compile_log = (run/'compile.log').read_text()
    match = re.search(r'Info \(12133\): Instantiated megafunction [^\n]*spk286_microcode_sync_rom[^\n]*\n'
                      r'((?:\s*Info \(12134\): Parameter [^\n]*\n)+)', compile_log)
    require(match, 'Compiled primitive parameters missing')
    parameters = dict(re.findall(r'Parameter "([A-Z0-9_]+)" = "([^"]*)"', match.group(1)))
    for key,value in {'OPERATION_MODE':'ROM','WIDTH_A':'9','WIDTHAD_A':'10','NUMWORDS_A':'1024',
                      'OUTDATA_REG_A':'UNREGISTERED','ADDRESS_ACLR_A':'NONE','RAM_BLOCK_TYPE':'M10K'}.items():
        require(parameters.get(key) == value, 'Unexpected primitive '+key)
    def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
    return {
        'status':'COMPILED_M10K_IMAGE_ALL_1024_WORDS_AND_READ_ALIGNMENT_PARAMETERS_PASS',
        'run':str(run),'mif':str(image.relative_to(work)),
        'mif_sha256':sha(image),'contract_sha256':sha(contract),
        'manifest_sha256':sha(run/'manifest.json'),
        'valid_words':743,'invalid_words':281,'parameters':parameters,
        'scope':'actual mapped memory image and primitive configuration; functional/source proofs separate; not physical timing closure or hardware validation'
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    result = analyze_compiled_image(args.run)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print('COMPILED_SYNC_MICROCODE_IMAGE_PASS: M10K 1024x9, all 743 valid / 281 invalid words match')


if __name__ == '__main__':
    main()
