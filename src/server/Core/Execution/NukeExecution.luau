-- Port of OpenFrontIO src/core/execution/NukeExecution.ts.
-- Launches an atom / hydrogen bomb (or a MIRV warhead) from the closest
-- ready silo along a parabola; on arrival it relinquishes the blast tiles,
-- leaves fallout, kills troops and destroys units in range.
-- TODO(port): water nukes (config.waterNukes, off by default) — land → water.

local Shared = game:GetService("ReplicatedStorage").Shared
local PseudoRandom = require(Shared.PseudoRandom)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local ExecUtil = require(script.Parent.ExecUtil)
local Parabola = require(Shared.Parabola)
local PathStatus = require(Core.Pathfinding.PathFinder).PathStatus

local UnitType = GameTypes.UnitType
local MessageType = GameTypes.MessageType
local Structures = GameTypes.Structures

local SPRITE_RADIUS = 16

local NOT_BLASTED = {
	[UnitType.AtomBomb] = true,
	[UnitType.HydrogenBomb] = true,
	[UnitType.MIRVWarhead] = true,
	[UnitType.MIRV] = true,
	[UnitType.SAMMissile] = true,
}

local NukeExecution = {}
NukeExecution.__index = NukeExecution

function NukeExecution.new(nukeType: string, player, dst: number, src: number?, speed: number?, waitTicks: number?, rocketDirectionUp: boolean?)
	return setmetatable({
		nukeType = nukeType,
		player = player,
		dst = dst,
		src = src,
		speed = speed or -1,
		waitTicks = waitTicks or 0,
		rocketDirectionUp = if rocketDirectionUp == nil then true else rocketDirectionUp,
		_active = true,
		nuke = nil,
		tilesToDestroyCache = nil,
	}, NukeExecution)
end

function NukeExecution:init(mg, _ticks: number)
	self.mg = mg
	if self.speed == -1 then
		self.speed = mg:config():nukeSpeed(self.nukeType)
	end
	self.pathFinder = Parabola.new(mg, { increment = self.speed, directionUp = self.rocketDirectionUp })
end

function NukeExecution:target()
	return self.mg:owner(self.dst)
end

-- Tiles hit: everything within inner, half of the outer ring (random),
-- never impassable. JSSet from a flood fill, like upstream.
function NukeExecution:_tilesToDestroy()
	if self.tilesToDestroyCache ~= nil then
		return self.tilesToDestroyCache
	end
	local mg = self.mg
	local magnitude = mg:config():nukeMagnitudes(self.nuke:type())
	local rand = PseudoRandom.new(mg:ticks())
	local inner2 = magnitude.inner * magnitude.inner
	local outer2 = magnitude.outer * magnitude.outer
	if mg:config():waterNukes() then
		error("TODO(port): water nukes")
	end
	local dst = self.dst
	self.tilesToDestroyCache = mg:bfs(dst, function(_, n)
		local d2 = mg:euclideanDistSquared(dst, n)
		return d2 <= outer2 and (d2 <= inner2 or rand:chance(2)) and not mg:isImpassable(n)
	end)
	return self.tilesToDestroyCache
end

-- Break alliances with players significantly affected by the strike.
function NukeExecution:_maybeBreakAlliances()
	if self.nuke:type() == UnitType.MIRVWarhead then
		return -- MIRV warheads shouldn't break alliances
	end
	local mg = self.mg
	local magnitude = mg:config():nukeMagnitudes(self.nuke:type())
	local toBreak = ExecUtil.listNukeBreakAlliance(mg, self.dst, magnitude, mg:config():nukeAllianceBreakThreshold())
	local toBreakSet = {}
	for _, id in toBreak do
		toBreakSet[id] = true
	end
	-- Automatically reject incoming alliance requests.
	for _, incoming in self.player:incomingAllianceRequests() do
		if toBreakSet[incoming:requestor():smallID()] then
			incoming:reject()
		end
	end
	for _, smallId in toBreak do
		local attacked = mg:playerBySmallID(smallId)
		if not attacked:isPlayer() then
			continue
		end
		-- A pending request accepted mid-flight is rejected instead.
		local outgoing = nil
		for _, ar in attacked:incomingAllianceRequests() do
			if ar:requestor() == self.player then
				outgoing = ar
				break
			end
		end
		if outgoing then
			outgoing:reject()
			continue
		end
		local alliance = self.player:allianceWith(attacked)
		if alliance ~= nil then
			self.player:breakAlliance(alliance)
		end
		if attacked ~= self.player then
			attacked:updateRelation(self.player, -100)
		end
	end
