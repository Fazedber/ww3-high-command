-- Port of OpenFrontIO src/core/game/PlayerImpl.ts.
--
-- Porting notes:
--  * Troops and gold are bigints upstream; here they are integer-valued
--    numbers, truncated with Util.toInt exactly where upstream calls toInt().
--  * JS Set / Map with insertion-order iteration -> JSSet / ordered maps.
--  * Systems not yet ported are marked TODO(port) and behave as "none"
--    (no units, no alliances), which is how a fresh player starts anyway.

local Shared = game:GetService("ReplicatedStorage").Shared
local GameMap = require(Shared.GameMap)
local JSSet = require(Shared.JSSet)
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local AttackImpl = require(script.Parent.AttackImpl)
local TransportShipUtils = require(script.Parent.TransportShipUtils)
local Scratch = require(script.Parent.TileTraversalScratch)
local GameTypes = require(script.Parent.GameTypes)

local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType
local Structures = GameTypes.Structures
local Relation = GameTypes.Relation
local ColoredTeams = GameTypes.ColoredTeams
local toInt, within, simpleHash = Util.toInt, Util.within, Util.simpleHash

-- Rot re-stamps every second, so a little slack keeps the cue from strobing.
local DECAY_CUE_GRACE_TICKS = 30

-- N, S, W, E — the sampling directions used by shoreReachableNeighbors().
local SHORE_DX = { 0, 0, -1, 1 }
local SHORE_DY = { -1, 1, 0, 0 }

local NEIGHBOR_SCRATCH = { 0, 0, 0, 0 }

-- Insertion-ordered map (JS Map semantics for iteration order).
local OrderedMap = {}
OrderedMap.__index = OrderedMap
function OrderedMap.new()
	return setmetatable({ keys = {}, values = {} }, OrderedMap)
end
function OrderedMap:get(k)
	return self.values[k]
end
function OrderedMap:has(k): boolean
	return self.values[k] ~= nil
end
function OrderedMap:set(k, v)
	if self.values[k] == nil then
		table.insert(self.keys, k)
	end
	self.values[k] = v
end
function OrderedMap:delete(k)
	if self.values[k] ~= nil then
		self.values[k] = nil
		table.remove(self.keys, table.find(self.keys, k) :: number)
	end
end
function OrderedMap:size(): number
	return #self.keys
end
-- Iterates (key, value) in insertion order over a snapshot of the keys.
function OrderedMap:entries()
	local keys = table.clone(self.keys)
	local i = 0
	return function()
		i += 1
		local k = keys[i]
		if k == nil then
			return nil
		end
		return k, self.values[k]
	end
end

local PlayerImpl = {}
PlayerImpl.__index = PlayerImpl
PlayerImpl.OrderedMap = OrderedMap

function PlayerImpl.new(mg, smallID: number, playerInfo, startTroops: number, team: string?)
	local self = setmetatable({
		mg = mg,
		_smallID = smallID,
		playerInfo = playerInfo,
		_team = team,

		_lastTileChange = 0,
		_tileChangeVersion = 0,
		_pseudo_random = PseudoRandom.new(simpleHash(playerInfo.id)),

		_troops = toInt(startTroops),
		_gold = mg:config():startingGold(playerInfo),
		_tradeGold = 0,
		_trainGold = 0,
		_piracyGold = 0,
		_goldEarned = 0,

		markedTraitorTick = -1,
		markedDoomsdayClockTick = -1,
		_rottedAtTick = -1,
		_betrayalCount = 0,

		_embargoes = OrderedMap.new(), -- PlayerID -> { createdAt, isTemporary, target }
		_tiles = JSSet.new(),
		_borderTiles = JSSet.new(),

		_units = {},
		_myUnitsVersion = 0,
		_numUnitsConstructed = {}, -- unitType -> count

		pastOutgoingAllianceRequests = {},
		_expiredAlliances = {},
		_alliances = {}, -- TODO(port): alliances

		_targets = {}, -- { tick, target }
		_relations = OrderedMap.new(), -- Player -> number

		_lastDeleteUnitTick = -1,
		outgoingEmojis_ = {}, -- EmojiMessage list
		outgoingQuickChats_ = {}, -- recipient smallID -> tick
		sentDonations = {}, -- { recipient, tick }
		_lastEmbargoAllTick = -1,

		_incomingAttacks = {},
		_outgoingAttacks = {},

		_spawnTile = nil,
		_isDisconnected = false,
		_disconnectSnapshot = nil,

		largestClusterBoundingBox = nil,
		_nearbyMemo = nil,
	}, PlayerImpl)
	return self
end

-- Basic info ------------------------------------------------------------------

function PlayerImpl:smallID(): number
	return self._smallID
end
function PlayerImpl:name(): string
	return self.playerInfo.name
end
function PlayerImpl:displayName(): string
	return self.playerInfo.displayName
end
function PlayerImpl:clanTag(): string?
	return self.playerInfo.clanTag
end
function PlayerImpl:nationFlag(): string?
	return self.playerInfo.nationFlag
end
function PlayerImpl:clientID(): string?
	return self.playerInfo.clientID
end
function PlayerImpl:id(): string
	return self.playerInfo.id
end
function PlayerImpl:type(): string
	return self.playerInfo.playerType
end
function PlayerImpl:isPlayer(): boolean
	return true
end
function PlayerImpl:info()
	return self.playerInfo
end
function PlayerImpl:isLobbyCreator(): boolean
	return self.playerInfo.isLobbyCreator
end
function PlayerImpl:__tostring(): string
	return `Player:\{name:{self.playerInfo.name},clientID:{self.playerInfo.clientID},isAlive:{self:isAlive()},troops:{self._troops},numTileOwned:{self:numTilesOwned()}}]`
end

-- Units -------------------------------------------------------------------------

