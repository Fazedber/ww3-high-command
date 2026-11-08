// Packs an OpenFrontIO map into a Luau ModuleScript.
//
// Usage: node tools/pack-map.mjs <mapDir> [<mapDir> ...]
//        node tools/pack-map.mjs --playlist      (the curated lobby set below)
//   e.g. node tools/pack-map.mjs world europe
//
// Reads ../OpenFrontIO/resources/maps/<mapDir>/{manifest.json,map4x.bin,map16x.bin}
// and writes src/maps/<Id>.luau (built into ServerStorage.Maps; the server
// copies only the selected map to ReplicatedStorage). Terrain is
// zstd-compressed and base64-encoded; the game decodes it with
// EncodingService (see MapLoader). Also writes src/shared/Data/MapCatalog.luau
// (name, categories, nations, size and a small thumbnail per packed map) for
// the lobby's map picker.
//
// We ship the Compact variant (map4x as the game map, map16x as the minimap),
// mirroring GameMapSize.Compact in OpenFrontIO's TerrainMapLoader.ts, including
// its floor(coord / 2) scaling of nation coordinates and team spawn areas.
//
// Map data is (c) OpenFront, licensed CC BY-SA 4.0 — see NOTICE.md.

import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const here = path.dirname(fileURLToPath(import.meta.url));
const upstreamRoot =
  process.env.OPENFRONT_DIR ?? path.resolve(here, "../../OpenFrontIO");
const upstreamMaps = path.join(upstreamRoot, "resources/maps");
// Map-generator source info (tribe name themes live only here).
const upstreamInfo = path.join(upstreamRoot, "map-generator/assets/maps");
const outDir = path.resolve(here, "../src/maps");
const catalogFile = path.resolve(here, "../src/shared/Data/MapCatalog.luau");
const THUMB_W = 96; // px; thumbnail.webp scaled down, aspect kept

// Lobby playlist: the most frequent maps of upstream's public rotation
// (manifest multiplayer_frequency) plus the featured continents, capped at
// ~1.8M tiles (Compact) for Roblox performance.
const PLAYLIST = [
  "world", "europe", "asia", "africa", "northamerica", "southamerica",
  "unitedstates", "alps", "china", "france", "hongkong", "indiansubcontinent",
  "losangeles", "middleeast", "milkyway", "russia", "worldinverted", "dyslexdria",
  "branchingpaths", "morethanluck", "scandinavia", "aegean", "arctic", "balkans",
  "blacksea", "greatlakes", "italia", "japan", "marenostrum", "mena", "pluto",
  "britannia", "baltics", "caribbean", "sierpinski", "svalmel",
];

function packTerrain(bin, meta, label) {
  if (bin.length !== meta.width * meta.height) {
    throw new Error(
      `${label}: ${bin.length} bytes, expected ${meta.width}x${meta.height}`,
    );
  }
  const z = zlib.zstdCompressSync(bin, {
    params: { [zlib.constants.ZSTD_c_compressionLevel]: 19 },
  });
  if (Buffer.compare(zlib.zstdDecompressSync(z), bin) !== 0) {
    throw new Error(`${label}: zstd round-trip mismatch`);
  }
  return Buffer.from(z).toString("base64");
}

const half = (v) => Math.floor(v / 2);

// Luau string literal. Names come from upstream manifests, so escape properly.
function luaStr(s) {
  return JSON.stringify(String(s));
}

function nationsLua(list) {
  if (!list || list.length === 0) return "{}";
  const rows = list.map((n) => {
    const parts = [`name = ${luaStr(n.name)}`];
    if (n.flag !== undefined) parts.push(`flag = ${luaStr(n.flag)}`);
    if (n.coordinates !== undefined) {
      parts.push(
        `coordinates = { ${half(n.coordinates[0])}, ${half(n.coordinates[1])} }`,
      );
    }
    return `\t\t{ ${parts.join(", ")} },`;
  });
  return `{\n${rows.join("\n")}\n\t}`;
}

function spawnAreasLua(areas) {
  if (!areas) return "nil";
  const keys = Object.keys(areas);
  const rows = keys.map((k) => {
    const list = areas[k]
      .map(
        (a) =>
          `{ x = ${half(a.x)}, y = ${half(a.y)}, width = ${Math.max(1, half(a.width))}, height = ${Math.max(1, half(a.height))} }`,
      )
      .join(", ");
    return `\t\t[${luaStr(k)}] = { ${list} },`;
  });
  return `{\n${rows.join("\n")}\n\t}`;
}

const catalog = [];

async function thumbnail(src, w, h) {
  const tw = THUMB_W;
  const th = Math.max(1, Math.round((THUMB_W * h) / w));
  const file = path.join(src, "thumbnail.webp");
  if (!fs.existsSync(file)) return null;
  const { data, info } = await sharp(file).resize(tw, th, { fit: "fill" }).flatten({ background: "#1f2937" }).raw().toBuffer({ resolveWithObject: true });
  // RGB, 5 bits per channel: plenty for a 96 px preview, compresses far better.
  for (let i = 0; i < data.length; i++) data[i] &= 0xf8;
  const z = zlib.zstdCompressSync(data, { params: { [zlib.constants.ZSTD_c_compressionLevel]: 19 } });
  return { w: info.width, h: info.height, data: Buffer.from(z).toString("base64") };
}

