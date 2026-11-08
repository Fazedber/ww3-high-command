-- Port of OpenFrontIO src/core/execution/MIRVExecution.ts.
-- The MIRV flies to a separation point north of the target, picks up to 350
-- spread-out tiles of the target player and splits into warheads
-- (NukeExecution with MIRVWarhead) launched from the separation point.

local Shared = game:GetService("ReplicatedStorage").Shared
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local Parabola = require(Shared.Parabola)
local PathStatus = require(Core.Pathfinding.PathFinder).PathStatus
local NukeExecution = require(script.Parent.NukeExecution)

local UnitType = GameTypes.UnitType
local MessageType = GameTypes.MessageType

local MATH_SCALE = 100
local LONG_FLIGHT_MULT = 14
local LONG_FLIGHT_LINEAR_PERCENT = 10
local SHORT_FLIGHT_MULT = 10

local MirvExecution = {}
MirvExecution.__index = MirvExecution

function MirvExecution.new(player, dst: number)
	local range = 1500
	return setmetatable({
		player = player,
		dst = dst,
		_active = true,
		nuke = nil,
		range = range,
		rangeSquared = range * range,
		minimumSpread = 55,
		warheadCount = 350,
		fullPath = {},
		pathIndex = 0, -- 0-based, like upstream
		speed = -1,
		stagedTargets = {},
		warheadsSpawned = false,
		warheadExecutions = {},
	}, MirvExecution)
end

function MirvExecution:init(mg, _ticks: number)
	self.random = PseudoRandom.new(mg:ticks() + Util.simpleHash(self.player:id()))
	self.mg = mg
	self.targetPlayer = mg:owner(self.dst)
	self.baseX = mg:x(self.dst)
	self.baseY = mg:y(self.dst)
	self.stagedTargets = { self.dst }
end

function MirvExecution:tick(_ticks: number)
	local mg = self.mg
	if self.nuke == nil then
		local spawn = self.player:canBuild(UnitType.MIRV, self.dst)
		if spawn == false then
			warn("cannot build MIRV")
			self._active = false
			return
		end
		self.spawnTile = spawn
		self.nuke = self.player:buildUnit(UnitType.MIRV, spawn, { targetTile = self.dst, targetPlayer = self.targetPlayer })
		mg:stats():bombLaunch(self.player, self.targetPlayer, UnitType.MIRV)

		-- Betrayal on launch, only once the missile actually spawned.
		if self.targetPlayer:isPlayer() then
			local alliance = self.player:allianceWith(self.targetPlayer)
			if alliance ~= nil then
				self.player:breakAlliance(alliance)
			end
			if self.targetPlayer ~= self.player then
				self.targetPlayer:updateRelation(self.player, -100)
				self.player:updateRelation(self.targetPlayer, -100)
			end
		end
		local x = math.floor((self.baseX + mg:x(self.nuke:tile())) / 2)
		local y = math.max(0, self.baseY - 500) + 50
		self.separateDst = mg:ref(x, y)

		self.speed = self:_calculateDeterministicSpeed(self.spawnTile, self.separateDst)
		self.pathFinder = Parabola.new(mg, { increment = self.speed })
		local result = self.pathFinder:next(self.spawnTile, self.separateDst, self.speed)
		while result.status == PathStatus.NEXT do
			table.insert(self.fullPath, result.node)
			result = self.pathFinder:next(self.spawnTile, self.separateDst, self.speed)
		end

		mg:displayIncomingUnit(
			self.nuke:id(),
			`⚠️⚠️⚠️ {self.player:displayName()} - MIRV INBOUND ⚠️⚠️⚠️`,
			MessageType.MIRV_INBOUND,
			self.targetPlayer:id()
		)

		for _, silo in self.player:units(UnitType.MissileSilo) do
			if silo:tile() == spawn then
				silo:launch()
				break
			end
		end
	end

	-- Destroyed or cancelled externally.
	if self.nuke ~= nil and not self.nuke:isActive() then
		self._active = false
		for _, warhead in self.warheadExecutions do
			warhead:cancel()
		end
		self.warheadExecutions = {}
		return
	end

	local remainingTicks = #self.fullPath - self.pathIndex

	-- Stagger destination finding across ticks 20..11 before separation.
	if remainingTicks <= 20 and remainingTicks > 10 then
		for _ = 1, 100 do
			if #self.stagedTargets >= self.warheadCount then
				break
			end
			local target = self:_tryGenerateTarget(self.stagedTargets)
			if target then
				table.insert(self.stagedTargets, target)
			end
		end
	end

	-- At <= 10 ticks: re-validate, finalize, sort and spawn warhead executions.
	if remainingTicks <= 10 and not self.warheadsSpawned then
		self.warheadsSpawned = true
		local extraAttempts = (10 - remainingTicks) * 50
		self:_finalizeDestinations(500 + extraAttempts)
		self:_spawnWarheadsWithWait(remainingTicks)
	end

	if self.pathIndex < #self.fullPath then
		self.pathIndex += 1
		self.nuke:move(self.fullPath[self.pathIndex])
	else
		self.nuke:delete(false) -- separate
		self._active = false
		mg:stats():bombLand(self.player, self.targetPlayer, UnitType.MIRV)
	end
end

