-- Port of OpenFrontIO src/core/execution/WarshipExecution.ts,
-- ShellExecution.ts and MoveWarshipExecution.ts.
-- A warship patrols around its patrol tile, shoots transport ships and enemy
-- warships (shells), hunts and captures trade ships, heals near its ports and
-- retreats to dock for repairs when badly damaged.

local Shared = game:GetService("ReplicatedStorage").Shared
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local UnitImpl = require(Core.UnitImpl)
local PathFinderMod = require(Core.Pathfinding.PathFinder)

local UnitType = GameTypes.UnitType
local PathStatus = PathFinderMod.PathStatus
local WaterPathFinder = PathFinderMod.WaterPathFinder
local NONE = UnitImpl.NONE

local function jsRound(x: number): number
	return math.floor(x + 0.5)
end

-- ShellExecution ---------------------------------------------------------------------

local ShellExecution = {}
ShellExecution.__index = ShellExecution

function ShellExecution.new(spawn: number, owner, ownerUnit, target)
	return setmetatable({
		spawn = spawn,
		_owner = owner,
		ownerUnit = ownerUnit,
		target = target,
		_active = true,
		shell = nil,
		destroyAtTick = -1,
	}, ShellExecution)
end

function ShellExecution:init(mg, _ticks: number)
	self.pathFinder = PathFinderMod.Air(mg)
	self.mg = mg
	self.random = PseudoRandom.new(mg:ticks())
end

function ShellExecution:tick(_ticks: number)
	local mg = self.mg
	if self.shell == nil then
		self.shell = self._owner:buildUnit(UnitType.Shell, self.spawn, {})
	end
	local shell = self.shell
	if not shell:isActive() then
		self._active = false
		return
	end
	if not self.target:isActive() or self.target:owner() == shell:owner() or (self.destroyAtTick ~= -1 and mg:ticks() >= self.destroyAtTick) then
		shell:delete(false)
		self._active = false
		return
	end
	if self.destroyAtTick == -1 and not self.ownerUnit:isActive() then
		self.destroyAtTick = mg:ticks() + mg:config():shellLifetime()
	end
	for _ = 1, 3 do
		local result = self.pathFinder:next(shell:tile(), self.target:tile())
		if result.status == PathStatus.COMPLETE then
			self._active = false
			local targetType = self.target:type()
			local targetWasActive = self.target:isActive()
			self.target:modifyHealth(-self:_effectOnTarget(), self._owner)
			-- Veterancy for the warship that landed the killing blow.
			if targetWasActive and not self.target:isActive() and self.ownerUnit:isActive() and self.ownerUnit:type() == UnitType.Warship then
				self.ownerUnit:recordKill(targetType)
			end
			shell:setReachedTarget()
			shell:delete(false)
			return
		elseif result.status == PathStatus.NEXT then
			shell:move(result.node)
		end
	end
end

function ShellExecution:_effectOnTarget(): number
	local damage = self.mg:config():unitInfo(UnitType.Shell).damage
	local baseDamage = damage or 250
	local roll = self.random:nextInt(1, 6)
	local damageMultiplier = (roll - 1) * 25 + 200
	local veterancy = self.ownerUnit:veterancy()
	if veterancy > 0 then
		local bonusPercent = self.mg:config():warshipVeterancyShellDamageBonus()
		damageMultiplier = math.floor((damageMultiplier * (100 + veterancy * bonusPercent)) / 100)
	end
	return jsRound((baseDamage / 250) * damageMultiplier)
end

function ShellExecution:isActive(): boolean
	return self._active
end

function ShellExecution:activeDuringSpawnPhase(): boolean
	return false
end

-- MoveWarshipExecution ------------------------------------------------------------------

local MoveWarshipExecution = {}
MoveWarshipExecution.__index = MoveWarshipExecution

function MoveWarshipExecution.new(owner, unitIds: { number }, position: number)
	return setmetatable({ owner = owner, unitIds = unitIds, position = position }, MoveWarshipExecution)
end

