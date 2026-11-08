// Golden "nations" scenario from the ORIGINAL OpenFrontIO TS.
//
// Usage (from the OpenFrontIO checkout):
//   cd ../OpenFrontIO && [GOLD=n] [TICKS=n] [SUFFIX=s] [FACTORY=1] [HASH_FROM=a HASH_TO=b] npx tsx ../OpenFrontRoblox/tools/golden-nations.mts [Difficulty]
//
// Two scripted humans plus 20 bots and all World nations (Compact map), run
// through createNationsForGame + NationExecution exactly like
// createGameRunner. Nations get plenty of starting gold so they build, nuke,
// launch warships and MIRVs. Writes tests/NationVectors<Difficulty>.luau.

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
const { createNationsForGame } = await imp("src/core/game/NationCreation.ts");

const DIFFICULTY = process.argv[2] ?? "Impossible";
// TEAMS=4 / Duos / "Humans Vs Nations": a team game instead of FFA.
const TEAMS: number | string | undefined = process.env.TEAMS === undefined ? undefined : /^[0-9]+$/.test(process.env.TEAMS) ? Number(process.env.TEAMS) : process.env.TEAMS;
const SCENARIO = {
  gameID: "golden06",
  bots: 20,
  ticks: Number(process.env.TICKS ?? 3000),
  snapshotEvery: 100,
  // Units not ported yet (they would diverge by construction, not by bug).
  disabledUnits: process.env.FACTORY ? [] : ["Factory"],
  startingGold: Number(process.env.GOLD ?? 5_000_000),
};

