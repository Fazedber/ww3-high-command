// Records a real OpenFront match (the ORIGINAL OpenFrontIO simulation, the
// same rules the Roblox port reproduces bit-exactly) into a vertical
// 1080x1920 video for social media: territories, borders, names, nuke blasts.
//
// Usage (from the OpenFrontIO checkout, ffmpeg on PATH):
//   cd ../OpenFrontIO && npx tsx ../OpenFrontRoblox/tools/record-sim.mts <out.mp4> [ticks] [every] [crop]
//   crop = "x,y,w,h" in map tiles (default Europe/Africa/Middle East)
//
// Nations + bots on the World map with plenty of starting gold, so the
// late game has nukes. Frames are piped raw into ffmpeg.

import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = process.env.OPENFRONT_DIR ?? path.resolve(here, "../../OpenFrontIO");
const imp = (p: string) => import(pathToFileURL(path.join(upstream, p)).href);
const toolsReq = createRequire(path.join(here, "package.json"));
const { Resvg } = toolsReq("@resvg/resvg-js");
const upReq = createRequire(path.join(upstream, "package.json"));
const { colord, extend } = upReq("colord");
extend([upReq("colord/plugins/lab")]);

const { Config } = await imp("src/core/configuration/Config.ts");
const { createGame } = await imp("src/core/game/GameImpl.ts");
const { genTerrainFromBin } = await imp("src/core/game/TerrainMapLoader.ts");
const { Executor } = await imp("src/core/execution/ExecutionManager.ts");
const { SpawnTimerExecution } = await imp("src/core/execution/SpawnTimerExecution.ts");
const { WinCheckExecution } = await imp("src/core/execution/WinCheckExecution.ts");
const { PlayerType, UnitType } = await imp("src/core/game/Game.ts");
const { PseudoRandom } = await imp("src/core/PseudoRandom.ts");
const { simpleHash } = await imp("src/core/Util.ts");
const { createNationsForGame } = await imp("src/core/game/NationCreation.ts");

const OUT = process.argv[2] ?? "match.mp4";
const TICKS = Number(process.argv[3] ?? 6000);
const EVERY = Number(process.argv[4] ?? 12);
const [CX, CY, CW, CH] = (process.argv[5] ?? "445,20,270,480").split(",").map(Number);
const W = 1080, H = 1920;
const GAME_ID = process.env.SEED ?? "promo01";
// WINDOWS="from-to:every,..." records only those tick ranges (e.g. slow motion on a nuke barrage).
const WINDOWS = (process.env.WINDOWS ?? "").split(",").filter(Boolean).map((w) => { const [r, e] = w.split(":"); const [a, b] = r.split("-").map(Number); return { a, b, e: Number(e ?? EVERY) }; });
function recordTick(tick: number): boolean {
  if (WINDOWS.length === 0) return tick % EVERY === 0 && tick >= 100;
  return WINDOWS.some((w) => tick >= w.a && tick <= w.b && (tick - w.a) % w.e === 0);
}

const gameConfig = {
  gameMap: "World", difficulty: "Hard", donateGold: false, donateTroops: false, gameType: "Private",
  gameMode: "Free For All", gameMapSize: "Compact", bots: Number(process.env.BOTS ?? 250), randomSpawn: false,
  infiniteGold: false, infiniteTroops: false, instantBuild: false, disabledUnits: [], nations: "default",
  startingGold: Number(process.env.GOLD ?? 3_000_000),
};
const mapDir = path.join(upstream, "resources/maps/world");
const manifest = JSON.parse(fs.readFileSync(path.join(mapDir, "manifest.json"), "utf8"));
const gameMap = await genTerrainFromBin(manifest.map4x, new Uint8Array(fs.readFileSync(path.join(mapDir, "map4x.bin"))));
const miniMap = await genTerrainFromBin(manifest.map16x, new Uint8Array(fs.readFileSync(path.join(mapDir, "map16x.bin"))));
const random = new PseudoRandom(simpleHash(GAME_ID));
const half = (n: any) => ({ ...n, coordinates: n.coordinates === undefined ? undefined : [Math.floor(n.coordinates[0] / 2), Math.floor(n.coordinates[1] / 2)] });
const nations = createNationsForGame({ gameID: GAME_ID, config: gameConfig, players: [] } as any, manifest.nations.map(half), (manifest.additionalNations ?? []).map(half), 0, random);
const config = new Config(gameConfig, null, false);
const game = createGame([], nations, gameMap, miniMap, config, undefined);
const executor = new Executor(game, GAME_ID, undefined, []);
game.addExecution(new SpawnTimerExecution());
game.addExecution(...executor.nationExecutions());
game.addExecution(...executor.spawnTribes(gameConfig.bots));
game.addExecution(new WinCheckExecution());
const { RecomputeRailClusterExecution } = await imp("src/core/execution/RecomputeRailClusterExecution.ts");
game.addExecution(new RecomputeRailClusterExecution(game.railNetwork()));

