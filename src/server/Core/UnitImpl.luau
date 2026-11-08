-- Port of OpenFrontIO src/core/game/UnitImpl.ts (and Veterancy.ts).
--
-- One class for every unit type (boats, warships, structures, nukes, trains);
-- per-type state lives in optional fields, exactly as upstream.
-- Health is a bigint upstream: integer-valued number here (toInt on writes).

local Util = require(game:GetService("ReplicatedStorage").Shared.Util)
local GameTypes = require(script.Parent.GameTypes)

local UnitType = GameTypes.UnitType
local MessageType = GameTypes.MessageType
local toInt, simpleHash = Util.toInt, Util.simpleHash

local function maxHealthWithVeterancy(base: number, veterancy: number, bonusPercent: number): number
	if veterancy <= 0 then
		return base
	end
	return base + math.floor((base * veterancy * bonusPercent) / 100)
end

local STAT_TYPES = {
	[UnitType.Warship] = true,
	[UnitType.Port] = true,
	[UnitType.MissileSilo] = true,
	[UnitType.DefensePost] = true,
	[UnitType.SAMLauncher] = true,
	[UnitType.City] = true,
	[UnitType.Factory] = true,
}

local function without(list, item)
	local out = {}
	for _, v in list do
		if v ~= item then
			table.insert(out, v)
		end
	end
	return out
end

local UnitImpl = {}
UnitImpl.__index = UnitImpl

-- Passed as a field value to updateWarshipState to set it to undefined
-- (JS spreads an explicit undefined; a Luau nil would mean "unchanged").
local NONE = table.freeze({})
UnitImpl.NONE = NONE

function UnitImpl.new(unitType: string, mg, tile: number, id: number, owner, params)
	params = params or {}
	local self = setmetatable({
		_type = unitType,
		mg = mg,
		_tile = tile,
		_lastTile = tile,
		_id = id,
		_owner = owner,
		_active = true,
		_health = toInt(mg:unitInfo(unitType).maxHealth or 1),
		_targetTile = params.targetTile,
		_targetPlayer = params.targetPlayer,
		_targetUnit = params.targetUnit,
		_troops = params.troops or 0,
		_lastSetSafeFromPirates = params.lastSetSafeFromPirates or 0,
		_reachedTarget = false,
		_wasDestroyedByEnemy = false,
		_destroyer = nil,
		_underConstruction = false,
		_lastOwner = nil,
		_missileTimerQueue = {},
		_hasTrainStation = false,
		_level = 1,
		_targetable = true,
		_loaded = params.loaded,
		_trainType = params.trainType,
		_deletionAt = nil,
		_transportShipState = nil,
		_warshipState = nil,
		_nukeState = nil,
		_samLauncherState = nil,
	}, UnitImpl)
	if params.trajectory ~= nil or params.waitTicks ~= nil then
		self._nukeState = { trajectory = params.trajectory or {}, waitTicks = 0, trajectoryIndex = 0, targetedBySam = false }
	end
	if unitType == UnitType.TransportShip then
		self._transportShipState = { isRetreating = false, troops = 0 }
	end
	if unitType == UnitType.SAMLauncher then
		self._samLauncherState = {
			startRange = mg:config():samRange(1),
			targetLevel = 1,
			duration = mg:config():samUpgradeDuration(),
		}
	end
	if params.patrolTile ~= nil then
		self._warshipState = {
			state = "patrolling",
			patrolTile = params.patrolTile,
			lastCombatTick = -100,
			veterancy = 0,
			veterancyProgress = 0,
		}
	end
	if STAT_TYPES[unitType] then
		mg:stats():unitBuild(owner, unitType)
	end
	return self
end

function UnitImpl:isUnit(): boolean
	return true
end
function UnitImpl:id(): number
	return self._id
end
function UnitImpl:type(): string
	return self._type
end
function UnitImpl:tile(): number
	return self._tile
end
function UnitImpl:lastTile(): number
	return self._lastTile
end
function UnitImpl:owner()
	return self._owner
end
function UnitImpl:info()
	return self.mg:unitInfo(self._type)
