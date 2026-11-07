#!/usr/bin/env python3
"""Memory image of the ZXTRES+ on-screen display font.

  make_mem.py osdfont FONT_HEX OUT  OSD font: the ASCII glyphs of FONT_HEX
                                  and the menu symbols and icons (codes 80h-92h)
"""
from pathlib import Path
import sys


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
    if kind == 'osdfont' and len(sys.argv) == 4:
        osd_font(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
