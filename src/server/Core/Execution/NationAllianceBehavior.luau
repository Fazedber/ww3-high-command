-- Port of OpenFrontIO src/core/execution/nation/NationAllianceBehavior.ts:
-- how nations answer/extend/send alliance requests and when they betray.

local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local SocialExecutions = require(script.Parent.SocialExecutions)
local NationEmoji = require(script.Parent.NationEmojiBehavior)
local NationUtils = require(script.Parent.NationUtils)

local PlayerType = GameTypes.PlayerType
local Relation = GameTypes.Relation
local Difficulty = GameTypes.Difficulty
local GameMode = GameTypes.GameMode

local AllianceRequestExecution = SocialExecutions.AllianceRequestExecution
local AllianceExtensionExecution = SocialExecutions.AllianceExtensionExecution

local function assertNever(x): any
	error(`Unhandled case: {x}`)
end

local function sumAttackTroops(p): number
	local sum = 0
	for _, attack in p:outgoingAttacks() do
		sum = sum + attack:troops()
	end
	return sum
end

local TROOP_PERCENT_RANGE = {
	[Difficulty.Easy] = { 60, 70 },
	[Difficulty.Medium] = { 70, 80 },
	[Difficulty.Hard] = { 75, 85 },
	[Difficulty.Impossible] = { 80, 90 },
}
local TILE_PERCENT_RANGE = {
	[Difficulty.Easy] = { 70, 80 },
	[Difficulty.Medium] = { 80, 90 },
	[Difficulty.Hard] = { 85, 95 },
	[Difficulty.Impossible] = { 90, 100 },
}

local Behavior = {}
Behavior.__index = Behavior

local M = {}

function M.new(random, game, player, emojiBehavior)
	return setmetatable({ random = random, game = game, player = player, emojiBehavior = emojiBehavior }, Behavior)
end

function Behavior:handleAllianceRequests()
	if self.game:config():disableAlliances() then
		return
	end
	for _, req in self.player:incomingAllianceRequests() do
		-- Requests created during the spawn phase are executed on the first
		-- tick post-spawn phase; reject those.
		if req:createdAt() <= self.game:config():numSpawnPhaseTurns() + 1 then
			req:reject()
			continue
		end
		if self:_getAllianceDecision(req:requestor(), true) then
			req:accept()
		else
			req:reject()
		end
	end
end

function Behavior:handleAllianceExtensionRequests()
	if self.game:config():disableAlliances() then
		return
	end
	for _, alliance in self.player:alliances() do
		if not alliance:onlyOneAgreedToExtend() then
			continue
		end
		local human = alliance:other(self.player)
		if not self:_getAllianceDecision(human, true) then
			continue
		end
		self.game:addExecution(AllianceExtensionExecution.new(self.player, human:id()))
	end
end

function Behavior:maybeSendAllianceRequests(borderingEnemies: { any })
	if self.game:config():disableAlliances() then
		return
	end
	-- Only easy nations are allowed to send alliance requests to bots
	local function isAcceptablePlayerType(p): boolean
		return (p:type() == PlayerType.Bot and self.game:config():gameConfig().difficulty == Difficulty.Easy) or p:type() ~= PlayerType.Bot
	end
	for _, enemy in borderingEnemies do
		if
			self.random:chance(30)
			and isAcceptablePlayerType(enemy)
			and self.player:canSendAllianceRequest(enemy)
			and self:_getAllianceDecision(enemy, false)
		then
			self.game:addExecution(AllianceRequestExecution.new(self.player, enemy:id()))
		end
	end
end

function Behavior:_getAllianceDecision(otherPlayer, isResponse: boolean): boolean
	if self:_isConfused() then
		return self.random:chance(2)
	end
	-- Nearly always reject traitors
	if otherPlayer:isTraitor() and self.random:nextInt(0, 100) >= 10 then
		if isResponse and self.random:chance(3) then
			self.emojiBehavior:sendEmoji(otherPlayer, NationEmoji.EMOJI_CONFUSED)
		end
		return false
	end
	if self:_hasTooManyAlliances(otherPlayer) then
		return false
	end
	if self:_isAlliancePartnerThreat(otherPlayer) then
		if not isResponse and self.random:chance(6) then
			self.emojiBehavior:sendEmoji(otherPlayer, NationEmoji.EMOJI_SCARED_OF_THREAT)
		end
		if isResponse and self.random:chance(6) then
			self.emojiBehavior:sendEmoji(otherPlayer, NationEmoji.EMOJI_LOVE)
		end
		return true
	end
	if self:_shouldRejectInTeamGame() then
		return false
	end
	if self.player:relation(otherPlayer) < Relation.Neutral then
		if isResponse and self.random:chance(3) then
			self.emojiBehavior:sendEmoji(otherPlayer, NationEmoji.EMOJI_CONFUSED)
		end
		return false
	end
	if self:_isAlliancePartnerFriendly(otherPlayer) then
		if self.random:chance(3) then
			self.emojiBehavior:sendEmoji(otherPlayer, NationEmoji.EMOJI_HANDSHAKE)
		end
		return true
	end
	if self:_checkAlreadyEnoughAlliances(otherPlayer) then
		return false
	end
	if self:_isEarlygame() then
		return true
	end
	return self:_isAlliancePartnerSimilarlyStrong(otherPlayer)
