#!/usr/bin/env python3
"""Build the ZXTRES+ boot splash from the MiSTer one.

  make_splash.py

Reads SW/splash_vga_320x200.png, redraws "MiSTer" beside the title as
"ZXTres" in the same 6-row font (each font dot two pixels wide, every other
line, white, yellow and orange from top to bottom), and writes
zxtres/splash/splash_vga_320x200.png and the framebuffer image
zxtres/splash/splash_vga_320x200.hex the way SW/make_vga_splash_rom.py does.
T, e and r are taken from the original word; Z, X and s are drawn here. The
palette is unchanged, so rtl/video/splash_vga_palette.hex serves both.
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'SW' / 'splash_vga_320x200.png'
PNG = ROOT / 'zxtres' / 'splash' / 'splash_vga_320x200.png'
HEX = ROOT / 'zxtres' / 'splash' / 'splash_vga_320x200.hex'
FRAMEBUFFER_BYTES = 65536

X0, Y0 = 215, 14                   # first font dot of "MiSTer"
COLUMNS = 45                       # its width in font dots
INK = (2, 16, 36, 39)              # palette indices of the lettering
ROW_INK = (2, 16, 16, 36, 36, 39)  # colour of each font row
DRAWN = {
    'Z': ['######', '....##', '...##.', '..##..', '.##...', '######'],
    'X': ['##...##', '.##.##.', '..###..', '..###..', '.##.##.', '##...##'],
    's': ['......', '.#####', '##....', '.####.', '....##', '#####.'],
}
TAKEN = {'T': (24, 29), 'e': (32, 37), 'r': (40, 44)}   # font columns in "MiSTer"


def main():
    image = Image.open(SOURCE)
    if image.mode != 'P' or image.size != (320, 200):
        raise SystemExit(f'{SOURCE}: expected a 320x200 indexed PNG')

    glyphs = dict(DRAWN)
    for letter, (first, last) in TAKEN.items():
        glyphs[letter] = [''.join('#' if image.getpixel((X0 + 2 * c, Y0 + 2 * r)) in INK else '.'
                                  for c in range(first, last + 1)) for r in range(6)]

    # Clear the old word with each line's own background.
    for y in range(Y0, Y0 + 12):
        background = image.getpixel((X0 - 10, y))
        for x in range(X0 - 10, X0 + 2 * COLUMNS + 10):
            image.putpixel((x, y), background)

    word = 'ZXTres'
    columns = sum(len(glyphs[c][0]) for c in word) + 2 * (len(word) - 1)
    x = X0 + COLUMNS - columns     # centred on the old word
    for letter in word:
        for r, line in enumerate(glyphs[letter]):
            for c, dot in enumerate(line):
                if dot == '#':
                    image.putpixel((x + 2 * c, Y0 + 2 * r), ROW_INK[r])
                    image.putpixel((x + 2 * c + 1, Y0 + 2 * r), ROW_INK[r])
        x += 2 * (len(glyphs[letter][0]) + 2)

    PNG.parent.mkdir(parents=True, exist_ok=True)
    image.save(PNG)
    pixels = image.tobytes()
    framebuffer = pixels + bytes(FRAMEBUFFER_BYTES - len(pixels))
    with HEX.open('w', encoding='ascii', newline='\n') as out:
        out.write(''.join(f'{value:02X}\n' for value in framebuffer))
    print(f'wrote {PNG.relative_to(ROOT)} and {HEX.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
