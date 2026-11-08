-- Port of OpenFrontIO src/core/execution/nation/NationWarshipBehavior.ts:
-- nations spawning warships, retaliating for lost boats and countering
-- warship infestations.

local Shared = game:GetService("ReplicatedStorage").Shared
local Util = require(Shared.Util)
local JSSet = require(Shared.JSSet)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local ConstructionExecution = require(script.Parent.ConstructionExecution)
local NationEmoji = require(script.Parent.NationEmojiBehavior)

local UnitType = GameTypes.UnitType
local PlayerType = GameTypes.PlayerType
local Difficulty = GameTypes.Difficulty
local AllPlayers = GameTypes.AllPlayers

local Behavior = {}
Behavior.__index = Behavior

local M = {}

function M.new(random, game, player, emojiBehavior)
	return setmetatable({
		random = random,
		game = game,
		player = player,
		emojiBehavior = emojiBehavior,
		trackedTransportShips = JSSet.new(),
		trackedTradeShips = JSSet.new(),
		trackedIncomingTransportShips = JSSet.new(),
		dealtWithTransportShip = JSSet.new(),
	}, Behavior)
end

function Behavior:maybeSpawnWarship(): boolean
	if self.player == nil then
		error("not initialized")
	end
	if self.game:config():isUnitDisabled(UnitType.Warship) then
		return false
	end
	if not self.random:chance(50) then
		return false
	end
	local ports = self.player:units(UnitType.Port)
	local ships = self.player:units(UnitType.Warship)
	if #ports > 0 and #ships == 0 and self.player:gold() > self:_cost(UnitType.Warship) then
		local port = self.random:randElement(ports)
		local targetTile = self:_warshipSpawnTile(port:tile(), 250)
		if targetTile == nil then
			return false
		end
		local canBuild = self.player:canBuild(UnitType.Warship, targetTile)
		if canBuild == false then
			return false
		end
		self.game:addExecution(ConstructionExecution.new(self.player, UnitType.Warship, targetTile))
		return true
	end
	return false
end

function Behavior:_warshipSpawnTile(portTile: number, radius: number): number?
	local game = self.game
	for _ = 1, 50 do
		local randX = self.random:nextInt(game:x(portTile) - radius, game:x(portTile) + radius)
		local randY = self.random:nextInt(game:y(portTile) - radius, game:y(portTile) + radius)
		if not game:isValidCoord(randX, randY) then
			continue
		end
		local tile = game:ref(randX, randY)
		if not game:isWater(tile) then
			continue
		end
		return tile
	end
	return nil
end

function Behavior:trackShipsAndRetaliate()
	self:_trackTransportShipsAndRetaliate()
	self:_trackTradeShipsAndRetaliate()
	self:_trackIncomingTransportsAndRetaliate()
end

-- Send out a warship if our transport ship got destroyed by an enemy
function Behavior:_trackTransportShipsAndRetaliate()
	if self.game:config():isUnitDisabled(UnitType.TransportShip) then
		return
	end
	for _, u in self.player:units(UnitType.TransportShip) do
		self.trackedTransportShips:add(u)
	end
	for ship in self.trackedTransportShips do
		if not ship:isActive() then
			if ship:wasDestroyedByEnemy() and ship:destroyer() ~= nil then
				self:_maybeRetaliateWithWarship(ship:tile(), ship:destroyer(), "transport")
			end
			self.trackedTransportShips:delete(ship)
		end
	end
end

-- Send out a warship if our trade ship got captured
function Behavior:_trackTradeShipsAndRetaliate()
	for _, u in self.player:units(UnitType.TradeShip) do
		self.trackedTradeShips:add(u)
	end
	for ship in self.trackedTradeShips do
		if not ship:isActive() then
			self.trackedTradeShips:delete(ship)
			continue
		end
		if ship:owner():id() ~= self.player:id() then
			self:_maybeRetaliateWithWarship(ship:tile(), ship:owner(), "trade")
			self.trackedTradeShips:delete(ship)
		end
	end
end

