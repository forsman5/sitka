#!/usr/bin/env python3
"""Index and search locally downloaded 3D asset packs (glTF/GLB, plus FBX names).

  asset_index.py packs                      one line per pack
  asset_index.py search <term...> [opts]    all terms must match pack/path/name
  asset_index.py info <path-or-name>        materials, bbox, animations for one model
  asset_index.py scan                       force a rescan
  asset_index.py add <folder-or-zip> [--name N] [--source URL]   copy a pack into the library

Library: env SITKA_ASSET_LIBRARY, default C:/gamedev-assets/packs (one folder per pack,
with a pack.json holding source URL and license). Override the scanned roots with
SITKA_ASSET_PACKS (os.pathsep-separated).
Cache: ~/.claude/asset_index.json (rebuilt on `scan`, or when missing).
Bounding boxes are mesh-local POSITION extents (node transforms ignored).
"""
import argparse
import datetime
import re
import shutil
import zipfile
import json
import os
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
CACHE = Path.home() / ".claude" / "asset_index.json"
SKIP_DIRS = {".git", ".godot", "node_modules", "obj", "dae", "fbx(unity)", "unity"}
LICENSE_HINTS = ("license", "licence")


DEFAULT_LIBRARY = Path(os.environ.get("SITKA_ASSET_LIBRARY", "C:/gamedev-assets/packs"))
TAKEOUT_SUFFIX = re.compile(r"-\d{8}T\d{6}Z-\d+-\d+$")


def pack_roots():
    raw = os.environ.get("SITKA_ASSET_PACKS")
    if raw:
        return [Path(p) for p in raw.split(os.pathsep) if p]
    return [DEFAULT_LIBRARY]


def add_pack(source, name=None, source_url=None):
    """Copy a pack folder (or unzip a .zip) into the library with a pack.json."""
    src = Path(source)
    name = name or TAKEOUT_SUFFIX.sub("", src.stem if src.suffix.lower() == ".zip" else src.name)
    dest = DEFAULT_LIBRARY / name
    if dest.exists():
        sys.exit(f"already in library: {dest}")
    DEFAULT_LIBRARY.mkdir(parents=True, exist_ok=True)
    if src.suffix.lower() == ".zip":
        with zipfile.ZipFile(src) as z:
            z.extractall(dest)
    elif src.is_dir():
        shutil.copytree(src, dest, ignore=shutil.ignore_patterns("*.zip"))
    else:
        sys.exit("source must be a folder or .zip")
    while True:
        children = list(dest.iterdir())
        if len(children) == 1 and children[0].is_dir():
            inner = children[0]
            for item in inner.iterdir():
                shutil.move(str(item), str(dest / item.name))
            inner.rmdir()
        else:
            break
    lic, _ = pack_extras(dest)
    meta = {"source_url": source_url or "unknown", "license_file": Path(lic).name if lic else None,
            "added": datetime.date.today().isoformat()}
    (dest / "pack.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(f"added {name} -> {dest}")


def read_gltf_json(path):
    if path.suffix.lower() == ".glb":
        data = path.read_bytes()
        offset = 12
        while offset < len(data):
            length, ctype = struct.unpack("<I4s", data[offset:offset + 8])
            if ctype == b"JSON":
                return json.loads(data[offset + 8:offset + 8 + length])
            offset += 8 + length
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def describe_gltf(path):
    g = read_gltf_json(path)
    if not g:
        return {}
    mins, maxs = [1e9] * 3, [-1e9] * 3
    for mesh in g.get("meshes", []):
        for prim in mesh.get("primitives", []):
            acc = g["accessors"][prim["attributes"]["POSITION"]]
            for i in range(3):
                mins[i] = min(mins[i], acc["min"][i])
                maxs[i] = max(maxs[i], acc["max"][i])
    size = [round(maxs[i] - mins[i], 2) for i in range(3)] if mins[0] < 1e8 else None
    mats = [m.get("name", "?") for m in g.get("materials", [])]
    return {
        "size": size,
        "style": "atlas" if g.get("images") else "flat",
        "materials": mats,
        "animations": [a.get("name", "?") for a in g.get("animations", [])],
        "meshes": len(g.get("meshes", [])),
    }


def pack_extras(pack_dir):
    license_file, preview = None, None
    for p in pack_dir.rglob("*"):
        if len(p.relative_to(pack_dir).parts) > 3 or not p.is_file():
            continue
        low = p.name.lower()
        if license_file is None and any(h in low for h in LICENSE_HINTS):
            license_file = str(p)
        if preview is None and low.startswith(("preview", "overview", "contents")) and low.endswith((".png", ".jpg")):
            preview = str(p)
    return license_file, preview


def repo_stems():
    stems = {}
    for p in (REPO_ROOT / "assets").rglob("*"):
        if p.suffix.lower() in (".gltf", ".glb", ".fbx"):
            stems[p.stem.lower().removesuffix(".gltf")] = str(p.relative_to(REPO_ROOT)).replace("\\", "/")
    return stems


def scan():
    in_repo = repo_stems()
    entries, packs = [], {}
    for root in pack_roots():
        if not root.is_dir():
            continue
        for pack_dir in sorted(p for p in root.iterdir() if p.is_dir()):
            found = []
            for dirpath, dirnames, filenames in os.walk(pack_dir):
                dirnames[:] = [d for d in dirnames if d.lower() not in SKIP_DIRS]
                for f in filenames:
                    if f.lower().endswith((".gltf", ".glb", ".fbx")):
                        found.append(Path(dirpath) / f)
            if not found:
                continue
            has_gltf = any(p.suffix.lower() in (".gltf", ".glb") for p in found)
            kept = [p for p in found if not (has_gltf and p.suffix.lower() == ".fbx")]
            lic, prev = pack_extras(pack_dir)
            meta_file = pack_dir / "pack.json"
            source_url = json.loads(meta_file.read_text(encoding="utf-8")).get("source_url") if meta_file.exists() else None
            packs[pack_dir.name] = {"path": str(pack_dir), "count": len(kept), "license": lic, "preview": prev,
                                    "source": source_url}
            for p in kept:
                stem = p.stem.lower().removesuffix(".gltf")
                e = {"pack": pack_dir.name, "name": p.name, "path": str(p), "format": p.suffix.lower().lstrip("."),
                     "in_repo": in_repo.get(stem)}
                if p.suffix.lower() in (".gltf", ".glb"):
                    try:
                        e.update(describe_gltf(p))
                    except (OSError, KeyError, ValueError):
                        e["parse_error"] = True
                entries.append(e)
    index = {"packs": packs, "entries": entries}
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(index), encoding="utf-8")
    return index


