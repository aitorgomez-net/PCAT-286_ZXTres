"""Pack the indexed VGA splash into the mode 13h framebuffer and DAC images.

The splash is a 320x200 palette PNG with up to 256 colours. It is shown
through the packed mode 13h raster, so the pixel indices are stored exactly as
mode 13h keeps them: one byte per pixel, row after row, at A000:0000. The
64000 picture bytes are padded with zeros to the full 64 KiB framebuffer.

The palette becomes a 256-entry RGB666 table, one 18-bit hex word per line
with red in bits 17:12, green in 11:6 and blue in 5:0. PNG palette components
are 8-bit, so each is reduced to the 6 bits a VGA DAC holds; author the image
with components that survive that (v == round(round(v * 63 / 255) * 255 / 63))
to see on screen exactly what the PNG shows.
"""

from pathlib import Path

from PIL import Image


WIDTH = 320
HEIGHT = 200
FRAMEBUFFER_BYTES = 65536
PALETTE_ENTRIES = 256

ROOT = Path(__file__).resolve().parents[1]
PREVIEW = ROOT / "SW" / "splash_vga_320x200.png"
PIXELS = ROOT / "rtl" / "video" / "splash_vga_320x200.hex"
PALETTE = ROOT / "rtl" / "video" / "splash_vga_palette.hex"


def dac6(value: int) -> int:
    return (value * 63 + 127) // 255


def main() -> None:
    image = Image.open(PREVIEW)
    if image.mode != "P":
        raise ValueError(f"Expected an indexed (palette) PNG, got mode {image.mode}")
    if image.size != (WIDTH, HEIGHT):
        raise ValueError(f"Expected {WIDTH}x{HEIGHT}, got {image.size}")

    pixels = image.tobytes()
    assert len(pixels) == WIDTH * HEIGHT
    framebuffer = pixels + bytes(FRAMEBUFFER_BYTES - len(pixels))

    palette = image.getpalette() or []
    palette = (palette + [0] * (PALETTE_ENTRIES * 3))[:PALETTE_ENTRIES * 3]
    entries = []
    for index in range(PALETTE_ENTRIES):
        red, green, blue = (dac6(v) for v in palette[index * 3:index * 3 + 3])
        entries.append((red << 12) | (green << 6) | blue)

    with PIXELS.open("w", encoding="ascii", newline="\n") as out:
        out.write("".join(f"{value:02X}\n" for value in framebuffer))
    with PALETTE.open("w", encoding="ascii", newline="\n") as out:
        out.write("".join(f"{value:05X}\n" for value in entries))


if __name__ == "__main__":
    main()
