// Upload build/OpenFront.rbxlx to the published place through Open Cloud.
//   node tools/upload-place.mjs            -> Published (live)
//   node tools/upload-place.mjs --saved    -> Saved only (not live)
// The API key is read from ~/.roblox-keys/ww3-place-upload.key (never stored in the repo)
// or from the ROBLOX_API_KEY env var. Close Studio first if you get HTTP 409.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const UNIVERSE_ID = 10775208930;
const PLACE_ID = 102627842655633;

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const file = join(root, "build", "OpenFront.rbxlx");
const versionType = process.argv.includes("--saved") ? "Saved" : "Published";

let key = process.env.ROBLOX_API_KEY;
if (!key) {
	try {
		key = readFileSync(join(homedir(), ".roblox-keys", "ww3-place-upload.key"), "utf8").trim();
	} catch {
		console.error("No API key: set ROBLOX_API_KEY or create ~/.roblox-keys/ww3-place-upload.key");
		process.exit(1);
	}
}

const body = readFileSync(file);
console.log(`Uploading ${file} (${(body.length / 1048576).toFixed(1)} MB) as ${versionType}...`);
const res = await fetch(
	`https://apis.roblox.com/universes/v1/${UNIVERSE_ID}/places/${PLACE_ID}/versions?versionType=${versionType}`,
	{ method: "POST", headers: { "x-api-key": key, "Content-Type": "application/xml" }, body },
);
const text = await res.text();
console.log(`HTTP ${res.status} ${text}`);
if (!res.ok) process.exit(1);
