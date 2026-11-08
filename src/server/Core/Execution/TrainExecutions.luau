-- Port of OpenFrontIO src/core/execution/FactoryExecution.ts,
-- TrainStationExecution.ts, TrainExecution.ts and
-- RecomputeRailClusterExecution.ts.

local Shared = game:GetService("ReplicatedStorage").Shared
local PseudoRandom = require(Shared.PseudoRandom)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local RailNetwork = require(Core.RailNetwork)

local UnitType = GameTypes.UnitType
local getOrientedRailroad = RailNetwork.getOrientedRailroad

local M = {}

local function base(class)
	class.__index = class
	class.isActive = function(self)
		return self._active
	end
	class.activeDuringSpawnPhase = function()
		return false
	end
	return class
end

-- TrainExecution ------------------------------------------------------------------------

local Train = base({})
M.TrainExecution = Train

function Train.new(railNetwork, player, source, destination, numCars: number)
	return setmetatable({
		_active = true,
		railNetwork = railNetwork,
		player = player,
		source = source,
		destination = destination,
		numCars = numCars,
		mg = nil,
		train = nil, -- primary unit
		cars = {}, -- back to front
		hasCargo = false,
		currentTile = 0, -- 0-based index into the current railroad
		spacing = 2,
		usedTiles = {}, -- tiles for the cars behind
		stations = {},
		currentRailroad = nil,
		speed = 2,
		_tradeStopsVisited = 0,
		pathTiles = {},
		pathIndex = 0,
	}, Train)
end

function Train:owner()
	return self.player
end

function Train:tradeStopsVisited(): number
	return self._tradeStopsVisited
end

