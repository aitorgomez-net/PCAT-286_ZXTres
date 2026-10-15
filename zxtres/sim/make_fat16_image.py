#!/usr/bin/env python3
"""Build a small FAT16 image (no partition table) for the SD card model,
plus IMAGE.sparse with only its non-zero bytes.

  make_fat16_image.py IMAGE FILE...

The image is 8 MiB with 2 KiB clusters, the files go to the root directory
under their 8.3 names in capitals. DeMiSTify's minfat accepts a FAT16 volume
that starts at sector 0.
"""
from pathlib import Path
import struct
import sys

SECTOR = 512
TOTAL_SECTORS = 16384            # 8 MiB
SECTORS_PER_CLUSTER = 4          # 2 KiB clusters
RESERVED = 1
FATS = 2
ROOT_ENTRIES = 512
ROOT_SECTORS = ROOT_ENTRIES * 32 // SECTOR
CLUSTERS = (TOTAL_SECTORS - RESERVED - ROOT_SECTORS) // SECTORS_PER_CLUSTER
FAT_SECTORS = ((CLUSTERS + 2) * 2 + SECTOR - 1) // SECTOR
DATA_START = RESERVED + FATS * FAT_SECTORS + ROOT_SECTORS


def name83(path):
    stem, _, ext = path.name.upper().partition('.')
    if not (1 <= len(stem) <= 8 and len(ext) <= 3):
        sys.exit(f'{path.name}: not an 8.3 name')
    return stem.ljust(8).encode() + ext.ljust(3).encode()


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    image = bytearray(TOTAL_SECTORS * SECTOR)
    boot = struct.pack('<3s8sHBHBHHBHHHII', b'\xEB\x3C\x90', b'SPK286  ', SECTOR,
                       SECTORS_PER_CLUSTER, RESERVED, FATS, ROOT_ENTRIES, TOTAL_SECTORS,
                       0xF8, FAT_SECTORS, 32, 64, 0, 0)
    boot += struct.pack('<BBBI11s8s', 0x80, 0, 0x29, 0x12345678, b'ZXTRES SIM ', b'FAT16   ')
    image[0:len(boot)] = boot
    image[510:512] = b'\x55\xAA'

    fat = [0xFFF8, 0xFFFF]
    root = bytearray()
    cluster = 2
    for argument in sys.argv[2:]:
        path = Path(argument)
        data = path.read_bytes()
        clusters = max(1, -(-len(data) // (SECTORS_PER_CLUSTER * SECTOR)))
        first = cluster
        for index in range(clusters):
            fat.append(0xFFFF if index == clusters - 1 else cluster + 1)
            offset = (DATA_START + (cluster - 2) * SECTORS_PER_CLUSTER) * SECTOR
            chunk = data[index * SECTORS_PER_CLUSTER * SECTOR:(index + 1) * SECTORS_PER_CLUSTER * SECTOR]
            image[offset:offset + len(chunk)] = chunk
            cluster += 1
        root += struct.pack('<11sBBBHHHHHHHI', name83(path), 0x20, 0, 0, 0, 0, 0, 0,
                            0, 0, first, len(data))
    fat_bytes = struct.pack(f'<{len(fat)}H', *fat)
    for copy in range(FATS):
        offset = (RESERVED + copy * FAT_SECTORS) * SECTOR
        image[offset:offset + len(fat_bytes)] = fat_bytes
    root_offset = (RESERVED + FATS * FAT_SECTORS) * SECTOR
    image[root_offset:root_offset + len(root)] = root
    Path(sys.argv[1]).write_bytes(image)
    # Sparse form for the SD card model: one "address value" line, in hex,
    # per non-zero byte. Loading 8 MiB byte by byte is too slow in xsim.
    with open(sys.argv[1] + '.sparse', 'w') as sparse:
        for address, value in enumerate(image):
            if value:
                sparse.write(f'{address:x} {value:02x}\n')
    print(f'{sys.argv[1]}: {len(sys.argv) - 2} files, data from sector {DATA_START}')


if __name__ == '__main__':
    main()
