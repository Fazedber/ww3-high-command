-- Port of OpenFrontIO src/core/execution/SpawnExecution.ts.

local Shared = game:GetService("ReplicatedStorage").Shared
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local ExecUtil = require(script.Parent.ExecUtil)

local PlayerType = GameTypes.PlayerType
local GameType = GameTypes.GameType

local MAX_SPAWN_TRIES = 1000
local RELAX_MIN_DIST_AT = 750

local SpawnExecution = {}
SpawnExecution.__index = SpawnExecution

-- fromIntent: true only for spawns built from a client's spawn intent;
-- internal callers (tribes, nations, random spawn) are trusted.
function SpawnExecution.new(gameID: string, playerInfo, tile: number?, fromIntent: boolean?)
	return setmetatable({
		_random = PseudoRandom.new(Util.simpleHash(playerInfo.id) + Util.simpleHash(gameID)),
		active = true,
		_playerInfo = playerInfo,
		tile = tile,
		_fromIntent = fromIntent == true,
		_queuedDuringSpawnPhase = false,
	}, SpawnExecution)
end

function SpawnExecution:init(mg, _ticks: number)
	self.mg = mg
	self._queuedDuringSpawnPhase = mg:inSpawnPhase()
end

function SpawnExecution:tick(_ticks: number)
	-- Lazily required: PlayerExecution / TribeExecution are siblings.
	local PlayerExecution = require(script.Parent.PlayerExecution)
	local TribeExecution = require(script.Parent.TribeExecution)

	self.active = false
	local mg = self.mg

	-- Reject malformed tiles before relinquishing any territory.
	if self.tile ~= nil and not mg:isValidRef(self.tile) then
		warn(`SpawnExecution: invalid spawn tile {self.tile}`)
		return
	end

	local player
	if mg:hasPlayer(self._playerInfo.id) then
		player = mg:player(self._playerInfo.id)
	else
		player = mg:addPlayer(self._playerInfo)
	end

	-- A client's spawn intent is only honoured if it was issued during the
	-- spawn phase.
	if self._fromIntent and not self._queuedDuringSpawnPhase then
		return
	end

	-- With random spawn, players cannot re-roll their spawn location.
	if mg:config():isRandomSpawn() and player:hasSpawned() then
		return
	end

	local prevTiles = player:tiles():toArray()
	for _, t in prevTiles do
		player:relinquish(t)
	end
	local center, tiles = self:_getSpawn(if mg:config():isRandomSpawn() then nil else self.tile)

	if center == nil then
		warn(`SpawnExecution: cannot spawn {self._playerInfo.name}`)
		for _, t in prevTiles do
			player:conquer(t)
		end
		return
	end

	for _, t in tiles do
		player:conquer(t)
	end

	if not player:hasSpawned() then
		mg:addExecution(PlayerExecution.new(player))
		if player:type() == PlayerType.Bot then
			mg:addExecution(TribeExecution.new(player))
		end
	end

	player:setSpawnTile(center)

	if mg:config():gameConfig().gameType == GameType.Singleplayer and self._playerInfo.playerType == PlayerType.Human then
		-- In singleplayer, spawn ends when the player selects a location.
		mg:endSpawnPhase()
	end
end

function SpawnExecution:isActive(): boolean
	return self.active
end

function SpawnExecution:activeDuringSpawnPhase(): boolean
	return true
end

-- Returns center, tiles (or nil when no spawn could be found).
function SpawnExecution:_getSpawn(center: number?): (number?, { number }?)
	local mg = self.mg
	if center ~= nil then
		local tiles = ExecUtil.getSpawnTiles(mg, center, false) :: { number }
		if #tiles == 0 then
			return nil, nil
		end
		return center, tiles
	end

	local spawnArea = self:_getTeamSpawnArea()
	local tries = 0
	while tries < MAX_SPAWN_TRIES do
		tries += 1
		local c = self:_randTile(spawnArea)
		if not mg:isLand(c) or mg:hasOwner(c) or mg:isBorder(c) then
			continue
		end

		if tries <= RELAX_MIN_DIST_AT then
			local tooClose = false
			local minDist = mg:config():minDistanceBetweenPlayers()
			for _, p in mg:allPlayers() do
				if p:id() ~= self._playerInfo.id then
					local spawnTile = p:spawnTile()
					if spawnTile ~= nil and mg:manhattanDist(spawnTile, c) < minDist then
						tooClose = true
						break
					end
				end
			end
			if tooClose then
				continue
			end
		end

		local tiles = ExecUtil.getSpawnTiles(mg, c, true)
		if not tiles then
			-- Some spawn tile is off land; find another spawn tile.
			continue
		end
		return c, tiles
	end
	return nil, nil
end

function SpawnExecution:_randTile(area): number
	local mg = self.mg
	if area then
		local x = self._random:nextInt(area.x, area.x + area.width)
		local y = self._random:nextInt(area.y, area.y + area.height)
		return mg:ref(x, y)
	end
	local x = self._random:nextInt(0, mg:width())
	local y = self._random:nextInt(0, mg:height())
	return mg:ref(x, y)
end

function SpawnExecution:_getTeamSpawnArea()
	local team = self.mg:player(self._playerInfo.id):team()
	if team == nil then
		return nil
	end
	return self.mg:teamSpawnArea(team)
end

return SpawnExecution
