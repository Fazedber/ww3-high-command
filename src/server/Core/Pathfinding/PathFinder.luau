-- Port of OpenFrontIO src/core/pathfinding/PathFinder.ts (water parts),
-- PathFinderStepper.ts and types.ts.
--
-- A water path query runs through a transformer chain shared per game:
--   MiniMap( ShoreCoercing( Smoothing( ComponentCheck( HPA* ) ) ) )
-- or, when the abstract graph is missing / tiny, MiniMap(ShoreCoercing(A*)).
-- Air (SAM missiles) is here; Parabola (rockets) lives in Parabola.luau.
-- Rail (railroads) and Stations (train routing) are at the end.
-- TODO(port): WaterPathMemo (trade ships).

local AStarWater = require(script.Parent.AStarWater)
local Transformers = require(script.Parent.Transformers)

local PathFinder = {}

local PathStatus = table.freeze({ NEXT = 0, COMPLETE = 2, NOT_FOUND = 3 })
PathFinder.PathStatus = PathStatus

-- PathFinderStepper -----------------------------------------------------------------

local Stepper = {}
Stepper.__index = Stepper

function Stepper.new(finder, config)
	return setmetatable({
		finder = finder,
		config = config or {
			equals = function(a, b)
				return a == b
			end,
		},
		path = nil,
		pathIndex = 0, -- 0-based, like upstream
		lastTo = nil,
	}, Stepper)
end

-- Next step from `from` toward `to`: { status, node? }.
function Stepper:next(from: number, to: number, dist: number?)
	local config = self.config
	if config.preCheck then
		local r = config.preCheck(from, to)
		if r then
			return r
		end
	end
	if config.equals(from, to) then
		return { status = PathStatus.COMPLETE, node = to }
	end
	if dist ~= nil and dist > 0 and config.distance then
		if config.distance(from, to) <= dist then
			return { status = PathStatus.COMPLETE, node = from }
		end
	end
	if self.lastTo == nil or not config.equals(self.lastTo, to) then
		self.path = nil
		self.pathIndex = 0
		self.lastTo = to
	end
	if self.path == nil then
		local ok, path = pcall(function()
			return self.finder:findPath(from, to)
		end)
		if not ok then
			warn("PathFinder threw an error during findPath", path)
			return { status = PathStatus.NOT_FOUND }
		end
		if path == nil then
			return { status = PathStatus.NOT_FOUND }
		end
		self.path = path
		self.pathIndex = 0
		if #path > 0 and config.equals(path[1], from) then
			self.pathIndex = 1
		end
	end
	local path = self.path
	if self.pathIndex > 0 and not config.equals(from, path[self.pathIndex]) then
		self:invalidate()
		self.lastTo = to
		return self:next(from, to, dist)
	end
	if self.pathIndex >= #path then
		return { status = PathStatus.COMPLETE, node = to }
	end
	local nextNode = path[self.pathIndex + 1]
	self.pathIndex += 1
	return { status = PathStatus.NEXT, node = nextNode }
end

function Stepper:invalidate()
	self.path = nil
	self.pathIndex = 0
	self.lastTo = nil
end

