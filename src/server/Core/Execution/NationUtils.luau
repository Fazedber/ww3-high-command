-- Port of OpenFrontIO src/core/execution/nation/NationUtils.ts.

local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local NameBoxCalculator = require(Core.NameBoxCalculator)

local UnitType = GameTypes.UnitType
local Structures = GameTypes.Structures

local NationUtils = {}

local function randTerritoryTile(random, mg, p, boundingBox)
	-- Prefer sampling inside the bounding box first (fast, usually good enough)
	boundingBox = boundingBox or NameBoxCalculator.calculateBoundingBox(mg, p:borderTiles())
	for _ = 1, 100 do
		local randX = random:nextInt(boundingBox.min.x, boundingBox.max.x)
		local randY = random:nextInt(boundingBox.min.y, boundingBox.max.y)
		if not mg:isOnMap({ x = randX, y = randY }) then
			-- Sanity check should never happen
			continue
		end
		local randTile = mg:ref(randX, randY)
		if mg:owner(randTile) == p then
			return randTile
		end
	end

	if p:numTilesOwned() > 0 and p:numTilesOwned() <= 100 then
		return random:randFromSet(p:tiles())
	end

	return nil
end

function NationUtils.randTerritoryTileArray(random, mg, player, numTiles: number): { number }
	local boundingBox = NameBoxCalculator.calculateBoundingBox(mg, player:borderTiles())
	local tiles = {}
	for _ = 1, numTiles do
		local tile = randTerritoryTile(random, mg, player, boundingBox)
		if tile ~= nil then
			table.insert(tiles, tile)
		end
	end
	return tiles
end

NationUtils.randTerritoryTile = randTerritoryTile

-- Ranks candidates by structures, troop-cap headroom, and tiles (normalized), returning the juiciest
function NationUtils.findJuiciestTarget(game, candidates)
	if #candidates == 0 then
		return nil
	end

	local stats = {}
	for _, p in candidates do
		-- Defense posts and missile silos are defensive, not a prize worth
		-- capturing - only count the rest of the structures.
		local structureCount = 0
		for _, u in p:units() do
			local t = u:type()
			if Structures.has(t) and t ~= UnitType.DefensePost and t ~= UnitType.MissileSilo then
				structureCount += u:level()
			end
		end
		local maxTroops = game:config():maxTroops(p)
		local troopGapRatio = if maxTroops > 0 then 1 - p:troops() / maxTroops else 0
		table.insert(stats, { player = p, structureCount = structureCount, troopGapRatio = troopGapRatio, tiles = p:numTilesOwned() })
	end

	local function range(key: string)
		local min, max = math.huge, -math.huge
		for _, s in stats do
			min = math.min(min, s[key])
			max = math.max(max, s[key])
		end
		return min, max
	end
	local function normalize(value: number, min: number, max: number): number
		return if max > min then (value - min) / (max - min) else 0
	end
	local sMin, sMax = range("structureCount")
	local gMin, gMax = range("troopGapRatio")
	local tMin, tMax = range("tiles")

	local best, bestScore = nil, -math.huge
	for _, s in stats do
		local juiciness = normalize(s.structureCount, sMin, sMax) + normalize(s.troopGapRatio, gMin, gMax) + normalize(s.tiles, tMin, tMax)
		if juiciness > bestScore then
			bestScore = juiciness
			best = s.player
		end
	end
	return best
end

return NationUtils
