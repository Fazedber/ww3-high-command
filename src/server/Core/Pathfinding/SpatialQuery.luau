-- Port of OpenFrontIO src/core/pathfinding/spatial/SpatialQuery.ts.
-- Picks boat launch / landing shores: nearest shore by land BFS, and the
-- best launch shore by multi-source water pathfinding plus a local refine.

local Core = script.Parent.Parent
local Scratch = require(Core.TileTraversalScratch)
local AStarWaterBounded = require(script.Parent.AStarWaterBounded)
local PathFinderMod = require(script.Parent.PathFinder)

local REFINE_MAX_SEARCH_AREA = 100 * 100

local readu32, writeu32 = buffer.readu32, buffer.writeu32

-- Water components touching a player's shoreline, memoised per player.
local reachableCache = setmetatable({}, { __mode = "k" })

local SpatialQuery = {}
SpatialQuery.__index = SpatialQuery

function SpatialQuery.new(game)
	return setmetatable({ game = game, boundedAStar = nil }, SpatialQuery)
end

function SpatialQuery:_getBoundedAStar()
	if not self.boundedAStar then
		self.boundedAStar = AStarWaterBounded.new(self.game:map(), REFINE_MAX_SEARCH_AREA)
	end
	return self.boundedAStar
end

-- Nearest tile matching predicate by DFS over tiles within Manhattan maxDist
-- (ignores terrain). Strict < keeps the first candidate at the minimum
-- distance, so traversal order (LIFO, N S W E) decides ties like upstream.
function SpatialQuery:_bfsNearest(from: number, maxDist: number, predicate: (number) -> boolean): number?
	local map = self.game:map()
	if not map:isValidRef(from) then
		return nil
	end
	local scratch = Scratch.get(self.game)
	local gen = Scratch.bump(scratch)
	local visited = scratch.visited
	local stack = scratch.stack
	table.clear(stack)
	local best, bestDist = nil, math.huge

	local function mark(t: number)
		writeu32(visited, t * 4, gen)
		table.insert(stack, t)
		if predicate(t) then
			local d = map:manhattanDist(from, t)
			if d < bestDist then
				best = t
				bestDist = d
			end
		end
	end

	if maxDist >= 0 then
		mark(from)
	end
	local function visit(n: number)
		if readu32(visited, n * 4) ~= gen and map:manhattanDist(from, n) <= maxDist then
			mark(n)
		end
	end
	while #stack > 0 do
		local curr = table.remove(stack) :: number
		map:forEachNeighbor(curr, visit)
	end
	return best
end

-- Closest shore tile of `owner` near `tile` (land BFS).
function SpatialQuery:closestShore(owner, tile: number, maxDist: number?): number?
	local gm = self.game
	local ownerId = owner:smallID()
	return self:_bfsNearest(tile, maxDist or 50, function(t)
		return gm:isShore(t) and gm:isLand(t) and gm:ownerID(t) == ownerId
	end)
end

function SpatialQuery:_reachableComponents(attacker)
	local gm = self.game
	local tileVersion = attacker:tileChangeVersion()
	local waterVersion = gm:map():waterVersion()
	local cached = reachableCache[attacker]
	if cached and cached.tileVersion == tileVersion and cached.waterVersion == waterVersion then
		return cached.components, cached.count
	end
	local components, count = {}, 0
	for t in attacker:borderTiles() do
		if gm:isShore(t) and gm:isLand(t) then
			local c = gm:getWaterComponent(t)
			if c ~= nil and not components[c] then
				components[c] = true
				count += 1
			end
		end
	end
	reachableCache[attacker] = { tileVersion = tileVersion, waterVersion = waterVersion, components = components, count = count }
	return components, count
end

