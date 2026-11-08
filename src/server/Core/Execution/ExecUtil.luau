-- Port of helpers from OpenFrontIO src/core/execution/Util.ts and
-- src/core/Util.ts used by executions.

local Shared = game:GetService("ReplicatedStorage").Shared
local GameMap = require(Shared.GameMap)
local Util = require(Shared.Util)

local ExecUtil = {}

-- Tiles within a radius-4 circle of `tile` (flood-filled, upstream order).
-- requireAllValid: returns nil if any of them is owned / water / impassable.
function ExecUtil.getSpawnTiles(gm, tile: number, requireAllValid: boolean?): { number }?
	local spawnTiles = gm:bfs(tile, GameMap.euclDistFN(tile, 4, true)):toArray()
	local function isInvalid(t: number): boolean
		return gm:hasOwner(t) or not gm:isLand(t) or gm:isImpassable(t)
	end
	if not requireAllValid then
		local out = {}
		for _, t in spawnTiles do
			if not isInvalid(t) then
				table.insert(out, t)
			end
		end
		return out
	end
	for _, t in spawnTiles do
		if isInvalid(t) then
			return nil
		end
	end
	return spawnTiles
end

-- Returns (closestRef | nil, distance) by Manhattan distance, first wins ties.
function ExecUtil.closestTile(gm, refs, tile: number): (number?, number)
	local minDistance = math.huge
	local minRef = nil
	for _, ref in refs do
		local distance = gm:manhattanDist(ref, tile)
		if distance < minDistance then
			minDistance = distance
			minRef = ref
		end
	end
	return minRef, minDistance
end

-- Closest pair between two tile lists by a sweep over x-sorted copies
-- (upstream closestTwoTiles; stable sort like JS). Returns x, y or nil.
function ExecUtil.closestTwoTiles(gm, xs: { number }, ys: { number }): (number?, number?)
	local w = gm:width()
	local byX = function(a: number, b: number): number
		return (a % w) - (b % w)
	end
	local xSorted = Util.sort(table.clone(xs), byX)
	local ySorted = Util.sort(table.clone(ys), byX)
	if #xSorted == 0 or #ySorted == 0 then
		return nil, nil
	end
	local i, j = 1, 1
	local minDistance = math.huge
	local rx, ry = xSorted[1], ySorted[1]
	while i <= #xSorted and j <= #ySorted do
		local cx, cy = xSorted[i], ySorted[j]
		local cxX, cyX = cx % w, cy % w
		local distance = math.abs(cxX - cyX) + math.abs(cx // w - cy // w)
		if distance < minDistance then
			minDistance = distance
			rx, ry = cx, cy
		end
		if i == #xSorted then
			j += 1
		elseif j == #ySorted then
			i += 1
		elseif cxX < cyX then
			i += 1
		else
			j += 1
		end
	end
	return rx, ry
end

-- Upstream Util.getMode over an insertion-ordered map (PlayerImpl.OrderedMap):
-- first key with the strictly largest count.
function ExecUtil.getMode(counts)
	local mode = nil
	local maxCount = 0
	for item, count in counts:entries() do
		if count > maxCount then
			maxCount = count
			mode = item
		end
	end
	return mode
end

-- Weighted tiles each player has in a blast (inner = 1, outer ring = 0.5):
-- smallID -> weight, in first-seen order (JS Map). computeNukeBlastCounts.
function ExecUtil.computeNukeBlastCounts(gm, targetTile: number, magnitude)
	local inner2 = magnitude.inner * magnitude.inner
	local order, counts = {}, {}
	gm:circleSearch(targetTile, magnitude.outer, function(tile, d2)
		local ownerSmallId = gm:ownerID(tile)
		if ownerSmallId > 0 then
			local weight = if d2 <= inner2 then 1 else 0.5
			if counts[ownerSmallId] == nil then
				table.insert(order, ownerSmallId)
				counts[ownerSmallId] = 0
			end
			counts[ownerSmallId] += weight
		end
		return true
	end)
	return order, counts
end

-- Players (smallIDs, insertion order) angered by a nuke: over the weighted
-- tile threshold, or owning a structure in the blast. listNukeBreakAlliance.
function ExecUtil.listNukeBreakAlliance(game, targetTile: number, magnitude, threshold: number): { number }
	local seen, out = {}, {}
	local function add(id)
		if not seen[id] then
			seen[id] = true
			table.insert(out, id)
		end
	end
	local order, counts = ExecUtil.computeNukeBlastCounts(game, targetTile, magnitude)
	for _, id in order do
		if counts[id] > threshold then
			add(id)
		end
	end
	local Structures = require(script.Parent.Parent.GameTypes).Structures
	for _, e in game:nearbyUnits(targetTile, magnitude.outer, Structures.types) do
		add(e.unit:owner():smallID())
	end
	return out
end

-- Would a nuke here break an alliance with one of `allySmallIds` (a set)?
-- Any allied structure in the blast, or an ally's weighted tile count over
-- the threshold (early exit). wouldNukeBreakAlliance.
function ExecUtil.wouldNukeBreakAlliance(game, targetTile: number, magnitude, allySmallIds, threshold: number): boolean
	if allySmallIds == nil or next(allySmallIds) == nil then
		return false
	end
	local Structures = require(script.Parent.Parent.GameTypes).Structures
	local hitsAllied = game:anyUnitNearby(targetTile, magnitude.outer, Structures.types, function(unit)
		return unit:owner():isPlayer() and allySmallIds[unit:owner():smallID()] == true
	end)
	if hitsAllied then
		return true
	end
	local inner2 = magnitude.inner * magnitude.inner
	local counts = {}
	local result = false
	game:circleSearch(targetTile, magnitude.outer, function(tile, d2)
		if result then
			return false
		end
		local owner = game:ownerID(tile)
		if owner > 0 and allySmallIds[owner] then
			counts[owner] = (counts[owner] or 0) + (if d2 <= inner2 then 1 else 0.5)
			if counts[owner] > threshold then
				result = true
				return false
			end
		end
		return true
	end)
	return result
end

return ExecUtil