-- units() -> live list; units(type, ...) / units({types}) -> fresh filtered copy.
function PlayerImpl:units(...: any): { any }
	local n = select("#", ...)
	if n == 0 then
		return self._units
	end
	local first = ...
	-- Single-type queries are memoised on _myUnitsVersion (bumped by every
	-- change to _units); callers get a copy.
	if n == 1 and type(first) == "string" then
		local cache = self._unitsByTypeCache
		if cache == nil or cache.version ~= self._myUnitsVersion then
			cache = { version = self._myUnitsVersion, lists = {} }
			self._unitsByTypeCache = cache
		end
		local list = cache.lists[first]
		if list == nil then
			list = {}
			for _, u in self._units do
				if u:type() == first then
					table.insert(list, u)
				end
			end
			cache.lists[first] = list
		end
		return table.clone(list)
	end
	local wanted = {}
	if type(first) == "table" then
		if #first == 0 then
			return self._units
		end
		for _, x in first do
			wanted[x] = true
		end
	else
		for i = 1, n do
			local t = select(i, ...)
			if t ~= nil then
				wanted[t] = true
			end
		end
	end
	local out = {}
	for _, u in self._units do
		if wanted[u:type()] then
			table.insert(out, u)
		end
	end
	return out
end

-- Units built, including those still under construction.
function PlayerImpl:unitsConstructed(unitType: string): number
	return self._numUnitsConstructed[unitType] or 0
end

-- Level-weighted count of owned units of a type.
function PlayerImpl:unitCount(unitType: string): number
	local total = 0
	for _, u in self._units do
		if u:type() == unitType then
			total += u:level()
		end
	end
	return total
end

-- Owned units of a type; under construction counts 1, else its level.
function PlayerImpl:unitsOwned(unitType: string): number
	local total = 0
	for _, u in self._units do
		if u:type() == unitType then
			total += if u:isUnderConstruction() then 1 else u:level()
		end
	end
	return total
end

function PlayerImpl:captureUnit(unit)
	if unit:owner() == self then
		error(`Cannot capture unit, {self} already owns {unit}`)
	end
	unit:setOwner(self)
end

function PlayerImpl:buildUnit(unitType: string, spawnTile: number, params)
	local mg = self.mg
	if mg:config():isUnitDisabled(unitType) then
		error(`Attempted to build disabled unit {unitType} at tile {spawnTile} by player {self:name()}`)
	end
	params = params or {}
	local cost = mg:unitInfo(unitType).cost(mg, self)
	local UnitImpl = require(script.Parent.UnitImpl)
	local b = UnitImpl.new(unitType, mg, spawnTile, mg:nextUnitID(), self, params)
	table.insert(self._units, b)
	self._myUnitsVersion += 1
	self._numUnitsConstructed[unitType] = (self._numUnitsConstructed[unitType] or 0) + 1
	self:removeGold(cost)
	self:removeTroops(params.troops or 0)
	mg:addUpdate(b:toUpdate())
	mg:addUnit(b)
	return b
end

function PlayerImpl:_canBuildUnitType(unitType: string, knownCost: number?): boolean
	local mg = self.mg
	if mg:config():isUnitDisabled(unitType) then
		return false
	end
	local cost = knownCost or mg:unitInfo(unitType).cost(mg, self)
	if self._gold < cost then
		return false
	end
	if unitType ~= UnitType.MIRVWarhead and not self:isAlive() then
		return false
	end
	return true
end

function PlayerImpl:_canSpawnUnitType(unitType: string, targetTile: number, validTiles)
	if unitType == UnitType.MIRV then
		if not self.mg:hasOwner(targetTile) then
			return false
		end
		return self:nukeSpawn(targetTile, unitType)
	elseif unitType == UnitType.AtomBomb or unitType == UnitType.HydrogenBomb then
		return self:nukeSpawn(targetTile, unitType)
	elseif unitType == UnitType.TransportShip then
		return TransportShipUtils.canBuildTransportShip(self.mg, self, targetTile)
	elseif unitType == UnitType.MIRVWarhead or unitType == UnitType.Shell or unitType == UnitType.SAMMissile then
		return targetTile
	elseif unitType == UnitType.Port then
		return self:portSpawn(targetTile, validTiles)
	elseif unitType == UnitType.TradeShip then
		return self:tradeShipSpawn(targetTile)
	elseif unitType == UnitType.Train then
		return self:landBasedUnitSpawn(targetTile)
	elseif
		unitType == UnitType.MissileSilo
		or unitType == UnitType.DefensePost
		or unitType == UnitType.SAMLauncher
		or unitType == UnitType.City
		or unitType == UnitType.Factory
	then
		return self:landBasedStructureSpawn(targetTile, validTiles)
	elseif unitType == UnitType.Warship then
		return self:warshipSpawn(targetTile)
	end
	error(`unknown unit type {unitType}`)
end

-- Warships launch from the closest built port on the same water body.
function PlayerImpl:warshipSpawn(tile: number)
	local mg = self.mg
	if not mg:isWater(tile) then
		return false
	end
	local tileComponent = mg:getWaterComponent(tile)
	local bestPort = Util.findClosestBy(self:units(UnitType.Port), function(port)
		return mg:manhattanDist(port:tile(), tile)
	end, function(port)
		return port:isActive() and not port:isUnderConstruction() and tileComponent ~= nil and mg:hasWaterComponent(port:tile(), tileComponent)
	end)
	return if bestPort then bestPort:tile() else false
end

