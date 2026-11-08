// Badge icons (512x512 PNG, Roblox crops them to a circle).
//
// Usage: node tools/make-badges.mjs   -> art/badges/<key>.png

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Resvg } from "@resvg/resvg-js";

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(here, "../art/badges");
fs.mkdirSync(outDir, { recursive: true });

const FONT = "C:/Windows/Fonts/segoeuib.ttf";

// Shared frame: radial background, gold rim, optional caption.
function badge(bg1, bg2, inner, caption) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <defs>
    <radialGradient id="bg" cx="50%" cy="40%" r="65%">
      <stop offset="0" stop-color="${bg1}"/><stop offset="1" stop-color="${bg2}"/>
    </radialGradient>
    <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fde68a"/><stop offset="0.5" stop-color="#f59e0b"/><stop offset="1" stop-color="#b45309"/>
    </linearGradient>
  </defs>
  <circle cx="256" cy="256" r="250" fill="url(#gold)"/>
  <circle cx="256" cy="256" r="226" fill="url(#bg)"/>
  ${inner}
  ${caption ? `<text x="256" y="430" font-family="Segoe UI" font-weight="700" font-size="64" text-anchor="middle" fill="#fff" stroke="#000" stroke-width="6" paint-order="stroke">${caption}</text>` : ""}
</svg>`;
}

const crown = (y, s = 1, fill = "url(#gold)") => `<g transform="translate(256 ${y}) scale(${s})">
  <path d="M-130 60 L-150 -70 L-70 0 L0 -100 L70 0 L150 -70 L130 60 Z" fill="${fill}" stroke="#78350f" stroke-width="10" stroke-linejoin="round"/>
  <rect x="-130" y="60" width="260" height="36" rx="8" fill="${fill}" stroke="#78350f" stroke-width="10"/>
  <circle cx="-150" cy="-70" r="16" fill="#fde68a"/><circle cx="0" cy="-100" r="16" fill="#fde68a"/><circle cx="150" cy="-70" r="16" fill="#fde68a"/>
</g>`;

const BADGES = {
  welcome: badge("#38bdf8", "#0c4a6e", `
    <circle cx="256" cy="236" r="130" fill="#1d4ed8" stroke="#e0f2fe" stroke-width="12"/>
    <path d="M190 170 q40 -30 70 0 q20 30 -10 50 q-40 10 -30 50 q10 30 -30 40 q-30 -40 -20 -90 z" fill="#4ade80"/>
    <path d="M290 250 q40 -20 60 10 q10 40 -30 60 q-30 0 -30 -30 z" fill="#4ade80"/>
    <ellipse cx="256" cy="236" rx="60" ry="130" fill="none" stroke="#e0f2fe" stroke-width="8"/>
    <line x1="126" y1="236" x2="386" y2="236" stroke="#e0f2fe" stroke-width="8"/>`, "HELLO"),
  firstWin: badge("#dc2626", "#450a0a", crown(230, 1.2), "VICTORY"),
  nuke: badge("#facc15", "#713f12", `
    <circle cx="256" cy="236" r="140" fill="#fde047" stroke="#111" stroke-width="12"/>
    <g fill="#111" transform="translate(256 236)">
      <path d="M0 0 L-58 -100 A116 116 0 0 1 58 -100 Z"/>
      <path d="M0 0 L-58 -100 A116 116 0 0 1 58 -100 Z" transform="rotate(120)"/>
      <path d="M0 0 L-58 -100 A116 116 0 0 1 58 -100 Z" transform="rotate(240)"/>
      <circle r="30" fill="#fde047"/><circle r="20"/>
    </g>`, "NUKE"),
  veteran: badge("#64748b", "#0f172a", `
    <path d="M256 90 L380 140 L370 280 Q350 360 256 400 Q162 360 142 280 L132 140 Z" fill="#94a3b8" stroke="#e2e8f0" stroke-width="12" stroke-linejoin="round"/>
    <text x="256" y="300" font-family="Segoe UI" font-weight="700" font-size="140" text-anchor="middle" fill="#0f172a">25</text>`, "VETERAN"),
  warlord: badge("#7c3aed", "#1e1b4b", `
    ${crown(180, 0.8)}
    <text x="256" y="345" font-family="Segoe UI" font-weight="700" font-size="120" text-anchor="middle" fill="#fde68a" stroke="#1e1b4b" stroke-width="8" paint-order="stroke">10</text>`, "WARLORD"),
};

for (const [key, svg] of Object.entries(BADGES)) {
  const png = new Resvg(svg, { font: { fontFiles: [FONT], loadSystemFonts: false, defaultFontFamily: "Segoe UI" } }).render().asPng();
  fs.writeFileSync(path.join(outDir, `${key}.png`), png);
  console.log(key, png.length);
}