-- Closest shore of `targetOwner` near `tile` on a water component reachable
-- from the attacker's own shoreline.
function SpatialQuery:closestReachableShore(targetOwner, attacker, tile: number, maxDist: number?): number?
	local gm = self.game
	local md = maxDist or 50
	local targetId = targetOwner:smallID()
	local reachable, count = self:_reachableComponents(attacker)
	if count == 0 then
		return nil
	end
	local function isValid(t: number): boolean
		if not gm:isShore(t) or not gm:isLand(t) then
			return false
		end
		if gm:ownerID(t) ~= targetId then
			return false
		end
		local c = gm:getWaterComponent(t)
		return c ~= nil and reachable[c] == true
	end
	if md >= 0 and gm:map():isValidRef(tile) and isValid(tile) then
		return tile
	end
	return self:_bfsNearest(tile, md, isValid)
end

-- Closest launch shore of `owner` to `target` by water pathfinding.
function SpatialQuery:closestShoreByWater(owner, target: number): number?
	if not owner:isPlayer() then
		return nil
	end
	local gm = self.game
	if not gm:isWater(target) and not gm:isShore(target) then
		return nil
	end
	local targetComponent = gm:getWaterComponent(target)
	if targetComponent == nil then
		return nil
	end
	local shores = {}
	for t in owner:borderTiles() do
		if gm:isShore(t) and gm:isLand(t) and gm:getWaterComponent(t) == targetComponent then
			table.insert(shores, t)
		end
	end
	if #shores == 0 then
		return nil
	end
	local path = PathFinderMod.Water(gm):findPath(shores, target)
	if not path or #path == 0 then
		return nil
	end
	return self:_refineStartTile(path, shores)
end

function SpatialQuery:_refineStartTile(path: { number }, shores: { number }): number
	local CANDIDATE_RADIUS = 20
	local MIN_WAYPOINT_DIST = 50
	local MAX_WAYPOINT_DIST = 200
	local PADDING = 10
	if #path <= MIN_WAYPOINT_DIST then
		return path[1]
	end
	local map = self.game:map()
	local bestTile = path[1]
	local candidates = {}
	for _, s in shores do
		if map:manhattanDist(s, bestTile) <= CANDIDATE_RADIUS then
			table.insert(candidates, s)
		end
	end
	if #candidates <= 1 then
		return bestTile
	end
	local candMinX, candMinY = map:x(candidates[1]), map:y(candidates[1])
	local candMaxX, candMaxY = candMinX, candMinY
	for i = 2, #candidates do
		local sx, sy = map:x(candidates[i]), map:y(candidates[i])
		candMinX = math.min(candMinX, sx)
		candMaxX = math.max(candMaxX, sx)
		candMinY = math.min(candMinY, sy)
		candMaxY = math.max(candMaxY, sy)
	end
	-- Binary search (<= 5 steps) for the farthest waypoint keeping the area small.
	local lo = MIN_WAYPOINT_DIST
	local hi = math.min(MAX_WAYPOINT_DIST, #path - 1)
	local bestIdx = lo
	local i = 0
	while i < 5 and lo <= hi do
		i += 1
		local mid = (lo + hi) // 2
		local wp = path[mid + 1]
		local wpX, wpY = map:x(wp), map:y(wp)
		local minX = math.min(candMinX, wpX) - PADDING
		local maxX = math.max(candMaxX, wpX) + PADDING
		local minY = math.min(candMinY, wpY) - PADDING
		local maxY = math.max(candMaxY, wpY) + PADDING
		if (maxX - minX + 1) * (maxY - minY + 1) <= REFINE_MAX_SEARCH_AREA then
			bestIdx = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	local waypoint = path[bestIdx + 1]
	local wpX, wpY = map:x(waypoint), map:y(waypoint)
	local bounds = {
		minX = math.max(0, math.min(candMinX, wpX) - PADDING),
		maxX = math.min(map:width() - 1, math.max(candMaxX, wpX) + PADDING),
		minY = math.max(0, math.min(candMinY, wpY) - PADDING),
		maxY = math.min(map:height() - 1, math.max(candMaxY, wpY) + PADDING),
	}
	if (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1) > REFINE_MAX_SEARCH_AREA then
		return bestTile
	end
	local refined = self:_getBoundedAStar():searchBounded(candidates, waypoint, bounds)
	return if refined and refined[1] ~= nil then refined[1] else bestTile
end

return SpatialQuery