-- Closest ready silo (active, loaded, built) to launch from, or false.
function PlayerImpl:nukeSpawn(tile: number, nukeType: string)
	local mg = self.mg
	if mg:isSpawnImmunityActive() then
		return false
	end
	-- Impassable terrain cannot be nuked.
	if mg:isImpassable(tile) then
		return false
	end
	local owner = mg:owner(tile)
	-- Rebirth shield: no nukes on a shielded player's land.
	if owner:isPlayer() and owner ~= self and owner._shieldUntil and mg:ticks() < owner._shieldUntil then
		return false
	end
	-- Allow nuking teammates after the game is over (aftergame fun), but not in singleplayer.
	local gameOver = mg:getWinner() ~= nil and mg:config():gameConfig().gameType ~= GameTypes.GameType.Singleplayer
	if owner:isPlayer() and self:isOnSameTeam(owner) and not gameOver then
		return false
	end
	local config = mg:config()
	-- Prevent launching nukes that would hit teammate structures (team games only).
	if config:gameConfig().gameMode == GameTypes.GameMode.Team and nukeType ~= UnitType.MIRV and not gameOver then
		local magnitude = config:nukeMagnitudes(nukeType)
		local wouldHitTeammate = mg:anyUnitNearby(tile, magnitude.outer, GameTypes.Structures.types, function(unit)
			return unit:owner():isPlayer() and self:isOnSameTeam(unit:owner())
		end)
		if wouldHitTeammate then
			return false
		end
	end
	local readySilos = {}
	for _, silo in self:units(UnitType.MissileSilo) do
		if silo:isActive() and not silo:isInCooldown() and not silo:isUnderConstruction() then
			table.insert(readySilos, silo)
		end
	end
	Util.sort(readySilos, function(a, b)
		return mg:manhattanDist(a:tile(), tile) - mg:manhattanDist(b:tile(), tile)
	end)
	return if readySilos[1] then readySilos[1]:tile() else false
end

-- Structure placement -------------------------------------------------------------

-- Own tiles within radius 15 of `tile` that keep structureMinDist (15) from
-- every structure, nearest first. Flood order matches GameMap.bfs (stack,
-- N S W E) so the stable sort keeps upstream's tie order.
function PlayerImpl:validStructureSpawnTiles(tile: number): { number }
	local mg = self.mg
	if mg:owner(tile) ~= self then
		return {}
	end
	local searchRadius = 15
	local r2 = searchRadius * searchRadius
	local nearbyUnits = mg:nearbyUnits(tile, searchRadius * 2, Structures.types, nil, true)
	local map = mg:map()
	local w = map:width()
	local cx, cy = tile % w, tile // w
	local smallID = self._smallID
	local function inside(t: number): boolean
		local dx, dy = t % w - cx, t // w - cy
		return dx * dx + dy * dy < r2 and map:ownerID(t) == smallID
	end
	local scratch = Scratch.get(mg)
	local gen = Scratch.bump(scratch)
	local visited = scratch.visited
	local stack = scratch.stack
	table.clear(stack)
	local nearbyTiles = {}
	if inside(tile) then
		buffer.writeu32(visited, tile * 4, gen)
		table.insert(nearbyTiles, tile)
		table.insert(stack, tile)
	end
	local function visit(n: number)
		if buffer.readu32(visited, n * 4) ~= gen and inside(n) then
			buffer.writeu32(visited, n * 4, gen)
			table.insert(nearbyTiles, n)
			table.insert(stack, n)
		end
	end
	while #stack > 0 do
		map:forEachNeighbor(table.remove(stack) :: number, visit)
	end
	-- Humans may build structures closer together (6 tiles) than the upstream 15; nations/bots keep the original rule (golden vectors).
	local minDist2 = (if self:type() == PlayerType.Human then 6 else mg:config():structureMinDist()) ^ 2
	local valid = {}
	for _, t in nearbyTiles do
		local blocked = false
		for _, entry in nearbyUnits do
			if mg:euclideanDistSquared(entry.unit:tile(), t) < minDist2 then
				blocked = true
				break
			end
		end
		if not blocked then
			table.insert(valid, t)
		end
	end
	Util.sort(valid, function(a, b)
		return mg:euclideanDistSquared(a, tile) - mg:euclideanDistSquared(b, tile)
	end)
	return valid
end

function PlayerImpl:landBasedStructureSpawn(tile: number, validTiles): number | false
	local tiles = validTiles or self:validStructureSpawnTiles(tile)
	if #tiles == 0 then
		return false
	end
	return tiles[1]
end

function PlayerImpl:landBasedUnitSpawn(tile: number): number | false
	return if self.mg:isLand(tile) and not self.mg:isImpassable(tile) then tile else false
end

function PlayerImpl:portSpawn(tile: number, validTiles): number | false
	local mg = self.mg
	local spawns = {}
	for t in mg:bfs(tile, GameMap.manhattanDistFN(tile, mg:config():radiusPortSpawn())) do
		if mg:owner(t) == self and mg:isShore(t) then
			table.insert(spawns, t)
		end
	end
	Util.sort(spawns, function(a, b)
		return mg:manhattanDist(a, tile) - mg:manhattanDist(b, tile)
	end)
	local validSet = {}
	for _, t in validTiles or self:validStructureSpawnTiles(tile) do
		validSet[t] = true
	end
	for _, t in spawns do
		if validSet[t] then
			return t
		end
	end
	return false
end

function PlayerImpl:tradeShipSpawn(targetTile: number): number | false
	for _, u in self:units(UnitType.Port) do
		if u:tile() == targetTile then
			return targetTile
		end
	end
	return false
end

-- Upgrades ------------------------------------------------------------------------

function PlayerImpl:_findExistingUnitToUpgrade(unitType: string, targetTile: number)
	local mg = self.mg
	local closest = Util.findClosestBy(mg:nearbyUnits(targetTile, mg:config():structureMinDist(), unitType, nil, true), function(entry)
		return entry.distSquared
	end)
	return if closest then closest.unit else false
end

