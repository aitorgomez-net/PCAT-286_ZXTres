#!/usr/bin/env python3
"""Build a PCAT286.CMS file for the ZXTRES+ CMOS store.

    make_cmos_file.py BASE.bin OUT.CMS [--drive-c CYL,HEADS,SPT]

BASE.bin is the 128 CMOS bytes that zxtres_pcat_bios_tb writes with
+DUMP_CMOS (cmos.bin). With --drive-c the file also describes hard disk C as
user-defined type 47, the way AT BIOSes store it (10h-2Dh), and carries the
checksums of the AT (2Eh/2Fh) and of MR BIOS (low five bits of 3Fh).

File layout (zxtres_cmos_store.sv): bytes 0-127 the CMOS image, 128-135 the
signature "PCATCMOS", byte 136 the version, the rest zero (512 bytes)."""
import sys


def main(argv):
    drive = None
    args = []
    i = 1
    while i < len(argv):
        if argv[i] == '--drive-c':
            drive = [int(v) for v in argv[i + 1].split(',')]
            i += 2
        else:
            args.append(argv[i])
            i += 1
    if len(args) != 2 or (drive is not None and len(drive) != 3):
        sys.exit(__doc__)
    cmos = bytearray(open(args[0], 'rb').read())
    if len(cmos) != 128:
        sys.exit("%s: %d bytes, expected 128" % (args[0], len(cmos)))
    if drive:
        cyl, heads, spt = drive
        cmos[0x12] = (cmos[0x12] & 0x0F) | 0xF0      # drive C: type above 14
        cmos[0x19] = 47                              # user-defined type
        cmos[0x1B:0x1D] = cyl.to_bytes(2, 'little')
        cmos[0x1D] = heads
        cmos[0x1E:0x20] = (0xFFFF).to_bytes(2, 'little')   # no write precompensation
        cmos[0x20] = 0x08 if heads > 8 else 0x00     # control byte
        cmos[0x21:0x23] = cyl.to_bytes(2, 'little')  # landing zone
        cmos[0x23] = spt
        total = sum(cmos[0x10:0x2E])
        cmos[0x2E:0x30] = total.to_bytes(2, 'big')
        total = 0x1F
        for a in range(0x10, 0x3F):
            if a in (0x11, 0x13) or 0x1B <= a <= 0x2D or 0x33 <= a <= 0x3E:
                total += cmos[a] & 0x1F
        cmos[0x3F] = (cmos[0x3F] & 0xE0) | (total & 0x1F)
    image = bytearray(512)
    image[:128] = cmos
    image[128:136] = b"PCATCMOS"
    image[136] = 1
    open(args[1], 'wb').write(image)


main(sys.argv)