-- Copy of the active path starting at the node most recently returned.
function Stepper:pathAfterNext()
	if self.path == nil or self.pathIndex == 0 then
		return nil
	end
	return table.move(self.path, self.pathIndex, #self.path, 1, {})
end

-- One-shot route without touching the cached route.
function Stepper:findPath(from, to: number)
	local config = self.config
	if config.preCheck then
		local fromArray = if type(from) == "table" then from else { from }
		local allFailed = true
		for _, f in fromArray do
			local r = config.preCheck(f, to)
			if not (r and r.status == PathStatus.NOT_FOUND) then
				allFailed = false
				break
			end
		end
		if allFailed then
			return nil
		end
	end
	return self.finder:findPath(from, to)
end
PathFinder.Stepper = Stepper

-- Shared water chain ------------------------------------------------------------------

local chainCache = setmetatable({}, { __mode = "k" }) -- game -> { version, chain }

local function buildWaterChain(game)
	local hpa = game:miniWaterHPA()
	local graph = game:miniWaterGraph()
	local miniMap = game:miniMap()
	if not hpa or not graph or graph.nodeCount < 100 then
		local chain = AStarWater.new(miniMap)
		chain = Transformers.ShoreCoercing.new(chain, miniMap)
		return Transformers.MiniMap.new(chain, game:map(), miniMap)
	end
	local chain = Transformers.ComponentCheck.new(hpa, function(t)
		return graph:getComponentId(t)
	end)
	chain = Transformers.Smoothing.new(chain, miniMap)
	chain = Transformers.ShoreCoercing.new(chain, miniMap)
	return Transformers.MiniMap.new(chain, game:map(), miniMap)
end

local function sharedWaterChain(game)
	local version = game:waterGraphVersion()
	local cached = chainCache[game]
	if not cached or cached.version ~= version then
		cached = { version = version, chain = buildWaterChain(game) }
		chainCache[game] = cached
	end
	return cached.chain
end
PathFinder.sharedWaterChain = sharedWaterChain

local function tileStepperConfig(game)
	return {
		equals = function(a, b)
			return a == b
		end,
		distance = function(a, b)
			return game:manhattanDist(a, b)
		end,
		preCheck = function(from, to)
			if type(from) ~= "number" or type(to) ~= "number" or not game:isValidRef(from) or not game:isValidRef(to) then
				return { status = PathStatus.NOT_FOUND }
			end
			return nil
		end,
	}
end

-- Upstream PathFinding.Water(game): a fresh stepper over the shared chain.
function PathFinder.Water(game)
	return Stepper.new(sharedWaterChain(game), tileStepperConfig(game))
end

-- WaterPathFinder ---------------------------------------------------------------------

local WaterPathFinder = {}
WaterPathFinder.__index = WaterPathFinder
WaterPathFinder.STAGGER_SPREAD = 50

-- stagger: ticks to wait before rebuilding after a water-graph change.
function WaterPathFinder.new(game, stagger: number?)
	return setmetatable({
		game = game,
		_stagger = stagger or 0,
		stepper = Stepper.new(sharedWaterChain(game), tileStepperConfig(game)),
		_version = game:waterGraphVersion(),
		_rebuilt = false,
		_countdown = 0,
		_pendingVersion = -1,
	}, WaterPathFinder)
end

function WaterPathFinder:_ensureFresh()
	local v = self.game:waterGraphVersion()
	if v == self._version then
		return
	end
	if self._pendingVersion ~= v then
		self._pendingVersion = v
		self._countdown = self._stagger
	end
	if self._countdown > 0 then
		self._countdown -= 1
		return
	end
	self._version = v
	self.stepper = Stepper.new(sharedWaterChain(self.game), tileStepperConfig(self.game))
	self._rebuilt = true
end

-- True once after the pathfinder was rebuilt (resets on read).
function WaterPathFinder:rebuilt(): boolean
	self:_ensureFresh()
	local v = self._rebuilt
	self._rebuilt = false
	return v
end

function WaterPathFinder:next(from: number, to: number, dist: number?)
	self:_ensureFresh()
	return self.stepper:next(from, to, dist)
end

function WaterPathFinder:findPath(from, to: number)
	self:_ensureFresh()
	return self.stepper:findPath(from, to)
end

function WaterPathFinder:pathForTraversal(from: number, to: number)
	self:_ensureFresh()
	local path = self.stepper:pathAfterNext() or self.stepper:findPath(from, to)
	if path == nil or #path == 0 then
		return { from }
	end
	if path[1] == from then
		return path
	end
	table.insert(path, 1, from)
	return path
end

function WaterPathFinder:invalidate()
	self.stepper:invalidate()
end
PathFinder.WaterPathFinder = WaterPathFinder

-- AirPathFinder (PathFinder.Air.ts): a straight-ish staircase seeded by the
-- tick the finder was made, stepped like every other finder.

local PseudoRandom = require(game:GetService("ReplicatedStorage").Shared.PseudoRandom)

local AirFinder = {}
AirFinder.__index = AirFinder

function AirFinder.new(game)
	return setmetatable({ game = game, seed = game:ticks() }, AirFinder)
end

function AirFinder:_computeNext(from: number, to: number, random): number
	local g = self.game
	local x, y = g:x(from), g:y(from)
	local dstX, dstY = g:x(to), g:y(to)
	if x == dstX and y == dstY then
		return to
	end
	local nextX, nextY = x, y
	local ratio = math.floor(1 + math.abs(dstY - y) / (math.abs(dstX - x) + 1))
	if x == dstX then
		nextY += if y < dstY then 1 else -1
	elseif y == dstY then
		nextX += if x < dstX then 1 else -1
	elseif random:chance(ratio) then
		nextX += if x < dstX then 1 else -1
	else
		nextY += if y < dstY then 1 else -1
	end
	return g:ref(nextX, nextY)
end

function AirFinder:findPath(from, to: number)
	assert(type(from) == "number", "AirPathFinder does not support multiple start points")
	local random = PseudoRandom.new(self.seed)
	local path = { from }
	local current = from
	while current ~= to do
		local nextTile = self:_computeNext(current, to, random)
		if nextTile == current then
			break
		end
		current = nextTile
		table.insert(path, current)
	end
	return path
end

function PathFinder.Air(game)
	return Stepper.new(AirFinder.new(game))
end


-- Rail (AStar.Rail.ts) -----------------------------------------------------------------
-- A* over the minimap: land freely, water only along shorelines, with water /
-- shoreline and direction-change penalties.

local AStar = require(script.Parent.AStar)

local RailAdapter = {}
RailAdapter.__index = RailAdapter
local WATER_PENALTY = 5
local HEURISTIC_WEIGHT = 2
local DIRECTION_CHANGE_PENALTY = 3

function RailAdapter.new(gameMap)
	local w, h = gameMap:width(), gameMap:height()
	return setmetatable({ map = gameMap, width = w, height = h, n = w * h }, RailAdapter)
end
function RailAdapter:numNodes(): number
	return self.n
end
function RailAdapter:maxNeighbors(): number
	return 4
end
function RailAdapter:maxPriority(): number
	local maxCost = 1 + WATER_PENALTY + DIRECTION_CHANGE_PENALTY
	return HEURISTIC_WEIGHT * (self.width + self.height) * maxCost
end
function RailAdapter:_traversable(to: number, fromShoreline: boolean, isImpassable: boolean): boolean
	if isImpassable then
		return false
	end
	if not self.map:isWater(to) then
		return true
	end
	return fromShoreline or self.map:isShoreline(to)
end
function RailAdapter:neighbors(node: number, buf: { number }): number
	local count = 0
	local w = self.width
	local x = node % w
	local fromShoreline = self.map:isShoreline(node)
	local isImpassable = self.map:isImpassable(node)
	if node >= w then
		local n = node - w
		if self:_traversable(n, fromShoreline, isImpassable) then
			count += 1
			buf[count] = n
		end
	end
	if node < self.n - w then
		local n = node + w
		if self:_traversable(n, fromShoreline, isImpassable) then
			count += 1
			buf[count] = n
		end
	end
	if x ~= 0 then
		local n = node - 1
		if self:_traversable(n, fromShoreline, isImpassable) then
			count += 1
			buf[count] = n
		end
	end
	if x ~= w - 1 then
		local n = node + 1
		if self:_traversable(n, fromShoreline, isImpassable) then
			count += 1
			buf[count] = n
		end
	end
	return count
end
function RailAdapter:cost(from: number, to: number, prev: number?): number
	local penalized = self.map:isWater(to) or self.map:isShoreline(to)
	local c = if penalized then 1 + WATER_PENALTY else 1
	if prev ~= nil and from - prev ~= to - from then
		c += DIRECTION_CHANGE_PENALTY
	end
	return c
end
function RailAdapter:heuristic(node: number, goal: number): number
	local w = self.width
	local nx, ny = node % w, node // w
	local gx, gy = goal % w, goal // w
	return HEURISTIC_WEIGHT * (math.abs(nx - gx) + math.abs(ny - gy))
end

-- Upstream builds a new AStarRail per query; the stamped buffers make reusing
-- one per minimap equivalent.
local railAStarCache = setmetatable({}, { __mode = "k" })

function PathFinder.Rail(game)
	local miniMap = game:miniMap()
	local astar = railAStarCache[miniMap]
	if astar == nil then
		astar = AStar.new(RailAdapter.new(miniMap))
		railAStarCache[miniMap] = astar
	end
	return Stepper.new(Transformers.MiniMap.new(astar, game:map(), miniMap), tileStepperConfig(game))
end

-- Stations (PathFinder.Station.ts) ---------------------------------------------------------
-- A* over the station graph (ids from the StationManager), unit costs and a
-- Manhattan heuristic; only within the destination's cluster.

local StationAdapter = {}
StationAdapter.__index = StationAdapter
function StationAdapter:numNodes(): number
	return self.manager:count()
end
function StationAdapter:maxNeighbors(): number
	return 32
end
function StationAdapter:maxPriority(): number
	return self.game:map():width() + self.game:map():height()
end
function StationAdapter:neighbors(node: number, buf: { number }): number
	local station = self.manager:getById(node)
	if not station then
		return 0
	end
	local count = 0
	for _, n in station:neighbors() do
		count += 1
		buf[count] = n.id
	end
	return count
end
function StationAdapter:cost(): number
	return 1
end
function StationAdapter:heuristic(node: number, goal: number): number
	local a, b = self.manager:getById(node), self.manager:getById(goal)
	if not a or not b then
		return 0
	end
	local g = self.game
	return math.abs(g:x(a:tile()) - g:x(b:tile())) + math.abs(g:y(a:tile()) - g:y(b:tile()))
end

local StationFinder = {}
StationFinder.__index = StationFinder
function StationFinder.new(game)
	local manager = game:railNetwork():stationManager()
	local adapter = setmetatable({ game = game, manager = manager }, StationAdapter)
	return setmetatable({ manager = manager, aStar = AStar.new(adapter) }, StationFinder)
end
function StationFinder:findPath(from, to)
	local toCluster = to:getCluster()
	local fromArray = if type(from) == "table" and from.unit == nil then from else { from }
	local fromIds = {}
	for _, s in fromArray do
		if s:getCluster() == toCluster then
			table.insert(fromIds, s.id)
		end
	end
	if #fromIds == 0 then
		return nil
	end
	local path = self.aStar:findPath(fromIds, to.id)
	if not path then
		return nil
	end
	local out = table.create(#path)
	for i, id in path do
		out[i] = self.manager:getById(id)
	end
	return out
end

function PathFinder.Stations(game)
	return Stepper.new(StationFinder.new(game), {
		equals = function(a, b)
			return a.id == b.id
		end,
		distance = function(a, b)
			return game:manhattanDist(a:tile(), b:tile())
		end,
	})
end

return PathFinder
