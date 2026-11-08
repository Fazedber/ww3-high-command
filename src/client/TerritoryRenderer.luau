--!native
-- Draws terrain + territory onto EditableImage tiles.
--
-- Look matches OpenFront's default theme (TerritoryPass / BorderStampPass):
--   * territory fill: player colour desaturated toward luma by
--     territorySaturation (0.85), alpha-blended over terrain at
--     territoryAlpha (0.588)
--   * border tiles (any 4-neighbour with a different owner): the player's
--     border colour (colord .darken(0.125)), opaque
--   * railroads (RailroadPass line mode, one tile wide): the tile owner's
--     border colour, white for the local player, grey on unowned land
--   * defense coverage (DefenseCoveragePass): tiles within defensePostRange
--     of a finished same-owner Defense Post get their fill darkened
--     (territoryDefenseDarken 0.85) and a checkerboard on their border
--     (defenseCheckerDarken 0.7 on every other tile)
--
-- Tile state is the simulation's u16 per tile (bits 0-11 owner smallID).
-- Changing a tile dirties it and its 4 neighbours (their border status may
-- flip); flush() recomputes dirty pixels and uploads each image's dirty
-- rectangle only.

local AssetService = game:GetService("AssetService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local TerrainColors = require(Shared:WaitForChild("TerrainColors"))

local MAX_TILE = 1024 -- EditableImage size limit
local TERRITORY_ALPHA = 0.588 -- render-settings.json territoryAlpha
local TERRITORY_SATURATION = 0.85 -- render-settings.json territorySaturation
local OWNER_MASK = 0x0fff
local FALLOUT_BIT = 0x2000 -- GameMap FALLOUT (bit 13)
local DEFENSE_RANGE = 30 -- render-settings mapOverlay.defensePostRange
local DEFENSE_FILL_DARKEN = 0.85 -- territoryDefenseDarken
local DEFENSE_CHECKER_DARKEN = 0.7 -- defenseCheckerDarken

local band = bit32.band
local readu16, writeu16 = buffer.readu16, buffer.writeu16
local readu32, writeu32 = buffer.readu32, buffer.writeu32

local TerritoryRenderer = {}
TerritoryRenderer.__index = TerritoryRenderer

-- Map palette (client-only override; simulation and shared defaults untouched):
-- blue sea vs. mauve land (clearly different hues), peach shoreline.
TerritoryRenderer.PALETTE = {
	oceanColor = { 24, 58, 128 },
	backgroundColor = { 10, 10, 28 },
	sandColor = { 178, 150, 150 },
	plainsColor = { 98, 82, 130 },
	highlandColor = { 120, 100, 142 },
	mountainColor = { 160, 142, 178 },
}

local function pack(r: number, g: number, b: number): number
	return r + g * 0x100 + b * 0x10000 + 0xff000000
end

-- railroad.frag.glsl: vec3(0.75) off-territory, uLocalRailColor (white) for ours.
local RAIL_UNOWNED = pack(191, 191, 191)
local RAIL_LOCAL = pack(255, 255, 255)

-- camera: MapCamera the image tiles are registered with.
function TerritoryRenderer.new(camera, gameMap)
	local W, H = gameMap:width(), gameMap:height()
	local n = W * H

	-- Terrain colour per tile, packed RGBA (little-endian r,g,b,a bytes).
	local terrainRGBA = TerrainColors.buildRGBA(gameMap:terrainBuffer(), W, 0, 0, W, H, TerrainColors.buildLUT(TerritoryRenderer.PALETTE))

	local self = setmetatable({
		W = W,
		H = H,
		terrain = terrainRGBA,
		state = buffer.create(n * 2),
		rail = buffer.create(n), -- railroads covering each tile
		localSmallID = 0,
		fill = {}, -- smallID -> { r, g, b } (saturated, pre-multiplied by alpha)
		border = {}, -- smallID -> packed RGBA
		chunks = {},
		dirty = {}, -- tile -> true
		dirtyList = {},
		fullRedraw = true,
		posts = {}, -- unit id -> { x, y, owner } (finished Defense Posts)
		postsByOwner = {}, -- smallID -> { [id] = post }
	}, TerritoryRenderer)
	if game:GetService("RunService"):IsStudio() then
		_G.OpenFrontTerritory = self -- debugging handle (Studio only)
	end

	local cols = math.ceil(W / MAX_TILE)
	local rows = math.ceil(H / MAX_TILE)
	local tileW = math.ceil(W / cols)
	local tileH = math.ceil(H / rows)
	self.cols, self.tileW, self.tileH = cols, tileW, tileH

	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			local x0, y0 = c * tileW, r * tileH
			local w = math.min(tileW, W - x0)
			local h = math.min(tileH, H - y0)
			local image = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
			if not image then
				error(`CreateEditableImage failed for {w}x{h} tile (client memory budget?)`)
			end
			local label = Instance.new("ImageLabel")
			label.Name = `Tile_{c}_{r}`
			label.BackgroundTransparency = 1
			label.BorderSizePixel = 0
			label.ResampleMode = Enum.ResamplerMode.Pixelated
			label.ImageContent = Content.fromObject(image)
			camera:addTile(label, x0, y0, w, h)
			table.insert(self.chunks, {
				image = image,
				x0 = x0,
				y0 = y0,
				w = w,
				h = h,
				pixels = buffer.create(w * h * 4),
				-- dirty rect in chunk-local coords (inclusive), empty when minX > maxX
				minX = math.huge,
				minY = math.huge,
				maxX = -1,
				maxY = -1,
			})
		end
	end
	return self
end

-- Player colours: rgb / border as { r, g, b } in 0-255.
function TerritoryRenderer:setPlayerColor(smallID: number, rgb: { number }, border: { number })
	local r, g, b = rgb[1] / 255, rgb[2] / 255, rgb[3] / 255
	-- Desaturate toward luma, as the territory shader does.
	local luma = r * 0.299 + g * 0.587 + b * 0.114
	r = luma + (r - luma) * TERRITORY_SATURATION
	g = luma + (g - luma) * TERRITORY_SATURATION
	b = luma + (b - luma) * TERRITORY_SATURATION
	self.fill[smallID] = { r * 255 * TERRITORY_ALPHA, g * 255 * TERRITORY_ALPHA, b * 255 * TERRITORY_ALPHA }
	self.border[smallID] = pack(border[1], border[2], border[3])
	-- Pattern secondary fill: the border colour, desaturated and blended like
	-- the territory fill (PlayerView.territoryColor(tile) for !isPrimary).
	local br, bg, bb = border[1] / 255, border[2] / 255, border[3] / 255
	local bl = br * 0.299 + bg * 0.587 + bb * 0.114
	br = bl + (br - bl) * TERRITORY_SATURATION
	bg = bl + (bg - bl) * TERRITORY_SATURATION
	bb = bl + (bb - bl) * TERRITORY_SATURATION
	self.fill2 = self.fill2 or {}
	self.fill2[smallID] = { br * 255 * TERRITORY_ALPHA, bg * 255 * TERRITORY_ALPHA, bb * 255 * TERRITORY_ALPHA }
	self.fullRedraw = true
end

-- Territory pattern (cosmetic, PatternDecoder): rows of "#" = secondary
-- cells, each covering 2^scale tiles; nil clears it.
function TerritoryRenderer:setPattern(smallID: number, rows: { string }?, scale: number?)
	self.patterns = self.patterns or {}
	if rows == nil then
		if self.patterns[smallID] then
			self.patterns[smallID] = nil
			self.fullRedraw = true
		end
		return
	end
	local h, w = #rows, #rows[1]
	local bits = table.create(w * h, false)
	for y, row in rows do
		for x = 1, w do
			bits[(y - 1) * w + x] = string.sub(row, x, x) == "#"
		end
	end
	self.patterns[smallID] = { w = w, h = h, scale = scale or 0, bits = bits }
	self.fullRedraw = true
end

function TerritoryRenderer:ownerAt(tile: number): number
	return band(readu16(self.state, tile * 2), OWNER_MASK)
end

function TerritoryRenderer:_markDirty(tile: number)
	if not self.dirty[tile] then
		self.dirty[tile] = true
		table.insert(self.dirtyList, tile)
	end
end

-- Apply one tile's new simulation state.
function TerritoryRenderer:setState(tile: number, s: number)
	if readu16(self.state, tile * 2) == s then
		return
	end
	writeu16(self.state, tile * 2, s)
	if self.fullRedraw then
		return
	end
	local W = self.W
	local x = tile % W
	self:_markDirty(tile)
	if tile >= W then
		self:_markDirty(tile - W)
	end
	if tile < (self.H - 1) * W then
		self:_markDirty(tile + W)
	end
	if x ~= 0 then
		self:_markDirty(tile - 1)
	end
	if x ~= W - 1 then
		self:_markDirty(tile + 1)
	end
end

-- Defense Post `id` at `tile` for `owner`; nil tile removes it. Tiles in
-- range of the old and new position are repainted.
function TerritoryRenderer:setDefensePost(id: number, tile: number?, owner: number?)
	local old = self.posts[id]
	local W = self.W
	if old and tile and old.x == tile % W and old.y == tile // W and old.owner == owner then
		return
	end
	if old then
		self.posts[id] = nil
		local list = self.postsByOwner[old.owner]
		if list then
			list[id] = nil
		end
		self:_dirtyCircle(old.x, old.y)
	end
	if tile and owner and owner ~= 0 then
		local post = { x = tile % W, y = tile // W, owner = owner }
		self.posts[id] = post
		self.postsByOwner[owner] = self.postsByOwner[owner] or {}
		self.postsByOwner[owner][id] = post
		self:_dirtyCircle(post.x, post.y)
	end
end

function TerritoryRenderer:_dirtyCircle(cx: number, cy: number)
	if self.fullRedraw then
		return
	end
	local W, H, r = self.W, self.H, DEFENSE_RANGE
	for y = math.max(0, cy - r), math.min(H - 1, cy + r) do
		local dy = y - cy
		local span = math.floor(math.sqrt(r * r - dy * dy))
		for x = math.max(0, cx - span), math.min(W - 1, cx + span) do
			self:_markDirty(y * W + x)
		end
	end
end

-- Is `tile` (owned by `owner`) within range of one of that owner's posts?
function TerritoryRenderer:_defended(tile: number, owner: number): boolean
	local list = self.postsByOwner[owner]
	if list == nil or next(list) == nil then
		return false
	end
	local W = self.W
	local x, y = tile % W, tile // W
	local r2 = DEFENSE_RANGE * DEFENSE_RANGE
	for _, p in list do
		local dx, dy = x - p.x, y - p.y
		if dx * dx + dy * dy <= r2 then
			return true
		end
	end
	return false
end

-- Add (delta 1) or remove (delta -1) one railroad's tiles.
function TerritoryRenderer:addRail(tiles: { number }, delta: number)
	local rail = self.rail
	for _, t in tiles do
		local v = math.clamp(buffer.readu8(rail, t) + delta, 0, 255)
		buffer.writeu8(rail, t, v)
		if not self.fullRedraw then
			self:_markDirty(t)
		end
	end
end

function TerritoryRenderer:setLocalPlayer(smallID: number)
	if self.localSmallID ~= smallID then
		self.localSmallID = smallID
		self.fullRedraw = true
	end
end

-- Replace the whole state (snapshot on join).
function TerritoryRenderer:loadState(stateBuf: buffer)
	buffer.copy(self.state, 0, stateBuf, 0, math.min(buffer.len(stateBuf), buffer.len(self.state)))
	self.fullRedraw = true
end

-- Build-mode ghost railroads (RailroadPass ghost texture): planned paths drawn
-- semi-transparent white, existing rails the station would snap to in gold.
local GHOST_PATH, GHOST_OVERLAP = { 255, 255, 255, 0.6 }, { 255, 214, 90, 0.85 }
function TerritoryRenderer:setGhostRails(paths: { { number } }?, overlapping: { number }?)
	local old = self.ghostRail
	local new = {}
	for _, path in paths or {} do
		for _, t in path do
			new[t] = GHOST_PATH
		end
	end
	for _, t in overlapping or {} do
		new[t] = GHOST_OVERLAP
	end
	self.ghostRail = if next(new) then new else nil
	if not self.fullRedraw then
		for t in old or {} do
			if new[t] == nil then
				self:_markDirty(t)
			end
		end
		for t, v in new do
			if old == nil or old[t] ~= v then
				self:_markDirty(t)
			end
		end
	end
end

-- Packed RGBA for one tile.
function TerritoryRenderer:_pixel(tile: number): number
	local ghost = self.ghostRail and self.ghostRail[tile]
	if ghost then
		local c, a = self:_basePixel(tile), ghost[4]
		return pack(
			math.floor(band(c, 0xff) * (1 - a) + ghost[1] * a + 0.5),
			math.floor(band(c // 0x100, 0xff) * (1 - a) + ghost[2] * a + 0.5),
			math.floor(band(c // 0x10000, 0xff) * (1 - a) + ghost[3] * a + 0.5)
		)
	end
	return self:_basePixel(tile)
end

function TerritoryRenderer:_basePixel(tile: number): number
	local state = self.state
	local raw = readu16(state, tile * 2)
	if band(raw, FALLOUT_BIT) ~= 0 then
		-- Stale-nuke ground (territory.frag.glsl): opaque green with a per-tile
		-- hash noise (staleNukeR/G/B 0.05/0.55/0.07, variation 0.05).
		local W = self.W
		local x, y = tile % W, tile // W
		local h = math.sin(x * 12.9898 + y * 78.233) * 43758.5453
		local n = (h - math.floor(h)) * 0.05
		return pack(math.floor((0.05 + n) * 255 + 0.5), math.floor((0.55 + n) * 255 + 0.5), math.floor((0.07 + n) * 255 + 0.5))
	end
	local owner = band(raw, OWNER_MASK)
	if buffer.readu8(self.rail, tile) > 0 then
		if owner == 0 then
			return RAIL_UNOWNED
		elseif owner == self.localSmallID then
			return RAIL_LOCAL
		end
		return self.border[owner] or RAIL_UNOWNED
	end
	if owner == 0 then
		return readu32(self.terrain, tile * 4)
	end
	local W = self.W
	local x = tile % W
	local isBorder = (tile >= W and band(readu16(state, (tile - W) * 2), OWNER_MASK) ~= owner)
		or (tile < (self.H - 1) * W and band(readu16(state, (tile + W) * 2), OWNER_MASK) ~= owner)
		or (x ~= 0 and band(readu16(state, (tile - 1) * 2), OWNER_MASK) ~= owner)
		or (x ~= W - 1 and band(readu16(state, (tile + 1) * 2), OWNER_MASK) ~= owner)
	if isBorder then
		-- The local player's border is always bright white, so own land is unmistakable
		-- even when many nations share a similar colour.
		if owner == self.localSmallID then
			return pack(255, 255, 255)
		end
		local bc = self.border[owner] or 0xff000000
		-- Defended border: checkerboard, every other tile darkened.
		if (x + tile // W) % 2 == 1 and self:_defended(tile, owner) then
			local k = DEFENSE_CHECKER_DARKEN
			return pack(math.floor(band(bc, 0xff) * k), math.floor(band(bit32.rshift(bc, 8), 0xff) * k), math.floor(band(bit32.rshift(bc, 16), 0xff) * k))
		end
		return bc
	end
	local f = self.fill[owner]
	local pat = self.patterns and self.patterns[owner]
	if pat then
		local px = (x // (2 ^ pat.scale)) % pat.w
		local py = ((tile // W) // (2 ^ pat.scale)) % pat.h
		if pat.bits[py * pat.w + px + 1] then
			f = self.fill2[owner] or f
		end
	end
	local t = readu32(self.terrain, tile * 4)
	if not f then
		return t
	end
	local k = 1 - TERRITORY_ALPHA
	local d = if self:_defended(tile, owner) then DEFENSE_FILL_DARKEN else 1
	local r = math.floor(band(t, 0xff) * k + f[1] * d + 0.5)
	local g = math.floor(band(bit32.rshift(t, 8), 0xff) * k + f[2] * d + 0.5)
	local b = math.floor(band(bit32.rshift(t, 16), 0xff) * k + f[3] * d + 0.5)
	if owner == self.localSmallID then
		-- Own land is lightened so it reads brighter than every neighbour.
		r = math.floor(r + (255 - r) * 0.2 + 0.5)
		g = math.floor(g + (255 - g) * 0.2 + 0.5)
		b = math.floor(b + (255 - b) * 0.2 + 0.5)
	end
	return pack(r, g, b)
end

function TerritoryRenderer:_chunkFor(x: number, y: number)
	local c = x // self.tileW
	local r = y // self.tileH
	return self.chunks[r * self.cols + c + 1]
end

-- Recompute dirty pixels and upload changed rectangles.
function TerritoryRenderer:flush()
	if self.fullRedraw then
		self.fullRedraw = false
		table.clear(self.dirty)
		table.clear(self.dirtyList)
		for _, ch in self.chunks do
			local px = ch.pixels
			local o = 0
			for y = ch.y0, ch.y0 + ch.h - 1 do
				local row = y * self.W
				for x = ch.x0, ch.x0 + ch.w - 1 do
					writeu32(px, o, self:_pixel(row + x))
					o += 4
				end
			end
			ch.image:WritePixelsBuffer(Vector2.zero, Vector2.new(ch.w, ch.h), px)
			ch.minX, ch.minY, ch.maxX, ch.maxY = math.huge, math.huge, -1, -1
		end
		return
	end

	local list = self.dirtyList
	if #list == 0 then
		return
	end
	local W = self.W
	for _, tile in list do
		local x, y = tile % W, tile // W
		local ch = self:_chunkFor(x, y)
		local lx, ly = x - ch.x0, y - ch.y0
		writeu32(ch.pixels, (ly * ch.w + lx) * 4, self:_pixel(tile))
		if lx < ch.minX then
			ch.minX = lx
		end
		if lx > ch.maxX then
			ch.maxX = lx
		end
		if ly < ch.minY then
			ch.minY = ly
		end
		if ly > ch.maxY then
			ch.maxY = ly
		end
	end
	table.clear(self.dirty)
	table.clear(list)

	for _, ch in self.chunks do
		if ch.maxX < ch.minX then
			continue
		end
		local rw = ch.maxX - ch.minX + 1
		local rh = ch.maxY - ch.minY + 1
		if rw * rh * 2 >= ch.w * ch.h then
			-- Most of the image changed: upload it whole.
			ch.image:WritePixelsBuffer(Vector2.zero, Vector2.new(ch.w, ch.h), ch.pixels)
		else
			local region = buffer.create(rw * rh * 4)
			for row = 0, rh - 1 do
				buffer.copy(region, row * rw * 4, ch.pixels, ((ch.minY + row) * ch.w + ch.minX) * 4, rw * 4)
			end
			ch.image:WritePixelsBuffer(Vector2.new(ch.minX, ch.minY), Vector2.new(rw, rh), region)
		end
		ch.minX, ch.minY, ch.maxX, ch.maxY = math.huge, math.huge, -1, -1
	end
end

return TerritoryRenderer
