-- Port of OpenFrontIO src/core/execution/nation/NationNukeBehavior.ts:
-- how nations pick nuke targets and tiles, save up for MIRVs, and (on
-- Impossible) overwhelm enemy SAMs with atom bomb salvos.

local Shared = game:GetService("ReplicatedStorage").Shared
local Util = require(Shared.Util)
local GameMap = require(Shared.GameMap)
local Parabola = require(Shared.Parabola)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local ExecUtil = require(script.Parent.ExecUtil)
local NukeExecution = require(script.Parent.NukeExecution)
local NationEmojiBehavior = require(script.Parent.NationEmojiBehavior)
local NationUtils = require(script.Parent.NationUtils)

local UnitType = GameTypes.UnitType
local PlayerType = GameTypes.PlayerType
local Difficulty = GameTypes.Difficulty
local GameMode = GameTypes.GameMode
local Relation = GameTypes.Relation
local Structures = GameTypes.Structures

local function UpgradeStructureExecution()
	return require(script.Parent.StructureExecutions).UpgradeStructureExecution
end

-- Cap on silo levels reachable via maybeDestroyEnemySam's upgrade fallback.
local MAX_NATION_SILO_UPGRADE_LEVEL = 5

-- Level-weighted structure density (sum of structure levels per tile owned)
-- above which the richest impossible nation will pre-emptively nuke a player.
local HIGH_DENSITY_NUKE_THRESHOLD = 1 / 75

-- Minimum sum of structure levels a player needs to qualify as a high-density nuke target.
local MIN_LEVEL_SUM_FOR_HIGH_DENSITY_NUKE = 5

-- Roblox port: at most this many structures are scored as nuke centres.
local MAX_STRUCTURE_CANDIDATES = 40

-- Upstream src/core/Util.ts boundingBoxTiles: the square ring of tiles at
-- Chebyshev distance `radius` around `center`.
local function boundingBoxTiles(gm, center: number, radius: number): { number }
	local tiles = {}
	local centerX = gm:x(center)
	local centerY = gm:y(center)
	local minX = centerX - radius
	local maxX = centerX + radius
	local minY = centerY - radius
	local maxY = centerY + radius
	-- Top and bottom edges (full width)
	for x = minX, maxX do
		if gm:isValidCoord(x, minY) then
			table.insert(tiles, gm:ref(x, minY))
		end
		if gm:isValidCoord(x, maxY) and minY ~= maxY then
			table.insert(tiles, gm:ref(x, maxY))
		end
	end
	-- Left and right edges (exclude corners already added)
	for y = minY + 1, maxY - 1 do
		if gm:isValidCoord(minX, y) then
			table.insert(tiles, gm:ref(minX, y))
		end
		if gm:isValidCoord(maxX, y) and minX ~= maxX then
			table.insert(tiles, gm:ref(maxX, y))
		end
	end
	return tiles
end

local NationNukeBehavior = {}
NationNukeBehavior.__index = NationNukeBehavior

function NationNukeBehavior.new(random, game, player, attackBehavior, emojiBehavior)
	local self = setmetatable({
		random = random,
		game = game,
		player = player,
		attackBehavior = attackBehavior,
		emojiBehavior = emojiBehavior,
		-- { tick, tile, nukeType }
		recentlySentNukes = {},
		atomBombsLaunched = 0,
		hydrogenBombsLaunched = 0,
	}, NationNukeBehavior)
	self.atomBombPerceivedCost = self:_cost(UnitType.AtomBomb)
	self.hydrogenBombPerceivedCost = self:_cost(UnitType.HydrogenBomb)
	-- Make 1/3 of nations "hydro-nations" that only throw hydrogen bombs (to reduce atom bomb spam)
	self.isHydroNation = random:chance(3)
	return self
end

