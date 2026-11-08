# FOR CLAUDE: capture / attack physics of a Roblox OpenFront-style game (single file)

You are a coding assistant. This ONE file contains everything needed: the explanation, then the Luau source of the modules that decide how territory is conquered. Read it all before changing anything. The code is a server-side simulation (Roblox Luau, strict determinism). Reply with a unified diff or complete replaced functions, and explain formulas and tuning numbers.

---

# Capture physics ("how territory gets conquered") - hand-off for another Claude

Project: Roblox/Luau port of OpenFront (territory-conquest RTS), working title "WW3: High Command".
License: AGPL-3.0 (derivative of OpenFront), (c) OpenFront and Contributors. Whoever receives these
files gets them under AGPL-3.0; keep the notice and publish your modified source if you ship it.

This folder holds the files that decide **how land changes hands**. Everything is server-authoritative
Luau in `src/server/Core`; the client only draws.

## Files
| File | Role |
| --- | --- |
| `AttackExecution.luau` | One running attack. Priority queue of enemy/unowned border tiles; each tick it conquers tiles until the tick "budget" is spent, charging troops per tile. |
| `AttackImpl.luau` | Data object for an attack (troops, border set, target, retreat flags). |
| `Config.luau` | Tunables. `attackLogic()` = per-tile troop loss / defender loss / tick cost; `attackAmount()`, `startManpower()`, `maxTroops()`, `structureMinDist()`, spawn-phase length. |
| `PlayerImpl.luau` | `conquer(tile)`, border bookkeeping, `canAttack`, `validStructureSpawnTiles` (structure spacing), troops/gold. |
| `GameRunner.luau` | Turns wire intents (`attack`, `spawn`, ...) into executions. |

## How an attack works (upstream behaviour, unchanged unless noted)
1. Client click -> intent `click`/`attack_at` (tile, ratio) -> `GameServer` checks `me:canAttack(tile)` and queues
   `{type="attack", targetID, ratio, focusTile}`; troops = remaining_troops * ratio (computed when the tick applies it).
2. `AttackExecution.new(startTroops, owner, targetID, sourceTile, removeTroops, focusTile)`. `init()` deducts troops,
   creates the `AttackImpl`, merges with other attacks on the same target, cancels against opposing attacks.
3. `_refreshToConquer()` enqueues every neighbour of the owner's border tiles that belongs to the target
   (`_addNeighbors`). Priority (lower = conquered earlier):
   `(rand(0..7)+10) * (1 - numNeighboursOwnedByMe*0.5 + terrainMagnitude/2) + currentTick`
   (more own neighbours -> earlier; mountains later; the `+tick` term makes the queue roughly FIFO).
4. `tick()`: `tickBudget = 1`; while budget > 0: dequeue a tile, verify it is still the target's, land, and borders
   us; add its neighbours; call `Config:attackLogic(input)` -> `attackerTroopLoss, defenderTroopLoss, tickFraction`;
   `tickBudget -= tickFraction`; subtract losses; `owner:conquer(tile)`. Stops when troops < 1 (attack dies) or the
   queue empties (attack ends, remaining troops return).
5. `attackLogic`: terrain magnitude/cost base, defense posts (bonus), fallout, large-territory bonuses, troop ratio
   (defender troops / attack troops clamps 0.6..2 for loss, 0.82..7.5 for speed), traitor debuffs, bots as defenders.
   Unowned land (terra nullius) is cheap and fast.

## Changes made in this fork (search for them)
* **Directed attack** - `focusTile`: `AttackExecution._addNeighbors` adds `0.6 * distance(tile, focusTile)` to the
  priority, so border tiles near the click are conquered first (soft bias; far tiles lag, not blocked). Only set for
  human `click`/`attack_at` intents (`GameServer.server.luau`, `GameRunner.luau` passes `intent.focusTile`); AI attacks
  and boats leave it `nil` = exact upstream behaviour. Tune the 0.6 constant.
* **Structure spacing** - `PlayerImpl:validStructureSpawnTiles`: humans 6 tiles between structures, others keep
  `Config:structureMinDist()` (15). The server snaps a build to the nearest valid own tile within radius 15.
* **Fair start** - `Config:startManpower` = 25000 for everyone (upstream nations differ). This (and other fork
  changes) is why the golden tests in `tests/` already mismatch from tick ~100 (`SimSpec`, `NationVectorsHard`).
* Spawn phase lengthened (`Config:numSpawnPhaseTurns`).

## Ideas the owner wants explored
* Make the directed attack feel stronger or switch to a "wedge" (conquer a cone from the click), keeping AI untouched.
* Keep determinism: no `math.random`; use the execution's `PseudoRandom`.
* Any change to shared simulation code must stay identical on every server; the client never simulates captures.

## How to test in Studio
```lua
local SimSpec = require(game.ServerStorage.Tests.SimSpec)
SimSpec.reset("NationVectorsHard"); print(SimSpec.run(600))   -- fork already diverges from upstream goldens
```
Practical test: Play -> Solo Campaign -> pick spawn -> click a neighbour; watch which part of the border advances.
`node tools/build.mjs` regenerates `build/OpenFront.rbxlx` from `src/`.

## Prompt you can paste to the other Claude
> You are working on the files in this folder (Luau, Roblox). Goal: <describe the change to conquest/attack physics>.
> Read README.md first. Keep AI behaviour deterministic and unchanged unless asked. Explain the formula you change,
> give before/after numbers, and list every edited function so it can be merged back into `src/server/Core`.


---

# SOURCE CODE

### AttackExecution.luau (src/server/Core/Execution)