end

function Behavior:_hasTooManyAlliances(otherPlayer): boolean
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty ~= Difficulty.Hard and difficulty ~= Difficulty.Impossible then
		return false
	end
	local totalPlayers = 0
	for _, p in self.game:players() do
		if p:type() ~= PlayerType.Bot then
			totalPlayers += 1
		end
	end
	local otherPlayerAlliances = #otherPlayer:alliances()
	if difficulty == Difficulty.Hard then
		return otherPlayerAlliances >= totalPlayers * 0.5
	else
		return otherPlayerAlliances >= totalPlayers * 0.25
	end
end

function Behavior:_isConfused(): boolean
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return self.random:chance(10)
	elseif difficulty == Difficulty.Medium then
		return self.random:chance(20)
	elseif difficulty == Difficulty.Hard then
		return self.random:chance(40)
	elseif difficulty == Difficulty.Impossible then
		return false
	end
	return assertNever(difficulty)
end

function Behavior:_isEarlygame(): boolean
	local spawnTicks = self.game:config():numSpawnPhaseTurns()
	local difficulty = self.game:config():gameConfig().difficulty
	local ticks = self.game:ticks()
	if difficulty == Difficulty.Easy then
		return ticks < 3000 + spawnTicks and self.random:nextInt(0, 100) >= 10
	elseif difficulty == Difficulty.Medium then
		return ticks < 1800 + spawnTicks and self.random:nextInt(0, 100) >= 30
	elseif difficulty == Difficulty.Hard then
		return ticks < 1800 + spawnTicks and self.random:nextInt(0, 100) >= 50
	elseif difficulty == Difficulty.Impossible then
		return ticks < 600 + spawnTicks and self.random:nextInt(0, 100) >= 70
	end
	return assertNever(difficulty)
end

function Behavior:_isAlliancePartnerThreat(otherPlayer): boolean
	local config = self.game:config()
	local difficulty = config:gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return false
	elseif difficulty == Difficulty.Medium then
		return otherPlayer:troops() > self.player:troops() * 2.5
	elseif difficulty == Difficulty.Hard then
		return otherPlayer:troops() > self.player:troops() and config:maxTroops(otherPlayer) > config:maxTroops(self.player) * 2
	elseif difficulty == Difficulty.Impossible then
		local otherHasMoreTroops = otherPlayer:troops() > self.player:troops() * 1.5
		local otherHasMoreMaxTroops = otherPlayer:troops() > self.player:troops()
			and config:maxTroops(otherPlayer) > config:maxTroops(self.player) * 1.5
		local otherHasMoreTiles = otherPlayer:troops() > self.player:troops()
			and otherPlayer:numTilesOwned() > self.player:numTilesOwned() * 1.5
		return otherHasMoreTroops or otherHasMoreMaxTroops or otherHasMoreTiles
	end
	return assertNever(difficulty)
end

function Behavior:_shouldRejectInTeamGame(): boolean
	local gameConfig = self.game:config():gameConfig()
	if gameConfig.gameMode ~= GameMode.Team then
		return false
	end
	local difficulty = gameConfig.difficulty
	if difficulty == Difficulty.Easy then
		return self.random:nextInt(0, 100) < 25
	elseif difficulty == Difficulty.Medium then
		return self.random:nextInt(0, 100) < 50
	elseif difficulty == Difficulty.Hard then
		return self.random:nextInt(0, 100) < 75
	elseif difficulty == Difficulty.Impossible then
		return true
	end
	return assertNever(difficulty)
end

function Behavior:_checkAlreadyEnoughAlliances(otherPlayer): boolean
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return false
	elseif difficulty == Difficulty.Medium then
		return #self.player:alliances() >= self.random:nextInt(4, 6)
	elseif difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible then
		-- Try not to ally with all our neighbors (if we have 2+ neighbors)
		local borderingPlayers = {}
		for _, n in self.player:nearby() do
			if n:isPlayer() and n:type() ~= PlayerType.Bot then
				table.insert(borderingPlayers, n)
			end
		end
		local numBorderingFriends = 0
		for _, o in borderingPlayers do
			if self.player:isFriendly(o) == true then
				numBorderingFriends += 1
			end
		end
		if #borderingPlayers >= 2 and table.find(borderingPlayers, otherPlayer) ~= nil then
			return #borderingPlayers <= numBorderingFriends + 1
		end
		if difficulty == Difficulty.Hard then
			return #self.player:alliances() >= self.random:nextInt(3, 5)
		end
		return #self.player:alliances() >= self.random:nextInt(2, 4)
	end
	return assertNever(difficulty)
