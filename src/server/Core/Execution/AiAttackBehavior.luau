-- Port of OpenFrontIO src/core/execution/utils/AiAttackBehavior.ts.

local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local AttackExecution = require(script.Parent.AttackExecution)
local ExecUtil = require(script.Parent.ExecUtil)
local TransportShipExecution = require(script.Parent.TransportShipExecution)
local TransportShipUtils = require(Core.TransportShipUtils)
local NameBoxCalculator = require(Core.NameBoxCalculator)
local NationUtils = require(script.Parent.NationUtils)
local NationEmojiBehavior = require(script.Parent.NationEmojiBehavior)
local Shared = game:GetService("ReplicatedStorage").Shared
local JSSet = require(Shared.JSSet)
local Util = require(Shared.Util)

local PlayerType = GameTypes.PlayerType
local Difficulty = GameTypes.Difficulty
local GameMode = GameTypes.GameMode
local UnitType = GameTypes.UnitType
local Structures = GameTypes.Structures
local Relation = GameTypes.Relation

local AiAttackBehavior = {}
AiAttackBehavior.__index = AiAttackBehavior

-- EARLY GRACE: nations/bots act only a third as often for the first 90 s, and
-- never attack human players during that window, so the player has time to
-- claim their starting territory (Roblox port tuning).
local EARLY_GRACE_TICKS = 1800
local EARLY_GRACE_SKIP = 5

function AiAttackBehavior.new(random, game, player, triggerRatio: number, reserveRatio: number, expandRatio: number, allianceBehavior, emojiBehavior)
	return setmetatable({
		random = random,
		game = game,
		player = player,
		triggerRatio = triggerRatio,
		reserveRatio = reserveRatio,
		expandRatio = expandRatio,
		allianceBehavior = allianceBehavior,
		emojiBehavior = emojiBehavior,
		_botAttackTroopsSent = 0,
		_nbuf = { 0, 0, 0, 0 },
	}, AiAttackBehavior)
end

function AiAttackBehavior:_hasReserveRatioTroops(): boolean
	local maxTroops = self.game:config():maxTroops(self.player)
	return self.player:troops() / maxTroops >= self.reserveRatio
end

function AiAttackBehavior:_hasTriggerRatioTroops(): boolean
	local maxTroops = self.game:config():maxTroops(self.player)
	return self.player:troops() / maxTroops >= self.triggerRatio
end

function AiAttackBehavior:findIncomingAttackPlayer()
	local player = self.player
	local largestAttack = 0
	local largestAttacker = nil
	for _, attack in player:incomingAttacks() do
		if player:isFriendly(attack:attacker()) then
			continue
		end
		-- Ignore bot attacks if we are not a bot.
		if player:type() ~= PlayerType.Bot and attack:attacker():type() == PlayerType.Bot then
			continue
		end
		if attack:troops() <= largestAttack then
			continue
		end
		largestAttack = attack:troops()
		largestAttacker = attack:attacker()
	end
	return largestAttacker
end

function AiAttackBehavior:attackRandomTarget()
	-- Save up troops until we reach the trigger ratio
	if not self:_hasTriggerRatioTroops() then
		return
	end

	-- Retaliate against incoming attacks
	local incomingAttackPlayer = self:findIncomingAttackPlayer()
	if incomingAttackPlayer then
		if self:sendAttack(incomingAttackPlayer, true) then
			return
		end
	end

	-- Select a traitor as an enemy
	local toAttack = self:getNeighborTraitorToAttack()
	if toAttack ~= nil then
		if self.random:chance(3) then
			if self:sendAttack(toAttack) then
				return
			end
		end
	end

	-- Choose a new enemy randomly
	local neighbors = self.player:nearby()
	for _, neighbor in self.random:shuffleArray(neighbors) do
		if not neighbor:isPlayer() then
			continue
		end
		if self.player:isFriendly(neighbor) then
			continue
		end
		if neighbor:type() == PlayerType.Nation or neighbor:type() == PlayerType.Human then
			if self.random:chance(2) then
				continue
			end
		end
		if self:sendAttack(neighbor) then
			return
		end
	end
end