// Colours: the game's terrain palette and theme colours.
function terrainRGB(tb: number): number[] {
  const ocean = [0x47, 0x85, 0xb5], sand = [204, 203, 158], plains = [190, 220, 138];
  const highland = [200, 183, 138], mountain = [230, 230, 230], peak = [0x3c, 0x3c, 0x3c];
  const land = tb & 0x80, shore = tb & 0x40, mag = tb & 0x1f;
  if (land && mag === 31) return peak;
  if (land && shore) return sand;
  if (land) {
    if (mag < 10) return [plains[0], plains[1] - 2 * mag, plains[2]];
    if (mag < 20) { const m = mag - 10; return highland.map((c) => Math.min(255, c + 2 * m)); }
    const m = mag >> 1;
    return mountain.map((c) => Math.min(255, c + m));
  }
  if (shore) return ocean.map((c) => Math.round(0.7 * c + 76.5));
  const m = Math.min(mag, 10);
  return ocean.map((c) => Math.max(0, c - m));
}
const theme = JSON.parse(fs.readFileSync(path.join(upstream, "src/client/render/gl/default-theme.json"), "utf8"));
const colorCache = new Map<number, { fill: number[]; border: number[] }>();
function colorsOf(p: any) {
  const id = p.smallID();
  let c = colorCache.get(id);
  if (!c) {
    const pool = p.type() === PlayerType.Bot ? theme.classicBotColors : theme.nationColors;
    const hex = pool[simpleHash(p.id()) % pool.length];
    const base = colord(hex);
    const { r, g, b } = base.toRgb();
    const br = base.darken(theme.borderDarken).toRgb();
    c = { fill: [r, g, b], border: [br.r, br.g, br.b] };
    colorCache.set(id, c);
  }
  return c;
}
const ALPHA = 0.588;

// Terrain layer, pre-rendered once for the crop.
const scale = W / CW;
const terrainTile = new Uint8Array(CW * CH * 3);
for (let y = 0; y < CH; y++) for (let x = 0; x < CW; x++) {
  const t = gameMap.ref(CX + x, CY + y);
  const c = terrainRGB((gameMap as any).terrain?.[t] ?? (gameMap as any).terrainData?.[t] ?? 0);
  terrainTile.set(c, (y * CW + x) * 3);
}
// Terrain byte access differs between versions: fall back to the map API.
if (terrainTile.every((v) => v === 0)) {
  for (let y = 0; y < CH; y++) for (let x = 0; x < CW; x++) {
    const t = gameMap.ref(CX + x, CY + y);
    let tb = 0;
    if (gameMap.isLand(t)) {
      tb |= 0x80;
      if (gameMap.isShore(t)) tb |= 0x40;
      tb |= gameMap.isImpassable(t) ? 31 : Math.min(30, gameMap.magnitude(t));
    } else {
      if (gameMap.isShoreline(t)) tb |= 0x40;
      tb |= Math.min(31, gameMap.magnitude(t));
    }
    terrainTile.set(terrainRGB(tb), (y * CW + x) * 3);
  }
}

