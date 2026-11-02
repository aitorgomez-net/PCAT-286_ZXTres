#!/usr/bin/env python3
"""Memory images for the ZXTRES+ demo, one 16-bit hex word per line.

  make_mem.py rom  DEMO_BIN OUT   64 KiB ROM image, little-endian words
  make_mem.py text OUT            initial text screen
  make_mem.py font FONT_HEX OUT   8x8 font, one byte per line
  make_mem.py osdfont FONT_HEX OUT  OSD font: the ASCII glyphs of FONT_HEX
                                  and the menu symbols and icons (codes 80h-92h)

The initial screen says the CPU has not drawn anything yet, so a board that
shows only this message has video but no running CPU.
"""
from pathlib import Path
import sys


def rom(source, target):
    data = Path(source).read_bytes()
    if len(data) != 0x10000:
        sys.exit(f'{source}: {len(data)} bytes, expected 65536')
    words = [data[i] | (data[i + 1] << 8) for i in range(0, len(data), 2)]
    Path(target).write_text(''.join(f'{word:04x}\n' for word in words))


def text(target):
    words = [0x0720] * 2048
    lines = [
        (10, 'SPK286 ZXTRES+ demo'),
        (12, 'The CPU has not written to the screen yet.'),
        (13, 'If this stays, video works but the CPU is not running:'),
        (14, 'see the status line at the bottom.'),
    ]
    for row, message in lines:
        column = (80 - len(message)) // 2
        for offset, character in enumerate(message):
            words[row * 80 + column + offset] = 0x4F00 | ord(character)
    Path(target).write_text(''.join(f'{word:04x}\n' for word in words))


def font(source, target):
    values = [int(line, 16) for line in Path(source).read_text().split()]
    if len(values) != 1024:
        sys.exit(f'{source}: {len(values)} entries, expected 1024')
    Path(target).write_text(''.join(f'{value:02x}\n' for value in values))


# The menu symbols and icons, codes 80h-92h, in the 6 dots (glyph bits 6-1) the OSD
# shows; eight lines each, top first.
OSD_SYMBOLS = [
    ('left arrow',  ['......', '....#.', '...##.', '..###.', '...##.', '....#.', '......', '......']),
    ('right arrow', ['......', '.#....', '.##...', '.###..', '.##...', '.#....', '......', '......']),
    ('up arrow',    ['......', '......', '..##..', '.####.', '######', '......', '......', '......']),
    ('down arrow',  ['......', '......', '######', '.####.', '..##..', '......', '......', '......']),
    ('check mark',  ['......', '......', '.....#', '....#.', '#..#..', '.##...', '..#...', '......']),
    ('cross',       ['......', '......', '##..##', '.####.', '..##..', '.####.', '##..##', '......']),
    ('cycle',       ['......', '.####.', '#....#', '#..###', '#...#.', '#....#', '.####.', '......']),
    ('ellipsis',    ['......', '......', '......', '......', '......', '......', '#.#.#.', '......']),
    # Codes 88h-92h: the rule and the icons of the menu rows (five dots wide, so
    # that they do not touch the text).
    ('rule',        ['......', '......', '......', '######', '......', '......', '......', '......']),
    ('floppy',      ['#####.', '#.#.#.', '#.#.#.', '#...#.', '#.###.', '#.###.', '#.###.', '#####.']),
    ('hard disk',   ['......', '#####.', '#...#.', '#####.', '#..#..', '#####.', '......', '......']),
    ('speaker',     ['..#...', '.##...', '###.#.', '###..#', '###.#.', '.##...', '..#...', '......']),
    ('monitor',     ['#####.', '#...#.', '#...#.', '#...#.', '#####.', '.###..', '..#...', '.###..']),
    ('joystick',    ['..#...', '.###..', '..#...', '..#...', '..#...', '#####.', '#####.', '......']),
    ('chip',        ['.#.#..', '#####.', '##.##.', '#.#.#.', '##.##.', '#####.', '.#.#..', '......']),
    ('gear',        ['..#...', '#.#.#.', '.###..', '##.##.', '.###..', '#.#.#.', '..#...', '......']),
    ('info',        ['.###..', '#.#.#.', '#...#.', '#.#.#.', '#.#.#.', '#.#.#.', '.###..', '......']),
    ('folder',      ['##....', '#####.', '#...#.', '#...#.', '#...#.', '#...#.', '#####.', '......']),
    ('file',        ['###...', '#.##..', '#..##.', '#...#.', '#...#.', '#...#.', '#####.', '......']),
]


def osd_font(source, target):
    values = [int(line, 16) for line in Path(source).read_text().split()]
    if len(values) != 1024:
        sys.exit(f'{source}: {len(values)} entries, expected 1024')
    font = values[:96 * 8]                    # codes 20h-7Fh
    for _, rows in OSD_SYMBOLS:
        font += [int(row.replace('.', '0').replace('#', '1'), 2) << 1 for row in rows]
    font += [0] * (1024 - len(font))
    Path(target).write_text(''.join(f'{value:02x}\n' for value in font))


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else ''
    if kind == 'rom' and len(sys.argv) == 4:
        rom(sys.argv[2], sys.argv[3])
    elif kind == 'text' and len(sys.argv) == 3:
        text(sys.argv[2])
    elif kind == 'font' and len(sys.argv) == 4:
        font(sys.argv[2], sys.argv[3])
    elif kind == 'osdfont' and len(sys.argv) == 4:
        osd_font(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