async function packMap(dir) {
  const src = path.join(upstreamMaps, dir);
  const manifest = JSON.parse(
    fs.readFileSync(path.join(src, "manifest.json"), "utf8"),
  );
  const map = manifest.map4x;
  const mini = manifest.map16x;
  const terrain = packTerrain(
    fs.readFileSync(path.join(src, "map4x.bin")),
    map,
    `${dir}/map4x`,
  );
  const miniTerrain = packTerrain(
    fs.readFileSync(path.join(src, "map16x.bin")),
    mini,
    `${dir}/map16x`,
  );
  const infoFile = path.join(upstreamInfo, dir, "info.json");
  const info = fs.existsSync(infoFile)
    ? JSON.parse(fs.readFileSync(infoFile, "utf8"))
    : {};
  const themes = info.themes ?? [];
  // Module name must be a valid Roblox instance name; ids are like "World".
  const id = String(manifest.id ?? manifest.name).replace(/[^A-Za-z0-9_]/g, "");

  const lua = `-- AUTO-GENERATED by tools/pack-map.mjs — do not edit by hand.
-- Source: OpenFrontIO resources/maps/${dir} (Compact size: map4x + map16x)
-- Map data (c) OpenFront, licensed CC BY-SA 4.0. See NOTICE.md.
return {
\tid = ${luaStr(id)},
\tname = ${luaStr(manifest.name)},
\tcategories = { ${(manifest.categories ?? []).map(luaStr).join(", ")} },
\t-- Tribe name themes (map-generator info.json); empty means "default".
\tthemes = { ${themes.map(luaStr).join(", ")} },
\twidth = ${map.width},
\theight = ${map.height},
\tnumLandTiles = ${map.num_land_tiles},
\tminiWidth = ${mini.width},
\tminiHeight = ${mini.height},
\tminiNumLandTiles = ${mini.num_land_tiles},
\tnations = ${nationsLua(manifest.nations)},
\tadditionalNations = ${nationsLua(manifest.additionalNations)},
\tteamGameSpawnAreas = ${spawnAreasLua(manifest.teamGameSpawnAreas)},
\t-- zstd + base64 terrain bytes (1 byte per tile, row-major).
\tterrain = "${terrain}",
\tminiTerrain = "${miniTerrain}",
}
`;
  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${id}.luau`);
  fs.writeFileSync(outFile, lua);
  console.log(
    `${dir} -> ${path.relative(process.cwd(), outFile)}  ${map.width}x${map.height}  ${(lua.length / 1024).toFixed(0)} KB`,
  );
  catalog.push({
    id,
    name: manifest.name,
    categories: manifest.categories ?? [],
    nations: (manifest.nations ?? []).length,
    width: map.width,
    height: map.height,
    frequency: manifest.multiplayer_frequency ?? 0,
    thumb: await thumbnail(src, map.width, map.height),
  });
}

function writeCatalog() {
  // Merge with maps packed earlier so partial runs keep the others.
  const existing = new Map();
  const keep = fs.existsSync(outDir) ? new Set(fs.readdirSync(outDir).map((f) => f.replace(/\.luau$/, ""))) : new Set();
  for (const e of catalog) existing.set(e.id, e);
  const rows = [...existing.values()].filter((e) => keep.has(e.id));
  const lua = `-- AUTO-GENERATED by tools/pack-map.mjs — do not edit by hand.
-- Lobby map picker data for the maps in src/maps (CC BY-SA 4.0, © OpenFront).
-- thumb: zstd + base64 RGB (w x h, 5-bit channels).
return {
${rows
  .map(
    (e) =>
      `\t{ id = ${luaStr(e.id)}, name = ${luaStr(e.name)}, categories = { ${e.categories.map(luaStr).join(", ")} }, nations = ${e.nations}, width = ${e.width}, height = ${e.height}, frequency = ${e.frequency}, thumb = ${e.thumb ? `{ w = ${e.thumb.w}, h = ${e.thumb.h}, data = "${e.thumb.data}" }` : "nil"} },`,
  )
  .join("\n")}
}
`;
  fs.writeFileSync(catalogFile, lua);
  console.log(`catalog: ${rows.length} maps -> ${path.relative(process.cwd(), catalogFile)} (${(lua.length / 1024).toFixed(0)} KB)`);
}

let dirs = process.argv.slice(2);
if (dirs.length === 1 && dirs[0] === "--playlist") dirs = PLAYLIST;
if (dirs.length === 0) {
  console.error("usage: node tools/pack-map.mjs <mapDir> [<mapDir> ...] | --playlist");
  process.exit(1);
}
for (const d of dirs) await packMap(d);
writeCatalog();
