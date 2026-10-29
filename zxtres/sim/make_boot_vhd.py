#!/usr/bin/env python3
"""Write a small fixed VHD whose boot sector prints a message through the BIOS.

  make_boot_vhd.py OUT.VHD [megabytes] [message]

Sector 0 holds a boot sector (no partition table) that prints the message with
INT 10h and stops; the rest is zero and ends in a fixed-VHD footer with the
disk geometry (16 heads, 63 sectors per track). It is for sim/run_bios_sim.sh:
a BIOS that reads the disk through the IDE store prints the message. Sector
n of the disk also starts with the text "Sn" so a test can tell them apart.
"""
import struct
import sys
from pathlib import Path


def boot_sector(message):
    code = bytes([
        0xFA,                    # cli
        0x31, 0xC0,              # xor ax, ax
        0x8E, 0xD8,              # mov ds, ax
        0x8E, 0xC0,              # mov es, ax
        0x8E, 0xD0,              # mov ss, ax
        0xBC, 0x00, 0x7C,        # mov sp, 7C00h
        0xFB,                    # sti
        0xBE, 0x20, 0x7C,        # mov si, message
        0xAC,                    # next: lodsb
        0x08, 0xC0,              # or al, al
        0x74, 0x09,              # jz done
        0xB4, 0x0E,              # mov ah, 0Eh
        0xBB, 0x07, 0x00,        # mov bx, 7
        0xCD, 0x10,              # int 10h
        0xEB, 0xF2,              # jmp next
        0xEB, 0xFE,              # done: jmp done
    ])
    assert len(code) == 32
    sector = bytearray(512)
    sector[:len(code)] = code
    text = message.encode('ascii') + b'\0'
    sector[32:32 + len(text)] = text
    sector[510:512] = b'\x55\xAA'
    return sector


def footer(size):
    sectors = size // 512
    cylinders = min(sectors // (16 * 63), 16383)
    f = bytearray(512)
    f[0:8] = b'conectix'
    struct.pack_into('>I', f, 8, 2)                 # features
    struct.pack_into('>I', f, 12, 0x00010000)       # file format version
    struct.pack_into('>Q', f, 16, 0xFFFFFFFFFFFFFFFF)
    f[28:32] = b'pcat'
    struct.pack_into('>Q', f, 40, size)             # original size
    struct.pack_into('>Q', f, 48, size)             # current size
    struct.pack_into('>H', f, 56, cylinders)
    f[58] = 16
    f[59] = 63
    struct.pack_into('>I', f, 60, 2)                # fixed disk
    struct.pack_into('>I', f, 64, (~sum(f)) & 0xFFFFFFFF)
    return f


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    megabytes = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    message = sys.argv[3] if len(sys.argv) > 3 else 'PCAT HDD BOOT OK'
    size = megabytes * 1024 * 1024
    data = bytearray(size)
    for n in range(size // 512):
        data[n * 512:n * 512 + 8] = (b'S%d' % n).ljust(8, b' ')[:8]
    data[0:512] = boot_sector(message)
    out.write_bytes(bytes(data) + bytes(footer(size)))


main()