```lua
-- Port of OpenFrontIO src/core/execution/AttackExecution.ts.
--
-- The heart of territorial expansion: a priority queue of enemy/unowned
-- border tiles (terrain + randomness + how surrounded each tile is) that the
-- attack conquers each tick until its tick budget is spent.

local Shared = game:GetService("ReplicatedStorage").Shared
local FlatBinaryHeap = require(Shared.FlatBinaryHeap)
local GameMap = require(Shared.GameMap)
local JSSet = require(Shared.JSSet)
local PseudoRandom = require(Shared.PseudoRandom)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)

local PlayerType = GameTypes.PlayerType
local Difficulty = GameTypes.Difficulty
local MessageType = GameTypes.MessageType
local UnitType = GameTypes.UnitType
local TerrainType = GameMap.TerrainType

local malusForRetreat = 25

local AttackExecution = {}
AttackExecution.__index = AttackExecution

-- targetID nil means Terra Nullius (upstream terraNullius().id() is null).
function AttackExecution.new(startTroops: number?, owner, targetID: string?, sourceTile: number?, removeTroops: boolean?, focusTile: number?)
	return setmetatable({
		-- Optional click point of a human-directed attack: border tiles nearer to it
		-- are conquered first (nil = upstream behaviour, golden-vector safe).
		_focusTile = focusTile,
		_active = true,
		_toConquer = FlatBinaryHeap.new(),
		_random = PseudoRandom.new(123),
		_startTroops = startTroops,
		_owner = owner,
		_targetID = targetID,
		_sourceTile = sourceTile,
		_removeTroops = if removeTroops == nil then true else removeTroops,
		_attack = nil,
		_nbuf = { 0, 0, 0, 0 },
		_nbuf2 = { 0, 0, 0, 0 },
	}, AttackExecution)
end

function AttackExecution:targetID(): string?
	return self._targetID
end

function AttackExecution:activeDuringSpawnPhase(): boolean
	return false
end

function AttackExecution:init(mg, _ticks: number)
	if not self._active then
		return
	end
	self.mg = mg
	self.map = mg:map()

	if self._targetID ~= nil and not mg:hasPlayer(self._targetID) then
		warn(`target {self._targetID} not found`)
		self._active = false
		return
	end

	self.target = if self._targetID == nil then mg:terraNullius() else mg:player(self._targetID)
	self._ownerSmallID = self._owner:smallID()
	self._targetSmallID = self.target:smallID()

	if self._owner == self.target then
		warn(`Player {self._owner} cannot attack itself`)
		self._active = false
		return
	end

	-- ALLIANCE CHECK — block attacks on friendly (ally or same team)
	if self.target:isPlayer() and self._owner:isFriendly(self.target) then
		self._active = false
		return
	end

	if self.target:isPlayer() then
		if self.target:type() ~= PlayerType.Bot and self._owner:type() ~= PlayerType.Bot then
			-- Don't let bots embargo since they can't trade anyway.
			self.target:addEmbargo(self._owner, true)
			self:_rejectIncomingAllianceRequests(self.target)
		end
	end

	if self.target:isPlayer() and not self._owner:canAttackPlayer(self.target) then
		self._active = false
		return
	end

	if self._startTroops == nil then
		self._startTroops = mg:config():attackAmount(self._owner, self.target)
	end
	if self._removeTroops then
		self._startTroops = math.min(self._owner:troops(), self._startTroops)
		-- Take the amount actually deducted (removeTroops floors).
		self._startTroops = self._owner:removeTroops(self._startTroops)
	end
	local attack = self._owner:createAttack(self.target, self._startTroops, self._sourceTile, JSSet.new())
	self._attack = attack

	if self._sourceTile ~= nil then
		self:_addNeighbors(self._sourceTile)
	else
		self:_refreshToConquer()
	end

	mg:stats():attack(self._owner, self.target, self._startTroops)

	for _, incoming in self._owner:incomingAttacks() do
		if incoming:attacker() == self.target then
			-- Target has opposing attack, cancel them out
			if incoming:troops() > attack:troops() then
				incoming:setTroops(incoming:troops() - attack:troops())
				attack:delete()
				self._active = false
				return
			else
				attack:setTroops(attack:troops() - incoming:troops())
				incoming:delete()
			end
		end
	end
	for _, outgoing in self._owner:outgoingAttacks() do
		if
			outgoing ~= attack
			and outgoing:target() == attack:target()
			-- Boat attacks (sourceTile set) are not combined with other attacks
			and attack:sourceTile() == nil
		then
			attack:setTroops(attack:troops() + outgoing:troops())
			outgoing:delete()
		end
	end

	mg:stats():attackMaxIncoming(self.target, attack:troops())

	if self.target:isPlayer() then
		local difficulty = mg:config():gameConfig().difficulty
		local relationChange
		if difficulty == Difficulty.Easy then
			relationChange = -60
		elseif difficulty == Difficulty.Medium then
			relationChange = -70
		elseif difficulty == Difficulty.Hard then
			relationChange = -80
		elseif difficulty == Difficulty.Impossible then
			relationChange = -100
		else
			error(`Unexpected difficulty: {difficulty}`)
		end
		self.target:updateRelation(self._owner, relationChange)
	end
end

function AttackExecution:_refreshToConquer()
	self._toConquer:clear()
	self._attack:clearBorder()
	for tile in self._owner:borderTiles() do
		self:_addNeighbors(tile)
	end
end

function AttackExecution:_retreat(malusPercent: number?)
	local attack = self._attack
	local deaths = attack:troops() * ((malusPercent or 0) / 100)
	if deaths ~= 0 then
		self.mg:displayMessage(
			"events_display.attack_cancelled_retreat",
			MessageType.ATTACK_CANCELLED,
			self._owner:id(),
			nil,
			{ troops = deaths }
		)
	end
	if self._removeTroops == false and self._sourceTile == nil then
		-- startTroops were added to the attack but never removed from the owner.
		attack:setTroops(attack:troops() - (self._startTroops or 0))
	end

	local survivors = attack:troops() - deaths
	self._owner:addTroops(survivors)
	attack:delete()
	self._active = false

	if attack:retreated() then
		self.mg:stats():attackCancel(self._owner, self.target, survivors)
	end
end

function AttackExecution:tick(_ticks: number)
	local attack = self._attack
	if attack == nil then
		error("Attack not initialized")
	end
	local troopCount = attack:troops()
	local targetIsPlayer = self.target:isPlayer()
	local targetPlayer = if targetIsPlayer then self.target else nil

	if attack:retreated() then
		if targetIsPlayer then
			self:_retreat(malusForRetreat)
		else
			self:_retreat()
		end
		self._active = false
		return
	end

	if attack:retreating() then
		return
	end

	if not attack:isActive() then
		self._active = false
		return
	end

	if targetPlayer and self._owner:isFriendly(targetPlayer) then
		-- A new alliance was created AFTER the attack started.
		self:_retreat()
		return
	end

	local map = self.map
	local nbuf = self._nbuf
	local borderSize = attack:borderSize() + self._random:nextInt(0, 5)
	-- Each tile consumes a fraction of the tick; conquer until it is spent.
	local tickBudget = 1

	while tickBudget > 0 do
		if troopCount < 1 then
			attack:delete()
			self._active = false
			return
		end

		if self._toConquer:size() == 0 then
			self:_refreshToConquer()
			self:_retreat()
			return
		end

		local tileToConquer = self._toConquer:dequeue()
		attack:removeBorderTile(tileToConquer)

		local onBorder = false
		local numNeighbors = map:neighbors4(tileToConquer, nbuf)
		for i = 1, numNeighbors do
			if map:ownerID(nbuf[i]) == self._ownerSmallID then
				onBorder = true
				break
			end
		end
		if map:ownerID(tileToConquer) ~= self._targetSmallID or not onBorder then
			continue
		end
		if not map:isLand(tileToConquer) or map:isImpassable(tileToConquer) then
			continue
		end
		self:_addNeighbors(tileToConquer)
		local attackerTroopLoss, defenderTroopLoss, tickFraction =
			self.mg:config():attackLogic(self:_attackLogicInput(troopCount, tileToConquer, borderSize))
		tickBudget -= tickFraction
		troopCount -= attackerTroopLoss
		attack:setTroops(troopCount)
		if targetPlayer then
			targetPlayer:removeTroops(defenderTroopLoss)
		end
		self._owner:conquer(tileToConquer)
		self:_handleDeadDefender()
	end
end

function AttackExecution:_attackLogicInput(attackTroops: number, tile: number, borderSize: number)
	local mg = self.mg
	local defender = if self.target:isPlayer() then self.target else nil
	local defenderHasDefensePost = defender ~= nil
		and mg:hasUnitNearby(tile, mg:config():defensePostRange(), UnitType.DefensePost, defender:id())
	return {
		terrain = self.map:terrainType(tile),
		attackTroops = attackTroops,
		attacker = { type = self._owner:type(), numTiles = self._owner:numTilesOwned() },
		defender = if defender == nil
			then nil
			else {
				type = defender:type(),
				numTiles = defender:numTilesOwned(),
				troops = defender:troops(),
				isTraitor = defender:isTraitor(),
				isDisconnectedTeammate = defender:isDisconnected() and self._owner:isOnSameTeam(defender),
			},
		defenderHasDefensePost = defenderHasDefensePost,
		falloutRatio = if mg:hasFallout(tile) then mg:numTilesWithFallout() / mg:numLandTiles() else nil,
		borderSize = borderSize,
	}
end

function AttackExecution:_rejectIncomingAllianceRequests(target)
	for _, ar in self._owner:incomingAllianceRequests() do
		if ar:requestor() == target then
			ar:reject()
			return
		end
	end
end

function AttackExecution:_addNeighbors(tile: number)
	local map = self.map
	local attack = self._attack
	local tickNow = self.mg:ticks()
	local nbuf, nbuf2 = self._nbuf, self._nbuf2

	local numNeighbors = map:neighbors4(tile, nbuf)
	for i = 1, numNeighbors do
		local neighbor = nbuf[i]
		if map:isWater(neighbor) or map:isImpassable(neighbor) or map:ownerID(neighbor) ~= self._targetSmallID then
			continue
		end
		attack:addBorderTile(neighbor)
		local numOwnedByMe = 0
		local numInner = map:neighbors4(neighbor, nbuf2)
		for j = 1, numInner do
			if map:ownerID(nbuf2[j]) == self._ownerSmallID then
				numOwnedByMe += 1
			end
		end

		local terrain = map:terrainType(neighbor)
		local mag
		if terrain == TerrainType.Plains then
			mag = 1
		elseif terrain == TerrainType.Highland then
			mag = 1.5
		elseif terrain == TerrainType.Mountain then
			mag = 2
		else
			mag = 0
		end

		local priority = (self._random:nextInt(0, 7) + 10) * (1 - numOwnedByMe * 0.5 + mag / 2) + tickNow
		local focus = self._focusTile
		if focus ~= nil then
			-- Soft directional bias: +0.6 priority (= later) per tile of distance from the click.
			priority += 0.6 * math.sqrt(self.mg:euclideanDistSquared(neighbor, focus))
		end
		self._toConquer:enqueue(neighbor, priority)
	end
end

function AttackExecution:_handleDeadDefender()
	if not (self.target:isPlayer() and self.target:numTilesOwned() < 100) then
		return
	end
	local target = self.target
	local mg = self.mg
	local owner = self._owner

	mg:conquerPlayer(owner, target)

	local MAX_PASSES = 100
	for _ = 1, MAX_PASSES do
		local progressed = false
		for tile in target:tiles() do
			local borders = false
			mg:forEachNeighbor(tile, function(t)
				if not borders and mg:owner(t) == owner then
					borders = true
				end
			end)
			if borders then
				owner:conquer(tile)
				progressed = true
			else
				local captured = false
				mg:forEachNeighbor(tile, function(neighbor)
					if captured then
						return
					end
					local no = mg:owner(neighbor)
					if no:isPlayer() and no ~= target and not no:isFriendly(target) then
						mg:player(no:id()):conquer(tile)
						captured = true
					end
				end)
				if captured then
					progressed = true
				end
			end
		end
		if not progressed then
			break
		end
	end
end

function AttackExecution:owner()
	return self._owner
end

function AttackExecution:isActive(): boolean
	return self._active
end

return AttackExecution
```

