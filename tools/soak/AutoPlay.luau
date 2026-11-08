-- Soak-test autoplayer (test only, never shipped). Decisions come from a
-- policy precomputed with TypeSafe Jev (POLICY: bucket -> action
-- probabilities); 20 % of turns pick a uniform random action for coverage,
-- and every few turns a malformed intent probes server validation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local POLICY = --[[POLICY]]

local ACTIONS = {}
for action in POLICY["early|none|low|safe|none"] do
	table.insert(ACTIONS, action)
end
table.sort(ACTIONS)

local AutoPlay = {}
local stats = { decisions = 0, actions = {}, failed = {}, errors = {}, fuzz = 0, started = os.clock() }
AutoPlay.stats = stats

local rng = Random.new()
local function pick(list)
	if #list == 0 then
		return nil
	end
	return list[rng:NextInteger(1, #list)]
end
local function intent(t)
	Net.Intent:FireServer(t)
end

-- Owner -> sample of tiles (cached a few seconds).
local ownerCache, ownerAt = nil, 0
local function ownerTiles()
	if ownerCache and os.clock() - ownerAt < 4 then
		return ownerCache
	end
	local c = _G.OpenFrontClient
	local r = c.renderer
	local n = r.W * r.H
	local out = {}
	local off = rng:NextInteger(0, 4)
	for t = off, n - 1, 5 do
		local o = r:ownerAt(t)
		if o > 0 then
			local l = out[o]
			if l == nil then
				l = {}
				out[o] = l
			end
			if #l < 60 then
				table.insert(l, t)
			elseif rng:NextNumber() < 0.02 then
				l[rng:NextInteger(1, 60)] = t
			end
		end
	end
	ownerCache, ownerAt = out, os.clock()
	return out
end

local function ctx()
	local c = _G.OpenFrontClient
	local s = c.snapshot()
	local me = s.mySmallID
	local allies = {}
	for _, a in (s.myInfo and s.myInfo.alliances) or {} do
		allies[a.other] = true
	end
	local neighbours = {}
	for id in s.bordering or {} do
		if id ~= me and s.stats[id] and s.stats[id].tiles > 0 then
			table.insert(neighbours, id)
		end
	end
	local others = {}
	for id, st in s.stats do
		if id ~= me and st.tiles > 0 then
			table.insert(others, id)
		end
	end
	return { c = c, s = s, me = me, mine = s.stats[me], allies = allies, neighbours = neighbours, others = others, map = c.gameMap, renderer = c.renderer }
end

local function query(tile)
	local ok, r = pcall(function()
		return Net.Query:InvokeServer({ tile = tile })
	end)
	return ok and r or nil
end

local function tryBuild(k, unit: string, wantUpgrade: boolean?)
	local mine = ownerTiles()[k.me] or {}
	for _ = 1, 6 do
		local t = pick(mine)
		if t == nil then
			return false
		end
		local r = query(t)
		for _, u in (r and r.units) or {} do
			if (unit == "*" or u.unit == unit) and ((wantUpgrade and u.canUpgrade) or (not wantUpgrade and u.canBuild)) then
				intent({ type = "place", unit = u.unit, tile = t, amount = if wantUpgrade and rng:NextNumber() < 0.3 then 5 else nil, rocketDirectionUp = rng:NextNumber() < 0.5 })
				return true
			end
		end
	end
	return false
end

local function neutralNearMe(k)
	local mine = ownerTiles()[k.me] or {}
	local map, r = k.map, k.renderer
	local W = r.W
	for _ = 1, 30 do
		local t = pick(mine)
		if t == nil then
			return nil
		end
		local x, y = t % W, t // W
		for _ = 1, 8 do
			local nx, ny = x + rng:NextInteger(-3, 3), y + rng:NextInteger(-3, 3)
			if nx >= 0 and ny >= 0 and nx < W and ny < r.H then
				local nt = ny * W + nx
				if r:ownerAt(nt) == 0 and map:isLand(nt) then
					return nt
				end
			end
		end
	end
	return nil
end

local function weakest(k, list)
	local best, bt = nil, math.huge
	for _, id in list do
		local st = k.s.stats[id]
		if st and st.troops < bt and not k.allies[id] then
			best, bt = id, st.troops
		end
	end
	return best
end
local function strongest(k)
	local best, bt = nil, -1
	for _, id in k.others do
		local st = k.s.stats[id]
		if st.tiles > bt and not k.allies[id] then
			best, bt = id, st.tiles
		end
	end
	return best
end
local function ratio()
	return rng:NextNumber(0.15, 0.5)
end

local ACT = {}
function ACT.expand(k)
	local t = neutralNearMe(k)
	if t then
		intent({ type = "click", tile = t, ratio = ratio() })
		return true
	end
	return false
end
function ACT.attack_weak(k)
	local id = weakest(k, k.neighbours)
	if id then
		intent({ type = "attack", targetSmallID = id, ratio = ratio() })
		return true
	end
	return ACT.expand(k)
end
function ACT.boat_attack(k)
	local id = pick(k.others)
	local t = id and pick(ownerTiles()[id] or {})
	if t then
		intent({ type = "boat_at", tile = t, ratio = ratio() })
		return true
	end
	return false
end
for name, unit in { build_city = "City", build_port = "Port", build_factory = "Factory", build_defense = "Defense Post", build_silo = "Missile Silo", build_sam = "SAM Launcher", build_warship = "Warship" } do
	ACT[name] = function(k)
		return tryBuild(k, unit)
	end
end
function ACT.upgrade(k)
	return tryBuild(k, "*", true)
end
local function nuke(unit)
	return function(k)
		local id = strongest(k)
		local t = id and pick(ownerTiles()[id] or {})
		if t then
			intent({ type = "place", unit = unit, tile = t, amount = if unit == "Atom Bomb" and rng:NextNumber() < 0.2 then 5 else nil, rocketDirectionUp = rng:NextNumber() < 0.5 })
			return true
		end
		return false
	end
end
ACT.atom_bomb = nuke("Atom Bomb")
ACT.hydrogen_bomb = nuke("Hydrogen Bomb")
ACT.mirv = nuke("MIRV")
function ACT.request_alliance(k)
	local id = pick(if #k.neighbours > 0 then k.neighbours else k.others)
	if id and not k.allies[id] then
		intent({ type = "alliance_request", target = id })
		return true
	end
	return false
end
function ACT.accept_alliance(k)
	local id = ((k.s.myInfo and k.s.myInfo.requestsIn) or {})[1]
	if id then
		intent({ type = if rng:NextNumber() < 0.85 then "alliance_request" else "alliance_reject", target = id })
		return true
	end
	return false
end
function ACT.break_alliance(k)
	local a = pick((k.s.myInfo and k.s.myInfo.alliances) or {})
	if a then
		intent({ type = if rng:NextNumber() < 0.5 then "break_alliance" else "alliance_extend", target = a.other })
		return true
	end
	return false
end
function ACT.donate(k)
	local ids = {}
	for id in k.allies do
		table.insert(ids, id)
	end
	local id = pick(ids)
	if id then
		if rng:NextNumber() < 0.5 then
			intent({ type = "donate_gold", target = id, amount = math.floor(k.mine.gold * 0.1) + 1 })
		else
			intent({ type = "donate_troops", target = id, amount = math.floor(k.mine.troops * 0.1) + 1 })
		end
		return true
	end
	return false
end
function ACT.embargo(k)
	local id = pick(k.others)
	if id then
		intent({ type = "embargo", target = id, action = if rng:NextNumber() < 0.7 then "start" else "stop" })
		if rng:NextNumber() < 0.1 then
			intent({ type = "embargo_all", action = if rng:NextNumber() < 0.5 then "start" else "stop" })
		end
		return true
	end
	return false
end
function ACT.emoji(k)
	local id = pick(k.others)
	intent({ type = "emoji", target = if id and rng:NextNumber() < 0.7 then id else 0, emoji = rng:NextInteger(0, 30) })
	return true
end
function ACT.quick_chat(k)
	local id = pick(k.others)
	if id then
		local keys = { "help.troops", "help.gold", "help.no_attack", "attack.attack", "greet.hello", "misc.go" }
		intent({ type = "quick_chat", target = id, key = pick(keys), chatTarget = pick(k.others) })
		intent({ type = "target_player", target = pick(k.others) })
		return true
	end
	return false
end
function ACT.cancel_attack(k)
	local out = (k.s.myInfo and k.s.myInfo.outgoing) or {}
	local a = out[#out]
	if a then
		intent({ type = "cancel_attack", attackID = a.id })
		return true
	end
	return false
end
function ACT.idle()
	return true
end

-- Malformed / hostile intents: the server must shrug these off.
local FUZZ = {
	function()
		intent({ type = "attack", targetSmallID = 1, ratio = 0 / 0 })
	end,
	function()
		intent({ type = "attack", targetSmallID = -1, ratio = 5 })
	end,
	function()
		intent({ type = "place", unit = "Nuke Everything", tile = -3 })
	end,
	function()
		intent({ type = "place", unit = "City", tile = 1e12 })
	end,
	function()
		local ids = table.create(500, 1)
		intent({ type = "move_warship", unitIds = ids, tile = "x" })
	end,
	function()
		intent({ type = 42 })
	end,
	function()
		intent({ type = "donate_gold", target = 1, amount = math.huge })
	end,
	function()
		intent({ type = "cancel_attack", attackID = string.rep("a", 5000) })
	end,
	function()
		intent({ type = "quick_chat", target = 1, key = string.rep("k", 1000) })
	end,
	function()
		intent({ type = "lobby_set", key = "bots", value = 1e9 })
	end,
	function()
		pcall(function()
			Net.Query:InvokeServer({ tile = "nope" })
		end)
	end,
	function()
		intent({ type = "equip", slot = "pattern", itemId = "pattern_not_owned" })
	end,
	function()
		intent({ type = "emoji", target = 0, emoji = 99999 })
	end,
	function()
		intent({ type = "spawn", tile = 3.5 })
	end,
}

local function bucket(k)
	local elapsed = os.clock() - stats.started + (AutoPlay.timeOffset or 0)
	local phase = if elapsed < 180 then "early" elseif elapsed < 720 then "mid" else "late"
	local strength = "none"
	local w = weakest(k, k.neighbours)
	if w then
		local ratioT = k.mine.troops / math.max(1, k.s.stats[w].troops)
		strength = if ratioT < 0.5 then "weaker" elseif ratioT > 2 then "stronger" else "even"
	end
	local gold = if k.mine.gold < 100000 then "low" elseif k.mine.gold < 1000000 then "mid" else "high"
	local info = k.s.myInfo or {}
	local threat = if #(info.incoming or {}) > 0 then "attacked" else "safe"
	local req = if #(info.requestsIn or {}) > 0 then "pending" else "none"
	return `{phase}|{strength}|{gold}|{threat}|{req}`
end

local function sample(probs)
	local x, acc = rng:NextNumber(), 0
	for _, a in ACTIONS do
		acc += probs[a] or 0
		if x <= acc then
			return a
		end
	end
	return "idle"
end

function AutoPlay.start(period: number?)
	if AutoPlay.running then
		return
	end
	AutoPlay.running = true
	task.spawn(function()
		while AutoPlay.running do
			task.wait((period or 1.2) * rng:NextNumber(0.6, 1.4))
			local c = _G.OpenFrontClient
			if not (c and c.snapshot) then
				continue
			end
			local ok, err = pcall(function()
				local k = ctx()
				if k.s.gameOver then
					stats.gameOver = true
					return
				end
				if k.me == nil or k.s.inSpawnPhase or k.mine == nil then
					return
				end
				if k.mine.tiles == 0 then
					stats.dead = true
					return
				end
				local b = bucket(k)
				local action = if rng:NextNumber() < 0.2 then pick(ACTIONS) else sample(POLICY[b] or {})
				stats.decisions += 1
				stats.lastBucket = b
				stats.actions[action] = (stats.actions[action] or 0) + 1
				if not ACT[action](k) then
					stats.failed[action] = (stats.failed[action] or 0) + 1
				end
				if stats.decisions % 7 == 0 then
					stats.fuzz += 1
					pick(FUZZ)()
				end
				if stats.decisions % 11 == 0 then
					-- UI data paths: player panel and shop queries.
					local t = pick(ownerTiles()[pick(k.others) or 0] or {})
					if t then
						pcall(function()
							Net.Query:InvokeServer({ tile = t, kind = "player" })
						end)
					end
					pcall(function()
						Net.Query:InvokeServer({ kind = "shop" })
					end)
				end
			end)
			if not ok then
				table.insert(stats.errors, tostring(err))
				if #stats.errors > 20 then
					table.remove(stats.errors, 1)
				end
			end
		end
	end)
end

function AutoPlay.stop()
	AutoPlay.running = false
end

return AutoPlay
