-- Port of OpenFrontIO src/core/execution/TradeShipExecution.ts.
-- A trade ship sails from one port to a partner's port; on arrival both
-- owners earn gold scaled by distance. Captured ships (warships) pay the
-- captor at its nearest reachable port instead.
-- TODO(port): WaterPathMemo (performance only; routes are identical).

local Shared = game:GetService("ReplicatedStorage").Shared
local Util = require(Shared.Util)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local PathFinderMod = require(Core.Pathfinding.PathFinder)

local UnitType = GameTypes.UnitType
local MessageType = GameTypes.MessageType
local PathStatus = PathFinderMod.PathStatus
local WaterPathFinder = PathFinderMod.WaterPathFinder

local staggerCounter = 0

local TradeShipExecution = {}
TradeShipExecution.__index = TradeShipExecution

function TradeShipExecution.new(origOwner, srcPort, dstPort)
	return setmetatable({
		origOwner = origOwner,
		srcPort = srcPort,
		_dstPort = dstPort,
		_active = true,
		tradeShip = nil,
		wasCaptured = false,
		tilesTraveled = 0,
	}, TradeShipExecution)
end

function TradeShipExecution:init(mg)
	self.mg = mg
	local stagger = staggerCounter % WaterPathFinder.STAGGER_SPREAD
	staggerCounter += 1
	self.pathFinder = WaterPathFinder.new(mg, stagger)
end

function TradeShipExecution:tick(ticks: number)
	local mg = self.mg
	self.pathFinder:rebuilt() -- upstream re-records the motion plan here

	if self.tradeShip == nil then
		local spawn = self.origOwner:canBuild(UnitType.TradeShip, self.srcPort:tile())
		if spawn == false then
			warn("cannot build trade ship")
			self._active = false
			return
		end
		self.tradeShip = self.origOwner:buildUnit(UnitType.TradeShip, spawn, {
			targetUnit = self._dstPort,
			lastSetSafeFromPirates = ticks,
		})
		mg:stats():boatSendTrade(self.origOwner, self._dstPort:owner())
	end
	local ship = self.tradeShip
	if not ship:isActive() then
		self._active = false
		return
	end

	local shipOwner = ship:owner()
	local dstPortOwner = self._dstPort:owner()
	if self.wasCaptured ~= true and self.origOwner ~= shipOwner then
		self.wasCaptured = true
		mg:displayMessage(
			"events_display.trade_ship_captured",
			MessageType.UNIT_DESTROYED,
			self.origOwner:id(),
			nil,
			{ name = shipOwner:displayName() },
			ship:id(),
			shipOwner:id()
		)
	end

	-- Capturing the destination port mid-trade removes the ship.
	if dstPortOwner:id() == self.srcPort:owner():id() then
		ship:delete(false)
		self._active = false
		return
	end
	if not self.wasCaptured and (not self._dstPort:isActive() or not shipOwner:canTrade(dstPortOwner)) then
		ship:delete(false)
		self._active = false
		return
	end

	local curTile = ship:tile()
	if self.wasCaptured and (shipOwner ~= dstPortOwner or not self._dstPort:isActive()) then
		local myComponent = mg:getWaterComponent(curTile)
		local nearestPort = Util.findClosestBy(shipOwner:units(UnitType.Port), function(p)
			return mg:manhattanDist(p:tile(), curTile)
		end, function(p)
			return p:isActive()
				and not p:isMarkedForDeletion()
				and not p:isUnderConstruction()
				and myComponent ~= nil
				and mg:hasWaterComponent(p:tile(), myComponent)
		end)
		if nearestPort == nil then
			ship:delete(false)
			self._active = false
			return
		end
		self._dstPort = nearestPort
		ship:setTargetUnit(nearestPort)
		ship:touch()
	end

	if curTile == self._dstPort:tile() then
		self:_complete()
		return
	end

	local dst = self._dstPort:tile()
	local result = self.pathFinder:next(curTile, dst)
	if result.status == PathStatus.NEXT then
		if mg:isWater(result.node) and mg:isShoreline(result.node) then
			ship:setSafeFromPirates()
		end
		ship:move(result.node)
		self.tilesTraveled += 1
	elseif result.status == PathStatus.COMPLETE then
		self:_complete()
	else
		warn("captured trade ship cannot find route")
		if ship:isActive() then
			ship:delete(false)
		end
		self._active = false
	end
end

function TradeShipExecution:_complete()
	local mg, ship = self.mg, self.tradeShip
	self._active = false
	ship:delete(false)
	local gold = mg:config():tradeShipGold(self.tilesTraveled, ship:owner())
	if self.wasCaptured and ship:owner() == self.origOwner then
		-- Retaken by its original owner: payout stands, nobody pirated it.
		self.origOwner:addGold(gold, self._dstPort:tile())
	elseif self.wasCaptured then
		ship:owner():addGold(gold, self._dstPort:tile())
		ship:owner():addPiracyGold(gold)
		mg:displayMessage(
			"events_display.received_gold_from_captured_ship",
			MessageType.CAPTURED_ENEMY_UNIT,
			ship:owner():id(),
			gold,
			{ gold = gold, name = self.origOwner:displayName() },
			nil,
			self.origOwner:id()
		)
		mg:stats():boatCapturedTrade(ship:owner(), self.origOwner, gold)
	else
		self.srcPort:owner():addGold(gold, self.srcPort:tile())
		self._dstPort:owner():addGold(gold, self._dstPort:tile())
		self.srcPort:owner():addTradeGold(gold)
		self._dstPort:owner():addTradeGold(gold)
		mg:stats():boatArriveTrade(self.srcPort:owner(), self._dstPort:owner(), gold)
	end
end

function TradeShipExecution:dstPort(): number
	return self._dstPort:tile()
end

function TradeShipExecution:isActive(): boolean
	return self._active
end

function TradeShipExecution:activeDuringSpawnPhase(): boolean
	return false
end

return TradeShipExecution
