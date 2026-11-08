-- Remote events shared by server and client, plus the binary packing used on
-- the wire. The server simulates; clients only receive what changed.
--
-- Server -> client
--   GameState(state)   full snapshot on join: map, tick, phase, roster, tiles
--   Roster(players)    players added since the last roster message
--   Tick(buf)          tile ownership changes for one tick (packed, see below)
--   Stats(buf)         per-player tiles / troops / gold (every few ticks)
--   Names(buf)         name placements (NameBoxCalculator), when recomputed
--   Units(list)        unit changes this tick: { id, unitType, ownerID, pos, troops, isActive, isRetreating,
--                      level, underConstruction, markedForDeletion, reachedTarget, targetTile,
--                      health, maxHealth, plan? }
--   Me(info)           private: { costs = { [unitType] = gold }, disabled = { [unitType] = true }, maxTroops,
--                      troopRate (per s),
--                      attackingTroops, attacking, allied, bordering? = { smallID }, hasCoast? }
--   Lobby(state)       pre-match lobby: { settings, hostUserId, secondsLeft?, players } | { starting = true }
--   Event(evt)         game events: spawn phase end, winner, conquest, GoldGain (private)
-- Client -> server
--   Intent(intent)     { type = "spawn", tile } | { type = "click", tile, ratio }
--                      | { type = "attack", targetSmallID, ratio } | { type = "cancel_boat", unitID }
--                      | { type = "cancel_attack", attackID }
--                      | { type = "place", unit, tile }   (build, or upgrade a structure in range)
--                      | { type = "delete_at", tile }     (closest own structure within 5 tiles)
--                      | { type = "move_warship", unitIds, tile }
--                      | { type = "attack_at" | "boat_at", tile, ratio }   (radial menu)
--                      | { type = "lobby_set", key, value } | { type = "lobby_start" }   (host only)
--   Query(q) -> result  RemoteFunction: { tile } -> { units = { { unit, cost, canBuild, canUpgrade,
--                      upgradeCosts, upgradeTile } }, deleteUnit, canAttack, canBoat, ownerSmallID, inSpawnPhase }

local RunService = game:GetService("RunService")
local EncodingService = game:GetService("EncodingService")

local Net = {}

local NAMES = { "GameState", "Roster", "Tick", "Stats", "Names", "Units", "UnitPos", "Me", "Event", "Lobby", "Intent" }

local FUNCTIONS = { "Query" }