function MoveWarshipExecution:init(mg, _ticks: number)
	if not mg:isValidRef(self.position) then
		warn(`MoveWarshipExecution: position {self.position} not valid`)
		return
	end
	local newComponent = mg:getWaterComponent(self.position)
	local byId = {}
	for _, u in self.owner:units(UnitType.Warship) do
		byId[u:id()] = u
	end
	local seen = {}
	for _, unitId in self.unitIds do
		if seen[unitId] then
			continue
		end
		seen[unitId] = true
		local warship = byId[unitId]
		if not warship then
			warn(`MoveWarshipExecution: warship {unitId} not found`)
			continue
		end
		if not warship:isActive() then
			continue
		end
		-- Stay in the same water body.
		if not mg:hasWaterComponent(warship:tile(), newComponent) then
			continue
		end
		warship:updateWarshipState({ patrolTile = self.position })
		-- Roblox port: sail to the clicked tile itself first (upstream only moves
		-- the patrol area, so the ship wandered to a random tile nearby and
		-- players felt it ignored orders); patrol around it after arriving.
		warship:setTargetTile(self.position)
		warship._manualMove = true
	end
end

function MoveWarshipExecution:tick(_ticks: number) end

function MoveWarshipExecution:isActive(): boolean
	return false
end

function MoveWarshipExecution:activeDuringSpawnPhase(): boolean
	return false
end

-- WarshipExecution -----------------------------------------------------------------------

local WarshipExecution = {}
WarshipExecution.__index = WarshipExecution

-- input: an existing warship unit, or { owner, patrolTile }.
function WarshipExecution.new(input)
	return setmetatable({
		input = input,
		warship = nil,
		lastShellAttack = 0,
		alreadySentShell = {}, -- unit -> true
		lastManualMoveTickRetreatDisabled = 0,
		lastObservedPatrolTile = nil,
		activeHealingRemainder = 0,
		lastEmittedCombat = false,
	}, WarshipExecution)
end

function WarshipExecution:init(mg, _ticks: number)
	self.mg = mg
	self.pathfinder = WaterPathFinder.new(mg)
	self.random = PseudoRandom.new(mg:ticks())
	if type(self.input) == "table" and self.input.isUnit then
		self.warship = self.input
	else
		local owner = self.input.owner
		local spawn = owner:canBuild(UnitType.Warship, self.input.patrolTile)
		if spawn == false then
			warn(`Failed to spawn warship for {owner:name()} at {self.input.patrolTile}`)
			return
		end
		self.warship = owner:buildUnit(UnitType.Warship, spawn, { patrolTile = self.input.patrolTile })
	end
	self.lastObservedPatrolTile = self.warship:warshipState().patrolTile
end

function WarshipExecution:tick(_ticks: number)
	local warship = self.warship
	if warship:health() <= 0 then
		warship:delete()
		return
	end
	local isInCombat = warship:warshipState().isInCombat or false
	if self.lastEmittedCombat and not isInCombat then
		warship:touch()
	end
	self.lastEmittedCombat = isInCombat
	local healthBeforeHealing = warship:health()

	self:_healWarship()
	self:_handleManualPatrolOverride()

	-- A doomed side cannot repair; keep patrolling.
	if warship:owner():inDoomsdayClock() and warship:warshipState().state ~= "patrolling" then
		self:_cancelRepairRetreat()
	end

	if warship:warshipState().state == "docked" then
		if self:_currentRetreatPort() == nil then
			self:_cancelRepairRetreat()
		end
		if self:_isFullyHealed() then
			self:_cancelRepairRetreat()
		end
		if warship:warshipState().state == "docked" then
			return
		end
	end

	if self:_handleRepairRetreat() then
		return
	end

	if self:_shouldStartRepairRetreat(healthBeforeHealing) then
		self:_startRepairRetreat()
		if self:_handleRepairRetreat() then
			return
		end
	end

	warship:setTargetUnit(self:_findTargetUnit())
	local target = warship:targetUnit()
	local ttype = target and target:type()

	-- Priority 1: transport ships, 2: enemy warships (shoot while patrolling).
	if ttype == UnitType.TransportShip or ttype == UnitType.Warship then
		self:_shootTarget()
		self:_patrol()
		return
	end
	-- Priority 3: hunt trade ships (not while following a player order).
	if ttype == UnitType.TradeShip and not warship._manualMove then
		self:_huntDownTradeShip()
		return
	end
	self:_patrol()
end