function PlayerImpl:findUnitToUpgrade(unitType: string, targetTile: number)
	local unit = self:_findExistingUnitToUpgrade(unitType, targetTile)
	if unit == false or not self:canUpgradeUnit(unit) then
		return false
	end
	return unit
end

function PlayerImpl:_canUpgradeUnitType(unitType: string): boolean
	return self.mg:config():unitInfo(unitType).upgradable == true
end

function PlayerImpl:_isUnitValidToUpgrade(unit): boolean
	return not unit:isUnderConstruction() and not unit:isMarkedForDeletion() and unit:owner() == self
end

function PlayerImpl:canUpgradeUnit(unit): boolean
	return self:_canUpgradeUnitType(unit:type()) and self:_canBuildUnitType(unit:type()) and self:_isUnitValidToUpgrade(unit)
end

function PlayerImpl:upgradeUnit(unit)
	local mg = self.mg
	local cost = mg:unitInfo(unit:type()).cost(mg, self)
	self:removeGold(cost)
	unit:increaseLevel()
	self._numUnitsConstructed[unit:type()] = (self._numUnitsConstructed[unit:type()] or 0) + 1
end

-- MAX_UPGRADE_AMOUNT (upstream Game.ts): longest bulk-upgrade price table.
local MAX_UPGRADE_AMOUNT = 50

-- What can be built / upgraded at `tile` (upstream buildableUnits).
function PlayerImpl:buildableUnits(tile: number?, units: { string }?, railsFor: (string | false)?)
	local mg = self.mg
	local config = mg:config()
	local list = units or GameTypes.PlayerBuildable.types
	local inSpawnPhase = mg:inSpawnPhase()
	local anyStructure = false
	for _, u in list do
		if Structures.has(u) then
			anyStructure = true
			break
		end
	end
	local validTiles = if tile ~= nil and anyStructure then self:validStructureSpawnTiles(tile) else {}
	local result = {}
	for _, u in list do
		local cost = config:unitInfo(u).cost(mg, self)
		local canUpgrade = false
		local canBuild = false
		if tile ~= nil and self:_canBuildUnitType(u, cost) and not inSpawnPhase then
			if self:_canUpgradeUnitType(u) then
				local existing = self:_findExistingUnitToUpgrade(u, tile)
				if existing ~= false and self:_isUnitValidToUpgrade(existing) then
					canUpgrade = existing:id()
				end
			end
			canBuild = self:_canSpawnUnitType(u, tile, validTiles)
		end
		local upgradeCosts = nil
		if canUpgrade ~= false then
			upgradeCosts = table.create(MAX_UPGRADE_AMOUNT)
			local total = 0
			for n = 0, MAX_UPGRADE_AMOUNT - 1 do
				total += config:unitInfo(u).cost(mg, self, n)
				upgradeCosts[n + 1] = total
			end
		end
		-- railsFor (Roblox): nil = every type (upstream), false = none, a type =
		-- only that one (the build ghost), so hover queries skip the pathfinding.
		local buildNew = canBuild ~= false and canUpgrade == false and (railsFor == nil or railsFor == u)
		local rail = mg:railNetwork()
		table.insert(result, {
			type = u,
			canBuild = canBuild,
			canUpgrade = canUpgrade,
			cost = cost,
			upgradeCosts = upgradeCosts,
			overlappingRailroads = if buildNew then rail:overlappingRailroads(u, canBuild) else {},
			ghostRailPaths = if buildNew then rail:computeGhostRailPaths(u, canBuild) else {},
		})
	end
	return result
end

-- Spawn tile for a unit of this type aimed at targetTile, or false.
function PlayerImpl:canBuild(unitType: string, targetTile: number, validTiles)
	if not self:_canBuildUnitType(unitType) then
		return false
	end
	return self:_canSpawnUnitType(unitType, targetTile, validTiles)
end

-- Territory ---------------------------------------------------------------------

function PlayerImpl:sharesBorderWith(other): boolean
	local map = self.mg:map()
	local otherID = other:smallID()
	local nbuf = NEIGHBOR_SCRATCH
	for border in self._borderTiles do
		local n = map:neighbors4(border, nbuf)
		for i = 1, n do
			if map:ownerID(nbuf[i]) == otherID then
				return true
			end
		end
	end
	return false
end

function PlayerImpl:numTilesOwned(): number
	return self._tiles:size()
end
function PlayerImpl:tiles()
	return self._tiles
end
function PlayerImpl:borderTiles()
	return self._borderTiles
end

function PlayerImpl:nearby(): { any }
	-- Memoised on territory + water versions, exactly like upstream.
	local version = self.mg:territoryVersion()
	local waterVersion = self.mg:map():waterVersion()
	local memo = self._nearbyMemo
	if memo ~= nil and memo.version == version and memo.waterVersion == waterVersion then
		return table.clone(memo.result)
	end
	local result = self:_computeNearby()
	self._nearbyMemo = { version = version, waterVersion = waterVersion, result = result }
	return table.clone(result)
end

function PlayerImpl:_computeNearby(): { any }
	local ns = JSSet.new()
	local map = self.mg:map()
	local smallID = self._smallID
	local mg = self.mg
	local function visit(neighbor: number)
		if map:isLand(neighbor) and not map:isImpassable(neighbor) then
			if not map:hasOwner(neighbor) and map:hasFallout(neighbor) then
				return
			end
			local owner = map:ownerID(neighbor)
			if owner ~= smallID then
				ns:add(mg:playerBySmallID(owner))
			end
		end
	end
	for border in self._borderTiles do
		map:forEachNeighbor(border, visit)
	end
	for n in self:_shoreReachableNeighbors() do
		ns:add(n)
	end
	return ns:toArray()
end

