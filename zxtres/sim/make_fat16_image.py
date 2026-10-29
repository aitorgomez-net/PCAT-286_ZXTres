#!/usr/bin/env python3
"""Build a small FAT16 image (no partition table) for the SD card model,
plus IMAGE.sparse with only its non-zero bytes.

  make_fat16_image.py IMAGE FILE...

The image is 8 MiB with 2 KiB clusters. A FILE goes to the root directory
under its 8.3 name in capitals; FOLDER/NAME.EXT=FILE puts it in that folder
of the root (one cluster of entries each) under that name. DeMiSTify's minfat accepts a FAT16 volume
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


def name83(name):
    stem, _, ext = name.upper().partition('.')
    if not (1 <= len(stem) <= 8 and len(ext) <= 3):
        sys.exit(f'{name}: not an 8.3 name')
    return stem.ljust(8).encode() + ext.ljust(3).encode()


def entry(name, attributes, cluster, size):
    return struct.pack('<11sBBBHHHHHHHI', name, attributes, 0, 0, 0, 0, 0, 0,
                       0, 0, cluster, size)


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
    cluster_bytes = SECTORS_PER_CLUSTER * SECTOR

    def put(cluster, data):
        offset = (DATA_START + (cluster - 2) * SECTORS_PER_CLUSTER) * SECTOR
        image[offset:offset + len(data)] = data

    files = []
    for argument in sys.argv[2:]:
        target, _, source = argument.rpartition('=')
        folder, _, name = (target or Path(source).name).rpartition('/')
        files.append((folder.upper(), name, Path(source).read_bytes()))
    # One cluster per folder, then the files.
    folders = {}
    root = bytearray()
    for folder in dict.fromkeys(f for f, _, _ in files if f):
        folders[folder] = [len(fat), bytearray()]
        fat.append(0xFFFF)
        folders[folder][1] += entry(b'.          ', 0x10, folders[folder][0], 0)
        folders[folder][1] += entry(b'..         ', 0x10, 0, 0)
        root += entry(name83(folder), 0x10, folders[folder][0], 0)
    for folder, name, data in files:
        first = len(fat)
        clusters = max(1, -(-len(data) // cluster_bytes))
        for index in range(clusters):
            fat.append(0xFFFF if index == clusters - 1 else len(fat) + 1)
            put(first + index, data[index * cluster_bytes:(index + 1) * cluster_bytes])
        record = entry(name83(name), 0x20, first, len(data))
        if folder:
            folders[folder][1] += record
        else:
            root += record
    for first, entries in folders.values():
        if len(entries) > cluster_bytes:
            sys.exit('too many files in one folder')
        put(first, entries)
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
    print(f'{sys.argv[1]}: {len(files)} files, {len(folders)} folders, data from sector {DATA_START}')


if __name__ == '__main__':
    main()
