# Publishing checklist (Roblox)

## Before the first publish
1. **Name** - working title is now "WW3: High Command" (change it if you prefer another), then set `GameInfo.TITLE` (src/shared/GameInfo.luau),
   the `HIGH COMMAND` text in `src/client/HighCommand.luau`, `node tools/make-art.mjs`.
   Must not be "OpenFront" (AGPL 7(c)). Avoid "RoFront", "RoWorld", "Territory Royale".
2. **Source link (AGPL section 13)** - create a PUBLIC repository with this project and set
   `GameInfo.SOURCE_URL` to it. The notice "(c) OpenFront and Contributors" + license are
   already shown in the main menu footer and Credits.
3. **Monetisation** - shop shows "Soon" while every productId/passId in
   `src/shared/Data/Shop.luau` is 0. Create passes/products in the Creator Dashboard and paste ids.
   Do NOT create the Rebirth product (pay-to-win, contradicts "no pay-to-win").
4. **Art** - new violet set: `art/icon-new.png` (512x512) and `art/thumbnail-new-menu.jpg` / `art/thumbnail-new-map.jpg` (1315x793 Studio screenshots; better to retake at 1920x1080). The old `icon.png` and `thumbnail-1/2` are orange and "Frontlines".

## Publish (Studio)
1. Open `build/OpenFront.rbxlx` (or the already open place) in Studio.
2. File -> Publish to Roblox As... -> new experience, name, description (`art/DESCRIPTION.md`).
3. Game Settings:
   - Security -> **Enable Studio Access to API Services** (DataStores/MemoryStores in Studio).
   - Security -> **Allow Mesh / Image APIs** MUST be ON. The whole client renders with EditableImage; with it off, a published
     server fails with "EditableImage is not accessible" in LobbyScreen and the client hangs on "Waiting for the match to start"
     (works in Studio regardless). Set via Studio: File > Experience Settings > Security (needs the cloud place open, not the local file).
   - Basic Info: genre Strategy, devices (PC, phone, tablet, console optional), Maturity questionnaire.
   - Permissions: keep Private until tested, then Public.
   - Max players: matchmaking uses the place's Max Players.
4. Test in the published game (Studio cannot test Find Match / private codes / teleports):
   Quick Match, Create private + join by code from a second account, Duel, leaving mid-match,
   rejoin, shop (after ids), data persistence (play, leave, rejoin: wins counter).
5. Set to Public.

## Updating later
Edit `src/`, `node tools/build.mjs`, open the place, File -> Publish to Roblox (same experience).
## New in this build
- Daily login reward with streak (cosmetic trial, 72 h on day 7), card under the player name in the menu.
- Hand-off for a friend's Claude: handoff/capture-physics.zip (capture/attack physics + README).

## Shop setup (after publishing)
1. Creator Hub -> Credentials: create an API key for this experience with scopes **developer-product:write** and **game-pass:write**.
2. Preview: `node tools/setup-shop.mjs --dry` (28 entries: 4 passes + 24 products).
3. Create: `node tools/setup-shop.mjs --universe <UNIVERSE_ID> --key <API_KEY>` - writes all ids into `src/shared/Data/Shop.luau` (re-run safe). Rebirth and ads are skipped unless `--with-rebirth` / `--with-ads`.
4. `node tools/build.mjs`, open the place, Publish again. Subscription (monthly) must be created in the Dashboard; put its id in `Shop.SUBSCRIPTION_ID`.

## What to check in the live game (cannot be tested in Studio)
- Start the game: MAIN shows 'PUBLIC MATCH - starts in N s'. Waiting -> public match starts.
- SOLO CAMPAIGN -> pick map -> START: you are teleported to your own server and the match starts automatically with your settings.
- ONLINE -> CREATE PRIVATE SERVER: you land on ONLINE with a JOIN CODE; a friend enters it -> host presses START MATCH.
- 1 vs 1 DUEL -> CREATE: you land on DUEL with the code -> friend joins -> START DUEL.
- Leave and rejoin: wins counter and daily reward streak are kept.