-- Samples every 10th shore border tile and checks the tile 5 steps away in each
-- cardinal direction that immediately enters water, to detect players across
-- a small river (up to 4 water tiles wide).
function PlayerImpl:_shoreReachableNeighbors()
	local ns = JSSet.new()
	local map = self.mg:map()
	local shoreIdx = 0
	for border in self._borderTiles do
		if not map:isShore(border) then
			continue
		end
		local visitThis = shoreIdx % 10 == 0
		shoreIdx += 1
		if not visitThis then
			continue
		end
		local bx, by = map:x(border), map:y(border)
		for d = 1, 4 do
			local dx, dy = SHORE_DX[d], SHORE_DY[d]
			local x1, y1 = bx + dx, by + dy
			if not map:isValidCoord(x1, y1) or not map:isWater(map:ref(x1, y1)) then
				continue
			end
			local nx, ny = bx + dx * 5, by + dy * 5
			if not map:isValidCoord(nx, ny) then
				continue
			end
			local tile = map:ref(nx, ny)
			if not map:isLand(tile) then
				continue
			end
			if map:isImpassable(tile) then
				continue
			end
			if not map:hasOwner(tile) and map:hasFallout(tile) then
				continue
			end
			local owner = map:ownerID(tile)
			if owner ~= self._smallID then
				ns:add(self.mg:playerBySmallID(owner))
			end
		end
	end
	return ns
end

function PlayerImpl:setTroops(troops: number)
	self._troops = toInt(troops)
end
function PlayerImpl:conquer(tile: number)
	self.mg:conquer(self, tile)
end

function PlayerImpl:orderRetreat(id: string)
	for _, attack in self._outgoingAttacks do
		if attack:id() == id then
			attack:orderRetreat()
			return
		end
	end
	warn(`Didn't find outgoing attack with id {id}`)
end

function PlayerImpl:executeRetreat(id: string)
	-- Execution is delayed so it's not an error that the attack does not exist.
	for _, attack in self._outgoingAttacks do
		if attack:id() == id then
			attack:executeRetreat()
			return
		end
	end
end

function PlayerImpl:relinquish(tile: number)
	if self.mg:owner(tile) ~= self then
		error("Cannot relinquish tile not owned by this player")
	end
	self.mg:relinquish(tile)
end

function PlayerImpl:isAlive(): boolean
	return self._tiles:size() > 0
end
function PlayerImpl:hasSpawned(): boolean
	return self._spawnTile ~= nil
end
function PlayerImpl:setSpawnTile(spawnTile: number)
	self._spawnTile = spawnTile
end
function PlayerImpl:spawnTile(): number?
	return self._spawnTile
end

-- Alliances -----------------------------------------------------------------------
-- Pending requests live on the game (mg.allianceRequests).

function PlayerImpl:incomingAllianceRequests(): { any }
	local out = {}
	for _, ar in self.mg.allianceRequests do
		if ar:recipient() == self then
			table.insert(out, ar)
		end
	end
	return out
end

function PlayerImpl:outgoingAllianceRequests(): { any }
	local out = {}
	for _, ar in self.mg.allianceRequests do
		if ar:requestor() == self then
			table.insert(out, ar)
		end
	end
	return out
end

function PlayerImpl:alliances(): { any }
	return self._alliances
end
function PlayerImpl:expiredAlliances(): { any }
	return table.clone(self._expiredAlliances)
end
function PlayerImpl:allies(): { any }
	local out = {}
	for _, a in self._alliances do
		table.insert(out, a:other(self))
	end
	return out
end

function PlayerImpl:isAlliedWith(other): boolean
	if other == self then
		return false
	end
	return self:allianceWith(other) ~= nil
end

function PlayerImpl:allianceWith(other)
	if other == self then
		return nil
	end
	for _, a in self._alliances do
		if a:recipient() == other or a:requestor() == other then
			return a
		end
	end
	return nil
end

function PlayerImpl:isRequestingAllianceWith(other): boolean
	for _, ar in self.mg.allianceRequests do
		if ar:requestor() == self and ar:recipient() == other then
			return true
		end
	end
	return false
end

-- Upstream allianceInfo: expiry and extension state of our alliance with other.
function PlayerImpl:allianceInfo(other)
	local alliance = self:allianceWith(other)
	if not alliance then
		return nil
	end
	local inExtensionWindow = alliance:expiresAt() <= self.mg:ticks() + self.mg:config():allianceExtensionPromptOffset()
	local canExtend = not self:isDisconnected()
		and not other:isDisconnected()
		and self:isAlive()
		and other:isAlive()
		and inExtensionWindow
		and not alliance:agreedToExtend(self)
	return {
		expiresAt = alliance:expiresAt(),
		inExtensionWindow = inExtensionWindow,
		myPlayerAgreedToExtend = alliance:agreedToExtend(self),
		otherAgreedToExtend = alliance:agreedToExtend(other),
		canExtend = canExtend,
	}
end

-- Upstream playerProfile: relations by smallID and allied smallIDs.
function PlayerImpl:playerProfile()
	local relations = {}
	for _, row in self:allRelationsSorted() do
		relations[row.player:smallID()] = row.relation
	end
	local alliances = {}
	for _, a in self._alliances do
		table.insert(alliances, a:other(self):smallID())
	end
	return { relations = relations, alliances = alliances }
end

function PlayerImpl:canSendAllianceRequest(other): boolean
	local config = self.mg:config()
	if config:disableAlliances() then
		return false
	end
	if other == self then
		return false
	end
	if self:isDisconnected() or other:isDisconnected() then
		return false
	end
	if self:isFriendly(other) or not self:isAlive() then
		return false
	end
	for _, ar in self:outgoingAllianceRequests() do
		if ar:recipient() == other then
			return false
		end
	end
	for _, ar in self:incomingAllianceRequests() do
		if ar:requestor() == other then
			return true
		end
	end
	local latest = nil
	for _, ar in self.pastOutgoingAllianceRequests do
		if ar:recipient() == other and (latest == nil or ar:createdAt() > latest) then
			latest = ar:createdAt()
		end
	end
	if latest == nil then
		return true
	end
	return self.mg:ticks() - latest >= config:allianceRequestCooldown()