function Behavior:_trackIncomingTransportsAndRetaliate()
	local game = self.game
	local player = self.player
	for _, p in game:units(UnitType.TransportShip) do
		local target = p:targetTile()
		-- JS `target &&`: tile 0 is falsy upstream too
		if
			target ~= nil
			and target ~= 0
			and p:isActive()
			and not p:transportShipState().isRetreating
			and game:ownerID(target) == player:smallID()
			and p:owner():smallID() ~= player:smallID()
		then
			self.trackedIncomingTransportShips:add(p)
		end
	end

	for transport in self.trackedIncomingTransportShips do
		local target = transport:targetTile()
		if not transport:isActive() or target == nil or transport:transportShipState().isRetreating then
			self.trackedIncomingTransportShips:delete(transport)
			self.dealtWithTransportShip:delete(transport)
			continue
		end
		if self.dealtWithTransportShip:has(transport) then
			continue
		end

		local distanceToTarget = game:manhattanDist(transport:tile(), target)
		-- Too close to deal with
		if distanceToTarget < 20 then
			self.dealtWithTransportShip:add(transport)
			continue
		end

		if not transport:owner():isAlliedWith(player) then
			local covered = game:hasUnitNearby(target, 90, UnitType.Warship, player:id(), true)
			if not covered then
				for _, w in player:units(UnitType.Warship) do
					local patrolTile = w:warshipState().patrolTile
					if patrolTile ~= nil and game:manhattanDist(target, patrolTile) < 90 then
						covered = true
					end
				end
			end
			if covered then
				self.dealtWithTransportShip:add(transport)
				continue
			end
			local oceanTiles = self:_warshipSpawnTile(target, 30)
			if oceanTiles == nil then
				continue
			end
			self:_maybeRetaliateWithWarship(oceanTiles, transport:owner(), "transport")
			self.dealtWithTransportShip:add(transport)
			break
		end
	end
end

function Behavior:_maybeRetaliateWithWarship(tile: number, enemy, reason: string)
	-- Don't retaliate against ourselves (e.g. own nuke destroyed own ship)
	if enemy == self.player then
		return
	end

	-- Don't send too many warships
	if #self.player:units(UnitType.Warship) >= 10 then
		self:_maybeMoveWarship(tile)
		return
	end

	local difficulty = self.game:config():gameConfig().difficulty
	-- Easy never; Medium 15%, Hard 50%, Impossible 80%.
	if
		(difficulty == Difficulty.Medium and self.random:nextInt(0, 100) < 15)
		or (difficulty == Difficulty.Hard and self.random:nextInt(0, 100) < 50)
		or (difficulty == Difficulty.Impossible and self.random:nextInt(0, 100) < 80)
	then
		local canBuild = self.player:canBuild(UnitType.Warship, tile)
		if canBuild == false then
			self:_maybeMoveWarship(tile)
			return
		end
		self.game:addExecution(ConstructionExecution.new(self.player, UnitType.Warship, tile))
		self.emojiBehavior:maybeSendEmoji(enemy, NationEmoji.EMOJI_WARSHIP_RETALIATION)
		self.player:updateRelation(enemy, if reason == "trade" then -7.5 else -15)
	end
end

function Behavior:_maybeMoveWarship(tile: number)
	local game = self.game
	if not game:isWater(tile) then
		return
	end
	local candidates = {}
	for _, p in self.player:units(UnitType.Warship) do
		local patrolTile = p:warshipState().patrolTile
		-- Don't send ships which are already traveling
		if patrolTile ~= nil and game:manhattanDist(p:tile(), patrolTile) < 130 then
			table.insert(candidates, p)
		end
	end
	Util.sort(candidates, function(a, b)
		return game:manhattanDist(a:tile(), tile) - game:manhattanDist(b:tile(), tile)
	end)
	local warship = candidates[1]
	if warship then
		warship:updateWarshipState({ patrolTile = tile })
	end
end

-- If we are one of the 3 richest and an enemy has too many warships (trying to
-- dominate the ocean), send a counter-warship.
function Behavior:counterWarshipInfestation()
	if not self:_shouldCounterWarshipInfestation() then
		return
	end
	local isTeamGame = self.player:team() ~= nil
	if not self:_isRichPlayer(isTeamGame) then
		return
	end
	local target = self:_findWarshipInfestationCounterTarget(isTeamGame)
	if target ~= nil then
		self:_buildCounterWarship(target)
	end
