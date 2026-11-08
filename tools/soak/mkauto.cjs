const fs = require("fs");
const dir = __dirname; // tools/soak
const policy = JSON.parse(fs.readFileSync(dir + "/policy.json", "utf8"));
let lua = "{\n";
for (const [k, probs] of Object.entries(policy)) {
  const parts = Object.entries(probs).map(([a, p]) => `${a} = ${Math.round(p * 1000) / 1000}`);
  lua += `\t["${k}"] = { ${parts.join(", ")} },\n`;
}
lua += "}";
const src = fs.readFileSync(dir + "/AutoPlay.luau", "utf8").replace("--[[POLICY]]", lua);
const xml = `<roblox version="4"><Item class="ModuleScript" referent="RBXAUTO"><Properties><string name="Name">AutoPlay</string><ProtectedString name="Source"><![CDATA[${src}]]></ProtectedString></Properties></Item></roblox>`;
fs.writeFileSync(dir + "/AutoPlay.rbxmx", xml);
console.log("ok", src.length);
