-- Ports of small OpenFrontIO structure executions:
--   CityExecution.ts, MissileSiloExecution.ts, DefensePostExecution.ts,
--   UpgradeStructureExecution.ts, DeleteUnitExecution.ts.

local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)

local UnitType = GameTypes.UnitType
local MessageType = GameTypes.MessageType

local StructureExecutions = {}

local function base(class)
	class.__index = class
	class.activeDuringSpawnPhase = function()
		return false
	end
	return class
end

-- CityExecution: joins the rail network when a factory is in range.
local City = base({})
function City.new(city)
	return setmetatable({ city = city, _active = true, _stationCreated = false }, City)
end
function City:init(mg)
	self.mg = mg
end
function City:tick()
	if not self._stationCreated then
		local nearbyFactory = self.mg:hasUnitNearby(self.city:tile(), self.mg:config():trainStationMaxRange(), UnitType.Factory)
		if nearbyFactory then
			local TrainStationExecution = require(script.Parent.TrainExecutions).TrainStationExecution
			self.mg:addExecution(TrainStationExecution.new(self.city))
		end
		self._stationCreated = true
	end
	if not self.city:isActive() then
		self._active = false
	end
end
function City:isActive(): boolean
	return self._active
end
StructureExecutions.CityExecution = City

-- MissileSiloExecution: reloads missiles after SiloCooldown ticks.
local Silo = base({})
function Silo.new(silo)
	return setmetatable({ silo = silo, _active = true }, Silo)
end
function Silo:init(mg)
	self.mg = mg
end
function Silo:tick()
	if self.silo:isUnderConstruction() then
		return
	end
	if not self.silo:isActive() then
		self._active = false
		return
	end
	local frontTime = self.silo:missileTimerQueue()[1]
	if frontTime == nil then
		return
	end
	if self.mg:config():SiloCooldown() - (self.mg:ticks() - frontTime) <= 0 then
		self.silo:reloadMissile()
	end
end
function Silo:isActive(): boolean
	return self._active
end
StructureExecutions.MissileSiloExecution = Silo

-- DefensePostExecution: upstream's shell targeting is commented out; posts
-- work through the attack defence bonus (Config.attackLogic) only.
local DefensePost = base({})
function DefensePost.new(post)
	return setmetatable({ post = post, _active = true }, DefensePost)
end
function DefensePost:init(mg)
	self.mg = mg
end
function DefensePost:tick()
	if not self.post:isActive() then
		self._active = false
	end
end
function DefensePost:isActive(): boolean
	return self._active
end
StructureExecutions.DefensePostExecution = DefensePost

-- UpgradeStructureExecution: upgrade one of the player's structures up to
-- `amount` times, all during init.
local Upgrade = base({})
function Upgrade.new(player, unitId: number, amount: number?)
	return setmetatable({ player = player, unitId = unitId, amount = amount or 1 }, Upgrade)
end
function Upgrade:init(mg)
	local structure = mg:unit(self.unitId)
	if structure and structure:owner() ~= self.player then
		warn("structure not owned by player")
		structure = nil
	end
	if structure == nil then
		warn("structure is undefined")
		return
	end
	for i = 1, self.amount do
		if not self.player:canUpgradeUnit(structure) then
			if i == 1 then
				warn(`[UpgradeStructureExecution] unit type {structure:type()} cannot be upgraded`)
			end
			break
		end
		self.player:upgradeUnit(structure)
	end
end
function Upgrade:tick() end
function Upgrade:isActive(): boolean
	return false
end
StructureExecutions.UpgradeStructureExecution = Upgrade

-- DeleteUnitExecution: mark an own structure for deletion; it is removed
-- once the deletion mark expires.
local Delete = base({})
function Delete.new(player, unitId: number)
	return setmetatable({ player = player, unitId = unitId, _active = true, unit = nil }, Delete)
end
function Delete:init(mg)
	if not self._active then
		return
	end
	self.mg = mg
	local player = self.player
	local unit = mg:unit(self.unitId)
	if not unit or unit:owner() ~= player then
		warn(`SECURITY: unit {self.unitId} not found or not owned by player {player:displayName()}`)
		self._active = false
		return
	end
	if not unit:isActive() then
		self._active = false
		return
	end
	self.unit = unit
	local tileOwner = mg:owner(unit:tile())
	if not tileOwner:isPlayer() or tileOwner:id() ~= player:id() then
		self._active = false
		return
	end
	if not mg:isLand(unit:tile()) then
		self._active = false
		return
	end
	if mg:inSpawnPhase() then
		self._active = false
		return
	end
	if not player:canDeleteUnit() then
		self._active = false
		return
	end
	player:recordDeleteUnit()
	unit:markForDeletion()
end
function Delete:tick()
	if not self._active or not self.unit then
		return
	end
	if not self.unit:isActive() then
		self._active = false
		return
	end
	if self.unit:isOverdueDeletion() then
		self.unit:delete(false)
		self.mg:displayMessage("events_display.unit_voluntarily_deleted", MessageType.UNIT_DESTROYED, self.player:id())
		self._active = false
	end
end
function Delete:isActive(): boolean
	return self._active
end
StructureExecutions.DeleteUnitExecution = Delete

return StructureExecutions