### AttackImpl.luau (src/server/Core)

```lua
-- Port of OpenFrontIO src/core/game/AttackImpl.ts.

local Shared = game:GetService("ReplicatedStorage").Shared
local JSSet = require(Shared.JSSet)
local Util = require(Shared.Util)

local AttackImpl = {}
AttackImpl.__index = AttackImpl

function AttackImpl.new(id: string, target, attacker, troops: number, sourceTile: number?, border, mg)
	return setmetatable({
		_id = id,
		_target = target,
		_attacker = attacker,
		_troops = troops,
		_sourceTile = sourceTile,
		_border = border or JSSet.new(),
		_mg = mg,
		_isActive = true,
		_borderSize = 0,
		_retreating = false,
		_retreated = false,
	}, AttackImpl)
end

function AttackImpl:sourceTile(): number?
	return self._sourceTile
end
function AttackImpl:target()
	return self._target
end
function AttackImpl:attacker()
	return self._attacker
end
function AttackImpl:troops(): number
	return self._troops
end
function AttackImpl:setTroops(troops: number)
	self._troops = math.max(0, troops)
end
function AttackImpl:isActive(): boolean
	return self._isActive
end
function AttackImpl:id(): string
	return self._id
end

local function without(list, item)
	local out = {}
	for _, v in list do
		if v ~= item then
			table.insert(out, v)
		end
	end
	return out
end

function AttackImpl:delete()
	if self._target:isPlayer() then
		self._target._incomingAttacks = without(self._target._incomingAttacks, self)
	end
	self._attacker._outgoingAttacks = without(self._attacker._outgoingAttacks, self)
	self._isActive = false
end

function AttackImpl:orderRetreat()
	self._retreating = true
end
function AttackImpl:executeRetreat()
	self._retreated = true
end
function AttackImpl:retreating(): boolean
	return self._retreating
end
function AttackImpl:retreated(): boolean
	return self._retreated
end

function AttackImpl:borderSize(): number
	return self._borderSize
end

function AttackImpl:clearBorder()
	self._borderSize = 0
	self._border:clear()
end

function AttackImpl:addBorderTile(tile: number)
	if not self._border:has(tile) then
		self._borderSize += 1
		self._border:add(tile)
	end
end

function AttackImpl:removeBorderTile(tile: number)
	if self._border:has(tile) then
		self._borderSize -= 1
		self._border:delete(tile)
	end
end

-- Top 2 clustered positions of the attack's border (for troop labels).
-- If the second cluster is too small, only the largest one is returned.
function AttackImpl:clusteredPositions(): { number }
	if self._borderSize == 0 then
		local tile = self:sourceTile()
		return if tile ~= nil then { tile } else {}
	end
	return self:_clusterBorderTiles(30, 2)
end

function AttackImpl:_clusterBorderTiles(minSize: number, maxClusters: number): { number }
	local map = self._mg:map()
	local border = self._border
	local visited = {}
	local clusters = {}

	for startTile in border do
		if visited[startTile] then
			continue
		end
		local queue = { startTile }
		visited[startTile] = true
		local qi = 1
		local sumX, sumY, count = 0, 0, 0

		while qi <= #queue do
			local t = queue[qi]
			qi += 1
			sumX += map:x(t)
			sumY += map:y(t)
			count += 1
			map:forEachNeighborWithDiag(t, function(neighbor)
				if border:has(neighbor) and not visited[neighbor] then
					visited[neighbor] = true
					table.insert(queue, neighbor)
				end
			end)
		end

		-- Pick the real border tile closest to the centroid.
		local cx, cy = sumX / count, sumY / count
		local best, bestDist = queue[1], math.huge
		for _, t in queue do
			local dx = map:x(t) - cx
			local dy = map:y(t) - cy
			local dist = dx * dx + dy * dy
			if dist < bestDist then
				bestDist = dist
				best = t
			end
		end
		table.insert(clusters, { tile = best, size = count })
	end

	Util.sort(clusters, function(a, b)
		return b.size - a.size
	end)

	if #clusters == 0 then
		return {}
	elseif #clusters == 1 then
		return { clusters[1].tile }
	end
	local out = {}
	for _, c in clusters do
		if c.size >= minSize and #out < maxClusters then
			table.insert(out, c.tile)
		end
	end
	if #out == 0 then
		-- Always keep at least the largest cluster even if below minSize.
		return { clusters[1].tile }
	end
	return out
end

return AttackImpl
```