end

function NukeExecution:tick(ticks: number)
	local mg = self.mg
	if self.nuke == nil then
		local spawn = self.player:canBuild(self.nukeType, self.dst)
		if spawn == false then
			warn("cannot build Nuke")
			self._active = false
			return
		end
		-- The launch tile can be overridden (MIRV warheads launch mid-air).
		if self.src == nil then
			self.src = spawn
		end
		local silo = nil
		for _, s in self.player:units(UnitType.MissileSilo) do
			if s:tile() == spawn then
				silo = s
				break
			end
		end
		-- Stacked launches from one silo trail each other.
		if silo ~= nil then
			local lastDep = 0
			for _, launchTick in silo:missileTimerQueue() do
				lastDep = math.max(launchTick + 1, lastDep + 1)
			end
			if lastDep > mg:ticks() then
				self.waitTicks += lastDep - mg:ticks()
			end
		end
		self.nuke = self.player:buildUnit(self.nukeType, self.src, {
			targetTile = self.dst,
			trajectory = self:_getTrajectory(self.dst),
		})
		self.nuke:updateNukeState({ waitTicks = self.waitTicks })
		-- Clients replay the flight from this plan (recordMotionPlan) instead
		-- of receiving a position update every tick.
		mg:recordMotionPlan({
			unitId = self.nuke:id(),
			src = self.src,
			dst = self.dst,
			speed = self.speed,
			directionUp = self.rocketDirectionUp,
			startTick = ticks + self.waitTicks + 1,
		})
		if self.nuke:type() ~= UnitType.MIRVWarhead then
			self:_maybeBreakAlliances()
		end
		if mg:hasOwner(self.dst) then
			local target = mg:owner(self.dst)
			if target:isPlayer() then
				if self.nukeType == UnitType.AtomBomb then
					mg:displayIncomingUnit(self.nuke:id(), `{self.player:displayName()} - atom bomb inbound`, MessageType.NUKE_INBOUND, target:id())
				elseif self.nukeType == UnitType.HydrogenBomb then
					mg:displayIncomingUnit(
						self.nuke:id(),
						`{self.player:displayName()} - hydrogen bomb inbound`,
						MessageType.HYDROGEN_BOMB_INBOUND,
						target:id()
					)
				end
				mg:stats():bombLaunch(self.player, target, self.nukeType)
			end
		end
		-- After sending a nuke, the silo reloads.
		if silo then
			silo:launch()
		end
		return
	end

	-- Intercepted.
	if not self.nuke:isActive() then
		self._active = false
		return
	end

	if self.waitTicks > 0 then
		self.waitTicks -= 1
		self.nuke:updateNukeState({ waitTicks = self.waitTicks })
		return
	end

	local result = self.pathFinder:next(self.src, self.dst, self.speed)
	if result.status == PathStatus.COMPLETE then
		self.nuke:move(result.node) -- moved first for the visual effect
		-- A SAM missile about to hit this nuke wins (execution order aside).
		local nuke = self.nuke
		local shouldBeDestroyed = #mg:nearbyUnits(self.dst, mg:config():defaultSamMissileSpeed(), UnitType.SAMMissile, function(e)
			local unit = e.unit
			if unit:owner() == nuke:owner() then
				return false
			end
			local t = unit:targetUnit()
			return t ~= nil and t:id() == nuke:id()
		end) >= 1
		if not shouldBeDestroyed then
			self:_detonate()
		end
	elseif result.status == PathStatus.NEXT then
		self:_updateNukeTargetable()
		self.nuke:move(result.node)
		-- Lets SAMs interpolate the future position.
		self.nuke:setTrajectoryIndex(self.pathFinder:currentIndex())
	end
end

function NukeExecution:getNuke()
	return self.nuke
end

function NukeExecution:_isTargetable(targetTile: number, nukeTile: number, targetRangeSquared: number): boolean
	local mg = self.mg
	return mg:euclideanDistSquared(nukeTile, targetTile) < targetRangeSquared
		or (self.src ~= nil and mg:euclideanDistSquared(self.src, nukeTile) < targetRangeSquared)
end

function NukeExecution:_getTrajectory(target: number)
	local out = {}
	local r = self.mg:config():defaultNukeTargetableRange()
	local r2 = r * r
	for _, tile in self.pathFinder:findPath(self.src, target) do
		table.insert(out, { tile = tile, targetable = self:_isTargetable(target, tile, r2) })
	end
	return out