end
function UnitImpl:isActive(): boolean
	return self._active
end
function UnitImpl:__tostring(): string
	return `Unit:{self._type},owner:{self._owner:name()}`
end

-- Replication snapshot (upstream UnitUpdate, trimmed to what clients draw).
function UnitImpl:toUpdate()
	return {
		type = "Unit",
		unitType = self._type,
		id = self._id,
		troops = self._troops,
		ownerID = self._owner:smallID(),
		lastOwnerID = if self._lastOwner then self._lastOwner:smallID() else nil,
		isActive = self._active,
		reachedTarget = self._reachedTarget,
		pos = self._tile,
		lastPos = self._lastTile,
		targetTile = self._targetTile,
		isRetreating = if self._transportShipState then self._transportShipState.isRetreating else nil,
		health = if self:hasHealth() then self._health else nil,
		maxHealth = if self:hasHealth() then self:maxHealth() else nil, -- replication only
		underConstruction = self._underConstruction,
		level = self._level,
		markedForDeletion = self._deletionAt or false,
		targetable = self._targetable,
		-- replication only (UnitPass flags)
		targetUnitId = if self._targetUnit then self._targetUnit:id() else nil,
		warshipRetreating = if self._warshipState then self._warshipState.state ~= "patrolling" else nil,
		trainType = self._trainType,
		loaded = self._loaded,
		-- replication only: reload bars (launch ticks of missiles still reloading)
		missileTimers = if #self._missileTimerQueue > 0 then table.clone(self._missileTimerQueue) else nil,
		reloadTicks = if #self._missileTimerQueue == 0 then nil
			elseif self._type == "SAM Launcher" then self.mg:config():SAMCooldown()
			else self.mg:config():SiloCooldown(),
	}
end

function UnitImpl:touch()
	self.mg:addUpdate(self:toUpdate())
end

function UnitImpl:setTargetable(targetable: boolean)
	if self._targetable ~= targetable then
		self._targetable = targetable
		self.mg:addUpdate(self:toUpdate())
	end
end
function UnitImpl:isTargetable(): boolean
	return self._targetable
end

function UnitImpl:move(tile: number)
	if tile == nil then
		error("tile cannot be null")
	end
	self._lastTile = self._tile
	self._tile = tile
	self.mg:onUnitMoved(self)
end

function UnitImpl:setTroops(troops: number)
	local nextTroops = math.max(0, troops)
	if self._troops == nextTroops then
		return
	end
	self._troops = nextTroops
	self.mg:addUpdate(self:toUpdate())
end
function UnitImpl:troops(): number
	return self._troops
end

function UnitImpl:health(): number
	return self._health
end
function UnitImpl:hasHealth(): boolean
	return self:info().maxHealth ~= nil
end

function UnitImpl:setOwner(newOwner)
	self:clearPendingDeletion()
	local stats = self.mg:stats()
	if STAT_TYPES[self._type] then
		stats:unitCapture(newOwner, self._type)
		stats:unitLose(self._owner, self._type)
	elseif self._type == UnitType.TransportShip then
		stats:boatCapturedTroops(newOwner, self._owner)
	end
	self._lastOwner = self._owner
	self._lastOwner._units = without(self._lastOwner._units, self)
	self._lastOwner._myUnitsVersion += 1
	self._owner = newOwner
	table.insert(newOwner._units, self)
	newOwner._myUnitsVersion += 1
	self.mg:bumpUnitsVersion()
	self.mg:addUpdate(self:toUpdate())
end

function UnitImpl:veterancy(): number
	return if self._warshipState then self._warshipState.veterancy else 0
end

function UnitImpl:maxHealth(): number
	return maxHealthWithVeterancy(self:info().maxHealth or 1, self:veterancy(), self.mg:config():warshipVeterancyHealthBonus())
end

function UnitImpl:modifyHealth(delta: number, attacker)
	local previous = self._health
	local nextHealth = math.clamp(self._health + toInt(delta), 0, toInt(self:maxHealth()))
	if nextHealth == previous then
		return
	end
	if attacker ~= nil and delta < 0 and self._warshipState ~= nil then
		self._warshipState.lastCombatTick = self.mg:ticks()
	end
	self._health = nextHealth
	self.mg:addUpdate(self:toUpdate())
	if self._health == 0 then
		self:delete(true, attacker)
	end
