-- Port of OpenFrontIO src/core/execution/AttackExecution.ts.
--
-- The heart of territorial expansion: a priority queue of enemy/unowned
-- border tiles (terrain + randomness + how surrounded each tile is) that the
-- attack conquers each tick until its tick budget is spent.

local Shared = game:GetService("ReplicatedStorage").Shared
local FlatBinaryHeap = require(Shared.FlatBinaryHeap)
local GameMap = require(Shared.GameMap)
local JSSet = require(Shared.JSSet)
local PseudoRandom = require(Shared.PseudoRandom)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)

local PlayerType = GameTypes.PlayerType
local Difficulty = GameTypes.Difficulty
local MessageType = GameTypes.MessageType
local UnitType = GameTypes.UnitType
local TerrainType = GameMap.TerrainType

local malusForRetreat = 25

local AttackExecution = {}
AttackExecution.__index = AttackExecution

-- targetID nil means Terra Nullius (upstream terraNullius().id() is null).
function AttackExecution.new(startTroops: number?, owner, targetID: string?, sourceTile: number?, removeTroops: boolean?, focusTile: number?)
	return setmetatable({
		-- Optional click point of a human-directed attack: border tiles nearer to it
		-- are conquered first (nil = upstream behaviour, golden-vector safe).
		_focusTile = focusTile,
		_active = true,
		_toConquer = FlatBinaryHeap.new(),
		_random = PseudoRandom.new(123),
		_startTroops = startTroops,
		_owner = owner,
		_targetID = targetID,
		_sourceTile = sourceTile,
		_removeTroops = if removeTroops == nil then true else removeTroops,
		_attack = nil,
		_nbuf = { 0, 0, 0, 0 },
		_nbuf2 = { 0, 0, 0, 0 },
	}, AttackExecution)
end

function AttackExecution:targetID(): string?
	return self._targetID
end

function AttackExecution:activeDuringSpawnPhase(): boolean
	return false
end

function AttackExecution:init(mg, _ticks: number)
	if not self._active then
		return
	end
	self.mg = mg
	self.map = mg:map()

	if self._targetID ~= nil and not mg:hasPlayer(self._targetID) then
		warn(`target {self._targetID} not found`)
		self._active = false
		return
	end

	self.target = if self._targetID == nil then mg:terraNullius() else mg:player(self._targetID)
	self._ownerSmallID = self._owner:smallID()
	self._targetSmallID = self.target:smallID()

	if self._owner == self.target then
		warn(`Player {self._owner} cannot attack itself`)
		self._active = false
		return
	end

	-- ALLIANCE CHECK — block attacks on friendly (ally or same team)
	if self.target:isPlayer() and self._owner:isFriendly(self.target) then
		self._active = false
		return
	end

	if self.target:isPlayer() then
		if self.target:type() ~= PlayerType.Bot and self._owner:type() ~= PlayerType.Bot then
			-- Don't let bots embargo since they can't trade anyway.
			self.target:addEmbargo(self._owner, true)
			self:_rejectIncomingAllianceRequests(self.target)
		end
	end

	if self.target:isPlayer() and not self._owner:canAttackPlayer(self.target) then
		self._active = false
		return
	end

	if self._startTroops == nil then
		self._startTroops = mg:config():attackAmount(self._owner, self.target)
	end
	if self._removeTroops then
		self._startTroops = math.min(self._owner:troops(), self._startTroops)
		-- Take the amount actually deducted (removeTroops floors).
		self._startTroops = self._owner:removeTroops(self._startTroops)
	end
	local attack = self._owner:createAttack(self.target, self._startTroops, self._sourceTile, JSSet.new())
	self._attack = attack

	if self._sourceTile ~= nil then
		self:_addNeighbors(self._sourceTile)
	else
		self:_refreshToConquer()
	end

	mg:stats():attack(self._owner, self.target, self._startTroops)

	for _, incoming in self._owner:incomingAttacks() do
		if incoming:attacker() == self.target then
			-- Target has opposing attack, cancel them out
			if incoming:troops() > attack:troops() then
				incoming:setTroops(incoming:troops() - attack:troops())
				attack:delete()
				self._active = false
				return
			else
				attack:setTroops(attack:troops() - incoming:troops())
				incoming:delete()
			end
		end
	end
	for _, outgoing in self._owner:outgoingAttacks() do
		if
			outgoing ~= attack
			and outgoing:target() == attack:target()
			-- Boat attacks (sourceTile set) are not combined with other attacks
			and attack:sourceTile() == nil
		then
			attack:setTroops(attack:troops() + outgoing:troops())
			outgoing:delete()
		end
	end

	mg:stats():attackMaxIncoming(self.target, attack:troops())

	if self.target:isPlayer() then
		local difficulty = mg:config():gameConfig().difficulty
		local relationChange
		if difficulty == Difficulty.Easy then
			relationChange = -60
		elseif difficulty == Difficulty.Medium then
			relationChange = -70
		elseif difficulty == Difficulty.Hard then
			relationChange = -80
		elseif difficulty == Difficulty.Impossible then
			relationChange = -100
		else
			error(`Unexpected difficulty: {difficulty}`)
		end
		self.target:updateRelation(self._owner, relationChange)
	end