function AiAttackBehavior:getNeighborTraitorToAttack()
	if self.game:config():disableAlliances() then
		return nil
	end
	local traitors = {}
	for _, n in self.player:nearby() do
		if n:isPlayer() and self.player:isFriendly(n) == false and n:isTraitor() then
			table.insert(traitors, n)
		end
	end
	return if #traitors > 0 then self.random:randElement(traitors) else nil
end

function AiAttackBehavior:forceSendAttack(target)
	self.game:addExecution(
		AttackExecution.new(self.player:troops() / 2, self.player, if target:isPlayer() then target:id() else nil)
	)
end

function AiAttackBehavior:sendAttack(target, force: boolean?): boolean
	if not force and not self:shouldAttack(target) then
		return false
	end
	if target:isPlayer() then
		if self.player:sharesBorderWith(target) then
			return self:_sendLandAttack(target)
		end
		return self:_sendBoatAttack(target)
	end
	-- sharesBorderWith(TerraNullius) counts water as TN, so use a land-only
	-- adjacency check to decide land vs boat attack.
	if self:_hasLandBorderWithTerraNullius() then
		return self:_sendLandAttack(target)
	end
	return self:_sendBoatAttackToNearbyTerraNullius()
end

function AiAttackBehavior:_hasLandBorderWithTerraNullius(): boolean
	local map = self.game:map()
	local nbuf = self._nbuf
	for border in self.player:borderTiles() do
		local n = map:neighbors4(border, nbuf)
		for i = 1, n do
			local neighbor = nbuf[i]
			if map:isLand(neighbor) and not map:isImpassable(neighbor) and not map:hasOwner(neighbor) then
				return true
			end
		end
	end
	return false
end

-- The player's shore border tiles, in border-set order.
function AiAttackBehavior:_shoreTiles(player): { number }
	local out = {}
	for t in player:borderTiles() do
		if self.game:isShore(t) then
			table.insert(out, t)
		end
	end
	return out
end

-- Scans every 10th shore border tile for unowned land within 5 water tiles
-- in each cardinal direction and sends a boat to the first match.
local DIRECTIONS = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }
function AiAttackBehavior:_sendBoatAttackToNearbyTerraNullius(): boolean
	local game, player = self.game, self.player
	if game:config():isUnitDisabled(UnitType.TransportShip) then
		return false
	end
	if player:unitCount(UnitType.TransportShip) >= game:config():boatMaxNumber() then
		return false
	end
	local shores = self:_shoreTiles(player)
	local checks = 0 -- Roblox port: at most 8 water-path checks per turn (see MAX_BOAT_TARGET_CHECKS)
	for i = 1, #shores, 10 do
		local border = shores[i]
		local bx, by = game:x(border), game:y(border)
		for _, d in DIRECTIONS do
			local dx, dy = d[1], d[2]
			local x1, y1 = bx + dx, by + dy
			if not game:isValidCoord(x1, y1) or not game:isWater(game:ref(x1, y1)) then
				continue
			end
			local nx, ny = bx + dx * 5, by + dy * 5
			if not game:isValidCoord(nx, ny) then
				continue
			end
			local tile = game:ref(nx, ny)
			if not game:isLand(tile) or game:isImpassable(tile) or game:hasOwner(tile) or game:hasFallout(tile) then
				continue
			end
			checks += 1
			if not TransportShipUtils.canBuildTransportShip(game, player, tile) then
				if checks >= 8 then
					return false
				end
				continue
			end
			local troops = math.min(player:troops() / 5, self:_troopSendCapForExpansion())
			if troops < 1 then
				return false
			end
			game:addExecution(TransportShipExecution.new(player, tile, troops))
			return true
		end
	end
	return false
end

function AiAttackBehavior:shouldAttack(other): boolean
	if self.game:ticks() < EARLY_GRACE_TICKS and other:isPlayer() and other:type() == PlayerType.Human then
		return false
	end
	if
		-- Always attack Terra Nullius, non-humans and traitors
		other:isPlayer() == false
		or other:type() ~= PlayerType.Human
		or other:isTraitor()
		-- Always attack if we are a bot or in an HvN game
		or self.player:type() == PlayerType.Bot
		or self.game:config():gameConfig().playerTeams == GameTypes.HumansVsNations
	then
		return true
	end
	-- Prevent attacking of humans on lower difficulties
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy and self.random:nextInt(0, 4) ~= 0 then
		return false
	end
	if difficulty == Difficulty.Medium and self.random:chance(4) then
		return false
	end
	return true
