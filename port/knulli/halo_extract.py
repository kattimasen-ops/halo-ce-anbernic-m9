#!/usr/bin/env python3
"""Copies the maps folder out of an Xbox disc image of Halo (an XISO, or a
full disc image), for the Knulli port's launcher (port/knulli/README.md):

    halo_extract.py <disc image> <destination folder>

It reads the Xbox file system (XDVDFS) as port/linux/src/xiso.c does, with
Python's standard library only, so that it runs on the handheld. The disc
image is only read.
"""

import os
import struct
import sys

SECTOR = 2048
MAGIC = b"MICROSOFT*XBOX*MEDIA"
# where the game's file system starts: an XISO, then the full disc images
# of the first Xbox discs (XGD1) and of later ones
PARTITIONS = [0, 0x18300000, 0xFD90000, 0x2080000]
CHUNK = 4 * 1024 * 1024


def find_partition(image):
    for base in PARTITIONS:
        image.seek(base + 32 * SECTOR)
        if image.read(len(MAGIC)) == MAGIC:
            return base
    raise SystemExit("not an Xbox disc image: no XDVDFS volume descriptor")


def read_directory(image, base, sector, size):
    """the entries of a directory: (name, sector, size, is_directory)"""
    image.seek(base + sector * SECTOR)
    data = image.read(size)
    entries, pending, seen = [], [0], set()
    while pending:
        offset = pending.pop()
        if offset in seen or offset + 14 > len(data):
            continue
        seen.add(offset)
        left, right, start, length, attributes, name_length = struct.unpack_from("<HHIIBB", data, offset)
        if left == 0xFFFF and right == 0xFFFF:
            continue
        name = data[offset + 14:offset + 14 + name_length].decode("latin-1")
        entries.append((name, start, length, bool(attributes & 0x10)))
        if left:
            pending.append(left * 4)
        if right:
            pending.append(right * 4)
    return entries


def main():
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} <disc image> <destination folder>")
    image_path, destination = sys.argv[1], sys.argv[2]
    with open(image_path, "rb") as image:
        base = find_partition(image)
        image.seek(base + 32 * SECTOR + len(MAGIC))
        root_sector, root_size = struct.unpack("<II", image.read(8))
        maps = next((entry for entry in read_directory(image, base, root_sector, root_size)
                     if entry[0].lower() == "maps" and entry[3]), None)
        if not maps:
            raise SystemExit("the disc image has no maps folder")
        files = [entry for entry in read_directory(image, base, maps[1], maps[2]) if not entry[3]]
        total = sum(entry[2] for entry in files) or 1
        target = os.path.join(destination, "maps")
        os.makedirs(target, exist_ok=True)
        done = 0
        # ui.map last: the launcher takes it as the sign that the folder is whole
        for name, start, length, _ in sorted(files, key=lambda entry: (entry[0].lower() == "ui.map", entry[0].lower())):
            path = os.path.join(target, name.lower())
            print(f"{done * 100 // total:3d}% {name}", flush=True)
            image.seek(base + start * SECTOR)
            with open(path + ".part", "wb") as output:
                remaining = length
                while remaining:
                    block = image.read(min(CHUNK, remaining))
                    if not block:
                        raise SystemExit(f"the disc image ends inside {name}")
                    output.write(block)
                    remaining -= len(block)
            os.replace(path + ".part", path)
            done += length
        print(f"100% {len(files)} files", flush=True)


if __name__ == "__main__":
    main()
