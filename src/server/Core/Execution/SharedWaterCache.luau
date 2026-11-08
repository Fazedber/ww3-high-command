-- Port of OpenFrontIO src/core/execution/nation/SharedWaterCache.ts.
--
-- Cache for "which water components does each nation share with a valid
-- trade partner". Used by nation AI to decide whether to spend cycles trying
-- to place a port on a given coastline. Rebuilt at most once every TTL_TICKS.

local Shared = game:GetService("ReplicatedStorage").Shared
local JSSet = require(Shared.JSSet)
local GameTypes = require(script.Parent.Parent.GameTypes)

local PlayerType = GameTypes.PlayerType

local TTL_TICKS = 30

-- Sentinel added to a player's shared-water set to signal "touches ocean".
local OCEAN_SENTINEL = -1

local SharedWaterCache = {}
SharedWaterCache.__index = SharedWaterCache
SharedWaterCache.OCEAN_SENTINEL = OCEAN_SENTINEL

function SharedWaterCache.new(game)
	return setmetatable({
		game = game,
		tick = -math.huge,
		byPlayer = nil,
		-- Pass-1 result per player, reused while that player's border and the
		-- map's water are unchanged.
		playerWater = setmetatable({}, { __mode = "k" }),
	}, SharedWaterCache)
end

function SharedWaterCache:get(player)
	local tick = self.game:ticks()
	if self.byPlayer == nil or tick - self.tick >= TTL_TICKS then
		self.byPlayer = self:_build()
		self.tick = tick
	end
	return self.byPlayer[player]
end

function SharedWaterCache:_waterFor(player, waterVersion: number)
	local game = self.game
	local tileVersion = player:tileChangeVersion()
	local cached = self.playerWater[player]
	if cached ~= nil and cached.tileVersion == tileVersion and cached.waterVersion == waterVersion then
		return cached
	end
	local hasOcean = false
	local lakes = JSSet.new()
	local function visit(neighbor: number)
		if not game:isWater(neighbor) then
			return
		end
		if game:isOcean(neighbor) then
			hasOcean = true
			return
		end
		local comp = game:getWaterComponent(neighbor)
		if comp ~= nil then
			lakes:add(comp)
		end
	end
	for tile in player:borderTiles() do
		if game:isShore(tile) then
			game:forEachNeighbor(tile, visit)
		end
	end
	local entry = { tileVersion = tileVersion, waterVersion = waterVersion, hasOcean = hasOcean, lakes = lakes }
	self.playerWater[player] = entry
	return entry
end

function SharedWaterCache:_build()
	local game = self.game

	-- Pass 1: which water bodies each non-bot player touches, and which lakes
	-- have them as a candidate trade partner.
	local order = {}
	local lakePartners = {}
	local waterVersion = game:map():waterVersion()
	for _, player in game:players() do
		if player:type() == PlayerType.Bot then
			continue
		end
		local water = self:_waterFor(player, waterVersion)
		table.insert(order, { player, water })
		for c in water.lakes do
			local arr = lakePartners[c]
			if arr == nil then
				arr = {}
				lakePartners[c] = arr
			end
			table.insert(arr, player)
		end
	end

	-- Pass 2: ocean always counts as shared; a lake only if some other player
	-- on it can trade with P.
	local result = {}
	for _, entry in order do
		local player, water = entry[1], entry[2]
		local shared = JSSet.new()
		if water.hasOcean then
			shared:add(OCEAN_SENTINEL)
		end
		for c in water.lakes do
			local partners = lakePartners[c]
			if partners == nil then
				continue
			end
			for _, other in partners do
				if other ~= player and player:canTrade(other) then
					shared:add(c)
					break
				end
			end
		end
		result[player] = if shared:size() > 0 then shared else nil
	end
	return result
end

return SharedWaterCache
