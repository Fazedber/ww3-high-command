// Builds Roblox model files from src/ for import into Studio.
//
// Usage: node tools/build.mjs
//
// Layout (Rojo-like):
//   src/shared/**           -> build/Shared.rbxmx   (Folder "Shared", import into ReplicatedStorage)
//   src/client/**            -> build/Client.rbxmx  (LocalScripts + modules, import into StarterPlayerScripts)
//   src/server/**            -> build/Server.rbxmx  (Scripts + Core modules, import into ServerScriptService)
//   tests/**                 -> build/Tests.rbxmx   (Folder "Tests", import into ServerStorage)
//   src/maps/*.luau          -> build/Maps.rbxmx    (Folder "Maps", import into ServerStorage)
//
// Inside src/shared, directories become Folders and *.luau files become
// ModuleScripts named after the file.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const buildDir = path.join(root, "build");

let referent = 0;

function xmlEscape(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// CDATA cannot contain "]]>": split it across two CDATA sections.
function cdata(s) {
  return `<![CDATA[${s.replace(/]]>/g, "]]]]><![CDATA[>")}]]>`;
}

function item(className, name, children = [], source) {
  const props = [`<string name="Name">${xmlEscape(name)}</string>`];
  if (source !== undefined) {
    props.push(`<ProtectedString name="Source">${cdata(source)}</ProtectedString>`);
  }
  return `<Item class="${className}" referent="RBX${referent++}"><Properties>${props.join("")}</Properties>${children.join("")}</Item>`;
}

function document(items) {
  return `<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">${items.join("")}</roblox>`;
}

function read(file) {
  // Normalise line endings; git on Windows may check files out as CRLF.
  return fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");
}

function sharedTree(dir, name) {
  const children = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      children.push(sharedTree(full, entry.name));
    } else if (entry.name.endsWith(".luau")) {
      children.push(item("ModuleScript", entry.name.replace(/\.luau$/, ""), [], read(full)));
    }
  }
  return item("Folder", name, children);
}

// Script tree: directories -> Folders, *<scriptSuffix> -> scriptClass,
// other *.luau -> ModuleScripts. Returns the top-level items.
function scriptTree(dir, scriptSuffix, scriptClass) {
  if (!fs.existsSync(dir)) return [];
  const items = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      items.push(item("Folder", entry.name, scriptTree(full, scriptSuffix, scriptClass)));
    } else if (entry.name.endsWith(scriptSuffix)) {
      items.push(item(scriptClass, entry.name.slice(0, -scriptSuffix.length), [], read(full)));
    } else if (entry.name.endsWith(".luau")) {
      items.push(item("ModuleScript", entry.name.slice(0, -".luau".length), [], read(full)));
    }
  }
  return items;
}


function write(name, items) {
  const file = path.join(buildDir, name);
  fs.writeFileSync(file, document(items));
  console.log(`${path.relative(root, file)}  ${(fs.statSync(file).size / 1024).toFixed(0)} KB  (${items.length} top-level)`);
}

fs.mkdirSync(buildDir, { recursive: true });
// Main waits for every client module by name (CLIENT_MODULES); keep in sync.
{
  const mods = fs.readdirSync(path.join(root, "src/client")).filter((f) => f.endsWith(".luau") && !f.endsWith(".client.luau")).map((f) => f.slice(0, -5)).sort();
  const main = read(path.join(root, "src/client/Main.client.luau"));
  const m = /local CLIENT_MODULES = {([^}]*)}/.exec(main);
  const listed = m ? [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]).sort() : [];
  if (JSON.stringify(mods) !== JSON.stringify(listed)) {
    throw new Error("Main.client.luau CLIENT_MODULES is out of date; expected: " + mods.join(", "));
  }
}
write("Shared.rbxmx", [sharedTree(path.join(root, "src/shared"), "Shared")]);
write("Client.rbxmx", scriptTree(path.join(root, "src/client"), ".client.luau", "LocalScript"));
write("Server.rbxmx", scriptTree(path.join(root, "src/server"), ".server.luau", "Script"));
// Golden-vector specs; import into ServerStorage (never replicated to players).
write("Tests.rbxmx", [sharedTree(path.join(root, "tests"), "Tests")]);
write("Maps.rbxmx", [sharedTree(path.join(root, "src/maps"), "Maps")]);

// Whole place: every build above in its service, so a fresh Studio session is
// one file (build/OpenFront.rbxlx) instead of five imports.
const client = scriptTree(path.join(root, "src/client"), ".client.luau", "LocalScript");
const place = [
  item("ReplicatedStorage", "ReplicatedStorage", [sharedTree(path.join(root, "src/shared"), "Shared")]),
  item("ServerScriptService", "ServerScriptService", scriptTree(path.join(root, "src/server"), ".server.luau", "Script")),
  item("ServerStorage", "ServerStorage", [
    sharedTree(path.join(root, "tests"), "Tests"),
    sharedTree(path.join(root, "src/maps"), "Maps"),
  ]),
  item("StarterPlayer", "StarterPlayer", [item("StarterPlayerScripts", "StarterPlayerScripts", client)]),
];
write("OpenFront.rbxlx", place);