end

function AttackExecution:_refreshToConquer()
	self._toConquer:clear()
	self._attack:clearBorder()
	for tile in self._owner:borderTiles() do
		self:_addNeighbors(tile)
	end
end

function AttackExecution:_retreat(malusPercent: number?)
	local attack = self._attack
	local deaths = attack:troops() * ((malusPercent or 0) / 100)
	if deaths ~= 0 then
		self.mg:displayMessage(
			"events_display.attack_cancelled_retreat",
			MessageType.ATTACK_CANCELLED,
			self._owner:id(),
			nil,
			{ troops = deaths }
		)
	end
	if self._removeTroops == false and self._sourceTile == nil then
		-- startTroops were added to the attack but never removed from the owner.
		attack:setTroops(attack:troops() - (self._startTroops or 0))
	end

	local survivors = attack:troops() - deaths
	self._owner:addTroops(survivors)
	attack:delete()
	self._active = false

	if attack:retreated() then
		self.mg:stats():attackCancel(self._owner, self.target, survivors)
	end
end

function AttackExecution:tick(_ticks: number)
	local attack = self._attack
	if attack == nil then
		error("Attack not initialized")
	end
	local troopCount = attack:troops()
	local targetIsPlayer = self.target:isPlayer()
	local targetPlayer = if targetIsPlayer then self.target else nil

	if attack:retreated() then
		if targetIsPlayer then
			self:_retreat(malusForRetreat)
		else
			self:_retreat()
		end
		self._active = false
		return
	end

	if attack:retreating() then
		return
	end

	if not attack:isActive() then
		self._active = false
		return
	end

	if targetPlayer and self._owner:isFriendly(targetPlayer) then
		-- A new alliance was created AFTER the attack started.
		self:_retreat()
		return
	end

	local map = self.map
	local nbuf = self._nbuf
	local borderSize = attack:borderSize() + self._random:nextInt(0, 5)
	-- Each tile consumes a fraction of the tick; conquer until it is spent.
	local tickBudget = 1

	while tickBudget > 0 do
		if troopCount < 1 then
			attack:delete()
			self._active = false
			return
		end

		if self._toConquer:size() == 0 then
			self:_refreshToConquer()
			self:_retreat()
			return
		end

		local tileToConquer = self._toConquer:dequeue()
		attack:removeBorderTile(tileToConquer)

		local onBorder = false
		local numNeighbors = map:neighbors4(tileToConquer, nbuf)
		for i = 1, numNeighbors do
			if map:ownerID(nbuf[i]) == self._ownerSmallID then
				onBorder = true
				break
			end
		end
		if map:ownerID(tileToConquer) ~= self._targetSmallID or not onBorder then
			continue
		end
		if not map:isLand(tileToConquer) or map:isImpassable(tileToConquer) then
			continue
		end
		self:_addNeighbors(tileToConquer)
		local attackerTroopLoss, defenderTroopLoss, tickFraction =
			self.mg:config():attackLogic(self:_attackLogicInput(troopCount, tileToConquer, borderSize))
		tickBudget -= tickFraction
		troopCount -= attackerTroopLoss
		attack:setTroops(troopCount)
		if targetPlayer then
			targetPlayer:removeTroops(defenderTroopLoss)
		end
		self._owner:conquer(tileToConquer)
		self:_handleDeadDefender()
	end