end

function PlayerImpl:breakAlliance(alliance)
	self.mg:breakAlliance(self, alliance)
end
function PlayerImpl:removeAllAlliances()
	self.mg:removeAlliancesByPlayerSilently(self)
end
function PlayerImpl:createAllianceRequest(recipient)
	if self:isAlliedWith(recipient) then
		error("cannot create alliance request, already allies")
	end
	return self.mg:createAllianceRequest(self, recipient)
end

-- Traitor / doomsday --------------------------------------------------------------

function PlayerImpl:isTraitor(): boolean
	return self:getTraitorRemainingTicks() > 0
end

function PlayerImpl:getTraitorRemainingTicks(): number
	if self.markedTraitorTick < 0 then
		return 0
	end
	local elapsed = self.mg:ticks() - self.markedTraitorTick
	local remaining = self.mg:config():traitorDuration() - elapsed
	return if remaining > 0 then remaining else 0
end

function PlayerImpl:markTraitor()
	self.markedTraitorTick = self.mg:ticks()
	self._betrayalCount += 1
	self.mg:stats():betray(self)
end

function PlayerImpl:inDoomsdayClock(): boolean
	return self:isAlive() and self.markedDoomsdayClockTick >= 0
end
function PlayerImpl:doomsdayClockTicks(): number
	return if self:inDoomsdayClock() then self.mg:ticks() - self.markedDoomsdayClockTick else 0
end
function PlayerImpl:enterDoomsdayClock()
	if self.markedDoomsdayClockTick < 0 then
		self.markedDoomsdayClockTick = self.mg:ticks()
	end
end
function PlayerImpl:clearDoomsdayClock()
	self.markedDoomsdayClockTick = -1
	self._rottedAtTick = -1
end
function PlayerImpl:markRotted()
	self._rottedAtTick = self.mg:ticks()
end
function PlayerImpl:isDecaying(): boolean
	if not self:inDoomsdayClock() or self._rottedAtTick < 0 then
		return false
	end
	return self.mg:ticks() - self._rottedAtTick <= DECAY_CUE_GRACE_TICKS
end

function PlayerImpl:betrayals(): number
	return self._betrayalCount
end

-- Relations -------------------------------------------------------------------------

local function relationFromValue(v: number): number
	if v < -50 then
		return Relation.Hostile
	end
	if v < 0 then
		return Relation.Distrustful
	end
	if v < 50 then
		return Relation.Neutral
	end
	return Relation.Friendly
end

function PlayerImpl:relation(other): number
	if other == self then
		error(`cannot get relation with self: {self}`)
	end
	return relationFromValue(self._relations:get(other) or 0)
end

function PlayerImpl:allRelationsSorted(): { any }
	local rows = {}
	for p, v in self._relations:entries() do
		if p:isAlive() then
			table.insert(rows, { player = p, relation = v })
		end
	end
	Util.sort(rows, function(a, b)
		return a.relation - b.relation
	end)
	for _, r in rows do
		r.relation = relationFromValue(r.relation)
	end
	return rows
end

function PlayerImpl:updateRelation(other, delta: number)
	if other == self then
		error(`cannot update relation with self: {self}`)
	end
	local relation = self._relations:get(other) or 0
	self._relations:set(other, within(relation + delta, -100, 100))
end

function PlayerImpl:decayRelations()
	for p, r in self._relations:entries() do
		local sign = -1 * math.sign(r)
		local delta = 0.05
		r += sign * delta
		if math.abs(r) < delta * 2 then
			r = 0
		end
		self._relations:set(p, r)
	end
end

-- Targeting ---------------------------------------------------------------------------

function PlayerImpl:canTarget(other): boolean
	if self == other then
		return false
	end
	if self:isFriendly(other) then
		return false
	end
	local cooldown = self.mg:config():targetCooldown()
	for _, t in self._targets do
		if self.mg:ticks() - t.tick < cooldown then
			return false
		end
	end
	return true
end

function PlayerImpl:target(other)
	table.insert(self._targets, { tick = self.mg:ticks(), target = other })
	self.mg:target(self, other)
end

function PlayerImpl:targets(): { any }
	local out = {}
	local duration = self.mg:config():targetDuration()
	for _, t in self._targets do
		if self.mg:ticks() - t.tick < duration then
			table.insert(out, t.target)
		end
	end
	return out
end

function PlayerImpl:transitiveTargets(): { any }
	local ts = JSSet.new()
	for _, a in self._alliances do
		for _, t in a:other(self):targets() do
			ts:add(t)
		end
	end
	for _, t in self:targets() do
		ts:add(t)
	end
	return ts:toArray()
end

-- Cooldown-gated actions -----------------------------------------------------------------
-- TODO(port): emoji, quick chat and donations.

-- Emoji / quick chat / donations ----------------------------------------------------
-- recipient may be GameTypes.AllPlayers ("AllPlayers").

function PlayerImpl:sendEmoji(recipient, emoji: string)
	if recipient == self then
		error(`Cannot send emoji to oneself: {self}`)
	end
	local msg = {
		message = emoji,
		senderID = self:smallID(),
		recipientID = if recipient == GameTypes.AllPlayers then recipient else recipient:smallID(),
		createdAt = self.mg:ticks(),
	}
	table.insert(self.outgoingEmojis_, msg)
	self.mg:sendEmojiUpdate(msg)
end

function PlayerImpl:outgoingEmojis()
	local out = {}
	for _, e in self.outgoingEmojis_ do
		if self.mg:ticks() - e.createdAt < self.mg:config():emojiMessageDuration() then
			table.insert(out, e)
		end
	end
	Util.sort(out, function(a, b)
		return b.createdAt - a.createdAt
	end)
	return out
