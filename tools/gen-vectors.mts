// Generates golden test vectors by running the ORIGINAL OpenFrontIO TypeScript.
//
// Usage (from the OpenFrontIO checkout, which has tsx installed):
//   cd ../OpenFrontIO && npx tsx ../OpenFrontRoblox/tools/gen-vectors.mts
//
// Writes tests/Vectors.luau. Doubles are stored as their exact IEEE-754 bits
// ({hi, lo} u32 words) so the Luau side can compare bit-for-bit without any
// decimal round-tripping.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = process.env.OPENFRONT_DIR ?? path.resolve(here, "../../OpenFrontIO");
const imp = (p: string) => import(pathToFileURL(path.join(upstream, p)).href);

const { exp, log, pow, pow2, atan2 } = await imp("src/core/DetMath.ts");
const { PseudoRandom } = await imp("src/core/PseudoRandom.ts");
const { FlatBinaryHeap } = await imp("src/core/execution/utils/FlatBinaryHeap.ts");
const { simpleHash, sigmoid } = await imp("src/core/Util.ts");

// ---- Luau literal emitter -----------------------------------------------------

const f64 = new Float64Array(1);
const u32 = new Uint32Array(f64.buffer);
// Little-endian hosts: u32[0] = low word, u32[1] = high word.
function bits(x: number): string {
  f64[0] = x;
  return `{${u32[1]},${u32[0]}}`;
}
type V = number | string | boolean | V[] | { [k: string]: V } | { __f64: number };
function lua(v: V): string {
  if (typeof v === "number") {
    if (!Number.isInteger(v)) throw new Error(`non-integer ${v}: wrap in f()`);
    return String(v);
  }
  if (typeof v === "string") return JSON.stringify(v);
  if (typeof v === "boolean") return String(v);
  if (Array.isArray(v)) return `{${v.map(lua).join(",")}}`;
  if ("__f64" in v) return bits((v as { __f64: number }).__f64);
  return `{${Object.entries(v)
    .map(([k, x]) => `[${JSON.stringify(k)}]=${lua(x)}`)
    .join(",")}}`;
}
const f = (x: number) => ({ __f64: x });

// ---- DetMath ------------------------------------------------------------------

const detInputs = [
  1e-310, 1e-300, 1e-10, 0.001, 0.1, 0.5, 0.9999999, 1, 1.0000001, 1.4142135, 1.4142136, 2, Math.E, 3,
  7.25, 10, 99.5, 300000, 1234567.891, 1e15, 1e300,
];
const detmath = {
  exp: [-750, -708, -100, -1, -1e-9, 0, 1e-9, 0.5, 1, 2.5, 10, 100, 700, 709, 710].map((x) => [f(x), f(exp(x))]),
  log: detInputs.map((x) => [f(x), f(log(x))]),
  pow: [
    [0, 2],
    [0, -1],
    [1, 123],
    [2, 0],
    [2, 10],
    [10, 0.6],
    [158068, 0.6],
    [25000, 0.73],
    [1, 0.73],
    [123456.789, 0.73],
    [0.5, 3.3],
    [300000, 2.5],
  ].map(([x, y]) => [f(x), f(y), f(pow(x, y))]),
  pow2: [-1100, -1022, -1, 0, 1, 52, 1023, 1024].map((n) => [n, f(pow2(n))]),
  atan2: [
    [0, 1],
    [0, -1],
    [1, 0],
    [-1, 0],
    [1, 1],
    [1, -1],
    [-1, -1],
    [0.3, 0.9],
    [5, 0.01],
    [-2.5, 7],
  ].map(([y, x]) => [f(y), f(x), f(atan2(y, x))]),
  sigmoid: [
    [Math.log(100), 2.5, Math.log(300000)],
    [log(1000000), 2.5, log(300000)],
    [0, 1, 0],
  ].map(([v, d, m]) => [f(v), f(d), f(m), f(sigmoid(v, d, m))]),
};

// ---- PseudoRandom -------------------------------------------------------------

const seeds = [0, 1, 123, 999, -5, 2 ** 32 + 7, 3.7, -3.7, 2 ** 31, simpleHash("abc"), simpleHash("gameID123") + 1];
const prng = seeds.map((seed) => {
  const r = new PseudoRandom(seed);
  const next = Array.from({ length: 40 }, () => f(r.next()));
  const ints = Array.from({ length: 20 }, () => r.nextInt(0, 7));
  const ids = Array.from({ length: 5 }, () => r.nextID());
  const shuffled = r.shuffleArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  return { seed: f(seed), next, ints, ids, shuffled };
});

// ---- simpleHash ---------------------------------------------------------------

const hashStrings = ["", "a", "abc", "gameID123", "The quick brown fox jumps over the lazy dog", "Zażółć gęślą jaźń", "x😀y"];
const hashes = hashStrings.map((s) => [s, simpleHash(s)]);

// ---- FlatBinaryHeap -------------------------------------------------------------
// Priorities shaped like AttackExecution's: (rand(0..6)+10) * factor + tick,
// which produces many exact and float32-level ties.

const heapRand = new PseudoRandom(42);
const heap = new FlatBinaryHeap(4); // small capacity to exercise grow()
const heapOps: V[] = [];
for (let step = 0; step < 400; step++) {
  if (heap.size() > 0 && heapRand.nextInt(0, 3) === 0) {
    heapOps.push(["d", heap.dequeue()]);
  } else {
    const tile = heapRand.nextInt(0, 1_000_000);
    const numOwned = heapRand.nextInt(0, 4);
    const mag = [0, 1, 1.5, 2][heapRand.nextInt(0, 4)];
    const tick = 1000 + Math.floor(step / 10);
    const pri = (heapRand.nextInt(0, 7) + 10) * (1 - numOwned * 0.5 + mag / 2) + tick;
    heap.enqueue(tile, pri);
    heapOps.push(["e", tile, f(pri)]);
  }
}
while (heap.size() > 0) heapOps.push(["d", heap.dequeue()]);

// ---- Stable sort ----------------------------------------------------------------

const sortRand = new PseudoRandom(7);
const sortInput = Array.from({ length: 60 }, (_, i) => ({ id: i + 1, key: sortRand.nextInt(0, 6) }));
const sorted = [...sortInput].sort((a, b) => a.key - b.key).map((o) => o.id);

// ---- Emit -------------------------------------------------------------------------

const out = `-- AUTO-GENERATED by tools/gen-vectors.ts from upstream OpenFrontIO. Do not edit.
-- Doubles are {hi, lo} IEEE-754 words.
return ${lua({
  detmath,
  prng,
  hashes,
  heapOps,
  sort: { keys: sortInput.map((o) => o.key), expected: sorted },
} as unknown as V)}
`;
const outFile = path.resolve(here, "../tests/Vectors.luau");
fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, out);
console.log(`wrote ${path.relative(process.cwd(), outFile)} (${(out.length / 1024).toFixed(1)} KB)`);
