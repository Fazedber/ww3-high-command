-- Port of OpenFrontIO src/core/execution/nation/NationMIRVBehavior.ts:
-- when a nation fires a MIRV (counter-MIRV, victory denial, steamroll stop).

local Shared = game:GetService("ReplicatedStorage").Shared
local Util = require(Shared.Util)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local MirvExecution = require(script.Parent.MirvExecution)
local NationEmoji = require(script.Parent.NationEmojiBehavior)

local UnitType = GameTypes.UnitType
local PlayerType = GameTypes.PlayerType
local Difficulty = GameTypes.Difficulty
local AllPlayers = GameTypes.AllPlayers

-- 30 seconds at 10 ticks/second
local MIRV_COOLDOWN_TICKS = 300

local function assertNever(x): any
	error(`Unhandled case: {x}`)
end

local function truthyTile(v): boolean
	return v ~= nil and v ~= false and v ~= 0
end

-- Upstream execution/Util.ts calculateTerritoryCenter.
local function calculateTerritoryCenter(game, target): number?
	local borderTiles = target:borderTiles()
	if borderTiles:size() == 0 then
		return nil
	end
	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	for tile in borderTiles do
		local x = game:x(tile)
		local y = game:y(tile)
		if x < minX then
			minX = x
		end
		if x > maxX then
			maxX = x
		end
		if y < minY then
			minY = y
		end
		if y > maxY then
			maxY = y
		end
	end
	local centerX = math.floor((minX + maxX) / 2)
	local centerY = math.floor((minY + maxY) / 2)
	local centerTile = game:ref(centerX, centerY)
	if game:owner(centerTile) == target then
		return centerTile
	end
	-- Fall back to nearest border tile if center is not owned
	local closestTile = nil
	local closestDistanceSquared = math.huge
	for tile in borderTiles do
		local dx = game:x(tile) - centerX
		local dy = game:y(tile) - centerY
		local distSquared = dx * dx + dy * dy
		if distSquared < closestDistanceSquared then
			closestDistanceSquared = distSquared
			closestTile = tile
		end
	end
	return closestTile
end

local Behavior = {}
Behavior.__index = Behavior

local M = {}

-- Shared by all nations of a game (upstream: a static map) so they don't pile
-- on the same target: game -> player id -> last MIRV tick. Upstream's static
-- also survives into later games in the same process; keyed per game here so
-- restarted matches (and test reruns) start clean.
local recentMirvTargetsByGame = setmetatable({}, { __mode = "k" })

local function recentMirvTargets(game): { [string]: number }
	local t = recentMirvTargetsByGame[game]
	if t == nil then
		t = {}
		recentMirvTargetsByGame[game] = t
	end
	return t
end

function M.new(random, game, player, emojiBehavior)
	return setmetatable({ random = random, game = game, player = player, emojiBehavior = emojiBehavior }, Behavior)
end

function Behavior:_hesitationOdds(): number
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return 2
	elseif difficulty == Difficulty.Medium then
		return 4
	elseif difficulty == Difficulty.Hard then
		return 8
	elseif difficulty == Difficulty.Impossible then
		return 16
	end
	return assertNever(difficulty)
end

-- Whole percent of the land (win bar is 80% in every mode).
function Behavior:_victoryDenialThresholdPercent(): number
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return 75
	elseif difficulty == Difficulty.Medium then
		return 65
	elseif difficulty == Difficulty.Hard then
		return 55
	elseif difficulty == Difficulty.Impossible then
		return 40
	end
	return assertNever(difficulty)
end

function Behavior:_steamrollCityGapMultiplier(): number
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return 2
	elseif difficulty == Difficulty.Medium then
		return 1.5
	elseif difficulty == Difficulty.Hard then
		return 1.25
	elseif difficulty == Difficulty.Impossible then
		return 1.15
	end
	return assertNever(difficulty)
end

function Behavior:_steamrollMinLeaderCities(): number
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return 20
	elseif difficulty == Difficulty.Medium or difficulty == Difficulty.Hard then
		return 10
	elseif difficulty == Difficulty.Impossible then
		return 8
	end
	return assertNever(difficulty)
end

function Behavior:considerMIRV(): boolean
	if self.player == nil then
		error("not initialized")
	end
	if self.game:config():isUnitDisabled(UnitType.MIRV) then
		return false
	end
	if #self.player:units(UnitType.MissileSilo) == 0 then
		return false
	end
	if self.player:gold() < self:_cost(UnitType.MIRV) then
		return false
	end

	if self.random:chance(self:_hesitationOdds()) then
		return false
	end

	local inboundMIRVSender = self:_selectCounterMirvTarget()
	if inboundMIRVSender and not self:_wasRecentlyMirved(inboundMIRVSender) then
		self:_maybeSendMIRV(inboundMIRVSender)
		return true
	end

	local victoryDenialTarget = self:_selectVictoryDenialTarget()
	if victoryDenialTarget and not self:_wasRecentlyMirved(victoryDenialTarget) then
		self:_maybeSendMIRV(victoryDenialTarget)
		return true
	end

	local steamrollStopTarget = self:_selectSteamrollStopTarget()
	if steamrollStopTarget and not self:_wasRecentlyMirved(steamrollStopTarget) then
		self:_maybeSendMIRV(steamrollStopTarget)
		return true
	end

	return false