end

function Behavior:_isAlliancePartnerFriendly(otherPlayer): boolean
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy or difficulty == Difficulty.Medium then
		return self.player:relation(otherPlayer) == Relation.Friendly
	elseif difficulty == Difficulty.Hard then
		return self.player:relation(otherPlayer) == Relation.Friendly and self.random:nextInt(0, 100) >= 17
	elseif difficulty == Difficulty.Impossible then
		return self.player:relation(otherPlayer) == Relation.Friendly and self.random:nextInt(0, 100) >= 33
	end
	return assertNever(difficulty)
end

-- Integer nextInt on purpose (upstream avoids nextFloat for desync reasons).
function Behavior:_isAlliancePartnerSimilarlyStrong(otherPlayer): boolean
	local difficulty = self.game:config():gameConfig().difficulty
	local troopRange = TROOP_PERCENT_RANGE[difficulty]
	local tileRange = TILE_PERCENT_RANGE[difficulty]

	local playerOutgoingTroops = sumAttackTroops(self.player)
	local otherOutgoingTroops = sumAttackTroops(otherPlayer)
	local playerTotalTroops = self.player:troops() + playerOutgoingTroops
	local otherTotalTroops = otherPlayer:troops() + otherOutgoingTroops

	local troopThreshold = playerTotalTroops * (self.random:nextInt(troopRange[1], troopRange[2]) / 100)
	local tileThreshold = self.player:numTilesOwned() * (self.random:nextInt(tileRange[1], tileRange[2]) / 100)

	local hasComparableTroops = otherTotalTroops > troopThreshold
	local hasComparableTiles = otherPlayer:numTilesOwned() > tileThreshold and otherTotalTroops > playerTotalTroops * 0.5
	return hasComparableTroops or hasComparableTiles
end

-- juiciestAlly comes from findJuiciestAlly(borderingFriends); callers looping
-- over borderingFriends should compute it once.
function Behavior:maybeBetray(otherPlayer, juiciestAlly, borderingFriends: { any }, borderingEnemies: { any }): boolean
	if not self.player:isAlliedWith(otherPlayer) then
		return false
	end
	local difficulty = self.game:config():gameConfig().difficulty

	-- Betray our juiciest ally if everybody around us is weak
	if
		(difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible)
		and juiciestAlly == otherPlayer
		and self:_isSafeToBetray(otherPlayer, borderingFriends, borderingEnemies)
	then
		self:_betray(otherPlayer)
		return true
	end

	-- Betray very weak players (easier difficulties; on easy, not humans)
	if
		(difficulty == Difficulty.Easy or difficulty == Difficulty.Medium)
		and not (difficulty == Difficulty.Easy and otherPlayer:type() == PlayerType.Human)
		and self.player:troops() >= otherPlayer:troops() * 10
	then
		self:_betray(otherPlayer)
		return true
	end

	-- Betray traitors who aren't significantly stronger than us
	if difficulty ~= Difficulty.Easy and otherPlayer:isTraitor() and otherPlayer:troops() < self.player:troops() * 1.2 then
		self:_betray(otherPlayer)
		return true
	end

	-- Betray our only bordering player if we are much stronger than them
	if difficulty ~= Difficulty.Easy and #borderingFriends + #borderingEnemies == 1 and otherPlayer:troops() * 3 < self.player:troops() then
		self:_betray(otherPlayer)
		return true
	end

	return false
end

function Behavior:findJuiciestAlly(borderingFriends: { any })
	local candidates = {}
	for _, friend in borderingFriends do
		if self.player:isAlliedWith(friend) then
			table.insert(candidates, friend)
		end
	end
	return NationUtils.findJuiciestTarget(self.game, candidates)
end

-- Safe if target + non-allied neighbors + (unless target is already a traitor)
-- our other allies stay under a third of our troops.
function Behavior:_isSafeToBetray(target, borderingFriends: { any }, borderingEnemies: { any }): boolean
	local threats = { target }
	for _, e in borderingEnemies do
		table.insert(threats, e)
	end
	if not target:isTraitor() then
		for _, f in borderingFriends do
			if f ~= target and self.player:isAlliedWith(f) then
				table.insert(threats, f)
			end
		end
	end
	local nearbyThreatTroops = 0
	for _, threat in threats do
		local outgoing = sumAttackTroops(threat)
		nearbyThreatTroops = nearbyThreatTroops + threat:troops() + outgoing
	end
	return nearbyThreatTroops < self.player:troops() * 0.33
end

function Behavior:_betray(target)
	local alliance = self.player:allianceWith(target)
	if not alliance then
		return
	end
	self.player:breakAlliance(alliance)
end

return M
