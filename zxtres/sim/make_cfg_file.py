#!/usr/bin/env python3
"""Write a PCAT286.CFG for the ZXTRES+ firmware (zxtres/firmware/overrides.c).

  make_cfg_file.py OUT [--disk0 PATH] [--disk1 PATH] [--floppy-a PATH]
                       [--floppy-b PATH] [--bios PATH] [--ega PATH]
                       [--low HEX] [--high HEX] [--blank]

PATH is the file's path from the root of the card, NAME.EXT separated by
'/' ("DISKS/BOOT.VHD"). --bios and --ega are the system and EGA BIOS files
(empty: PCAT286.ROM and EGA.ROM). The status word halves default to 0, the
OSD's defaults. --blank writes the zeroed sector a new card starts with.
"""
import argparse
import struct
from pathlib import Path

PATHS = 32
PATH_SIZE = 80      # version 2 had four paths of 112


def main():
    parser = argparse.ArgumentParser(usage=__doc__)
    parser.add_argument('out')
    for name in ('disk0', 'disk1', 'floppy-a', 'floppy-b', 'bios', 'ega'):
        parser.add_argument('--' + name, default='')
    parser.add_argument('--low', default='0')
    parser.add_argument('--high', default='0')
    parser.add_argument('--blank', action='store_true')
    args = parser.parse_args()

    sector = bytearray(512)
    if not args.blank:
        sector[0:16] = struct.pack('<4sB3xII', b'PCAT', 3, int(args.low, 16), int(args.high, 16))
        for index, path in enumerate((args.disk0, args.disk1, args.floppy_a, args.floppy_b,
                                    args.bios, args.ega)):
            data = path.upper().encode()
            if len(data) >= PATH_SIZE:
                raise SystemExit(f'{path}: longer than {PATH_SIZE - 1} characters')
            sector[PATHS + index * PATH_SIZE:PATHS + index * PATH_SIZE + len(data)] = data
    Path(args.out).write_bytes(sector)


if __name__ == '__main__':
    main()
