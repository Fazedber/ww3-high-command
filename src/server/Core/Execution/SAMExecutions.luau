-- Port of OpenFrontIO src/core/execution/SAMLauncherExecution.ts (with its
-- SAMTargetingSystem) and SAMMissileExecution.ts.
-- A SAM pre-computes, per incoming nuke, the tick at which a missile must be
-- fired to meet it inside the (upgrade-dependent) range, then fires missiles
-- that fly on the Air path finder and destroy the nuke on arrival.

local Shared = game:GetService("ReplicatedStorage").Shared
local Util = require(Shared.Util)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local PathFinderMod = require(Core.Pathfinding.PathFinder)

local UnitType = GameTypes.UnitType
local MessageType = GameTypes.MessageType
local PathStatus = PathFinderMod.PathStatus

local NUKE_TYPES = { UnitType.AtomBomb, UnitType.HydrogenBomb, UnitType.MIRVWarhead }
local INTERCEPTABLE = { [UnitType.AtomBomb] = true, [UnitType.HydrogenBomb] = true, [UnitType.MIRVWarhead] = true }
local INTERCEPTED_UNIT_KEYS = {
	[UnitType.AtomBomb] = "unit_type.atom_bomb",
	[UnitType.HydrogenBomb] = "unit_type.hydrogen_bomb",
	[UnitType.MIRVWarhead] = "unit_type.mirv",
}

-- Insertion-ordered map id -> value (JS Map), with deletion while iterating
-- over a snapshot of the keys.
local IdMap = {}
IdMap.__index = IdMap
function IdMap.new()
	return setmetatable({ keys = {}, values = {} }, IdMap)
end
function IdMap:get(k)
	return self.values[k]
end
function IdMap:set(k, v)
	if self.values[k] == nil then
		table.insert(self.keys, k)
	end
	self.values[k] = v
end
function IdMap:delete(k)
	if self.values[k] ~= nil then
		self.values[k] = nil
		table.remove(self.keys, table.find(self.keys, k) :: number)
	end
end
function IdMap:each(fn)
	for _, k in table.clone(self.keys) do
		local v = self.values[k]
		if v ~= nil then
			fn(k, v)
		end
	end
end

-- SAMTargetingSystem ----------------------------------------------------------------

local Targeting = {}
Targeting.__index = Targeting

function Targeting.new(mg, sam)
	local self = setmetatable({
		mg = mg,
		sam = sam,
		-- nuke id -> { tick (>=0 launch tick, -1 unreachable now, -2 never), tile, minDistSq, lastSeenTick }
		precomputedNukes = IdMap.new(),
		missileSpeed = mg:config():defaultSamMissileSpeed(),
	}, Targeting)
	self.isTargetableNearbyUnit = function(e)
		return self:_isValidNukeTarget(e.unit)
	end
	return self
end

function Targeting:onLevelUp()
	self.precomputedNukes:each(function(id, cached)
		if cached.tick == -1 then
			self.precomputedNukes:delete(id)
		end
	end)
end

function Targeting:updateUnreachableNukes(currentTick: number)
	self.precomputedNukes:each(function(id, cached)
		if cached.lastSeenTick ~= currentTick then
			self.precomputedNukes:delete(id)
		end
	end)
end

function Targeting:_tickToReach(currentTile: number, tile: number): number
	return math.ceil(self.mg:manhattanDist(currentTile, tile) / self.missileSpeed)
end

-- trajectory[i] with upstream 0-based i.
local function at(trajectory, i: number)
	return trajectory[i + 1]
end