### Config.luau (src/server/Core) - all tunables incl. attackLogic

```lua
-- Port of OpenFrontIO src/core/configuration/Config.ts (simulation subset).
--
-- Formulas are transcribed exactly (same DetMath calls, same operation order)
-- so attacks, troop growth and gold match the original game.
-- Gold is a plain integer-valued number (upstream: bigint); bigint division
-- truncates, so it is written as floor division on non-negative gold.
--
-- Unit costs / nukes / trains / SAM tuning arrive with the stages that port
-- those systems.

local Shared = game:GetService("ReplicatedStorage").Shared
local DetMath = require(Shared.DetMath)
local GameMap = require(Shared.GameMap)
local Util = require(Shared.Util)
local GameTypes = require(script.Parent.GameTypes)

local PlayerType = GameTypes.PlayerType
local Difficulty = GameTypes.Difficulty
local GameType = GameTypes.GameType
local UnitType = GameTypes.UnitType
local TerrainType = GameMap.TerrainType

local log, pow = DetMath.log, DetMath.pow
local within, sigmoid, toInt = Util.within, Util.sigmoid, Util.toInt

-- attackLogic tunables
local LARGE_TERRITORY_MIDPOINT = 300000
local LARGE_TERRITORY_STEEPNESS = 2.5
local LARGE_ATTACKER_DEPTH = 0.7
local LARGE_DEFENDER_DEPTH = 0.3
local BOT_DEFENDER_LOSS_MULT = 0.7
local TERRA_NULLIUS_COST_SCALE = 2000
local TERRA_NULLIUS_MIN_COST = 5
local TERRA_NULLIUS_MAX_COST = 100
local ATTACKER_LOSS_BASE = 0.463
local ATTACKER_LOSS_PER_DENSITY = 0.0039
local SPEED_COST_DIVISOR = 11.5
local LARGE_ATTACKER_SPEED_DEPTH = 0.73

local DEFAULT_SPAWN_IMMUNITY_TICKS = 150
local PERCENT_TILES_OWNED_TO_WIN = 80

local OVERTIME_DEFAULTS = { enabled = false, startMinutes = 30, dropPercentPerMinute = 2 }

-- Logistic in log(tiles): ~1 for small territories, easing down to
-- 1 - depth for huge ones, halfway at LARGE_TERRITORY_MIDPOINT.
local function largeTerritoryBonus(numTiles: number, depth: number): number
	return 1 - depth * sigmoid(log(numTiles), LARGE_TERRITORY_STEEPNESS, log(LARGE_TERRITORY_MIDPOINT))
end

local function terrainAttackBase(terrain: number): (number, number)
	if terrain == TerrainType.Plains then
		return 80, 16.5
	elseif terrain == TerrainType.Highland then
		return 100, 20
	elseif terrain == TerrainType.Mountain then
		return 120, 25
	elseif terrain == TerrainType.Impassable then
		error("impassable terrain cannot be attacked")
	end
	error(`terrain type {terrain} not supported`)
end

local Config = {}
Config.__index = Config

--[[
	gameConfig fields (upstream GameConfigSchema): gameMap, difficulty,
	donateGold, donateTroops, gameType, gameMode, gameMapSize, bots,
	randomSpawn, infiniteGold, infiniteTroops, instantBuild, disabledUnits,
	playerTeams, nations, startingGold, goldMultiplier, spawnImmunityDuration,
	customAllianceDuration, disableAlliances, waterNukes, disableNavMesh,
	hostCheats, overtime, doomsdayClock.
]]
function Config.new(gameConfig: { [string]: any })
	return setmetatable({ _gameConfig = gameConfig }, Config)
end

function Config:gameConfig()
	return self._gameConfig
end

function Config:traitorDefenseDebuff(): number
	return 0.5
end
function Config:traitorSpeedDebuff(): number
	return 0.8
end
function Config:traitorDuration(): number
	return 30 * 10
end
function Config:teamLandShareWinThresholdTenths(): number
	return 7
end

function Config:overtimeConfig()
	local c = self._gameConfig.overtime
	return {
		enabled = if c and c.enabled ~= nil then c.enabled else OVERTIME_DEFAULTS.enabled,
		startMinutes = if c and c.startMinutes ~= nil then c.startMinutes else OVERTIME_DEFAULTS.startMinutes,
		dropPercentPerMinute = OVERTIME_DEFAULTS.dropPercentPerMinute,
	}
end

function Config:doomsdayClockConfig()
	-- TODO(port): Doomsday Clock (anti-stall mode) — only `enabled` is read so far.
	local c = self._gameConfig.doomsdayClock
	return { enabled = c ~= nil and c.enabled == true }
end

function Config:spawnImmunityDuration(): number
	return self._gameConfig.spawnImmunityDuration or DEFAULT_SPAWN_IMMUNITY_TICKS
end
function Config:nationSpawnImmunityDuration(): number
	return DEFAULT_SPAWN_IMMUNITY_TICKS
end
function Config:hasExtendedSpawnImmunity(): boolean
	return self:spawnImmunityDuration() > DEFAULT_SPAWN_IMMUNITY_TICKS
end

function Config:cityTroopIncrease(): number
	return 250000
end

-- falloutRatio is between 0 and 1, so the modifier is between [5, 2.5].
function Config:falloutDefenseModifier(falloutRatio: number): number
	return 5 - falloutRatio * 2
end

function Config:msPerTick(): number
	return 100
end
function Config:SAMCooldown(): number
	-- Roblox port: 130 (upstream 90), players found SAMs too strong.
	return 130
end
function Config:SiloCooldown(): number
	return 90
end
function Config:defensePostRange(): number
	return 30
end
function Config:defensePostDefenseBonus(): number
	return 5
end
function Config:defensePostSpeedBonus(): number
	return 3
end

function Config:playerTeams()
	return self._gameConfig.playerTeams or 0
end
function Config:spawnNations(): boolean
	return self._gameConfig.nations ~= "disabled"
end
function Config:isUnitDisabled(unitType: string): boolean
	local disabled = self._gameConfig.disabledUnits
	return disabled ~= nil and table.find(disabled, unitType) ~= nil
end
function Config:bots(): number
	return self._gameConfig.bots
end
function Config:instantBuild(): boolean
	return self._gameConfig.instantBuild == true
end
function Config:disableNavMesh(): boolean
	return self._gameConfig.disableNavMesh == true
end
function Config:disableAlliances(): boolean
	-- customAllianceDuration == 0 disables alliances; the legacy boolean is honored too.
	return self._gameConfig.customAllianceDuration == 0 or self._gameConfig.disableAlliances == true
end
function Config:waterNukes(): boolean
	return self._gameConfig.waterNukes == true
end
function Config:isRandomSpawn(): boolean
	return self._gameConfig.randomSpawn == true
end
function Config:infiniteGold(): boolean
	return self._gameConfig.infiniteGold == true
end
function Config:donateGold(): boolean
	return self._gameConfig.donateGold == true
end
function Config:infiniteTroops(): boolean
	return self._gameConfig.infiniteTroops == true
end
function Config:donateTroops(): boolean
	return self._gameConfig.donateTroops == true
end
function Config:goldMultiplier(): number
	return self._gameConfig.goldMultiplier or 1
end

function Config:_hostCheats()
	return self._gameConfig.hostCheats or {}
end

function Config:startingGold(playerInfo): number
	if playerInfo.playerType == PlayerType.Bot then
		return 0
	end
	local base = self._gameConfig.startingGold or 0
	local hc = self:_hostCheats()
	if hc.startingGold and playerInfo.isLobbyCreator then
		return base + hc.startingGold
	end
	return base
end

function Config:_hasInfiniteTroopsFor(player): boolean
	if self:infiniteTroops() then
		return true
	end
	return self:_hostCheats().infiniteTroops == true and player:isLobbyCreator()
end

function Config:_hasInfiniteTroopsForInfo(playerInfo): boolean
	if self:infiniteTroops() then
		return true
	end
	return self:_hostCheats().infiniteTroops == true and playerInfo.isLobbyCreator
end

function Config:_goldMultiplierFor(player): number
	local hc = self:_hostCheats()
	if hc.goldMultiplier and player:isLobbyCreator() then
		return hc.goldMultiplier
	end
	return self:goldMultiplier()
end

function Config:conquerGoldAmount(captured): number
	local t = captured:type()
	if t == PlayerType.Bot or t == PlayerType.Nation then
		return captured:gold()
	end
	return captured:gold() // 2
end

function Config:defaultDonationAmount(sender): number
	return math.floor(sender:troops() / 3)
end
function Config:donateCooldown(): number
	return 10 * 10
end
function Config:embargoAllCooldown(): number
	return 10 * 10
end
function Config:deletionMarkDuration(): number
	return 30 * 10
end
function Config:deleteUnitCooldown(): number
	return 30 * 10
end
function Config:emojiMessageDuration(): number
	return 5 * 10
end
function Config:emojiMessageCooldown(): number
	return 5 * 10
end
function Config:quickChatCooldown(): number
	return 3 * 10
end
function Config:targetDuration(): number
	return 10 * 10
end
function Config:targetCooldown(): number
	return 15 * 10
end
function Config:allianceRequestDuration(): number
	return 20 * 10
end
function Config:allianceRequestCooldown(): number
	return 30 * 10
end
function Config:allianceDuration(): number
	-- Host-set duration in minutes (1-15); falls back to 5 minutes.
	local m = self._gameConfig.customAllianceDuration
	if type(m) == "number" and m > 0 then
		return m * 60 * 10
	end
	return 300 * 10
end
function Config:temporaryEmbargoDuration(): number
	return 300 * 10
end
function Config:minDistanceBetweenPlayers(): number
	return 30
end
function Config:allianceExtensionPromptOffset(): number
	return 300
end

function Config:percentageTilesOwnedToWin(elapsedGameSeconds: number): number
	local base = PERCENT_TILES_OWNED_TO_WIN
	local sd = self:overtimeConfig()
	if not sd.enabled then
		return base
	end
	local secondsPastStart = math.floor(elapsedGameSeconds) - sd.startMinutes * 60
	if secondsPastStart <= 0 then
		return base
	end
	return math.max(0, base - math.floor((secondsPastStart * sd.dropPercentPerMinute) / 60))
end

function Config:armyLimitWarningThreshold(): number
	return 0.8
end

function Config:boatMaxNumber(): number
	if self:isUnitDisabled(UnitType.TransportShip) then
		return 0
	end
	return 3
end

function Config:numSpawnPhaseTurns(): number
	-- Roblox port: give the human more time to pick a starting territory before
	-- the AI starts expanding (was 100 / 150 / 200).
	if self._gameConfig.gameType == GameType.Singleplayer then
		return 250
	end
	if self:isRandomSpawn() then
		return 350
	end
	return 450
end

function Config:numBots(): number
	return self:bots()
end

--[[
	Per-tile attack outcome. Pure: depends only on `input` and tunables.
	Returns attackerTroopLoss, defenderTroopLoss, tickFraction.

	input = {
		terrain, attackTroops,
		attacker = { type, numTiles },
		defender = { type, numTiles, troops, isTraitor, isDisconnectedTeammate } | nil,
		defenderHasDefensePost, falloutRatio (number | nil), borderSize,
	}
]]
function Config:attackLogic(input): (number, number, number)
	local attackTroops = input.attackTroops
	local attacker = input.attacker
	local defender = input.defender
	local mag, tileCost = terrainAttackBase(input.terrain)

	if defender ~= nil and input.defenderHasDefensePost then
		mag *= self:defensePostDefenseBonus()
		tileCost *= self:defensePostSpeedBonus()
	end
	if input.falloutRatio ~= nil then
		local fallout = self:falloutDefenseModifier(input.falloutRatio)
		mag *= fallout
		tileCost *= fallout
	end

	if defender == nil then
		local tickBudget = input.borderSize * 2
		return mag / (if attacker.type == PlayerType.Bot then 10 else 5),
			0,
			within((TERRA_NULLIUS_COST_SCALE * tileCost) / attackTroops, TERRA_NULLIUS_MIN_COST, TERRA_NULLIUS_MAX_COST)
				/ tickBudget
	end

	if defender.isDisconnectedTeammate then
		-- No troop loss if defender is disconnected and on same team
		mag = 0
	end
	if (attacker.type == PlayerType.Human or attacker.type == PlayerType.Nation) and defender.type == PlayerType.Bot then
		mag *= BOT_DEFENDER_LOSS_MULT
	end

	local largeAttackerBonus = largeTerritoryBonus(attacker.numTiles, LARGE_ATTACKER_DEPTH)
	local largeDefenderBonus = largeTerritoryBonus(defender.numTiles, LARGE_DEFENDER_DEPTH)

	local traitorLossMod = if defender.isTraitor then self:traitorDefenseDebuff() else 1
	local traitorCostMod = if defender.isTraitor then self:traitorSpeedDebuff() else 1

	-- Defender loses its average troops-per-tile.
	local defenderTroopLoss = defender.troops / defender.numTiles

	local troopRatio = defender.troops / attackTroops
	local attackerTroopLoss = mag
		* traitorLossMod
		* within(troopRatio, 0.6, 2)
		* (ATTACKER_LOSS_BASE * largeAttackerBonus * largeDefenderBonus + ATTACKER_LOSS_PER_DENSITY * defenderTroopLoss)

	local speedCost = (within(troopRatio, 0.82, 7.5) * within(troopRatio / 20, 1, 50)) / SPEED_COST_DIVISOR
	local largeAttackerSpeedBonus = largeTerritoryBonus(attacker.numTiles, LARGE_ATTACKER_SPEED_DEPTH)
	return attackerTroopLoss,
		defenderTroopLoss,
		(speedCost * tileCost * largeAttackerSpeedBonus * largeDefenderBonus * traitorCostMod) / input.borderSize
end

function Config:boatAttackAmount(attacker, _defender): number
	return math.floor(attacker:troops() / 5)
end

function Config:attackAmount(attacker, _defender): number
	if attacker:type() == PlayerType.Bot then
		return attacker:troops() / 20
	end
	return attacker:troops() / 5
end

function Config:startManpower(playerInfo): number
	-- FAIR START: every human, bot and nation starts with the same army.
	if self:_hasInfiniteTroopsForInfo(playerInfo) then
		return 1000000
	end
	return 25000
end

function Config:maxTroops(player): number
	-- OpenFront reference formula (Config.ts troopCap): more land -> higher cap,
	-- cities add capacity. The same formula is used for humans, bots and
	-- nations, so nobody gets hidden type bonuses.
	if player:type() == PlayerType.Human and self:_hasInfiniteTroopsFor(player) then
		return 1000000000
	end
	local cityLevels = 0
	for _, city in player:units(UnitType.City) do
		if not city:isUnderConstruction() then
			cityLevels += city:level()
		end
	end
	return 2 * (pow(player:numTilesOwned(), 0.6) * 1000 + 50000) + cityLevels * self:cityTroopIncrease()
end

function Config:troopIncreaseRate(player): number
	-- OpenFront reference formula: small armies regrow very fast, large ones
	-- slow down; a bigger country (higher cap) keeps growing longer.
	local max = self:maxTroops(player)
	local toAdd = 10 + pow(player:troops(), 0.73) / 4
	local ratio = 1 - player:troops() / math.max(max, 1)
	toAdd *= math.max(ratio, 0)
	return math.min(player:troops() + toAdd, max) - player:troops()
end

-- Units ----------------------------------------------------------------------------

local SAM_CONSTRUCTION_TICKS = 30 * 10
Config.SAM_CONSTRUCTION_TICKS = SAM_CONSTRUCTION_TICKS

function Config:_hasInfiniteGoldFor(player): boolean
	if self:infiniteGold() then
		return true
	end
	return self:_hostCheats().infiniteGold == true and player:isLobbyCreator()
end

-- Cost counts built units of `types` (owned vs constructed, whichever is lower).
function Config:_costWrapper(costFn: (number) -> number, ...: string)
	local types = { ... }
	return function(_game, player, extraUnits: number?): number
		if player:type() == PlayerType.Human and self:_hasInfiniteGoldFor(player) then
			return 0
		end
		local numUnits = 0
		for _, t in types do
			numUnits += math.min(player:unitsOwned(t), player:unitsConstructed(t))
		end
		return math.floor(costFn(numUnits + (extraUnits or 0)))
	end
end

local function free()
	return 0
end

-- UnitInfo: { cost(game, player, extraUnits?) -> gold, maxHealth?, damage?,
-- constructionDuration?, upgradable? }
function Config:unitInfo(unitType: string)
	self._unitInfoCache = self._unitInfoCache or {}
	local cached = self._unitInfoCache[unitType]
	if cached then
		return cached
	end
	local pow2 = DetMath.pow2
	local instant = self:instantBuild()
	local info
	if unitType == UnitType.TransportShip then
		info = { cost = free }
	elseif unitType == UnitType.Warship then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(1000000, (n + 1) * 250000)
			end, UnitType.Warship),
			maxHealth = 1000,
		}
	elseif unitType == UnitType.Shell then
		info = { cost = free, damage = 250 }
	elseif unitType == UnitType.SAMMissile then
		info = { cost = free }
	elseif unitType == UnitType.Port then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(1000000, pow2(n) * 125000)
			end, UnitType.Port, UnitType.Factory),
			constructionDuration = if instant then 0 else 5 * 10,
			upgradable = true,
		}
	elseif unitType == UnitType.AtomBomb then
		info = { cost = self:_costWrapper(function()
			return 750000
		end, UnitType.AtomBomb) }
	elseif unitType == UnitType.HydrogenBomb then
		info = { cost = self:_costWrapper(function()
			return 5000000
		end, UnitType.HydrogenBomb) }
	elseif unitType == UnitType.MIRV then
		info = {
			cost = function(game, player)
				if player:type() == PlayerType.Human and self:_hasInfiniteGoldFor(player) then
					return 0
				end
				return 25000000 + game:stats():numMirvsLaunched() * 15000000
			end,
		}
	elseif unitType == UnitType.MIRVWarhead or unitType == UnitType.TradeShip or unitType == UnitType.Train then
		info = { cost = free }
	elseif unitType == UnitType.MissileSilo then
		info = {
			cost = self:_costWrapper(function()
				return 1000000
			end, UnitType.MissileSilo),
			constructionDuration = if instant then 0 else 10 * 10,
			upgradable = true,
		}
	elseif unitType == UnitType.DefensePost then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(250000, (n + 1) * 50000)
			end, UnitType.DefensePost),
			constructionDuration = if instant then 0 else 5 * 10,
		}
	elseif unitType == UnitType.SAMLauncher then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(3000000, (n + 1) * 1500000)
			end, UnitType.SAMLauncher),
			constructionDuration = if instant then 0 else SAM_CONSTRUCTION_TICKS,
			upgradable = true,
		}
	elseif unitType == UnitType.City then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(1000000, pow2(n) * 125000)
			end, UnitType.City),
			constructionDuration = if instant then 0 else 2 * 10,
			upgradable = true,
		}
	elseif unitType == UnitType.Factory then
		info = {
			cost = self:_costWrapper(function(n)
				return math.min(1000000, pow2(n) * 125000)
			end, UnitType.Factory, UnitType.Port),
			constructionDuration = if instant then 0 else 2 * 10,
			upgradable = true,
		}
	else
		error(`Unexpected unit type: {unitType}`)
	end
	self._unitInfoCache[unitType] = info
	return info
end

-- Nukes ------------------------------------------------------------------------------------

function Config:nukeMagnitudes(unitType: string): { inner: number, outer: number }
	if unitType == UnitType.MIRVWarhead then
		-- Roblox port: stronger than upstream (12 / 18), players found MIRVs too weak.
		return { inner = 16, outer = 24 }
	elseif unitType == UnitType.AtomBomb then
		return { inner = 12, outer = 30 }
	elseif unitType == UnitType.HydrogenBomb then
		return { inner = 80, outer = 100 }
	end
	error(`Unknown nuke type: {unitType}`)
end
function Config:nukeAllianceBreakThreshold(): number
	return 100
end
function Config:nukeSpeed(unitType: string): number
	if unitType == UnitType.AtomBomb or unitType == UnitType.HydrogenBomb then
		return 10
	elseif unitType == UnitType.MIRV then
		return 15
	elseif unitType == UnitType.MIRVWarhead then
		return 22
	end
	error(`Unknown nuke type: {unitType}`)
end
function Config:mirvNormalizeTargetTicks(): number
	return 14
end
function Config:defaultNukeTargetableRange(): number
	return 150
end
-- Humans can be soldiers, soldiers attacking, soldiers in boat etc.
function Config:nukeDeathFactor(nukeType: string, humans: number, tilesOwned: number, maxTroops: number): number
	if nukeType ~= UnitType.MIRVWarhead then
		return (5 * humans) / math.max(1, tilesOwned)
	end
	local targetTroops = 0.03 * maxTroops
	local excessTroops = math.max(0, humans - targetTroops)
	local scalingFactor = 500
	local steepness = 2
	local normalizedExcess = excessTroops / maxTroops
	return scalingFactor * (1 - DetMath.exp(-steepness * normalizedExcess))
end

function Config:defaultSamRange(): number
	return 70
end
function Config:maxSamRange(): number
	-- Roblox port: 130 (upstream 150): level 1 covers 50 tiles instead of 70.
	return 130
end
function Config:samRange(level: number): number
	return self:maxSamRange() - 480 / (level + 5)
end
function Config:samUpgradeDuration(): number
	return math.floor(self:SAMCooldown() / 2)
end
function Config:dynamicSamRange(sam, currentTick: number): number
	local state = sam:samLauncherState()
	if state == nil or state.upgradeStartTick == nil then
		return self:samRange(sam:level())
	end
	local duration = state.duration or self:samUpgradeDuration()
	local elapsed = currentTick - state.upgradeStartTick
	if elapsed >= duration then
		return self:samRange(state.targetLevel)
	end
	local targetRange = self:samRange(state.targetLevel)
	return state.startRange + ((targetRange - state.startRange) * elapsed) / duration
end
function Config:defaultSamMissileSpeed(): number
	return 12
end
function Config:structureMinDist(): number
	return 15
end
function Config:shellLifetime(): number
	return 50
end
function Config:warshipShellLifetime(): number
	return 20
end
function Config:warshipPatrolRange(): number
	return 100
end
function Config:warshipTargettingRange(): number
	return 130
end
function Config:warshipShellAttackRate(): number
	return 20
end
function Config:warshipDockingRange(): number
	return 5
end
function Config:warshipPortHealingBonusPerLevel(): number
	return 5
end
function Config:warshipRetreatHealthPercent(): number
	return 75
end
function Config:warshipPassiveHealing(): number
	return 1
end
function Config:warshipPassiveHealingRange(): number
	return 150
end
function Config:warshipPortSwitchThreshold(): number
	return 0.75
end
function Config:warshipMaxVeterancy(): number
	return 3
end
function Config:warshipVeterancyHealthBonus(): number
	return 20
end
function Config:warshipVeterancyShellDamageBonus(): number
	return 20
end
function Config:warshipVeterancyTransportKills(): number
	return 10
end
function Config:warshipVeterancyTradeCaptures(): number
	return 25
end
function Config:defensePostShellAttackRate(): number
	return 100
end
function Config:safeFromPiratesCooldownMax(): number
	return 20
end
function Config:defensePostTargettingRange(): number
	return 75
end
function Config:radiusPortSpawn(): number
	return 20
end

-- Trade & trains --------------------------------------------------------------------

local LN2 = 0.6931471805599453 -- JS Math.LN2

function Config:tradeShipShortRangeDebuff(): number
	return 300
end

function Config:proximityBonusPortsNb(totalPorts: number): number
	return within(totalPorts / 3, 4, totalPorts)
end

function Config:tradeShipGold(dist: number, player): number
	local debuff = self:tradeShipShortRangeDebuff()
	local baseGold = 75000 / (1 + DetMath.exp(-0.03 * (dist - debuff))) + 50 * dist
	return math.floor(baseGold * self:_goldMultiplierFor(player))
end

function Config:tradeShipSaturation(numTradeShips: number): number
	local boost = 1 + 0.45 * DetMath.exp(-numTradeShips / 120)
	local damping = 1 - sigmoid(numTradeShips, LN2 / 50, 330)
	local plateau = 0.25 * (1 - sigmoid(numTradeShips, LN2 / 100, 800))
	return boost * math.max(damping, plateau)
end

function Config:tradeShipSpawnRate(rejections: number, numTradeShips: number): number
	local rejectionModifier = 1 / (rejections + 1)
	return math.max(1, math.floor((100 * rejectionModifier) / self:tradeShipSaturation(numTradeShips)))
end

function Config:trainSaturation(numTrainUnits: number): number
	local boost = 1 + 0.5 * DetMath.exp(-numTrainUnits / 30)
	local damping = 1 - sigmoid(numTrainUnits, LN2 / 100, 560)
	local plateau = 0.25 * (1 - sigmoid(numTrainUnits, LN2 / 150, 900))
	return boost * math.max(damping, plateau)
end

function Config:trainSpawnRate(numPlayerFactories: number, numTrainUnits: number): number
	local rate = (numPlayerFactories + 10) * 15
	return math.max(1, math.floor(rate / self:trainSaturation(numTrainUnits)))
end

function Config:trainGold(rel: string, citiesVisited: number, player): number
	citiesVisited = math.max(0, citiesVisited - 9)
	local baseGold
	if rel == "ally" then
		baseGold = 35000
	elseif rel == "team" or rel == "other" then
		baseGold = 25000
	else -- "self"
		baseGold = 10000
	end
	local gold = math.max(5000, baseGold - citiesVisited * 5000)
	return toInt(gold * self:_goldMultiplierFor(player))
end

function Config:trainStationMinRange(): number
	return 15
end
function Config:trainStationMaxRange(): number
	return 110
end
function Config:railroadMaxSize(): number
	return self:trainStationMaxRange() * 1.4142
end

function Config:goldAdditionRate(player): number
	local multiplier = self:_goldMultiplierFor(player)
	local baseRate = 100 -- FAIR ECONOMY: identical for bots, nations and humans
	return math.floor(baseRate * multiplier)
end

return Config
```