end

function UnitImpl:clearPendingDeletion()
	self._deletionAt = nil
end
function UnitImpl:isMarkedForDeletion(): boolean
	return self._deletionAt ~= nil
end
function UnitImpl:markForDeletion()
	if not self:isActive() then
		return
	end
	self._deletionAt = self.mg:ticks() + self.mg:config():deletionMarkDuration()
	self.mg:addUpdate(self:toUpdate())
end
function UnitImpl:isOverdueDeletion(): boolean
	if not self:isActive() then
		return false
	end
	return self._deletionAt ~= nil and self.mg:ticks() - self._deletionAt > 0
end

function UnitImpl:delete(displayMessage: boolean?, destroyer)
	if not self:isActive() then
		error(`cannot delete {self} not active`)
	end
	self._wasDestroyedByEnemy = destroyer ~= nil
	self._destroyer = destroyer
	self._owner._units = without(self._owner._units, self)
	self._owner._myUnitsVersion += 1
	self._active = false
	self.mg:addUpdate(self:toUpdate())
	self.mg:removeUnit(self)
	if displayMessage ~= false then
		self:_displayMessageOnDeleted()
	end
	if destroyer ~= nil then
		local stats = self.mg:stats()
		if self._type == UnitType.TransportShip then
			stats:boatDestroyTroops(destroyer, self._owner, self._troops)
		elseif self._type == UnitType.TradeShip then
			stats:boatDestroyTrade(destroyer, self._owner)
		elseif STAT_TYPES[self._type] then
			stats:unitDestroy(destroyer, self._type)
			stats:unitLose(self._owner, self._type)
		end
	end
end

function UnitImpl:_displayMessageOnDeleted()
	if self._type ~= UnitType.Warship and self._type ~= UnitType.TransportShip then
		return
	end
	self.mg:displayMessage(
		"events_display.unit_destroyed",
		MessageType.UNIT_DESTROYED,
		self._owner:id(),
		nil,
		{ unit = if self._type == UnitType.TransportShip then "unit_type.boat" else "unit_type.warship" },
		self._id
	)
end

function UnitImpl:wasDestroyedByEnemy(): boolean
	return self._wasDestroyedByEnemy
end
function UnitImpl:destroyer()
	return self._destroyer
end

-- Warship state -----------------------------------------------------------------

function UnitImpl:isInCombat(): boolean
	return self.mg:ticks() - self._warshipState.lastCombatTick <= 3
end

function UnitImpl:warshipState()
	if self._warshipState == nil then
		error("warshipState called on non-warship unit")
	end
	self._warshipState.isInCombat = self:isInCombat()
	return self._warshipState
end

function UnitImpl:_markInCombat()
	local was = self:isInCombat()
	self._warshipState.lastCombatTick = self.mg:ticks()
	if not was then
		self.mg:addUpdate(self:toUpdate())
	end
end

function UnitImpl:updateWarshipState(update)
	local ws = self._warshipState
	if ws == nil then
		error("updateWarshipState called on non-warship unit")
	end
	if update.isInCombat then
		self:_markInCombat()
	end
	local function pick(v, old)
		if v == NONE then
			return nil
		end
		return if v ~= nil then v else old
	end
	local state = pick(update.state, ws.state)
	local patrolTile = pick(update.patrolTile, ws.patrolTile)
	local retreatPort = pick(update.retreatPort, ws.retreatPort)
	if state == ws.state and patrolTile == ws.patrolTile and retreatPort == ws.retreatPort then
		return
	end
	self._warshipState = {
		state = state,
		patrolTile = patrolTile,
		retreatPort = retreatPort,
		lastCombatTick = ws.lastCombatTick,
		veterancy = ws.veterancy,
		veterancyProgress = ws.veterancyProgress,
	}
	self.mg:addUpdate(self:toUpdate())
end