end

function Behavior:_selectCounterMirvTarget()
	local attackers = {}
	for _, p in self:_getValidMirvTargetPlayers() do
		if self:_isInboundMIRVFrom(p) then
			table.insert(attackers, p)
		end
	end
	if #attackers == 0 then
		return nil
	end
	Util.sort(attackers, function(a, b)
		return b:numTilesOwned() - a:numTilesOwned()
	end)
	return attackers[1]
end

function Behavior:_selectVictoryDenialTarget()
	local totalLand = self.game:numLandTiles()
	if totalLand == 0 then
		return nil
	end
	local scaledThreshold = totalLand * self:_victoryDenialThresholdPercent()
	local bestP, bestSeverity = nil, 0
	for _, p in self:_getValidMirvTargetPlayers() do
		local severity = 0
		local team = p:team()
		if team ~= nil then
			local teamMembers = {}
			for _, x in self.game:players() do
				if x:team() == team and x:isPlayer() then
					table.insert(teamMembers, x)
				end
			end
			local teamTerritory = 0
			for _, x in teamMembers do
				teamTerritory = teamTerritory + x:numTilesOwned()
			end
			if teamTerritory * 100 >= scaledThreshold then
				-- Only the largest team member is the target
				local largestMember = nil
				local largestTiles = -1
				for _, member in teamMembers do
					local tiles = member:numTilesOwned()
					if tiles > largestTiles then
						largestTiles = tiles
						largestMember = member
					end
				end
				if largestMember == p then
					severity = teamTerritory
				else
					severity = 0
				end
			end
		else
			local tiles = p:numTilesOwned()
			if tiles * 100 >= scaledThreshold then
				severity = tiles
			end
		end
		if severity > 0 then
			if bestP == nil or severity > bestSeverity then
				bestP, bestSeverity = p, severity
			end
		end
	end
	return bestP
end

function Behavior:_selectSteamrollStopTarget()
	local validTargets = self:_getValidMirvTargetPlayers()
	if #validTargets == 0 then
		return nil
	end

	local allPlayers = {}
	for _, p in self.game:players() do
		if p:isPlayer() then
			table.insert(allPlayers, { p = p, cityCount = self:_countCities(p) })
		end
	end
	Util.sort(allPlayers, function(a, b)
		return b.cityCount - a.cityCount
	end)

	if #allPlayers < 2 then
		return nil
	end

	local topPlayer = allPlayers[1]
	if topPlayer.cityCount <= self:_steamrollMinLeaderCities() then
		return nil
	end

	local secondHighest = allPlayers[2].cityCount
	local threshold = secondHighest * self:_steamrollCityGapMultiplier()

	if topPlayer.cityCount >= threshold then
		return if table.find(validTargets, topPlayer.p) ~= nil then topPlayer.p else nil
	end
	return nil
end

function Behavior:_wasRecentlyMirved(target): boolean
	local lastTick = recentMirvTargets(self.game)[target:id()]
	if lastTick == nil then
		return false
	end
	return self.game:ticks() - lastTick < MIRV_COOLDOWN_TICKS
end

function Behavior:_recordMirvHit(target)
	recentMirvTargets(self.game)[target:id()] = self.game:ticks()
end

function Behavior:_getValidMirvTargetPlayers(): { any }
	local out = {}
	for _, p in self.game:players() do
		if p ~= self.player and p:isPlayer() and p:type() ~= PlayerType.Bot and not self.player:isOnSameTeam(p) then
			table.insert(out, p)
		end
	end
	return out
end

function Behavior:_isInboundMIRVFrom(attacker): boolean
	for _, mirv in attacker:units(UnitType.MIRV) do
		local dst = mirv:targetTile()
		-- JS `!dst`: tile 0 is falsy upstream too
		if dst == nil or dst == 0 then
			continue
		end
		if not self.game:hasOwner(dst) then
			continue
		end
		if self.game:owner(dst) == self.player then
			return true
		end
	end
	return false
end

function Behavior:_maybeSendMIRV(enemy)
	self.emojiBehavior:maybeSendAttackEmoji(enemy)

	local centerTile = calculateTerritoryCenter(self.game, enemy)
	-- JS truthiness: tile 0 (center or canBuild's spawn tile) is falsy upstream
	if centerTile ~= nil and centerTile ~= 0 and truthyTile(self.player:canBuild(UnitType.MIRV, centerTile)) then
		self.game:addExecution(MirvExecution.new(self.player, centerTile))
		self:_recordMirvHit(enemy)
		self.emojiBehavior:sendEmoji(AllPlayers, NationEmoji.EMOJI_NUKE)
		NationEmoji.respondToMIRV(self.game, self.random, enemy)
	end
end

function Behavior:_countCities(p): number
	return p:unitCount(UnitType.City)
end

function Behavior:_cost(unitType: string): number
	return self.game:unitInfo(unitType).cost(self.game, self.player)
end

return M
