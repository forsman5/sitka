---
name: find-asset
description: Search the user's locally downloaded 3D asset packs (KayKit, Quaternius, etc. in ~/Downloads) for models to use in Sitka. Use whenever asked to find, suggest, or add a model/asset (houses, characters, animals, props), or to check whether a pack already has something, before searching the web or proposing a new download.
---

# find-asset

Always search the local library first; only suggest new downloads if it has nothing suitable.

```bash
python3 -I .claude/skills/find-asset/asset_index.py packs                 # packs, license, preview image
python3 -I .claude/skills/find-asset/asset_index.py search house          # all terms must match pack/path/name
python3 -I .claude/skills/find-asset/asset_index.py search female --pack character --not-in-repo
python3 -I .claude/skills/find-asset/asset_index.py info "builder pack 1.0\models\objects\gltf\house"
python3 -I .claude/skills/find-asset/asset_index.py add <folder-or-zip> --source <url>   # new download -> library
python3 -I .claude/skills/find-asset/asset_index.py scan                  # rebuild index
```

The library is `C:/gamedev-assets/packs/<pack>/` (env `SITKA_ASSET_LIBRARY`), one folder per pack with a `pack.json` (source URL, license file, date). Always `add` a newly downloaded pack so it persists outside Downloads, passing `--source` when known; `packs` shows `UNKNOWN` for missing sources. `SITKA_ASSET_PACKS` overrides the scanned roots. Index cache: `~/.claude/asset_index.json`. No backup is set up yet.
Output shows format, `flat` (solid material colors) vs `atlas` (shared texture), raw bbox, animation count, and `IN REPO` if a same-named file is already under `assets/`.

## Before proposing or importing a model

1. **Read the pack's `Preview`/`Overview` image** (path from `packs`) to judge art style. Sitka's look is low-poly, single team color (blue). Detailed PBR kits (Quaternius Medieval Village MegaKit) do not blend.
2. **Modular kits are not drop-ins.** Hundreds of wall/roof/corner pieces mean hand-assembling a building. Prefer packs with whole buildings.
3. **Team colors:** the KayKit Hexagon pack ships `_blue/_green/_red/_yellow` variants; Sitka uses blue only. Flat-color packs (KayKit Builder, Quaternius characters) have no team variants; retint a material by editing `baseColorFactor` in the glb JSON.
4. **Materials can hide geometry.** In flat-color glbs, one material = one merged primitive, so decoration (fence, puddle) and wanted detail (door trim) can share a primitive and can't be removed by dropping it. Check by rendering, not by material name.
5. **Bbox drives scaling.** `he_town_view.gd` scales by `width / max(x, z)` of the full mesh bounds, so stray wide decoration shrinks the whole model. Use the art dict's `scale_ref` override rather than editing the mesh. House plots are 6x6; house art width is about 4.5.
6. Raw bbox units differ per pack (animated characters report armature-scale numbers); compare within a pack, and confirm real size with a Godot probe.
7. Importing: copy the `.gltf` + `.bin` (or `.glb`), run `godot --headless --path . --import` so Godot writes the `.import`, then add the file to `scripts/ci/check_web_assets.gd` `REQUIRED_MODELS`. Do not hand-write `.import` files.
8. Check the pack's License file (CC0 for the KayKit/Quaternius packs so far). Same-pack character models share rig and animation names, so a female/male pair is a drop-in.
