--!native
-- Port of OpenFrontIO src/core/pathfinding/algorithms/AStar.WaterBounded.ts.
-- Water A* confined to a rectangle, preferring water 3-10 tiles from shore,
-- with a cross-product tie-breaker toward the straight start-goal line.

local MinHeap = require(script.Parent.MinHeap)

local LAND_MASK = 0x80
local MAGNITUDE_MASK = 0x1f
local COST_SCALE = 100
local BASE_COST = 1 * COST_SCALE

local readu8 = buffer.readu8
local readu32, writeu32 = buffer.readu32, buffer.writeu32
local readi32, writei32 = buffer.readi32, buffer.writei32
local band = bit32.band

local function magnitudePenalty(magnitude: number): number
	if magnitude < 3 then
		return 3 * COST_SCALE -- too close to shore
	end
	if magnitude <= 10 then
		return 0 -- sweet spot
	end
	return 1 * COST_SCALE -- deep water, slight penalty
end

local AStarWaterBounded = {}
AStarWaterBounded.__index = AStarWaterBounded

function AStarWaterBounded.new(map, maxSearchArea: number, config)
	return setmetatable({
		terrain = map:terrainBuffer(),
		mapWidth = map:width(),
		heuristicWeight = config and config.heuristicWeight or 3,
		maxIterations = config and config.maxIterations or 100000,
		_stamp = 1,
		_capacity = maxSearchArea,
		_closed = buffer.create(maxSearchArea * 4),
		_gStamp = buffer.create(maxSearchArea * 4),
		_g = buffer.create(maxSearchArea * 4),
		_cameFrom = buffer.create(maxSearchArea * 4),
		queue = MinHeap.new(maxSearchArea * 4),
	}, AStarWaterBounded)
end

function AStarWaterBounded:findPath(start, goal: number)
	local starts = if type(start) == "table" then start else { start }
	local w = self.mapWidth
	local goalX, goalY = goal % w, goal // w
	local minX, maxX, minY, maxY = goalX, goalX, goalY, goalY
	for _, s in starts do
		local sx, sy = s % w, s // w
		minX = math.min(minX, sx)
		maxX = math.max(maxX, sx)
		minY = math.min(minY, sy)
		maxY = math.max(maxY, sy)
	end
	return self:searchBounded(starts, goal, { minX = minX, maxX = maxX, minY = minY, maxY = maxY })
end

