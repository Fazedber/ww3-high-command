-- Rocket flight paths: port of upstream utilities/Line.ts
-- (DistanceBasedBezierCurve) and pathfinding/PathFinder.Parabola.ts.
-- Shared: the server steps nukes with it and clients replay the same path
-- from a motion plan (src, dst, speed, direction, start tick).
--
-- The curve is walked with 8-bit fixed-point integers (x256) and JS `>>`
-- shifts; every value stays non-negative and far below 2^31, so `>> n` is
-- floor division and plain Luau arithmetic reproduces it exactly.

local Util = require(script.Parent.Util)

-- Same values as the server's PathFinder.PathStatus.
local PathStatus = table.freeze({ NEXT = 0, COMPLETE = 2, NOT_FOUND = 3 })

local within = Util.within

local SUB_SCALE = 256

local function jsRound(x: number): number
	return math.floor(x + 0.5)
end

local function half(v: number): number -- v >> 1
	return math.floor(v / 2)
end

-- DistanceBasedBezierCurve ----------------------------------------------------------

local Bezier = {}
Bezier.__index = Bezier

-- Single-pass in-order recursive De Casteljau subdivision (sharedSubdivide).
local function subdivide(ax, ay, bx, by, cx, cy, dx, dy, depth, st)
	local dist = math.abs(bx - ax) + math.abs(by - ay) + math.abs(cx - bx) + math.abs(cy - by) + math.abs(dx - cx) + math.abs(dy - cy)
	if dist <= 256 or depth >= 10 then
		local edx = ax - st.lastX
		local edy = ay - st.lastY
		st.accumDist += math.floor(math.sqrt(edx * edx + edy * edy))
		st.lastX = ax
		st.lastY = ay
		if st.stepThreshold ~= nil and st.cachedPoints ~= nil then
			while st.accumDist >= st.stepThreshold do
				table.insert(st.cachedPoints, { x = math.floor((ax + 128) / 256), y = math.floor((ay + 128) / 256) })
				st.accumDist -= st.stepThreshold
			end
		end
		return
	end
	local m01x, m01y = half(ax + bx), half(ay + by)
	local m12x, m12y = half(bx + cx), half(by + cy)
	local m23x, m23y = half(cx + dx), half(cy + dy)
	local m012x, m012y = half(m01x + m12x), half(m01y + m12y)
	local m123x, m123y = half(m12x + m23x), half(m12y + m23y)
	local mx, my = half(m012x + m123x), half(m012y + m123y)
	subdivide(ax, ay, m01x, m01y, m012x, m012y, mx, my, depth + 1, st)
	subdivide(mx, my, m123x, m123y, m23x, m23y, dx, dy, depth + 1, st)
end

function Bezier.new(p0, p1, p2, p3, distanceIncrement: number)
	local self = setmetatable({
		p0 = p0,
		p1 = p1,
		p2 = p2,
		p3 = p3,
		cachedPoints = {},
		currentIndex = 0, -- 0-based like upstream
		pixelSpacingScaled = 1,
		accumulatedDistanceScaled = 0,
	}, Bezier)
	self:computeAllPoints(distanceIncrement)
	return self
end

-- Full curve length without allocating points (static getLength).
function Bezier.getLength(p0, p1, p2, p3): number
	local scale = 256
	local p0x, p0y = jsRound(p0.x) * scale, jsRound(p0.y) * scale
	local p3x, p3y = jsRound(p3.x) * scale, jsRound(p3.y) * scale
	local st = { lastX = p0x, lastY = p0y, accumDist = 0 }
	subdivide(p0x, p0y, jsRound(p1.x) * scale, jsRound(p1.y) * scale, jsRound(p2.x) * scale, jsRound(p2.y) * scale, p3x, p3y, 0, st)
	local edx, edy = p3x - st.lastX, p3y - st.lastY
	st.accumDist += math.floor(math.sqrt(edx * edx + edy * edy))
	return st.accumDist / scale
end

function Bezier:getAllPoints()
	return self.cachedPoints
end

-- Advance by `distance`; the next cached point, or nil at the end.
function Bezier:increment(distance: number?)
	self.accumulatedDistanceScaled += math.max(1, jsRound((distance or 1) * SUB_SCALE))
	local n = #self.cachedPoints
	while self.currentIndex < n - 1 and self.accumulatedDistanceScaled >= self.pixelSpacingScaled do
		self.currentIndex += 1
		self.accumulatedDistanceScaled -= self.pixelSpacingScaled
	end
	if self.currentIndex >= n - 1 then
		return nil
	end
	return self.cachedPoints[self.currentIndex + 1]
end

function Bezier:getCurrentIndex(): number
	return self.currentIndex
end

