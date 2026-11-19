#!/usr/bin/env python3
"""Unpack a Xiaomi-band .face/.face.bin container into a watchsim face dir.

Container layout (magic 5A A5 34 12, seen on MiBand/AstroBox toolchains):
    header   ~0x800 bytes of device metadata
    entries  repeat {
        u32(?)   kind: 0x00000011 image, 0x0000000c lua source (low byte
                 observed; stored little-endian before the pad)
        16 x 00  padding
        u32      name_len
        bytes    name (name_len, e.g. "lua/main.lua")
        bytes    data   (image bytes / lua source; runs until the next
                 entry's kind word)
    }
    The last entry may be followed by a footer table (u32 offsets); the
    unpacker bounds data by scanning for the next "lua/..." or "assets/..."
    name and backing up over its header.

Usage:
    python3 tools/unpack_face.py <file.face[.bin]> <out_dir>
"""
from __future__ import annotations

import os
import re
import sys

NAME_RE = re.compile(rb'(?:lua|assets)/[a-zA-Z0-9_./-]{2,60}')
# header between entries: kind(4) + pad(16) + name_len(4) = 24 bytes
HEAD_LEN = 24


def unpack(path: str, out_dir: str) -> int:
    data = open(path, "rb").read()
    if data[:4] != b"\x5a\xa5\x34\x12":
        sys.exit(f"not a .face container: {path}")

    cands = [(m.start(), m.group().decode()) for m in NAME_RE.finditer(data)]
    if not cands:
        sys.exit("no lua/assets entries found")

    os.makedirs(out_dir, exist_ok=True)
    n = 0
    for i, (name_off, name) in enumerate(cands):
        data_start = name_off + len(name)
        if i + 1 < len(cands):
            next_name = cands[i + 1][0]
            # Walk back over the next entry's header (kind + pad +
            # name_len). Some containers put extra footer/u32 tables between
            # entries; trim any trailing NULs and one ETX (0x03) marker the
            # toolchain appends after lua sources.
            end = next_name - HEAD_LEN
            while end > data_start and data[end - 1] == 0:
                end -= 1
            if end > data_start and data[end - 1] == 3:
                end -= 1
        else:
            end = len(data)
            while end > data_start and data[end - 1] == 0:
                end -= 1

        blob = data[data_start:end]
        out = os.path.join(out_dir, name)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "wb") as f:
            f.write(blob)
        n += 1
        print(f"  {name}  ({len(blob)} bytes)")
    return n


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    print(f"unpack {sys.argv[1]} -> {sys.argv[2]}")
    count = unpack(sys.argv[1], sys.argv[2])
    print(f"{count} entries")
