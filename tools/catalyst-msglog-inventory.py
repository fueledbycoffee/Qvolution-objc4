#!/usr/bin/env python3
"""Write a CATALYST_MSGLOG inventory: "<size> /<guest path>" for every regular Mach-O file under ROOT.

  python3 -I tools/catalyst-msglog-inventory.py ROOT OUT

ROOT is a runtime tree built from source by us (the catalyst stage or DESTDIR libexec/darling);
the magic check reads only that tree. Symlinks are skipped: libobjc matches images by real path. Each image is listed under
its guest-root path and its /Volumes/SystemRoot host path.
"""
import os, sys
from pathlib import Path

MAGICS = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
root, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
lines = []
for dirpath, dirnames, filenames in os.walk(root):
    for name in filenames:
        p = Path(dirpath) / name
        if p.is_symlink() or not p.is_file():
            continue
        with open(p, 'rb') as f:
            if f.read(4) not in MAGICS:
                continue
        size = p.stat().st_size
        # a root-mode guest names images under its own root; a DARLING_NONROOT guest names them
        # by their host path under /Volumes/SystemRoot
        lines.append(f'{size} /{p.relative_to(root)}\n')
        lines.append(f'{size} /Volumes/SystemRoot{p}\n')
lines.sort(key=lambda l: l.split(' ', 1)[1])
out.write_text(''.join(lines))
print(f'{len(lines)} images -> {out}')