function MirvExecution:_finalizeDestinations(additionalAttempts: number)
	local mg = self.mg
	local kept = {}
	for _, tile in self.stagedTargets do
		if tile == self.dst or mg:owner(tile) == self.targetPlayer then
			table.insert(kept, tile)
		end
	end
	self.stagedTargets = kept
	for _ = 1, additionalAttempts do
		if #self.stagedTargets >= self.warheadCount then
			break
		end
		local target = self:_tryGenerateTarget(self.stagedTargets)
		if target then
			table.insert(self.stagedTargets, target)
		end
	end
	-- Farthest from the target first (stable, like Array.sort).
	local dst = self.dst
	Util.sort(self.stagedTargets, function(a, b)
		return mg:manhattanDist(b, dst) - mg:manhattanDist(a, dst)
	end)
end

function MirvExecution:_spawnWarheadsWithWait(remainingTicks: number)
	if self.nuke == nil then
		return
	end
	local waitBase = math.max(0, remainingTicks)
	local warheadSpeed = self.mg:config():nukeSpeed(UnitType.MIRVWarhead)
	for idx, dst in self.stagedTargets do
		local i = idx - 1
		local speedOffset = 4
		if i < 70 then
			speedOffset = 0
		elseif i < 140 then
			speedOffset = 1
		elseif i < 210 then
			speedOffset = 2
		elseif i < 280 then
			speedOffset = 3
		end
		local execution = NukeExecution.new(
			UnitType.MIRVWarhead,
			self.player,
			dst,
			self.separateDst,
			warheadSpeed + speedOffset,
			waitBase + self.random:nextInt(0, 15)
		)
		table.insert(self.warheadExecutions, execution)
		self.mg:addExecution(execution)
	end
end

function MirvExecution:_tryGenerateTarget(taken: { number }): number?
	local mg = self.mg
	for _ = 1, 100 do
		local r1 = self.random:next()
		local r2 = (r1 * 15485863) % 1
		local x = math.floor(r1 * self.range * 2 - self.range + self.baseX + 0.5)
		local y = math.floor(r2 * self.range * 2 - self.range + self.baseY + 0.5)
		if not mg:isValidCoord(x, y) then
			continue
		end
		local tile = mg:ref(x, y)
		if not mg:isLand(tile) then
			continue
		end
		local ddx, ddy = x - self.baseX, y - self.baseY
		if ddx * ddx + ddy * ddy > self.rangeSquared then
			continue
		end
		if mg:owner(tile) ~= self.targetPlayer then
			continue
		end
		if self:_isOverlapping(x, y, taken) then
			continue
		end
		return tile
	end
	return nil
end

function MirvExecution:_isOverlapping(x: number, y: number, taken: { number }): boolean
	local mg = self.mg
	for _, t in taken do
		if math.abs(x - mg:x(t)) + math.abs(y - mg:y(t)) < self.minimumSpread then
			return true
		end
	end
	return false
end

-- Flight time normalised towards mirvNormalizeTargetTicks with integer maths.
function MirvExecution:_calculateDeterministicSpeed(spawnTile: number, separateDst: number): number
	local mg = self.mg
	local Bezier = Parabola.Bezier
	local iP0, iP1, iP2, iP3 = Parabola.controlPoints(mg, spawnTile, separateDst, {
		distanceBasedHeight = true,
		directionUp = true,
		ignoreMapBounds = true,
	})
	local idealMirvLength = Bezier.getLength(iP0, iP1, iP2, iP3)
	local baseSpeed = mg:config():nukeSpeed(UnitType.MIRV)
	local idealMirvTicks = idealMirvLength / baseSpeed

	local baseTicksScaled = mg:config():mirvNormalizeTargetTicks() * MATH_SCALE
	local idealMirvTicksInt = math.floor(idealMirvTicks * MATH_SCALE)
	local targetMirvTicksInt = baseTicksScaled
	if idealMirvTicksInt > baseTicksScaled then
		local diff = idealMirvTicksInt - baseTicksScaled
		targetMirvTicksInt = baseTicksScaled
			+ math.floor(math.sqrt(diff)) * LONG_FLIGHT_MULT
			+ math.floor((diff * LONG_FLIGHT_LINEAR_PERCENT) / 100)
	elseif idealMirvTicksInt < baseTicksScaled then
		local diff = baseTicksScaled - idealMirvTicksInt
		targetMirvTicksInt = baseTicksScaled - math.floor(math.sqrt(diff)) * SHORT_FLIGHT_MULT
	end
	targetMirvTicksInt = math.max(MATH_SCALE, targetMirvTicksInt)

	local aP0, aP1, aP2, aP3 = Parabola.controlPoints(mg, spawnTile, separateDst)
	local actualMirvLength = Bezier.getLength(aP0, aP1, aP2, aP3)
	local actualMirvLengthInt = math.floor(actualMirvLength * 256 + 0.5)
	local num = actualMirvLengthInt * MATH_SCALE
	local den = targetMirvTicksInt
	local pureIntegerSpeedScaled = math.floor((num + math.floor(den / 2)) / den)
	return math.max(1, pureIntegerSpeedScaled / 256)
end

function MirvExecution:owner()
	return self.player
end

function MirvExecution:isActive(): boolean
	return self._active
end

function MirvExecution:activeDuringSpawnPhase(): boolean
	return false
end

return MirvExecution
