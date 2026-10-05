"""Build reproducible DOS COM programs and standalone diagnostic floppies."""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent


def warning_options(nasm):
    options = ['-Wall', '-Werror']
    # NASM 2.16.01 does not have the diagnostic introduced in 2.16.03.
    if 'reloc-abs-word' in subprocess.check_output([str(nasm), '-h'], text=True):
        options.append('-w-reloc-abs-word')
    return options


def com_boot_image(program: Path, destination: Path, nasm: str, segment: int = 0x1000):
    """Validation adapter: execute a COM unchanged at a chosen load paragraph."""
    payload = program.read_bytes()
    loader = destination.with_suffix('.BOOT')
    subprocess.run([nasm, '-f', 'bin', *warning_options(nasm),
                    f'-DLOAD_SEGMENT={segment}', f'-DPAYLOAD_SECTORS={(len(payload)+511)//512}',
                    '-o', str(loader), str(SOURCE/'boot.asm')], check=True)
    image = bytearray(1474560)
    image[:512] = loader.read_bytes()
    image[512:512+len(payload)] = payload
    destination.write_bytes(image)


def build(output: Path, nasm: str, inject: int = 0):
    output.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([nasm, '-v'], text=True).strip()
    warnings = warning_options(nasm)
    files = {}
    for name, literal in [('PM286', 0), ('PMROM', 1)]:
        for boot in (0, 1):
            target = output / (name + ('.BIN' if boot else '.COM'))
            # A flat 16-bit COM intentionally contains absolute word offsets.
            subprocess.run([nasm, '-f', 'bin', *warnings,
                            f'-DROM_FLOW={literal}', f'-DBOOT={boot}',
                            f'-DINJECT={inject}',
                            '-l', str(target.with_suffix(target.suffix+'.lst')),
                            '-o', str(target), str(SOURCE / 'pm286.asm')], check=True)
            payload = target.read_bytes()
            if boot:
                sectors = (len(payload) + 511) // 512
                loader = output / (name + '.BOOT')
                subprocess.run([nasm, '-f', 'bin', *warnings,
                                f'-DPAYLOAD_SECTORS={sectors}', '-o', str(loader),
                                str(SOURCE / 'boot.asm')], check=True)
                image = bytearray(1474560)
                image[:512] = loader.read_bytes()
                image[512:512+len(payload)] = payload
                target = output / (name + '.IMG')
                target.write_bytes(image)
            files[target.name] = {'bytes': target.stat().st_size,
                                 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}
    manifest = {'version': '0.1', 'assembler': version, 'injected_fault': inject,
                'files': files, 'sources': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                           for p in [SOURCE/'pm286.asm', SOURCE/'boot.asm']},
                'scope': 'Superdiag late PM/task diagnostic subset; not full PM certification'}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    for name in ('README.md', 'VALIDATION.md', 'RESULT_TEMPLATE.md'):
        shutil.copyfile(SOURCE / name, output / name)
    print(json.dumps(manifest, indent=2))
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'build/pm-diag')
    parser.add_argument('--nasm', default=shutil.which('nasm') or 'nasm')
    parser.add_argument('--inject', type=int, choices=[0, 1, 2], default=0,
                        help='development-only negative fixture: 1=data mismatch, 2=absent CS')
    args = parser.parse_args()
    build(args.output, args.nasm, args.inject)
