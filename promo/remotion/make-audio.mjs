// Original synthwave-style trailer track + hits, rendered to WAV (no third-party audio).
// Usage: node make-audio.mjs [out.wav]    30 s, 128 BPM, hits land on the cut times used in src/Promo.tsx
import fs from "node:fs";

const SR = 44100;
const DUR = 30;
const BPM = 128;
const BEAT = 60 / BPM;
const N = SR * DUR;
const L = new Float32Array(N);
const R = new Float32Array(N);
let seed = 99;
const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296) * 2 - 1;

const add = (t, fn, len, pan = 0) => {
  const s0 = Math.floor(t * SR);
  const n = Math.floor(len * SR);
  const gl = 1 - Math.max(0, pan), gr = 1 + Math.min(0, pan);
  for (let i = 0; i < n && s0 + i < N; i++) {
    const v = fn(i / SR, i / n);
    L[s0 + i] += v * gl;
    R[s0 + i] += v * gr;
  }
};
const hz = (m) => 440 * Math.pow(2, (m - 69) / 12);
const saw = (p) => 2 * (p - Math.floor(p + 0.5));
const sq = (p) => (p % 1 < 0.5 ? 1 : -1);
const lp = () => { let y = 0; return (x, a) => (y += a * (x - y)); };

// ---- drums ----
const kick = (t, g = 1) =>
  add(t, (x, u) => {
    const f = 45 + 110 * Math.exp(-x * 35);
    return Math.sin(2 * Math.PI * f * x) * Math.exp(-x * 9) * g + (x < 0.005 ? rnd() * 0.3 * g : 0);
  }, 0.4);
const hat = (t, g = 0.25, open = false) => {
  const f = lp();
  add(t, (x) => { const n = rnd(); return (n - f(n, 0.35)) * Math.exp(-x * (open ? 14 : 55)) * g; }, open ? 0.25 : 0.08);
};
const snare = (t, g = 0.6) => {
  const f = lp();
  add(t, (x) => (rnd() * 0.8 + Math.sin(2 * Math.PI * 190 * x) * 0.5) * Math.exp(-x * 18) * g - f(rnd(), 0.02) * 0.0, 0.3);
};
const boom = (t, g = 1) => {
  const f = lp();
  add(t, (x) => (Math.sin(2 * Math.PI * (70 * Math.exp(-x * 3) + 28) * x) * Math.exp(-x * 2.2) + f(rnd(), 0.08) * Math.exp(-x * 5) * 0.8) * g, 1.6);
};
const whoosh = (t, len, g = 0.5, up = true) => {
  const f = lp();
  add(t, (x, u) => { const a = up ? u : 1 - u; return f(rnd(), 0.02 + 0.5 * a * a) * (up ? u : (1 - u) * 1.0) * g * 2; }, len);
};

// ---- harmony: Am | F | C | G, one chord per 4 beats ----
const roots = [45, 41, 36, 43]; // A2 F2 C2 G2 (bass)
const chords = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]];
const bass = (t, m, len, g = 0.5) => {
  const f = lp();
  add(t, (x, u) => f(saw(hz(m) * x) + sq(hz(m) * 0.5 * x) * 0.4, 0.12 + 0.2 * Math.exp(-x * 14)) * Math.exp(-x * 4) * g, len);
};
const lead = (t, m, len, g = 0.12, pan = 0) => {
  add(t, (x, u) => {
    const p = hz(m) * x;
    const vib = 1 + 0.003 * Math.sin(2 * Math.PI * 5.5 * x);
    return (sq(p * vib) * 0.5 + saw(p * 1.005) * 0.5) * Math.min(1, x * 80) * Math.exp(-x * 5) * g;
  }, len, pan);
};
const pad = (t, notes, len, g = 0.07) => {
  for (const m of notes) {
    const f = lp();
    add(t, (x, u) => f(saw(hz(m) * x) + saw(hz(m) * 1.004 * x), 0.06) * Math.min(1, x * 3) * Math.min(1, (1 - u) * 3) * g, len);
  }
};

const totalBeats = DUR / BEAT;
const DROP = 6; // beat of the first drop (matches cut at 2.81 s)

// intro: heartbeat + riser + low pad
for (let b = 0; b < DROP; b += 1) kick(b * BEAT, 0.45 + b * 0.05);
whoosh(0, DROP * BEAT, 0.55, true);
pad(0, chords[0], DROP * BEAT, 0.05);
boom(DROP * BEAT, 1.0);

for (let b = DROP; b < totalBeats - 4; b++) {
  const t = b * BEAT;
  const bar = Math.floor((b - DROP) / 4);
  const chord = chords[bar % 4];
  const root = roots[bar % 4];
  kick(t, 0.95);
  hat(t + BEAT / 2, 0.22);
  if ((b - DROP) % 2 === 1) snare(t, 0.5);
  if ((b - DROP) % 4 === 3) hat(t + BEAT * 0.75, 0.2, true);
  // bass 8ths
  bass(t, root, BEAT / 2 * 0.9, 0.55);
  bass(t + BEAT / 2, root + ((b % 2) ? 12 : 0), BEAT / 2 * 0.9, 0.45);
  // arp 16ths (from beat 12)
  if (b >= 12) {
    for (let i = 0; i < 4; i++) {
      const note = chord[(i + (b % 2) * 2) % 3] + (i === 3 ? 12 : 0) + 12;
      lead(t + (i * BEAT) / 4, note, BEAT / 4 * 0.9, 0.1, i % 2 ? 0.4 : -0.4);
    }
  }
  if ((b - DROP) % 4 === 0) pad(t, chord, BEAT * 4, 0.06);
}

// impacts on the cuts (seconds)
for (const c of [5.62, 9.375, 13.59, 18.28, 24.375]) { boom(c, 0.8); whoosh(c - 0.6, 0.6, 0.35, true); }

// finale: big chord + ring-out from 24.375 s
pad(24.375, [57, 60, 64, 69], 5.6, 0.09);
lead(24.375, 81, 1.5, 0.12);

// master: soft clip + fade out
let peak = 0;
for (let i = 0; i < N; i++) {
  const fade = i > N - SR * 1.2 ? (N - i) / (SR * 1.2) : 1;
  L[i] = Math.tanh(L[i] * 0.9) * fade;
  R[i] = Math.tanh(R[i] * 0.9) * fade;
  peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i]));
}
const k = 0.89 / peak;
const buf = Buffer.alloc(44 + N * 4);
buf.write("RIFF", 0); buf.writeUInt32LE(36 + N * 4, 4); buf.write("WAVEfmt ", 8);
buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22);
buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34);
buf.write("data", 36); buf.writeUInt32LE(N * 4, 40);
for (let i = 0; i < N; i++) {
  buf.writeInt16LE(Math.max(-32767, Math.min(32767, Math.round(L[i] * k * 32767))), 44 + i * 4);
  buf.writeInt16LE(Math.max(-32767, Math.min(32767, Math.round(R[i] * k * 32767))), 46 + i * 4);
}
const out = process.argv[2] ?? "public/track.wav";
fs.writeFileSync(out, buf);
console.log("wrote", out, (buf.length / 1e6).toFixed(1) + " MB");
