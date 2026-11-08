// Store art (icon + thumbnails) rendered the way the game renders a match:
// real map terrain (upstream map.bin, game terrain palette), nation
// territories grown from the map's real nation spawns with the game's
// territory alpha and border colours, and nation names on top.
//
// Usage: node tools/make-art.mjs      (re-run after changing GameInfo.TITLE)
// Output: art/icon.png (512x512), art/thumbnail-1.png, art/thumbnail-2.png (1920x1080)
//
// Map data (c) OpenFront, CC BY-SA 4.0 — see NOTICE.md.

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";
import { Resvg } from "@resvg/resvg-js";

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = process.env.OPENFRONT_DIR ?? path.resolve(here, "../../OpenFrontIO");
const req = createRequire(path.join(upstream, "package.json"));
const { colord, extend } = req("colord");
extend([req("colord/plugins/lab"), req("colord/plugins/lch")]);
const outDir = path.resolve(here, "../art");
fs.mkdirSync(outDir, { recursive: true });

const gameInfo = fs.readFileSync(path.resolve(here, "../src/shared/GameInfo.luau"), "utf8");
const TITLE = gameInfo.match(/TITLE = "([^"]+)"/)[1];

// Terrain palette: TerrainColors.encodeTile (upstream ColorUtils.encodeTerrainTile).
function terrainRGB(tb) {
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
function border(c) {
  let out = colord(c);
  if (theme.borderDarken) out = out.darken(theme.borderDarken);
  const { r, g, b } = out.toRgb();
  return [r, g, b];
}
const ALPHA = 0.588; // TerritoryRenderer TERRITORY_ALPHA

function loadMap(dir) {
  const manifest = JSON.parse(fs.readFileSync(path.join(upstream, "resources/maps", dir, "manifest.json"), "utf8"));
  const { width: W, height: H } = manifest.map;
  const terrain = fs.readFileSync(path.join(upstream, "resources/maps", dir, "map.bin"));
  if (terrain.length < W * H) throw new Error(`${dir}: map.bin ${terrain.length} < ${W * H}`);
  return { manifest, W, H, terrain };
}

// Seeded RNG so the art is reproducible.
function rng(seed) {
  return () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
}

// Multi-source Dijkstra over land with noise-weighted steps: nations grow
// into free land with ragged, organic fronts; each stops at its budget.
function grow(map, budgets) {
  const { W, H, terrain, manifest } = map;
  const owner = new Uint16Array(W * H);
  const size = new Array(manifest.nations.length).fill(0);
  // Smooth value noise (cell 24 tiles) -> step weight 1..6.
  const CELL = 24, gw = Math.ceil(W / CELL) + 2, gh = Math.ceil(H / CELL) + 2;
  const r = rng(99);
  const grid = Float32Array.from({ length: gw * gh }, () => r());
  const weight = (t) => {
    const x = (t % W) / CELL, y = Math.floor(t / W) / CELL;
    const ix = Math.floor(x), iy = Math.floor(y), fx = x - ix, fy = y - iy;
    const g = (a, b) => grid[b * gw + a];
    const v = (g(ix, iy) * (1 - fx) + g(ix + 1, iy) * fx) * (1 - fy) + (g(ix, iy + 1) * (1 - fx) + g(ix + 1, iy + 1) * fx) * fy;
    return 1 + 5 * v * v;
  };
  // Binary heap of [cost, tile, nation].
  const heap = [];
  const push = (e) => { heap.push(e); let i = heap.length - 1; while (i > 0) { const p = (i - 1) >> 1; if (heap[p][0] <= heap[i][0]) break; [heap[p], heap[i]] = [heap[i], heap[p]]; i = p; } };
  const pop = () => { const top = heap[0], last = heap.pop(); if (heap.length) { heap[0] = last; let i = 0; for (;;) { const l = 2 * i + 1, rr = l + 1; let m = i; if (l < heap.length && heap[l][0] < heap[m][0]) m = l; if (rr < heap.length && heap[rr][0] < heap[m][0]) m = rr; if (m === i) break; [heap[m], heap[i]] = [heap[i], heap[m]]; i = m; } } return top; };
  manifest.nations.forEach((n, i) => {
    const t = n.coordinates[1] * W + n.coordinates[0];
    if (terrain[t] & 0x80) push([0, t, i]);
  });
  while (heap.length) {
    const [cost, t, i] = pop();
    if (owner[t] || size[i] >= budgets[i]) continue;
    owner[t] = i + 1;
    size[i]++;
    const x = t % W, y = (t / W) | 0;
    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      const nx = x + dx, ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
      const nt = ny * W + nx;
      if (owner[nt] || !(terrain[nt] & 0x80) || (terrain[nt] & 0x1f) === 31) continue;
      push([cost + weight(nt), nt, i]);
    }
  }
  return { owner, size };
}