end

function AttackExecution:_attackLogicInput(attackTroops: number, tile: number, borderSize: number)
	local mg = self.mg
	local defender = if self.target:isPlayer() then self.target else nil
	local defenderHasDefensePost = defender ~= nil
		and mg:hasUnitNearby(tile, mg:config():defensePostRange(), UnitType.DefensePost, defender:id())
	return {
		terrain = self.map:terrainType(tile),
		attackTroops = attackTroops,
		attacker = { type = self._owner:type(), numTiles = self._owner:numTilesOwned() },
		defender = if defender == nil
			then nil
			else {
				type = defender:type(),
				numTiles = defender:numTilesOwned(),
				troops = defender:troops(),
				isTraitor = defender:isTraitor(),
				isDisconnectedTeammate = defender:isDisconnected() and self._owner:isOnSameTeam(defender),
			},
		defenderHasDefensePost = defenderHasDefensePost,
		falloutRatio = if mg:hasFallout(tile) then mg:numTilesWithFallout() / mg:numLandTiles() else nil,
		borderSize = borderSize,
	}
end

function AttackExecution:_rejectIncomingAllianceRequests(target)
	for _, ar in self._owner:incomingAllianceRequests() do
		if ar:requestor() == target then
			ar:reject()
			return
		end
	end
end

function AttackExecution:_addNeighbors(tile: number)
	local map = self.map
	local attack = self._attack
	local tickNow = self.mg:ticks()
	local nbuf, nbuf2 = self._nbuf, self._nbuf2

	local numNeighbors = map:neighbors4(tile, nbuf)
	for i = 1, numNeighbors do
		local neighbor = nbuf[i]
		if map:isWater(neighbor) or map:isImpassable(neighbor) or map:ownerID(neighbor) ~= self._targetSmallID then
			continue
		end
		attack:addBorderTile(neighbor)
		local numOwnedByMe = 0
		local numInner = map:neighbors4(neighbor, nbuf2)
		for j = 1, numInner do
			if map:ownerID(nbuf2[j]) == self._ownerSmallID then
				numOwnedByMe += 1
			end
		end

		local terrain = map:terrainType(neighbor)
		local mag
		if terrain == TerrainType.Plains then
			mag = 1
		elseif terrain == TerrainType.Highland then
			mag = 1.5
		elseif terrain == TerrainType.Mountain then
			mag = 2
		else
			mag = 0
		end

		local priority = (self._random:nextInt(0, 7) + 10) * (1 - numOwnedByMe * 0.5 + mag / 2) + tickNow
		local focus = self._focusTile
		if focus ~= nil then
			-- Soft directional bias: +0.6 priority (= later) per tile of distance from the click.
			priority += 0.6 * math.sqrt(self.mg:euclideanDistSquared(neighbor, focus))
		end
		self._toConquer:enqueue(neighbor, priority)
	end
end

function AttackExecution:_handleDeadDefender()
	if not (self.target:isPlayer() and self.target:numTilesOwned() < 100) then
		return
	end
	local target = self.target
	local mg = self.mg
	local owner = self._owner

	mg:conquerPlayer(owner, target)

	local MAX_PASSES = 100
	for _ = 1, MAX_PASSES do
		local progressed = false
		for tile in target:tiles() do
			local borders = false
			mg:forEachNeighbor(tile, function(t)
				if not borders and mg:owner(t) == owner then
					borders = true
				end
			end)
			if borders then
				owner:conquer(tile)
				progressed = true
			else
				local captured = false
				mg:forEachNeighbor(tile, function(neighbor)
					if captured then
						return
					end
					local no = mg:owner(neighbor)
					if no:isPlayer() and no ~= target and not no:isFriendly(target) then
						mg:player(no:id()):conquer(tile)
						captured = true
					end
				end)
				if captured then
					progressed = true
				end
			end
		end
		if not progressed then
			break
		end
	end
end

function AttackExecution:owner()
	return self._owner
end

function AttackExecution:isActive(): boolean
	return self._active
end

return AttackExecution
