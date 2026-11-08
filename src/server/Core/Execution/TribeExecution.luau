-- Port of OpenFrontIO src/core/execution/TribeExecution.ts (bot "tribes").

local Shared = game:GetService("ReplicatedStorage").Shared
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local AiAttackBehavior = require(script.Parent.AiAttackBehavior)
local StructureExecutions = require(script.Parent.StructureExecutions)

local Structures = GameTypes.Structures

local TribeExecution = {}
TribeExecution.__index = TribeExecution

function TribeExecution.new(tribe)
	local random = PseudoRandom.new(Util.simpleHash(tribe:id()))
	local self = setmetatable({
		_active = true,
		_random = random,
		_tribe = tribe,
		_neighborsTerraNullius = true,
		_attackBehavior = nil,
	}, TribeExecution)
	-- Draw order matters: identical to the upstream constructor.
	self._attackRate = random:nextInt(40, 80)
	self._attackTick = random:nextInt(0, self._attackRate)
	self._triggerRatio = random:nextInt(50, 60) / 100
	self._reserveRatio = random:nextInt(30, 40) / 100
	self._expandRatio = random:nextInt(10, 20) / 100
	return self
end

function TribeExecution:activeDuringSpawnPhase(): boolean
	return false
end

function TribeExecution:init(mg)
	self.mg = mg
end

function TribeExecution:tick(ticks: number)
	if ticks % self._attackRate ~= self._attackTick then
		return
	end

	if not self._tribe:isAlive() then
		-- removeOnDeath is called from the tribe's PlayerExecution
		self._active = false
		return
	end

	if self._attackBehavior == nil then
		self._attackBehavior = AiAttackBehavior.new(
			self._random,
			self.mg,
			self._tribe,
			self._triggerRatio,
			self._reserveRatio,
			self._expandRatio
		)
		-- Send an attack on the first tick
		self._attackBehavior:sendAttack(self.mg:terraNullius())
		return
	end

	self:_acceptAllAllianceRequests()
	self:_deleteNextStructure()
	self:_maybeAttack()
end

function TribeExecution:_acceptAllAllianceRequests()
	for _, req in self._tribe:incomingAllianceRequests() do
		req:accept()
	end
	for _, alliance in self._tribe:alliances() do
		if not alliance:onlyOneAgreedToExtend() then
			continue
		end
		local human = alliance:other(self._tribe)
		local AllianceExtensionExecution = require(script.Parent.SocialExecutions).AllianceExtensionExecution
		self.mg:addExecution(AllianceExtensionExecution.new(self._tribe, human:id()))
	end
end

function TribeExecution:_deleteNextStructure()
	if not self._tribe:canDeleteUnit() then
		return
	end
	for _, unit in self._tribe:units() do
		if not Structures.has(unit:type()) then
			continue
		end
		if unit:isMarkedForDeletion() then
			continue
		end
		self.mg:addExecution(StructureExecutions.DeleteUnitExecution.new(self._tribe, unit:id()))
		return
	end
end

function TribeExecution:_maybeAttack()
	local behavior = self._attackBehavior
	local tribe = self._tribe
	local toAttack = behavior:getNeighborTraitorToAttack()
	if toAttack ~= nil then
		local odds = if tribe:isFriendly(toAttack) then 6 else 3
		if self._random:chance(odds) then
			local alliance = tribe:allianceWith(toAttack)
			if alliance ~= nil then
				tribe:breakAlliance(alliance)
			end
			if behavior:sendAttack(toAttack) then
				return
			end
		end
	end

	if self._neighborsTerraNullius then
		local hasTN = false
		for _, n in tribe:nearby() do
			if not n:isPlayer() then
				hasTN = true
				break
			end
		end
		if hasTN then
			if behavior:sendAttack(self.mg:terraNullius()) then
				return
			end
		else
			self._neighborsTerraNullius = false
		end
	end

	behavior:attackRandomTarget()
end

function TribeExecution:isActive(): boolean
	return self._active
end

return TribeExecution
