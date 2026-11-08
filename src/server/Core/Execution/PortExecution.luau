-- Port of OpenFrontIO src/core/execution/PortExecution.ts.
-- Every 10 ticks a finished port may launch a trade ship to a random trading
-- partner's port (closer / friendly ports weighted more).

local Shared = game:GetService("ReplicatedStorage").Shared
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)

local UnitType = GameTypes.UnitType

local PortExecution = {}
PortExecution.__index = PortExecution

function PortExecution.new(port)
	return setmetatable({ port = port, _active = true, _rejections = 0 }, PortExecution)
end

function PortExecution:init(mg)
	self.mg = mg
	self.random = PseudoRandom.new(mg:ticks())
	self.checkOffset = mg:ticks() % 10
end

function PortExecution:tick()
	local mg, port = self.mg, self.port
	if not port:isActive() then
		self._active = false
		return
	end
	if port:isUnderConstruction() then
		return
	end
	if not port:hasTrainStation() then
		local nearbyFactory = mg:hasUnitNearby(port:tile(), mg:config():trainStationMaxRange(), UnitType.Factory)
		if nearbyFactory then
			local TrainStationExecution = require(script.Parent.TrainExecutions).TrainStationExecution
			mg:addExecution(TrainStationExecution.new(port))
		end
	end
	if (mg:ticks() + self.checkOffset) % 10 ~= 0 then
		return
	end
	if not self:shouldSpawnTradeShip() then
		return
	end
	local ports = self:tradingPorts()
	if #ports == 0 then
		return
	end
	local dst = self.random:randElement(ports)
	local TradeShipExecution = require(script.Parent.TradeShipExecution)
	mg:addExecution(TradeShipExecution.new(port:owner(), port, dst))
end

function PortExecution:shouldSpawnTradeShip(): boolean
	local numTradeShips = self.mg:unitCount(UnitType.TradeShip)
	for _ = 1, self.port:level() do
		local spawnRate = self.mg:config():tradeShipSpawnRate(self._rejections, numTradeShips)
		if self.random:chance(spawnRate) then
			self._rejections = 0
			return true
		end
		self._rejections += 1
	end
	return false
end

-- Probability list: a port appearing twice is twice as likely to be picked.
function PortExecution:tradingPorts()
	local mg, port = self.mg, self.port
	local owner = port:owner()
	local sourceComponents = {}
	for _, n in mg:neighbors(port:tile()) do
		if mg:isWater(n) then
			local comp = mg:getWaterComponent(n)
			if comp ~= nil and not table.find(sourceComponents, comp) then
				table.insert(sourceComponents, comp)
			end
		end
	end
	local ports = {}
	for _, p in mg:players() do
		if p ~= owner and p:canTrade(owner) then
			for _, other in p:units(UnitType.Port) do
				for _, comp in sourceComponents do
					if mg:hasWaterComponent(other:tile(), comp) then
						table.insert(ports, other)
						break
					end
				end
			end
		end
	end
	Util.sort(ports, function(a, b)
		return mg:manhattanDist(port:tile(), a:tile()) - mg:manhattanDist(port:tile(), b:tile())
	end)
	local config = mg:config()
	local weighted = {}
	local bonusCount = config:proximityBonusPortsNb(#ports)
	for i, other in ports do
		local copies = other:level()
		local function push()
			for _ = 1, copies do
				table.insert(weighted, other)
			end
		end
		push()
		local tooClose = mg:manhattanDist(port:tile(), other:tile()) < config:tradeShipShortRangeDebuff()
		local closeBonus = (i - 1) < bonusCount -- upstream index is 0-based
		if not tooClose and closeBonus then
			push()
		end
		if not tooClose and owner:isFriendly(other:owner()) then
			push()
		end
	end
	return weighted
end

function PortExecution:isActive(): boolean
	return self._active
end

function PortExecution:activeDuringSpawnPhase(): boolean
	return false
end

return PortExecution