end

function NukeExecution:_updateNukeTargetable()
	local targetTile = self.nuke:targetTile()
	if targetTile == nil then
		return
	end
	local r = self.mg:config():defaultNukeTargetableRange()
	self.nuke:setTargetable(self:_isTargetable(targetTile, self.nuke:tile(), r * r))
end

function NukeExecution:_detonate()
	local mg = self.mg
	local config = mg:config()
	local magnitude = config:nukeMagnitudes(self.nuke:type())
	local toDestroy = self:_tilesToDestroy()

	-- Impacted players and their tile counts (JS Map: first-seen order).
	local order, perPlayer = {}, {}
	for tile in toDestroy do
		local owner = mg:owner(tile)
		if owner:isPlayer() then
			owner:relinquish(tile)
			if perPlayer[owner] == nil then
				perPlayer[owner] = 0
				table.insert(order, owner)
			end
			perPlayer[owner] += 1
		end
		if mg:isLand(tile) then
			mg:queueWaterConversion(tile)
		end
		mg:queueNukeImpact(tile)
	end

	-- Explosion effect on each player.
	for _, player in order do
		local numImpactedTiles = perPlayer[player]
		local tilesBeforeNuke = player:numTilesOwned() + numImpactedTiles
		local transportShips = player:units(UnitType.TransportShip)
		local shipTroops = {}
		for _, unit in transportShips do
			shipTroops[unit] = unit:troops()
		end
		local outgoingAttacks = player:outgoingAttacks()
		local maxTroops = config:maxTroops(player)
		for i = 0, numImpactedTiles - 1 do
			-- Diminishing effect as each affected tile has been nuked.
			local numTilesLeft = tilesBeforeNuke - i
			player:removeTroops(config:nukeDeathFactor(self.nukeType, player:troops(), numTilesLeft, maxTroops))
			for _, attack in outgoingAttacks do
				local attackTroops = attack:troops()
				local deaths = config:nukeDeathFactor(self.nukeType, attackTroops, numTilesLeft, maxTroops)
				attack:setTroops(attackTroops - deaths)
			end
			for _, unit in transportShips do
				local unitTroops = shipTroops[unit]
				local deaths = config:nukeDeathFactor(self.nukeType, unitTroops, numTilesLeft, maxTroops)
				shipTroops[unit] = math.max(0, unitTroops - deaths)
			end
		end
		for _, unit in transportShips do
			unit:setTroops(shipTroops[unit])
		end
	end

	local outer2 = magnitude.outer * magnitude.outer
	local dst = self.dst
	for _, unit in mg:units() do
		if NOT_BLASTED[unit:type()] then
			continue
		end
		if mg:euclideanDistSquared(dst, unit:tile()) < outer2 then
			-- treatAFKFriendly matches warship targeting.
			local friendly = self.player:isFriendly(unit:owner(), true)
			unit:delete(true, if friendly then nil else self.player)
		end
	end

	self:_redrawBuildings(magnitude.outer + SPRITE_RADIUS)
	self._active = false
	self.nuke:setReachedTarget()
	self.nuke:delete(false)

	if self.nukeType == UnitType.AtomBomb or self.nukeType == UnitType.HydrogenBomb then
		local key = if self.nukeType == UnitType.AtomBomb then "events_display.atom_bomb_detonated" else "events_display.hydrogen_bomb_detonated"
		for _, impacted in order do
			mg:displayMessage(key, MessageType.NUKE_DETONATED, impacted:id(), nil, { name = self.player:displayName() }, nil, self.player:id())
		end
	end
	mg:stats():bombLand(self.player, self:target(), self.nuke:type())
end

function NukeExecution:_redrawBuildings(range: number)
	local r2 = range * range
	for _, unit in self.mg:units() do
		if Structures.has(unit:type()) and self.mg:euclideanDistSquared(self.dst, unit:tile()) < r2 then
			unit:touch()
		end
	end
end

function NukeExecution:cancel()
	self._active = false
	if self.nuke ~= nil and self.nuke:isActive() then
		self.nuke:delete(false)
	end
end

function NukeExecution:owner()
	return self.player
end

function NukeExecution:isActive(): boolean
	return self._active
end

function NukeExecution:activeDuringSpawnPhase(): boolean
	return false
end

return NukeExecution
