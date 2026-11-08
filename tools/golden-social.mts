// Golden "diplomacy" scenario from the ORIGINAL OpenFrontIO TS.
//
// Usage (from the OpenFrontIO checkout):
//   cd ../OpenFrontIO && npx tsx ../OpenFrontRoblox/tools/golden-social.mts
//
// Two scripted humans plus 40 bots, with ports and trade. Alice allies with
// a neighbouring tribe, Alice and Bob ally (request + accept), donate gold
// and troops, send emojis, target players, embargo each other, extend and
// finally break alliances (traitor). Writes tests/SocialVectors.luau.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = process.env.OPENFRONT_DIR ?? path.resolve(here, "../../OpenFrontIO");
const imp = (p: string) => import(pathToFileURL(path.join(upstream, p)).href);

const { Config } = await imp("src/core/configuration/Config.ts");
const { createGame } = await imp("src/core/game/GameImpl.ts");
const { genTerrainFromBin } = await imp("src/core/game/TerrainMapLoader.ts");
const { Executor } = await imp("src/core/execution/ExecutionManager.ts");
const { SpawnTimerExecution } = await imp("src/core/execution/SpawnTimerExecution.ts");
const { WinCheckExecution } = await imp("src/core/execution/WinCheckExecution.ts");
const { PlayerInfo, PlayerType } = await imp("src/core/game/Game.ts");
const { PseudoRandom } = await imp("src/core/PseudoRandom.ts");
const { simpleHash } = await imp("src/core/Util.ts");

const SCENARIO = {
  gameID: "golden05",
  bots: 40,
  ticks: 1600,
  snapshotEvery: 100,
  // Units not ported yet (they would diverge by construction, not by bug).
  disabledUnits: ["Factory", "SAM Launcher", "Atom Bomb", "Hydrogen Bomb", "MIRV", "Warship"],
  startingGold: 20_000_000,
};

const gameConfig = {
  gameMap: "World",
  difficulty: "Medium",
  donateGold: true,
  donateTroops: true,
  gameType: "Private",
  gameMode: "Free For All",
  gameMapSize: "Compact",
  bots: SCENARIO.bots,
  randomSpawn: false,
  infiniteGold: false,
  infiniteTroops: false,
  instantBuild: false,
  disabledUnits: SCENARIO.disabledUnits,
  nations: "disabled",
  startingGold: SCENARIO.startingGold,
};

const mapDir = path.join(upstream, "resources/maps/world");
const manifest = JSON.parse(fs.readFileSync(path.join(mapDir, "manifest.json"), "utf8"));
const gameMap = await genTerrainFromBin(manifest.map4x, new Uint8Array(fs.readFileSync(path.join(mapDir, "map4x.bin"))));
const miniMap = await genTerrainFromBin(manifest.map16x, new Uint8Array(fs.readFileSync(path.join(mapDir, "map16x.bin"))));

// Humans, created exactly like createGameRunner does.
const humansDef = [
  { username: "Alice", clientID: "human1" },
  { username: "Bob", clientID: "human2" },
];
const random = new PseudoRandom(simpleHash(SCENARIO.gameID));
const humans = humansDef.map((h) => new PlayerInfo(h.username, PlayerType.Human, h.clientID, random.nextID(), false, null, [], null));

const config = new Config(gameConfig, null, false);
const game = createGame(humans, [], gameMap, miniMap, config, undefined);
const executor = new Executor(game, SCENARIO.gameID, undefined, []);
game.addExecution(new SpawnTimerExecution());
game.addExecution(...executor.spawnTribes(SCENARIO.bots));
game.addExecution(new WinCheckExecution());

// Nearest shore land tile to (x, y) by ring search.
function nearestShore(x0: number, y0: number): number {
  for (let r = 0; r < 200; r++) {
    for (let dy = -r; dy <= r; dy++) {
      for (let dx = -r; dx <= r; dx++) {
        if (Math.max(Math.abs(dx), Math.abs(dy)) !== r) continue;
        const x = x0 + dx;
        const y = y0 + dy;
        if (!gameMap.isValidCoord(x, y)) continue;
        const t = gameMap.ref(x, y);
        if (gameMap.isLand(t) && gameMap.isShore(t) && !gameMap.isImpassable(t)) return t;
      }
    }
  }
  throw new Error("no shore");
}
const tileA = nearestShore(505, 110);
const tileB = nearestShore(285, 140);