function AStarWaterBounded:searchBounded(start, goal: number, bounds)
	self._stamp += 1
	if self._stamp > 0xffffffff then
		buffer.fill(self._closed, 0, 0)
		buffer.fill(self._gStamp, 0, 0)
		self._stamp = 1
	end
	local stamp = self._stamp
	local mapWidth = self.mapWidth
	local terrain = self.terrain
	local closed, gStamp, g, cameFrom = self._closed, self._gStamp, self._g, self._cameFrom
	local queue = self.queue
	local weight = self.heuristicWeight

	local minX, maxX, minY, maxY = bounds.minX, bounds.maxX, bounds.minY, bounds.maxY
	local boundsWidth = maxX - minX + 1
	local boundsHeight = maxY - minY + 1
	local numLocal = boundsWidth * boundsHeight
	local goalX, goalY = goal % mapWidth, goal // mapWidth
	if numLocal > self._capacity then
		return nil
	end

	local function toLocal(tile: number, clamp: boolean): number
		local x, y = tile % mapWidth, tile // mapWidth
		if clamp then
			x = math.max(minX, math.min(maxX, x))
			y = math.max(minY, math.min(maxY, y))
		end
		return (y - minY) * boundsWidth + (x - minX)
	end

	local goalLocal = toLocal(goal, true)
	if goalLocal < 0 or goalLocal >= numLocal then
		return nil
	end

	queue:clear()
	local starts = if type(start) == "table" then start else { start }
	local s0 = starts[1]
	local startX, startY = s0 % mapWidth, s0 // mapWidth
	local dxGoal, dyGoal = goalX - startX, goalY - startY
	local crossNorm = math.max(1, math.abs(dxGoal) + math.abs(dyGoal))
	local function crossTieBreaker(nx: number, ny: number): number
		local cross = math.abs(dxGoal * (ny - goalY) - dyGoal * (nx - goalX))
		return math.floor((cross * (COST_SCALE - 1)) / crossNorm / crossNorm)
	end

	for _, s in starts do
		local startLocal = toLocal(s, true)
		if startLocal < 0 or startLocal >= numLocal then
			continue
		end
		writeu32(g, startLocal * 4, 0)
		writeu32(gStamp, startLocal * 4, stamp)
		writei32(cameFrom, startLocal * 4, -1)
		local sx, sy = s % mapWidth, s // mapWidth
		queue:push(startLocal, weight * BASE_COST * (math.abs(sx - goalX) + math.abs(sy - goalY)))
	end

	-- Relax one neighbor (shared by the four directions below).
	local function relax(currentLocal: number, currentG: number, neighbor: number, neighborLocal: number, nx: number, ny: number)
		local t = readu8(terrain, neighbor)
		if readu32(closed, neighborLocal * 4) == stamp or not (neighbor == goal or band(t, LAND_MASK) == 0) then
			return
		end
		local distToGoal = math.abs(nx - goalX) + math.abs(ny - goalY)
		local tentativeG = currentG + BASE_COST + magnitudePenalty(band(t, MAGNITUDE_MASK))
		if readu32(gStamp, neighborLocal * 4) ~= stamp or tentativeG < readu32(g, neighborLocal * 4) then
			writei32(cameFrom, neighborLocal * 4, currentLocal)
			writeu32(g, neighborLocal * 4, tentativeG)
			writeu32(gStamp, neighborLocal * 4, stamp)
			queue:push(neighborLocal, tentativeG + weight * BASE_COST * distToGoal + crossTieBreaker(nx, ny))
		end
	end

	local iterations = self.maxIterations
	while not queue:isEmpty() do
		iterations -= 1
		if iterations <= 0 then
			return nil
		end
		local currentLocal = queue:pop()
		if readu32(closed, currentLocal * 4) == stamp then
			continue
		end
		writeu32(closed, currentLocal * 4, stamp)
		if currentLocal == goalLocal then
			return self:_buildPath(goalLocal, boundsWidth, minX, minY, numLocal)
		end
		local currentG = readu32(g, currentLocal * 4)
		local lx, ly = currentLocal % boundsWidth, currentLocal // boundsWidth
		local currentX, currentY = lx + minX, ly + minY
		local current = currentY * mapWidth + currentX

		if currentY > minY then
			relax(currentLocal, currentG, current - mapWidth, currentLocal - boundsWidth, currentX, currentY - 1)
		end
		if currentY < maxY then
			relax(currentLocal, currentG, current + mapWidth, currentLocal + boundsWidth, currentX, currentY + 1)
		end
		if currentX > minX then
			relax(currentLocal, currentG, current - 1, currentLocal - 1, currentX - 1, currentY)
		end
		if currentX < maxX then
			relax(currentLocal, currentG, current + 1, currentLocal + 1, currentX + 1, currentY)
		end
	end
	return nil
end

function AStarWaterBounded:_buildPath(goalLocal: number, boundsWidth: number, minX: number, minY: number, maxLen: number)
	local path = {}
	local current = goalLocal
	local iterations = 0
	local mapWidth = self.mapWidth
	while current ~= -1 and iterations < maxLen do
		local lx, ly = current % boundsWidth, current // boundsWidth
		table.insert(path, (ly + minY) * mapWidth + (lx + minX))
		current = readi32(self._cameFrom, current * 4)
		iterations += 1
	end
	local n = #path
	for i = 1, n // 2 do
		path[i], path[n - i + 1] = path[n - i + 1], path[i]
	end
	return path
end

return AStarWaterBounded
