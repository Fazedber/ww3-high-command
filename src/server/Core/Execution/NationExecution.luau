-- Port of OpenFrontIO src/core/execution/NationExecution.ts: the AI that
-- drives one nation (spawning, attacks, structures, alliances, nukes...).

local Shared = game:GetService("ReplicatedStorage").Shared
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local GameMap = require(Shared.GameMap)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local SpawnExecution = require(script.Parent.SpawnExecution)
local AiAttackBehavior = require(script.Parent.AiAttackBehavior)
local NationEmojiBehavior = require(script.Parent.NationEmojiBehavior)
local NationAllianceBehavior = require(script.Parent.NationAllianceBehavior)
local NationMIRVBehavior = require(script.Parent.NationMIRVBehavior)
local NationNukeBehavior = require(script.Parent.NationNukeBehavior)
local NationStructureBehavior = require(script.Parent.NationStructureBehavior)
local NationWarshipBehavior = require(script.Parent.NationWarshipBehavior)

local Difficulty = GameTypes.Difficulty
local GameMode = GameTypes.GameMode
local PlayerType = GameTypes.PlayerType
local Relation = GameTypes.Relation
local UnitType = GameTypes.UnitType
local TerrainType = GameMap.TerrainType

local NationExecution = {}
NationExecution.__index = NationExecution

function NationExecution.new(gameID: string, nation)
	local random = PseudoRandom.new(Util.simpleHash(nation.playerInfo.id) + Util.simpleHash(gameID))
	local self = setmetatable({
		active = true,
		gameID = gameID,
		nation = nation,
		random = random,
		behaviorsInitialized = false,
		spawnExecAdded = false,
		player = nil,
		embargoMalusApplied = {},
	}, NationExecution)
	-- Draw order matters: identical to the upstream constructor.
	self.triggerRatio = random:nextInt(50, 60) / 100
	self.reserveRatio = random:nextInt(30, 40) / 100
	self.expandRatio = random:nextInt(10, 20) / 100
	return self
end

function NationExecution:init(mg)
	self.mg = mg
	self.attackRate = self:_getAttackRate()
	self.attackTick = self.random:nextInt(0, self.attackRate)
	local info = self.nation.playerInfo
	if not mg:hasPlayer(info.id) then
		self.player = mg:addPlayer(info)
	else
		self.player = mg:player(info.id)
	end
end

function NationExecution:_getAttackRate(): number
	local difficulty = self.mg:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return self.random:nextInt(65, 100) -- Slower reactions
	elseif difficulty == Difficulty.Medium then
		return self.random:nextInt(55, 70)
	elseif difficulty == Difficulty.Hard then
		return self.random:nextInt(45, 60)
	elseif difficulty == Difficulty.Impossible then
		return self.random:nextInt(30, 50) -- Faster reactions
	end
	error(`unknown difficulty {difficulty}`)
end

local AI_TURN_BUDGET = 0.02
local aiBudget = { tick = -1, spent = 0 }

function NationExecution:tick(ticks: number)
	local mg, player = self.mg, self.player
	-- Ship tracking
	if
		self.behaviorsInitialized
		and player ~= nil
		and player:isAlive()
		and mg:config():gameConfig().difficulty ~= Difficulty.Easy
		and player:unitsConstructed(UnitType.Port) > 0
		and not mg:config():isUnitDisabled(UnitType.Warship)
	then
		self.warshipBehavior:trackShipsAndRetaliate()
	end

	if player == nil then
		return
	end

	if mg:inSpawnPhase() then
		if player:hasSpawned() then
			-- Already on the map: periodically re-spawn so the nation visibly
			-- hops to different locations during the spawn phase.
			if ticks % self.attackRate ~= self.attackTick then
				return
			end
		elseif self.spawnExecAdded then
			-- First SpawnExecution already queued, wait for it to land.
			return
		end
		local info = self.nation.playerInfo
		-- Nations without a spawn cell (created for HumansVsNations) spawn randomly.
		local cell = self.nation.spawnCell
		if cell == nil then
			mg:addExecution(SpawnExecution.new(self.gameID, info))
			self.spawnExecAdded = true
			return
		end

		-- Spawn cell outside the team's spawn area: spawn randomly within it.
		local team = player:team()
		if team ~= nil then
			local area = mg:teamSpawnArea(team)
			if area ~= nil then
				local inArea = cell.x >= area.x and cell.x < area.x + area.width and cell.y >= area.y and cell.y < area.y + area.height
				if not inArea then
					mg:addExecution(SpawnExecution.new(self.gameID, info))
					self.spawnExecAdded = true
					return
				end
			end
		end

		-- Select a tile near the position defined in the map manifest
		local rl = self:_randomSpawnLand()
		if rl == nil then
			warn(`cannot spawn {info.name}`)
			return
		end
		mg:addExecution(SpawnExecution.new(self.gameID, info, rl))
		self.spawnExecAdded = true
		return
	end

	-- Spawn phase already ended but our SpawnExecution hasn't fired yet.
	if self.spawnExecAdded and not player:hasSpawned() then
		return
	end

	if not player:isAlive() then
		-- removeOnDeath is called from the nation's PlayerExecution
		self.active = false
		return
	end

	if not self.behaviorsInitialized then
		self:_initializeBehaviors()
		self.attackBehavior:forceSendAttack(mg:terraNullius())
		return
	end

	-- Roblox port: a nation's main turn (below) can take 10-20 ms late in a
	-- match (nuke targeting, border scans), and several landing on one tick
	-- stalled the server. Turns share a 20 ms budget per tick; a turn that
	-- does not fit waits for the next tick instead of being skipped.
	if ticks % self.attackRate == self.attackTick then
		self._turnDue = true
	end
	if self._turnDue then
		if aiBudget.tick ~= ticks then
			aiBudget.tick, aiBudget.spent = ticks, 0
		end
		if aiBudget.spent < AI_TURN_BUDGET then
			self._turnDue = false
			local t0 = os.clock()
			self:_mainTurn()
			aiBudget.spent += os.clock() - t0
		end
		return
	end
	do
		-- handleStructures also runs at 1/3 and 2/3 of the interval, otherwise
		-- nations can earn more gold than they spend.
		if player:isAlive() then
			local offset = ticks % self.attackRate
			local oneThird = (self.attackTick + math.floor(self.attackRate / 3)) % self.attackRate
			local twoThirds = (self.attackTick + math.floor((self.attackRate * 2) / 3)) % self.attackRate
			if offset == oneThird or offset == twoThirds then
				self.structureBehavior:handleStructures()
			end
		end
		return
	end