type Intent = Record<string, unknown> & { type: string; clientID: string };
const recorded: { tick: number; intent: Intent }[] = [];
const byClient = (id: string) => game.playerByClientID(id);

// First owned tile (territory order) at least `d` tiles (euclidean) from
// `from`; structures must keep 15 tiles apart, so each build targets a
// different part of the territory. Recorded as a fixed tile in the intent.
function farTile(player: any, from: number, d: number): number | null {
  const d2 = d * d;
  for (const t of player.tiles()) {
    if (game.euclideanDistSquared(t, from) >= d2) return t;
  }
  return null;
}

// First living tribe sharing a border with `p` (players() order).
function borderingBot(p: any): any {
  for (const o of game.players()) {
    if (o.type() === "BOT" && o.isAlive() && p.sharesBorderWith(o)) return o;
  }
  return null;
}

// Intents to issue at a tick (some depend on live state: players, units).
function intentsFor(tick: number): Intent[] {
  const out: Intent[] = [];
  const A = byClient("human1");
  const B = byClient("human2");
  if (tick === 0) {
    out.push({ type: "spawn", clientID: "human1", tile: tileA });
    out.push({ type: "spawn", clientID: "human2", tile: tileB });
  }
  if (tick === 202 || tick === 260 || tick === 330) {
    out.push({ type: "attack", clientID: "human1", targetID: null, troops: A.troops() * 0.3 });
    out.push({ type: "attack", clientID: "human2", targetID: null, troops: B.troops() * 0.3 });
  }
  if (tick === 205) {
    out.push({ type: "build_unit", clientID: "human1", unit: "Port", tile: tileA });
    out.push({ type: "build_unit", clientID: "human2", unit: "Port", tile: tileB });
  }
  if (tick === 350) {
    const bot = borderingBot(A);
    if (bot) out.push({ type: "allianceRequest", clientID: "human1", recipient: bot.id() });
    out.push({ type: "allianceRequest", clientID: "human1", recipient: B.id() });
  }
  if (tick === 380) {
    // Bob accepts by requesting back.
    out.push({ type: "allianceRequest", clientID: "human2", recipient: A.id() });
  }
  if (tick === 420) {
    out.push({ type: "donate_gold", clientID: "human2", recipient: A.id(), gold: 2_000_000 });
    out.push({ type: "donate_troops", clientID: "human1", recipient: B.id(), troops: 3000 });
    out.push({ type: "emoji", clientID: "human1", recipient: B.id(), emoji: 7 });
    out.push({ type: "emoji", clientID: "human2", recipient: "AllPlayers", emoji: 20 });
  }
  if (tick === 500) {
    const bot = borderingBot(B);
    if (bot) out.push({ type: "targetPlayer", clientID: "human2", target: bot.id() });
    out.push({ type: "embargo", clientID: "human1", targetID: B.id(), action: "start" });
  }
  if (tick === 700) {
    out.push({ type: "embargo", clientID: "human1", targetID: B.id(), action: "stop" });
    out.push({ type: "allianceExtension", clientID: "human1", recipient: B.id() });
  }
  if (tick === 720) {
    out.push({ type: "allianceExtension", clientID: "human2", recipient: A.id() });
  }
  if (tick === 900) {
    const ally = A.alliances().map((al: any) => al.other(A)).find((p: any) => p.type() === "BOT");
    if (ally) out.push({ type: "breakAlliance", clientID: "human1", recipient: ally.id() });
  }
  if (tick === 910 || tick === 960) {
    const bot = borderingBot(A);
    if (bot) out.push({ type: "attack", clientID: "human1", targetID: bot.id(), troops: A.troops() * 0.4 });
  }
  if (tick === 1200) {
    out.push({ type: "breakAlliance", clientID: "human2", recipient: A.id() });
  }
  return out;
}

type Snapshot = { tick: number; stateSha: string; hash: number; alive: number; totalOwned: number; players: any[] };
function snapshot(tick: number): Snapshot {
  const state: Uint16Array = game.map().tileStateBuffer();
  const stateSha = crypto.createHash("sha256").update(Buffer.from(state.buffer, state.byteOffset, state.byteLength)).digest("hex");
  const all = game.allPlayers();
  let totalOwned = 0;
  for (const p of all) totalOwned += p.numTilesOwned();
  return {
    tick,
    stateSha,
    hash: game.hash(),
    alive: game.players().length,
    totalOwned,
    players: all.map((p: any) => ({ name: p.name(), id: p.id(), tiles: p.numTilesOwned(), troops: p.troops(), gold: Number(p.gold()) })),
  };
}