function Train:init(mg, ticks: number)
	self.mg = mg
	local stations = self.railNetwork:findStationsPath(self.source, self.destination)
	if not stations or #stations <= 1 then
		self._active = false
		return
	end
	self.stations = stations
	local railroad = getOrientedRailroad(stations[1], stations[2])
	if not railroad then
		self._active = false
		return
	end
	self.currentRailroad = railroad

	local spawn = self.player:canBuild(UnitType.Train, stations[1]:tile())
	if spawn == false then
		warn("cannot build train")
		self._active = false
		return
	end
	self.train = self:_createTrainUnits(spawn)

	-- Whole route (upstream records it as a client motion plan; here it only
	-- backs resolveSplitRailroad).
	local pathTiles = {}
	for i = 1, #stations - 1 do
		local segment = getOrientedRailroad(stations[i], stations[i + 1])
		if not segment then
			self._active = false
			return
		end
		table.move(segment:getTiles(), 1, #segment:getTiles(), #pathTiles + 1, pathTiles)
	end
	local startTile = self.train:tile()
	if #pathTiles == 0 or pathTiles[1] ~= startTile then
		table.insert(pathTiles, 1, startTile)
		self.pathIndex = 1
	end
	self.pathTiles = pathTiles
end

function Train:tick(ticks: number)
	assert(self.train ~= nil, "Not initialized")
	if not self.train:isActive() or not self:_activeSourceOrDestination() then
		self:_deleteTrain()
		return
	end
	local tile = self:_getNextTile()
	if tile then
		self:_updateCarsPositions(tile)
	else
		self:_targetReached()
		self:_deleteTrain()
	end
end

function Train:loadCargo()
	if self.hasCargo or self.train == nil then
		return
	end
	self.hasCargo = true
	-- Skip index 1: don't load the tail engine.
	for i = 2, #self.cars do
		self.cars[i]:setLoaded(true)
	end
end

function Train:_targetReached()
	if self.train == nil then
		return
	end
	self.train:setReachedTarget()
	for _, car in self.cars do
		car:setReachedTarget()
	end
end

function Train:_createTrainUnits(tile: number)
	local player = self.player
	local train = player:buildUnit(UnitType.Train, tile, { targetUnit = self.destination.unit, trainType = "Engine" })
	-- The tail is also an engine, just for cosmetics.
	table.insert(self.cars, player:buildUnit(UnitType.Train, tile, { targetUnit = self.destination.unit, trainType = "TailEngine" }))
	for _ = 1, self.numCars do
		table.insert(self.cars, player:buildUnit(UnitType.Train, tile, { trainType = "Carriage", loaded = self.hasCargo }))
	end
	return train
end

function Train:_deleteTrain()
	self._active = false
	if self.train and self.train:isActive() then
		self.train:delete(false)
	end
	for _, car in self.cars do
		if car:isActive() then
			car:delete(false)
		end
	end
end

function Train:_activeSourceOrDestination(): boolean
	local s = self.stations
	return #s > 1 and s[2]:isActive() and s[1]:isActive()
end

-- Tiles the train went through, reused by the cars (so the spacing does not
-- depend on the train speed).
function Train:_saveTraversedTiles(from: number, speed: number)
	if not self.currentRailroad then
		return
	end
	local tiles = self.currentRailroad:getTiles()
	local tileToSave = from
	local i = 0
	while i < speed and tileToSave < #tiles do
		self:_saveTile(tiles[tileToSave + 1])
		tileToSave += 1
		i += 1
	end
end

function Train:_saveTile(tile: number)
	table.insert(self.usedTiles, tile)
	if #self.usedTiles > #self.cars * self.spacing + 3 then
		table.remove(self.usedTiles, 1)
	end
end

function Train:_updateCarsPositions(newTile: number)
	for i = #self.cars, 1, -1 do
		-- upstream: carTileIndex = (i + 1) * spacing + 2 with 0-based i
		local carTileIndex = i * self.spacing + 2
		if #self.usedTiles > carTileIndex then
			self.cars[i]:move(self.usedTiles[carTileIndex + 1])
		end
	end
	if self.train ~= nil then
		self.train:move(newTile)
	end
end

function Train:_nextStation(): boolean
	if #self.stations > 2 then
		self.pathIndex += if self.currentRailroad then #self.currentRailroad:getTiles() else 0
		table.remove(self.stations, 1)
		local railroad = getOrientedRailroad(self.stations[1], self.stations[2]) or self:_resolveSplitRailroad()
		if railroad then
			self.currentRailroad = railroad
			return true
		end
	end
	return false
end

-- A station built on our railroad split it in two: continue along the new
-- segments if they retrace the planned route exactly.
function Train:_resolveSplitRailroad()
	local station0, station1 = self.stations[1], self.stations[2]
	local path = self.railNetwork:findStationsPath(station0, station1)
	if not path or #path <= 2 then
		return nil
	end
	local cursor = self.pathIndex -- 0-based
	for i = 1, #path - 1 do
		local segment = getOrientedRailroad(path[i], path[i + 1])
		if not segment then
			return nil
		end
		for _, tile in segment:getTiles() do
			if self.pathTiles[cursor + 1] ~= tile then
				return nil
			end
			cursor += 1
		end
	end
	table.remove(self.stations, 1)
	table.remove(self.stations, 1)
	for i = #path, 1, -1 do
		table.insert(self.stations, 1, path[i])
	end
	return getOrientedRailroad(self.stations[1], self.stations[2])
end

function Train:_canTradeWithDestination(): boolean
	return #self.stations > 1 and self.stations[2]:tradeAvailable(self.player)
end

function Train:_getNextTile(): number?
	if self.currentRailroad == nil or not self:_canTradeWithDestination() then
		return nil
	end
	self:_saveTraversedTiles(self.currentTile, self.speed)
	self.currentTile += self.speed
	local leftOver = self.currentTile - #self.currentRailroad:getTiles()
	if leftOver >= 0 then
		-- Station reached, pick the next station.
		self:_stationReached()
		if not self:_nextStation() then
			return nil -- destination reached (or no valid connection)
		end
		self.currentTile = leftOver
		self:_saveTraversedTiles(0, leftOver)
	end
	return self.currentRailroad:getTiles()[self.currentTile + 1]
end

function Train:_stationReached()
	local station = self.stations[2]
	station:onTrainStop(self)
	local t = station.unit:type()
	if t == UnitType.City or t == UnitType.Port then
		self._tradeStopsVisited += 1
	end
end

-- TrainStationExecution -------------------------------------------------------------------

local StationExec = base({})
M.TrainStationExecution = StationExec

function StationExec.new(unit, spawnTrains: boolean?)
	unit:setTrainStation(true)
	return setmetatable({
		_active = true,
		unit = unit,
		spawnTrains = spawnTrains,
		station = nil,
		numCars = 5,
		lastSpawnTick = 0,
		ticksCooldown = 10, -- minimum cooldown between two trains
	}, StationExec)
end

function StationExec:init(mg)
	self.mg = mg
	if self.spawnTrains then
		self.random = PseudoRandom.new(mg:ticks())
	end
end

-- Connecting a station lays its railroads (pathfinding for each nearby
-- station). A new factory stations every city / port / factory around it on
-- the same tick and one station can lay a dozen railroads, which made single
-- ticks take up to 400 ms late in a match. Roblox port: the connection runs
-- as a coroutine that pauses once this tick's 8 ms rail budget is used and
-- resumes on the next tick (every job makes progress at least once a tick).
local CONNECT_BUDGET = 0.008
local connectBudget = { tick = -1, deadline = 0 }

function StationExec:tick(ticks: number)
	if not self._active or self.unit == nil then
		return
	end
	if self.station == nil or self.connectJob then
		if connectBudget.tick ~= ticks then
			connectBudget.tick, connectBudget.deadline = ticks, os.clock() + CONNECT_BUDGET
		end
		if not self.unit:isActive() then
			self._active = false -- destroyed while waiting for the budget
			return
		end
		if self.station == nil then
			if os.clock() > connectBudget.deadline then
				return -- no budget left this tick
			end
			-- Executions can't be created during init, so it happens on the first tick.
			local station = RailNetwork.TrainStation.new(self.mg, self.unit)
			local rail = self.mg:railNetwork()
			self.station = station
			self.connectJob = coroutine.create(function()
				rail:connectStation(station)
			end)
		end
		RailNetwork.setSliceDeadline(connectBudget.deadline)
		local ok, err = coroutine.resume(self.connectJob)
		RailNetwork.setSliceDeadline(math.huge)
		if not ok then
			warn("[Rail] station connection failed:", err)
			self.connectJob = nil
		elseif coroutine.status(self.connectJob) == "dead" then
			self.connectJob = nil
		else
			return -- still connecting
		end
	end
	if not self.station:isActive() then
		self._active = false
		return
	end
	if self.spawnTrains then
		self:_spawnTrain(self.station, ticks)
	end
end

function StationExec:_shouldSpawnTrain(): boolean
	local spawnRate = self.mg:config():trainSpawnRate(self.unit:owner():unitCount(UnitType.Factory), self.mg:unitCount(UnitType.Train))
	for _ = 1, self.unit:level() do
		if self.random:chance(spawnRate) then
			return true
		end
	end
	return false
end

function StationExec:_spawnTrain(station, currentTick: number)
	if currentTick < self.lastSpawnTick + self.ticksCooldown then
		return
	end
	local cluster = station:getCluster()
	if cluster == nil then
		return
	end
	local owner = self.unit:owner()
	if not cluster:hasAnyTradeDestination(owner) then
		return
	end
	if not self:_shouldSpawnTrain() then
		return
	end
	-- Pick a destination randomly.
	local destination = cluster:randomTradeDestination(owner, self.random)
	if destination == nil or destination == station then
		return
	end
	self.mg:addExecution(Train.new(self.mg:railNetwork(), owner, station, destination, self.numCars))
	self.lastSpawnTick = currentTick
end

-- FactoryExecution -------------------------------------------------------------------------

local Factory = base({})
M.FactoryExecution = Factory

function Factory.new(factory)
	return setmetatable({ _active = true, factory = factory, stationCreated = false }, Factory)
end

function Factory:init(mg)
	self.game = mg
end

function Factory:tick()
	if not self.stationCreated then
		self:_createStation()
		self.stationCreated = true
	end
	if not self.factory:isActive() then
		self._active = false
	end
end

function Factory:_createStation()
	local game = self.game
	local structures = game:nearbyUnits(self.factory:tile(), game:config():trainStationMaxRange(), { UnitType.City, UnitType.Port, UnitType.Factory })
	game:addExecution(StationExec.new(self.factory, true))
	for _, entry in structures do
		if not entry.unit:hasTrainStation() then
			game:addExecution(StationExec.new(entry.unit))
		end
	end
end

-- RecomputeRailClusterExecution -------------------------------------------------------------

local Recompute = base({})
M.RecomputeRailClusterExecution = Recompute

function Recompute.new(railNetwork)
	return setmetatable({ _active = true, railNetwork = railNetwork }, Recompute)
end
function Recompute:init() end
function Recompute:tick()
	self.railNetwork:recomputeClusters()
end

return M