end

function NationExecution:_mainTurn()
	self.emojiBehavior:maybeSendCasualEmoji()
	self:_updateRelationsFromEmbargos()
	self.allianceBehavior:handleAllianceRequests()
	self.allianceBehavior:handleAllianceExtensionRequests()
	self.mirvBehavior:considerMIRV()
	self.structureBehavior:handleStructures()
	self.warshipBehavior:maybeSpawnWarship()
	self:_handleEmbargoesToHostileNations()
	self.attackBehavior:maybeAttack()
	self.warshipBehavior:counterWarshipInfestation()
	self.nukeBehavior:maybeSendNuke()
end

function NationExecution:_initializeBehaviors()
	local random, mg, player = self.random, self.mg, self.player
	self.emojiBehavior = NationEmojiBehavior.new(random, mg, player)
	self.mirvBehavior = NationMIRVBehavior.new(random, mg, player, self.emojiBehavior)
	self.allianceBehavior = NationAllianceBehavior.new(random, mg, player, self.emojiBehavior)
	self.warshipBehavior = NationWarshipBehavior.new(random, mg, player, self.emojiBehavior)
	self.attackBehavior = AiAttackBehavior.new(
		random,
		mg,
		player,
		self.triggerRatio,
		self.reserveRatio,
		self.expandRatio,
		self.allianceBehavior,
		self.emojiBehavior
	)
	self.nukeBehavior = NationNukeBehavior.new(random, mg, player, self.attackBehavior, self.emojiBehavior)
	self.structureBehavior = NationStructureBehavior.new(random, mg, player)
	self.behaviorsInitialized = true
end

function NationExecution:_randomSpawnLand(): number?
	local mg, cell = self.mg, self.nation.spawnCell
	local delta = 25
	for _ = 1, 50 do
		local x = self.random:nextInt(cell.x - delta, cell.x + delta)
		local y = self.random:nextInt(cell.y - delta, cell.y + delta)
		if not mg:isValidCoord(x, y) then
			continue
		end
		local tile = mg:ref(x, y)
		if mg:isLand(tile) and not mg:hasOwner(tile) and not mg:isImpassable(tile) then
			if mg:terrainType(tile) == TerrainType.Mountain and self.random:chance(2) then
				continue
			end
			return tile
		end
	end
	return nil
end

function NationExecution:_updateRelationsFromEmbargos()
	local player = self.player
	local embargoMalus = -20
	for _, other in self.mg:players() do
		if other:id() == player:id() then
			continue
		end
		local applied = self.embargoMalusApplied[other:id()] == true
		if other:hasEmbargoAgainst(player) and not applied then
			player:updateRelation(other, embargoMalus)
			self.embargoMalusApplied[other:id()] = true
		elseif not other:hasEmbargoAgainst(player) and applied then
			player:updateRelation(other, -embargoMalus)
			self.embargoMalusApplied[other:id()] = nil
		end
	end
end

function NationExecution:_handleEmbargoesToHostileNations()
	local player = self.player
	local difficulty = self.mg:config():gameConfig().difficulty
	local isHigherDifficulty = difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible
	local teamGame = self.mg:config():gameConfig().gameMode == GameMode.Team

	for _, other in self.mg:players() do
		if other:id() == player:id() then
			continue
		end
		-- In team games on higher difficulties, refuse to trade with anyone
		-- not on this nation's team.
		if teamGame and isHigherDifficulty and other:type() ~= PlayerType.Bot and not player:isOnSameTeam(other) then
			if not player:hasEmbargoAgainst(other) then
				player:addEmbargo(other, false)
			end
			continue
		end

		-- Hostile starts an embargo; it lasts until neutral again.
		local relation = player:relation(other)
		if relation <= Relation.Hostile and not player:hasEmbargoAgainst(other) and not player:isOnSameTeam(other) then
			player:addEmbargo(other, false)
		elseif relation >= Relation.Neutral and player:hasEmbargoAgainst(other) and difficulty ~= Difficulty.Hard and difficulty ~= Difficulty.Impossible then
			player:stopEmbargo(other)
		elseif relation >= Relation.Friendly and player:hasEmbargoAgainst(other) and difficulty ~= Difficulty.Impossible then
			player:stopEmbargo(other)
		end
	end
end

function NationExecution:isActive(): boolean
	return self.active
end

function NationExecution:activeDuringSpawnPhase(): boolean
	return true
end

return NationExecution