function WarshipExecution:_healWarship()
	local mg, warship = self.mg, self.warship
	local owner = warship:owner()
	if owner:inDoomsdayClock() then
		return
	end
	local passiveHealing = mg:config():warshipPassiveHealing()
	local range = mg:config():warshipPassiveHealingRange()
	local range2 = range * range
	local tile = warship:tile()
	local isNearPort = false
	for _, port in owner:units(UnitType.Port) do
		if mg:euclideanDistSquared(tile, port:tile()) <= range2 then
			isNearPort = true
			break
		end
	end
	if isNearPort then
		warship:modifyHealth(passiveHealing)
	end
	if warship:warshipState().state == "docked" then
		self:_applyActiveDockedHealing()
	end
end

function WarshipExecution:_isFullyHealed(): boolean
	local warship = self.warship
	if not warship:hasHealth() then
		return true
	end
	return warship:health() >= warship:maxHealth()
end

function WarshipExecution:_shouldStartRepairRetreat(healthBeforeHealing: number): boolean
	local mg, warship = self.mg, self.warship
	if warship:warshipState().state ~= "patrolling" then
		return false
	end
	if warship:owner():inDoomsdayClock() then
		return false
	end
	if mg:ticks() - self.lastManualMoveTickRetreatDisabled < 50 then
		return false
	end
	local threshold = math.floor((warship:maxHealth() * mg:config():warshipRetreatHealthPercent()) / 100)
	if healthBeforeHealing >= threshold then
		return false
	end
	return #warship:owner():units(UnitType.Port) > 0
end

function WarshipExecution:_findNearestPort(): number?
	local mg, warship = self.mg, self.warship
	local ports = warship:owner():units(UnitType.Port)
	if #ports == 0 then
		return nil
	end
	local tile = warship:tile()
	local component = mg:getWaterComponent(tile)
	if component == nil then
		error(`Warship at tile {tile} has no water component`)
	end
	local nearest = Util.findClosestBy(ports, function(port)
		return mg:euclideanDistSquared(tile, port:tile())
	end, function(port)
		local pc = mg:getWaterComponent(port:tile())
		if pc == nil then
			error(`Port at tile {port:tile()} has no water component`)
		end
		return pc == component
	end)
	return nearest and nearest:tile()
end

function WarshipExecution:_findRetreatAggroTarget()
	return self:_findBestTarget({ UnitType.TransportShip, UnitType.Warship }, false)
end

function WarshipExecution:_findTargetUnit()
	return self:_findBestTarget({ UnitType.TransportShip, UnitType.Warship, UnitType.TradeShip }, true)
end

-- Best target by type priority (transport < warship < trade ship), then distance.
function WarshipExecution:_findBestTarget(types, includeTradeShips: boolean)
	local mg, warship = self.mg, self.warship
	local config = mg:config()
	local owner = warship:owner()
	local ships = mg:nearbyUnits(warship:tile(), config:warshipTargettingRange(), types)

	local lazyDone = false
	local hasReachablePort, patrolTile, patrolRangeSquared = false, nil, 0

	local bestUnit, bestPriority, bestDist = nil, 0, 0
	for _, e in ships do
		local unit, distSquared = e.unit, e.distSquared
		if
			unit == warship
			or unit:owner() == owner
			or not owner:canAttackPlayer(unit:owner(), true)
			or self.alreadySentShell[unit]
			or (unit:type() == UnitType.Warship and unit:warshipState().state == "docked")
		then
			continue
		end
		local utype = unit:type()
		if includeTradeShips and utype == UnitType.TradeShip then
			if not lazyDone then
				lazyDone = true
				local component = mg:getWaterComponent(warship:tile())
				hasReachablePort = false
				if component ~= nil then
					for _, port in owner:units(UnitType.Port) do
						if port:isActive() and not port:isMarkedForDeletion() and not port:isUnderConstruction() and mg:hasWaterComponent(port:tile(), component) then
							hasReachablePort = true
							break
						end
					end
				end
				patrolTile = warship:warshipState().patrolTile
				patrolRangeSquared = config:warshipPatrolRange() ^ 2
			end
			local tu = unit:targetUnit()
			if not hasReachablePort or patrolTile == nil or unit:isSafeFromPirates() or (tu ~= nil and (tu:owner() == owner or tu:owner():isFriendly(owner))) then
				continue
			end
			if mg:euclideanDistSquared(patrolTile, unit:tile()) > patrolRangeSquared then
				continue
			end
		end
		local priority = if utype == UnitType.TransportShip then 0 elseif utype == UnitType.Warship then 1 else 2
		if bestUnit == nil or priority < bestPriority or (priority == bestPriority and distSquared < bestDist) then
			bestUnit, bestPriority, bestDist = unit, priority, distSquared
		end
	end
	return bestUnit