end

function Behavior:_shouldCounterWarshipInfestation(): boolean
	if self.game:config():isUnitDisabled(UnitType.Warship) then
		return false
	end
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty ~= Difficulty.Hard and difficulty ~= Difficulty.Impossible then
		return false
	end
	if self.game:unitCount(UnitType.Warship) <= 10 then
		return false
	end
	if self:_cost(UnitType.Warship) > self.player:gold() then
		return false
	end
	if #self.player:units(UnitType.Port) == 0 then
		return false
	end
	if #self.player:units(UnitType.Warship) >= 10 then
		return false
	end
	return true
end

function Behavior:_isRichPlayer(isTeamGame: boolean): boolean
	local players = {}
	for _, p in self.game:players() do
		if p:type() == PlayerType.Human then
			continue
		end
		if (not isTeamGame) or p:team() == self.player:team() then
			table.insert(players, p)
		end
	end
	Util.sort(players, function(a, b)
		return b:gold() - a:gold()
	end)
	local myId = self.player:id()
	for i = 1, math.min(3, #players) do
		if players[i]:id() == myId then
			return true
		end
	end
	return false
end

function Behavior:_findWarshipInfestationCounterTarget(isTeamGame: boolean)
	if isTeamGame then
		return self:_findTeamGameWarshipTarget()
	end
	return self:_findFreeForAllWarshipTarget()
end

function Behavior:_findTeamGameWarshipTarget()
	-- JS Map keyed by team, insertion-ordered
	local teamKeys = {}
	local enemyTeamWarships = {}

	for _, p in self.game:players() do
		-- Skip friendly players (our team and allies)
		if self.player:isFriendly(p) or p:id() == self.player:id() then
			continue
		end
		local team = p:team()
		if team == nil then
			continue
		end
		local teamKey = tostring(team)
		local warshipCount = #p:units(UnitType.Warship)
		local teamData = enemyTeamWarships[teamKey]
		if teamData == nil then
			teamData = { count = 0, team = teamKey, players = {} }
			enemyTeamWarships[teamKey] = teamData
			table.insert(teamKeys, teamKey)
		end
		teamData.count += warshipCount
		table.insert(teamData.players, p)
	end

	-- Find team with more than 15 warships
	for _, teamKey in teamKeys do
		local teamData = enemyTeamWarships[teamKey]
		if teamData.count > 15 then
			-- Player in that team with most warships
			local playerWithMostWarships = nil
			for _, p in teamData.players do
				local count = #p:units(UnitType.Warship)
				local maxCount = if playerWithMostWarships then #playerWithMostWarships:units(UnitType.Warship) else 0
				if count > maxCount then
					playerWithMostWarships = p
				end
			end
			if playerWithMostWarships then
				local warships = playerWithMostWarships:units(UnitType.Warship)
				if #warships > 3 then
					return { player = playerWithMostWarships, warship = self.random:randElement(warships) }
				end
			end
		end
	end

	return nil
end

function Behavior:_findFreeForAllWarshipTarget()
	for _, enemy in self.game:players() do
		if self.player:isFriendly(enemy) or enemy:id() == self.player:id() then
			continue
		end
		local enemyWarships = enemy:units(UnitType.Warship)
		if #enemyWarships > 10 then
			return { player = enemy, warship = self.random:randElement(enemyWarships) }
		end
	end
	return nil
end

function Behavior:_buildCounterWarship(target)
	local tile = target.warship:tile()
	local canBuild = self.player:canBuild(UnitType.Warship, tile)
	if canBuild == false then
		self:_maybeMoveWarship(tile)
		return
	end
	self.game:addExecution(ConstructionExecution.new(self.player, UnitType.Warship, tile))
	self.emojiBehavior:sendEmoji(AllPlayers, NationEmoji.EMOJI_WARSHIP_RETALIATION)
end

function Behavior:_cost(unitType: string): number
	return self.game:unitInfo(unitType).cost(self.game, self.player)
end

return M