// ffmpeg: raw RGB frames in, H.264 out (30 fps, TikTok friendly).
const FONT = "C\\:/Windows/Fonts/segoeuib.ttf";
const hookTop = process.env.HOOK ?? "100 nations. 1 world.";
const hookSub = process.env.HOOK2 ?? "Only one survives.";
const cta = process.env.CTA ?? "Play FRONTLINES on Roblox";
const esc = (s: string) => s.replace(/:/g, "\\:").replace(/'/g, "\u2019");
const draw = [
  `drawbox=x=0:y=0:w=iw:h=330:color=black@0.45:t=fill`,
  `drawtext=fontfile='${FONT}':text='${esc(hookTop)}':fontsize=84:fontcolor=white:borderw=6:bordercolor=black:x=(w-text_w)/2:y=110`,
  `drawtext=fontfile='${FONT}':text='${esc(hookSub)}':fontsize=64:fontcolor=0xfde68a:borderw=5:bordercolor=black:x=(w-text_w)/2:y=215`,
  `drawbox=x=0:y=ih-260:w=iw:h=260:color=black@0.45:t=fill`,
  `drawtext=fontfile='${FONT}':text='${esc(cta)}':fontsize=62:fontcolor=white:borderw=5:bordercolor=black:x=(w-text_w)/2:y=h-190`,
].join(",");
const ff = spawn("ffmpeg", ["-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", `${W}x${H}`, "-r", "30", "-i", "-",
  "-vf", draw, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "medium", "-crf", "20", "-movflags", "+faststart", OUT], { stdio: ["pipe", "inherit", "inherit"] });

const frame = Buffer.alloc(W * H * 3);
const blasts: { x: number; y: number; r: number; age: number }[] = [];
const NUKES = new Set([UnitType.AtomBomb, UnitType.HydrogenBomb, UnitType.MIRVWarhead, UnitType.MIRV]);
const BLAST = { [UnitType.AtomBomb]: 30, [UnitType.HydrogenBomb]: 100, [UnitType.MIRVWarhead]: 18 } as Record<string, number>;
let prevNukes = new Map<number, any>();
const blastLog: string[] = [];
const trails = new Map<number, number[][]>();
// Sound cues for tools/add-audio.mjs: { f: output frame, cue: upstream SoundEffect name }.
const events: { f: number; cue: string }[] = [];
const inCrop = (t: number) => { const x = gameMap.x(t), y = gameMap.y(t); return x >= CX && x < CX + CW && y >= CY && y < CY + CH; };
const LAUNCH_CUE: Record<string, string> = { [UnitType.AtomBomb]: "atom-launch", [UnitType.HydrogenBomb]: "hydrogen-launch", [UnitType.MIRV]: "mirv-launch", [UnitType.MIRVWarhead]: "mirv-launch" };
// (A MIRV splits on the tick it is launched, so the recorder only ever sees its warheads.)
let aliveBefore = -1;

function renderFrame() {
  const owner = new Uint16Array(CW * CH);
  for (let y = 0; y < CH; y++) for (let x = 0; x < CW; x++) owner[y * CW + x] = game.ownerID(gameMap.ref(CX + x, CY + y));
  const colorBySmall = new Map<number, any>();
  for (const p of game.allPlayers()) colorBySmall.set(p.smallID(), colorsOf(p));
  const tileColor = new Uint8Array(CW * CH * 3);
  for (let y = 0; y < CH; y++) for (let x = 0; x < CW; x++) {
    const i = y * CW + x, o = owner[i];
    let r = terrainTile[i * 3], g = terrainTile[i * 3 + 1], b = terrainTile[i * 3 + 2];
    if (o) {
      const c = colorBySmall.get(o);
      const edge = (x > 0 && owner[i - 1] !== o) || (x < CW - 1 && owner[i + 1] !== o) || (y > 0 && owner[i - CW] !== o) || (y < CH - 1 && owner[i + CW] !== o);
      if (edge) [r, g, b] = c.border;
      else { r = r * (1 - ALPHA) + c.fill[0] * ALPHA; g = g * (1 - ALPHA) + c.fill[1] * ALPHA; b = b * (1 - ALPHA) + c.fill[2] * ALPHA; }
    }
    tileColor[i * 3] = r; tileColor[i * 3 + 1] = g; tileColor[i * 3 + 2] = b;
  }
  // Nearest-neighbour upscale into the frame.
  for (let py = 0; py < H; py++) {
    const ty = Math.min(CH - 1, Math.floor(py / scale));
    for (let px = 0; px < W; px++) {
      const tx = Math.min(CW - 1, Math.floor(px / scale));
      const s = (ty * CW + tx) * 3, d = (py * W + px) * 3;
      frame[d] = tileColor[s]; frame[d + 1] = tileColor[s + 1]; frame[d + 2] = tileColor[s + 2];
    }
  }
  // Blasts: white flash fading into an orange ring.
  for (const bl of blasts) {
    const cx = (bl.x - CX) * scale, cy = (bl.y - CY) * scale;
    const rad = Math.max(60, bl.r * scale) * (0.5 + 1.1 * Math.min(1, bl.age / 10));
    const a = Math.max(0, 1 - bl.age / 28);
    const x0 = Math.max(0, Math.floor(cx - rad)), x1 = Math.min(W - 1, Math.ceil(cx + rad));
    const y0 = Math.max(0, Math.floor(cy - rad)), y1 = Math.min(H - 1, Math.ceil(cy + rad));
    for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
      const d = Math.hypot(x - cx, y - cy);
      if (d > rad) continue;
      const ringT = Math.max(0, 1 - Math.abs(d - rad * 0.92) / (rad * 0.08));
      const k = (bl.age < 4 ? 0.9 : 0.4) * a;
      const o = (y * W + x) * 3;
      const [fr, fg, fb] = ringT > 0 ? [255, 150, 40] : [255, 245, 215];
      const kk = ringT > 0 ? Math.max(k, ringT * a) : k;
      frame[o] = frame[o] * (1 - kk) + fr * kk; frame[o + 1] = frame[o + 1] * (1 - kk) + fg * kk; frame[o + 2] = frame[o + 2] * (1 - kk) + fb * kk;
    }
  }
  // Missiles in flight: glowing head + fading trail.
  for (const [, trail] of trails) {
    trail.forEach((pt, i) => {
      const cx = (pt[0] - CX + 0.5) * scale, cy = (pt[1] - CY + 0.5) * scale;
      const head = i === trail.length - 1;
      const rad = head ? 14 : 4 + 6 * (i / trail.length);
      const k0 = head ? 1 : 0.25 + 0.5 * (i / trail.length);
      for (let y = Math.max(0, Math.floor(cy - rad)); y <= Math.min(H - 1, Math.ceil(cy + rad)); y++)
        for (let x = Math.max(0, Math.floor(cx - rad)); x <= Math.min(W - 1, Math.ceil(cx + rad)); x++) {
          const d = Math.hypot(x - cx, y - cy);
          if (d > rad) continue;
          const k = k0 * (1 - d / rad * 0.6);
          const o = (y * W + x) * 3;
          const col = head && d < rad * 0.5 ? [255, 255, 255] : [255, 70, 50];
          frame[o] = frame[o] * (1 - k) + col[0] * k; frame[o + 1] = frame[o + 1] * (1 - k) + col[1] * k; frame[o + 2] = frame[o + 2] * (1 - k) + col[2] * k;
        }
    });
  }
  // Names of the biggest players whose centre is inside the crop.
  const sums = new Map<number, number[]>();
  for (let y = 0; y < CH; y += 2) for (let x = 0; x < CW; x += 2) {
    const o = owner[y * CW + x];
    if (!o) continue;
    const s = sums.get(o) ?? [0, 0, 0];
    s[0] += x; s[1] += y; s[2]++;
    sums.set(o, s);
  }
  let svg = "";
  const ranked = [...sums.entries()].filter(([, s]) => s[2] > 60).sort((a, b) => b[1][2] - a[1][2]).slice(0, 18);
  for (const [o, [sx, sy, n]] of ranked) {
    const p = game.playerBySmallID(o);
    if (!p || !p.isAlive?.()) continue;
    const fs_ = Math.min(72, Math.max(26, Math.sqrt(n * 4) * scale * 0.14));
    const nm = String(p.displayName?.() ?? p.name()).replace(/&/g, "&amp;").replace(/</g, "&lt;");
    svg += `<text x="${(sx / n) * scale}" y="${(sy / n) * scale}" font-size="${fs_.toFixed(0)}" font-family="Segoe UI" font-weight="700" fill="#fff" stroke="#000" stroke-opacity=".6" stroke-width="${(fs_ / 12).toFixed(1)}" paint-order="stroke" text-anchor="middle" dominant-baseline="middle">${nm}</text>`;
  }
  if (svg) {
    const img = new Resvg(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">${svg}</svg>`, { font: { loadSystemFonts: true } }).render();
    const px = img.pixels;
    for (let i = 0, o = 0; i < px.length; i += 4, o += 3) {
      const a = px[i + 3] / 255;
      if (a === 0) continue;
      frame[o] = frame[o] * (1 - a) + px[i] * a; frame[o + 1] = frame[o + 1] * (1 - a) + px[i + 1] * a; frame[o + 2] = frame[o + 2] * (1 - a) + px[i + 2] * a;
    }
  }
}

async function write(buf: Buffer) {
  if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once("drain", r));
}

