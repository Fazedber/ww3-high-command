--!native
-- Ports of OpenFrontIO src/core/pathfinding/transformers/*:
--   ComponentCheckTransformer, MiniMapTransformer, ShoreCoercingTransformer,
--   SmoothingWaterTransformer.
-- Each wraps an inner pathfinder: { findPath(from | {from}, to) -> path | nil }.

local AStarWaterBounded = require(script.Parent.AStarWaterBounded)

local Transformers = {}

local band = bit32.band
local readu8 = buffer.readu8

-- JS Math.round (half up) for the coordinates used here.
local function jsRound(v: number): number
	return math.floor(v + 0.5)
end

local function indexOf(list: { number }, value: number): number
	for i, v in list do
		if v == value then
			return i
		end
	end
	return -1
end

local function slice(list: { number }, i: number, j: number?): { number }
	return table.move(list, i, j or #list, 1, {})
end

-- ComponentCheckTransformer: fail fast if no source shares the destination's
-- water component.
local ComponentCheck = {}
ComponentCheck.__index = ComponentCheck
function ComponentCheck.new(inner, getComponent: (number) -> number)
	return setmetatable({ inner = inner, getComponent = getComponent }, ComponentCheck)
end
function ComponentCheck:findPath(from, to: number)
	local toComponent = self.getComponent(to)
	local fromArray = if type(from) == "table" then from else { from }
	local valid = {}
	for _, f in fromArray do
		if self.getComponent(f) == toComponent then
			table.insert(valid, f)
		end
	end
	if #valid == 0 then
		return nil
	end
	return self.inner:findPath(if #valid == 1 then valid[1] else valid, to)
end
Transformers.ComponentCheck = ComponentCheck

-- MiniMapTransformer: game coords -> minimap (x/2, y/2), search, then upscale
-- back with interpolated points so consecutive tiles stay adjacent.
local MiniMap = {}
MiniMap.__index = MiniMap
function MiniMap.new(inner, map, miniMap)
	return setmetatable({ inner = inner, map = map, miniMap = miniMap }, MiniMap)
end

function MiniMap:findPath(from, to: number)
	local map, mini = self.map, self.miniMap
	local fromArray = if type(from) == "table" then from else { from }
	local miniFromArray = {}
	for _, f in fromArray do
		table.insert(miniFromArray, mini:ref(map:x(f) // 2, map:y(f) // 2))
	end
	local miniFrom = if #miniFromArray == 1 then miniFromArray[1] else miniFromArray
	local miniTo = mini:ref(map:x(to) // 2, map:y(to) // 2)

	local path = self.inner:findPath(miniFrom, miniTo)
	if not path or #path == 0 then
		return nil
	end
	local upscaled = self:_upscalePath(path, 2)

	local srcRef = nil
	if type(from) == "table" then
		if #upscaled > 0 then
			local sx, sy = map:x(upscaled[1]), map:y(upscaled[1])
			local minDist = math.huge
			for _, f in from do
				local d = math.abs(map:x(f) - sx) + math.abs(map:y(f) - sy)
				if d < minDist then
					minDist = d
					srcRef = f
				end
			end
		end
	else
		srcRef = from
	end
	return self:_fixExtremes(upscaled, to, srcRef)
end

function MiniMap:_upscalePath(path: { number }, scale: number): { number }
	local mini, main = self.miniMap, self.map
	local out = {}
	for i = 1, #path - 1 do
		local curX, curY = mini:x(path[i]) * scale, mini:y(path[i]) * scale
		local nextX, nextY = mini:x(path[i + 1]) * scale, mini:y(path[i + 1]) * scale
		table.insert(out, main:ref(curX, curY))
		local dx, dy = nextX - curX, nextY - curY
		local steps = math.max(math.abs(dx), math.abs(dy))
		for step = 1, steps - 1 do
			table.insert(out, main:ref(jsRound(curX + (dx * step) / steps), jsRound(curY + (dy * step) / steps)))
		end
	end
	if #path > 0 then
		local last = path[#path]
		table.insert(out, main:ref(mini:x(last) * scale, mini:y(last) * scale))
	end
	return out
end

function MiniMap:_fixExtremes(upscaled: { number }, dst: number, src: number?): { number }
	if src ~= nil then
		local srcIndex = indexOf(upscaled, src)
		if srcIndex == -1 then
			table.insert(upscaled, 1, src)
		elseif srcIndex ~= 1 then
			upscaled = slice(upscaled, srcIndex)
		end
	end
	local dstIndex = indexOf(upscaled, dst)
	if dstIndex == -1 then
		table.insert(upscaled, dst)
	elseif dstIndex ~= #upscaled then
		upscaled = slice(upscaled, 1, dstIndex)
	end
	return upscaled
end
Transformers.MiniMap = MiniMap

-- ShoreCoercingTransformer: path from/to a shore tile's best water neighbour,
-- then restore the original shore endpoints.
local ShoreCoercing = {}
ShoreCoercing.__index = ShoreCoercing
function ShoreCoercing.new(inner, map)
	return setmetatable({ inner = inner, map = map, _nbuf = { 0, 0, 0, 0 }, _nbuf2 = { 0, 0, 0, 0 } }, ShoreCoercing)
end

function ShoreCoercing:_countWaterNeighbors(tile: number): number
	local count = 0
	local nbuf = self._nbuf2
	local n = self.map:neighbors4(tile, nbuf)
	for i = 1, n do
		if self.map:isWater(nbuf[i]) then
			count += 1
		end
	end
	return count
end

-- Highest water-connectivity adjacent water tile (first wins ties), or -1.
function ShoreCoercing:_bestWaterNeighbor(tile: number): number
	local best, maxScore = -1, -1
	local nbuf = self._nbuf
	local n = self.map:neighbors4(tile, nbuf)
	-- Copy: _countWaterNeighbors uses the other scratch buffer.
	local a, b, c, d = nbuf[1], nbuf[2], nbuf[3], nbuf[4]
	local list = { a, b, c, d }
	for i = 1, n do
		local nb = list[i]
		if self.map:isWater(nb) then
			local score = self:_countWaterNeighbors(nb)
			if score > maxScore then
				maxScore = score
				best = nb
			end
		end
	end
	return best
end

function ShoreCoercing:findPath(from, to: number)
	local map = self.map
	local fromArray = if type(from) == "table" then from else { from }
	local waterToOriginal = {}
	local waterFrom = {}
	for _, f in fromArray do
		if map:isWater(f) then
			table.insert(waterFrom, f)
			waterToOriginal[f] = nil -- a raw water source overrides earlier coercions
		else
			local water = self:_bestWaterNeighbor(f)
			if water ~= -1 then
				table.insert(waterFrom, water)
				waterToOriginal[water] = f
			end
		end
	end
	if #waterFrom == 0 then
		return nil
	end
	local waterTo, originalTo = to, -1
	if not map:isWater(to) then
		waterTo = self:_bestWaterNeighbor(to)
		if waterTo == -1 then
			return nil
		end
		originalTo = to
	end
	local path = self.inner:findPath(if #waterFrom == 1 then waterFrom[1] else waterFrom, waterTo)
	if not path or #path == 0 then
		return nil
	end
	local originalShore = waterToOriginal[path[1]]
	if originalShore ~= nil then
		table.insert(path, 1, originalShore)
	end
	if originalTo ~= -1 and path[#path] ~= originalTo then
		table.insert(path, originalTo)
	end
	return path
end
Transformers.ShoreCoercing = ShoreCoercing

-- SmoothingWaterTransformer: LOS smoothing (binary search), local A*
-- refinement of both endpoints, then LOS smoothing again farther from shore.
local ENDPOINT_REFINEMENT_TILES = 50
local LOCAL_ASTAR_MAX_AREA = 100 * 100
local LOS_MIN_MAGNITUDE_PASS1 = 2
local LOS_MIN_MAGNITUDE_PASS2 = 3
local MAGNITUDE_MASK = 0x1f

local Smoothing = {}
Smoothing.__index = Smoothing
function Smoothing.new(inner, map, isTraversable: ((number) -> boolean)?)
	return setmetatable({
		inner = inner,
		map = map,
		mapWidth = map:width(),
		localAStar = AStarWaterBounded.new(map, LOCAL_ASTAR_MAX_AREA),
		terrain = map:terrainBuffer(),
		isTraversable = isTraversable or function(t)
			return map:isWater(t)
		end,
	}, Smoothing)
end

function Smoothing:findPath(from, to: number)
	local path = self.inner:findPath(from, to)
	return if path then self:_smooth(path) else nil
end

function Smoothing:_smooth(path: { number }): { number }
	if #path <= 2 then
		return path
	end
	local smoothed = self:_losSmooth(path, LOS_MIN_MAGNITUDE_PASS1)
	smoothed = self:_refineEndpoints(smoothed)
	smoothed = self:_losSmooth(smoothed, LOS_MIN_MAGNITUDE_PASS2)
	return smoothed
end

function Smoothing:_losSmooth(path: { number }, minMagnitude: number): { number }
	local result = { path[1] }
	-- Indices are 0-based below to mirror upstream; path[i + 1] reads index i.
	local n = #path
	local current = 0
	while current < n - 1 do
		local lo, hi = current + 1, n - 1
		local farthest = lo
		while lo <= hi do
			local mid = (lo + hi) // 2
			if self:_canSee(path[current + 1], path[mid + 1], minMagnitude) then
				farthest = mid
				lo = mid + 1
			else
				hi = mid - 1
			end
		end
		if farthest > current + 1 then
			local trace = self:_tracePath(path[current + 1], path[farthest + 1])
			if trace then
				for i = 2, #trace - 1 do
					table.insert(result, trace[i])
				end
			end
		end
		current = farthest
		if current < n - 1 then
			table.insert(result, path[current + 1])
		end
	end
	table.insert(result, path[n])
	return result
end

function Smoothing:_manhattan(a: number, b: number): number
	local w = self.mapWidth
	return math.abs(a % w - b % w) + math.abs(a // w - b // w)
end

-- 0-based index walk, like upstream findTileAtDistance.
function Smoothing:_findTileAtDistance(path: { number }, startIdx: number, distance: number, forward: boolean): number
	local cum = 0
	local idx = startIdx
	if forward then
		while idx < #path - 1 and cum < distance do
			cum += self:_manhattan(path[idx + 1], path[idx + 2])
			idx += 1
		end
	else
		while idx > 0 and cum < distance do
			cum += self:_manhattan(path[idx + 1], path[idx])
			idx -= 1
		end
	end
	return idx
end

function Smoothing:_refineSegment(from: number, to: number)
	local map = self.map
	local x0, y0, x1, y1 = map:x(from), map:y(from), map:x(to), map:y(to)
	local padding = 10
	return self.localAStar:searchBounded(from, to, {
		minX = math.max(0, math.min(x0, x1) - padding),
		maxX = math.min(map:width() - 1, math.max(x0, x1) + padding),
		minY = math.max(0, math.min(y0, y1) - padding),
		maxY = math.min(map:height() - 1, math.max(y0, y1) + padding),
	})
end

function Smoothing:_refineEndpoints(path: { number }): { number }
	if #path <= 2 then
		return path
	end
	local result = path
	local startEndIdx = self:_findTileAtDistance(path, 0, ENDPOINT_REFINEMENT_TILES, true)
	if startEndIdx > 1 then
		local seg = self:_refineSegment(path[1], path[startEndIdx + 1])
		if seg and #seg > 0 then
			local merged = table.move(seg, 1, #seg - 1, 1, {})
			table.move(result, startEndIdx + 1, #result, #merged + 1, merged)
			result = merged
		end
	end
	local endStartIdx = self:_findTileAtDistance(result, #result - 1, ENDPOINT_REFINEMENT_TILES, false)
	if endStartIdx < #result - 2 then
		local seg = self:_refineSegment(result[#result], result[endStartIdx + 1])
		if seg and #seg > 0 then
			local merged = table.move(result, 1, endStartIdx, 1, {})
			for i = #seg, 1, -1 do -- reversed
				table.insert(merged, seg[i])
			end
			result = merged
		end
	end
	return result
end

function Smoothing:_canSee(from: number, to: number, minMagnitude: number): boolean
	local w = self.mapWidth
	local terrain = self.terrain
	local trav = self.isTraversable
	local x0, y0, x1, y1 = from % w, from // w, to % w, to // w
	local dx, dy = math.abs(x1 - x0), math.abs(y1 - y0)
	local sx = if x0 < x1 then 1 else -1
	local sy = if y0 < y1 then 1 else -1
	local err = dx - dy
	local x, y = x0, y0
	local iterations = 0
	while true do
		iterations += 1
		if iterations > 100001 then
			return false
		end
		local tile = y * w + x
		if not trav(tile) then
			return false
		end
		if band(readu8(terrain, tile), MAGNITUDE_MASK) < minMagnitude then
			return false
		end
		if x == x1 and y == y1 then
			return true
		end
		local e2 = 2 * err
		local moveX, moveY = e2 > -dy, e2 < dx
		if moveX and moveY then
			x += sx
			err -= dy
			local it = y * w + x
			if not trav(it) or band(readu8(terrain, it), MAGNITUDE_MASK) < minMagnitude then
				x -= sx
				err += dy
				y += sy
				err += dx
				local alt = y * w + x
				if not trav(alt) or band(readu8(terrain, alt), MAGNITUDE_MASK) < minMagnitude then
					return false
				end
				x += sx
				err -= dy
			else
				y += sy
				err += dx
			end
		else
			if moveX then
				x += sx
				err -= dy
			end
			if moveY then
				y += sy
				err += dx
			end
		end
	end
end

function Smoothing:_tracePath(from: number, to: number): { number }?
	local w = self.mapWidth
	local trav = self.isTraversable
	local x0, y0, x1, y1 = from % w, from // w, to % w, to // w
	local tiles = {}
	local dx, dy = math.abs(x1 - x0), math.abs(y1 - y0)
	local sx = if x0 < x1 then 1 else -1
	local sy = if y0 < y1 then 1 else -1
	local err = dx - dy
	local x, y = x0, y0
	local iterations = 0
	while true do
		iterations += 1
		if iterations > 100001 then
			return nil
		end
		local tile = y * w + x
		if not trav(tile) then
			return nil
		end
		table.insert(tiles, tile)
		if x == x1 and y == y1 then
			break
		end
		local e2 = 2 * err
		local moveX, moveY = e2 > -dy, e2 < dx
		if moveX and moveY then
			x += sx
			err -= dy
			local it = y * w + x
			if not trav(it) then
				x -= sx
				err += dy
				y += sy
				err += dx
				local alt = y * w + x
				if not trav(alt) then
					return nil
				end
				table.insert(tiles, alt)
				x += sx
				err -= dy
			else
				table.insert(tiles, it)
				y += sy
				err += dx
			end
		else
			if moveX then
				x += sx
				err -= dy
			end
			if moveY then
				y += sy
				err += dx
			end
		end
	end
	return tiles
end
Transformers.Smoothing = Smoothing

return Transformers
