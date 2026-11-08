-- Port of OpenFrontIO src/core/execution/nation/NationStructureBehavior.ts:
-- which structures a nation builds / upgrades, where, and when.

local Shared = game:GetService("ReplicatedStorage").Shared
local Util = require(Shared.Util)
local JSSet = require(Shared.JSSet)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local ConstructionExecution = require(script.Parent.ConstructionExecution)
local StructureExecutions = require(script.Parent.StructureExecutions)
local NationUtils = require(script.Parent.NationUtils)
local SharedWaterCache = require(script.Parent.SharedWaterCache)

local UnitType = GameTypes.UnitType
local Difficulty = GameTypes.Difficulty
local GameMode = GameTypes.GameMode
local PlayerType = GameTypes.PlayerType
local Structures = GameTypes.Structures
local UpgradeStructureExecution = StructureExecutions.UpgradeStructureExecution

-- SAM launcher ratio per city, keyed by difficulty
local SAM_RATIO_BY_DIFFICULTY = {
	[Difficulty.Easy] = 0.15,
	[Difficulty.Medium] = 0.2,
	[Difficulty.Hard] = 0.25,
	[Difficulty.Impossible] = 0.3,
}

-- Structure ratios relative to city count, adjusted by difficulty.
local function getStructureRatios(difficulty: string)
	return {
		[UnitType.Port] = { ratioPerCity = 0.75, perceivedCostIncreasePerOwned = 1 },
		[UnitType.Factory] = { ratioPerCity = 0.75, perceivedCostIncreasePerOwned = 1 },
		[UnitType.SAMLauncher] = { ratioPerCity = SAM_RATIO_BY_DIFFICULTY[difficulty], perceivedCostIncreasePerOwned = 0.3 },
		[UnitType.MissileSilo] = { ratioPerCity = 0.2, perceivedCostIncreasePerOwned = 1 },
	}
end

local CITY_PERCEIVED_COST_INCREASE_PER_OWNED = 1
local FACTORY_COASTAL_RATIO_MULTIPLIER = 0.33
local MAX_MISSILE_SILOS = 3
local FIRST_MISSILE_SILO_RATIO = 0.4
local UPGRADE_DENSITY_THRESHOLD = 1 / 1500
local MIN_PORT_WATER_COMPONENT_SIZE = 3000
local TILES_PER_CITY_EQUIVALENT = 2000
local HIGH_NATION_DENSITY_THRESHOLD = 1 / 7500
local HIGH_STARTING_GOLD_THRESHOLD = 3000000