const snaps: Snapshot[] = [];
const t0 = performance.now();
for (let tick = 0; tick <= SCENARIO.ticks; tick++) {
  if (tick % SCENARIO.snapshotEvery === 0 || tick === 201) snaps.push(snapshot(tick));
  if (tick === SCENARIO.ticks) break;
  for (const intent of intentsFor(tick)) {
    recorded.push({ tick, intent });
    game.addExecution(executor.createExec(intent));
  }
  game.executeNextTick();
}
const ms = performance.now() - t0;

const A = byClient("human1");
const B = byClient("human2");
const units = game.units().map((u: any) => `${u.id()}:${u.type()}:${u.owner().name()}:${u.tile()}:${u.level()}`);
const tradeGold = [Number(A.tradeGold()), Number(B.tradeGold())];

const luaVal = (v: unknown): string =>
  v === null || v === undefined ? "nil" : typeof v === "string" ? JSON.stringify(v) : typeof v === "boolean" ? String(v) : String(v);
const intentLua = (i: Intent) =>
  `{ ${Object.entries(i)
    .filter(([, v]) => v !== null && v !== undefined)
    .map(([k, v]) => `${k} = ${luaVal(v)}`)
    .join(", ")} }`;

const lua = `-- AUTO-GENERATED by tools/golden-social.mts from upstream OpenFrontIO. Do not edit.
-- Upstream ran ${SCENARIO.ticks} ticks in ${ms.toFixed(0)} ms.
return {
\tgameID = ${JSON.stringify(SCENARIO.gameID)},
\tmap = "World",
\tbots = ${SCENARIO.bots},
\tticks = ${SCENARIO.ticks},
\tunitsCreated = ${(game as any)._nextUnitID - 1},
\tunitsAlive = ${JSON.stringify(units.join(";"))},
\ttradeGold = { ${tradeGold.join(", ")} },
\tplayers = {
${humansDef.map((h) => `\t\t{ username = ${JSON.stringify(h.username)}, clientID = ${JSON.stringify(h.clientID)} },`).join("\n")}
\t},
\tconfig = {
\t\tgameMap = "World", difficulty = "Medium", donateGold = true, donateTroops = true,
\t\tgameType = "Private", gameMode = "Free For All", gameMapSize = "Compact",
\t\tbots = ${SCENARIO.bots}, randomSpawn = false, infiniteGold = false, infiniteTroops = false,
\t\tinstantBuild = false, nations = "disabled", startingGold = ${SCENARIO.startingGold},
\t\tdisabledUnits = { ${SCENARIO.disabledUnits.map((u) => JSON.stringify(u)).join(", ")} },
\t},
\tintents = {
${recorded.map((r) => `\t\t{ tick = ${r.tick}, intent = ${intentLua(r.intent)} },`).join("\n")}
\t},
\tsnapshots = {
${snaps
  .map(
    (s) =>
      `\t\t{ tick = ${s.tick}, stateSha = ${JSON.stringify(s.stateSha)}, hash = ${s.hash}, alive = ${s.alive}, totalOwned = ${s.totalOwned}, players = {\n${s.players
        .map((p) => `\t\t\t{ name = ${JSON.stringify(p.name)}, id = ${JSON.stringify(p.id)}, tiles = ${p.tiles}, troops = ${p.troops}, gold = ${p.gold} },`)
        .join("\n")}\n\t\t} },`,
  )
  .join("\n")}
\t},
}
`;
fs.writeFileSync(path.resolve(here, "../tests/SocialVectors.luau"), lua);
console.log(`upstream: ${SCENARIO.ticks} ticks in ${ms.toFixed(0)} ms; ${recorded.length} intents; units created ${(game as any)._nextUnitID - 1}`);
console.log(`alive units: ${units.join(" | ")}`);
console.log(`A alliances=${A.alliances().length} traitor=${A.isTraitor()} B alliances=${B.alliances().length} relation B->A=${B.relation(A)}`);
console.log(`trade gold A=${tradeGold[0]} B=${tradeGold[1]}; A tiles=${A.numTilesOwned()} B tiles=${B.numTilesOwned()}`);
