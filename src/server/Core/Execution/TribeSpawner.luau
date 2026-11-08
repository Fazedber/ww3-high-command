-- Port of OpenFrontIO src/core/execution/TribeSpawner.ts and
-- src/core/execution/utils/TribeNames.ts.

local Shared = game:GetService("ReplicatedStorage").Shared
local JSSet = require(Shared.JSSet)
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local TribeNameThemes = require(Core.Data.TribeNameThemes)
local SpawnExecution = require(script.Parent.SpawnExecution)

local PlayerType = GameTypes.PlayerType

-- resolveTribeNameData: merge the map's themes, falling back to "default".
-- TODO(port): customTribes (no shipped map defines any today).
local function resolveTribeNameData(themes: { string }?)
	local themeNames = if themes and #themes > 0 then themes else { "default" }
	local prefixes, suffixes = {}, {}
	for _, themeName in themeNames do
		local theme = TribeNameThemes[themeName]
		if theme == nil then
			warn(`[TribeNames] unknown tribe name theme "{themeName}". Skipping.`)
			continue
		end
		table.move(theme.prefixes, 1, #theme.prefixes, #prefixes + 1, prefixes)
		table.move(theme.suffixes, 1, #theme.suffixes, #suffixes + 1, suffixes)
	end
	if #prefixes == 0 or #suffixes == 0 then
		local d = TribeNameThemes.default
		table.move(d.prefixes, 1, #d.prefixes, #prefixes + 1, prefixes)
		table.move(d.suffixes, 1, #d.suffixes, #suffixes + 1, suffixes)
	end
	return { prefixes = prefixes, suffixes = suffixes }
end

local TribeSpawner = {}
TribeSpawner.__index = TribeSpawner

-- mapThemes: the map's tribe name themes (from the packed map manifest).
function TribeSpawner.new(gs, gameID: string, nationCells, mapThemes: { string }?)
	local self = setmetatable({
		gs = gs,
		gameID = gameID,
		-- Different seed than the game runner (simpleHash(gameID)) so tribe IDs
		-- never collide with nation/human IDs.
		random = PseudoRandom.new(Util.simpleHash(gameID) + 2),
		tribeNameData = resolveTribeNameData(mapThemes),
		nationTiles = JSSet.new(),
	}, TribeSpawner)
	for _, c in nationCells or {} do
		if gs:isValidCoord(c.x, c.y) then
			self.nationTiles:add(gs:ref(c.x, c.y))
		end
	end
	return self
end

function TribeSpawner:spawnTribes(numTribes: number, purchasedNames: { string }?)
	local tribes = {}
	purchasedNames = purchasedNames or {}

	-- Purchased names each take one random remaining slot. Guarded so games
	-- without purchased names consume the PRNG exactly like upstream.
	local remaining = numTribes - #tribes
	local purchasedBySlot = {}
	if #purchasedNames > 0 and remaining > 0 then
		local used = table.move(purchasedNames, 1, math.min(#purchasedNames, remaining), 1, {})
		local indices = {}
		for i = 0, remaining - 1 do
			table.insert(indices, i)
		end
		local slots = self.random:shuffleArray(indices)
		for i, name in used do
			purchasedBySlot[slots[i]] = name
		end
	end

	local slot = 0
	while #tribes < numTribes do
		local purchased = purchasedBySlot[slot]
		table.insert(tribes, self:spawnTribe(purchased or self:_randomTribeName()))
		slot += 1
	end
	return tribes
end

function TribeSpawner:spawnTribe(tribeName: string)
	return SpawnExecution.new(self.gameID, GameTypes.PlayerInfo(tribeName, PlayerType.Bot, nil, self.random:nextID()))
end

function TribeSpawner:_randomTribeName(): string
	local data = self.tribeNameData
	local prefixIndex = self.random:nextInt(0, #data.prefixes)
	local suffixIndex = self.random:nextInt(0, #data.suffixes)
	return `{data.prefixes[prefixIndex + 1]} {data.suffixes[suffixIndex + 1]}`
end

return TribeSpawner
