#!/usr/bin/env python3
"""Packs clothod/dist for the app bundle: manifest.json as is, and each build raw-deflated as
<file>.deflate. App Store validation rejects Mach-O executables for other platforms inside an iOS app;
the app inflates the exact bytes back on first use (DistBundle.swift).

Usage: pack-dist.py <clothod/dist> <output dir>"""
import json, os, shutil, sys, zlib

src, out = sys.argv[1], sys.argv[2]
manifest_path = os.path.join(src, "manifest.json")
stamp = os.path.join(out, ".packed-from")
if not os.path.exists(manifest_path):
    # A fresh clone: clothod/dist is gitignored and made by clothod/scripts/dist.sh.
    sys.exit(f"error: {manifest_path} is missing; build the clothod releases first with clothod/scripts/dist.sh")
key = open(manifest_path, "rb").read()
if os.path.exists(stamp) and open(stamp, "rb").read() == key:
    # The stamp alone proves nothing: a cleaned or half-written output dir can keep it. Skip only when every
    # packed file is there too.
    packed = ["manifest.json"] + [build["file"] + ".deflate" for build in json.loads(key)["builds"].values()]
    missing = [name for name in packed if not os.path.isfile(os.path.join(out, name))]
    if not missing:
        sys.exit(0)
    print(f"stale stamp in {out}: {len(missing)} of {len(packed)} packed files missing ({missing[0]}); repacking")
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)
shutil.copy(manifest_path, os.path.join(out, "manifest.json"))
for build in json.loads(key)["builds"].values():
    data = open(os.path.join(src, build["file"]), "rb").read()
    packer = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw deflate, which NSData's .zlib expects
    target = os.path.join(out, build["file"] + ".deflate")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    open(target, "wb").write(packer.compress(data) + packer.flush())
open(stamp, "wb").write(key)
print(f"packed {len(json.loads(key)['builds'])} clothod builds into {out}")
