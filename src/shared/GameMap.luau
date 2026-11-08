--!native
-- Port of OpenFrontIO src/core/game/GameMap.ts (GameMapImpl + distance helpers).
--
-- Porting notes:
--  * TileRef stays 0-based, exactly as upstream: it indexes the terrain and
--    state buffers, so all neighbor arithmetic (ref - w, ref + 1, ...) is 1:1.
--  * Uint8Array terrain -> buffer (u8); Uint16Array state -> buffer (u16).
--  * JS Set results (circleSearch, bfs) -> JSSet, preserving insertion order.
--  * neighbors4 / neighbors8 write into a 1-based `out` table (Luau arrays);
--    the returned count and neighbor ORDER match upstream.

local JSSet = require(script.Parent.JSSet)

local band, bor, btest = bit32.band, bit32.bor, bit32.btest
local readu8, writeu8 = buffer.readu8, buffer.writeu8
local readu16, writeu16 = buffer.readu16, buffer.writeu16

-- Terrain bits (u8)
local IS_LAND = 0x80 -- bit 7
local SHORELINE = 0x40 -- bit 6
local OCEAN = 0x20 -- bit 5
local MAGNITUDE_MASK = 0x1f
-- Land tiles with magnitude == IMPASSABLE_MAGNITUDE are impassable terrain:
-- solid ground that cannot be owned, attacked, or nuked, and that nuke
-- trajectories cannot cross. Rendered as the map background colour.
local IMPASSABLE_MAGNITUDE = 31

-- State bits (u16)
local PLAYER_ID_MASK = 0x0fff
local NOT_PLAYER_ID_MASK = 0xf000
local FALLOUT = 0x2000 -- bit 13
local DEFENSE_BONUS = 0x4000 -- bit 14
-- Bit 15 still reserved

-- Matches upstream `enum TerrainType` numeric values.
local TerrainType = table.freeze({
	Plains = 0,
	Highland = 1,
	Mountain = 2,
	Ocean = 3,
	Impassable = 4,
})

local GameMap = {}
GameMap.__index = GameMap
GameMap.TerrainType = TerrainType
GameMap.IMPASSABLE_MAGNITUDE = IMPASSABLE_MAGNITUDE
GameMap.PLAYER_ID_MASK = PLAYER_ID_MASK

local function isInteger(n: number): boolean
	return n == math.floor(n) and n == n
end

function GameMap.new(width: number, height: number, terrainData: buffer, numLandTiles: number)
	if buffer.len(terrainData) ~= width * height then
		error(
			`Terrain data length {buffer.len(terrainData)} doesn't match dimensions {width}x{height}`
		)
	end
	local self = setmetatable({
		_numTilesWithFallout = 0,
		_terrain = terrainData, -- terrain byte per tile
		_state = buffer.create(width * height * 2), -- u16 per tile
		_width = width,
		_height = height,
		_numLandTiles = numLandTiles,
		_waterVersion = 0,
	}, GameMap)
	return self
end

function GameMap:numTilesWithFallout(): number
	return self._numTilesWithFallout
end

function GameMap:ref(x: number, y: number): number
	if not self:isValidCoord(x, y) then
		error(`Invalid coordinates: {x},{y}`)
	end
	return y * self._width + x
end

function GameMap:isValidRef(ref: number): boolean
	return isInteger(ref) and ref >= 0 and ref < self._width * self._height
end

function GameMap:x(ref: number): number
	return ref % self._width
end

function GameMap:y(ref: number): number
	return ref // self._width
end