-- UnitPos: moves of units whose only change is their position (trade ships,
-- trains, boats, warships), batched a few times a second as u24 id + u24
-- tile (6 bytes; ids and tiles stay below 16.7M). Sending these as full Units
-- tables was ~90 KB/s per player late in a match, far over what Roblox
-- delivers without queueing (the "lag as the game goes on").
local function writeu24(b: buffer, o: number, v: number)
	buffer.writeu16(b, o, v % 65536)
	buffer.writeu8(b, o + 2, (v // 65536) % 256)
end
local function readu24(b: buffer, o: number): number
	return buffer.readu16(b, o) + buffer.readu8(b, o + 2) * 65536
end

function Net.packUnitPos(ids: { number }, positions: { number }): buffer
	local n = #ids
	local b = buffer.create(n * 6)
	for i = 1, n do
		writeu24(b, (i - 1) * 6, ids[i])
		writeu24(b, (i - 1) * 6 + 3, positions[i])
	end
	return b
end

function Net.unpackUnitPos(b: buffer, fn: (number, number) -> ())
	for o = 0, buffer.len(b) - 6, 6 do
		fn(readu24(b, o), readu24(b, o + 3))
	end
end

local folder: Folder
if RunService:IsServer() then
	folder = script.Parent:FindFirstChild("Remotes") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		for _, name in NAMES do
			local e = Instance.new("RemoteEvent")
			e.Name = name
			e.Parent = folder
		end
		for _, name in FUNCTIONS do
			local f = Instance.new("RemoteFunction")
			f.Name = name
			f.Parent = folder
		end
		folder.Parent = script.Parent
	end
else
	folder = script.Parent:WaitForChild("Remotes") :: Folder
end

for _, name in NAMES do
	Net[name] = folder:WaitForChild(name) :: RemoteEvent
end
for _, name in FUNCTIONS do
	Net[name] = folder:WaitForChild(name) :: RemoteFunction
end

-- Payloads above this size are zstd-compressed.
local COMPRESS_THRESHOLD = 1024

local function wrap(payload: buffer): buffer
	local len = buffer.len(payload)
	if len > COMPRESS_THRESHOLD then
		local z = EncodingService:CompressBuffer(payload, Enum.CompressionAlgorithm.Zstd, 1)
		if buffer.len(z) < len then
			local out = buffer.create(buffer.len(z) + 1)
			buffer.writeu8(out, 0, 1)
			buffer.copy(out, 1, z)
			return out
		end
	end
	local out = buffer.create(len + 1)
	buffer.writeu8(out, 0, 0)
	buffer.copy(out, 1, payload)
	return out
end

local function unwrap(buf: buffer): buffer
	local body = buffer.create(buffer.len(buf) - 1)
	buffer.copy(body, 0, buf, 1)
	if buffer.readu8(buf, 0) == 1 then
		return EncodingService:DecompressBuffer(body, Enum.CompressionAlgorithm.Zstd)
	end
	return body
end
Net.wrap, Net.unwrap = wrap, unwrap

-- Tick: u32 tick, u32 count, then count x (u32 tile, u16 state).
function Net.packTiles(tick: number, tiles: { number }, states: { number }): buffer
	local n = #tiles
	local b = buffer.create(8 + n * 6)
	buffer.writeu32(b, 0, tick)
	buffer.writeu32(b, 4, n)
	local o = 8
	for i = 1, n do
		buffer.writeu32(b, o, tiles[i])
		buffer.writeu16(b, o + 4, states[i])
		o += 6
	end
	return wrap(b)
end

-- Calls fn(tile, state) for each change; returns the tick.
function Net.unpackTiles(buf: buffer, fn: (number, number) -> ()): number
	local b = unwrap(buf)
	local tick = buffer.readu32(b, 0)
	local n = buffer.readu32(b, 4)
	local o = 8
	for _ = 1, n do
		fn(buffer.readu32(b, o), buffer.readu16(b, o + 4))
		o += 6
	end
	return tick
end

-- Stats: u32 tick, u16 count, then count x (u16 smallID, u32 tiles, f64 troops, f64 gold).
function Net.packStats(tick: number, rows: { { number } }): buffer
	local b = buffer.create(6 + #rows * 22)
	buffer.writeu32(b, 0, tick)
	buffer.writeu16(b, 4, #rows)
	local o = 6
	for _, r in rows do
		buffer.writeu16(b, o, r[1])
		buffer.writeu32(b, o + 2, r[2])
		buffer.writef64(b, o + 6, r[3])
		buffer.writef64(b, o + 14, r[4])
		o += 22
	end
	return wrap(b)
end

function Net.unpackStats(buf: buffer, fn: (number, number, number, number) -> ()): number
	local b = unwrap(buf)
	local tick = buffer.readu32(b, 0)
	local n = buffer.readu16(b, 4)
	local o = 6
	for _ = 1, n do
		fn(buffer.readu16(b, o), buffer.readu32(b, o + 2), buffer.readf64(b, o + 6), buffer.readf64(b, o + 14))
		o += 22
	end
	return tick
end

-- Names: u16 count, then count x (u16 smallID, i16 x, i16 y, f32 size).
function Net.packNames(rows: { { number } }): buffer
	local b = buffer.create(2 + #rows * 10)
	buffer.writeu16(b, 0, #rows)
	local o = 2
	for _, r in rows do
		buffer.writeu16(b, o, r[1])
		buffer.writei16(b, o + 2, r[2])
		buffer.writei16(b, o + 4, r[3])
		buffer.writef32(b, o + 6, r[4])
		o += 10
	end
	return wrap(b)
end

function Net.unpackNames(buf: buffer, fn: (number, number, number, number) -> ())
	local b = unwrap(buf)
	local n = buffer.readu16(b, 0)
	local o = 2
	for _ = 1, n do
		fn(buffer.readu16(b, o), buffer.readi16(b, o + 2), buffer.readi16(b, o + 4), buffer.readf32(b, o + 6))
		o += 10
	end
end

return Net