end

-- Hard & Impossible nations in FFA: true if `troops` < 20% of the target's.
function AiAttackBehavior:_isAttackTooWeak(troops: number, target): boolean
	if self.player:type() == PlayerType.Bot then
		return false
	end
	if self.game:config():gameConfig().gameMode == GameMode.Team then
		return false
	end
	if #self.player:incomingAttacks() > 0 then
		return false
	end
	local difficulty = self.game:config():gameConfig().difficulty
	return (difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible) and troops < target:troops() * 0.2
end

-- Hard & Impossible nations in FFA: max troops sendable without dropping
-- below a fraction of the strongest non-allied neighbor. Infinity if no cap.
function AiAttackBehavior:_troopSendCap(): number
	local player = self.player
	if player:type() == PlayerType.Bot then
		return math.huge
	end
	if self.game:config():gameConfig().gameMode == GameMode.Team then
		return math.huge
	end
	local difficulty = self.game:config():gameConfig().difficulty
	local retainFraction
	if difficulty == Difficulty.Hard then
		retainFraction = 0.75
	elseif difficulty == Difficulty.Impossible then
		retainFraction = 0.9
	else
		return math.huge
	end

	local maxNeighborTroops = 0
	for _, n in player:nearby() do
		if n:isPlayer() and not player:isFriendly(n) and n:type() ~= PlayerType.Bot and n:troops() > maxNeighborTroops then
			maxNeighborTroops = n:troops()
		end
	end

	local cap
	if maxNeighborTroops == 0 then
		cap = math.huge
	else
		local minRetained = math.ceil(maxNeighborTroops * retainFraction)
		cap = math.max(0, player:troops() - minRetained)
	end

	local incoming = player:incomingAttacks()
	if #incoming > 0 then
		local totalIncoming = 0
		for _, a in incoming do
			totalIncoming += a:troops()
		end
		cap = math.max(cap, totalIncoming)
	end
	return cap
end

-- Like troopSendCap(), floored above 0: Terra Nullius can't fight back.
function AiAttackBehavior:_troopSendCapForExpansion(): number
	local cap = self:_troopSendCap()
	if cap > 0 then
		return cap
	end
	return math.ceil(self.player:troops() * 0.05)
end

function AiAttackBehavior:_calculateAttackTroops(target, nonBotTroops: (number) -> number): number?
	local player = self.player
	local maxTroops = self.game:config():maxTroops(player)
	local botWithStructures = false
	if target:isPlayer() and target:type() == PlayerType.Bot then
		for _, u in target:units() do
			if Structures.has(u:type()) then
				botWithStructures = true
				break
			end
		end
	end
	-- Expand ratio when attacking a bot that owns structures (recapture ASAP).
	local useReserve = target:isPlayer() and not botWithStructures
	local reserveRatio = if useReserve then self.reserveRatio else self.expandRatio
	local targetTroops = maxTroops * reserveRatio

	local troops
	local isBotAttack = target:isPlayer() and target:type() == PlayerType.Bot and player:type() ~= PlayerType.Bot
	if isBotAttack then
		troops = self:_calculateBotAttackTroops(target, player:troops() - targetTroops - self._botAttackTroopsSent)
	else
		troops = nonBotTroops(targetTroops)
	end

	troops = math.min(troops, if target:isPlayer() then self:_troopSendCap() else self:_troopSendCapForExpansion())

	if troops < 1 then
		return nil
	end

	if target:isPlayer() and self:_isAttackTooWeak(troops, target) then
		return nil
	end

	if target:isPlayer() and player:type() == PlayerType.Nation then
		if self.emojiBehavior then
			self.emojiBehavior:maybeSendAttackEmoji(target)
		end
	end

	if isBotAttack then
		self._botAttackTroopsSent += troops
	end
	return troops
end

function AiAttackBehavior:_sendLandAttack(target): boolean
	local troops = self:_calculateAttackTroops(target, function(targetTroops)
		return self.player:troops() - targetTroops
	end)
	if troops == nil then
		return false
	end
	self.game:addExecution(AttackExecution.new(troops, self.player, if target:isPlayer() then target:id() else nil))
	return true
end