end

function WarshipExecution:_startRepairRetreat()
	local portTile = self:_findNearestPort()
	if portTile == nil then
		return
	end
	self.warship:updateWarshipState({ retreatPort = portTile, state = "retreating" })
	self.activeHealingRemainder = 0
	self.warship:setTargetUnit(nil)
end

function WarshipExecution:_cancelRepairRetreat(clearTargetTile: boolean?)
	self.activeHealingRemainder = 0
	self.warship:updateWarshipState({ state = "patrolling", retreatPort = NONE })
	if clearTargetTile ~= false then
		self.warship:setTargetTile(nil)
	end
end

function WarshipExecution:_handleManualPatrolOverride()
	local warship = self.warship
	local patrolTile = warship:warshipState().patrolTile
	if self.lastObservedPatrolTile ~= nil and patrolTile ~= self.lastObservedPatrolTile then
		self.lastManualMoveTickRetreatDisabled = self.mg:ticks()
		if warship:warshipState().state ~= "patrolling" then
			self:_cancelRepairRetreat(false)
		end
	end
	self.lastObservedPatrolTile = patrolTile
end

function WarshipExecution:_portAt(tile: number)
	for _, p in self.warship:owner():units(UnitType.Port) do
		if p:tile() == tile then
			return p
		end
	end
	return nil
end

function WarshipExecution:_handleRepairRetreat(): boolean
	local mg, warship = self.mg, self.warship
	if warship:warshipState().state == "patrolling" then
		return false
	end
	local aggro = self:_findRetreatAggroTarget()
	if aggro then
		warship:setTargetUnit(aggro)
		self:_shootTarget()
	end
	if not self:_refreshRetreatPortTile() then
		self:_cancelRepairRetreat()
		return false
	end
	if not aggro then
		warship:setTargetUnit(nil)
	end
	local retreatPortTile = warship:warshipState().retreatPort
	if retreatPortTile == nil then
		return false
	end
	local dockingRadius = mg:config():warshipDockingRange()
	if mg:euclideanDistSquared(warship:tile(), retreatPortTile) <= dockingRadius * dockingRadius then
		local port = self:_portAt(retreatPortTile)
		if port and not self:_isPortFullOfHealing(port, warship) then
			warship:setTargetTile(nil)
			warship:updateWarshipState({ state = "docked" })
			return true
		end
		-- Port full: wait near it, unless already healed.
		if self:_isFullyHealed() then
			self:_cancelRepairRetreat()
			return false
		end
		return true
	end

	warship:setTargetTile(retreatPortTile)
	local result = self.pathfinder:next(warship:tile(), retreatPortTile)
	if result.status == PathStatus.COMPLETE then
		warship:move(result.node)
		if result.node == retreatPortTile then
			warship:setTargetTile(nil)
		end
	elseif result.status == PathStatus.NEXT then
		warship:move(result.node)
	elseif result.status == PathStatus.NOT_FOUND then
		local newPort = self:_findNearestAvailablePortTile()
		warship:updateWarshipState({ retreatPort = if newPort == nil then NONE else newPort })
		if newPort == nil then
			self:_cancelRepairRetreat()
		end
	end
	return true
end

function WarshipExecution:_refreshRetreatPortTile(): boolean
	local warship = self.warship
	local ports = warship:owner():units(UnitType.Port)
	if #ports == 0 then
		return false
	end
	local current = warship:warshipState().retreatPort
	local currentPort = if current ~= nil then self:_portAt(current) else nil
	if currentPort == nil then
		local newPort = self:_findNearestAvailablePortTile()
		warship:updateWarshipState({ retreatPort = if newPort == nil then NONE else newPort })
		return newPort ~= nil
	end
	if self:_isPortFullOfHealing(currentPort) then
		local alternative = self:_findNearestAvailablePort()
		if alternative then
			warship:updateWarshipState({ retreatPort = alternative })
		end
		return warship:warshipState().retreatPort ~= nil
	end
	local closer = self:_findBetterPortTile()
	if closer and closer ~= current then
		warship:updateWarshipState({ retreatPort = closer })
		return true
	end
	return true
