--!native
-- Port of OpenFrontIO src/core/pathfinding/algorithms/AStar.Water.ts.
-- Plain water A* over the whole minimap; used when the abstract graph is
-- unavailable or tiny (< 100 nodes).

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
		return 10 * COST_SCALE -- too close to shore
	end
	if magnitude <= 10 then
		return 0 -- sweet spot
	end
	return 1 * COST_SCALE -- deep water, slight penalty
end

local AStarWater = {}
AStarWater.__index = AStarWater

function AStarWater.new(map, config)
	local n = map:width() * map:height()
	return setmetatable({
		terrain = map:terrainBuffer(),
		width = map:width(),
		numNodes = n,
		heuristicWeight = config and config.heuristicWeight or 5,
		maxIterations = config and config.maxIterations or 1000000,
		_stamp = 1,
		_closed = buffer.create(n * 4),
		_gStamp = buffer.create(n * 4),
		_g = buffer.create(n * 4),
		_cameFrom = buffer.create(n * 4),
		queue = MinHeap.new(n),
	}, AStarWater)
end

function AStarWater:findPath(start, goal: number)
	self._stamp += 1
	if self._stamp > 0xffffffff then
		buffer.fill(self._closed, 0, 0)
		buffer.fill(self._gStamp, 0, 0)
		self._stamp = 1
	end
	local stamp = self._stamp
	local width, numNodes, terrain = self.width, self.numNodes, self.terrain
	local closed, gStamp, g, cameFrom = self._closed, self._gStamp, self._g, self._cameFrom
	local queue = self.queue
	local weight = self.heuristicWeight
	local goalX, goalY = goal % width, goal // width

	queue:clear()
	local starts = if type(start) == "table" then start else { start }
	local s0 = starts[1]
	local dxGoal, dyGoal = goalX - s0 % width, goalY - s0 // width
	local crossNorm = math.max(1, math.abs(dxGoal) + math.abs(dyGoal))
	local function crossTieBreaker(nx: number, ny: number): number
		local cross = math.abs(dxGoal * (ny - goalY) - dyGoal * (nx - goalX))
		return math.floor((cross * (COST_SCALE - 1)) / crossNorm / crossNorm)
	end

	for _, s in starts do
		writeu32(g, s * 4, 0)
		writeu32(gStamp, s * 4, stamp)
		writei32(cameFrom, s * 4, -1)
		queue:push(s, weight * BASE_COST * (math.abs(s % width - goalX) + math.abs(s // width - goalY)))
	end

	local function relax(current: number, currentG: number, neighbor: number, nx: number, ny: number)
		local t = readu8(terrain, neighbor)
		if readu32(closed, neighbor * 4) == stamp or not (neighbor == goal or band(t, LAND_MASK) == 0) then
			return
		end
		local tentativeG = currentG + BASE_COST + magnitudePenalty(band(t, MAGNITUDE_MASK))
		if readu32(gStamp, neighbor * 4) ~= stamp or tentativeG < readu32(g, neighbor * 4) then
			writei32(cameFrom, neighbor * 4, current)
			writeu32(g, neighbor * 4, tentativeG)
			writeu32(gStamp, neighbor * 4, stamp)
			local h = weight * BASE_COST * (math.abs(nx - goalX) + math.abs(ny - goalY))
			queue:push(neighbor, tentativeG + h + crossTieBreaker(nx, ny))
		end
	end

	local iterations = self.maxIterations
	while not queue:isEmpty() do
		iterations -= 1
		if iterations <= 0 then
			return nil
		end
		local current = queue:pop()
		if readu32(closed, current * 4) == stamp then
			continue
		end
		writeu32(closed, current * 4, stamp)
		if current == goal then
			return self:_buildPath(goal)
		end
		local currentG = readu32(g, current * 4)
		local cx, cy = current % width, current // width
		if current >= width then
			relax(current, currentG, current - width, cx, cy - 1)
		end
		if current < numNodes - width then
			relax(current, currentG, current + width, cx, cy + 1)
		end
		if cx ~= 0 then
			relax(current, currentG, current - 1, cx - 1, cy)
		end
		if cx ~= width - 1 then
			relax(current, currentG, current + 1, cx + 1, cy)
		end
	end
	return nil
end

function AStarWater:_buildPath(goal: number)
	local path = {}
	local current = goal
	while current ~= -1 do
		table.insert(path, current)
		current = readi32(self._cameFrom, current * 4)
	end
	local n = #path
	for i = 1, n // 2 do
		path[i], path[n - i + 1] = path[n - i + 1], path[i]
	end
	return path
end

return AStarWater
