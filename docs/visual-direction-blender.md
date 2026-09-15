# Direction B: Build a small reusable asset kit in Blender

**Recommendation:** Follow the first landscape pass with this direction, or choose it first if close-up settlement character is the immediate priority. Blender supplies recognizable forms; Godot remains where the scene is assembled and judged.

## What the current image needs

The settlement clusters look like similarly sized boxes, and resource markers still read as symbols. At the shown camera distance, roof shapes, building proportions, and the arrangement of a landing will contribute more identity than detailed wall textures. The existing trees are already imported models; replacing every asset would add work without resolving the rough river geometry.

Aim for a coherent, slightly stylized early-medieval settlement kit: broad thatched roofs, timber structures, earth-colored walls, and strong silhouettes. Historical specificity can deepen later; avoid making a few decorative models dictate the entire building system.

## Proposed asset kit

Keep the first batch small:

- **Two house variants:** the same material family, different roof/profile proportions.
- **One clan hall:** a distinct larger silhouette that anchors Aldford.
- **One modular landing:** reusable deck and support pieces, assembled to fit the bank.
- **One production landmark:** a charcoal-burning site or bloomery with an identifiable working area.
- **A few grounding props:** logs, sacks, a fence section, and rocks. Reuse these across settlements.

Use a shared palette and a small set of wood, thatch, earth, and stone materials. Texture details should support forms rather than fight them. Model the roof ridge, overhang, and main supports; avoid individual thatch stalks or elaborate interiors. A clean low-detail mesh with good proportions is sufficient for the first pass.

## Division of work

**Blender:** model silhouettes, establish dimensions and ground pivots, prepare UVs/material slots, and create deliberate variations. Keep editable source files. Export a small trial asset to Godot before completing the kit so scale and orientation are verified early.

**Godot:** assign or tune runtime materials, place buildings against actual terrain height, arrange clusters around paths, set lighting, and evaluate selection/labels at both camera distances. Keep simulation IDs and economic state outside the decorative mesh hierarchy.

Continue using the existing Blender height/biome export when editing terrain. Do not turn the entire five-settlement valley into one large exported mesh: reusable pieces and independently placed scenery will accommodate later construction and generated worlds more easily.

## Small first deliverable

Replace only Aldford's hall, two houses, and landing. Keep the surrounding world unchanged for comparison. Check one close view and the normal valley overview, using the same Godot lighting for both old and new assets.

**Accept when:** the hall and landing are recognizable without labels, buildings sit convincingly on the land, their materials feel consistent, and the kit can form a visibly different second settlement without new models.

**Scale guardrail:** design shared meshes/materials and a few controlled variants. Later, distant representations can simplify these assets, while the 100-settlement graph remains useful for simulation testing. Do not build 100 unique towns or detailed interiors now.

## Tradeoff

This direction gives settlements identity, but it will not repair box-segment river joins, flat ground shading, or map framing. My preferred sequence is **Godot landscape/readability pass → Blender landmark kit → evaluate both together in Godot**.

This note proposes work only; no implementation accompanies it.