function AiAttackBehavior:_sendBoatAttack(target): boolean
	local game = self.game
	if game:config():isUnitDisabled(UnitType.TransportShip) then
		return false
	end
	local _, closestY = ExecUtil.closestTwoTiles(game, self:_shoreTiles(self.player), self:_shoreTiles(target))
	if closestY == nil then
		return false
	end
	if not TransportShipUtils.canBuildTransportShip(game, self.player, closestY) then
		return false
	end
	local troops = self:_calculateAttackTroops(target, function()
		return self.player:troops() / 5
	end)
	if troops == nil then
		return false
	end
	game:addExecution(TransportShipExecution.new(self.player, closestY, troops))
	return true
end

function AiAttackBehavior:_calculateBotAttackTroops(target, maxTroops: number): number
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return maxTroops
	end
	local troops = target:troops() * 4
	-- Don't send more troops than maxTroops (keep reserve)
	if troops > maxTroops then
		if maxTroops < target:troops() * 2 then
			troops = 0
		else
			troops = maxTroops
		end
	end
	return troops
end


-- Nation behaviour ----------------------------------------------------------------

function AiAttackBehavior:maybeAttack()
	local game, player = self.game, self.player
	assert(self.allianceBehavior ~= nil, "not initialized")
	if game:ticks() < EARLY_GRACE_TICKS and game:ticks() % EARLY_GRACE_SKIP ~= 0 then
		return
	end

	-- Neighbor visit order matters: the set's insertion order feeds the
	-- stable troop-count sort below, so ties keep border-discovery order.
	local borderingPlayerSet = JSSet.new()
	local borderHasNonNukedTerraNullius = false
	local smallID = player:smallID()
	local function visit(t: number)
		if not game:isLand(t) or game:isImpassable(t) then
			return
		end
		if game:ownerID(t) == smallID then
			return
		end
		local owner = game:playerBySmallID(game:ownerID(t))
		if owner:isPlayer() then
			borderingPlayerSet:add(owner)
		end
		if not game:hasOwner(t) and not game:hasFallout(t) then
			borderHasNonNukedTerraNullius = true
		end
	end
	-- Roblox port: the border scan is cached per nation (a big late-game
	-- border is tens of thousands of tiles, ~15 ms per scan) and redone every
	-- 20 ticks: a nation at war changes territory every tick, so a version
	-- check would never hit.
	local cache = self._borderScan
	if cache and game:ticks() - cache.tick < 20 then
		for _, owner in cache.owners do
			if owner:isAlive() then
				borderingPlayerSet:add(owner)
			end
		end
		borderHasNonNukedTerraNullius = cache.terraNullius
	else
		for t in player:borderTiles() do
			game:forEachNeighbor(t, visit)
		end
		self._borderScan = {
			tick = game:ticks(),
			owners = borderingPlayerSet:toArray(),
			terraNullius = borderHasNonNukedTerraNullius,
		}
	end
	local playerNeighbors = player:nearby()
	for _, n in playerNeighbors do
		if n:isPlayer() then
			borderingPlayerSet:add(n)
		end
	end
	local borderingPlayers = Util.sort(borderingPlayerSet:toArray(), function(a, b)
		return a:troops() - b:troops()
	end)
	local borderingFriends, borderingEnemies = {}, {}
	for _, o in borderingPlayers do
		if player:isFriendly(o) then
			table.insert(borderingFriends, o)
		else
			table.insert(borderingEnemies, o)
		end
	end

	-- Attack TerraNullius but not nuked territory (direct border or across a river)
	local hasNonNukedTerraNullius = borderHasNonNukedTerraNullius
	if not hasNonNukedTerraNullius then
		for _, n in playerNeighbors do
			if not n:isPlayer() then
				hasNonNukedTerraNullius = true
				break
			end
		end
	end
	if hasNonNukedTerraNullius then
		if self:sendAttack(game:terraNullius()) then
			return
		end
	end

	if #borderingEnemies == 0 then
		if self.random:chance(5) then
			self:_attackWithRandomBoat({})
		end
	else
		if self.random:chance(10) then
			self:_attackWithRandomBoat(borderingEnemies)
			return
		end
		self.allianceBehavior:maybeSendAllianceRequests(borderingEnemies)
	end

	self:_attackBestTarget(borderingFriends, borderingEnemies)
end