const gameConfig = {
  gameMap: "World",
  difficulty: DIFFICULTY,
  donateGold: false,
  donateTroops: false,
  gameType: "Private",
  gameMode: TEAMS === undefined ? "Free For All" : "Team",
  ...(TEAMS === undefined ? {} : { playerTeams: TEAMS }),
  gameMapSize: "Compact",
  bots: SCENARIO.bots,
  randomSpawn: false,
  infiniteGold: false,
  infiniteTroops: false,
  instantBuild: false,
  disabledUnits: SCENARIO.disabledUnits,
  nations: "default",
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

// Compact map: nation coordinates halved, like loadGameMap.
const half = (n: any) => ({ ...n, coordinates: n.coordinates === undefined ? undefined : [Math.floor(n.coordinates[0] / 2), Math.floor(n.coordinates[1] / 2)] });
const manifestNations = manifest.nations.map(half);
const additionalNations = (manifest.additionalNations ?? []).map(half);
const nations = createNationsForGame({ gameID: SCENARIO.gameID, config: gameConfig, players: [] } as any, manifestNations, additionalNations, humans.length, random);

const config = new Config(gameConfig, null, false);
const game = createGame(humans, nations, gameMap, miniMap, config, undefined);
const executor = new Executor(game, SCENARIO.gameID, undefined, []);
game.addExecution(new SpawnTimerExecution());
game.addExecution(...executor.nationExecutions());
game.addExecution(...executor.spawnTribes(SCENARIO.bots));
game.addExecution(new WinCheckExecution());
if (!config.isUnitDisabled("Factory")) {
  const { RecomputeRailClusterExecution } = await imp("src/core/execution/RecomputeRailClusterExecution.ts");
  game.addExecution(new RecomputeRailClusterExecution(game.railNetwork()));
}

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

// Intents to issue at a tick.
function intentsFor(tick: number): Intent[] {
  const out: Intent[] = [];
  const A = byClient("human1");
  const B = byClient("human2");
  if (tick === 0) {
    out.push({ type: "spawn", clientID: "human1", tile: tileA });
    out.push({ type: "spawn", clientID: "human2", tile: tileB });
  }
  if (tick === 202 || tick === 260 || tick === 330 || tick === 600) {
    out.push({ type: "attack", clientID: "human1", targetID: null, troops: A.troops() * 0.3 });
    out.push({ type: "attack", clientID: "human2", targetID: null, troops: B.troops() * 0.3 });
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
// Optional per-tick game hash + unit counter (HASH_FROM..HASH_TO) to pin the first diverging tick.
const hashFrom = Number(process.env.HASH_FROM ?? -1);
const hashTo = Number(process.env.HASH_TO ?? -1);
const tickHashes: string[] = [];
const seenUnits = new Set<number>();
const unitLog = new Map<string, number>();
const t0 = performance.now();
for (let tick = 0; tick <= SCENARIO.ticks; tick++) {
  if (tick % SCENARIO.snapshotEvery === 0 || tick === 201) snaps.push(snapshot(tick));
  if (tick === SCENARIO.ticks) break;
  for (const intent of intentsFor(tick)) {
    recorded.push({ tick, intent });
    game.addExecution(executor.createExec(intent));
  }
  game.executeNextTick();
  if (tick + 1 >= hashFrom && tick + 1 <= hashTo) tickHashes.push(`[${tick + 1}] = { ${game.hash()}, ${(game as any)._nextUnitID} }`);
  for (const u of game.units()) if (!seenUnits.has(u.id())) { seenUnits.add(u.id()); unitLog.set(u.type(), (unitLog.get(u.type()) ?? 0) + 1); }
}
const ms = performance.now() - t0;

const A = byClient("human1");
const B = byClient("human2");
const units = game.units().map((u: any) => `${u.id()}:${u.type()}:${u.owner().name()}:${u.tile()}:${u.level()}`);
const tradeGold = [Number(A.tradeGold()), Number(B.tradeGold())];
const nationCount = nations.length;

const luaVal = (v: unknown): string =>
  v === null || v === undefined ? "nil" : typeof v === "string" ? JSON.stringify(v) : typeof v === "boolean" ? String(v) : String(v);
const luaList = (v: unknown): string => (Array.isArray(v) ? `{ ${v.map((x) => luaVal(x)).join(", ")} }` : luaVal(v));
const intentLua = (i: Intent) =>
  `{ ${Object.entries(i)
    .filter(([, v]) => v !== null && v !== undefined)
    .map(([k, v]) => `${k} = ${luaList(v)}`)
    .join(", ")} }`;

const lua = `-- AUTO-GENERATED by tools/golden-nations.mts from upstream OpenFrontIO. Do not edit.
-- Upstream ran ${SCENARIO.ticks} ticks in ${ms.toFixed(0)} ms.
return {
\tgameID = ${JSON.stringify(SCENARIO.gameID)},
\tmap = "World",
\tbots = ${SCENARIO.bots},
\tticks = ${SCENARIO.ticks},
\tnations = ${nationCount},\n\tunitsCreated = ${(game as any)._nextUnitID - 1},
\tunitsAlive = ${JSON.stringify(units.join(";"))},
\ttradeGold = { ${tradeGold.join(", ")} },
\tplayers = {
${humansDef.map((h) => `\t\t{ username = ${JSON.stringify(h.username)}, clientID = ${JSON.stringify(h.clientID)} },`).join("\n")}
\t},
\tconfig = {
\t\tgameMap = "World", difficulty = "${DIFFICULTY}", donateGold = false, donateTroops = false,
\t\tgameType = "Private", gameMode = "${TEAMS === undefined ? "Free For All" : "Team"}", gameMapSize = "Compact",${TEAMS === undefined ? "" : ` playerTeams = ${JSON.stringify(TEAMS)},`}
\t\tbots = ${SCENARIO.bots}, randomSpawn = false, infiniteGold = false, infiniteTroops = false,
\t\tinstantBuild = false, nations = "default", startingGold = ${SCENARIO.startingGold},
\t\tdisabledUnits = { ${SCENARIO.disabledUnits.map((u) => JSON.stringify(u)).join(", ")} },
\t},
\tintents = {
${recorded.map((r) => `\t\t{ tick = ${r.tick}, intent = ${intentLua(r.intent)} },`).join("\n")}
\t},
\ttickHashes = { ${tickHashes.join(", ")} },
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
fs.writeFileSync(path.resolve(here, `../tests/NationVectors${DIFFICULTY}${process.env.SUFFIX ?? ""}.luau`), lua);
console.log(`upstream: ${SCENARIO.ticks} ticks in ${ms.toFixed(0)} ms; ${recorded.length} intents; units created ${(game as any)._nextUnitID - 1}`);
console.log(`alive units: ${units.join(" | ")}`);
console.log(`units by type: ${[...unitLog].map(([k, v]) => k + '=' + v).join(', ')}`);
console.log(`nations=${nationCount} alive players=${game.players().length}`);
console.log(`piracy gold A=${Number(A.piracyGold?.() ?? 0)}`);
console.log(`trade gold A=${tradeGold[0]} B=${tradeGold[1]}; A tiles=${A.numTilesOwned()} B tiles=${B.numTilesOwned()}`);