end

function PlayerImpl:canSendEmoji(recipient): boolean
	if recipient == self then
		return false
	end
	local recipientID = if recipient == GameTypes.AllPlayers then recipient else recipient:smallID()
	for _, msg in self.outgoingEmojis_ do
		if msg.recipientID == recipientID and self.mg:ticks() - msg.createdAt < self.mg:config():emojiMessageCooldown() then
			return false
		end
	end
	return true
end

function PlayerImpl:canSendQuickChat(recipient): boolean
	if recipient == self then
		return false
	end
	local last = self.outgoingQuickChats_[recipient:smallID()]
	return last == nil or self.mg:ticks() - last >= self.mg:config():quickChatCooldown()
end

function PlayerImpl:recordQuickChat(recipient)
	self.outgoingQuickChats_[recipient:smallID()] = self.mg:ticks()
end

function PlayerImpl:_canDonate(recipient, allowedForHumans: boolean): boolean
	if recipient == self then
		return false
	end
	if not self:isAlive() or not recipient:isAlive() or not self:isFriendly(recipient) then
		return false
	end
	if recipient:type() == PlayerType.Human and not allowedForHumans then
		return false
	end
	for _, d in self.sentDonations do
		if d.recipient == recipient and self.mg:ticks() - d.tick < self.mg:config():donateCooldown() then
			return false
		end
	end
	return true
end
function PlayerImpl:canDonateGold(recipient): boolean
	return self:_canDonate(recipient, self.mg:config():donateGold())
end
function PlayerImpl:canDonateTroops(recipient): boolean
	return self:_canDonate(recipient, self.mg:config():donateTroops())
end

function PlayerImpl:donateTroops(recipient, troops: number): boolean
	if recipient == self or troops <= 0 then
		return false
	end
	local removed = self:removeTroops(troops)
	if removed == 0 then
		return false
	end
	recipient:addTroops(removed)
	table.insert(self.sentDonations, { recipient = recipient, tick = self.mg:ticks() })
	self.mg:addUpdate({ type = "DonateEvent", donationType = "troops", senderId = self:id(), recipientId = recipient:id(), amount = removed })
	return true
end

function PlayerImpl:donateGold(recipient, gold: number): boolean
	if recipient == self or gold <= 0 then
		return false
	end
	local removed = self:removeGold(gold)
	if removed == 0 then
		return false
	end
	recipient:addGold(removed)
	table.insert(self.sentDonations, { recipient = recipient, tick = self.mg:ticks() })
	self.mg:addUpdate({ type = "DonateEvent", donationType = "gold", senderId = self:id(), recipientId = recipient:id(), amount = removed })
	return true
end

function PlayerImpl:canDeleteUnit(): boolean
	return self.mg:ticks() - self._lastDeleteUnitTick >= self.mg:config():deleteUnitCooldown()
end
function PlayerImpl:recordDeleteUnit()
	self._lastDeleteUnitTick = self.mg:ticks()
end

function PlayerImpl:canEmbargoAll(): boolean
	if self.mg:ticks() - self._lastEmbargoAllTick < self.mg:config():embargoAllCooldown() then
		return false
	end
	for _, p in self.mg:players() do
		if p:id() == self:id() then
			continue
		end
		if p:type() == PlayerType.Bot then
			continue
		end
		if self:isOnSameTeam(p) then
			continue
		end
		return true
	end
	return false
end
function PlayerImpl:recordEmbargoAll()
	self._lastEmbargoAllTick = self.mg:ticks()
end

-- Embargo ------------------------------------------------------------------------------------

function PlayerImpl:hasEmbargoAgainst(other): boolean
	return self._embargoes:has(other:id())
end

function PlayerImpl:canTrade(other): boolean
	local embargo = other:hasEmbargoAgainst(self) or self:hasEmbargoAgainst(other)
	return not embargo and other:id() ~= self:id()
end

function PlayerImpl:getEmbargoes(): { any }
	local out = {}
	for _, e in self._embargoes:entries() do
		table.insert(out, e)
	end
	return out
end

function PlayerImpl:addEmbargo(other, isTemporary: boolean)
	local embargo = self._embargoes:get(other:id())
	if embargo ~= nil and not embargo.isTemporary then
		return
	end
	self.mg:addUpdate({
		type = "EmbargoEvent",
		event = "start",
		playerID = self._smallID,
		embargoedID = other:smallID(),
	})
	self._embargoes:set(other:id(), { createdAt = self.mg:ticks(), isTemporary = isTemporary, target = other })
end

function PlayerImpl:stopEmbargo(other)
	self._embargoes:delete(other:id())
	self.mg:addUpdate({
		type = "EmbargoEvent",
		event = "stop",
		playerID = self._smallID,
		embargoedID = other:smallID(),
	})
end

function PlayerImpl:endTemporaryEmbargo(other)
	local embargo = self._embargoes:get(other:id())
	if embargo ~= nil and not embargo.isTemporary then
		return
	end
	self:stopEmbargo(other)
end

function PlayerImpl:tradingPartners(): { any }
	local out = {}
	for _, other in self.mg:players() do
		if other ~= self and self:canTrade(other) then
			table.insert(out, other)
		end
	end
	return out
end

-- Teams -----------------------------------------------------------------------------------------

function PlayerImpl:team(): string?
	return self._team
end

function PlayerImpl:isOnSameTeam(other): boolean
	if other == self then
		return false
	end
	if self:team() == nil or other:team() == nil then
		return false
	end
	if self:team() == ColoredTeams.Bot or other:team() == ColoredTeams.Bot then
		return false
	end
	return self._team == other:team()
end

