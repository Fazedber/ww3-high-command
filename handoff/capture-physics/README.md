# Capture physics ("how territory gets conquered") - hand-off for another Claude

Project: Roblox/Luau port of OpenFront (territory-conquest RTS), working title "WW3: High Command".
License: AGPL-3.0 (derivative of OpenFront), (c) OpenFront and Contributors. Whoever receives these
files gets them under AGPL-3.0; keep the notice and publish your modified source if you ship it.

This folder holds the files that decide **how land changes hands**. Everything is server-authoritative
Luau in `src/server/Core`; the client only draws.

## Files
| File | Role |
| --- | --- |
| `AttackExecution.luau` | One running attack. Priority queue of enemy/unowned border tiles; each tick it conquers tiles until the tick "budget" is spent, charging troops per tile. |
| `AttackImpl.luau` | Data object for an attack (troops, border set, target, retreat flags). |
| `Config.luau` | Tunables. `attackLogic()` = per-tile troop loss / defender loss / tick cost; `attackAmount()`, `startManpower()`, `maxTroops()`, `structureMinDist()`, spawn-phase length. |
| `PlayerImpl.luau` | `conquer(tile)`, border bookkeeping, `canAttack`, `validStructureSpawnTiles` (structure spacing), troops/gold. |
| `GameRunner.luau` | Turns wire intents (`attack`, `spawn`, ...) into executions. |

## How an attack works (upstream behaviour, unchanged unless noted)
1. Client click -> intent `click`/`attack_at` (tile, ratio) -> `GameServer` checks `me:canAttack(tile)` and queues
   `{type="attack", targetID, ratio, focusTile}`; troops = remaining_troops * ratio (computed when the tick applies it).
2. `AttackExecution.new(startTroops, owner, targetID, sourceTile, removeTroops, focusTile)`. `init()` deducts troops,
   creates the `AttackImpl`, merges with other attacks on the same target, cancels against opposing attacks.
3. `_refreshToConquer()` enqueues every neighbour of the owner's border tiles that belongs to the target
   (`_addNeighbors`). Priority (lower = conquered earlier):
   `(rand(0..7)+10) * (1 - numNeighboursOwnedByMe*0.5 + terrainMagnitude/2) + currentTick`
   (more own neighbours -> earlier; mountains later; the `+tick` term makes the queue roughly FIFO).
4. `tick()`: `tickBudget = 1`; while budget > 0: dequeue a tile, verify it is still the target's, land, and borders
   us; add its neighbours; call `Config:attackLogic(input)` -> `attackerTroopLoss, defenderTroopLoss, tickFraction`;
   `tickBudget -= tickFraction`; subtract losses; `owner:conquer(tile)`. Stops when troops < 1 (attack dies) or the
   queue empties (attack ends, remaining troops return).
5. `attackLogic`: terrain magnitude/cost base, defense posts (bonus), fallout, large-territory bonuses, troop ratio
   (defender troops / attack troops clamps 0.6..2 for loss, 0.82..7.5 for speed), traitor debuffs, bots as defenders.
   Unowned land (terra nullius) is cheap and fast.

## Changes made in this fork (search for them)
* **Directed attack** - `focusTile`: `AttackExecution._addNeighbors` adds `0.6 * distance(tile, focusTile)` to the
  priority, so border tiles near the click are conquered first (soft bias; far tiles lag, not blocked). Only set for
  human `click`/`attack_at` intents (`GameServer.server.luau`, `GameRunner.luau` passes `intent.focusTile`); AI attacks
  and boats leave it `nil` = exact upstream behaviour. Tune the 0.6 constant.
* **Structure spacing** - `PlayerImpl:validStructureSpawnTiles`: humans 6 tiles between structures, others keep
  `Config:structureMinDist()` (15). The server snaps a build to the nearest valid own tile within radius 15.
* **Fair start** - `Config:startManpower` = 25000 for everyone (upstream nations differ). This (and other fork
  changes) is why the golden tests in `tests/` already mismatch from tick ~100 (`SimSpec`, `NationVectorsHard`).
* Spawn phase lengthened (`Config:numSpawnPhaseTurns`).

## Ideas the owner wants explored
* Make the directed attack feel stronger or switch to a "wedge" (conquer a cone from the click), keeping AI untouched.
* Keep determinism: no `math.random`; use the execution's `PseudoRandom`.
* Any change to shared simulation code must stay identical on every server; the client never simulates captures.

## How to test in Studio
```lua
local SimSpec = require(game.ServerStorage.Tests.SimSpec)
SimSpec.reset("NationVectorsHard"); print(SimSpec.run(600))   -- fork already diverges from upstream goldens
```
Practical test: Play -> Solo Campaign -> pick spawn -> click a neighbour; watch which part of the border advances.
`node tools/build.mjs` regenerates `build/OpenFront.rbxlx` from `src/`.

## Prompt you can paste to the other Claude
> You are working on the files in this folder (Luau, Roblox). Goal: <describe the change to conquest/attack physics>.
> Read README.md first. Keep AI behaviour deterministic and unchanged unless asked. Explain the formula you change,
> give before/after numbers, and list every edited function so it can be merged back into `src/server/Core`.
