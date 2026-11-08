-- Port of OpenFrontIO src/core/execution/TransportShipExecution.ts.
--
-- A boat carrying troops to a landing shore: picks the landing tile and a
-- launch shore, sails one tile per tick along the water path, then lands and
-- starts an AttackExecution from the beach (or returns troops home when
-- retreating / landing on own land).
-- Motion plans (upstream's client-side interpolation records) are replaced by
-- per-move unit updates in this port's replication.

local Format = require(game:GetService("ReplicatedStorage").Shared.Format)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local PathFinderMod = require(Core.Pathfinding.PathFinder)
local TransportShipUtils = require(Core.TransportShipUtils)
local AttackExecution = require(script.Parent.AttackExecution)

local UnitType = GameTypes.UnitType
local PlayerType = GameTypes.PlayerType
local MessageType = GameTypes.MessageType
local PathStatus = PathFinderMod.PathStatus
local WaterPathFinder = PathFinderMod.WaterPathFinder

local malusForRetreat = 25
local staggerCounter = 0

local TransportShipExecution = {}
TransportShipExecution.__index = TransportShipExecution

-- troops may be nil (upstream `troops ??= boatAttackAmount(...)`).
function TransportShipExecution.new(attacker, ref: number, troops: number?)
	return setmetatable({
		_active = true,
		_ticksPerMove = 1,
		_lastMove = 0,
		attacker = attacker,
		originalOwner = attacker,
		ref = ref,
		troops = troops,
		dst = nil,
		src = nil,
		retreatDst = nil, -- nil = unresolved, false = none, number = tile
		boat = nil,
	}, TransportShipExecution)
end

function TransportShipExecution:activeDuringSpawnPhase(): boolean
	return false
end

function TransportShipExecution:init(mg, ticks: number)
	if not mg:isValidRef(self.ref) then
		warn(`TransportShipExecution: ref {self.ref} not valid`)
		self._active = false
		return
	end
	self._lastMove = ticks
	self.mg = mg
	self.target = mg:owner(self.ref)
	local stagger = staggerCounter % WaterPathFinder.STAGGER_SPREAD
	staggerCounter += 1
	self.pathFinder = WaterPathFinder.new(mg, stagger)

	local attacker = self.attacker
	if attacker:unitCount(UnitType.TransportShip) >= mg:config():boatMaxNumber() then
		mg:displayMessage(
			"events_display.no_boats_available",
			MessageType.ATTACK_FAILED,
			attacker:id(),
			nil,
			{ max = mg:config():boatMaxNumber() }
		)
		self._active = false
		return
	end

	if self.target:isPlayer() then
		if self.target:type() ~= PlayerType.Bot and attacker:type() ~= PlayerType.Bot then
			self:_rejectIncomingAllianceRequests(self.target)
		end
	end

	if self.target == attacker then
		self._active = false
		return
	end
	if self.target:isPlayer() and not attacker:canAttackPlayer(self.target) then
		self._active = false
		return
	end

	if self.troops == nil then
		self.troops = mg:config():boatAttackAmount(attacker, self.target)
	end
	self.troops = math.min(self.troops, attacker:troops())

	self.dst = TransportShipUtils.targetTransportTile(mg, attacker, self.ref)
	if self.dst == nil then
		warn(`{attacker} cannot send ship to {self.target}, cannot find target tile`)
		self._active = false
		return
	end

	local src = attacker:canBuild(UnitType.TransportShip, self.dst)
	if src == false then
		warn(`{attacker} cannot send ship to {self.target}, cannot find start tile`)
		self._active = false
		return
	end
	self.src = src

	self.boat = attacker:buildUnit(UnitType.TransportShip, src, { troops = self.troops, targetTile = self.dst })

	-- Upstream records a motion plan (full path) here for client interpolation;
	-- the path query itself does not touch simulation state.
	self.pathFinder:findPath(self.src, self.dst)

	if self.target:id() ~= mg:terraNullius():id() then
		mg:displayIncomingUnit(
			self.boat:id(),
			`Naval invasion incoming from {attacker:displayName()} ({Format.renderTroops(self.boat:troops())})`,
			MessageType.NAVAL_INVASION_INBOUND,
			self.target:id()
		)
	end
	mg:stats():boatSendTroops(attacker, self.target, self.boat:troops())
end

function TransportShipExecution:tick(ticks: number)
	if self.dst == nil then
		self._active = false
		return
	end
	if not self._active then
		return
	end
	local boat, mg = self.boat, self.mg
	if not boat:isActive() then
		self._active = false
		return
	end
	if ticks - self._lastMove < self._ticksPerMove then
		return
	end
	self._lastMove = ticks

	-- A teammate can inherit a disconnected player's ships.
	local boatOwner = boat:owner()
	if self.originalOwner:isDisconnected() and boatOwner ~= self.originalOwner and boatOwner:isOnSameTeam(self.originalOwner) then
		self.attacker = boatOwner
		self.originalOwner = boatOwner
	end

	self.pathFinder:rebuilt() -- upstream re-records the motion plan here

	-- Auto-retreat if the destination turned to water (nuked).
	if self.dst ~= nil and mg:isWater(self.dst) then
		if not boat:transportShipState().isRetreating then
			boat:updateTransportShipState({ isRetreating = true })
		end
		self.retreatDst = nil
	end

	if boat:transportShipState().isRetreating then
		if self.retreatDst == nil then
			self.retreatDst = self.attacker:bestTransportShipSpawn(boat:tile())
		end
		if self.retreatDst == false then
			warn("TransportShipExecution: retreating but no retreat destination found")
			self.attacker:addTroops(boat:troops())
			boat:delete(false)
			self._active = false
			return
		end
		self.dst = self.retreatDst
		if boat:targetTile() ~= self.dst then
			boat:setTargetTile(self.dst)
		end
	end

	local result = self.pathFinder:next(boat:tile(), self.dst)
	if result.status == PathStatus.COMPLETE then
		if mg:owner(self.dst) == self.attacker then
			local deaths = boat:troops() * (malusForRetreat / 100)
			local survivors = boat:troops() - deaths
			self.attacker:addTroops(survivors)
			boat:delete(false)
			self._active = false
			mg:stats():boatArriveTroops(self.attacker, self.target, survivors)
			if deaths ~= 0 then
				mg:displayMessage(
					"events_display.attack_cancelled_retreat",
					MessageType.ATTACK_CANCELLED,
					self.attacker:id(),
					nil,
					{ troops = deaths }
				)
			end
			return
		end
		self.attacker:conquer(self.dst)
		if self.target:isPlayer() and self.attacker:isFriendly(self.target) then
			self.attacker:addTroops(boat:troops())
		else
			mg:addExecution(AttackExecution.new(boat:troops(), self.attacker, self.target:id(), self.dst, false))
		end
		boat:delete(false)
		self._active = false
		mg:stats():boatArriveTroops(self.attacker, self.target, boat:troops())
		return
	elseif result.status == PathStatus.NEXT then
		boat:move(result.node)
		-- Roblox port: boats sail 2 tiles per tick (upstream 1); players found
		-- them too slow. Arrival is still handled on the next tick.
		local second = self.pathFinder:next(boat:tile(), self.dst)
		if second.status == PathStatus.NEXT then
			boat:move(second.node)
		end
	else -- NOT_FOUND
		local map = mg:map()
		local bt = boat:tile()
		warn(
			`TransportShip path not found: boat@({map:x(bt)},{map:y(bt)}) -> dst@({map:x(self.dst)},{map:y(self.dst)}), attacker={self.attacker:id()}`
		)
		self.attacker:addTroops(boat:troops())
		boat:delete(false)
		self._active = false
		return
	end
end

function TransportShipExecution:owner()
	return self.attacker
end

function TransportShipExecution:isActive(): boolean
	return self._active
end

function TransportShipExecution:_rejectIncomingAllianceRequests(target)
	for _, ar in self.attacker:incomingAllianceRequests() do
		if ar:requestor() == target then
			ar:reject()
			return
		end
	end
end

return TransportShipExecution