function Targeting:_checkDetonationInterception(unit, samTile: number, ticks: number)
	local mg = self.mg
	local trajectory = unit:trajectory()
	local maxIdx = #trajectory - 2
	local finalTile = at(trajectory, #trajectory - 1)
	if not (finalTile and finalTile.targetable) then
		return nil
	end
	local curIdx = unit:trajectoryIndex()
	local waitTicks = unit:nukeState().waitTicks or 0
	local expTicks = #trajectory - 1 - curIdx + waitTicks
	local range = mg:config():dynamicSamRange(self.sam, ticks + expTicks)
	if mg:euclideanDistSquared(samTile, finalTile.tile) > range * range then
		return nil
	end
	local flightTile = at(trajectory, maxIdx)
	if not (flightTile and flightTile.targetable) then
		return nil
	end
	local nukeTicks = maxIdx - curIdx + waitTicks
	local samTicks = self:_tickToReach(samTile, flightTile.tile)
	local tickBeforeShooting = nukeTicks - samTicks
	return if tickBeforeShooting >= 0 then { tick = tickBeforeShooting, tile = flightTile.tile } else nil
end

function Targeting:_computeInterceptionTile(unit, samTile: number, ticks: number)
	local mg = self.mg
	local trajectory = unit:trajectory()
	local curIdx = unit:trajectoryIndex()
	local waitTicks = unit:nukeState().waitTicks or 0
	local maxIdx = #trajectory - 2
	local maxSam = mg:config():maxSamRange()
	local maxSamRangeSq = maxSam * maxSam
	local minDistSq = math.huge
	local closestTile = samTile
	local incSteps = 0
	local lastDistSq = -1

	for i = curIdx, maxIdx do
		local tile = at(trajectory, i)
		local distSq = mg:euclideanDistSquared(samTile, tile.tile)
		if distSq < minDistSq then
			minDistSq = distSq
			closestTile = tile.tile
		end
		incSteps = if lastDistSq ~= -1 and distSq > lastDistSq then incSteps + 1 else 0
		lastDistSq = distSq

		local nukeTicks = i - curIdx + waitTicks
		local samTicks = self:_tickToReach(samTile, tile.tile)
		local allowed = mg:config():dynamicSamRange(self.sam, ticks + nukeTicks)
		if tile.targetable and distSq <= allowed * allowed and nukeTicks >= samTicks then
			return { tick = nukeTicks - samTicks, tile = tile.tile, minDistSq = minDistSq, lastSeenTick = ticks }
		end
		if incSteps > 3 and distSq > maxSamRangeSq then
			break
		end
	end

	local det = self:_checkDetonationInterception(unit, samTile, ticks)
	if det then
		return { tick = det.tick, tile = det.tile, minDistSq = minDistSq, lastSeenTick = ticks }
	end
	return {
		tick = if minDistSq > maxSamRangeSq then -2 else -1,
		tile = closestTile,
		minDistSq = minDistSq,
		lastSeenTick = ticks,
	}
end

function Targeting:_isValidNukeTarget(unit): boolean
	if unit:targetedBySAM() or unit:owner() == self.sam:owner() then
		return false
	end
	local samOwner = self.sam:owner()
	local nukeOwner = unit:owner()
	if samOwner:isFriendly(nukeOwner) then
		-- Aftergame fun is disabled in singleplayer.
		local mg = self.mg
		local gameOver = mg:getWinner() ~= nil and mg:config():gameConfig().gameType ~= GameTypes.GameType.Singleplayer
		return gameOver and samOwner:isOnSameTeam(nukeOwner)
	end
	return true
end

function Targeting:_computeTargetScore(target): number
	local mg = self.mg
	local samTile = self.sam:tile()
	local unit = target.unit
	local trajectory = unit:trajectory()
	local timeToExplode = math.max(1, #trajectory - unit:trajectoryIndex())
	local targetTile = unit:targetTile()
	if targetTile == nil then
		targetTile = if #trajectory > 0 then trajectory[#trajectory].tile else samTile
	end
	local distToSilo = mg:manhattanDist(samTile, targetTile)
	local typeBonus = if unit:type() == UnitType.HydrogenBomb then 70001 else 0
	local distanceBonus = math.max(0, 200000 - distToSilo * 1000)
	local urgencyBonus = math.max(0, 10000 - timeToExplode * 100)
	return typeBonus + distanceBonus + urgencyBonus
end

function Targeting:_sortTargets(targets)
	if #targets <= 1 then
		return targets
	end
	for _, t in targets do
		t.score = self:_computeTargetScore(t)
	end
	return Util.sort(targets, function(a, b)
		return b.score - a.score
	end)
end

function Targeting:getValidTargets(ticks: number)
	local mg = self.mg
	local samTile = self.sam:tile()
	local detectionRange = mg:config():maxSamRange() * 4
	local nukes = mg:nearbyUnits(samTile, detectionRange, NUKE_TYPES, self.isTargetableNearbyUnit)
	local targets = {}
	for _, e in nukes do
		local id = e.unit:id()
		local cached = self.precomputedNukes:get(id)
		local skip = false
		if cached ~= nil then
			cached.lastSeenTick = ticks
			if cached.tick == -2 or cached.tick == -1 then
				skip = true
			elseif cached.tick == ticks or cached.tick == ticks + 1 then
				table.insert(targets, { tile = cached.tile, unit = e.unit })
				self.precomputedNukes:delete(id)
				skip = true
			elseif cached.tick > ticks then
				skip = true
			else
				self.precomputedNukes:delete(id)
			end
		end
		if not skip then
			local res = self:_computeInterceptionTile(e.unit, samTile, ticks)
			if res.tick >= 0 and res.tick <= 1 then
				table.insert(targets, { unit = e.unit, tile = res.tile })
			else
				self.precomputedNukes:set(id, {
					tick = if res.tick >= 0 then res.tick + ticks else res.tick,
					tile = res.tile,
					minDistSq = res.minDistSq,
					lastSeenTick = ticks,
				})
			end
		end
	end
	self:updateUnreachableNukes(ticks)
	return self:_sortTargets(targets)
end

-- SAMMissileExecution ------------------------------------------------------------------

local SAMMissileExecution = {}
SAMMissileExecution.__index = SAMMissileExecution

function SAMMissileExecution.new(spawn: number, owner, ownerUnit, target, targetTile: number)
	return setmetatable({
		spawn = spawn,
		_owner = owner,
		ownerUnit = ownerUnit,
		target = target,
		targetTile = targetTile,
		_active = true,
		missile = nil,
		speed = 0,
	}, SAMMissileExecution)
end

function SAMMissileExecution:init(mg, ticks: number)
	self.pathFinder = PathFinderMod.Air(mg)
	self.mg = mg
	self.speed = mg:config():defaultSamMissileSpeed()
	self:tick(ticks)
end

function SAMMissileExecution:tick(_ticks: number)
	if self.missile == nil then
		self.missile = self._owner:buildUnit(UnitType.SAMMissile, self.spawn, { targetUnit = self.target })
	end
	local missile = self.missile
	if not missile:isActive() then
		self._active = false
		return
	end
	-- The MIRV carrier itself can't be intercepted, only its warheads.
	if not self.target:isActive() or not self.ownerUnit:isActive() or self.target:owner() == missile:owner() or not INTERCEPTABLE[self.target:type()] then
		-- Let other SAMs re-target this nuke.
		if self.target:isActive() then
			self.target:setTargetedBySAM(false)
		end
		missile:delete(false)
		self._active = false
		return
	end
	for _ = 1, self.speed do
		local result = self.pathFinder:next(missile:tile(), self.targetTile)
		if result.status == PathStatus.COMPLETE then
			self.mg:displayMessage("events_display.missile_intercepted", MessageType.SAM_HIT, self._owner:id(), nil, {
				unit = INTERCEPTED_UNIT_KEYS[self.target:type()] or self.target:type(),
			})
			self._active = false
			self.target:delete(true, self._owner)
			missile:delete(false)
			self.mg:stats():bombIntercept(self._owner, self.target:type(), 1)
			return
		elseif result.status == PathStatus.NEXT then
			missile:move(result.node)
		end
	end
end

function SAMMissileExecution:isActive(): boolean
	return self._active
end

function SAMMissileExecution:activeDuringSpawnPhase(): boolean
	return false
end

-- SAMLauncherExecution ------------------------------------------------------------------

local SAMLauncherExecution = {}
SAMLauncherExecution.__index = SAMLauncherExecution

function SAMLauncherExecution.new(player, tile: number?, sam)
	return setmetatable({
		player = player,
		tile = if sam ~= nil then sam:tile() else tile,
		sam = sam,
		_active = true,
		targetingSystem = nil,
		lastLevel = 1,
	}, SAMLauncherExecution)
end

function SAMLauncherExecution:init(mg, _ticks: number)
	self.mg = mg
end

function SAMLauncherExecution:tick(ticks: number)
	local mg = self.mg
	if self.sam == nil then
		assert(self.tile ~= nil, "tile is null")
		local spawnTile = self.player:canBuild(UnitType.SAMLauncher, self.tile)
		if spawnTile == false then
			warn("cannot build SAM Launcher")
			self._active = false
			return
		end
		self.sam = self.player:buildUnit(UnitType.SAMLauncher, spawnTile, {})
	end
	local sam = self.sam
	if self.targetingSystem == nil then
		self.targetingSystem = Targeting.new(mg, sam)
	end
	if self.lastLevel ~= sam:level() then
		self.lastLevel = sam:level()
		self.targetingSystem:onLevelUp()
	end
	if sam:isUnderConstruction() then
		return
	end
	if not sam:isActive() then
		self._active = false
		return
	end
	if self.player ~= sam:owner() then
		self.player = sam:owner()
	end

	while #sam:missileTimerQueue() > 0 do
		local frontTime = sam:missileTimerQueue()[1]
		local cooldown = mg:config():SAMCooldown() - (mg:ticks() - frontTime)
		if cooldown > 0 then
			break
		end
		sam:reloadMissile()
	end
	if sam:isInCooldown() then
		return
	end

	-- No nuke in flight anywhere: nothing to target (exact shortcut upstream).
	if mg:unitCount(UnitType.AtomBomb) == 0 and mg:unitCount(UnitType.HydrogenBomb) == 0 and mg:unitCount(UnitType.MIRVWarhead) == 0 then
		return
	end
	for _, target in self.targetingSystem:getValidTargets(ticks) do
		if sam:isInCooldown() then
			break
		end
		sam:launch()
		target.unit:setTargetedBySAM(true)
		mg:addExecution(SAMMissileExecution.new(sam:tile(), sam:owner(), sam, target.unit, target.tile))
	end
end

function SAMLauncherExecution:isActive(): boolean
	return self._active
end

function SAMLauncherExecution:activeDuringSpawnPhase(): boolean
	return false
end

return {
	SAMLauncherExecution = SAMLauncherExecution,
	SAMMissileExecution = SAMMissileExecution,
}
