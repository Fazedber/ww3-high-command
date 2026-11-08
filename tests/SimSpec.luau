-- Golden simulation check: replays the scenario from tools/golden-sim.mts in
-- the Luau port and compares every snapshot with the original TypeScript.
--
-- The run is resumable so it fits in short Studio calls:
--   local spec = require(game.ServerStorage.Tests.SimSpec)
--   spec.reset()
--   spec.run(250)   -- advance to tick 250, comparing snapshots on the way
--   spec.run(1000)

local EncodingService = game:GetService("EncodingService")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = game:GetService("ReplicatedStorage").Shared

-- Scenario vectors; reset(name) switches (default SimVectors).
local V = require(script.Parent.SimVectors)

local SimSpec = {}

local state = nil

local function sha256Hex(buf: buffer): string
	local h = EncodingService:ComputeBufferHash(buf, Enum.HashAlgorithm.Sha256)
	local out = table.create(buffer.len(h))
	for i = 0, buffer.len(h) - 1 do
		out[i + 1] = string.format("%02x", buffer.readu8(h, i))
	end
	return table.concat(out)
end

local function snapshot(game)
	local all = game:allPlayers()
	local totalOwned = 0
	for _, p in all do
		totalOwned += p:numTilesOwned()
	end
	return {
		stateSha = sha256Hex(game:map():tileStateBuffer()),
		hash = game:hash(),
		alive = #game:players(),
		totalOwned = totalOwned,
		players = all,
	}
end

-- Compares one snapshot; returns a list of human-readable differences.
local function compare(got, want): { string }
	local diffs = {}
	if got.stateSha ~= want.stateSha then
		table.insert(diffs, `tile state sha {string.sub(got.stateSha, 1, 12)} != {string.sub(want.stateSha, 1, 12)}`)
	end
	if got.hash ~= want.hash then
		table.insert(diffs, `game hash {got.hash} != {want.hash}`)
	end
	if got.alive ~= want.alive then
		table.insert(diffs, `alive {got.alive} != {want.alive}`)
	end
	if got.totalOwned ~= want.totalOwned then
		table.insert(diffs, `owned {got.totalOwned} != {want.totalOwned}`)
	end
	if #got.players ~= #want.players then
		table.insert(diffs, `players {#got.players} != {#want.players}`)
	end
	for i, wp in want.players do
		local p = got.players[i]
		if p == nil then
			break
		end
		local line = {}
		if p:name() ~= wp.name then
			table.insert(line, `name {p:name()} != {wp.name}`)
		end
		if p:id() ~= wp.id then
			table.insert(line, `id {p:id()} != {wp.id}`)
		end
		if p:numTilesOwned() ~= wp.tiles then
			table.insert(line, `tiles {p:numTilesOwned()} != {wp.tiles}`)
		end
		if p:troops() ~= wp.troops then
			table.insert(line, `troops {p:troops()} != {wp.troops}`)
		end
		if p:gold() ~= wp.gold then
			table.insert(line, `gold {p:gold()} != {wp.gold}`)
		end
		if #line > 0 then
			table.insert(diffs, `player #{i} ({wp.name}): {table.concat(line, ", ")}`)
			if #diffs > 8 then
				break
			end
		end
	end
	return diffs
end

function SimSpec.reset(vectorsName: string?)
	V = require(script.Parent[vectorsName or "SimVectors"])
	local GameRunner = require(ServerScriptService.Core.GameRunner)
	local t0 = os.clock()
	local runner = GameRunner.create({ gameID = V.gameID, config = V.config, players = V.players or {} }, game:GetService("ServerStorage").Maps[V.map])
	-- Scripted intents grouped by the tick they were issued.
	local intentsByTick = {}
	for _, r in V.intents or {} do
		intentsByTick[r.tick] = intentsByTick[r.tick] or {}
		table.insert(intentsByTick[r.tick], table.clone(r.intent))
	end
	state = {
		runner = runner,
		tick = 0,
		nextSnap = 1,
		results = {},
		intentsByTick = intentsByTick,
		firstFailure = nil,
		simSeconds = 0,
		setupMs = (os.clock() - t0) * 1000,
	}
	return `reset: setup {math.floor(state.setupMs)} ms`
end

-- Advance to `untilTick` (inclusive snapshot check), return a report.
function SimSpec.run(untilTick: number): string
	if state == nil then
		SimSpec.reset()
	end
	local s = state
	local game = s.runner.game
	while s.tick <= math.min(untilTick, V.ticks) do
		local want = V.snapshots[s.nextSnap]
		if want and want.tick == s.tick then
			local diffs = compare(snapshot(game), want)
			table.insert(s.results, { tick = s.tick, ok = #diffs == 0, diffs = diffs })
			if #diffs > 0 and s.firstFailure == nil then
				s.firstFailure = s.tick
			end
			s.nextSnap += 1
		end
		if s.tick == untilTick or s.tick == V.ticks then
			break
		end
		local t0 = os.clock()
		s.runner:executeNextTick(s.intentsByTick[s.tick])
		s.simSeconds += os.clock() - t0
		s.tick += 1
		-- Optional per-tick { hash, nextUnitID } to pin the first diverging tick.
		local th = V.tickHashes and V.tickHashes[s.tick]
		if th and s.firstTickMismatch == nil and (game:hash() ~= th[1] or game._nextUnitID ~= th[2]) then
			s.firstTickMismatch = `tick {s.tick}: hash {game:hash()} != {th[1]}, nextUnitID {game._nextUnitID} != {th[2]}`
		end
	end

	local lines = {}
	for _, r in s.results do
		if r.ok then
			table.insert(lines, `tick {r.tick}: OK`)
		else
			table.insert(lines, `tick {r.tick}: MISMATCH`)
			for _, d in r.diffs do
				table.insert(lines, `    {d}`)
			end
		end
	end
	if V.unitsCreated ~= nil and s.tick == V.ticks then
		local created = game._nextUnitID - 1
		table.insert(lines, `units created: {created} (upstream {V.unitsCreated}) {if created == V.unitsCreated then "OK" else "MISMATCH"}`)
	end
	if V.unitsAlive ~= nil and s.tick == V.ticks then
		local parts = {}
		for _, u in game:units() do
			table.insert(parts, `{u:id()}:{u:type()}:{u:owner():name()}:{u:tile()}:{u:level()}`)
		end
		local got = table.concat(parts, ";")
		table.insert(lines, `alive units: {if got == V.unitsAlive then "OK" else "MISMATCH\n    got  " .. got .. "\n    want " .. V.unitsAlive}`)
	end
	if V.tradeGold ~= nil and s.tick == V.ticks then
		local a = game:playerByClientID(V.players[1].clientID)
		local b = game:playerByClientID(V.players[2].clientID)
		local ok = a:tradeGold() == V.tradeGold[1] and b:tradeGold() == V.tradeGold[2]
		table.insert(lines, `trade gold: {a:tradeGold()} / {b:tradeGold()} {if ok then "OK" else "MISMATCH (want " .. V.tradeGold[1] .. " / " .. V.tradeGold[2] .. ")"}`)
	end
	table.insert(
		lines,
		string.format(
			"at tick %d, sim %.0f ms total (%.2f ms/tick), first failure: %s",
			s.tick,
			s.simSeconds * 1000,
			s.simSeconds * 1000 / math.max(1, s.tick),
			tostring(s.firstFailure)
		)
	)
	if s.firstTickMismatch then
		table.insert(lines, `first per-tick mismatch: {s.firstTickMismatch}`)
	end
	return table.concat(lines, "\n")
end

return SimSpec
