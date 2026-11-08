// One-shot shop setup: creates every game pass / developer product listed in
// src/shared/Data/Shop.luau that still has id 0, through Roblox Open Cloud, and writes
// the new ids back into Shop.luau. Run it AFTER the experience is published.
//
//   node tools/setup-shop.mjs --universe 123456789 --key <API_KEY> [--dry] [--with-rebirth] [--with-ads]
//   (or set ROBLOX_API_KEY / ROBLOX_UNIVERSE_ID)
//
// API key (Creator Hub -> Credentials): scopes developer-product:write, game-pass:write for this
// experience; leave the IP allow-list at 0.0.0.0/0 or add yours. The key is never stored.
// Not created by the script: the monthly subscription (Dashboard only) and, unless asked, Rebirth
// (pay-to-win) and the rewarded-ad product.
// Safe to re-run: only entries whose id is still 0 are created.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const shopFile = path.join(root, "src/shared/Data/Shop.luau");
const artDir = path.join(root, "art");

const args = process.argv.slice(2);
const flag = (n) => args.includes(`--${n}`);
const opt = (n, env) => {
  const i = args.indexOf(`--${n}`);
  return i >= 0 ? args[i + 1] : process.env[env];
};
const universe = opt("universe", "ROBLOX_UNIVERSE_ID");
const key = opt("key", "ROBLOX_API_KEY");
const dry = flag("dry");

let src = fs.readFileSync(shopFile, "utf8");
const nl = src.includes("\r\n") ? "\r\n" : "\n";

// --- collect work -----------------------------------------------------------------
const jobs = [];
const lines = src.split(/\r?\n/);
for (let i = 0; i < lines.length; i++) {
  const l = lines[i];
  let m;
  // passes: supporter = { id = 0, price = 199, name = "Supporter", desc = "..." },
  if ((m = l.match(/^\t(\w+) = \{ id = 0, price = (\d+), name = "([^"]+)", desc = "([^"]*)" \},?/)) && src.indexOf("Shop.PASSES") < src.indexOf(l)) {
    const imgs = { supporter: "supporter-pass.png", color: "pass-color.png", host: "pass-host.png", flag: "pass-flag.png" };
    jobs.push({ kind: "pass", line: i, token: "id = 0", repl: "id = ", name: m[3], desc: m[4], price: +m[2], image: imgs[m[1]] });
    continue;
  }
  // items: { id = "pattern_stripes", kind = "pattern", name = "Stripes", price = 49, productId = 0, ...
  if ((m = l.match(/^\t\{ id = "([^"]+)", kind = "(\w+)", name = "([^"]+)", price = (\d+), productId = 0/))) {
    const label = { pattern: "Territory pattern", nameColor: "Name colour", explosion: "Nuke blast colour" }[m[2]] ?? "Cosmetic";
    jobs.push({ kind: "product", line: i, token: "productId = 0", repl: "productId = ", name: `${m[3]} (${label.toLowerCase()})`, desc: `${label}: ${m[3]}. Cosmetic only, no gameplay advantage.`, price: +m[4] });
    continue;
  }
  // bundles
  if ((m = l.match(/^\t\{ id = "(bundle_\w+)", name = "([^"]+)", price = (\d+), productId = 0/))) {
    jobs.push({ kind: "product", line: i, token: "productId = 0", repl: "productId = ", name: m[2], desc: `${m[2]}: several cosmetics in one purchase. Cosmetic only.`, price: +m[3] });
    continue;
  }
  if ((m = l.match(/^Shop\.DAILY_DEAL = \{ productId = 0, price = (\d+) \}/))) {
    jobs.push({ kind: "product", line: i, token: "productId = 0", repl: "productId = ", name: "Deal of the day", desc: "Today's featured cosmetic at a discount.", price: +m[1] });
    continue;
  }
  if ((m = l.match(/^Shop\.AD_REWARD = \{ productId = 0, price = (\d+) \}/))) {
    if (flag("with-ads")) jobs.push({ kind: "product", line: i, token: "productId = 0", repl: "productId = ", name: "Free cosmetic trial", desc: "24 hour trial of a random cosmetic.", price: +m[1] });
    continue;
  }
  if ((m = l.match(/^Shop\.REBIRTH = \{ productId = 0, price = (\d+) \}/))) {
    if (flag("with-rebirth")) jobs.push({ kind: "product", line: i, token: "productId = 0", repl: "productId = ", name: "Rebirth", desc: "Return after defeat with your biggest territory.", price: +m[1] });
    continue;
  }
}

console.log(`${jobs.length} entries to create (${jobs.filter((j) => j.kind === "pass").length} passes, ${jobs.filter((j) => j.kind === "product").length} products)`);
for (const j of jobs) console.log(`  [${j.kind}] ${j.name}  R$ ${j.price}`);
if (dry || jobs.length === 0) {
  console.log(dry ? "Dry run: nothing created." : "Nothing to do.");
  process.exit(0);
}
if (!universe || !key) {
  console.error("Need --universe <id> and --key <API key> (or ROBLOX_UNIVERSE_ID / ROBLOX_API_KEY).");
  process.exit(1);
}

// --- create -----------------------------------------------------------------------
const created = [];
async function create(j) {
  const form = new FormData();
  form.set("name", j.name.slice(0, 50));
  form.set("description", j.desc.slice(0, 1000));
  form.set("price", String(j.price));
  form.set("isForSale", "true");
  form.set("isRegionalPricingEnabled", "true");
  if (j.image) {
    const f = path.join(artDir, j.image);
    if (fs.existsSync(f)) form.set("imageFile", new Blob([fs.readFileSync(f)], { type: "image/png" }), j.image);
  }
  const url =
    j.kind === "pass"
      ? `https://apis.roblox.com/game-passes/v1/universes/${universe}/game-passes`
      : `https://apis.roblox.com/developer-products/v2/universes/${universe}/developer-products`;
  for (let attempt = 1; attempt <= 4; attempt++) {
    const res = await fetch(url, { method: "POST", headers: { "x-api-key": key }, body: form });
    const text = await res.text();
    if (res.status === 429) {
      await new Promise((r) => setTimeout(r, 1500 * attempt));
      continue;
    }
    if (!res.ok) throw new Error(`${res.status} ${text.slice(0, 300)}`);
    const body = JSON.parse(text);
    const id = body.gamePassId ?? body.productId ?? body.id;
    if (!id) throw new Error("no id in response: " + text.slice(0, 200));
    return Number(id);
  }
  throw new Error("rate limited");
}

for (const j of jobs) {
  try {
    const id = await create(j);
    lines[j.line] = lines[j.line].replace(j.token, j.repl + id);
    fs.writeFileSync(shopFile, lines.join(nl)); // patch after every success: re-run is safe
    created.push({ name: j.name, kind: j.kind, id });
    console.log(`  ok  ${j.name} -> ${id}`);
  } catch (e) {
    console.error(`  FAIL ${j.name}: ${e.message}`);
  }
  await new Promise((r) => setTimeout(r, 400)); // 3 requests/second limit
}
fs.writeFileSync(path.join(root, "tools/shop-created.json"), JSON.stringify(created, null, 2));
console.log(`Done: ${created.length}/${jobs.length}. Ids written into src/shared/Data/Shop.luau - now run: node tools/build.mjs and republish.`);
console.log("Still manual: monthly subscription (Dashboard -> Monetization -> Subscriptions), then set Shop.SUBSCRIPTION_ID.");