end

function WarshipExecution:_isPortFullOfHealing(port, excludeShip): boolean
	return #self:_dockedShipsAtPort(port, excludeShip) >= port:level()
end

function WarshipExecution:_dockedShipsAtPort(port, excludeShip)
	local mg = self.mg
	local owner = self.warship:owner()
	local out = {}
	for _, e in mg:nearbyUnits(port:tile(), mg:config():warshipDockingRange(), { UnitType.Warship }) do
		local ship = e.unit
		if excludeShip and ship == excludeShip then
			continue
		end
		if ship:owner() ~= owner or ship:warshipState().state == "patrolling" or ship:targetTile() ~= nil then
			continue
		end
		table.insert(out, ship)
	end
	return out
end

function WarshipExecution:_applyActiveDockedHealing()
	local dockedPort = self:_currentRetreatPort()
	if not dockedPort then
		return
	end
	local dockedShips = self:_dockedShipsAtPort(dockedPort)
	if not table.find(dockedShips, self.warship) then
		return
	end
	local healingPool = dockedPort:level() * self.mg:config():warshipPortHealingBonusPerLevel()
	if healingPool <= 0 or #dockedShips == 0 then
		return
	end
	-- Fractional split healing carried over with a per-ship remainder.
	self.activeHealingRemainder += healingPool / #dockedShips
	local integerHealing = math.floor(self.activeHealingRemainder)
	if integerHealing <= 0 then
		return
	end
	self.activeHealingRemainder -= integerHealing
	self.warship:modifyHealth(integerHealing)
end

function WarshipExecution:_currentRetreatPort()
	local retreatPort = self.warship:warshipState().retreatPort
	if retreatPort == nil then
		return nil
	end
	return self:_portAt(retreatPort)
end

function WarshipExecution:_nearestAvailablePortTile(excludeShip)
	local mg, warship = self.mg, self.warship
	local tile = warship:tile()
	local component = mg:getWaterComponent(tile)
	if component == nil then
		error(`Warship at tile {tile} has no water component`)
	end
	local bestTile, bestDistance = nil, math.huge
	for _, port in warship:owner():units(UnitType.Port) do
		if self:_isPortFullOfHealing(port, excludeShip) then
			continue
		end
		local portTile = port:tile()
		if not mg:hasWaterComponent(portTile, component) then
			continue
		end
		local d = mg:euclideanDistSquared(tile, portTile)
		if d < bestDistance then
			bestDistance = d
			bestTile = portTile
		end
	end
	return bestTile, bestDistance
end

function WarshipExecution:_findNearestAvailablePort(): number?
	return (self:_nearestAvailablePortTile(nil))
end

function WarshipExecution:_findBetterPortTile(): number?
	local tile, dist = self:_nearestAvailablePortTile(nil)
	if tile == nil then
		return nil
	end
	local currentDistance = math.huge
	local current = self.warship:warshipState().retreatPort
	if current ~= nil then
		currentDistance = self.mg:euclideanDistSquared(self.warship:tile(), current)
	end
	if dist < currentDistance * self.mg:config():warshipPortSwitchThreshold() then
		return tile
	end
	return nil
end

function WarshipExecution:_findNearestAvailablePortTile(): number?
	return (self:_nearestAvailablePortTile(self.warship))
end

function WarshipExecution:_shootTarget()
	local mg, warship = self.mg, self.warship
	warship:updateWarshipState({ isInCombat = true })
	local rate = mg:config():warshipShellAttackRate()
	if mg:ticks() - self.lastShellAttack > rate then
		local target = warship:targetUnit()
		if target:type() ~= UnitType.TransportShip then
			-- No reload against transport ships.
			self.lastShellAttack = mg:ticks()
		end
		mg:addExecution(ShellExecution.new(warship:tile(), warship:owner(), warship, target))
		if not target:hasHealth() then
			-- One shell is enough for targets without health.
			self.alreadySentShell[target] = true
			warship:setTargetUnit(nil)
			return
		end
	end
end

function WarshipExecution:_captureTarget(target)
	local warship = self.warship
	warship:owner():captureUnit(target)
	warship:recordTradeCapture()
	warship:setTargetUnit(nil)
	warship:touch()
end