function AiAttackBehavior:_attackWithRandomBoat(borderingEnemies)
	local game, player = self.game, self.player
	if game:config():isUnitDisabled(UnitType.TransportShip) then
		return
	end
	if player:unitCount(UnitType.TransportShip) >= game:config():boatMaxNumber() then
		return
	end
	local shore = self:_shoreTiles(player)
	if #shore == 0 then
		return
	end
	local src = self.random:randElement(shore)

	-- First look for high-interest targets (unowned or bot-owned), then players.
	local dst = self:_findRandomBoatTarget(src, borderingEnemies, true)
	if dst == nil then
		dst = self:_findRandomBoatTarget(src, borderingEnemies, false)
		if dst == nil then
			return
		end
	end

	local owner = game:owner(dst)
	local cap = if owner:isPlayer() then self:_troopSendCap() else self:_troopSendCapForExpansion()
	local troops = math.min(player:troops() / 5, cap)
	if troops < 1 then
		return
	end
	if owner:isPlayer() and self:_isAttackTooWeak(troops, owner) then
		return
	end
	game:addExecution(TransportShipExecution.new(player, dst, troops))
end

local MAX_BOAT_TARGET_CHECKS = 8

function AiAttackBehavior:_findRandomBoatTarget(tile: number, borderingEnemies, highInterestOnly: boolean): number?
	local game, player = self.game, self.player
	local x, y = game:x(tile), game:y(tile)
	local unreachablePlayers = {}
	local expensiveChecks = 0
	for _ = 1, 500 do
		local randX = self.random:nextInt(x - 150, x + 150)
		local randY = self.random:nextInt(y - 150, y + 150)
		if not game:isValidCoord(randX, randY) then
			continue
		end
		local randTile = game:ref(randX, randY)
		if not game:isLand(randTile) or game:isImpassable(randTile) then
			continue
		end
		local owner = game:owner(randTile)
		if owner == player then
			continue
		end
		local isPlayer = owner:isPlayer()
		if isPlayer and unreachablePlayers[owner:id()] then
			continue
		end
		-- Don't send boats to players with which we share a border
		if isPlayer and table.find(borderingEnemies, owner) then
			continue
		end
		-- Don't spam boats into players which are stronger than us (FFA only)
		if self:_isFFA() and isPlayer and owner:troops() > player:troops() then
			continue
		end
		local matchesCriteria
		if highInterestOnly then
			matchesCriteria = not isPlayer or owner:type() == PlayerType.Bot
		else
			matchesCriteria = not isPlayer or not owner:isFriendly(player)
		end
		if not matchesCriteria then
			continue
		end
		-- Roblox port: canBuildTransportShip searches water paths (several ms
		-- each); with unreachable land nearby up to 500 of them ran in one turn
		-- (a 350 ms tick). Give up after 8 failed checks and try next turn.
		expensiveChecks += 1
		if TransportShipUtils.canBuildTransportShip(game, player, randTile) == false then
			if isPlayer then
				unreachablePlayers[owner:id()] = true
			end
			if expensiveChecks >= MAX_BOAT_TARGET_CHECKS then
				return nil
			end
			continue
		end
		return randTile
	end
	return nil
end

-- Called with borderingFriends / borderingEnemies sorted by troops (ascending).
function AiAttackBehavior:_attackBestTarget(borderingFriends, borderingEnemies)
	-- With high starting gold nations build many cities and expand slowly, so
	-- attack bots (which would steal structures) before the ratio checks.
	if self:_hasNeighboringBotWithStructures() then
		if self:_attackBots() then
			return
		end
	end
	if not self:_hasReserveRatioTroops() then
		return
	end
	if not self:_hasTriggerRatioTroops() and not self.random:chance(10) then
		return
	end
	for _, strategy in self:_getAttackStrategies(borderingFriends, borderingEnemies) do
		if strategy() then
			return
		end
	end
end

