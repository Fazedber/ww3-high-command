// Adds a soundtrack to a promo video from tools/record-sim.mts.
//
// Usage: node tools/add-audio.mjs <video.mp4> [out.mp4]
//   BED=0  game sound effects only (music gets added on the platform instead)
//
// Reads <video>.events.json (sound cues logged by the recorder), mixes the
// upstream sound effects (OpenFront resources/sounds, CC BY-SA 4.0) at those
// frames over a synthesized war-drum bed, and muxes the result into the video.
// ffmpeg must be on PATH; OpenFrontIO is expected next to this repo.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const SOUNDS = path.join(here, "../../OpenFrontIO/resources/sounds/effects");
const RATE = 44100;

const video = process.argv[2];
const out = process.argv[3] ?? video.replace(/\.mp4$/, "") + "-sound.mp4";
const meta = JSON.parse(fs.readFileSync(video + ".events.json", "utf8"));
const duration = meta.frames / meta.fps;
const N = Math.ceil(duration * RATE);
const L = new Float32Array(N), R = new Float32Array(N);

// Per-cue gain and minimum spacing (s): a MIRV or a mass elimination would
// otherwise stack dozens of copies (same idea as upstream's AudioMixer budget).
const CUES = {
  "atom-hit": { gain: 0.9, gap: 0.22 },
  "hydrogen-hit": { gain: 1.0, gap: 0.5 },
  "atom-launch": { gain: 0.45, gap: 0.5 },
  "hydrogen-launch": { gain: 0.5, gap: 0.6 },
  "mirv-launch": { gain: 0.6, gap: 6.0, maxLen: 6 }, // the upstream cue is a 19.5 s barrage
  conquered: { gain: 0.35, gap: 1.1 },
  "game-start": { gain: 0.7, gap: 1 },
  victory: { gain: 0.8, gap: 1 },
  "nuke-warning": { gain: 0.45, gap: 3 },
};

const cache = new Map();
function load(cue) {
  if (!cache.has(cue)) {
    const raw = execFileSync("ffmpeg", ["-v", "error", "-i", path.join(SOUNDS, cue + ".mp3"), "-f", "f32le", "-ac", "2", "-ar", String(RATE), "-"], { maxBuffer: 1 << 28 });
    cache.set(cue, new Float32Array(raw.buffer, raw.byteOffset, raw.byteLength / 4));
  }
  return cache.get(cue);
}

// Ducking envelope: the bed dips under big explosions.
const duck = new Float32Array(N).fill(1);
const last = {};
function place(cue, t) {
  const c = CUES[cue];
  if (!c) return;
  if (last[cue] !== undefined && t - last[cue] < c.gap) return;
  last[cue] = t;
  const pcm = load(cue);
  const start = Math.floor(t * RATE);
  const len = Math.min(pcm.length / 2, c.maxLen ? c.maxLen * RATE : Infinity);
  for (let i = 0; i < len && start + i < N; i++) {
    // Trimmed cues fade out over their last second.
    const g = c.gain * Math.min(1, (len - i) / RATE);
    L[start + i] += pcm[2 * i] * g;
    R[start + i] += pcm[2 * i + 1] * g;
  }
  if (cue.endsWith("-hit")) {
    for (let i = 0; i < RATE * 1.2 && start + i < N; i++) duck[start + i] = Math.min(duck[start + i], 0.45 + 0.55 * (i / (RATE * 1.2)));
  }
}

// The first incoming nuke of a barrage gets the upstream siren a little ahead
// of its launch sound.
const events = [...meta.events].sort((a, b) => a.f - b.f);
const firstLaunch = events.find((e) => e.cue.endsWith("-launch"));
place("game-start", 0.15);
if (firstLaunch) place("nuke-warning", Math.max(0.3, firstLaunch.f / meta.fps - 0.8));
for (const e of events) place(e.cue, e.f / meta.fps);
if (meta.winner) place("victory", Math.max(0, duration - 2.2));

