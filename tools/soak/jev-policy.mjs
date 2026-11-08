// Builds an autoplayer policy for the OpenFront soak test with TypeSafe Jev:
// one Choice question per coarse game-state bucket, answers = action
// probability distributions. Key comes from env JEV_KEY (never stored).
import fs from "node:fs";

const KEY = process.env.JEV_KEY;
if (!KEY) throw new Error("JEV_KEY missing");

const ACTIONS = {
  expand: "Attack unclaimed neutral land next to my border to grow",
  attack_weak: "Attack the weakest neighbouring player",
  boat_attack: "Send a boat invasion to a player across water",
  build_city: "Build a city (more max troops)",
  build_port: "Build a port (trade gold)",
  build_factory: "Build a factory (railroads, trains, gold)",
  build_defense: "Build a defense post on the border",
  build_silo: "Build a missile silo",
  build_sam: "Build a SAM launcher against nukes",
  build_warship: "Build a warship",
  upgrade: "Upgrade an existing structure",
  atom_bomb: "Launch an atom bomb at an enemy (needs a silo)",
  hydrogen_bomb: "Launch a hydrogen bomb at an enemy (needs a silo)",
  mirv: "Launch a MIRV at the strongest enemy (needs a silo)",
  request_alliance: "Ask a neighbour for an alliance",
  accept_alliance: "Accept a pending alliance request",
  break_alliance: "Break an alliance (betray)",
  donate: "Donate gold or troops to an ally",
  embargo: "Stop trading with a rival",
  emoji: "Send an emoji",
  quick_chat: "Send a quick chat message",
  cancel_attack: "Retreat: cancel my newest attack",
  idle: "Do nothing, let troops regenerate",
};

const PHASES = { early: "first 3 minutes", mid: "3 to 12 minutes in", late: "after 12 minutes" };
const STRENGTH = { none: "no land neighbours", weaker: "I am much weaker than my weakest neighbour", even: "about as strong as my weakest neighbour", stronger: "much stronger than my weakest neighbour" };
const GOLD = { low: "under 100k gold", mid: "100k to 1M gold", high: "over 1M gold" };
const THREAT = { safe: "nobody is attacking me", attacked: "I am being attacked" };
const REQ = { none: "no alliance requests", pending: "an alliance request is waiting for me" };

const buckets = [];
for (const p in PHASES) for (const s in STRENGTH) for (const g in GOLD) for (const t in THREAT) for (const r in REQ)
  buckets.push({ key: `${p}|${s}|${g}|${t}|${r}`, desc: { phase: PHASES[p], strength: STRENGTH[s], gold: GOLD[g], threat: THREAT[t], diplomacy: REQ[r] } });

const state = {
  game: "OpenFront-style territory strategy game (like openfront.io): players expand over a world map, attack neighbours with troops, build cities/ports/factories/defenses, and late game use missile silos for nukes. Gold buys structures. Alliances matter.",
  goal: "Choose the next action for an automated test player so it plays plausibly and exercises all game features over a long session.",
};

async function ask(batch) {
  const questions = {};
  batch.forEach((b, i) => {
    questions[`q${i}`] = {
      type: "choice",
      instructions: { situation: b.desc, question: "Given `situation`, what should the player do next?" },
      criteria: ACTIONS,
    };
  });
  const res = await fetch("https://api.typesafe.ai/v1/systemone", {
    method: "POST",
    headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ state, model: "jev-latest", questions }),
  });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  const data = await res.json();
  return batch.map((b, i) => [b.key, data.answers[`q${i}`].probabilities]);
}

const policy = {};
const size = 24;
const jobs = [];
for (let i = 0; i < buckets.length; i += size) jobs.push(ask(buckets.slice(i, i + size)));
for (const part of await Promise.all(jobs)) for (const [k, probs] of part) policy[k] = probs;
fs.writeFileSync(new URL("./policy.json", import.meta.url), JSON.stringify(policy));
const sample = policy["mid|stronger|high|safe|none"];
console.log(Object.keys(policy).length, "buckets; mid|stronger|high:", Object.entries(sample).sort((a, b) => b[1] - a[1]).slice(0, 5));