function Bezier:computeAllPoints(pixelSpacing: number)
	self.cachedPoints = {}
	self.currentIndex = 0
	self.accumulatedDistanceScaled = 0
	self.pixelSpacingScaled = math.max(SUB_SCALE, jsRound(pixelSpacing * SUB_SCALE))
	local scale = SUB_SCALE
	local p0x, p0y = jsRound(self.p0.x) * scale, jsRound(self.p0.y) * scale
	local p3x, p3y = jsRound(self.p3.x) * scale, jsRound(self.p3.y) * scale
	local st = {
		lastX = p0x,
		lastY = p0y,
		accumDist = 0,
		stepThreshold = self.pixelSpacingScaled,
		cachedPoints = self.cachedPoints,
	}
	table.insert(self.cachedPoints, { x = math.floor((p0x + 128) / 256), y = math.floor((p0y + 128) / 256) })
	subdivide(
		p0x,
		p0y,
		jsRound(self.p1.x) * scale,
		jsRound(self.p1.y) * scale,
		jsRound(self.p2.x) * scale,
		jsRound(self.p2.y) * scale,
		p3x,
		p3y,
		0,
		st
	)
	-- Ensure the endpoint is included.
	local last = { x = math.floor((p3x + 128) / 256), y = math.floor((p3y + 128) / 256) }
	local endCached = self.cachedPoints[#self.cachedPoints]
	if endCached == nil or endCached.x ~= last.x or endCached.y ~= last.y then
		table.insert(self.cachedPoints, last)
	end
end

-- getParabolaControlPoints -------------------------------------------------------------

local PARABOLA_MIN_HEIGHT = 50

local Parabola = {}
Parabola.Bezier = Bezier
Parabola.PathStatus = PathStatus

-- options: { increment, distanceBasedHeight = true, directionUp = true, ignoreMapBounds = false }
function Parabola.controlPoints(gameMap, from: number, to: number, options)
	options = options or {}
	local distanceBasedHeight = if options.distanceBasedHeight == nil then true else options.distanceBasedHeight
	local directionUp = if options.directionUp == nil then true else options.directionUp
	local ignoreMapBounds = options.ignoreMapBounds == true

	local p0 = { x = gameMap:x(from), y = gameMap:y(from) }
	local p3 = { x = gameMap:x(to), y = gameMap:y(to) }
	local dx = p3.x - p0.x
	local dy = p3.y - p0.y
	local distance = math.sqrt(dx * dx + dy * dy)
	local maxHeight = if distanceBasedHeight then math.max(distance / 3, PARABOLA_MIN_HEIGHT) else 0
	local heightMult = if directionUp then -1 else 1
	local mapHeight = gameMap:height()

	local p1y = p0.y + dy / 4 + heightMult * maxHeight
	local p2y = p0.y + (dy * 3) / 4 + heightMult * maxHeight
	local p1 = { x = p0.x + dx / 4, y = if ignoreMapBounds then p1y else within(p1y, 0, mapHeight - 1) }
	local p2 = { x = p0.x + (dx * 3) / 4, y = if ignoreMapBounds then p2y else within(p2y, 0, mapHeight - 1) }
	return p0, p1, p2, p3
end

-- ParabolaUniversalPathFinder ----------------------------------------------------------------

local Finder = {}
Finder.__index = Finder

function Parabola.new(gameMap, options)
	return setmetatable({ gameMap = gameMap, options = options or {}, curve = nil, lastTo = nil }, Finder)
end

function Finder:_createCurve(from: number, to: number)
	local p0, p1, p2, p3 = Parabola.controlPoints(self.gameMap, from, to, self.options)
	return Bezier.new(p0, p1, p2, p3, self.options.increment or 3)
end

function Finder:findPath(from: number, to: number): { number }
	local curve = self:_createCurve(from, to)
	local out = {}
	for i, p in curve:getAllPoints() do
		out[i] = self.gameMap:ref(math.floor(p.x), math.floor(p.y))
	end
	return out
end

function Finder:next(from: number, to: number, speed: number?)
	if self.lastTo ~= to then
		self.curve = self:_createCurve(from, to)
		self.lastTo = to
	end
	local p = self.curve:increment(speed or 1)
	if p == nil then
		return { status = PathStatus.COMPLETE, node = to }
	end
	return { status = PathStatus.NEXT, node = self.gameMap:ref(math.floor(p.x), math.floor(p.y)) }
end

function Finder:invalidate()
	self.curve = nil
	self.lastTo = nil
end

function Finder:currentIndex(): number
	return if self.curve then self.curve:getCurrentIndex() else 0
end

-- Tiles a nuke visits, one per tick from its start tick (the path upstream's
-- recordMotionPlan replays): src, then every next() until COMPLETE.
function Parabola.motionPath(gameMap, src: number, dst: number, speed: number, directionUp: boolean?): { number }
	local finder = Parabola.new(gameMap, { increment = speed, directionUp = directionUp })
	local path = { src }
	local r = finder:next(src, dst, speed)
	while r.status == PathStatus.NEXT do
		table.insert(path, r.node)
		r = finder:next(src, dst, speed)
	end
	return path
end

return Parabola