// Bed: low drone plus war drums at 96 bpm (kick on 1, "and" of 2, 3; toms on 4).
const BEAT = 60 / 96;
function kick(t0, gain, f0 = 110, f1 = 42, len = 0.45) {
  const s = Math.floor(t0 * RATE);
  let phase = 0;
  for (let i = 0; i < len * RATE && s + i < N; i++) {
    const t = i / RATE;
    const f = f1 + (f0 - f1) * Math.exp(-t * 18);
    phase += (2 * Math.PI * f) / RATE;
    const v = Math.sin(phase) * Math.exp(-t * 7) * gain;
    L[s + i] += v * duck[s + i];
    R[s + i] += v * duck[s + i];
  }
}
let seed = 7;
const noise = () => ((seed = (seed * 16807) % 2147483647) / 2147483647) * 2 - 1;
function snare(t0, gain) {
  const s = Math.floor(t0 * RATE);
  let lp = 0;
  for (let i = 0; i < 0.22 * RATE && s + i < N; i++) {
    const t = i / RATE;
    lp += 0.35 * (noise() - lp);
    const v = lp * Math.exp(-t * 16) * gain;
    L[s + i] += v * duck[s + i];
    R[s + i] += v * 0.85 * duck[s + i];
  }
}
const BED = process.env.BED !== "0";
const drumsFrom = 0.9, drumsTo = BED ? duration - 2.4 : 0;
for (let b = 0; drumsFrom + b * BEAT < drumsTo; b++) {
  const t = drumsFrom + b * BEAT;
  const inBar = b % 4;
  const build = Math.min(1, 0.55 + t / 20);
  if (inBar === 0 || inBar === 2) kick(t, 0.5 * build);
  if (inBar === 1) kick(t + BEAT / 2, 0.32 * build);
  if (inBar === 3) { kick(t, 0.28 * build, 180, 90, 0.3); kick(t + BEAT / 2, 0.24 * build, 160, 80, 0.3); }
  if (inBar === 1 || inBar === 3) snare(t, 0.11 * build);
}
for (let i = 0; BED && i < N; i++) {
  const t = i / RATE;
  const lfo = 0.6 + 0.4 * Math.sin(2 * Math.PI * 0.11 * t);
  const fade = Math.min(1, t / 1.5) * Math.min(1, (duration - t) / 1.5);
  const d = (Math.sin(2 * Math.PI * 55 * t) * 0.5 + Math.sin(2 * Math.PI * 82.41 * t) * 0.3 + Math.sin(2 * Math.PI * 110.3 * t) * 0.2) * 0.1 * lfo * fade * duck[i];
  L[i] += d;
  R[i] += d;
}

// Soft clip, then 16-bit WAV.
const wav = Buffer.alloc(44 + N * 4);
wav.write("RIFF", 0); wav.writeUInt32LE(36 + N * 4, 4); wav.write("WAVE", 8);
wav.write("fmt ", 12); wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(2, 22);
wav.writeUInt32LE(RATE, 24); wav.writeUInt32LE(RATE * 4, 28); wav.writeUInt16LE(4, 32); wav.writeUInt16LE(16, 34);
wav.write("data", 36); wav.writeUInt32LE(N * 4, 40);
for (let i = 0; i < N; i++) {
  wav.writeInt16LE(Math.round(Math.tanh(L[i]) * 32000), 44 + i * 4);
  wav.writeInt16LE(Math.round(Math.tanh(R[i]) * 32000), 46 + i * 4);
}
const tmp = out + ".wav";
fs.writeFileSync(tmp, wav);
execFileSync("ffmpeg", ["-v", "error", "-y", "-i", video, "-i", tmp, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-af", "loudnorm=I=-14:TP=-1.5:LRA=11", "-shortest", "-movflags", "+faststart", out]);
fs.unlinkSync(tmp);
console.log(`${out}: ${duration.toFixed(1)} s, ${events.length} cues`);
