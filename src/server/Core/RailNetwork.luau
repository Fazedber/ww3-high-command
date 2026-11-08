-- Port of OpenFrontIO src/core/game/RailNetworkImpl.ts, TrainStation.ts,
-- Railroad.ts and RailroadSpatialGrid.ts: train stations on cities, ports
-- and factories, the railroads between them and their connected clusters.
--
-- JS Sets whose iteration order matters (stations, railroads, cluster
-- members, grid query results) are JSSets.

local Shared = game:GetService("ReplicatedStorage").Shared
local JSSet = require(Shared.JSSet)
local Util = require(Shared.Util)
local GameTypes = require(script.Parent.GameTypes)
local PathFinder = require(script.Parent.Pathfinding.PathFinder)

local UnitType = GameTypes.UnitType

local RailNetwork = {}

-- Railroad ----------------------------------------------------------------------------

local Railroad = {}
Railroad.__index = Railroad

function Railroad.new(from, to, tiles: { number }, id: number)
	return setmetatable({ from = from, to = to, tiles = tiles, id = id }, Railroad)
end

function Railroad:delete(game)
	game:addUpdate({ type = "RailroadDestructionEvent", id = self.id })
	self.from:removeRailroad(self)
	self.to:removeRailroad(self)
end

-- 0-based index of the tile closest to `to`, like upstream.
function Railroad:getClosestTileIndex(game, to: number): number
	local tiles = self.tiles
	if #tiles == 0 then
		return -1
	end
	local toX, toY = game:x(to), game:y(to)
	local closest, minD = 0, math.huge
	for i, tile in tiles do
		local dx, dy = game:x(tile) - toX, game:y(tile) - toY
		local d = dx * dx + dy * dy
		if d < minD then
			minD = d
			closest = i - 1
		end
	end
	return closest
end

-- A railroad seen from one end, so its tiles always start at that end.
local OrientedRailroad = {}
OrientedRailroad.__index = OrientedRailroad

function OrientedRailroad.new(railroad, forward: boolean)
	local tiles = railroad.tiles
	if not forward then
		local n = #tiles
		local rev = table.create(n)
		for i = 1, n do
			rev[i] = tiles[n - i + 1]
		end
		tiles = rev
	end
	return setmetatable({ railroad = railroad, forward = forward, tiles = tiles }, OrientedRailroad)
end
function OrientedRailroad:getTiles(): { number }
	return self.tiles
end
function OrientedRailroad:getStart()
	return if self.forward then self.railroad.from else self.railroad.to
end
function OrientedRailroad:getEnd()
	return if self.forward then self.railroad.to else self.railroad.from
end

function RailNetwork.getOrientedRailroad(from, to)
	local railroad = from:getRailroadTo(to)
	if not railroad then
		return nil
	end
	return OrientedRailroad.new(railroad, railroad.to == to)
end

-- RailSpatialGrid ---------------------------------------------------------------------

local RailSpatialGrid = {}
RailSpatialGrid.__index = RailSpatialGrid

function RailSpatialGrid.new(gameMap, cellSize: number)
	return setmetatable({ game = gameMap, cellSize = cellSize, cells = {}, railToCells = {} }, RailSpatialGrid)
end

function RailSpatialGrid:_key(cx: number, cy: number): string
	return `{cx}:{cy}`
end