### PlayerImpl.luau - excerpts (conquer / structure placement)

```lua
function PlayerImpl:conquer(tile: number)
	self.mg:conquer(self, tile)
end

function PlayerImpl:validStructureSpawnTiles(tile: number): { number }
	local mg = self.mg
	if mg:owner(tile) ~= self then
		return {}
	end
	local searchRadius = 15
	local r2 = searchRadius * searchRadius
	local nearbyUnits = mg:nearbyUnits(tile, searchRadius * 2, Structures.types, nil, true)
	local map = mg:map()
	local w = map:width()
	local cx, cy = tile % w, tile // w
	local smallID = self._smallID
	local function inside(t: number): boolean
		local dx, dy = t % w - cx, t // w - cy
		return dx * dx + dy * dy < r2 and map:ownerID(t) == smallID
	end
	local scratch = Scratch.get(mg)
	local gen = Scratch.bump(scratch)
	local visited = scratch.visited
	local stack = scratch.stack
	table.clear(stack)
	local nearbyTiles = {}
	if inside(tile) then
		buffer.writeu32(visited, tile * 4, gen)
		table.insert(nearbyTiles, tile)
		table.insert(stack, tile)
	end
	local function visit(n: number)
		if buffer.readu32(visited, n * 4) ~= gen and inside(n) then
			buffer.writeu32(visited, n * 4, gen)
			table.insert(nearbyTiles, n)
			table.insert(stack, n)
		end
	end
	while #stack > 0 do
		map:forEachNeighbor(table.remove(stack) :: number, visit)
	end
	-- Humans may build structures closer together (6 tiles) than the upstream 15; nations/bots keep the original rule (golden vectors).
	local minDist2 = (if self:type() == PlayerType.Human then 6 else mg:config():structureMinDist()) ^ 2
	local valid = {}
	for _, t in nearbyTiles do
		local blocked = false
		for _, entry in nearbyUnits do
			if mg:euclideanDistSquared(entry.unit:tile(), t) < minDist2 then
				blocked = true
				break
			end
		end
		if not blocked then
			table.insert(valid, t)
		end
	end
	Util.sort(valid, function(a, b)
		return mg:euclideanDistSquared(a, tile) - mg:euclideanDistSquared(b, tile)
	end)
	return valid
end

function PlayerImpl:landBasedStructureSpawn(tile: number, validTiles): number | false
	local tiles = validTiles or self:validStructureSpawnTiles(tile)
	if #tiles == 0 then
		return false
	end
	return tiles[1]
end
```

