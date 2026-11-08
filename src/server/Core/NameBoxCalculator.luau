-- Port of OpenFrontIO src/client/hud/NameBoxCalculator.ts (placeName /
-- placeSpawnName) and core/Util.calculateBoundingBox.
--
-- Places each player's name at the centre of the largest rectangle inscribed
-- in their territory, sized to fit it. Upstream runs this in the simulation
-- worker (GameRunner) and ships NameViewData { x, y, size } to the client;
-- here the server does the same.

local NameBoxCalculator = {}

-- Spawn region diameter (euclidean radius 4 spawn, see getSpawnTiles).
local SPAWN_REGION_DIAMETER = 8

-- UTF-16 length, like JS string.length (names can contain non-ASCII).
local function jsLength(s: string): number
	local n = 0
	for _, cp in utf8.codes(s) do
		n += if cp >= 0x10000 then 2 else 1
	end
	return n
end

local function calculateFontSize(rect, name: string): number
	local widthConstrained = (rect.width / jsLength(name)) * 2
	local heightConstrained = rect.height / 3
	return math.min(widthConstrained, heightConstrained)
end

function NameBoxCalculator.calculateBoundingBox(gm, tiles)
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for tile in tiles do
		local x, y = gm:x(tile), gm:y(tile)
		minX = math.min(minX, x)
		minY = math.min(minY, y)
		maxX = math.max(maxX, x)
		maxY = math.max(maxY, y)
	end
	return { min = { x = minX, y = minY }, max = { x = maxX, y = maxY } }
end

function NameBoxCalculator.placeSpawnName(game, player)
	local spawnTile = player:spawnTile()
	if spawnTile == nil then
		return { x = 0, y = 0, size = 0 }
	end
	local fontSize = calculateFontSize({ x = 0, y = 0, width = SPAWN_REGION_DIAMETER, height = SPAWN_REGION_DIAMETER }, player:displayName())
	return {
		x = math.ceil(game:x(spawnTile)),
		y = math.ceil(game:y(spawnTile) - fontSize / 3),
		size = fontSize,
	}
end

local function largestRectangleInHistogram(widths: { number })
	local stack = {}
	local maxArea = 0
	local rect = { x = 0, y = 0, width = 0, height = 0 }
	local n = #widths
	for i = 0, n do
		local h = if i == n then 0 else widths[i + 1]
		while #stack > 0 and h < widths[stack[#stack] + 1] do
			local height = widths[(table.remove(stack) :: number) + 1]
			local width = if #stack == 0 then i else i - stack[#stack] - 1
			if height * width > maxArea then
				maxArea = height * width
				rect = { x = if #stack == 0 then 0 else stack[#stack] + 1, y = 0, width = width, height = height }
			end
		end
		table.insert(stack, i)
	end
	return rect
end

-- grid[col][row] (1-based) of booleans.
local function findLargestInscribedRectangle(grid, cols: number, rows: number)
	local heights = table.create(cols, 0)
	local largest = { x = 0, y = 0, width = 0, height = 0 }
	for row = 1, rows do
		for col = 1, cols do
			if grid[col][row] then
				heights[col] += 1
			else
				heights[col] = 0
			end
		end
		local r = largestRectangleInHistogram(heights)
		if r.width * r.height > largest.width * largest.height then
			-- row is 1-based here; upstream's `row` is 0-based.
			largest = { x = r.x, y = (row - 1) - r.height + 1, width = r.width, height = r.height }
		end
	end
	return largest
end

local function createGrid(game, player, bbox, scale: number)
	local minX, minY = bbox.min.x // scale, bbox.min.y // scale
	local maxX, maxY = bbox.max.x // scale, bbox.max.y // scale
	local cols, rows = maxX - minX + 1, maxY - minY + 1
	local W, H = game:width(), game:height()
	local smallID = player:smallID()
	local grid = table.create(cols)
	for c = 1, cols do
		grid[c] = table.create(rows, false)
	end
	for x = minX, maxX do
		for y = minY, maxY do
			local cx, cy = x * scale, y * scale
			if cx >= 0 and cx < W and cy >= 0 and cy < H then
				local tile = cy * W + cx
				grid[x - minX + 1][y - minY + 1] = game:isShore(tile)
					or (game:isOcean(tile) and game:magnitude(tile) < 10)
					or game:ownerID(tile) == smallID
					or game:hasFallout(tile)
			end
		end
	end
	return grid, cols, rows
end

function NameBoxCalculator.placeName(game, player)
	local bbox = player.largestClusterBoundingBox
		or NameBoxCalculator.calculateBoundingBox(game, player:borderTiles())
	if bbox.min.x == math.huge then
		return { x = 0, y = 0, size = 0 } -- no territory
	end

	local width = bbox.max.x - bbox.min.x
	local height = bbox.max.y - bbox.min.y
	local size = math.min(width, height)
	local scale
	if size < 25 then
		scale = 1
	elseif size < 50 then
		scale = 2
	elseif size < 100 then
		scale = 4
	elseif size < 250 then
		scale = 8
	elseif size < 500 then
		scale = 16
	else
		scale = 32
	end

	local grid, cols, rows = createGrid(game, player, bbox, scale)
	local rect = findLargestInscribedRectangle(grid, cols, rows)
	rect.x *= scale
	rect.y *= scale
	rect.width *= scale
	rect.height *= scale

	local cx = math.floor(rect.x + rect.width / 2 + bbox.min.x)
	local cy = math.floor(rect.y + rect.height / 2 + bbox.min.y)
	local fontSize = calculateFontSize(rect, player:displayName())
	cy -= fontSize / 3
	return { x = math.ceil(cx), y = math.ceil(cy), size = fontSize }
end

return NameBoxCalculator