function render(map, owner, colors, x0, y0, w, h, scale) {
  const { W, terrain } = map;
  const png = new PNG({ width: w * scale, height: h * scale });
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const t = (y0 + y) * W + (x0 + x);
      let rgb = terrainRGB(terrain[t]);
      const o = owner[t];
      if (o) {
        const isBorder = [-1, 1, -W, W].some((d) => owner[t + d] !== o);
        const c = colors[o - 1];
        rgb = isBorder ? c.border : rgb.map((v, k) => Math.round(v * (1 - ALPHA) + c.fill[k] * ALPHA));
      }
      for (let sy = 0; sy < scale; sy++) {
        for (let sx = 0; sx < scale; sx++) {
          const p = ((y * scale + sy) * w * scale + (x * scale + sx)) * 4;
          png.data[p] = rgb[0]; png.data[p + 1] = rgb[1]; png.data[p + 2] = rgb[2]; png.data[p + 3] = 255;
        }
      }
    }
  }
  return PNG.sync.write(png);
}

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");

function namesSvg(map, owner, size, x0, y0, w, h, scale, skipTop = 0) {
  const sums = new Map();
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const o = owner[(y0 + y) * map.W + x0 + x];
    if (!o) continue;
    const s = sums.get(o) ?? [0, 0, 0];
    s[0] += x; s[1] += y; s[2]++;
    sums.set(o, s);
  }
  let out = "";
  for (const [o, [sx, sy, n]] of sums) {
    if (n < 600 || (sy / n) * scale < skipTop) continue;
    const name = map.manifest.nations[o - 1].name;
    const fs_ = Math.min(64, Math.max(14, Math.sqrt(n) * scale * 0.16));
    out += `<text x="${(sx / n) * scale}" y="${(sy / n) * scale}" font-size="${fs_.toFixed(1)}" class="name">${esc(name)}</text>`;
  }
  return out;
}

function compose(bgPng, W, H, overlay) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
<style>
.name{font-family:'Segoe UI','Arial';font-weight:700;fill:#fff;stroke:#000;stroke-opacity:.55;stroke-width:3px;paint-order:stroke;text-anchor:middle;dominant-baseline:middle}
.title{font-family:'Segoe UI Black','Arial Black','Segoe UI';font-weight:900;fill:#fff;stroke:#0b1220;stroke-width:10px;paint-order:stroke;text-anchor:middle}
.sub{font-family:'Segoe UI','Arial';font-weight:700;fill:#fde68a;stroke:#0b1220;stroke-width:6px;paint-order:stroke;text-anchor:middle}
</style>
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0b1220" stop-opacity=".75"/><stop offset="1" stop-color="#0b1220" stop-opacity="0"/></linearGradient><linearGradient id="gb" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#0b1220" stop-opacity=".7"/><stop offset="1" stop-color="#0b1220" stop-opacity="0"/></linearGradient></defs>
<image href="data:image/png;base64,${bgPng.toString("base64")}" x="0" y="0" width="${W}" height="${H}" style="image-rendering:pixelated"/>
${overlay}
</svg>`;
  return new Resvg(svg, { font: { loadSystemFonts: true, defaultFontFamily: "Segoe UI" } }).render().asPng();
}

const world = loadMap("world");
const rand = rng(42);
const budgets = world.manifest.nations.map(() => 3000 + Math.floor(rand() * rand() * 40000));
const { owner, size } = grow(world, budgets);
const colors = world.manifest.nations.map((_, i) => {
  const hex = theme.nationColors[i % theme.nationColors.length];
  const { r, g, b } = colord(hex).toRgb();
  return { fill: [r, g, b], border: border(hex) };
});

// Thumbnail 1: Europe / Africa at 2x zoom with the title.
{
  const [x0, y0, w, h] = [760, 120, 960, 540];
  const bg = render(world, owner, colors, x0, y0, w, h, 2);
  const overlay = namesSvg(world, owner, size, x0, y0, w, h, 2, 300) +
    `<rect x="0" y="0" width="1920" height="340" fill="url(#g)"/>` +
    `<text x="960" y="170" font-size="150" class="title">${esc(TITLE)}</text>` +
    `<text x="960" y="250" font-size="54" class="sub">Conquer the world, one border at a time</text>`;
  fs.writeFileSync(path.join(outDir, "thumbnail-1.png"), compose(bg, 1920, 1080, overlay));
}
// Thumbnail 2: the Americas, names only.
{
  const [x0, y0, w, h] = [180, 120, 960, 540];
  const bg = render(world, owner, colors, x0, y0, w, h, 2);
  const overlay = namesSvg(world, owner, size, x0, y0, w, h, 2) +
    `<rect x="0" y="900" width="1920" height="180" fill="url(#gb)"/>` +
    `<text x="960" y="1020" font-size="60" class="sub">Expand · Ally · Betray · Build · Nuke</text>`;
  fs.writeFileSync(path.join(outDir, "thumbnail-2.png"), compose(bg, 1920, 1080, overlay));
}
// Icon: a square crop at 2x with the title.
{
  const [x0, y0, w, h] = [940, 200, 256, 256];
  const bg = render(world, owner, colors, x0, y0, w, h, 2);
  const overlay = `<rect x="0" y="170" width="512" height="180" fill="#0b1220" opacity=".35"/>` + `<text x="256" y="300" font-size="${Math.min(110, Math.floor(900 / TITLE.length))}" class="title">${esc(TITLE)}</text>`;
  fs.writeFileSync(path.join(outDir, "icon.png"), compose(bg, 512, 512, overlay));
}
console.log(`art/ written (title "${TITLE}")`);
