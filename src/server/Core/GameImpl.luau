-- Port of OpenFrontIO src/core/game/GameImpl.ts.
--
-- Porting notes:
--  * Players are kept in insertion order (upstream Map) in `_playerList`,
--    with `_players` as the id lookup; `_playersBySmallID[smallID]` matches
--    upstream's `_playersBySmallID[smallID - 1]`.
--  * The execution loop reproduces upstream's array semantics exactly
--    (forEach length fixed at loop start, executions added during init() are
--    dropped, in-place compaction), because execution order drives the game.
--  * Game updates are collected as plain tables; the server's replication
--    layer (not upstream's worker protocol) consumes them.

local Shared = game:GetService("ReplicatedStorage").Shared
local Util = require(Shared.Util)
local GameTypes = require(script.Parent.GameTypes)
local PlayerImpl = require(script.Parent.PlayerImpl)
local Stats = require(script.Parent.Stats)
local WaterManager = require(script.Parent.Pathfinding.WaterManager)
local UnitGrid = require(script.Parent.UnitGrid)
local AllianceImpl = require(script.Parent.AllianceImpl)

local PlayerType = GameTypes.PlayerType
local GameMode = GameTypes.GameMode
local ColoredTeams = GameTypes.ColoredTeams
local MessageType = GameTypes.MessageType
local UnitType = GameTypes.UnitType

-- Copy of list without item (JS filter(x => x !== item)).
local function without(list, item)
	local out = {}
	for _, v in list do
		if v ~= item then
			table.insert(out, v)
		end
	end
	return out
end

local TerraNullius = {}
TerraNullius.__index = TerraNullius
function TerraNullius.new()
	return setmetatable({}, TerraNullius)
end
function TerraNullius:smallID(): number
	return 0
end
function TerraNullius:clientID(): string
	return "TERRA_NULLIUS_CLIENT_ID"
end
function TerraNullius:id()
	return nil
end
function TerraNullius:isPlayer(): boolean
	return false
end

local GameImpl = {}
GameImpl.__index = GameImpl

function GameImpl.new(humans, nations, map, miniGameMap, config, teamGameSpawnAreas)
	local self = setmetatable({
		_ticks = 0,
		_startTick = nil,
		_unInitExecs = {},
		_execs = {},
		_players = {}, -- id -> PlayerImpl
		_playerList = {}, -- insertion order
		_playersBySmallID = {},
		_terraNullius = TerraNullius.new(),
		allianceRequests = {}, -- AllianceRequestImpl list (pending)
		_nextPlayerID = 1,
		_nextUnitID = 1,
		_updates = {},
		_tileUpdates = {}, -- flat { tile, packedState, ... } for this tick
		_playerTeams = {},
		_botTeam = ColoredTeams.Bot,
		_nextAllianceID = 0,
		_isPaused = false,
		_winner = nil,
		_teamGameSpawnAreas = teamGameSpawnAreas,
		_territoryVersion = 0,
		_unitsVersion = 0,

		_humans = humans,
		_nations = nations,
		_map = map,
		_miniGameMap = miniGameMap,
		_config = config,
		_stats = Stats.new(),
	}, GameImpl)

	self._unitGrid = UnitGrid.new(map)
	self._railNetwork = require(script.Parent.RailNetwork).new(self)
	self._unitMap = {} -- id -> unit
	self._waterManager = WaterManager.new(map, miniGameMap, config:disableNavMesh())
	if config:gameConfig().gameMode == GameMode.Team then
		self:_populateTeams()
	end
	self:_addPlayers()
	return self
end

function GameImpl:_populateTeams()
	local TeamAssignment = require(script.Parent.TeamAssignment)
	self._playerTeams = TeamAssignment.resolveTeamsList(self._config:playerTeams(), #self._humans + #self._nations)
end

function GameImpl:_addPlayers()
	if self._config:gameConfig().gameMode == GameMode.FFA then
		for _, p in self._humans do
			self:addPlayer(p)
		end
		for _, n in self._nations do
			self:addPlayer(n.playerInfo)
		end
		return
	end
	if self._config:playerTeams() == GameTypes.HumansVsNations then
		for _, p in self._humans do
			self:addPlayer(p, ColoredTeams.Humans)
		end
		for _, n in self._nations do
			self:addPlayer(n.playerInfo, ColoredTeams.Nations)
		end
		return
	end
	-- Team mode
	local TeamAssignment = require(script.Parent.TeamAssignment)
	local allPlayers = table.clone(self._humans)
	for _, n in self._nations do
		table.insert(allPlayers, n.playerInfo)
	end
	local pt = self._config:playerTeams()
	local isDuosTriosQuads = pt == GameTypes.Duos or pt == GameTypes.Trios or pt == GameTypes.Quads
	for _, row in TeamAssignment.assignTeams(allPlayers, self._playerTeams, isDuosTriosQuads) do
		if row.team == "kicked" then
			warn(`Player {row.player.name} was kicked from team`)
			continue
		end
		self:addPlayer(row.player, row.team)
	end
end

-- Map & ownership -----------------------------------------------------------------

function GameImpl:owner(ref: number)
	return self:playerBySmallID(self._map:ownerID(ref))
end

function GameImpl:playerBySmallID(id: number)
	if id == 0 then
		return self._terraNullius
	end
	return self._playersBySmallID[id]
end

function GameImpl:map()
	return self._map
end
function GameImpl:miniMap()
	return self._miniGameMap
end

function GameImpl:addUpdate(update)
	table.insert(self._updates, update)
end

function GameImpl:nextUnitID(): number
	local old = self._nextUnitID
	self._nextUnitID += 1
	return old
end

function GameImpl:setFallout(tile: number, value: boolean)
	if value and self:hasOwner(tile) then
		error(`cannot set fallout, tile {tile} has owner`)
	end
	if self._map:hasFallout(tile) then
		return
	end
	self._territoryVersion += 1
	self._map:setFallout(tile, value)
	self:_recordTileUpdate(tile)
end

function GameImpl:setWater(tile: number)
	if not self:isLand(tile) then
		return
	end
	if self:hasOwner(tile) then
		error(`cannot set water, tile {tile} has owner`)
	end
	if self._map:hasFallout(tile) then
		self._map:setFallout(tile, false)
	end
	self._territoryVersion += 1
	self._map:setWater(tile)
	self:_recordTileUpdate(tile)
end

function GameImpl:queueWaterConversion(tile: number)
	if not self:isLand(tile) then
		return
	end
	if self:hasOwner(tile) then
		error(`cannot queue water conversion, tile {tile} has owner`)
	end
	if not self._config:waterNukes() then
		self:setFallout(tile, true)
		return
	end
	self._waterManager:queueTile(tile)
end

-- Every tile inside a blast radius, drained once per tick for clients
-- (upstream feeds its "nukeable layer"; here the explosion effect).
function GameImpl:queueNukeImpact(tile: number)
	self._nukeImpactQueue = self._nukeImpactQueue or {}
	table.insert(self._nukeImpactQueue, tile)
end
function GameImpl:drainNukeImpacts(): { number }
	local tiles = self._nukeImpactQueue or {}
	self._nukeImpactQueue = {}
	return tiles
end

-- Nuke motion plans for clients: unitId -> { src, dst, speed, directionUp, startTick }.
-- Not part of the simulation state.
function GameImpl:recordMotionPlan(record)
	self._motionPlans = self._motionPlans or {}
	self._motionPlans[record.unitId] = record
end
function GameImpl:motionPlan(unitId: number)
	return self._motionPlans and self._motionPlans[unitId]
end
function GameImpl:clearMotionPlan(unitId: number)
	if self._motionPlans then
		self._motionPlans[unitId] = nil
	end
end

-- Water navigation (WaterManager) ------------------------------------------------

function GameImpl:miniWaterHPA()
	return self._waterManager:miniWaterHPA()
end
function GameImpl:miniWaterGraph()
	return self._waterManager:miniWaterGraph()
end
function GameImpl:waterGraphVersion(): number
	return self._waterManager:waterGraphVersion()
end
function GameImpl:getWaterComponent(tile: number): number?
	return self._waterManager:getWaterComponent(tile)
end
function GameImpl:hasWaterComponent(tile: number, component: number): boolean
	return self._waterManager:hasWaterComponent(tile, component)
end
function GameImpl:getWaterComponentSize(tile: number): number?
	return self._waterManager:getWaterComponentSize(tile)
end

-- Units ---------------------------------------------------------------------------

function GameImpl:unit(id: number)
	return self._unitMap[id]
end

-- units() / units(type, ...) / units({types}) across all players, in player order.
function GameImpl:units(...: any)
	local n = select("#", ...)
	-- Single-type queries (nations scan transports every tick) are memoised
	-- on the units version, which every add / remove / owner change bumps, so
	-- the players-then-units order is unchanged. Callers get a copy.
	if n == 1 and type((...)) == "string" then
		local unitType = ...
		local cache = self._unitsByTypeCache
		if cache == nil or cache.version ~= self._unitsVersion then
			cache = { version = self._unitsVersion, lists = {} }
			self._unitsByTypeCache = cache
		end
		local list = cache.lists[unitType]
		if list == nil then
			list = {}
			for _, p in self._playerList do
				for _, u in p:units() do
					if u:type() == unitType then
						table.insert(list, u)
					end
				end
			end
			cache.lists[unitType] = list
		end
		return table.clone(list)
	end
	local out = {}
	local wanted = nil
	if n > 0 then
		local first = ...
		if type(first) == "table" then
			if #first > 0 then
				wanted = {}
				for _, t in first do
					wanted[t] = true
				end
			end
		else
			wanted = {}
			for i = 1, n do
				local t = select(i, ...)
				if t ~= nil then
					wanted[t] = true
				end
			end
		end
	end
	for _, p in self._playerList do
		for _, u in p:units() do
			if wanted == nil or wanted[u:type()] then
				table.insert(out, u)
			end
		end
	end
	return out
end

-- Level-weighted count over all players. Memoised on the units version
-- (bumped on add / remove / level change): SAMs ask every tick.
function GameImpl:unitCount(unitType: string): number
	local cache = self._unitCountCache
	if cache == nil or cache.version ~= self._unitsVersion then
		cache = { version = self._unitsVersion, counts = {} }
		self._unitCountCache = cache
	end
	local total = cache.counts[unitType]
	if total == nil then
		total = 0
		for _, p in self._playerList do
			total += p:unitCount(unitType)
		end
		cache.counts[unitType] = total
	end
	return total
end

function GameImpl:unitInfo(unitType: string)
	return self._config:unitInfo(unitType)
end

function GameImpl:hasUnitNearby(tile: number, range: number, unitType: string, playerId: string?, includeUnderConstruction: boolean?): boolean
	return self._unitGrid:hasUnitNearby(tile, range, unitType, playerId, includeUnderConstruction)
end
function GameImpl:anyUnitNearby(tile: number, range: number, types, predicate, playerId: string?, includeUnderConstruction: boolean?): boolean
	return self._unitGrid:anyUnitNearby(tile, range, types, predicate, playerId, includeUnderConstruction)
end
function GameImpl:nearbyUnits(tile: number, range: number, types, predicate, includeUnderConstruction: boolean?)
	return self._unitGrid:nearbyUnits(tile, range, types, predicate, includeUnderConstruction)
end

function GameImpl:bumpUnitsVersion()
	self._unitsVersion += 1
end

function GameImpl:addUnit(u)
	self._unitsVersion += 1
	self._unitGrid:addUnit(u)
	self._unitMap[u:id()] = u
end

function GameImpl:removeUnit(u)
	self._unitsVersion += 1
	self._unitGrid:removeUnit(u)
	self._unitMap[u:id()] = nil
	if u:hasTrainStation() then
		self._railNetwork:removeStation(u)
	end
end

function GameImpl:updateUnitTile(u)
	self._unitGrid:updateUnitCell(u)
end

function GameImpl:onUnitMoved(u)
	self:updateUnitTile(u)
	self:addUpdate(u:toUpdate())
end

function GameImpl:nations()
	return self._nations
end

function GameImpl:railNetwork()
	return self._railNetwork
end

-- Alliances -------------------------------------------------------------------------

function GameImpl:createAllianceRequest(requestor, recipient)
	if requestor:isAlliedWith(recipient) then
		return nil -- already allied
	end
	for _, ar in recipient:incomingAllianceRequests() do
		if ar:requestor() == requestor then
			return nil -- duplicate
		end
	end
	for _, ar in requestor:incomingAllianceRequests() do
		if ar:requestor() == recipient then
			-- Corresponding requests: accept instead.
			ar:accept()
			return nil
		end
	end
	local ar = AllianceImpl.AllianceRequestImpl.new(requestor, recipient, self._ticks, self)
	table.insert(self.allianceRequests, ar)
	self:addUpdate(ar:toUpdate())
	return ar
end

function GameImpl:acceptAllianceRequest(request)
	self.allianceRequests = without(self.allianceRequests, request)
	local requestor, recipient = request:requestor(), request:recipient()
	if requestor:allianceWith(recipient) then
		error(`cannot accept alliance request, already allied with {recipient:name()}`)
	end
	local alliance = AllianceImpl.AllianceImpl.new(self, requestor, recipient, self._ticks, self._nextAllianceID)
	self._nextAllianceID += 1
	table.insert(requestor._alliances, alliance)
	table.insert(recipient._alliances, alliance)
	self._stats:allianceFormed(requestor)
	self._stats:allianceFormed(recipient)
	table.insert(requestor.pastOutgoingAllianceRequests, request)
	self:addUpdate({ type = "AllianceRequestReply", request = request:toUpdate(), accepted = true })
end

function GameImpl:rejectAllianceRequest(request)
	self.allianceRequests = without(self.allianceRequests, request)
	table.insert(request:requestor().pastOutgoingAllianceRequests, request)
	self:addUpdate({ type = "AllianceRequestReply", request = request:toUpdate(), accepted = false })
end

function GameImpl:expireAlliance(alliance)
	local recipientSet = {}
	for _, a in alliance:recipient():alliances() do
		recipientSet[a] = true
	end
	local shared = {}
	for _, a in alliance:requestor():alliances() do
		if recipientSet[a] then
			table.insert(shared, a)
		end
	end
	if #shared ~= 1 then
		error(`cannot expire alliance: must have exactly one alliance, have {#shared}`)
	end
	local expiring = shared[1]
	local duration = self._ticks - expiring:createdAt()
	self._stats:allianceEnded(expiring:requestor(), duration, "expired")
	self._stats:allianceEnded(expiring:recipient(), duration, "expired")
	self:_detachAlliance(expiring)
	self:addUpdate({ type = "AllianceExpired", player1ID = alliance:requestor():smallID(), player2ID = alliance:recipient():smallID() })
end

function GameImpl:breakAlliance(breaker, alliance)
	local other = if alliance:requestor() == breaker then alliance:recipient() else alliance:requestor()
	if not breaker:isAlliedWith(other) then
		error(`{breaker} not allied with {other}, cannot break alliance`)
	end
	local duration = self._ticks - alliance:createdAt()
	if not other:isTraitor() and not other:isDisconnected() then
		breaker:markTraitor()
		self._stats:allianceEnded(other, duration, "brokenByOther")
	else
		self._stats:allianceEnded(other, duration, nil)
	end
	self._stats:allianceEnded(breaker, duration, nil)
	self:_detachAlliance(alliance)
	self:addUpdate({
		type = "BrokeAlliance",
		traitorID = breaker:smallID(),
		betrayedID = other:smallID(),
		allianceID = alliance:id(),
	})
end

function GameImpl:removeAlliancesByPlayerSilently(player)
	local removed = table.clone(player._alliances)
	for _, alliance in removed do
		local duration = self._ticks - alliance:createdAt()
		self._stats:allianceEnded(alliance:requestor(), duration, nil)
		self._stats:allianceEnded(alliance:recipient(), duration, nil)
		self:_detachAlliance(alliance)
	end
end

function GameImpl:_detachAlliance(alliance)
	local requestor = alliance:requestor()
	local recipient = alliance:recipient()
	requestor._alliances = without(requestor._alliances, alliance)
	recipient._alliances = without(recipient._alliances, alliance)
end

-- Game state --------------------------------------------------------------------------

function GameImpl:hasPlayer(id: string): boolean
	return self._players[id] ~= nil
end
function GameImpl:config()
	return self._config
end
function GameImpl:stats()
	return self._stats
end
function GameImpl:isPaused(): boolean
	return self._isPaused
end
function GameImpl:setPaused(paused: boolean)
	self._isPaused = paused
	self:addUpdate({ type = "GamePaused", paused = paused })
end
function GameImpl:inSpawnPhase(): boolean
	return self._startTick == nil
end
function GameImpl:endSpawnPhase()
	if self._startTick ~= nil then
		return
	end
	self._startTick = self._ticks
	self:addUpdate({ type = "SpawnPhaseEnd", startTick = self._startTick })
end
function GameImpl:ticks(): number
	return self._ticks
end

-- Runs one simulation tick. Returns the updates produced this tick.
function GameImpl:executeNextTick()
	self._updates = {}
	table.clear(self._tileUpdates)

	-- forEach semantics: length fixed at loop start, the array object is the
	-- one current at loop start (removeExecution reassigns, never mutates).
	local execs = self._execs
	local n = #execs
	-- Optional spike attribution (set game._profile = { spikes = {} } from a
	-- test): time per execution module, kept for ticks over 80 ms.
	local prof = self._profile
	local cost = if prof then {} else nil
	local tickStart = os.clock()
	for i = 1, n do
		local e = execs[i]
		if (not self:inSpawnPhase() or e:activeDuringSpawnPhase()) and e:isActive() then
			if cost then
				local t0 = os.clock()
				e:tick(self._ticks)
				local key = debug.info(e.tick, "s")
				cost[key] = (cost[key] or 0) + os.clock() - t0
			else
				e:tick(self._ticks)
			end
		end
	end

	local inited, unInited = {}, {}
	local pending = self._unInitExecs
	local m = #pending
	for i = 1, m do
		local e = pending[i]
		if not self:inSpawnPhase() or e:activeDuringSpawnPhase() then
			if cost then
				local t0 = os.clock()
				e:init(self, self._ticks)
				local key = "init:" .. debug.info(e.init, "s")
				cost[key] = (cost[key] or 0) + os.clock() - t0
			else
				e:init(self, self._ticks)
			end
			table.insert(inited, e)
		else
			table.insert(unInited, e)
		end
	end

	self:removeInactiveExecutions()

	table.move(inited, 1, #inited, #self._execs + 1, self._execs)
	-- Executions queued during init() above are dropped, as upstream does.
	self._unInitExecs = unInited

	for _, player in self._playerList do
		if player:isAlive() and player:hasSpawned() then
			self._stats:recordTickSample(player, player:numTilesOwned(), player:troops(), #player:alliances())
		end
	end

	-- Flush pending water conversions + throttled graph rebuild.
	local tw = os.clock()
	for _, tile in self._waterManager:tick(self._ticks) do
		self:_recordTileUpdate(tile)
	end
	if cost then
		cost["waterManager"] = os.clock() - tw
		local total = os.clock() - tickStart
		if total > 0.08 then
			local rows = {}
			for k, v in cost do
				table.insert(rows, { k = string.match(k, "[^%.]+$") or k, v = v })
			end
			table.sort(rows, function(a, b)
				return a.v > b.v
			end)
			local parts = {}
			for i = 1, math.min(4, #rows) do
				table.insert(parts, string.format("%s %.0fms", rows[i].k, rows[i].v * 1000))
			end
			table.insert(prof.spikes, string.format("t%d %.0fms: %s", self._ticks, total * 1000, table.concat(parts, ", ")))
		end
	end
	self._ticks += 1
	return self._updates
end

function GameImpl:_recordTileUpdate(tile: number)
	-- Low 16 bits: tile state, bits 16-23: terrain byte (upstream packing).
	table.insert(self._tileUpdates, tile)
	table.insert(self._tileUpdates, self._map:tileState(tile) + self._map:terrainByte(tile) * 65536)
end

-- Flat { tile, packed, tile, packed, ... } of tile changes from the last tick.
function GameImpl:tileUpdates(): { number }
	return self._tileUpdates
end

function GameImpl:hash(): number
	local hash = 1
	for _, p in self._playerList do
		hash += p:hash()
	end
	return hash
end

function GameImpl:terraNullius()
	return self._terraNullius
end

function GameImpl:removeInactiveExecutions()
	-- Compact in place, like upstream.
	local execs = self._execs
	local inSpawnPhase = self:inSpawnPhase()
	local w = 0
	for i = 1, #execs do
		local exec = execs[i]
		local keep
		if inSpawnPhase then
			keep = not exec:activeDuringSpawnPhase() or exec:isActive()
		else
			keep = exec:isActive()
		end
		if keep then
			w += 1
			execs[w] = exec
		end
	end
	for i = #execs, w + 1, -1 do
		execs[i] = nil
	end
end

function GameImpl:players(): { any }
	local out = {}
	for _, p in self._playerList do
		if p:isAlive() then
			table.insert(out, p)
		end
	end
	return out
end

function GameImpl:allPlayers(): { any }
	return table.clone(self._playerList)
end

function GameImpl:executions(): { any }
	local out = table.clone(self._execs)
	table.move(self._unInitExecs, 1, #self._unInitExecs, #out + 1, out)
	return out
end

function GameImpl:addExecution(...)
	for i = 1, select("#", ...) do
		table.insert(self._unInitExecs, (select(i, ...)))
	end
end

function GameImpl:removeExecution(exec)
	self._execs = without(self._execs, exec)
	self._unInitExecs = without(self._unInitExecs, exec)
end

function GameImpl:addPlayer(playerInfo, team: string?)
	local player = PlayerImpl.new(
		self,
		self._nextPlayerID,
		playerInfo,
		self._config:startManpower(playerInfo),
		team or self:_maybeAssignTeam(playerInfo)
	)
	self._playersBySmallID[self._nextPlayerID] = player
	self._nextPlayerID += 1
	if self._players[playerInfo.id] == nil then
		table.insert(self._playerList, player)
	else
		-- Map.set on an existing key replaces the value in place.
		local idx = table.find(self._playerList, self._players[playerInfo.id]) :: number
		self._playerList[idx] = player
	end
	self._players[playerInfo.id] = player
	return player
end

function GameImpl:_maybeAssignTeam(playerInfo): string?
	if self._config:gameConfig().gameMode ~= GameMode.Team then
		return nil
	end
	if playerInfo.playerType == PlayerType.Bot then
		return self._botTeam
	end
	local rand = Util.simpleHash(playerInfo.id)
	return self._playerTeams[rand % #self._playerTeams + 1]
end

function GameImpl:player(id: string)
	local player = self._players[id]
	if player == nil then
		error(`Player with id {id} not found`)
	end
	return player
end

function GameImpl:playerByClientID(id: string)
	for _, player in self._playerList do
		if player:clientID() == id then
			return player
		end
	end
	return nil
end

function GameImpl:isOnMap(cell): boolean
	return cell.x >= 0 and cell.x < self._map:width() and cell.y >= 0 and cell.y < self._map:height()
end

-- Territory --------------------------------------------------------------------------

function GameImpl:conquer(owner, tile: number)
	if not self:isLand(tile) then
		error("cannot conquer water")
	end
	if self:isImpassable(tile) then
		error("cannot conquer impassable terrain")
	end
	local previousOwner = self:owner(tile)
	if previousOwner:isPlayer() then
		previousOwner._lastTileChange = self._ticks
		previousOwner._tileChangeVersion += 1
		previousOwner._tiles:delete(tile)
		previousOwner._borderTiles:delete(tile)
	end
	self._territoryVersion += 1
	self._map:setOwnerID(tile, owner:smallID())
	owner._tiles:add(tile)
	owner._lastTileChange = self._ticks
	owner._tileChangeVersion += 1
	self:_updateBorders(tile)
	self._map:setFallout(tile, false)
	self:_recordTileUpdate(tile)
end

function GameImpl:relinquish(tile: number)
	if not self:hasOwner(tile) then
		error("Cannot relinquish tile because it is unowned")
	end
	if self:isWater(tile) then
		error("Cannot relinquish water")
	end
	local previousOwner = self:owner(tile)
	previousOwner._lastTileChange = self._ticks
	previousOwner._tileChangeVersion += 1
	previousOwner._tiles:delete(tile)
	previousOwner._borderTiles:delete(tile)

	self._territoryVersion += 1
	self._map:setOwnerID(tile, 0)
	self:_updateBorders(tile)
	self:_recordTileUpdate(tile)
end

local borderNbuf = { 0, 0, 0, 0 }

function GameImpl:_updateBorders(tile: number)
	self:_updateBorderStatus(tile)
	local n = self._map:neighbors4(tile, borderNbuf)
	-- Copy: _updateBorderStatus does not touch borderNbuf, but keep the
	-- neighbor list stable regardless.
	local a, b, c, d = borderNbuf[1], borderNbuf[2], borderNbuf[3], borderNbuf[4]
	local list = { a, b, c, d }
	for i = 1, n do
		self:_updateBorderStatus(list[i])
	end
end

function GameImpl:_updateBorderStatus(t: number)
	if not self._map:hasOwner(t) then
		return
	end
	local owner = self:owner(t)
	if self._map:isBorder(t) then
		owner._borderTiles:add(t)
	else
		owner._borderTiles:delete(t)
	end
end

function GameImpl:target(targeter, target)
	self:addUpdate({ type = "TargetPlayer", playerID = targeter:smallID(), targetID = target:smallID() })
end

function GameImpl:territoryVersion(): number
	return self._territoryVersion
end

-- Immunity & time ------------------------------------------------------------------------

function GameImpl:_ticksSinceStart(): number
	if self:inSpawnPhase() then
		return 0
	end
	return math.max(0, self._ticks - self._startTick)
end

function GameImpl:isSpawnImmunityActive(): boolean
	return self:inSpawnPhase() or self:_ticksSinceStart() < self._config:spawnImmunityDuration()
end

function GameImpl:isNationSpawnImmunityActive(): boolean
	return self:inSpawnPhase() or self:_ticksSinceStart() < self._config:nationSpawnImmunityDuration()
end

function GameImpl:elapsedGameSeconds(): number
	return self:_ticksSinceStart() / 10
end

-- Winner ------------------------------------------------------------------------------------

function GameImpl:setWinner(winner, allPlayersStats)
	self._winner = winner
	self:addUpdate({ type = "Win", winner = winner, allPlayersStats = allPlayersStats })
end

function GameImpl:getWinner()
	return self._winner
end

function GameImpl:teams(): { string }
	if self._config:gameConfig().gameMode ~= GameMode.Team then
		return {}
	end
	local out = { self._botTeam }
	table.move(self._playerTeams, 1, #self._playerTeams, 2, out)
	return out
end

function GameImpl:teamTilesOwned(team: string): number
	local teamTiles = 0
	for _, p in self._playerList do
		if p:team() == team then
			teamTiles += p:numTilesOwned()
		end
	end
	return teamTiles
end

function GameImpl:totalLandTiles(): number
	return math.max(0, self:numLandTiles() - self:numTilesWithFallout())
end

function GameImpl:teamSpawnArea(team: string)
	local areas = self._teamGameSpawnAreas and self._teamGameSpawnAreas[tostring(#self._playerTeams)]
	if not areas then
		return nil
	end
	local teamIndex = table.find(self._playerTeams, team)
	if teamIndex == nil or teamIndex > #areas then
		return nil
	end
	return areas[teamIndex]
end

-- Messages ------------------------------------------------------------------------------------

function GameImpl:displayMessage(message: string, messageType: number, playerID: string?, goldAmount: number?, params, unitID: number?, focusPlayerID: string?)
	self:addUpdate({
		type = "DisplayEvent",
		messageType = messageType,
		message = message,
		playerID = if playerID ~= nil then self:player(playerID):smallID() else nil,
		goldAmount = goldAmount,
		params = params,
		unitID = unitID,
		focusPlayerID = if focusPlayerID ~= nil then self:player(focusPlayerID):smallID() else nil,
	})
end

function GameImpl:sendEmojiUpdate(msg)
	self:addUpdate({ type = "Emoji", emoji = msg })
end

function GameImpl:displayChat(message: string, category: string, target: string?, playerID: string?, isFrom: boolean, recipient: string)
	self:addUpdate({
		type = "DisplayChatEvent",
		key = message,
		category = category,
		target = target,
		playerID = if playerID ~= nil then self:player(playerID):smallID() else nil,
		isFrom = isFrom,
		recipient = recipient,
	})
end

function GameImpl:displayIncomingUnit(unitID: number, message: string, messageType: number, playerID: string)
	self:addUpdate({
		type = "UnitIncoming",
		unitID = unitID,
		message = message,
		messageType = messageType,
		playerID = self:player(playerID):smallID(),
	})
end

function GameImpl:conquerPlayer(conqueror, conquered)
	if conquered:isDisconnected() and conqueror:isOnSameTeam(conquered) then
		for _, ship in conquered:units(UnitType.Warship, UnitType.TransportShip) do
			conqueror:captureUnit(ship)
		end
	end

	-- Don't transfer gold when the conquered human never attacked anyone.
	local skipGoldTransfer = self._stats:attacksSent(conquered) == 0 and conquered:type() == PlayerType.Human
	local gold = if skipGoldTransfer then 0 else conquered:gold()
	local goldCaptured = if skipGoldTransfer then 0 else self._config:conquerGoldAmount(conquered)

	if skipGoldTransfer then
		self:displayMessage(
			"events_display.conquered_no_gold",
			MessageType.CONQUERED_PLAYER,
			conqueror:id(),
			nil,
			{ name = conquered:displayName() },
			nil,
			conquered:id()
		)
	else
		self:displayMessage(
			"events_display.received_gold_from_conquest",
			MessageType.CONQUERED_PLAYER,
			conqueror:id(),
			gold,
			{ gold = goldCaptured, name = conquered:displayName() },
			nil,
			conquered:id()
		)
		conqueror:addGold(goldCaptured)
		conquered:removeGold(gold)
		self._stats:goldWar(conqueror, conquered, goldCaptured)
	end

	self._stats:recordKill(conqueror, conquered, self._ticks)
	self:addUpdate({
		type = "ConquestEvent",
		conquerorId = conqueror:id(),
		conqueredId = conquered:id(),
		gold = goldCaptured,
	})
end

-- GameMap delegation ------------------------------------------------------------------------
-- Game extends GameMap upstream; these forward unchanged.

for _, name in
	{
		"ref",
		"isValidRef",
		"x",
		"y",
		"cell",
		"width",
		"height",
		"numLandTiles",
		"waterVersion",
		"isValidCoord",
		"isLand",
		"isImpassable",
		"isOceanShore",
		"isOcean",
		"isShoreline",
		"magnitude",
		"terrainByte",
		"setShorelineBit",
		"clearShorelineBit",
		"setOcean",
		"setMagnitude",
		"ownerID",
		"hasOwner",
		"hasFallout",
		"isBorder",
		"isOnEdgeOfMap",
		"neighbors",
		"forEachNeighbor",
		"neighbors4",
		"neighbors8",
		"forEachNeighborWithDiag",
		"isWater",
		"isShore",
		"cost",
		"terrainType",
		"forEachTile",
		"manhattanDist",
		"euclideanDistSquared",
		"circleSearch",
		"bfs",
		"tileState",
		"numTilesWithFallout",
		"hasDefenseBonus",
	}
do
	GameImpl[name] = function(self, ...)
		local map = self._map
		return map[name](map, ...)
	end
end

function GameImpl:setOwnerID(ref: number, playerId: number)
	self._territoryVersion += 1
	self._map:setOwnerID(ref, playerId)
end

GameImpl.TerraNullius = TerraNullius
return GameImpl