-- Upstream returns a Cell object; only x/y are used by ported code.
function GameMap:cell(ref: number)
	return { x = ref % self._width, y = ref // self._width }
end

function GameMap:width(): number
	return self._width
end

function GameMap:height(): number
	return self._height
end

function GameMap:numLandTiles(): number
	return self._numLandTiles
end

function GameMap:isValidCoord(x: number, y: number): boolean
	return isInteger(x) and isInteger(y) and x >= 0 and x < self._width and y >= 0 and y < self._height
end

-- Terrain getters

function GameMap:isLand(ref: number): boolean
	return btest(readu8(self._terrain, ref), IS_LAND)
end

function GameMap:isImpassable(ref: number): boolean
	local t = readu8(self._terrain, ref)
	return btest(t, IS_LAND) and band(t, MAGNITUDE_MASK) == IMPASSABLE_MAGNITUDE
end

function GameMap:isOceanShore(ref: number): boolean
	if not self:isLand(ref) then
		return false
	end
	local w = self._width
	local x = ref % w
	if x ~= 0 and self:isOcean(ref - 1) then
		return true
	end
	if x ~= w - 1 and self:isOcean(ref + 1) then
		return true
	end
	if ref >= w and self:isOcean(ref - w) then
		return true
	end
	if ref < (self._height - 1) * w and self:isOcean(ref + w) then
		return true
	end
	return false
end

function GameMap:isOcean(ref: number): boolean
	return btest(readu8(self._terrain, ref), OCEAN)
end

function GameMap:isShoreline(ref: number): boolean
	return btest(readu8(self._terrain, ref), SHORELINE)
end

function GameMap:magnitude(ref: number): number
	return band(readu8(self._terrain, ref), MAGNITUDE_MASK)
end

function GameMap:terrainByte(ref: number): number
	return readu8(self._terrain, ref)
end

-- Raw terrain buffer (read-only for callers), e.g. for building textures.
function GameMap:terrainBuffer(): buffer
	return self._terrain
end

-- Terrain setters

function GameMap:waterVersion(): number
	return self._waterVersion
end

function GameMap:setWater(ref: number)
	if not self:isLand(ref) or self:isImpassable(ref) then
		return
	end
	self._waterVersion += 1
	writeu8(self._terrain, ref, 0) -- Lake water: no land, no ocean, no shoreline, magnitude 0
	self._numLandTiles -= 1
end

function GameMap:setShorelineBit(ref: number)
	writeu8(self._terrain, ref, bor(readu8(self._terrain, ref), SHORELINE))
end

function GameMap:clearShorelineBit(ref: number)
	writeu8(self._terrain, ref, band(readu8(self._terrain, ref), 0xff - SHORELINE))
end

function GameMap:setOcean(ref: number)
	writeu8(self._terrain, ref, bor(readu8(self._terrain, ref), OCEAN))
end

function GameMap:setMagnitude(ref: number, value: number)
	local t = readu8(self._terrain, ref)
	writeu8(self._terrain, ref, bor(band(t, 0xff - MAGNITUDE_MASK), band(value, MAGNITUDE_MASK)))
end

-- State getters and setters (mutable)

function GameMap:ownerID(ref: number): number
	return band(readu16(self._state, ref * 2), PLAYER_ID_MASK)
end

function GameMap:hasOwner(ref: number): boolean
	return self:ownerID(ref) ~= 0
end

function GameMap:setOwnerID(ref: number, playerId: number)
	if playerId > PLAYER_ID_MASK then
		error(`Player ID {playerId} exceeds maximum value {PLAYER_ID_MASK}`)
	end
	local s = readu16(self._state, ref * 2)
	writeu16(self._state, ref * 2, bor(band(s, NOT_PLAYER_ID_MASK), playerId))
end

function GameMap:hasFallout(ref: number): boolean
	return btest(readu16(self._state, ref * 2), FALLOUT)
end

function GameMap:setFallout(ref: number, value: boolean)
	local existing = self:hasFallout(ref)
	local s = readu16(self._state, ref * 2)
	if value then
		if not existing then
			self._numTilesWithFallout += 1
			writeu16(self._state, ref * 2, bor(s, FALLOUT))
		end
	else
		if existing then
			self._numTilesWithFallout -= 1
			writeu16(self._state, ref * 2, band(s, 0xffff - FALLOUT))
		end
	end
end

-- True when the tile touches the map boundary or an impassable tile.
-- Impassable terrain acts like the map edge for enclosure checks: a
-- cluster hugging it cannot be "surrounded" from that side.
function GameMap:isOnEdgeOfMap(ref: number): boolean
	local w = self._width
	local x = ref % w
	if x == 0 or x == w - 1 or ref < w or ref >= (self._height - 1) * w then
		return true
	end
	return self:isImpassable(ref - 1)
		or self:isImpassable(ref + 1)
		or self:isImpassable(ref - w)
		or self:isImpassable(ref + w)
end

function GameMap:isBorder(ref: number): boolean
	local w = self._width
	local x = ref % w
	local owner = self:ownerID(ref)
	if x ~= 0 and self:ownerID(ref - 1) ~= owner then
		return true
	end
	if x ~= w - 1 and self:ownerID(ref + 1) ~= owner then
		return true
	end
	if ref >= w and self:ownerID(ref - w) ~= owner then
		return true
	end
	if ref < (self._height - 1) * w and self:ownerID(ref + w) ~= owner then
		return true
	end
	return false
end

function GameMap:hasDefenseBonus(ref: number): boolean
	return btest(readu16(self._state, ref * 2), DEFENSE_BONUS)
end

function GameMap:setDefenseBonus(ref: number, value: boolean)
	local s = readu16(self._state, ref * 2)
	if value then
		writeu16(self._state, ref * 2, bor(s, DEFENSE_BONUS))
	else
		writeu16(self._state, ref * 2, band(s, 0xffff - DEFENSE_BONUS))
	end
end

-- Helper methods

function GameMap:isWater(ref: number): boolean
	return not self:isLand(ref)
end

function GameMap:isShore(ref: number): boolean
	return self:isLand(ref) and self:isShoreline(ref)
end

function GameMap:cost(ref: number): number
	return if self:magnitude(ref) < 10 then 2 else 1
end

function GameMap:terrainType(ref: number): number
	if self:isLand(ref) then
		local magnitude = self:magnitude(ref)
		if magnitude >= IMPASSABLE_MAGNITUDE then
			return TerrainType.Impassable
		end
		if magnitude < 10 then
			return TerrainType.Plains
		end
		if magnitude < 20 then
			return TerrainType.Highland
		end
		return TerrainType.Mountain
	end
	return TerrainType.Ocean
end

-- Neighbors are always enumerated N, S, W, E (same as upstream); several
-- simulation paths are order-sensitive.
function GameMap:neighbors(ref: number): { number }
	local out = {}
	local w = self._width
	local x = ref % w
	if ref >= w then
		table.insert(out, ref - w)
	end
	if ref < (self._height - 1) * w then
		table.insert(out, ref + w)
	end
	if x ~= 0 then
		table.insert(out, ref - 1)
	end
	if x ~= w - 1 then
		table.insert(out, ref + 1)
	end
	return out
end

function GameMap:forEachNeighbor(ref: number, callback: (number) -> ())
	local w = self._width
	local x = ref % w
	if ref >= w then
		callback(ref - w)
	end
	if ref < (self._height - 1) * w then
		callback(ref + w)
	end
	if x ~= 0 then
		callback(ref - 1)
	end
	if x ~= w - 1 then
		callback(ref + 1)
	end
end

-- Writes cardinal neighbors into out[1..n] (N, S, W, E) and returns n.
function GameMap:neighbors4(ref: number, out: { number }): number
	local w = self._width
	local x = ref % w
	local n = 0
	if ref >= w then
		n += 1
		out[n] = ref - w
	end
	if ref < (self._height - 1) * w then
		n += 1
		out[n] = ref + w
	end
	if x ~= 0 then
		n += 1
		out[n] = ref - 1
	end
	if x ~= w - 1 then
		n += 1
		out[n] = ref + 1
	end
	return n
end

-- Writes all 8 neighbors into out[1..n] in dx-major order and returns n.
function GameMap:neighbors8(ref: number, out: { number }): number
	local w = self._width
	local x = ref % w
	local hasN = ref >= w
	local hasS = ref < (self._height - 1) * w
	local n = 0
	if x ~= 0 then
		if hasN then
			n += 1
			out[n] = ref - 1 - w
		end
		n += 1
		out[n] = ref - 1
		if hasS then
			n += 1
			out[n] = ref - 1 + w
		end
	end
	if hasN then
		n += 1
		out[n] = ref - w
	end
	if hasS then
		n += 1
		out[n] = ref + w
	end
	if x ~= w - 1 then
		if hasN then
			n += 1
			out[n] = ref + 1 - w
		end
		n += 1
		out[n] = ref + 1
		if hasS then
			n += 1
			out[n] = ref + 1 + w
		end
	end
	return n
end

-- Diagonal-inclusive iteration in dx-major order:
-- (-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1).
function GameMap:forEachNeighborWithDiag(ref: number, callback: (number) -> ())
	local w = self._width
	local x = ref % w
	local hasN = ref >= w
	local hasS = ref < (self._height - 1) * w
	if x ~= 0 then
		if hasN then
			callback(ref - 1 - w)
		end
		callback(ref - 1)
		if hasS then
			callback(ref - 1 + w)
		end
	end
	if hasN then
		callback(ref - w)
	end
	if hasS then
		callback(ref + w)
	end
	if x ~= w - 1 then
		if hasN then
			callback(ref + 1 - w)
		end
		callback(ref + 1)
		if hasS then
			callback(ref + 1 + w)
		end
	end
end

function GameMap:forEachTile(fn: (number) -> ())
	for ref = 0, self._width * self._height - 1 do
		fn(ref)
	end
end

function GameMap:manhattanDist(c1: number, c2: number): number
	local w = self._width
	return math.abs(c1 % w - c2 % w) + math.abs(c1 // w - c2 // w)
end

function GameMap:euclideanDistSquared(c1: number, c2: number): number
	local w = self._width
	local x = c1 % w - c2 % w
	local y = c1 // w - c2 // w
	return x * x + y * y
end

-- Returns a JSSet of tiles within `radius`, iterated x-major like upstream.
function GameMap:circleSearch(tile: number, radius: number, filter: ((number, number) -> boolean)?)
	local w = self._width
	local cx, cy = tile % w, tile // w
	local tiles = JSSet.new()
	local minX = math.max(0, cx - radius)
	local maxX = math.min(w - 1, cx + radius)
	local minY = math.max(0, cy - radius)
	local maxY = math.min(self._height - 1, cy + radius)
	local r2 = radius * radius
	for i = minX, maxX do
		for j = minY, maxY do
			local t = j * w + i
			local d2 = self:euclideanDistSquared(tile, t)
			if d2 <= r2 and (filter == nil or filter(t, d2)) then
				tiles:add(t)
			end
		end
	end
	return tiles
end

-- Flood fill from `tile` over tiles accepted by filter(gm, tile).
-- Uses a stack (q.pop()) exactly like upstream, so visit order matches.
function GameMap:bfs(tile: number, filter: (any, number) -> boolean)
	local seen = JSSet.new()
	local q: { number } = {}
	if filter(self, tile) then
		seen:add(tile)
		table.insert(q, tile)
	end
	local w = self._width
	local southLimit = (self._height - 1) * w
	local function visit(n: number)
		if not seen:has(n) and filter(self, n) then
			seen:add(n)
			table.insert(q, n)
		end
	end
	while #q > 0 do
		local curr = table.remove(q) :: number
		local x = curr % w
		if curr >= w then
			visit(curr - w)
		end
		if curr < southLimit then
			visit(curr + w)
		end
		if x ~= 0 then
			visit(curr - 1)
		end
		if x ~= w - 1 then
			visit(curr + 1)
		end
	end
	return seen
end

function GameMap:tileState(tile: number): number
	return readu16(self._state, tile * 2)
end

-- Live u16-per-tile state buffer: bits 0-11 owner, 13 fallout, 14 defense.
function GameMap:tileStateBuffer(): buffer
	return self._state
end

-- Update a tile from a packed value:
--   bits  0-15: tile state (owner, fallout, etc.)
--   bits 16-23: terrain byte (land, ocean, shoreline, magnitude)
-- Returns true when the terrain byte changed.
function GameMap:updateTile(tile: number, packed: number): boolean
	local state = band(packed, 0xffff)
	local terrainByte = band(bit32.rshift(packed, 16), 0xff)

	local existingFallout = self:hasFallout(tile)
	writeu16(self._state, tile * 2, state)
	local newFallout = self:hasFallout(tile)
	if existingFallout and not newFallout then
		self._numTilesWithFallout -= 1
	end
	if not existingFallout and newFallout then
		self._numTilesWithFallout += 1
	end

	local terrainChanged = readu8(self._terrain, tile) ~= terrainByte
	if terrainChanged then
		local wasLand = self:isLand(tile)
		writeu8(self._terrain, tile, terrainByte)
		local isNowLand = btest(terrainByte, IS_LAND)
		-- Water-derived caches key on waterVersion(): a packed update that flips
		-- land/water must invalidate them just like setWater() does.
		if wasLand ~= isNowLand then
			self._waterVersion += 1
		end
		if wasLand and not isNowLand then
			self._numLandTiles -= 1
		elseif not wasLand and isNowLand then
			self._numLandTiles += 1
		end
	end
	return terrainChanged
end

-- Distance filter factories (upstream free functions). Each returns a
-- predicate (gm, tile) -> boolean suitable for GameMap:bfs.

function GameMap.euclDistFN(root: number, dist: number, center: boolean?)
	local dist2 = dist * dist
	if not center then
		return function(gm, n: number): boolean
			return gm:euclideanDistSquared(root, n) <= dist2
		end
	end
	return function(gm, n: number): boolean
		-- Shifts the root tile's coordinates by -0.5 so its "center" becomes
		-- the corner of four pixels rather than the middle of one pixel.
		local rootX = gm:x(root) - 0.5
		local rootY = gm:y(root) - 0.5
		local dx = gm:x(n) - rootX
		local dy = gm:y(n) - rootY
		return dx * dx + dy * dy <= dist2
	end
end

function GameMap.manhattanDistFN(root: number, dist: number, center: boolean?)
	if not center then
		return function(gm, n: number): boolean
			return gm:manhattanDist(root, n) <= dist
		end
	end
	return function(gm, n: number): boolean
		local rootX = gm:x(root) - 0.5
		local rootY = gm:y(root) - 0.5
		return math.abs(gm:x(n) - rootX) + math.abs(gm:y(n) - rootY) <= dist
	end
end

function GameMap.rectDistFN(root: number, dist: number, center: boolean?)
	if not center then
		return function(gm, n: number): boolean
			return math.abs(gm:x(n) - gm:x(root)) <= dist and math.abs(gm:y(n) - gm:y(root)) <= dist
		end
	end
	return function(gm, n: number): boolean
		local rootX = gm:x(root) - 0.5
		local rootY = gm:y(root) - 0.5
		return math.abs(gm:x(n) - rootX) <= dist and math.abs(gm:y(n) - rootY) <= dist
	end
end

local function isInIsometricTile(cx: number, cy: number, tx: number, ty: number, yOffset: number, distance: number)
	local dx = math.abs(tx - cx)
	local dy = math.abs(ty - (cy + yOffset))
	return dx + dy * 2 <= distance + 1
end

function GameMap.isometricDistFN(root: number, dist: number, center: boolean?)
	if not center then
		return function(gm, n: number): boolean
			return gm:manhattanDist(root, n) <= dist
		end
	end
	return function(gm, n: number): boolean
		local rootX = gm:x(root) - 0.5
		local rootY = gm:y(root) - 0.5
		return isInIsometricTile(rootX, rootY, gm:x(n), gm:y(n), 0, dist)
	end
end

function GameMap.hexDistFN(root: number, dist: number, center: boolean?)
	if not center then
		return function(gm, n: number): boolean
			local dx = math.abs(gm:x(n) - gm:x(root))
			local dy = math.abs(gm:y(n) - gm:y(root))
			return dx <= dist and dy <= dist and dx + dy <= dist * 1.5
		end
	end
	return function(gm, n: number): boolean
		local rootX = gm:x(root) - 0.5
		local rootY = gm:y(root) - 0.5
		local dx = math.abs(gm:x(n) - rootX)
		local dy = math.abs(gm:y(n) - rootY)
		return dx <= dist and dy <= dist and dx + dy <= dist * 1.5
	end
end

function GameMap.andFN(a, b)
	return function(gm, tile: number): boolean
		return a(gm, tile) and b(gm, tile)
	end
end

return GameMap
