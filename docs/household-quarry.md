# Household economy: Quarry and stone

## What exists

- **Stone** (`Commodity.Type.STONE`, appended to the enum so saved ints stay valid): base price 4.0, icon `assets/icons/goods/stone.svg`.
- **Quarry** (`type_key "quarry"`, `HEScenarioSeeds.make_quarry`): opt-in business, same shape as the Iron Mine. Both are built by `HEScenarioSeeds.make_extractor` (no inputs, one raw good per worker-day, no depletion yet), so a future depletion rule hooks in once for both.
- **Rate:** the Quarry digs 2.0 stone per worker-day, the mine 1.0 ore. Stone has no household buyer, so everything it earns comes through the Trader's discounted export bid. At 1.0 the crew went insolvent whenever the reference wage spiked past ~2; at 2.0 it stayed solvent through a 3.3 wage (`check_quarry.gd`).
- **Trader export:** stone is in `EXPORT_COMMODITIES`, so the export checkbox starts on and the Quarry always has a buyer for its surplus. (Iron ore stays off because the Bloomery is its buyer.)
- **Tenement cost:** 100 stone (new) / 75 stone (upgrade) on top of the timber and gold. A town with no Quarry gets stone through the Trader's imports, so a tenement is never blocked outright.
- **3D model:** KayKit Medieval Hexagon `building_mine_blue.gltf`, shared by the Quarry and the Iron Mine in the town view.
- **Presets:** Mining village (4 quarry workers) and Large village (6) include a Quarry; Custom adds it as a roster option (6). Presets' warehouses start with some stone.

## Coming consumers (not built)

- **Houses in stone:** a masonry house tier (fireproof, higher capacity or lower upkeep).
- **Government buildings:** Warehouse, a town wall, a well/market square, roads and bridges (paving) as stone-priced builds.
- **Bloomery / smelting:** flux (limestone) as a small second input to iron, tying stone to the iron chain.
- **Toolsmith:** whetstones, or stone-headed tools as a cheaper low-tier tool.
- **Defense:** walls and towers once there is a threat model (ties to the overland-map tactical layer).
- **Export value:** a dressed-stone product (Mason business) that exports at a better margin than raw stone.
- **Depletion:** a finite deposit per extractor, shared with the Iron Mine.
