-- Ports of small OpenFrontIO executions:
--   SpawnTimerExecution.ts, RetreatExecution.ts, NoOpExecution.ts,
--   WinCheckExecution.ts.

local Shared = game:GetService("ReplicatedStorage").Shared
local Util = require(Shared.Util)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)

local GameMode = GameTypes.GameMode
local ColoredTeams = GameTypes.ColoredTeams

local SmallExecutions = {}

-- SpawnTimerExecution: ends the spawn phase after numSpawnPhaseTurns.
local SpawnTimer = {}
SpawnTimer.__index = SpawnTimer
function SpawnTimer.new()
	return setmetatable({}, SpawnTimer)
end
function SpawnTimer:init(mg)
	self.mg = mg
end
function SpawnTimer:tick()
	if self.mg:ticks() > self.mg:config():numSpawnPhaseTurns() then
		self.mg:endSpawnPhase()
	end
end
function SpawnTimer:isActive(): boolean
	return self.mg:inSpawnPhase()
end
function SpawnTimer:activeDuringSpawnPhase(): boolean
	return true
end
SmallExecutions.SpawnTimerExecution = SpawnTimer

-- RetreatExecution: order a retreat now, execute it after cancelDelay ticks.
local CANCEL_DELAY = 20
local Retreat = {}
Retreat.__index = Retreat
function Retreat.new(player, attackID: string)
	return setmetatable({ player = player, attackID = attackID, _active = true, _retreatOrdered = false }, Retreat)
end
function Retreat:init(mg)
	self.mg = mg
	self._startTick = mg:ticks()
end
function Retreat:tick()
	if not self._retreatOrdered then
		self.player:orderRetreat(self.attackID)
		self._retreatOrdered = true
	end
	if self.mg:ticks() >= self._startTick + CANCEL_DELAY then
		self.player:executeRetreat(self.attackID)
		self._active = false
	end
end
function Retreat:owner()
	return self.player
end
function Retreat:isActive(): boolean
	return self._active
end
function Retreat:activeDuringSpawnPhase(): boolean
	return false
end
SmallExecutions.RetreatExecution = Retreat

-- BoatRetreatExecution: turn one of the player's boats around.
local BoatRetreat = {}
BoatRetreat.__index = BoatRetreat
function BoatRetreat.new(player, unitID: number)
	return setmetatable({ player = player, unitID = unitID, _active = true }, BoatRetreat)
end
function BoatRetreat:init() end
function BoatRetreat:tick()
	local found = nil
	for _, u in self.player:units() do
		if u:id() == self.unitID and u:type() == GameTypes.UnitType.TransportShip then
			found = u
			break
		end
	end
	if not found then
		warn(`Didn't find outgoing boat with id {self.unitID}`)
		self._active = false
		return
	end
	found:updateTransportShipState({ isRetreating = true })
	self._active = false
end
function BoatRetreat:owner()
	return self.player
end
function BoatRetreat:isActive(): boolean
	return self._active
end
function BoatRetreat:activeDuringSpawnPhase(): boolean
	return false
end
SmallExecutions.BoatRetreatExecution = BoatRetreat

-- NoOpExecution
local NoOp = {}
NoOp.__index = NoOp
function NoOp.new()
	return setmetatable({}, NoOp)
end
function NoOp:init() end
function NoOp:tick() end
function NoOp:isActive(): boolean
	return false
end
function NoOp:activeDuringSpawnPhase(): boolean
	return false
end
SmallExecutions.NoOpExecution = NoOp

-- WinCheckExecution
-- Hard time limit (seconds) forcing a winner: 170 minutes.
local HARD_TIME_LIMIT_SECONDS = 170 * 60
local WinCheck = {}
WinCheck.__index = WinCheck
function WinCheck.new()
	return setmetatable({ _active = true }, WinCheck)
end
function WinCheck:init(mg)
	self.mg = mg
end
function WinCheck:tick(ticks: number)
	if ticks % 10 ~= 0 then
		return
	end
	-- TODO(port): ranked 1v1 / 2v2 rules (Roblox matchmaking decides these).
	if self.mg:config():gameConfig().gameMode == GameMode.FFA then
		self:checkWinnerFFA()
	else
		self:checkWinnerTeam()
	end
end

function WinCheck:checkWinnerFFA()
	local sorted = self.mg:players()
	Util.sort(sorted, function(a, b)
		return b:numTilesOwned() - a:numTilesOwned()
	end)
	if #sorted == 0 then
		return
	end
	local max = sorted[1]
	local won = if self.mg:config():gameConfig().robloxWinRule then self:_hasWonRoblox(max) else self:_hasWon(max:numTilesOwned())
	if won then
		self.mg:setWinner(max, nil)
		print(`{max:name()} has won the game`)
		self._active = false
	end
end

-- Hold more than the required share of non-fallout land, or outlast the
-- lobby timer / hard limit.
function WinCheck:_hasWon(tilesOwned: number): boolean
	local mg = self.mg
	local timeElapsed = mg:elapsedGameSeconds()
	local maxTimerValue = mg:config():gameConfig().maxTimerValue
	if maxTimerValue ~= nil and timeElapsed >= maxTimerValue * 60 then
		return true
	end
	if timeElapsed >= HARD_TIME_LIMIT_SECONDS then
		return true
	end
	local numTilesWithoutFallout = mg:numLandTiles() - mg:numTilesWithFallout()
	return tilesOwned * 100 > numTilesWithoutFallout * mg:config():percentageTilesOwnedToWin(timeElapsed)
end

-- Roblox servers (gameConfig.robloxWinRule, not upstream): no timers and no
-- "keep playing" — the leader wins only with 95 % of the non-fallout land
-- while no other living player can still afford a MIRV.
local ROBLOX_WIN_PERCENT = 80
function WinCheck:_hasWonRoblox(leader): boolean
	local mg = self.mg
	local numTilesWithoutFallout = mg:numLandTiles() - mg:numTilesWithFallout()
	if leader:numTilesOwned() * 100 < numTilesWithoutFallout * ROBLOX_WIN_PERCENT then
		return false
	end
	return true
end

-- Team version of the Roblox rule: the team holds 95 % of the land and no
-- living player outside it can afford a MIRV.
function WinCheck:_hasWonRobloxTeam(team: string, tilesOwned: number): boolean
	local mg = self.mg
	local numTilesWithoutFallout = mg:numLandTiles() - mg:numTilesWithFallout()
	if tilesOwned * 100 < numTilesWithoutFallout * ROBLOX_WIN_PERCENT then
		return false
	end
	return true
end

function WinCheck:checkWinnerTeam()
	local teamToTiles = {}
	local order = {}
	for _, player in self.mg:players() do
		local team = player:team()
		if team == nil then
			continue
		end
		if teamToTiles[team] == nil then
			table.insert(order, team)
			teamToTiles[team] = 0
		end
		teamToTiles[team] += player:numTilesOwned()
	end
	Util.sort(order, function(a, b)
		return teamToTiles[b] - teamToTiles[a]
	end)
	if #order == 0 then
		return
	end
	local team = order[1]
	local won = if self.mg:config():gameConfig().robloxWinRule then self:_hasWonRobloxTeam(team, teamToTiles[team]) else self:_hasWon(teamToTiles[team])
	if won then
		if team == ColoredTeams.Bot then
			return
		end
		self.mg:setWinner(team, nil)
		print(`{team} has won the game`)
		self._active = false
	end
end

function WinCheck:isActive(): boolean
	return self._active
end
function WinCheck:activeDuringSpawnPhase(): boolean
	return false
end
SmallExecutions.WinCheckExecution = WinCheck

return SmallExecutions