function PlayerImpl:isFriendly(other, treatAFKFriendly: boolean?): boolean
	if other == self then
		return true
	end
	if other:isDisconnected() and not treatAFKFriendly then
		return false
	end
	return self:isOnSameTeam(other) or self:isAlliedWith(other)
end

-- Gold & troops -----------------------------------------------------------------------------------

function PlayerImpl:gold(): number
	return self._gold
end
function PlayerImpl:tradeGold(): number
	return self._tradeGold
end
function PlayerImpl:addTradeGold(toAdd: number)
	self._tradeGold += toAdd
end
function PlayerImpl:trainGold(): number
	return self._trainGold
end
function PlayerImpl:addTrainGold(toAdd: number)
	self._trainGold += toAdd
end
function PlayerImpl:piracyGold(): number
	return self._piracyGold
end
function PlayerImpl:addPiracyGold(toAdd: number)
	self._piracyGold += toAdd
end
function PlayerImpl:goldEarned(): number
	return self._goldEarned
end

function PlayerImpl:addGold(toAdd: number, tile: number?)
	self._gold += toAdd
	-- Lifetime income; starting gold deliberately does not count.
	self._goldEarned += toAdd
	if tile then
		self.mg:addUpdate({ type = "BonusEvent", player = self:id(), tile = tile, gold = toAdd, troops = 0 })
	end
end

function PlayerImpl:removeGold(toRemove: number): number
	if toRemove <= 0 then
		return 0
	end
	local actualRemoved = math.min(self._gold, toRemove)
	self._gold -= actualRemoved
	return actualRemoved
end

function PlayerImpl:troops(): number
	return self._troops
end

function PlayerImpl:addTroops(troops: number)
	if troops < 0 then
		self:removeTroops(-1 * troops)
		return
	end
	self._troops += toInt(troops)
end

function PlayerImpl:removeTroops(troops: number): number
	if troops <= 0 then
		return 0
	end
	local toRemove = math.min(self._troops, toInt(troops))
	self._troops -= toRemove
	return toRemove
end

-- Connection ------------------------------------------------------------------------------------------

function PlayerImpl:tileChangeVersion(): number
	return self._tileChangeVersion
end
function PlayerImpl:lastTileChange(): number
	return self._lastTileChange
end
function PlayerImpl:isDisconnected(): boolean
	return self._isDisconnected
end

function PlayerImpl:markDisconnected(isDisconnected: boolean, snapshot)
	self._isDisconnected = isDisconnected
	if isDisconnected then
		if self._disconnectSnapshot == nil then
			local team = self:team()
			self._disconnectSnapshot = snapshot
				or {
					currentTick = self.mg:ticks(),
					teamTiles = if team then self.mg:teamTilesOwned(team) else 0,
					totalLand = self.mg:totalLandTiles(),
					wasAlive = self:isAlive(),
				}
		end
	else
		self._disconnectSnapshot = nil
	end
end

function PlayerImpl:disconnectSnapshot()
	return self._disconnectSnapshot
end
function PlayerImpl:disconnectedAtTick(): number?
	return if self._disconnectSnapshot then self._disconnectSnapshot.currentTick else nil
end

function PlayerImpl:hash(): number
	local unitHash = 0
	for _, unit in self._units do
		unitHash += unit:hash()
	end
	return simpleHash(self:id()) * (self:troops() + self:numTilesOwned()) + unitHash
end

-- Attacks -----------------------------------------------------------------------------------------------

function PlayerImpl:createAttack(target, troops: number, sourceTile: number?, border)
	local attack = AttackImpl.new(self._pseudo_random:nextID(), target, self, troops, sourceTile, border, self.mg)
	table.insert(self._outgoingAttacks, attack)
	if target:isPlayer() then
		table.insert(target._incomingAttacks, attack)
	end
	return attack
end

function PlayerImpl:outgoingAttacks(): { any }
	return self._outgoingAttacks
end

function PlayerImpl:incomingAttacks(): { any }
	local out = {}
	for _, a in self._incomingAttacks do
		if a:attacker():isAlive() then
			table.insert(out, a)
		end
	end
	return out
end

function PlayerImpl:isImmune(): boolean
	-- Roblox port: a short shield after a Rebirth (see GameServer applyRebirth).
	if self._shieldUntil and self.mg:ticks() < self._shieldUntil then
		return true
	end
	local t = self:type()
	if t == PlayerType.Human then
		return self.mg:isSpawnImmunityActive()
	end
	if t == PlayerType.Nation then
		return self.mg:isNationSpawnImmunityActive()
	end
	return false
end

function PlayerImpl:canAttackPlayer(player, treatAFKFriendly: boolean?): boolean
	if self:type() ~= PlayerType.Human then
		-- Only human attackers respect PVP immunity
		return not self:isFriendly(player, treatAFKFriendly)
	end
	return not player:isImmune() and not self:isFriendly(player, treatAFKFriendly)
end

function PlayerImpl:canAttack(tile: number): boolean
	local mg = self.mg
	local owner = mg:owner(tile)
	if owner == self then
		return false
	end
	if owner:isPlayer() and not self:canAttackPlayer(owner) then
		return false
	end
	if not mg:isLand(tile) or mg:isImpassable(tile) then
		return false
	end
	if mg:hasOwner(tile) then
		return self:sharesBorderWith(owner)
	end
	local filter = GameMap.andFN(function(gm, t)
		return not gm:hasOwner(t) and gm:isLand(t) and not gm:isImpassable(t)
	end, GameMap.manhattanDistFN(tile, 200))
	for t in mg:bfs(tile, filter) do
		for _, n in mg:neighbors(t) do
			if mg:owner(n) == self then
				return true
			end
		end
	end
	return false
end

function PlayerImpl:bestTransportShipSpawn(targetTile: number)
	return TransportShipUtils.bestShoreDeploymentSource(self.mg, self, targetTile) or false
end

return PlayerImpl