function AiAttackBehavior:_getAttackStrategies(borderingFriends, borderingEnemies)
	local game, player = self.game, self.player
	local difficulty = game:config():gameConfig().difficulty

	local function retaliate(): boolean
		local attacker = self:findIncomingAttackPlayer()
		if attacker then
			return self:sendAttack(attacker, true)
		end
		return false
	end
	local function bots(): boolean
		return self:_attackBots()
	end
	local function assist(): boolean
		return self:_assistAllies()
	end
	local function traitor(): boolean
		local t = self:_findTraitor(borderingEnemies)
		if t then
			return self:sendAttack(t)
		end
		return false
	end
	local function afk(): boolean
		for _, enemy in borderingEnemies do
			if enemy:isDisconnected() and (not self:_isFFA() or enemy:troops() < player:troops() * 3) then
				return self:sendAttack(enemy)
			end
		end
		return false
	end
	local function betray(): boolean
		return self:_maybeBetrayAndAttack(borderingFriends, borderingEnemies)
	end
	local function nuked(): boolean
		if self:_isBorderingNukedTerritory() then
			return self:sendAttack(game:terraNullius())
		end
		return false
	end
	local function victim(): boolean
		local v = self:_findVictim(borderingEnemies)
		if v then
			return self:sendAttack(v)
		end
		return false
	end
	local function juicy(): boolean
		local target = self:_findJuicyTarget(borderingEnemies)
		return if target ~= nil then self:sendAttack(target) else false
	end
	local function hated(): boolean
		for _, relation in player:allRelationsSorted() do
			if relation.relation ~= Relation.Hostile then
				continue
			end
			local other = relation.player
			if player:isFriendly(other) then
				continue
			end
			if self:_isFFA() and other:troops() > player:troops() * 3 then
				continue
			end
			return self:sendAttack(other)
		end
		return false
	end
	local function veryWeak(): boolean
		local v = self:_findVeryWeakEnemy(borderingEnemies)
		if v then
			return self:sendAttack(v)
		end
		return false
	end
	local function weakest(): boolean
		if #borderingEnemies > 0 then
			local w = borderingEnemies[1]
			if not self:_isFFA() or w:troops() < player:troops() then
				return self:sendAttack(w)
			end
		end
		return false
	end
	local function island(): boolean
		if #borderingEnemies == 0 then
			local enemy = self:_findNearestIslandEnemy()
			if enemy then
				return self:sendAttack(enemy)
			end
		end
		return false
	end
	local function donate(): boolean
		return self:_donateTroops()
	end

	-- Easy nations get the dumbest order, impossible nations the smartest.
	if difficulty == Difficulty.Easy then
		return { nuked, bots, retaliate, assist, betray, hated, weakest }
	elseif difficulty == Difficulty.Medium then
		return { bots, nuked, retaliate, assist, betray, hated, afk, traitor, weakest, island, donate }
	elseif difficulty == Difficulty.Hard then
		return { bots, retaliate, assist, betray, nuked, traitor, afk, hated, veryWeak, juicy, victim, weakest, island, donate }
	elseif difficulty == Difficulty.Impossible then
		return { retaliate, bots, veryWeak, betray, assist, victim, traitor, juicy, afk, nuked, hated, weakest, island, donate }
	end
	error(`unknown difficulty {difficulty}`)
end

local function ownsStructures(p): boolean
	for _, u in p:units() do
		if Structures.has(u:type()) then
			return true
		end
	end
	return false
end

function AiAttackBehavior:_hasNeighboringBotWithStructures(): boolean
	for _, n in self.player:nearby() do
		if n:isPlayer() and n:type() == PlayerType.Bot and not self.player:isFriendly(n) and ownsStructures(n) then
			return true
		end
	end
	return false
end