-- Tick gap a high-starting-gold nation must wait before placing its Nth
-- structure (index 1 = before #1).
local HIGH_GOLD_STRUCTURE_COOLDOWN_TICKS = { 0, 0, 250, 150, 100 }

local TEAM_POST_SAVE_UP_PHASE_TICKS = 150
local UNDER_ATTACK_THREAT_RATIO = 0.35
local DEFENSE_POST_RATIO_PER_POST = 0.4

local NEIGHBOR_SCRATCH = { 0, 0, 0, 0 }

-- Upstream GameImpl owns one SharedWaterCache per game
-- (game.sharedWaterComponents). Use that if the port has it, otherwise a
-- per-game cache here (this behavior is its only caller upstream).
local waterCaches = setmetatable({}, { __mode = "k" })
local function sharedWaterComponents(game, player)
	if game.sharedWaterComponents ~= nil then
		return game:sharedWaterComponents(player)
	end
	local cache = waterCaches[game]
	if cache == nil then
		cache = SharedWaterCache.new(game)
		waterCaches[game] = cache
	end
	return cache:get(player)
end

-- JS truthiness of a canBuild() result (TileRef | false): tile 0 is falsy.
local function truthy(v): boolean
	return v ~= nil and v ~= false and v ~= 0
end

-- From src/core/execution/Util.ts: nearestTileDist.
local function nearestTileDist(gm, tiles: { number }, tile: number): number
	local best = math.huge
	for _, t in tiles do
		local d = gm:manhattanDist(t, tile)
		if d < best then
			best = d
		end
	end
	return best
end

-- nearestTileDist over the unit tiles minus `tile` (upstream builds
-- `new Set(units.map(tile))`, deletes `tile`, then scans; min is order-free).
local function nearestUnitDistExcluding(gm, units, tile: number): number
	local best = math.huge
	for _, u in units do
		local t = u:tile()
		if t == tile then
			continue
		end
		local d = gm:manhattanDist(t, tile)
		if d < best then
			best = d
		end
	end
	return best
end

-- From src/core/execution/Util.ts: nearestTileDistCapped. Manhattan distance
-- to the nearest member of `tiles` when <= cap, else math.huge. Walks rings
-- around `tile` when `tiles` is a set, like upstream.
local function nearestTileDistCapped(gm, tiles, tile: number, cap: number): number
	if type(tiles) ~= "table" or tiles.has == nil then
		local d = nearestTileDist(gm, tiles, tile)
		return if d <= cap then d else math.huge
	end
	if tiles:size() == 0 then
		return math.huge
	end
	if tiles:has(tile) then
		return 0
	end
	local w = gm:width()
	local h = gm:height()
	local cx = gm:x(tile)
	local cy = gm:y(tile)
	local d = 1
	while d <= cap do
		for dx = -d, d do
			local x = cx + dx
			if x < 0 or x >= w then
				continue
			end
			local dy = d - math.abs(dx)
			local y1 = cy - dy
			if y1 >= 0 and tiles:has(y1 * w + x) then
				return d
			end
			if dy ~= 0 then
				local y2 = cy + dy
				if y2 < h and tiles:has(y2 * w + x) then
					return d
				end
			end
		end
		d += 1
	end
	return math.huge
end

local function landAttacksOf(player): { any }
	local out = {}
	for _, a in player:incomingAttacks() do
		if a:sourceTile() == nil then
			table.insert(out, a)
		end
	end
	return out
end

local function sumTroops(attacks: { any }): number
	local sum = 0
	for _, a in attacks do
		sum += a:troops()
	end
	return sum
end

local Behavior = {}
Behavior.__index = Behavior

local M = {}

function M.new(random, game, player)
	return setmetatable({
		random = random,
		game = game,
		player = player,
		reachableStationsCache = nil,
		_sharedWaterComponents = nil,
		lastStructureTick = nil,
		placementsCount = 0,
		builtCrowdedMapFirstStructure = false,
		_hasHighStartingGold = nil,
		_postSaveUpStartTick = nil,
	}, Behavior)
end

function Behavior:handleStructures(): boolean
	-- Defense posts are handled outside the normal pacing/counter system:
	-- they don't increment placementsCount or lastStructureTick, and they
	-- are never built as the very first structure.
	if self.placementsCount > 0 and not self.game:config():isUnitDisabled(UnitType.DefensePost) then
		if self:_tryBuildDefensePost() then
			return true
		end
		-- If the attack threshold is met, block other structures even when
		-- placement failed (no tile found / can't afford).
		if self:_defensePostNeeded() then
			return false
		end
	end

	if self:_isOnStructureCooldown() then
		return false
	end
	if self:_isInPostSaveUpBlockedPhase() then
		return false
	end
	local built = self:_doHandleStructures()
	if built then
		self.lastStructureTick = self.game:ticks()
		self.placementsCount += 1
	end
	return built
end

-- Tries to place one defense post near an active land-attack front.
-- Not on Easy. Medium: 50% chance per call, 1 post total. Hard/Impossible:
-- ceil(ratio / 0.4) posts total. Boat attacks are ignored.
function Behavior:_tryBuildDefensePost(): boolean
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return false
	end
	if difficulty == Difficulty.Medium and not self.random:chance(2) then
		return false
	end

	local player = self.player
	local landAttacks = landAttacksOf(player)
	if #landAttacks == 0 then
		return false
	end

	local ourTroops = player:troops()
	if ourTroops <= 0 then
		return false
	end

	local incomingTroops = sumTroops(landAttacks)
	local ratio = incomingTroops / ourTroops
	if ratio < UNDER_ATTACK_THREAT_RATIO then
		return false
	end

	local allowed
	if difficulty == Difficulty.Medium then
		allowed = 1
	else
		allowed = math.ceil(ratio / DEFENSE_POST_RATIO_PER_POST)
	end

	local frontTiles = self:_getAttackFrontTiles(landAttacks)
	if self:_countDefensePostsNearFront(frontTiles, allowed) >= allowed then
		return false
	end

	local cost = self:_cost(UnitType.DefensePost)
	if player:gold() < cost then
		return false
	end

	local tiles = self:_sampleTilesNearFront(frontTiles, 25, UnitType.DefensePost)
	for _, tile in tiles do
		if not truthy(player:canBuild(UnitType.DefensePost, tile)) then
			continue
		end
		self.game:addExecution(ConstructionExecution.new(player, UnitType.DefensePost, tile))
		return true
	end
	return false
end

function Behavior:_defensePostNeeded(): boolean
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return false
	end
	local landAttacks = landAttacksOf(self.player)
	if #landAttacks == 0 then
		return false
	end
	local ourTroops = self.player:troops()
	if ourTroops <= 0 then
		return false
	end
	local incomingTroops = sumTroops(landAttacks)
	return incomingTroops / ourTroops >= UNDER_ATTACK_THREAT_RATIO
end

-- Our border tiles adjacent to a tile owned by any of the attacking players.
function Behavior:_getAttackFrontTiles(landAttacks: { any }): { number }
	local game = self.game
	local attackerSet = {}
	local any = false
	for _, a in landAttacks do
		attackerSet[a:attacker()] = true
		any = true
	end
	if not any then
		return {}
	end

	local frontTiles = {}
	local nbuf = NEIGHBOR_SCRATCH
	for borderTile in self.player:borderTiles() do
		local n = game:neighbors4(borderTile, nbuf)
		for i = 1, n do
			local owner = game:owner(nbuf[i])
			if owner ~= nil and attackerSet[owner] then
				table.insert(frontTiles, borderTile)
				break
			end
		end
	end
	return frontTiles
end

-- Counts defense posts within 1.5 x borderSpacing of any front tile.
-- `cap` short-circuits the scan once that many are found.
function Behavior:_countDefensePostsNearFront(frontTiles: { number }, cap: number?): number
	if #frontTiles == 0 then
		return 0
	end

	local game = self.game
	local borderSpacing = self:_spacingConstants()
	local r = borderSpacing * 1.5
	local rangeSquared = r * r

	local count = 0
	for _, dp in self.player:units(UnitType.DefensePost) do
		for _, frontTile in frontTiles do
			if game:euclideanDistSquared(dp:tile(), frontTile) <= rangeSquared then
				count += 1
				if cap ~= nil and count >= cap then
					return count
				end
				break
			end
		end
	end
	return count
end

-- Samples territory tiles for defense-post placement around the attack front.
-- Phase 1: tiles at depth [0.75x, 1.5x] borderSpacing from any border.
-- Fallback: relax the depth constraint (canBuild checked by caller).
function Behavior:_sampleTilesNearFront(frontTiles: { number }, count: number, unitType: string): { number }
	local game = self.game
	local player = self.player
	local random = self.random

	if #frontTiles == 0 then
		return {}
	end

	local borderSpacing = self:_spacingConstants()
	local searchRadius = math.ceil(borderSpacing * 1.5)
	local minBorderDist = math.ceil(borderSpacing * 0.75)
	local maxBorderDist = math.ceil(borderSpacing * 1.5)
	local borderTiles = player:borderTiles()

	-- Spread: prefer front tiles far from existing defense posts.
	local sr = borderSpacing * 1.5
	local spreadRangeSquared = sr * sr
	local existingDPTiles = {}
	for _, u in player:units(UnitType.DefensePost) do
		table.insert(existingDPTiles, u:tile())
	end

	local anchors
	if #existingDPTiles > 0 then
		anchors = {}
		for _, ft in frontTiles do
			local near = false
			for _, dp in existingDPTiles do
				if game:euclideanDistSquared(ft, dp) < spreadRangeSquared then
					near = true
					break
				end
			end
			if not near then
				table.insert(anchors, ft)
			end
		end
		if #anchors == 0 then
			anchors = frontTiles
		end
	else
		anchors = frontTiles
	end

	local result = {}
	local attempt = 0
	while attempt < count * 6 and #result < count do
		local anchor = random:randElement(anchors)
		local ax = game:x(anchor)
		local ay = game:y(anchor)
		local x = random:nextInt(ax - searchRadius, ax + searchRadius + 1)
		local y = random:nextInt(ay - searchRadius, ay + searchRadius + 1)
		if game:isValidCoord(x, y) then
			local t = game:ref(x, y)
			if game:owner(t) == player then
				-- Only "inside [min, max]" matters, so the search is capped at max.
				local borderDist = nearestTileDistCapped(game, borderTiles, t, maxBorderDist)
				if
					not (borderDist < minBorderDist or borderDist > maxBorderDist)
					and truthy(player:canBuild(unitType, t))
				then
					table.insert(result, t)
				end
			end
		end
		attempt += 1
	end

	if #result > 0 then
		return result
	end

	-- Fallback: relax border-depth constraint (territory too small for depth ring)
	local fallback = {}
	attempt = 0
	while attempt < count * 4 and #fallback < count do
		local anchor = random:randElement(anchors)
		local ax = game:x(anchor)
		local ay = game:y(anchor)
		local x = random:nextInt(ax - searchRadius, ax + searchRadius + 1)
		local y = random:nextInt(ay - searchRadius, ay + searchRadius + 1)
		if game:isValidCoord(x, y) then
			local t = game:ref(x, y)
			if game:owner(t) == player then
				table.insert(fallback, t)
			end
		end
		attempt += 1
	end

	return fallback
end

function Behavior:_isOnStructureCooldown(): boolean
	-- Only high-starting-gold nations pause
	if self.lastStructureTick == nil or not self:_hasHighStartingGoldCheck() then
		return false
	end
	local requiredGap = HIGH_GOLD_STRUCTURE_COOLDOWN_TICKS[self.placementsCount + 1] or 0
	if requiredGap == 0 then
		return false
	end
	return self.game:ticks() - self.lastStructureTick < requiredGap
end

-- Spreads placements after the save-up target is first reached:
-- 15s ON / 15s OFF, alternating, to allow NationNukeBehavior to spend the gold.
function Behavior:_isInPostSaveUpBlockedPhase(): boolean
	if self.game:config():isUnitDisabled(UnitType.MissileSilo) then
		return false
	end
	local saveUpTarget = self:_getSaveUpTarget()
	if self._postSaveUpStartTick == nil then
		if self.player:gold() < saveUpTarget then
			return false
		end
		self._postSaveUpStartTick = self.game:ticks()
	end
	local elapsed = self.game:ticks() - self._postSaveUpStartTick
	return math.fmod(elapsed, TEAM_POST_SAVE_UP_PHASE_TICKS * 2) >= TEAM_POST_SAVE_UP_PHASE_TICKS
end

function Behavior:_doHandleStructures(): boolean
	self.reachableStationsCache = nil
	local config = self.game:config()
	local citiesDisabled = config:isUnitDisabled(UnitType.City)
	local cityCount = if citiesDisabled
		then math.max(1, math.floor(self.player:numTilesOwned() / TILES_PER_CITY_EQUIVALENT))
		else self.player:unitsOwned(UnitType.City)
	self._sharedWaterComponents = sharedWaterComponents(self.game, self.player)
	local hasCoastalTiles = self._sharedWaterComponents ~= nil

	local missileSilosEnabled = not config:isUnitDisabled(UnitType.MissileSilo)

	-- High-starting-gold Hard/Impossible nations build a SAM first.
	local difficulty = config:gameConfig().difficulty
	if
		self.placementsCount == 0
		and (difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible)
		and not config:isUnitDisabled(UnitType.AtomBomb)
		and missileSilosEnabled
		and not config:isUnitDisabled(UnitType.SAMLauncher)
		and self:_hasHighStartingGoldCheck()
		and self:_maybeSpawnStructure(UnitType.SAMLauncher)
	then
		return true
	end

	-- On crowded maps the first structure is a port (or factory if landlocked)
	-- instead of a city, so nations can get income earlier.
	if not citiesDisabled and not self.builtCrowdedMapFirstStructure and self:_isHighNationDensity() then
		local preferredFirst = if hasCoastalTiles and not config:isUnitDisabled(UnitType.Port)
			then UnitType.Port
			else UnitType.Factory
		if config:isUnitDisabled(preferredFirst) then
			self.builtCrowdedMapFirstStructure = true
		elseif self:_maybeSpawnStructure(preferredFirst) then
			self.builtCrowdedMapFirstStructure = true
			return true
		end
	end

	-- Build order for non-city structures (priority order)
	local buildOrder = { UnitType.Port, UnitType.Factory, UnitType.SAMLauncher, UnitType.MissileSilo }

	local nukesEnabled = not config:isUnitDisabled(UnitType.AtomBomb)
		or not config:isUnitDisabled(UnitType.HydrogenBomb)
		or not config:isUnitDisabled(UnitType.MIRV)

	for _, structureType in buildOrder do
		if config:isUnitDisabled(structureType) then
			continue
		end
		if structureType == UnitType.Port and not hasCoastalTiles then
			continue
		end
		if not nukesEnabled and (structureType == UnitType.MissileSilo or structureType == UnitType.SAMLauncher) then
			continue
		end
		if not missileSilosEnabled and structureType == UnitType.SAMLauncher then
			continue
		end
		if self:_shouldBuildStructure(structureType, cityCount, hasCoastalTiles) then
			if self:_maybeSpawnStructure(structureType) then
				return true
			end
		end
	end

	if not citiesDisabled and self:_maybeSpawnStructure(UnitType.City) then
		return true
	end

	return false
end

function Behavior:_hasHighStartingGoldCheck(): boolean
	if self._hasHighStartingGold == nil then
		self._hasHighStartingGold = self.game:config():startingGold(self.player:info()) >= HIGH_STARTING_GOLD_THRESHOLD
	end
	return self._hasHighStartingGold
end

function Behavior:_isHighNationDensity(): boolean
	local landTiles = self.game:numLandTiles()
	if landTiles <= 0 then
		return false
	end
	return #self.game:nations() / landTiles > HIGH_NATION_DENSITY_THRESHOLD
end

-- Should we build more of this structure type given the city count and ratio?
function Behavior:_shouldBuildStructure(unitType: string, cityCount: number, hasCoastalTiles: boolean): boolean
	local gameConfig = self.game:config()
	local difficulty = gameConfig:gameConfig().difficulty
	local ratios = getStructureRatios(difficulty)
	local config = ratios[unitType]
	if config == nil then
		return false
	end

	local ratio = config.ratioPerCity

	-- Heavily reduce factory spawning if we have coastal tiles
	if unitType == UnitType.Factory and hasCoastalTiles and not gameConfig:isUnitDisabled(UnitType.Port) then
		ratio *= FACTORY_COASTAL_RATIO_MULTIPLIER
	end

	local owned = self.player:unitsOwned(unitType)

	if unitType == UnitType.MissileSilo and owned >= MAX_MISSILE_SILOS then
		return false
	end

	-- First missile silo uses a higher ratio so nations can start nuking earlier
	if unitType == UnitType.MissileSilo and owned == 0 then
		ratio = FIRST_MISSILE_SILO_RATIO
	end

	local targetCount = math.floor(cityCount * ratio)

	return owned < targetCount
end

function Behavior:_cost(unitType: string): number
	return self.game:unitInfo(unitType).cost(self.game, self.player)
end

function Behavior:_maybeSpawnStructure(unitType: string): boolean
	local game = self.game
	local perceivedCost = self:_getPerceivedCost(unitType)
	if self.player:gold() < perceivedCost then
		return false
	end

	-- Check if we should upgrade instead of building new
	local structures = self.player:units(unitType)
	if self:_getTotalStructureDensity() > UPGRADE_DENSITY_THRESHOLD and game:config():unitInfo(unitType).upgradable then
		if self:_maybeUpgradeStructure(structures) then
			return true
		end
		-- Density too high but couldn't upgrade — wait for construction.
		if #structures > 0 then
			return false
		end
		-- No structures of this type exist yet — fall through to build the first one.
	end

	local tile = self:_structureSpawnTile(unitType)
	if tile == nil then
		return false
	end
	local canBuild = self.player:canBuild(unitType, tile)
	if canBuild == false then
		return false
	end
	game:addExecution(ConstructionExecution.new(self.player, unitType, tile))
	return true
end

-- Real cost inflated per owned structure of the type, until the nation can
-- afford its save-up target.
function Behavior:_getPerceivedCost(unitType: string): number
	local realCost = self:_cost(unitType)

	local saveUpTarget = self:_getSaveUpTarget()
	if saveUpTarget == 0 or self.player:gold() >= saveUpTarget then
		return realCost
	end

	local owned = self.player:unitsOwned(unitType)

	local increasePerOwned
	if unitType == UnitType.City then
		increasePerOwned = CITY_PERCEIVED_COST_INCREASE_PER_OWNED
	else
		local difficulty = self.game:config():gameConfig().difficulty
		local ratios = getStructureRatios(difficulty)
		local config = ratios[unitType]
		increasePerOwned = if config ~= nil then config.perceivedCostIncreasePerOwned else 0.1
	end

	local multiplier = 1 + increasePerOwned * owned
	return math.ceil(realCost * multiplier)
end

-- Gold target to save up for based on which nukes are enabled.
function Behavior:_getSaveUpTarget(): number
	local config = self.game:config()

	-- Just save up for SAMs if missile silos are disabled
	if config:isUnitDisabled(UnitType.MissileSilo) then
		return self:_cost(UnitType.SAMLauncher)
	end

	-- Save up a limited amount in team games, synced with NationNukeBehavior
	if config:gameConfig().gameMode == GameMode.Team then
		return self:_cost(UnitType.HydrogenBomb)
	end

	local mirvEnabled = not config:isUnitDisabled(UnitType.MIRV)
	local hydroEnabled = not config:isUnitDisabled(UnitType.HydrogenBomb)
	local atomEnabled = not config:isUnitDisabled(UnitType.AtomBomb)

	if mirvEnabled then
		return self:_cost(UnitType.MIRV) + self:_cost(UnitType.HydrogenBomb)
	end
	if hydroEnabled then
		return self:_cost(UnitType.HydrogenBomb) * 5
	end
	if atomEnabled then
		return self:_cost(UnitType.AtomBomb) * 20
	end
	return self:_cost(UnitType.SAMLauncher)
end

function Behavior:_maybeUpgradeStructure(structures: { any }): boolean
	if self:_getTotalStructureDensity() <= UPGRADE_DENSITY_THRESHOLD then
		return false
	end
	if #structures == 0 then
		return false
	end
	local structureToUpgrade = self:_findBestStructureToUpgrade(structures)
	if structureToUpgrade ~= nil then
		self.game:addExecution(UpgradeStructureExecution.new(self.player, structureToUpgrade:id()))
		return true
	end
	return false
end

function Behavior:_getTotalStructureDensity(): number
	local tilesOwned = self.player:numTilesOwned()
	return if tilesOwned > 0 then #self.player:units(Structures.types) / tilesOwned else 0
end

-- Best structure to upgrade, preferring SAM-protected ones. In 50% of cases
-- picks the second or third best for variety.
function Behavior:_findBestStructureToUpgrade(structures: { any })
	local game = self.game
	local random = self.random
	if #structures == 0 then
		return nil
	end

	local upgradable = {}
	for _, s in structures do
		if self.player:canUpgradeUnit(s) then
			table.insert(upgradable, s)
		end
	end
	if #upgradable == 0 then
		return nil
	end

	local difficulty = game:config():gameConfig().difficulty
	local randomChance
	if difficulty == Difficulty.Easy then
		randomChance = 70
	elseif difficulty == Difficulty.Medium then
		randomChance = 40
	elseif difficulty == Difficulty.Hard then
		randomChance = 25
	elseif difficulty == Difficulty.Impossible then
		randomChance = 10
	else
		error(`Unexpected difficulty: {difficulty}`)
	end

	if random:nextInt(0, 100) < randomChance then
		return random:randElement(upgradable)
	end

	local samLaunchers = self.player:units(UnitType.SAMLauncher)

	local scored = {}
	for _, structure in upgradable do
		local score = 0

		for _, sam in samLaunchers do
			local samRange = game:config():samRange(sam:level())
			local samRangeSquared = samRange * samRange
			local distSquared = game:euclideanDistSquared(structure:tile(), sam:tile())
			if distSquared <= samRangeSquared then
				score += 10
				if sam:level() > 1 then
					score += (sam:level() - 1) * 7.5
				end
			end
		end

		-- Add small random factor to break ties
		score += random:nextInt(0, 5)

		table.insert(scored, { structure = structure, score = score })
	end

	if #scored == 0 then
		return nil
	end

	Util.sort(scored, function(a, b)
		return b.score - a.score
	end)

	if #scored >= 2 and random:chance(2) then
		local pickIndex = if #scored >= 3 then random:nextInt(1, 3) else 1
		return scored[pickIndex + 1].structure
	end

	return scored[1].structure
end

function Behavior:_structureSpawnTile(unitType: string): number?
	local tiles = if unitType == UnitType.Port
		then self:_randCoastalTileArray(25)
		else NationUtils.randTerritoryTileArray(self.random, self.game, self.player, 25)
	if #tiles == 0 then
		return nil
	end
	local valueFunction = self:_structureSpawnTileValue(unitType)
	if valueFunction == nil then
		return nil
	end
	local bestTile = nil
	local bestValue = 0
	for _, t in tiles do
		local v = valueFunction(t)
		if v <= bestValue and bestTile ~= nil then
			continue
		end
		if not truthy(self.player:canBuild(unitType, t)) then
			continue
		end
		bestTile = t
		bestValue = v
	end
	return bestTile
end

-- Samples shore tiles adjacent to water reachable by another player.
function Behavior:_randCoastalTileArray(numTiles: number): { number }
	local game = self.game
	local shared = self._sharedWaterComponents
	local tiles = {}
	for t in self.player:borderTiles() do
		if not game:isShore(t) then
			continue
		end
		if shared == nil then
			continue
		end
		for _, neighbor in game:neighbors(t) do
			if not game:isWater(neighbor) then
				continue
			end
			-- Ocean is always considered shared.
			if game:isOcean(neighbor) then
				table.insert(tiles, t)
				break
			end
			local comp = game:getWaterComponent(neighbor)
			if comp == nil or not shared:has(comp) then
				continue
			end
			-- Skip tiny lakes that are too small for meaningful port use (not on Easy).
			local difficulty = game:config():gameConfig().difficulty
			if difficulty ~= Difficulty.Easy then
				local size = game:getWaterComponentSize(neighbor)
				if size ~= nil and size < MIN_PORT_WATER_COMPONENT_SIZE then
					continue
				end
			end
			table.insert(tiles, t)
			break
		end
	end
	return self:_arraySampler(tiles, numTiles)
end

function Behavior:_arraySampler(a: { any }, sampleSize: number): { any }
	if #a <= sampleSize then
		return table.clone(a)
	end
	local out = {}
	local remaining = JSSet.new(a)
	for _ = 1, sampleSize do
		local t = self.random:randFromSet(remaining)
		remaining:delete(t)
		table.insert(out, t)
	end
	return out
end

function Behavior:_structureSpawnTileValue(unitType: string): ((number) -> number)?
	if unitType == UnitType.City then
		return self:_cityValue()
	elseif unitType == UnitType.MissileSilo then
		return self:_missileSiloValue()
	elseif unitType == UnitType.Factory then
		return self:_factoryValue()
	elseif unitType == UnitType.Port then
		return self:_portValue()
	elseif unitType == UnitType.SAMLauncher then
		return self:_samLauncherValue()
	end
	error(`Value function not implemented for {unitType}`)
end

-- Prefers high elevation, distance from border, and spacing from same-type structures.
function Behavior:_missileSiloValue(): (number) -> number
	local game = self.game
	local borderTiles = self.player:borderTiles()
	local otherUnits = self.player:units(UnitType.MissileSilo)
	local borderSpacing, structureSpacing = self:_spacingConstants()

	return function(tile: number): number
		local w = 0

		w += game:magnitude(tile)

		-- Clamped at borderSpacing, so the ring search may stop there.
		local closestBorderDist = nearestTileDistCapped(game, borderTiles, tile, borderSpacing)
		w += math.min(closestBorderDist, borderSpacing)

		local d = nearestUnitDistExcluding(game, otherUnits, tile)
		if d ~= math.huge then
			w += math.min(d, structureSpacing)
		end

		return w
	end
end

-- Prefers spacing from other ports.
function Behavior:_portValue(): (number) -> number
	local game = self.game
	local otherUnits = self.player:units(UnitType.Port)

	return function(tile: number): number
		local w = 0
		local closestOtherDist = nearestUnitDistExcluding(game, otherUnits, tile)
		w += closestOtherDist
		return w
	end
end

-- Prefers high elevation, spacing from other factories / cities, distance
-- from border, and (difficulty-gated) rail-cluster connectivity.
function Behavior:_factoryValue(): (number) -> number
	local game = self.game
	local player = self.player
	local borderTiles = player:borderTiles()
	local otherUnits = player:units(UnitType.Factory)
	local borderSpacing, structureSpacing = self:_spacingConstants()
	local stationRange = game:config():trainStationMaxRange()
	local stationRangeSquared = stationRange * stationRange
	local difficulty = game:config():gameConfig().difficulty
	local useConnectionScore = self:_shouldUseConnectivityScore(difficulty)

	local reachableStations = if useConnectionScore then self:_getOrBuildReachableStations() else {}
	local minRange = game:config():trainStationMinRange()
	local minRangeSquared = minRange * minRange

	-- Cross-type spacing: prefer to be away from cities.
	local cityTiles = {}
	for _, u in player:units(UnitType.City) do
		table.insert(cityTiles, u:tile())
	end

	return function(tile: number): number
		local w = 0

		w += game:magnitude(tile)

		local closestBorderDist = nearestTileDistCapped(game, borderTiles, tile, borderSpacing)
		w += math.min(closestBorderDist, borderSpacing)

		local d = nearestUnitDistExcluding(game, otherUnits, tile)
		if d ~= math.huge then
			w += math.min(d, stationRange)
		end

		local d2 = nearestTileDist(game, cityTiles, tile)
		if d2 ~= math.huge then
			w += math.min(d2, structureSpacing)
		end

		if not useConnectionScore then
			return w
		end

		w += self:_computeConnectivityScore(tile, reachableStations, minRangeSquared, stationRangeSquared)
			* structureSpacing

		return w
	end
end

function Behavior:_shouldUseConnectivityScore(difficulty: string): boolean
	local randomChance
	if difficulty == Difficulty.Easy then
		randomChance = 0
	elseif difficulty == Difficulty.Medium then
		randomChance = 60
	elseif difficulty == Difficulty.Hard then
		randomChance = 75
	elseif difficulty == Difficulty.Impossible then
		randomChance = 100
	else
		error(`Unexpected difficulty: {difficulty}`)
	end

	return self.random:nextInt(0, 100) < randomChance
end

function Behavior:_getOrBuildReachableStations()
	if self.reachableStationsCache == nil then
		self.reachableStationsCache = self:_buildReachableStations()
	end
	return self.reachableStationsCache
end

-- Trade-weighted station entries { tile, cluster (nil = isolated), weight }
-- for own and non-embargoed non-bot neighbor structures.
function Behavior:_buildReachableStations()
	local game = self.game
	local player = self.player

	-- unit -> cluster lookup; false stands in for a null cluster.
	local stationManager = game:railNetwork():stationManager()
	local unitToCluster = {}
	local stations = stationManager:getAll() -- upstream Set<TrainStation>
	if stations.toArray ~= nil then
		stations = stations:toArray()
	end
	for _, station in stations do
		local cluster = station:getCluster()
		unitToCluster[station.unit] = if cluster == nil then false else cluster
	end

	local maxTradeGold = math.max(game:config():trainGold("ally", 0, player), 1)
	local result = {}

	-- Own structures — weighted by "self" trade gold.
	local selfWeight = game:config():trainGold("self", 0, player) / maxTradeGold
	for _, unit in player:units(UnitType.City, UnitType.Port, UnitType.Factory) do
		local cluster = unitToCluster[unit]
		if cluster ~= nil then
			table.insert(result, { tile = unit:tile(), cluster = cluster or nil, weight = selfWeight })
		end
	end

	-- Neighbor structures — all non-embargoed non-bot neighbors.
	for _, neighbor in player:nearby() do
		if not neighbor:isPlayer() then
			continue
		end
		if neighbor:type() == PlayerType.Bot then
			continue
		end
		if not player:canTrade(neighbor) then
			continue
		end
		local relType = if player:isOnSameTeam(neighbor)
			then "team"
			elseif player:isAlliedWith(neighbor) then "ally"
			else "other"
		local weight = game:config():trainGold(relType, 0, player) / maxTradeGold
		for _, unit in neighbor:units(UnitType.City, UnitType.Port, UnitType.Factory) do
			local cluster = unitToCluster[unit]
			if cluster ~= nil then
				table.insert(result, { tile = unit:tile(), cluster = cluster or nil, weight = weight })
			end
		end
	end

	return result
end

-- Summed cluster-deduplicated connectivity weight for a candidate tile.
-- Per cluster the max weight in range counts; isolated stations add their own.
function Behavior:_computeConnectivityScore(tile: number, reachableStations, minRangeSquared: number, stationRangeSquared: number): number
	-- JS Map insertion order: the summation order below affects float results.
	local clusterOrder = {}
	local clusterWeight = {}
	local isolatedWeight = 0
	for _, entry in reachableStations do
		local dist = self.game:euclideanDistSquared(tile, entry.tile)
		if dist < minRangeSquared or dist > stationRangeSquared then
			continue
		end
		local cluster = entry.cluster
		if cluster ~= nil then
			local prev = clusterWeight[cluster]
			if prev == nil then
				table.insert(clusterOrder, cluster)
				prev = 0
			end
			clusterWeight[cluster] = math.max(prev, entry.weight)
		else
			isolatedWeight += entry.weight
		end
	end
	local score = isolatedWeight
	for _, cluster in clusterOrder do
		score += clusterWeight[cluster]
	end
	return score
end

-- Interior placement criteria plus (difficulty-gated) rail connectivity.
function Behavior:_cityValue(): (number) -> number
	local game = self.game
	local player = self.player
	local borderTiles = player:borderTiles()
	local otherUnits = player:units(UnitType.City)
	local borderSpacing, structureSpacing = self:_spacingConstants()
	local stationRange = game:config():trainStationMaxRange()
	local stationRangeSquared = stationRange * stationRange
	local difficulty = game:config():gameConfig().difficulty
	local useConnectionScore = self:_shouldUseConnectivityScore(difficulty)

	local reachableStations = if useConnectionScore then self:_getOrBuildReachableStations() else {}
	local minRange = game:config():trainStationMinRange()
	local minRangeSquared = minRange * minRange

	-- Cross-type spacing: prefer to be away from factories.
	local factoryTiles = {}
	for _, u in player:units(UnitType.Factory) do
		table.insert(factoryTiles, u:tile())
	end

	return function(tile: number): number
		local w = 0

		w += game:magnitude(tile)

		local closestBorderDist = nearestTileDistCapped(game, borderTiles, tile, borderSpacing)
		w += math.min(closestBorderDist, borderSpacing)

		local d = nearestUnitDistExcluding(game, otherUnits, tile)
		if d ~= math.huge then
			w += math.min(d, structureSpacing)
		end

		local d2 = nearestTileDist(game, factoryTiles, tile)
		if d2 ~= math.huge then
			w += math.min(d2, structureSpacing)
		end

		if not useConnectionScore then
			return w
		end

		w += self:_computeConnectivityScore(tile, reachableStations, minRangeSquared, stationRangeSquared)
			* structureSpacing

		return w
	end
end

-- Prefers elevation, distance from border, spacing, and proximity to
-- protectable structures. Harder difficulties weight by level and existing coverage.
function Behavior:_samLauncherValue(): (number) -> number
	local game = self.game
	local player = self.player
	local borderTiles = player:borderTiles()
	local otherUnits = player:units(UnitType.SAMLauncher)
	local borderSpacing, structureSpacing = self:_spacingConstants()

	local difficulty = game:config():gameConfig().difficulty
	local weightByLevel = difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible

	local protectEntries = {}
	for _, unit in player:units() do
		local t = unit:type()
		if t == UnitType.City or t == UnitType.Factory or t == UnitType.MissileSilo or t == UnitType.Port then
			table.insert(protectEntries, {
				tile = unit:tile(),
				weight = if weightByLevel then unit:level() else 1,
			})
		end
	end
	local range = game:config():defaultSamRange()
	local rangeSquared = range * range

	local useCoverageWeighting = difficulty ~= Difficulty.Easy and self.random:nextInt(0, 100) < 25

	-- Pre-compute existing SAM coverage for each protectable structure
	local structureCoverage = nil
	if useCoverageWeighting then
		structureCoverage = {}
		local existingSams = player:units(UnitType.SAMLauncher)
		for _, entry in protectEntries do
			local coverageScore = 0
			for _, sam in existingSams do
				local samRange = game:config():samRange(sam:level())
				local dist = game:euclideanDistSquared(entry.tile, sam:tile())
				if dist <= samRange * samRange then
					coverageScore += sam:level()
				end
			end
			structureCoverage[entry.tile] = coverageScore
		end
	end

	return function(tile: number): number
		local w = 0

		w += game:magnitude(tile)

		local closestBorderDist = nearestTileDistCapped(game, borderTiles, tile, borderSpacing)
		-- math.huge here also means "farther than borderSpacing", which still
		-- earns the clamped term; only an empty border set contributes nothing.
		if borderTiles:size() > 0 then
			w += math.min(closestBorderDist, borderSpacing)
		end

		local d = nearestUnitDistExcluding(game, otherUnits, tile)
		if d ~= math.huge then
			w += math.min(d, structureSpacing)
		end

		-- Prefer to be in range of other structures (skip on easy difficulty)
		if difficulty ~= Difficulty.Easy then
			for _, entry in protectEntries do
				local distanceSquared = game:euclideanDistSquared(tile, entry.tile)
				if distanceSquared > rangeSquared then
					continue
				end
				if useCoverageWeighting and structureCoverage ~= nil then
					local coverage = structureCoverage[entry.tile] or 0
					local coverageWeight = 1 / (1 + coverage)
					w += structureSpacing * entry.weight * coverageWeight
				else
					w += structureSpacing * entry.weight
				end
			end
		end

		return w
	end
end

-- Shared spacing constants derived from atom bomb range:
-- returns borderSpacing, structureSpacing.
function Behavior:_spacingConstants(): (number, number)
	local borderSpacing = self.game:config():nukeMagnitudes(UnitType.AtomBomb).outer
	return borderSpacing, borderSpacing * 2
end

return M