### GameRunner.luau - how an attack intent becomes an execution (excerpt)

```lua

		mapThemes = mapThemes,
		-- Add one to avoid id collisions with tribes.
		random = PseudoRandom.new(Util.simpleHash(gameID) + 1),
	}, Executor)
end

function Executor:createExec(intent)
	local player = self.mg:playerByClientID(intent.clientID)
	if not player then
		warn(`player with clientID {intent.clientID} not found`)
		return SmallExecutions.NoOpExecution.new()
	end
	local t = intent.type
	if t == "attack" then
		return AttackExecution.new(intent.troops, player, intent.targetID, nil, nil, intent.focusTile)
	elseif t == "cancel_attack" then
		return SmallExecutions.RetreatExecution.new(player, intent.attackID)
	elseif t == "spawn" then
		-- fromIntent: subject to the spawn-phase gate.
		return SpawnExecution.new(self.gameID, player:info(), intent.tile, true)
	elseif t == "boat" then
		return TransportShipExecution.new(player, intent.dst, intent.troops)
	elseif t == "cancel_boat" th
```

### GameServer.server.luau - click / attack_at intents (excerpt, where focusTile is attached)

```lua
elseif t == "click" then
		-- Upstream ClientGameRunner.inputEvent: land attack when the tile is
		-- attackable, else an auto-boat when a launch shore is within 100 tiles.
		local tile, ratio = intent.tile, intent.ratio
		if not isInt(tile) or not mg:isValidRef(tile) or type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio > 1 then
			return
		end
		if mg:inSpawnPhase() then
			return
		end
		if me:canAttack(tile) then
			local owner = mg:owner(tile)
			table.insert(pending, { type = "attack", clientID = clientID, targetID = owner:id(), ratio = ratio, focusTile = tile })
		elseif mg:isLand(tile) then
			local spawn = me:canBuild("Transport", tile)
			if spawn ~= false and mg:euclideanDistSquared(tile, spawn) < 100 * 100 then
				table.insert(pending, { type = "boat", clientID = clientID, dst = tile, ratio = ratio })
			end
		end
	elseif t == "attack_at" or t == "boat_at" then
		-- Radial menu: centre button attack / boat slot (no auto-boat range limit).
		local tile, ratio = intent.tile, intent.ratio
		if not isInt(tile) or not mg:isValidRef(tile) or type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio > 1 then
			return
		end
		if mg:inSpawnPhase() then
			return
		end
		if t == "attack_at" then
			if me:canAttack(tile) then
				table.insert(pending, { type = "attack", clientID = clientID, targetID = mg:owner(tile):id(), ratio = ratio, focusTile = tile })
			end
		elseif mg:isLand(tile) and me:canBuild("Transport", tile) ~= false then
			table.insert(pending, { type = "boat", clientID = clientID, dst = tile, ratio = ratio })
		end
	elseif t == "cancel_attack" then
		if type(intent.attackID) == "string" and #intent.attackID <= 16 then
			table.insert(pending, { type = "cancel_attack", clientID = clientID, attackID = intent.attackID })
		end
	elseif t == "place" then
		-- Build menu placement: upgrade a structure in range when possible,
		-- otherwise build a new one (upstream build ghost behaviour).
		local tile, unitType = intent.tile, intent.unit
		if not isInt(tile) or not mg:isValidRef(tile) or type(unitType) ~= "string" then
			return
```