function UnitImpl:_increaseVeterancy()
	local ws = self._warshipState
	if ws == nil or ws.veterancy >= self.mg:config():warshipMaxVeterancy() then
		return
	end
	ws.veterancy += 1
	self.mg:addUpdate(self:toUpdate())
end

function UnitImpl:_addVeterancyProgress(source: string)
	local ws = self._warshipState
	if ws == nil then
		return
	end
	local config = self.mg:config()
	local maxVet = config:warshipMaxVeterancy()
	if ws.veterancy >= maxVet then
		return
	end
	local transportThreshold = config:warshipVeterancyTransportKills()
	local captureThreshold = config:warshipVeterancyTradeCaptures()
	local pointsPerLevel = transportThreshold * captureThreshold
	ws.veterancyProgress += if source == UnitType.TransportShip then captureThreshold else transportThreshold
	while ws.veterancyProgress >= pointsPerLevel and ws.veterancy < maxVet do
		ws.veterancyProgress -= pointsPerLevel
		self:_increaseVeterancy()
	end
	if ws.veterancy >= maxVet then
		ws.veterancyProgress = 0
	end
end

function UnitImpl:recordKill(targetType: string)
	if self._warshipState == nil then
		return
	end
	if targetType == UnitType.Warship then
		self._warshipState.veterancyProgress = 0
		self:_increaseVeterancy()
	elseif targetType == UnitType.TransportShip then
		self:_addVeterancyProgress(UnitType.TransportShip)
	end
end

function UnitImpl:recordTradeCapture()
	if self._warshipState ~= nil then
		self:_addVeterancyProgress(UnitType.TradeShip)
	end
end

-- Transport ship state ------------------------------------------------------------

function UnitImpl:transportShipState()
	if self._transportShipState == nil then
		error("transportShipState called on non-transport-ship unit")
	end
	return { isRetreating = self._transportShipState.isRetreating, troops = self._troops }
end

function UnitImpl:updateTransportShipState(update)
	if self._transportShipState == nil then
		error("updateTransportShipState called on non-transport-ship unit")
	end
	if update.isRetreating ~= nil and self._transportShipState.isRetreating ~= update.isRetreating then
		self._transportShipState = { isRetreating = update.isRetreating, troops = self._transportShipState.troops }
		self.mg:addUpdate(self:toUpdate())
	end
end

-- Nuke state ------------------------------------------------------------------------

function UnitImpl:nukeState()
	if self._nukeState == nil then
		error("nukeState called on non-nuke unit")
	end
	return self._nukeState
end

function UnitImpl:updateNukeState(update)
	local ns = self._nukeState
	if ns == nil then
		error("updateNukeState called on non-nuke unit")
	end
	local targetedBySam = if update.targetedBySam ~= nil then update.targetedBySam else ns.targetedBySam
	local trajectoryIndex = if update.trajectoryIndex ~= nil then update.trajectoryIndex else ns.trajectoryIndex
	local waitTicks = if update.waitTicks ~= nil then update.waitTicks else ns.waitTicks
	if targetedBySam == ns.targetedBySam and trajectoryIndex == ns.trajectoryIndex and waitTicks == ns.waitTicks then
		return
	end
	self._nukeState = {
		targetedBySam = targetedBySam,
		trajectoryIndex = trajectoryIndex,
		waitTicks = waitTicks,
		trajectory = ns.trajectory,
	}
	self.mg:addUpdate(self:toUpdate())
end

function UnitImpl:setTrajectoryIndex(i: number)
	if self._nukeState == nil then
		error("setTrajectoryIndex called on non-nuke unit")
	end
	local max = #self:trajectory() - 1
	self._nukeState.trajectoryIndex = if i < 0 then 0 elseif i > max then max else i
end
function UnitImpl:trajectoryIndex(): number
	return if self._nukeState then self._nukeState.trajectoryIndex else 0
end
function UnitImpl:trajectory()
	return if self._nukeState then self._nukeState.trajectory else {}
end
function UnitImpl:setTargetedBySAM(targeted: boolean)
	self._nukeState.targetedBySam = targeted