-- Attack neighbouring bots in parallel, those owning structures first, then
-- by density; sendAttack does nothing once the reserve is used up.
function AiAttackBehavior:_attackBots(): boolean
	local bots = {}
	for _, n in self.player:nearby() do
		if n:isPlayer() and self.player:isFriendly(n) == false and n:type() == PlayerType.Bot then
			table.insert(bots, n)
		end
	end
	if #bots == 0 then
		return false
	end

	self._botAttackTroopsSent = 0

	local function density(p): number
		return p:troops() / p:numTilesOwned()
	end
	Util.sort(bots, function(a, b)
		local aHas, bHas = ownsStructures(a), ownsStructures(b)
		if aHas ~= bHas then
			return if aHas then -1 else 1
		end
		return density(a) - density(b)
	end)
	local limit = self:_getBotAttackMaxParallelism()
	for i = 1, math.min(limit, #bots) do
		self:sendAttack(bots[i])
	end
	-- Only short-circuit the targeting pipeline if troops were allocated.
	return self._botAttackTroopsSent > 0
end

function AiAttackBehavior:_getBotAttackMaxParallelism(): number
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy then
		return 1
	elseif difficulty == Difficulty.Medium then
		return if self.random:chance(2) then 1 else 2
	elseif difficulty == Difficulty.Hard then
		return 3
	end
	return 100
end

function AiAttackBehavior:_assistAllies(): boolean
	local player, emoji = self.player, self.emojiBehavior
	if self.game:config():disableAlliances() then
		return false
	end
	for _, ally in player:allies() do
		local targets = ally:targets()
		if #targets == 0 then
			continue
		end
		if player:relation(ally) < Relation.Friendly then
			emoji:sendEmoji(ally, NationEmojiBehavior.EMOJI_ASSIST_RELATION_TOO_LOW)
			continue
		end
		for _, target in targets do
			if target == player then
				emoji:sendEmoji(ally, NationEmojiBehavior.EMOJI_ASSIST_TARGET_ME)
				continue
			end
			if player:isFriendly(target) then
				emoji:sendEmoji(ally, NationEmojiBehavior.EMOJI_ASSIST_TARGET_ALLY)
				continue
			end
			if not self:sendAttack(target) then
				continue
			end
			player:updateRelation(ally, -20)
			emoji:sendEmoji(ally, NationEmojiBehavior.EMOJI_ASSIST_ACCEPT)
			return true
		end
	end
	return false
end

-- A traitor who isn't significantly stronger than us.
function AiAttackBehavior:_findTraitor(borderingEnemies)
	if self.game:config():disableAlliances() then
		return nil
	end
	for _, enemy in borderingEnemies do
		if enemy:isTraitor() and (not self:_isFFA() or enemy:troops() < self.player:troops() * 1.2) then
			return enemy
		end
	end
	return nil
end

function AiAttackBehavior:_maybeBetrayAndAttack(borderingFriends, borderingEnemies): boolean
	if self.game:config():disableAlliances() then
		return false
	end
	if #borderingFriends > 0 then
		local juiciestAlly = self.allianceBehavior:findJuiciestAlly(borderingFriends)
		for _, friend in borderingFriends do
			if self.allianceBehavior:maybeBetray(friend, juiciestAlly, borderingFriends, borderingEnemies) then
				return self:sendAttack(friend, true)
			end
		end
	end
	return false
end

function AiAttackBehavior:_isBorderingNukedTerritory(): boolean
	local game = self.game
	if game:config():isUnitDisabled(UnitType.MissileSilo) then
		return false
	end
	local nbuf = self._nbuf
	for tile in self.player:borderTiles() do
		local n = game:neighbors4(tile, nbuf)
		for i = 1, n do
			local neighbor = nbuf[i]
			if game:isLand(neighbor) and not game:hasOwner(neighbor) and game:hasFallout(neighbor) then
				return true
			end
		end
	end
	return false
end

-- Someone not much stronger than us under big attack (50%+ of their troops incoming).
function AiAttackBehavior:_findVictim(borderingEnemies)
	for _, enemy in borderingEnemies do
		if self:_isFFA() and enemy:troops() > self.player:troops() * 1.2 then
			continue
		end
		local totalIncoming = 0
		for _, attack in enemy:incomingAttacks() do
			totalIncoming += attack:troops()
		end
		if totalIncoming > enemy:troops() * 0.5 then
			return enemy
		end
	end
	return nil
end

-- Enemies below 15% of their max troops that don't have many more troops than us.
function AiAttackBehavior:_findVeryWeakEnemy(borderingEnemies)
	for _, enemy in borderingEnemies do
		local enemyMaxTroops = self.game:config():maxTroops(enemy)
		if enemy:troops() < enemyMaxTroops * 0.15 and (not self:_isFFA() or enemy:troops() < self.player:troops() * 1.2) then
			return enemy
		end
	end
	return nil
end

function AiAttackBehavior:_findJuicyTarget(borderingEnemies)
	local candidates = {}
	for _, enemy in borderingEnemies do
		if enemy:troops() <= self.player:troops() * 0.75 then
			table.insert(candidates, enemy)
		end
	end
	return NationUtils.findJuiciestTarget(self.game, candidates)
end

function AiAttackBehavior:_findNearestIslandEnemy()
	local game, player = self.game, self.player
	if game:config():isUnitDisabled(UnitType.TransportShip) then
		return nil
	end
	if player:unitCount(UnitType.TransportShip) >= game:config():boatMaxNumber() then
		return nil
	end
	local hasShore = false
	for t in player:borderTiles() do
		if game:isShore(t) then
			hasShore = true
			break
		end
	end
	if not hasShore then
		return nil
	end

	local filtered = {}
	for _, p in game:players() do
		if p == player or player:isFriendly(p) then
			continue
		end
		if not self:_isFFA() or p:troops() < player:troops() then
			table.insert(filtered, p)
		end
	end
	if #filtered == 0 then
		return nil
	end

	local playerCenter = self:_getPlayerCenter(player)
	local sorted = {}
	for _, p in filtered do
		local c = self:_getPlayerCenter(p)
		local distance = game:manhattanDist(game:ref(playerCenter.x, playerCenter.y), game:ref(c.x, c.y))
		table.insert(sorted, { player = p, distance = distance })
	end
	Util.sort(sorted, function(a, b)
		return a.distance - b.distance
	end)

	local reachable = {}
	for _, entry in sorted do
		local _, closestY = ExecUtil.closestTwoTiles(game, self:_shoreTiles(player), self:_shoreTiles(entry.player))
		if closestY == nil then
			continue
		end
		if TransportShipUtils.canBuildTransportShip(game, player, closestY) then
			table.insert(reachable, entry.player)
			if #reachable >= 2 then
				break
			end
		end
	end
	if #reachable == 0 then
		return nil
	end
	-- 33% chance to pick the second-nearest player if available
	if #reachable >= 2 and self.random:chance(3) then
		return reachable[2]
	end
	return reachable[1]
end

-- In team games nations may go after stronger enemies (teammates donate).
function AiAttackBehavior:_isFFA(): boolean
	return self.game:config():gameConfig().gameMode == GameMode.FFA
end

local function boundingBoxCenter(box)
	return { x = box.min.x + math.floor((box.max.x - box.min.x) / 2), y = box.min.y + math.floor((box.max.y - box.min.y) / 2) }
end

function AiAttackBehavior:_getPlayerCenter(player)
	if player.largestClusterBoundingBox then
		return boundingBoxCenter(player.largestClusterBoundingBox)
	end
	return boundingBoxCenter(NameBoxCalculator.calculateBoundingBox(self.game, player:borderTiles()))
end

function AiAttackBehavior:_donateTroops(): boolean
	local game, player = self.game, self.player
	local gc = game:config():gameConfig()
	if gc.gameMode ~= GameMode.Team then
		return false
	end
	-- Don't donate in public games (to balance HvN)
	if gc.gameType == GameTypes.GameType.Public then
		return false
	end
	if game:config():donateTroops() == false then
		return false
	end
	if game:getWinner() ~= nil then
		return false
	end
	local difficulty = gc.difficulty
	if difficulty == Difficulty.Easy then
		return false
	elseif difficulty == Difficulty.Medium then
		if not self.random:chance(4) then
			return false
		end
	elseif difficulty == Difficulty.Hard then
		if not self.random:chance(2) then
			return false
		end
	end

	local rows = {}
	for _, p in game:players() do
		if player:isOnSameTeam(p) and (#p:incomingAttacks() > 0 or #p:outgoingAttacks() > 0) then
			table.insert(rows, { teammate = p, pct = p:troops() / math.max(game:config():maxTroops(p), 1) })
		end
	end
	if #rows == 0 then
		return false
	end
	Util.sort(rows, function(a, b)
		return a.pct - b.pct
	end)

	local selected = nil
	for _, entry in rows do
		if player:canDonateTroops(entry.teammate) then
			selected = entry.teammate
			break
		end
	end
	if selected == nil then
		return false
	end

	local troopsToKeep = game:config():maxTroops(player) * self.reserveRatio
	local availableTroops = player:troops() - troopsToKeep
	if availableTroops < 1 then
		return false
	end
	local DonateTroopsExecution = require(script.Parent.SocialExecutions).DonateTroopsExecution
	game:addExecution(DonateTroopsExecution.new(player, selected:id(), availableTroops))
	return true
end

return AiAttackBehavior