function WarshipExecution:_huntDownTradeShip()
	local mg, warship = self.mg, self.warship
	warship:updateWarshipState({ isInCombat = true })
	for _ = 1, 2 do
		local target = warship:targetUnit()
		local targetTile = target:tile()
		local dist = mg:manhattanDist(warship:tile(), targetTile)
		if dist <= 5 then
			self:_captureTarget(target)
			return
		end
		-- Close in greedily: minimap paths zig-zag at short range.
		if dist <= 20 then
			local nextTile = self:_bestNeighborToward(targetTile)
			if nextTile ~= nil then
				warship:move(nextTile)
				continue
			end
		end
		local result = self.pathfinder:next(warship:tile(), targetTile, 5)
		if result.status == PathStatus.COMPLETE then
			self:_captureTarget(target)
			return
		elseif result.status == PathStatus.NEXT then
			warship:move(result.node)
		end
	end
end

function WarshipExecution:_bestNeighborToward(targetTile: number): number?
	local mg = self.mg
	local tile = self.warship:tile()
	local best = nil
	local bestDist = mg:manhattanDist(tile, targetTile)
	mg:forEachNeighbor(tile, function(n)
		if not mg:isWater(n) then
			return
		end
		local d = mg:manhattanDist(n, targetTile)
		if d < bestDist then
			bestDist = d
			best = n
		end
	end)
	return best
end

function WarshipExecution:_patrol()
	local warship = self.warship
	if warship:targetTile() == nil then
		warship:setTargetTile(self:randomTile(false))
		if warship:targetTile() == nil then
			return
		end
	end
	local result = self.pathfinder:next(warship:tile(), warship:targetTile())
	if result.status == PathStatus.COMPLETE then
		warship:setTargetTile(nil)
		warship._manualMove = nil
		warship:move(result.node)
	elseif result.status == PathStatus.NEXT then
		warship:move(result.node)
		-- Roblox port: warships sail 2 tiles per tick (upstream 1) so they
		-- answer move orders faster.
		local second = self.pathfinder:next(warship:tile(), warship:targetTile())
		if second.status == PathStatus.COMPLETE then
			warship:setTargetTile(nil)
			warship._manualMove = nil
			warship:move(second.node)
		elseif second.status == PathStatus.NEXT then
			warship:move(second.node)
		end
	elseif result.status == PathStatus.NOT_FOUND then
		warship:setTargetTile(nil)
		warship._manualMove = nil
	end
end

function WarshipExecution:isActive(): boolean
	return self.warship ~= nil and self.warship:isActive()
end

function WarshipExecution:isDocked(): boolean
	return self.warship ~= nil and self.warship:warshipState().state == "docked"
end

function WarshipExecution:activeDuringSpawnPhase(): boolean
	return false
end

function WarshipExecution:randomTile(allowShoreline: boolean): number?
	local mg = self.mg
	local patrolRange = mg:config():warshipPatrolRange()
	local maxAttemptBeforeExpand = 500
	local attempts, expandCount = 0, 0
	local component = mg:getWaterComponent(self.warship:tile())
	local patrolTile = self.warship:warshipState().patrolTile
	if patrolTile == nil or not mg:isValidRef(patrolTile) then
		return nil
	end
	while expandCount < 3 do
		local x = mg:x(patrolTile) + self.random:nextInt(-patrolRange / 2, patrolRange / 2)
		local y = mg:y(patrolTile) + self.random:nextInt(-patrolRange / 2, patrolRange / 2)
		if not mg:isValidCoord(x, y) then
			continue
		end
		local tile = mg:ref(x, y)
		local bad = not mg:isWater(tile) or (not allowShoreline and mg:isShoreline(tile))
		if not bad and component ~= nil and not mg:hasWaterComponent(tile, component) then
			bad = true
		end
		if bad then
			attempts += 1
			if attempts == maxAttemptBeforeExpand then
				expandCount += 1
				attempts = 0
				patrolRange = patrolRange + math.floor(patrolRange / 2)
			end
			continue
		end
		return tile
	end
	warn(`Failed to find random tile for warship for {self.warship:owner():name()}`)
	if not allowShoreline then
		return self:randomTile(true)
	end
	return nil
end

return {
	WarshipExecution = WarshipExecution,
	ShellExecution = ShellExecution,
	MoveWarshipExecution = MoveWarshipExecution,
}
