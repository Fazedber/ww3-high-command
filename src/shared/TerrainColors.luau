--!native
-- Port of OpenFrontIO src/client/render/gl/utils/ColorUtils.ts
-- (encodeTerrainTile / buildTerrainRGBA), default theme.
--
-- Terrain byte layout per tile:
--   bit 7: isLand
--   bit 6: isShoreline
--   bit 5: isOcean  (water only)
--   bits 0-4: magnitude (0-31)
--
-- Since a tile's colour depends only on its terrain byte, we precompute a
-- 256-entry lookup table of packed RGBA and build textures from that.

local TerrainColors = {}

-- Defaults from upstream src/client/render/gl/render-settings.json.
TerrainColors.DEEP_WATER_BASE = { 0x47, 0x85, 0xb5 } -- terrain.oceanColor #4785b5
TerrainColors.BACKGROUND_BASE = { 0x3c, 0x3c, 0x3c } -- terrain.backgroundColor #3c3c3c

export type RGB = { number }
export type Overrides = {
	backgroundColor: RGB?,
	oceanColor: RGB?,
	sandColor: RGB?,
	plainsColor: RGB?,
	highlandColor: RGB?,
	mountainColor: RGB?,
}

-- JS Math.round semantics (round half up) for non-negative inputs.
local function jsRound(v: number): number
	return math.floor(v + 0.5)
end

-- Returns r, g, b for one terrain byte. Mirrors encodeTerrainTile exactly.
function TerrainColors.encodeTile(tb: number, colors: Overrides?): (number, number, number)
	local c = colors or {}
	local ocean = c.oceanColor or TerrainColors.DEEP_WATER_BASE
	local sand = c.sandColor or { 204, 203, 158 }
	local plains = c.plainsColor or { 190, 220, 138 }
	local highland = c.highlandColor or { 200, 183, 138 }
	local mountain = c.mountainColor or { 230, 230, 230 }
	local peak = c.backgroundColor or TerrainColors.BACKGROUND_BASE

	local isLand = bit32.btest(tb, 0x80)
	local isShoreline = bit32.btest(tb, 0x40)
	local magnitude = bit32.band(tb, 0x1f)

	if isLand and magnitude == 31 then
		-- Impassable terrain renders as the map background colour.
		return peak[1], peak[2], peak[3]
	elseif isLand and isShoreline then
		return sand[1], sand[2], sand[3]
	elseif isLand then
		if magnitude < 10 then
			-- Plains
			return plains[1], plains[2] - 2 * magnitude, plains[3]
		elseif magnitude < 20 then
			-- Highland
			local m = magnitude - 10
			return math.min(255, highland[1] + 2 * m), math.min(255, highland[2] + 2 * m), math.min(255, highland[3] + 2 * m)
		else
			-- Mountain
			local m = magnitude // 2
			return math.min(255, mountain[1] + m), math.min(255, mountain[2] + m), math.min(255, mountain[3] + m)
		end
	elseif isShoreline then
		-- Shoreline water: 70% ocean colour + 30% white.
		return jsRound(0.7 * ocean[1] + 76.5), jsRound(0.7 * ocean[2] + 76.5), jsRound(0.7 * ocean[3] + 76.5)
	else
		-- Deep water darkens with depth (magnitude), capped at 10.
		local m = math.min(magnitude, 10)
		return math.max(0, ocean[1] - m), math.max(0, ocean[2] - m), math.max(0, ocean[3] - m)
	end
end

-- 256-entry table: terrain byte -> packed little-endian RGBA u32
-- (bytes in memory: r, g, b, 255), ready for buffer.writeu32.
function TerrainColors.buildLUT(colors: Overrides?): { number }
	local lut = table.create(256)
	for tb = 0, 255 do
		local r, g, b = TerrainColors.encodeTile(tb, colors)
		lut[tb + 1] = r + g * 0x100 + b * 0x10000 + 0xff000000
	end
	return lut
end

-- RGBA8 pixel buffer for a w x h region of the terrain, starting at (x0, y0)
-- of a map `mapWidth` wide. Use x0 = y0 = 0 and the full size for the whole map.
function TerrainColors.buildRGBA(
	terrain: buffer,
	mapWidth: number,
	x0: number,
	y0: number,
	w: number,
	h: number,
	lut: { number }
): buffer
	local out = buffer.create(w * h * 4)
	local readu8, writeu32 = buffer.readu8, buffer.writeu32
	local o = 0
	for y = y0, y0 + h - 1 do
		local row = y * mapWidth
		for x = x0, x0 + w - 1 do
			writeu32(out, o, lut[readu8(terrain, row + x) + 1])
			o += 4
		end
	end
	return out
end

return TerrainColors