end
function UnitImpl:targetedBySAM(): boolean
	return self._nukeState.targetedBySam
end

-- Construction, levels, missiles ------------------------------------------------------

function UnitImpl:isUnderConstruction(): boolean
	return self._underConstruction
end

function UnitImpl:setUnderConstruction(underConstruction: boolean)
	if self._underConstruction ~= underConstruction then
		self._underConstruction = underConstruction
		self._owner._myUnitsVersion += 1
		self.mg:addUpdate(self:toUpdate())
	end
end

function UnitImpl:hash(): number
	return self:tile() + simpleHash(self:type()) * self._id
end

function UnitImpl:launch()
	table.insert(self._missileTimerQueue, self.mg:ticks())
	self.mg:addUpdate(self:toUpdate())
end
function UnitImpl:ticksLeftInCooldown(): number?
	return self._missileTimerQueue[1]
end
function UnitImpl:isInCooldown(): boolean
	return #self._missileTimerQueue == self._level
end
function UnitImpl:missileTimerQueue()
	return self._missileTimerQueue
end
function UnitImpl:samLauncherState()
	return self._samLauncherState
end
function UnitImpl:reloadMissile()
	table.remove(self._missileTimerQueue, 1)
	self.mg:addUpdate(self:toUpdate())
end

function UnitImpl:setTargetTile(targetTile: number?)
	self._targetTile = targetTile
end
function UnitImpl:targetTile(): number?
	return self._targetTile
end
function UnitImpl:targetPlayer()
	return self._targetPlayer
end
function UnitImpl:setTargetUnit(target)
	self._targetUnit = target
end
function UnitImpl:targetUnit()
	return self._targetUnit
end
function UnitImpl:setReachedTarget()
	self._reachedTarget = true
end
function UnitImpl:reachedTarget(): boolean
	return self._reachedTarget
end
function UnitImpl:setSafeFromPirates()
	self._lastSetSafeFromPirates = self.mg:ticks()
end
function UnitImpl:isSafeFromPirates(): boolean
	return self.mg:ticks() - self._lastSetSafeFromPirates < self.mg:config():safeFromPiratesCooldownMax()
end

function UnitImpl:level(): number
	return self._level
end

function UnitImpl:setTrainStation(trainStation: boolean)
	self._hasTrainStation = trainStation
	self.mg:addUpdate(self:toUpdate())
end
function UnitImpl:hasTrainStation(): boolean
	return self._hasTrainStation
end

local MISSILE_TYPES = { [UnitType.MissileSilo] = true, [UnitType.SAMLauncher] = true }

function UnitImpl:increaseLevel()
	if self._type == UnitType.SAMLauncher then
		local currentTick = self.mg:ticks()
		local currentRange = self.mg:config():dynamicSamRange(self, currentTick)
		self._samLauncherState = {
			upgradeStartTick = currentTick,
			startRange = currentRange,
			targetLevel = self._level + 1,
			duration = self.mg:config():samUpgradeDuration(),
		}
	end
	self._level += 1
	self.mg:bumpUnitsVersion()
	self._owner._myUnitsVersion += 1
	if MISSILE_TYPES[self._type] then
		table.insert(self._missileTimerQueue, self.mg:ticks())
	end
	self.mg:addUpdate(self:toUpdate())
end

function UnitImpl:decreaseLevel(destroyer)
	self._level -= 1
	if MISSILE_TYPES[self._type] then
		table.remove(self._missileTimerQueue)
	end
	if self._type == UnitType.SAMLauncher then
		self._samLauncherState = nil
	end
	if self._level <= 0 then
		self:delete(true, destroyer)
		return
	end
	self.mg:bumpUnitsVersion()
	self._owner._myUnitsVersion += 1
	self.mg:addUpdate(self:toUpdate())
end

function UnitImpl:trainType()
	return self._trainType
end
function UnitImpl:isLoaded(): boolean?
	return self._loaded
end
function UnitImpl:setLoaded(loaded: boolean)
	if self._loaded ~= loaded then
		self._loaded = loaded
		self.mg:addUpdate(self:toUpdate())
	end
end

return UnitImpl
