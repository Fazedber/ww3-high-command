// Synthesises the game's own sound effects (no third-party audio) as 16-bit mono WAV.
// Usage: node tools/make-sfx.mjs [outDir]   (default: art/sfx)
//   capture.wav   - 8-bit "pum" tick for conquered territory
//   alert.wav     - two-tone pixel alarm when someone attacks you
//   warcry.wav    - crowd "aaah" charge with stomping boots (when you attack)
import fs from "node:fs";
import path from "node:path";

const SR = 22050;
const outDir = process.argv[2] ?? "art/sfx";
fs.mkdirSync(outDir, { recursive: true });

let seed = 1234567;
const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);

function writeWav(name, samples) {
  let peak = 0;
  for (const s of samples) peak = Math.max(peak, Math.abs(s));
  const k = peak > 0 ? 0.85 / peak : 1;
  const buf = Buffer.alloc(44 + samples.length * 2);
  buf.write("RIFF", 0);
  buf.writeUInt32LE(36 + samples.length * 2, 4);
  buf.write("WAVEfmt ", 8);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(SR, 24);
  buf.writeUInt32LE(SR * 2, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write("data", 36);
  buf.writeUInt32LE(samples.length * 2, 40);
  samples.forEach((s, i) => buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, s * k)) * 32767), 44 + i * 2));
  fs.writeFileSync(path.join(outDir, name), buf);
  console.log(name, (buf.length / 1024).toFixed(1) + " KB", (samples.length / SR).toFixed(2) + " s");
}

const square = (phase, duty = 0.5) => ((phase % 1) < duty ? 1 : -1);

// --- capture: pitch-dropping square blip with a soft click ---
function capture() {
  const n = Math.floor(SR * 0.1);
  const out = new Float32Array(n);
  let phase = 0;
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    const f = 340 * Math.pow(0.45, t / 0.1);
    phase += f / SR;
    const env = Math.exp(-t * 28) * Math.min(1, t * 400);
    out[i] = square(phase, 0.25) * env;
  }
  return out;
}

// --- alert: "bee-boop" x2 ---
function alert() {
  const notes = [[880, 0.11], [0, 0.03], [660, 0.11], [0, 0.07], [880, 0.11], [0, 0.03], [660, 0.16]];
  const total = notes.reduce((a, n) => a + n[1], 0);
  const out = new Float32Array(Math.floor(SR * total));
  let i = 0, phase = 0;
  for (const [f, d] of notes) {
    const len = Math.floor(SR * d);
    for (let j = 0; j < len && i < out.length; j++, i++) {
      if (f === 0) continue;
      phase += f / SR;
      const t = j / SR;
      const env = Math.min(1, t * 600) * Math.min(1, (d - t) * 300);
      out[i] = square(phase, 0.5) * env * 0.8;
    }
  }
  return out;
}

// --- warcry: crowd of sawtooth voices through vowel formants + boot stomps ---
function biquadBP(f0, q) {
  const w0 = (2 * Math.PI * f0) / SR;
  const alpha = Math.sin(w0) / (2 * q);
  const b0 = alpha, b1 = 0, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * Math.cos(w0), a2 = 1 - alpha;
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  return (x) => {
    const y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}
function warcry() {
  const dur = 1.15;
  const n = Math.floor(SR * dur);
  const voices = [];
  for (let v = 0; v < 9; v++) {
    voices.push({
      f0: 120 + rnd() * 110,
      start: rnd() * 0.14,
      rise: 0.1 + rnd() * 0.18,
      vib: 5 + rnd() * 1.5,
      ph: rnd(),
      vph: rnd() * 6.28,
      gain: 0.6 + rnd() * 0.4,
    });
  }
  const formants = [biquadBP(780, 7), biquadBP(1180, 9), biquadBP(2800, 10)];
  const fg = [1.0, 0.7, 0.25];
  const raw = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    let s = 0;
    for (const v of voices) {
      const tt = t - v.start;
      if (tt < 0) continue;
      const f = v.f0 * (1 + v.rise * Math.min(1, tt / 0.6)) * (1 + 0.015 * Math.sin(2 * Math.PI * v.vib * t + v.vph));
      v.ph += f / SR;
      const saw = 2 * (v.ph % 1) - 1;
      const env = Math.min(1, tt / 0.1) * Math.min(1, Math.max(0, (dur - 0.2 - t) / 0.0001 + 1) ) * Math.min(1, (dur - t) / 0.28);
      s += saw * env * v.gain;
    }
    s += (rnd() * 2 - 1) * 0.12; // breath
    raw[i] = s / voices.length;
  }
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    let y = 0;
    for (let k = 0; k < formants.length; k++) y += formants[k](raw[i]) * fg[k];
    out[i] = y;
  }
  // boot stomps: low-passed noise thumps, 7 per second
  const lp = { y: 0 };
  for (let hit = 0; hit * (1 / 7) < dur - 0.1; hit++) {
    const start = Math.floor(SR * (0.03 + hit / 7 + (rnd() - 0.5) * 0.02));
    const len = Math.floor(SR * 0.09);
    for (let j = 0; j < len && start + j < n; j++) {
      lp.y += 0.18 * ((rnd() * 2 - 1) - lp.y);
      out[start + j] += lp.y * Math.exp(-j / (SR * 0.025)) * 1.6;
    }
  }
  return out;
}

writeWav("capture.wav", capture());
writeWav("alert.wav", alert());
writeWav("warcry.wav", warcry());