def load(force=False):
    if force or not CACHE.exists():
        return scan()
    return json.loads(CACHE.read_text(encoding="utf-8"))


def fmt(e):
    size = "x".join(str(s) for s in e["size"]) if e.get("size") else "?"
    tags = [e["format"], e.get("style", "unparsed"), f"size {size}"]
    if e.get("animations"):
        tags.append(f"{len(e['animations'])} anims")
    if e.get("in_repo"):
        tags.append("IN REPO: " + e["in_repo"])
    return f"{e['pack']} :: {e['name']}  [{', '.join(tags)}]\n    {e['path']}"


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("packs")
    sub.add_parser("scan")
    a = sub.add_parser("add")
    a.add_argument("source")
    a.add_argument("--name")
    a.add_argument("--source", dest="source_url")
    s = sub.add_parser("search")
    s.add_argument("terms", nargs="+")
    s.add_argument("--pack")
    s.add_argument("--style", choices=["flat", "atlas"])
    s.add_argument("--not-in-repo", action="store_true")
    s.add_argument("--limit", type=int, default=40)
    s.add_argument("--rescan", action="store_true")
    i = sub.add_parser("info")
    i.add_argument("target")
    args = ap.parse_args()

    if args.cmd == "add":
        add_pack(args.source, args.name, args.source_url)
        args.cmd = "scan"
    index = scan() if args.cmd == "scan" else load(getattr(args, "rescan", False))
    if args.cmd == "scan":
        print(f"indexed {len(index['entries'])} models in {len(index['packs'])} packs -> {CACHE}")
    elif args.cmd == "packs":
        for name, p in index["packs"].items():
            print(f"{name}: {p['count']} models\n    {p['path']}\n    source: {p.get('source') or 'UNKNOWN'}\n    license: {p['license'] or 'none found'}\n    preview: {p['preview'] or 'none'}")
    elif args.cmd == "search":
        terms = [t.lower() for t in args.terms]
        hits = [e for e in index["entries"]
                if all(t in (e["pack"] + " " + e["path"]).lower() for t in terms)
                and (not args.pack or args.pack.lower() in e["pack"].lower())
                and (not args.style or e.get("style") == args.style)
                and not (args.not_in_repo and e.get("in_repo"))]
        for e in hits[:args.limit]:
            print(fmt(e))
        print(f"-- {len(hits)} match(es), showing {min(len(hits), args.limit)}")
    elif args.cmd == "info":
        t = args.target.lower()
        for e in index["entries"]:
            if t in e["path"].lower():
                print(fmt(e))
                if e.get("materials"):
                    print("    materials:", ", ".join(e["materials"]))
                if e.get("animations"):
                    print("    animations:", ", ".join(e["animations"][:20]))


if __name__ == "__main__":
    sys.exit(main())
