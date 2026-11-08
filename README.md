# Frontlines — OpenFront for Roblox

A Roblox (Luau) port of [OpenFront](https://github.com/openfrontio/OpenFrontIO),
the multiplayer territory-conquest strategy game. The simulation is a
bit-exact translation of upstream's game core (verified by golden tests), with
a Roblox client, lobby, matchmaking, profiles and a cosmetic-only shop.

© OpenFront and Contributors. Code: **AGPL-3.0** ([LICENSE](LICENSE)).
Maps, sprites, icons, colours and translations from upstream `resources/`:
**CC BY-SA 4.0**. Details in [NOTICE.md](NOTICE.md).

## Layout

| Path | Contents |
| --- | --- |
| `src/server/Core` | Game simulation (port of `src/core`), executions, nation AI |
| `src/server` | `GameServer` (lobby, tick loop, remotes), matchmaking, profiles, shop |
| `src/client` | Renderer, HUD, menus, tutorial, localisation |
| `src/shared` | Code and data used on both sides (maps catalogue, net, maths) |
| `src/maps` | Packed maps (generated) |
| `tests` | Golden vectors generated from upstream + Luau specs |
| `tools` | Build and packing scripts |
| `art` | Store icon, thumbnails and description |

## Build

Requirements: Node.js 20+, a checkout of OpenFrontIO next to this repo
(`../OpenFrontIO`, or set `OPENFRONT_DIR`) for regenerating data, Roblox Studio.

```bash
cd tools && npm install && cd ..
node tools/build.mjs
```

`build/OpenFront.rbxlx` is the complete place — open it in Studio and publish.
The separate `build/*.rbxmx` models (Server, Client, Shared, Tests, Maps) can
be imported into an existing place instead.

Regenerating data from upstream (only needed after updating OpenFrontIO):

```bash
node tools/pack-map.mjs --playlist   # maps + lobby catalogue
node tools/pack-colors.mjs           # theme colours
node tools/pack-icons.mjs            # HUD icons
node tools/pack-sprites.mjs          # unit sprites
node tools/pack-quickchat.mjs        # quick chat
node tools/pack-lang.mjs             # UI translations (+ tools/lang/*.json)
node tools/make-art.mjs              # store art (uses GameInfo.TITLE)
```

## Tests

Golden vectors are produced by running upstream's real simulation
(`tools/golden-*.mts`, run with `npx tsx` from the OpenFrontIO checkout) and
replayed in Studio:

```lua
local SimSpec = require(game.ServerStorage.Tests.SimSpec)
SimSpec.reset("NationVectorsHard")
print(SimSpec.run(3000))
```

## Configuration before publishing

- `src/shared/GameInfo.luau` — title and the source-code URL shown in game (github.com/a01635117-pixel/frontlines-roblox).
- `src/shared/Data/Shop.luau` — developer product and game pass IDs.
- Game settings: Max players, Studio API access (DataStore), private servers.
