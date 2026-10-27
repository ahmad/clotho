#!/usr/bin/env python3
"""Packs clothod/dist for the app bundle: manifest.json as is, and each build raw-deflated as
<file>.deflate. App Store validation rejects Mach-O executables for other platforms inside an iOS app;
the app inflates the exact bytes back on first use (DistBundle.swift).

Usage: pack-dist.py <clothod/dist> <output dir>"""
import json, os, shutil, sys, zlib

src, out = sys.argv[1], sys.argv[2]
manifest_path = os.path.join(src, "manifest.json")
stamp = os.path.join(out, ".packed-from")
key = open(manifest_path, "rb").read()
if os.path.exists(stamp) and open(stamp, "rb").read() == key:
    sys.exit(0)
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