const t0 = Date.now();
let frames = 0;
for (let tick = 0; tick < TICKS; tick++) {
  game.executeNextTick();
  // Nukes that disappeared since last tick having reached their target blow up.
  const now = new Map<number, any>();
  for (const u of game.units(...NUKES)) now.set(u.id(), u);
  for (const [id, u] of prevNukes) {
    if (!now.has(id) && u.type() !== UnitType.MIRV && u.targetTile?.() != null) {
      const t = u.targetTile();
      blasts.push({ x: gameMap.x(t), y: gameMap.y(t), r: BLAST[u.type()] ?? 30, age: 0 });
      blastLog.push(`${tick}:${u.type()}@${gameMap.x(t)},${gameMap.y(t)}`);
      if (inCrop(t)) events.push({ f: frames, cue: u.type() === UnitType.HydrogenBomb ? "hydrogen-hit" : "atom-hit" });
    }
  }
  for (const [id, u] of now) {
    const cue = LAUNCH_CUE[u.type()];
    if (!prevNukes.has(id) && cue && (inCrop(u.tile()) || (u.targetTile?.() != null && inCrop(u.targetTile())))) events.push({ f: frames, cue });
  }
  if (tick === 0 || recordTick(tick)) {
    const alive = game.players().filter((p: any) => p.isAlive()).length;
    if (aliveBefore >= 0 && alive < aliveBefore) events.push({ f: frames, cue: "conquered" });
    aliveBefore = alive;
  }
  prevNukes = now;
  for (const id of [...trails.keys()]) if (!now.has(id)) trails.delete(id);
  for (const [id, u] of now) {
    const t = u.tile();
    const tr = trails.get(id) ?? [];
    tr.push([gameMap.x(t), gameMap.y(t)]);
    if (tr.length > 14) tr.shift();
    trails.set(id, tr);
  }
  if (recordTick(tick)) {
    renderFrame();
    await write(frame);
    frames++;
    for (const b of blasts) b.age++;
    for (let i = blasts.length - 1; i >= 0; i--) if (blasts[i].age > 28) blasts.splice(i, 1);
  }
  if (game.getWinner?.()) break;
  if (tick % 500 === 0) console.error(`tick ${tick}, frames ${frames}, ${((Date.now() - t0) / 1000).toFixed(0)} s`);
}
// Hold the last frame for 2 s.
for (let i = 0; i < 60; i++) await write(frame);
ff.stdin.end();
await new Promise((r) => ff.on("close", r));
console.error(`done: ${frames} frames -> ${OUT}`);
fs.writeFileSync(OUT + ".events.json", JSON.stringify({ fps: 30, frames: frames + 60, winner: !!game.getWinner?.(), events }));
console.error(`blasts (${blastLog.length}): ${blastLog.slice(0, 60).join(" ")}`);