function NationNukeBehavior:maybeSendNuke()
	local silos = self.player:units(UnitType.MissileSilo)
	local config = self.game:config()
	if
		#silos == 0
		or config:isUnitDisabled(UnitType.MissileSilo)
		or (config:isUnitDisabled(UnitType.AtomBomb) and config:isUnitDisabled(UnitType.HydrogenBomb))
	then
		return
	end

	local nukeTarget = self:findBestNukeTarget()
	if nukeTarget == nil then
		return
	end

	if
		nukeTarget:type() == PlayerType.Bot -- Don't nuke tribes (as opposed to nations and humans)
		or self.player:isOnSameTeam(nukeTarget)
		or self.attackBehavior:shouldAttack(nukeTarget) == false
	then
		return
	end

	local hydroCost = self:_getPerceivedNukeCost(UnitType.HydrogenBomb)
	local atomCost = self:_getPerceivedNukeCost(UnitType.AtomBomb)
	local nukeType
	if not config:isUnitDisabled(UnitType.HydrogenBomb) and self.player:gold() >= hydroCost then
		nukeType = UnitType.HydrogenBomb
	elseif
		not config:isUnitDisabled(UnitType.AtomBomb)
		and (not self.isHydroNation or self:_isUnderHeavyAttack())
		and self.player:gold() >= atomCost
	then
		nukeType = UnitType.AtomBomb
	else
		return
	end
	local range = config:nukeMagnitudes(nukeType).outer

	local structures = nukeTarget:units(Structures.types)
	local difficulty = config:gameConfig().difficulty
	-- Use more random tiles on Impossible difficulty to improve chances of finding a perfect SAM outranging spot
	local numRandomTiles = if difficulty == Difficulty.Impossible then 30 else 10
	local allTiles = NationUtils.randTerritoryTileArray(self.random, self.game, nukeTarget, numRandomTiles)
	-- Roblox port: each candidate gets a full blast-area check and score, and a
	-- big late-game nation has hundreds of structures (20 ms per decision, many
	-- decisions per second across nations). Score at most 40 of them, picked
	-- at random, alongside the random tiles.
	local candidates = structures
	if #structures > MAX_STRUCTURE_CANDIDATES then
		candidates = table.clone(structures)
		for i = 1, MAX_STRUCTURE_CANDIDATES do
			local j = self.random:nextInt(i, #candidates + 1)
			candidates[i], candidates[j] = candidates[j], candidates[i]
		end
		for i = #candidates, MAX_STRUCTURE_CANDIDATES + 1, -1 do
			candidates[i] = nil
		end
	end
	for _, u in candidates do
		table.insert(allTiles, u:tile())
	end

	local bestTile = nil
	local bestValue = -1 -- -1 is important, so that we can also nuke land without structures
	self:_removeOldNukeEvents()

	-- new Set(allTiles): first occurrence order.
	local seen = {}
	for _, tile in allTiles do
		if seen[tile] then
			continue
		end
		seen[tile] = true

		local valid = true
		for _, t in boundingBoxTiles(self.game, tile, range) do
			if not self:_isValidNukeTile(t, nukeTarget) then
				valid = false
				break
			end
		end
		if not valid then
			continue
		end
		-- Add radius / 2 in case there is a piece of unwanted territory inside the outer radius that we miss.
		for _, t in boundingBoxTiles(self.game, tile, math.floor(range / 2)) do
			if not self:_isValidNukeTile(t, nukeTarget) then
				valid = false
				break
			end
		end
		if not valid then
			continue
		end
		local spawnTile = self.player:canBuild(nukeType, tile)
		if spawnTile == false then
			continue
		end

		-- In team games, avoid nuking the same position as a teammate
		if
			config:gameConfig().gameMode == GameMode.Team
			and difficulty ~= Difficulty.Easy
			and self:_isTeammateAlreadyNukingThisSpot(tile, nukeType)
		then
			continue
		end

		-- On Hard & Impossible, avoid trajectories that can be intercepted by enemy SAMs
		if
			(difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible)
			and self:_isTrajectoryInterceptableBySam(spawnTile, tile)
		then
			continue
		end

		local value = self:_nukeTileScore(tile, silos, structures, nukeType)
		if value > bestValue then
			bestTile = tile
			bestValue = value
		end
	end
	if bestTile ~= nil and (bestValue > 0 or difficulty ~= Difficulty.Impossible) then
		self:_sendNuke(bestTile, nukeType, nukeTarget)
	elseif difficulty == Difficulty.Impossible then
		self:_maybeDestroyEnemySam(nukeTarget)
	end
end

local function sortByTilesDesc(players)
	return Util.sort(players, function(a, b)
		return b:numTilesOwned() - a:numTilesOwned()
	end)
end

function NationNukeBehavior:findBestNukeTarget()
	local game, player = self.game, self.player
	-- On Hard & Impossible with only 2 players left, target the only other one
	local diff = game:config():gameConfig().difficulty
	if (diff == Difficulty.Hard or diff == Difficulty.Impossible) and #game:players() == 2 then
		for _, p in game:players() do
			if p ~= player then
				return p
			end
		end
	end

	-- Retaliate against incoming attacks (Most important!)
	local incomingAttackPlayer = self.attackBehavior:findIncomingAttackPlayer()
	if incomingAttackPlayer then
		return incomingAttackPlayer
	end

	-- On Impossible, the richest nation hunts very high structure density targets
	-- Restricting to the richest nation prevents every impossible nation
	-- from piling onto the same compact player.
	if diff == Difficulty.Impossible and self:_isRichestNation() and self.random:chance(2) then
		local denseTarget = self:_findHighDensityTarget()
		if denseTarget ~= nil then
			return denseTarget
		end
	end

	-- On impossible difficulty, prioritize nuking the crown if they have more than 50% of the map
	local gc = game:config():gameConfig()
	if gc.difficulty == Difficulty.Impossible and gc.gameMode == GameMode.FFA then
		local numTilesWithoutFallout = game:numLandTiles() - game:numTilesWithFallout()
		if numTilesWithoutFallout > 0 then
			local crown = sortByTilesDesc(game:players())[1]
			if crown and crown ~= player and not player:isFriendly(crown) then
				local crownShare = crown:numTilesOwned() / numTilesWithoutFallout
				if crownShare > 0.5 then
					return crown
				end
			end
		end
	end

	-- Assist allies, check their targets (this is basically the same as in assistAllies, but without sending emojis)
	for _, ally in player:allies() do
		if #ally:targets() == 0 then
			continue
		end
		if player:relation(ally) < Relation.Friendly then
			continue
		end
		for _, target in ally:targets() do
			if target == player then
				continue
			end
			if player:isFriendly(target) then
				continue
			end
			-- Found a valid ally target to nuke
			return target
		end
	end

	-- Find the most hated player
	-- Ignore much weaker players (we don't need nukes to deal with them)
	local myMaxTroops = game:config():maxTroops(player)
	for _, relation in player:allRelationsSorted() do
		if relation.relation ~= Relation.Hostile then
			continue
		end
		local other = relation.player
		if player:isFriendly(other) then
			continue
		end
		local otherMaxTroops = game:config():maxTroops(other)
		if myMaxTroops >= otherMaxTroops * 2 then
			continue
		end
		return other
	end

	-- In FFAs, nuke the crown if they're far enough ahead
	local crownTarget = self:_findFFACrownTarget()
	if crownTarget then
		return crownTarget
	end

	-- In Teams, nuke the strongest team
	local teamTarget = self:_findStrongestTeamTarget()
	if teamTarget then
		return teamTarget
	end

	return nil
end

function NationNukeBehavior:_isRichestNation(): boolean
	local myGold = self.player:gold()
	for _, other in self.game:players() do
		if other == self.player then
			continue
		end
		if other:type() ~= PlayerType.Nation then
			continue
		end
		if other:gold() > myGold then
			return false
		end
	end
	return true
end

function NationNukeBehavior:_findHighDensityTarget()
	local bestTarget = nil
	local bestDensity = HIGH_DENSITY_NUKE_THRESHOLD
	for _, other in self.game:players() do
		if other == self.player then
			continue
		end
		if other:type() == PlayerType.Bot then
			continue
		end
		if self.player:isFriendly(other) then
			continue
		end
		local tilesOwned = other:numTilesOwned()
		if tilesOwned == 0 then
			continue
		end
		local levelSum = 0
		for _, s in other:units(Structures.types) do
			levelSum += s:level()
		end
		-- Skip players with too few structures regardless of density
		if levelSum < MIN_LEVEL_SUM_FOR_HIGH_DENSITY_NUKE then
			continue
		end
		local density = levelSum / tilesOwned
		if density > bestDensity then
			bestDensity = density
			bestTarget = other
		end
	end
	return bestTarget
end

function NationNukeBehavior:_findFFACrownTarget()
	local game, player = self.game, self.player
	local gc = game:config():gameConfig()
	local difficulty = gc.difficulty
	if gc.gameMode ~= GameMode.FFA then
		return nil
	end

	if #game:players() <= 1 then
		return nil
	end

	local sortedByTiles = sortByTilesDesc(game:players())
	local firstPlace = sortedByTiles[1]

	-- If we're the crown on Impossible difficulty, target 2nd place
	if difficulty == Difficulty.Impossible and firstPlace == player and #sortedByTiles >= 2 then
		local secondPlace = sortedByTiles[2]
		if not player:isFriendly(secondPlace) then
			return secondPlace
		end
	end

	-- Don't target ourselves or allies
	if firstPlace == player or player:isFriendly(firstPlace) then
		return nil
	end

	local numTilesWithoutFallout = game:numLandTiles() - game:numTilesWithFallout()
	if numTilesWithoutFallout <= 0 then
		return nil
	end

	local firstPlaceShare = firstPlace:numTilesOwned() / numTilesWithoutFallout
	local myShare = player:numTilesOwned() / numTilesWithoutFallout

	local threshold
	if difficulty == Difficulty.Easy then
		threshold = 0.4 -- 40%
	elseif difficulty == Difficulty.Medium then
		threshold = 0.3 -- 30%
	elseif difficulty == Difficulty.Hard then
		threshold = 0.2 -- 20%
	elseif difficulty == Difficulty.Impossible then
		threshold = 0.1 -- 10%
	else
		error(`unknown difficulty {difficulty}`)
	end

	-- Check if first place has threshold% more tile-percentage of the map than us
	if firstPlaceShare - myShare > threshold then
		return firstPlace
	end

	return nil
end

function NationNukeBehavior:_findStrongestTeamTarget()
	local game, player = self.game, self.player
	if game:config():gameConfig().gameMode ~= GameMode.Team then
		return nil
	end

	if #game:players() <= 1 then
		return nil
	end

	-- JS Maps: insertion-ordered team keys.
	local teamOrder = {}
	local teamTiles = {}
	local teamPlayers = {}

	for _, p in game:players() do
		local team = p:team()
		if team == nil then
			continue
		end
		if teamTiles[team] == nil then
			table.insert(teamOrder, team)
			teamTiles[team] = 0
			teamPlayers[team] = {}
		end
		teamTiles[team] += p:numTilesOwned()
		table.insert(teamPlayers[team], p)
	end

	local sortedTeams = Util.sort(teamOrder, function(a, b)
		return teamTiles[b] - teamTiles[a]
	end)

	if #sortedTeams == 0 then
		return nil
	end

	local strongestTeam = sortedTeams[1]
	if strongestTeam == player:team() then
		if #sortedTeams > 1 then
			strongestTeam = sortedTeams[2]
		else
			return nil
		end
	end

	-- Filter out friendly players
	local validTargets = {}
	for _, p in teamPlayers[strongestTeam] do
		if not player:isFriendly(p) then
			table.insert(validTargets, p)
		end
	end

	if #validTargets == 0 then
		return nil
	end

	if self.random:chance(2) then
		-- Strongest player
		local config = game:config()
		local prev = validTargets[1]
		for i = 2, #validTargets do
			local current = validTargets[i]
			if not (config:maxTroops(prev) > config:maxTroops(current)) then
				prev = current
			end
		end
		return prev
	else
		-- Random player
		return self.random:randElement(validTargets)
	end
end

-- Simulate saving up for a MIRV
function NationNukeBehavior:_getPerceivedNukeCost(unitType: string): number
	local game = self.game
	-- If only 2 players left, use actual cost (no point saving for MIRV)
	if #game:players() == 2 then
		return self:_cost(unitType)
	end

	-- If MIRVs are disabled, return the actual cost
	if game:config():isUnitDisabled(UnitType.MIRV) then
		return self:_cost(unitType)
	end

	-- Save up a limited amount in team games, synced with NationStructureBehavior
	-- Saving up for a MIRV is not relevant
	if game:config():gameConfig().gameMode == GameMode.Team and self.player:gold() > self:_cost(UnitType.HydrogenBomb) then
		return self:_cost(unitType)
	end

	-- Return the actual cost if we already have enough gold to buy both a MIRV and a hydro
	if self.player:gold() > self:_cost(UnitType.MIRV) + self:_cost(UnitType.HydrogenBomb) then
		return self:_cost(unitType)
	end

	-- On Hard & Impossible, ignore perceived cost when under heavy attack
	-- The nation is probably going to get destroyed soon, so go all-in on nukes
	local difficulty = game:config():gameConfig().difficulty
	if (difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible) and self:_isUnderHeavyAttack() then
		return self:_cost(unitType)
	end

	if unitType == UnitType.AtomBomb then
		return self.atomBombPerceivedCost
	else
		return self.hydrogenBombPerceivedCost
	end
end

function NationNukeBehavior:_isUnderHeavyAttack(): boolean
	-- Get the total incoming attack troops
	local totalIncomingTroops = 0
	for _, attack in self.player:incomingAttacks() do
		totalIncomingTroops += attack:troops()
	end
	return totalIncomingTroops >= self.player:troops()
end

function NationNukeBehavior:_removeOldNukeEvents()
	local maxAge = 600 -- 600 ticks = 1 minute
	local tick = self.game:ticks()
	local recent = self.recentlySentNukes
	while #recent > 0 and recent[1][1] + maxAge < tick do
		table.remove(recent, 1)
	end
end

function NationNukeBehavior:_isTeammateAlreadyNukingThisSpot(tile: number, nukeType: string): boolean
	local game = self.game
	-- Get the inner radius for our nuke type
	local ourInnerRadius = game:config():nukeMagnitudes(nukeType).inner

	-- Check if any teammate's nuke blast radius overlaps with ours
	for _, nuke in game:units(UnitType.AtomBomb, UnitType.HydrogenBomb) do
		local nukeOwner = nuke:owner()

		-- Skip our own nukes and non-teammate nukes
		if nukeOwner == self.player or not self.player:isFriendly(nukeOwner) then
			continue
		end

		-- Get the target tile of the teammate's nuke (JS `!targetTile`: tile 0 is skipped too)
		local targetTile = nuke:targetTile()
		if targetTile == nil or targetTile == 0 then
			continue
		end

		local teammateInnerRadius = game:config():nukeMagnitudes(nuke:type()).inner

		-- They overlap if distance between targets < sum of the two radii
		local distSquared = game:euclideanDistSquared(tile, targetTile)
		local sumRadius = ourInnerRadius + teammateInnerRadius
		if distSquared <= sumRadius * sumRadius then
			return true
		end
	end

	return false
end

-- mirroring NukeTrajectoryPreviewLayer.ts logic a bit
-- excludedSamIds: optional set { [unitId] = true }
function NationNukeBehavior:_isTrajectoryInterceptableBySam(spawnTile: number, targetTile: number, excludedSamIds): boolean
	local game = self.game
	local config = game:config()
	local speed = config:nukeSpeed(UnitType.AtomBomb)
	local pathFinder = Parabola.new(game, {
		increment = speed,
		distanceBasedHeight = true, -- Atom/Hydrogen bombs use distance-based height
		directionUp = true, -- AI nukes always go "up" for now
	})

	local trajectory = pathFinder:findPath(spawnTile, targetTile) or {}
	local n = #trajectory
	if n == 0 then
		return false
	end

	local targetRange = config:defaultNukeTargetableRange()
	local targetRangeSquared = targetRange * targetRange

	-- 1-based indices; -1 = unset.
	local untargetableStart = -1
	local untargetableEnd = -1
	for i = 1, n do
		local tile = trajectory[i]
		if untargetableStart == -1 then
			if game:euclideanDistSquared(tile, spawnTile) > targetRangeSquared then
				if game:euclideanDistSquared(tile, targetTile) < targetRangeSquared then
					-- Overlapping spawn & target range – no untargetable segment.
					break
				else
					untargetableStart = i
				end
			end
		elseif game:euclideanDistSquared(tile, targetTile) < targetRangeSquared then
			untargetableEnd = i
			break
		end
	end

	local maxSamRange = config:maxSamRange()
	local i = 1
	while i <= n do
		-- Skip the mid-air untargetable portion
		if untargetableStart ~= -1 and untargetableEnd ~= -1 and i == untargetableStart then
			i = untargetableEnd
			continue
		end

		local tile = trajectory[i]
		for _, sam in game:nearbyUnits(tile, maxSamRange, UnitType.SAMLauncher) do
			local owner = sam.unit:owner()
			if owner == self.player or self.player:isFriendly(owner) then
				continue
			end
			-- Skip SAMs we're intentionally overwhelming
			if excludedSamIds ~= nil and excludedSamIds[sam.unit:id()] then
				continue
			end
			local samRange = config:samRange(sam.unit:level())
			if sam.distSquared <= samRange * samRange then
				return true
			end
		end
		i += 1
	end

	return false
end

function NationNukeBehavior:_isValidNukeTile(t: number, nukeTarget): boolean
	local gc = self.game:config():gameConfig()
	local difficulty = gc.difficulty

	local owner = self.game:owner(t)
	if owner == nukeTarget then
		return true
	end
	-- On Hard & Impossible, allow TerraNullius (hit small islands) and in team games other non-friendly players
	if
		(difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible)
		and (not owner:isPlayer() or (gc.gameMode == GameMode.Team and owner:isPlayer() and not self.player:isFriendly(owner)))
	then
		return true
	end
	-- On Easy & Medium, only allow tiles owned by the target player (=> nuke away from the border) to reduce nuke usage
	return false
end

local STRUCTURE_VALUE = {
	[UnitType.City] = 25000,
	[UnitType.DefensePost] = 5000,
	[UnitType.MissileSilo] = 50000,
	[UnitType.Port] = 15000,
	[UnitType.Factory] = 15000,
}

function NationNukeBehavior:_nukeTileScore(tile: number, silos, targets, nukeType: string): number
	local game = self.game
	local config = game:config()
	local magnitude = config:nukeMagnitudes(nukeType)
	local dist = GameMap.euclDistFN(tile, magnitude.outer, false)
	local tileValue = 0
	for _, unit in targets do
		if dist(game, unit:tile()) then
			local level = unit:level()
			tileValue += (STRUCTURE_VALUE[unit:type()] or 0) * level
		end
	end

	local difficulty = config:gameConfig().difficulty
	-- On Easy, ignore SAMs entirely.
	-- On Medium, apply a simple local SAM penalty.
	-- On Hard & Impossible we rely on trajectory-based interception checks instead. See maybeSendNuke().
	if difficulty == Difficulty.Medium then
		local dist50 = GameMap.euclDistFN(tile, 50, false)
		for _, unit in targets do
			if unit:type() == UnitType.SAMLauncher and dist50(game, unit:tile()) then
				return -1
			end
		end
	end

	-- On Impossible difficulty and a hydrogen bomb, add value for SAMs that can be outranged
	if difficulty == Difficulty.Impossible and nukeType == UnitType.HydrogenBomb then
		local hydroMagnitude = config:nukeMagnitudes(UnitType.HydrogenBomb)
		for _, sam in game:nearbyUnits(tile, hydroMagnitude.outer, UnitType.SAMLauncher) do
			local samLevel = sam.unit:level()
			if samLevel >= 5 then
				continue -- Can't outrange level 5+ SAMs
			end
			local samRange = config:samRange(samLevel)
			local distToSam = math.sqrt(game:euclideanDistSquared(tile, sam.unit:tile()))
			-- Check if we can outrange this SAM
			if distToSam > samRange then
				-- Add significant value for destroying a SAM that we can outrange
				tileValue += 100000 * samLevel
			end
		end
	end

	-- Prefer tiles that are closer to a silo (but preserve structure value)
	local siloTiles = {}
	for _, u in silos do
		table.insert(siloTiles, u:tile())
	end
	local closestSilo = ExecUtil.closestTwoTiles(game, siloTiles, { tile })
	if closestSilo == nil then
		error("Missing result")
	end
	local distanceSquared = game:euclideanDistSquared(tile, closestSilo)
	local distanceToClosestSilo = math.sqrt(distanceSquared)
	local distancePenalty = distanceToClosestSilo * 30
	local baseTileValue = tileValue
	tileValue = math.max(baseTileValue * 0.2, tileValue - distancePenalty) -- Keep at least 20% of structure value

	-- Don't target near recent targets
	local recentPenalty = 0
	for _, entry in self.recentlySentNukes do
		local recentInnerRadius = config:nukeMagnitudes(entry[3]).inner
		local distSquared = game:euclideanDistSquared(tile, entry[2])
		if distSquared <= recentInnerRadius * recentInnerRadius then
			recentPenalty += 1000000
		end
	end
	tileValue -= recentPenalty

	return tileValue
end

function NationNukeBehavior:_sendNuke(tile: number, nukeType: string, targetPlayer, waitTicks: number?)
	local tick = self.game:ticks()
	table.insert(self.recentlySentNukes, { tick, tile, nukeType })
	if nukeType == UnitType.AtomBomb then
		self.atomBombsLaunched += 1
		-- Increase perceived cost by 50% each time to simulate saving up for a MIRV (higher than hydro to make atom bombs less attractive for the lategame)
		self.atomBombPerceivedCost = (self.atomBombPerceivedCost * 150) // 100
	elseif nukeType == UnitType.HydrogenBomb then
		self.hydrogenBombsLaunched += 1
		-- Increase perceived cost by 25% each time to simulate saving up for a MIRV
		self.hydrogenBombPerceivedCost = (self.hydrogenBombPerceivedCost * 125) // 100
	end
	self.game:addExecution(NukeExecution.new(nukeType, self.player, tile, nil, -1, waitTicks or 0))
	self.emojiBehavior:maybeSendEmoji(targetPlayer, NationEmojiBehavior.EMOJI_NUKE)
end

-- On Impossible difficulty, when no good nuke target is available (score <= 0),
-- attempt to destroy enemy SAMs by overwhelming them with atom bombs.
-- A SAM of level N can intercept N nukes before going on cooldown,
-- so we need N+1 bombs to destroy it (accounting for all covering SAMs).
function NationNukeBehavior:_maybeDestroyEnemySam(nukeTarget)
	local game, player = self.game, self.player
	local config = game:config()
	if config:isUnitDisabled(UnitType.AtomBomb) then
		return
	end

	-- Don't launch another salvo if we already have atom bombs in flight
	if #player:units(UnitType.AtomBomb) > 0 then
		return
	end

	local atomCost = self:_cost(UnitType.AtomBomb)
	local enemySams = nukeTarget:units(UnitType.SAMLauncher)
	if #enemySams == 0 then
		return
	end

	local ourSilos = {}
	for _, silo in player:units(UnitType.MissileSilo) do
		if not silo:isUnderConstruction() then
			table.insert(ourSilos, silo)
		end
	end
	if #ourSilos == 0 then
		return
	end

	-- Try each enemy SAM as a target, easiest (lowest level) first
	local sortedSams = Util.sort(table.clone(enemySams), function(a, b)
		return a:level() - b:level()
	end)
	local needsMoreSilos = false
	-- Track the first failed attempt so we can upgrade a silo that would
	-- actually have helped that plan (rather than an unrelated silo).
	-- { targetTile, coveringSamIds, totalBombs }
	local failedTarget = nil

	for _, targetSam in sortedSams do
		local targetTile = targetSam:tile()

		-- Find all enemy SAMs whose range covers the target tile (they will all try to intercept)
		local coveringSams = self:_findEnemySamsCoveringTile(targetTile)
		local coveringSamIds = {}
		for _, s in coveringSams do
			coveringSamIds[s:id()] = true
		end

		-- Total interception capacity = sum of covering SAM levels
		local totalInterceptions = 0
		for _, sam in coveringSams do
			totalInterceptions += sam:level()
		end
		local bombsNeeded = totalInterceptions + 1

		-- NukeExecution always picks the closest non-cooldown silo by Manhattan
		-- distance to target (via nukeSpawn). Our planning must mirror that order.
		-- Silos with interceptable trajectories will still be picked first by
		-- NukeExecution — their bombs launch but get intercepted, "wasting" slots.
		local nukeSpeed = config:nukeSpeed(UnitType.AtomBomb)
		local allAvailableSilos = {}
		for _, silo in ourSilos do
			local availableSlots = silo:level() - #silo:missileTimerQueue()
			if availableSlots <= 0 then
				continue
			end
			local interceptable = self:_isTrajectoryInterceptableBySam(silo:tile(), targetTile, coveringSamIds)
			-- Compute actual parabolic flight time in ticks
			local pathFinder = Parabola.new(game, {
				increment = nukeSpeed,
				distanceBasedHeight = true,
				directionUp = true,
			})
			local trajectory = pathFinder:findPath(silo:tile(), targetTile) or {}
			if #trajectory == 0 then
				continue
			end
			table.insert(allAvailableSilos, {
				silo = silo,
				slots = availableSlots,
				flightTicks = #trajectory,
				interceptable = interceptable,
			})
		end

		-- Sort by Manhattan distance to target (matching nukeSpawn's pick order)
		Util.sort(allAvailableSilos, function(a, b)
			return game:manhattanDist(a.silo:tile(), targetTile) - game:manhattanDist(b.silo:tile(), targetTile)
		end)

		-- Flatten into a per-bomb launch sequence matching NukeExecution's order.
		-- Each silo contributes `slots` consecutive bombs before NukeExecution
		-- moves to the next silo.
		local launchSequence = {}
		for _, entry in allAvailableSilos do
			for _ = 1, entry.slots do
				table.insert(launchSequence, { flightTicks = entry.flightTicks, interceptable = entry.interceptable })
			end
		end

		-- Use half the SAM cooldown as the max total arrival spread to be safe.
		local samCooldown = config:SAMCooldown()
		local maxTotalArrivalSpread = math.floor(samCooldown / 2)

		-- Add extra bombs: 1 for every 5 to account for enemy building more SAMs
		-- while our bombs are in flight
		local extraBombs = math.floor(bombsNeeded / 5)
		local totalBombs = bombsNeeded + extraBombs

		-- Collect bombs from silos whose trajectory to the target is NOT blocked
		-- by enemy SAMs other than the covering SAMs we're trying to overwhelm.
		-- index is 1-based into launchSequence.
		local unblockedBombs = {}
		for i, bomb in launchSequence do
			if not bomb.interceptable then
				table.insert(unblockedBombs, { index = i, flightTicks = bomb.flightTicks })
			end
		end

		if #unblockedBombs < totalBombs then
			if failedTarget == nil then
				failedTarget = { targetTile = targetTile, coveringSamIds = coveringSamIds, totalBombs = totalBombs }
			end
			needsMoreSilos = true
			continue
		end

		-- Sort unblocked bombs by flight time to find a sliding window
		-- of maxTotalArrivalSpread that captures the most bombs.
		local sortedByFlight = Util.sort(table.clone(unblockedBombs), function(a, b)
			return a.flightTicks - b.flightTicks
		end)

		local bestWindowStart = 1
		local bestWindowCount = 0
		for start = 1, #sortedByFlight do
			local e = start
			while e <= #sortedByFlight and sortedByFlight[e].flightTicks - sortedByFlight[start].flightTicks <= maxTotalArrivalSpread do
				e += 1
			end
			if e - start > bestWindowCount then
				bestWindowCount = e - start
				bestWindowStart = start
			end
		end

		if bestWindowCount < totalBombs then
			if failedTarget == nil then
				failedTarget = { targetTile = targetTile, coveringSamIds = coveringSamIds, totalBombs = totalBombs }
			end
			needsMoreSilos = true
			continue
		end

		-- From the window, pick totalBombs with the lowest launch-sequence
		-- indices to minimise how many bombs we need to fire (minimise gold cost).
		local windowByIndex = table.move(sortedByFlight, bestWindowStart, bestWindowStart + bestWindowCount - 1, 1, {})
		Util.sort(windowByIndex, function(a, b)
			return a.index - b.index
		end)
		local selected = table.move(windowByIndex, 1, totalBombs, 1, {})
		local selectedSet = {}
		for _, b in selected do
			selectedSet[b.index] = true
		end
		local bombsToFire = selected[#selected].index

		-- Compute per-bomb waitTicks so all selected bombs arrive in the window.
		-- Target: spread arrivals evenly, anchored at the earliest flight time
		-- in the selected set.
		local selectedFlightMin = math.huge
		for _, b in selected do
			selectedFlightMin = math.min(selectedFlightMin, b.flightTicks)
		end
		local staggerInterval = math.max(1, math.floor(maxTotalArrivalSpread / totalBombs))
		local selectedIdx = 0
		local waitTicksPerBomb = {}
		for i = 1, bombsToFire do
			if selectedSet[i] then
				local targetArrival = selectedFlightMin + selectedIdx * staggerInterval
				table.insert(waitTicksPerBomb, math.max(0, targetArrival - launchSequence[i].flightTicks))
				selectedIdx += 1
			else
				-- Wasted bomb (interceptable or out-of-window) — launch immediately
				table.insert(waitTicksPerBomb, 0)
			end
		end

		-- Check gold for all fired bombs (including wasted ones)
		local totalCost = atomCost * bombsToFire
		if player:gold() < totalCost then
			continue
		end

		-- Fire the salvo — NukeExecution will pick silos in the same
		-- Manhattan distance order we planned.
		for i = 1, bombsToFire do
			self:_sendNuke(targetTile, UnitType.AtomBomb, nukeTarget, waitTicksPerBomb[i])
		end
		return
	end

	-- Couldn't destroy any SAM — upgrade silos only if capacity was the bottleneck.
	-- If we only lack gold, don't waste it upgrading silos — just wait and save.
	if needsMoreSilos and failedTarget ~= nil then
		self:_maybeUpgradeHelpfulSilo(failedTarget)
	end
end

-- Find all enemy SAMs whose range covers a given tile.
function NationNukeBehavior:_findEnemySamsCoveringTile(tile: number)
	local config = self.game:config()
	local result = {}
	for _, sam in self.game:nearbyUnits(tile, config:maxSamRange(), UnitType.SAMLauncher) do
		local owner = sam.unit:owner()
		if owner == self.player or self.player:isFriendly(owner) then
			continue
		end
		local range = config:samRange(sam.unit:level())
		if sam.distSquared <= range * range then
			table.insert(result, sam.unit)
		end
	end
	return result
end

-- Upgrade a missile silo that would actually have helped the failed
-- overwhelm attempt: trajectory to the failed target is not blocked by
-- non-covering enemy SAMs, and the silo is below the upgrade cap. Among
-- those, picks the one best protected by our own SAMs.
function NationNukeBehavior:_maybeUpgradeHelpfulSilo(failedTarget)
	local game, player = self.game, self.player
	local silos = player:units(UnitType.MissileSilo)
	if #silos == 0 then
		return
	end

	-- First pass: find silos with an unblocked trajectory to the failed
	-- target. Only these contribute slots to the overwhelm plan.
	-- "Unblocked" means not interceptable by non-covering enemy SAMs.
	local unblockedSilos = {}
	for _, silo in silos do
		if not self:_isTrajectoryInterceptableBySam(silo:tile(), failedTarget.targetTile, failedTarget.coveringSamIds) then
			table.insert(unblockedSilos, silo)
		end
	end
	if #unblockedSilos == 0 then
		return
	end

	-- Bail out if the target is unreachable even at max silo level —
	-- crazy amounts of covering SAMs, upgrading is wasted gold.
	local maxAchievableSlots = #unblockedSilos * MAX_NATION_SILO_UPGRADE_LEVEL
	if maxAchievableSlots < failedTarget.totalBombs then
		return
	end

	local config = game:config()
	local ourSams = player:units(UnitType.SAMLauncher)
	local bestSilo = nil
	local bestProtection = -1

	for _, silo in unblockedSilos do
		if silo:level() >= MAX_NATION_SILO_UPGRADE_LEVEL then
			continue
		end
		if not player:canUpgradeUnit(silo) then
			continue
		end

		local protection = 0
		for _, sam in ourSams do
			local range = config:samRange(sam:level())
			local distSquared = game:euclideanDistSquared(silo:tile(), sam:tile())
			if distSquared <= range * range then
				protection += sam:level()
			end
		end

		if protection > bestProtection then
			bestProtection = protection
			bestSilo = silo
		end
	end

	if bestSilo ~= nil then
		game:addExecution(UpgradeStructureExecution().new(player, bestSilo:id()))
	end
end

function NationNukeBehavior:_cost(unitType: string): number
	return self.game:unitInfo(unitType).cost(self.game, self.player)
end

return NationNukeBehavior