function RailSpatialGrid:register(rail)
	self:unregister(rail)
	local railCells = {}
	local any = false
	for _, tile in rail.tiles do
		local k = self:_key(self.game:x(tile) // self.cellSize, self.game:y(tile) // self.cellSize)
		if railCells[k] then
			continue
		end
		local set = self.cells[k]
		if not set then
			set = JSSet.new()
			self.cells[k] = set
		end
		railCells[k] = true
		any = true
		set:add(rail)
	end
	if any then
		self.railToCells[rail] = railCells
	end
end

function RailSpatialGrid:unregister(rail)
	local keys = self.railToCells[rail]
	if not keys then
		return
	end
	for k in keys do
		local set = self.cells[k]
		if set then
			set:delete(rail)
			if set:size() == 0 then
				self.cells[k] = nil
			end
		end
	end
	self.railToCells[rail] = nil
end

function RailSpatialGrid:query(tile: number, radius: number)
	local x, y = self.game:x(tile), self.game:y(tile)
	local cs = self.cellSize
	local result = JSSet.new()
	for cx = (x - radius) // cs, (x + radius) // cs do
		for cy = (y - radius) // cs, (y + radius) // cs do
			local set = self.cells[self:_key(cx, cy)]
			if set then
				for rail in set do
					result:add(rail)
				end
			end
		end
	end
	return result
end

-- TrainStation / Cluster ----------------------------------------------------------------

local function rel(player, other): string
	if player == other then
		return "self"
	end
	if player:isOnSameTeam(other) then
		return "team"
	end
	if player:isAlliedWith(other) then
		return "ally"
	end
	return "other"
end

local TrainStation = {}
TrainStation.__index = TrainStation

function TrainStation.new(mg, unit)
	return setmetatable({
		id = -1, -- assigned by the StationManager
		mg = mg,
		unit = unit,
		cluster = nil,
		railroads = JSSet.new(),
		railroadByNeighbor = {},
	}, TrainStation)
end

function TrainStation:tradeAvailable(otherPlayer): boolean
	local player = self.unit:owner()
	return otherPlayer == player or player:canTrade(otherPlayer)
end

function TrainStation:clearRailroads()
	self.railroads:clear()
	table.clear(self.railroadByNeighbor)
end

function TrainStation:addRailroad(railroad)
	self.railroads:add(railroad)
	local neighbor = if railroad.from == self then railroad.to else railroad.from
	self.railroadByNeighbor[neighbor] = railroad
end

function TrainStation:removeRailroad(railroad)
	self.railroads:delete(railroad)
	local neighbor = if railroad.from == self then railroad.to else railroad.from
	self.railroadByNeighbor[neighbor] = nil
end

function TrainStation:neighbors()
	local out = {}
	for r in self.railroads do
		table.insert(out, if r.from ~= self then r.from else r.to)
	end
	return out
end

function TrainStation:tile(): number
	return self.unit:tile()
end

function TrainStation:isActive(): boolean
	return self.unit:isActive()
end

function TrainStation:getRailroads()
	return self.railroads
end

function TrainStation:getRailroadTo(station)
	return self.railroadByNeighbor[station]
end

function TrainStation:setCluster(cluster)
	-- Properly disconnect from the previous cluster.
	if self.cluster ~= nil and self.cluster ~= cluster then
		self.cluster:removeStation(self)
	end
	self.cluster = cluster
end

function TrainStation:getCluster()
	return self.cluster
end

-- City and port stops pay both the train owner and (if different) the
-- station owner; factory stops pay nothing.
function TrainStation:onTrainStop(trainExecution)
	local t = self.unit:type()
	if t ~= UnitType.City and t ~= UnitType.Port then
		return
	end
	local mg = self.mg
	local stationOwner = self.unit:owner()
	local trainOwner = trainExecution:owner()
	local gold = mg:config():trainGold(rel(trainOwner, stationOwner), trainExecution:tradeStopsVisited(), trainOwner)
	if trainOwner ~= stationOwner then
		stationOwner:addGold(gold, self:tile())
		stationOwner:addTrainGold(gold)
	end
	trainOwner:addGold(gold, self:tile())
	trainOwner:addTrainGold(gold)
end

local Cluster = {}
Cluster.__index = Cluster

function Cluster.new()
	return setmetatable({ stations = JSSet.new(), tradeStations = JSSet.new() }, Cluster)
end

local function isTradeStation(station): boolean
	local t = station.unit:type()
	return t == UnitType.City or t == UnitType.Port
end

function Cluster:has(station): boolean
	return self.stations:has(station)
end

function Cluster:addStation(station)
	self.stations:add(station)
	if isTradeStation(station) then
		self.tradeStations:add(station)
	end
	station:setCluster(self)
end

function Cluster:removeStation(station)
	self.stations:delete(station)
	self.tradeStations:delete(station)
end

function Cluster:addStations(stations)
	for station in stations do
		self:addStation(station)
	end
end

function Cluster:merge(other)
	for s in other.stations do
		self:addStation(s)
	end
end

function Cluster:hasAnyTradeDestination(player): boolean
	for station in self.tradeStations do
		if station:tradeAvailable(player) then
			return true
		end
	end
	return false
end

-- Reservoir sampling over the eligible trade stations.
function Cluster:randomTradeDestination(player, random)
	local selected = nil
	local eligibleSeen = 0
	for station in self.tradeStations do
		if not station:tradeAvailable(player) then
			continue
		end
		eligibleSeen += 1
		if random:nextInt(0, eligibleSeen) == 0 then
			selected = station
		end
	end
	return selected
end

function Cluster:availableForTrade(player)
	local out = JSSet.new()
	for station in self.tradeStations do
		if station:tradeAvailable(player) then
			out:add(station)
		end
	end
	return out
end

function Cluster:size(): number
	return self.stations:size()
end

function Cluster:clear()
	self.stations:clear()
	self.tradeStations:clear()
end

RailNetwork.TrainStation = TrainStation
RailNetwork.Cluster = Cluster
RailNetwork.Railroad = Railroad

-- StationManager ---------------------------------------------------------------------------

local StationManager = {}
StationManager.__index = StationManager

function StationManager.new()
	return setmetatable({ stations = JSSet.new(), stationsById = {}, nextId = 1 }, StationManager)
end

function StationManager:addStation(station)
	station.id = self.nextId
	self.nextId += 1
	self.stationsById[station.id] = station
	self.stations:add(station)
end

function StationManager:removeStation(station)
	self.stationsById[station.id] = nil
	self.stations:delete(station)
end

function StationManager:findStation(unit)
	for station in self.stations do
		if station.unit == unit then
			return station
		end
	end
	return nil
end

function StationManager:getAll()
	return self.stations
end

function StationManager:getById(id: number)
	return self.stationsById[id]
end

function StationManager:count(): number
	return self.nextId
end

-- RailNetworkImpl ---------------------------------------------------------------------------

local Impl = {}
-- os.clock() deadline for rail work this tick (see TrainStationExecution).
Impl.sliceDeadline = math.huge
Impl.__index = Impl

local MAX_CONNECTION_DISTANCE = 4
local STATION_RADIUS = 3
local GRID_CELL_SIZE = 4

function RailNetwork.new(game)
	return setmetatable({
		game = game,
		_stationManager = StationManager.new(),
		railGrid = RailSpatialGrid.new(game, GRID_CELL_SIZE),
		nextId = 0,
		dirtyClusters = JSSet.new(),
	}, Impl)
end

function Impl:stationManager()
	return self._stationManager
end

function Impl:_findTilePath(from: number, to: number): { number }
	return PathFinder.Rail(self.game):findPath(from, to) or {}
end

function Impl:findStationsPath(from, to)
	return PathFinder.Stations(self.game):findPath(from, to) or {}
end

function Impl:connectStation(station)
	self._stationManager:addStation(station)
	if not self:_connectToExistingRails(station) then
		self:_connectToNearbyStations(station)
	end
end

function Impl:recomputeClusters()
	if self.dirtyClusters:size() == 0 then
		return
	end
	for cluster in self.dirtyClusters do
		local remaining = JSSet.new(cluster.stations:toArray())
		while remaining:size() > 0 do
			local nextStation
			for s in remaining do
				nextStation = s
				break
			end
			local connected = self:_computeCluster(nextStation)
			for s in connected do
				remaining:delete(s)
			end
			-- Those stations were disconnected: new cluster.
			if remaining:size() > 0 then
				Cluster.new():addStations(connected)
			end
		end
	end
	self.dirtyClusters:clear()
end

function Impl:removeStation(unit)
	local station = self._stationManager:findStation(unit)
	if not station then
		return
	end
	self:_disconnectFromNetwork(station)
	self._stationManager:removeStation(station)
	station.unit:setTrainStation(false)

	local cluster = station:getCluster()
	if not cluster then
		return
	end
	cluster:removeStation(station)
	if cluster:size() == 0 then
		self:_deleteCluster(cluster)
		self.dirtyClusters:delete(cluster)
		return
	end
	self.dirtyClusters:add(cluster)
end

function Impl:_connectToExistingRails(station): boolean
	local game = self.game
	local rails = self.railGrid:query(station:tile(), STATION_RADIUS)
	local editedClusters = JSSet.new()
	for rail in rails do
		local from, to = rail.from, rail.to
		local originalId = rail.id
		local idx = rail:getClosestTileIndex(game, station:tile())
		if idx == 0 or idx >= #rail.tiles then
			continue
		end
		-- The current rail becomes invalid.
		from:removeRailroad(rail)
		to:removeRailroad(rail)
		self.railGrid:unregister(rail)

		local newRailFrom = Railroad.new(from, station, table.move(rail.tiles, 1, idx, 1, {}), self.nextId)
		self.nextId += 1
		local newRailTo = Railroad.new(station, to, table.move(rail.tiles, idx + 1, #rail.tiles, 1, {}), self.nextId)
		self.nextId += 1

		station:addRailroad(newRailFrom)
		station:addRailroad(newRailTo)
		from:addRailroad(newRailFrom)
		to:addRailroad(newRailTo)

		self.railGrid:register(newRailTo)
		self.railGrid:register(newRailFrom)
		local cluster = from:getCluster()
		if cluster then
			cluster:addStation(station)
			editedClusters:add(cluster)
		end
		game:addUpdate({
			type = "RailroadSnapEvent",
			originalId = originalId,
			newId1 = newRailFrom.id,
			newId2 = newRailTo.id,
			tiles1 = newRailFrom.tiles,
			tiles2 = newRailTo.tiles,
		})
	end
	if editedClusters:size() > 1 then
		self:_mergeClusters(editedClusters)
	end
	return editedClusters:size() ~= 0
end

local RAIL_UNITS = { [UnitType.City] = true, [UnitType.Port] = true, [UnitType.Factory] = true }

function Impl:overlappingRailroads(unitType: string, tile: number): { number }
	if not RAIL_UNITS[unitType] then
		return {}
	end
	local seen, tiles = {}, {}
	for railroad in self.railGrid:query(tile, STATION_RADIUS) do
		for _, t in railroad.tiles do
			if not seen[t] then
				seen[t] = true
				table.insert(tiles, t)
			end
		end
	end
	return Util.sort(tiles, function(a, b)
		return a - b
	end)
end

function Impl:_canSnapToExistingRailway(tile: number): boolean
	return self.railGrid:query(tile, STATION_RADIUS):size() > 0
end

function Impl:computeGhostRailPaths(unitType: string, tile: number): { { number } }
	local game = self.game
	if not RAIL_UNITS[unitType] then
		return {}
	end
	if self:_canSnapToExistingRailway(tile) then
		return {}
	end
	local maxRange = game:config():trainStationMaxRange()
	local minRange = game:config():trainStationMinRange()
	local minRangeSquared = minRange * minRange
	local maxPathSize = game:config():railroadMaxSize()

	-- A city or port only joins when a factory is already in range; a factory
	-- always becomes a station and pulls nearby structures in itself.
	local buildingFactory = unitType == UnitType.Factory
	if not buildingFactory and not game:hasUnitNearby(tile, maxRange, UnitType.Factory) then
		return {}
	end

	local neighbors = game:nearbyUnits(tile, maxRange, { UnitType.City, UnitType.Factory, UnitType.Port })
	Util.sort(neighbors, function(a, b)
		return a.distSquared - b.distSquared
	end)

	local paths, connectedStations = {}, {}
	for _, neighbor in neighbors do
		-- Limit to the closest 5 stations.
		if #paths >= 5 then
			break
		end
		if neighbor.distSquared <= minRangeSquared then
			continue
		end
		local neighborStation = self._stationManager:findStation(neighbor.unit)
		local targetTile
		if neighborStation then
			local alreadyReachable = false
			for _, s in connectedStations do
				if self:_distanceFrom(neighborStation, s, MAX_CONNECTION_DISTANCE - 1) ~= -1 then
					alreadyReachable = true
					break
				end
			end
			if alreadyReachable then
				continue
			end
			targetTile = neighborStation:tile()
		elseif buildingFactory then
			targetTile = neighbor.unit:tile()
		else
			continue
		end
		-- A completed city is promoted by the factory and connects back to it.
		local path = if not neighborStation and neighbor.unit:type() == UnitType.City
			then self:_findTilePath(targetTile, tile)
			else self:_findTilePath(tile, targetTile)
		if #path > 0 and #path < maxPathSize then
			table.insert(paths, path)
			if neighborStation then
				table.insert(connectedStations, neighborStation)
			end
		end
	end
	return paths
end

function Impl:_connectToNearbyStations(station)
	local game = self.game
	local neighbors = game:nearbyUnits(station:tile(), game:config():trainStationMaxRange(), { UnitType.City, UnitType.Factory, UnitType.Port })
	local editedClusters = JSSet.new()
	Util.sort(neighbors, function(a, b)
		return a.distSquared - b.distSquared
	end)
	local minRange = game:config():trainStationMinRange()
	for _, neighbor in neighbors do
		if neighbor.unit == station.unit then
			continue
		end
		local neighborStation = self._stationManager:findStation(neighbor.unit)
		if not neighborStation then
			continue
		end
		local distanceToStation = self:_distanceFrom(neighborStation, station, MAX_CONNECTION_DISTANCE)
		local neighborCluster = neighborStation:getCluster()
		if neighborCluster == nil then
			continue
		end
		local connectionAvailable = distanceToStation > MAX_CONNECTION_DISTANCE or distanceToStation == -1
		if connectionAvailable and neighbor.distSquared > minRange * minRange then
			if self:_connect(station, neighborStation) then
				neighborCluster:addStation(station)
				editedClusters:add(neighborCluster)
			end
			-- Roblox port: when run as a TrainStationExecution job, pause here once
			-- this tick's rail budget is used up (a station can lay a dozen
			-- railroads, which made single ticks take 400 ms).
			if coroutine.isyieldable() and os.clock() > Impl.sliceDeadline then
				coroutine.yield()
				if not station:isActive() then
					return -- destroyed while waiting
				end
			end
		end
	end
	if editedClusters:size() > 1 then
		self:_mergeClusters(editedClusters)
	elseif editedClusters:size() == 0 then
		Cluster.new():addStation(station)
	end
end

function Impl:_disconnectFromNetwork(station)
	for rail in station:getRailroads() do
		rail:delete(self.game)
		self.railGrid:unregister(rail)
	end
	station:clearRailroads()
end

function Impl:_deleteCluster(cluster)
	for station in cluster.stations do
		station:setCluster(nil)
	end
	cluster:clear()
end

function Impl:_connect(from, to): boolean
	local path = self:_findTilePath(from:tile(), to:tile())
	if #path > 0 and #path < self.game:config():railroadMaxSize() then
		local railroad = Railroad.new(from, to, path, self.nextId)
		self.nextId += 1
		self.game:addUpdate({ type = "RailroadConstructionEvent", id = railroad.id, tiles = railroad.tiles })
		from:addRailroad(railroad)
		to:addRailroad(railroad)
		self.railGrid:register(railroad)
		return true
	end
	return false
end

-- BFS hop count from start to dest, or -1 beyond maxDistance.
function Impl:_distanceFrom(start, dest, maxDistance: number): number
	if start == dest then
		return 0
	end
	local visited = {}
	local queue = { { station = start, distance = 0 } }
	local head = 1
	while head <= #queue do
		local entry = queue[head]
		head += 1
		local station, distance = entry.station, entry.distance
		if visited[station] then
			continue
		end
		visited[station] = true
		if distance >= maxDistance then
			continue
		end
		for _, neighbor in station:neighbors() do
			if neighbor == dest then
				return distance + 1
			end
			if not visited[neighbor] then
				table.insert(queue, { station = neighbor, distance = distance + 1 })
			end
		end
	end
	return -1
end

function Impl:_computeCluster(start)
	local visited = JSSet.new()
	local queue = { start }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		if visited:has(current) then
			continue
		end
		visited:add(current)
		for _, neighbor in current:neighbors() do
			if not visited:has(neighbor) then
				table.insert(queue, neighbor)
			end
		end
	end
	return visited
end

function Impl:_mergeClusters(clusters)
	local merged = Cluster.new()
	for cluster in clusters do
		merged:merge(cluster)
	end
end

-- Deadline (os.clock) for rail work this tick; connectStation yields past it
-- when running inside a coroutine (TrainStationExecution).
function RailNetwork.setSliceDeadline(t: number)
	Impl.sliceDeadline = t
end

return RailNetwork
