--!native
-- Port of OpenFrontIO src/core/pathfinding/algorithms/ConnectedComponents.ts.
-- Labels water components with a scan-line flood fill; supports incremental
-- growth (land -> water after nukes) through a union-find alias table.
--
-- Upstream starts with a Uint8Array (land marker 0xFF) and promotes to
-- Uint16Array (land marker 0xFFFF) once 253 components exist. The marker is
-- observable through getComponentId() on land tiles, so it is tracked here
-- even though storage is always u16.

local ConnectedComponents = {}
ConnectedComponents.__index = ConnectedComponents

local LAND_STORED = 0xffff -- internal u16 land marker
local readu16, writeu16 = buffer.readu16, buffer.writeu16

function ConnectedComponents.new(map)
	local w, h = map:width(), map:height()
	return setmetatable({
		map = map,
		width = w,
		height = h,
		numTiles = w * h,
		lastRowStart = (h - 1) * w,
		ids = nil :: buffer?,
		sizes = {}, -- componentId -> size
		parents = {},
		maxId = 0,
		landMarker = 0xff, -- value getComponentId reports for land
	}, ConnectedComponents)
end

function ConnectedComponents:initialize()
	local n = self.numTiles
	local ids = buffer.create(n * 2)
	local terrain = self.map:terrainBuffer()
	for i = 0, n - 1 do
		if buffer.readu8(terrain, i) >= 0x80 then
			writeu16(ids, i * 2, LAND_STORED)
		end
	end
	self.sizes = {}
	local queue = buffer.create(n * 4)
	local nextId = 0
	local upgraded = false
	for start = 0, n - 1 do
		local value = readu16(ids, start * 2)
		if value == LAND_STORED or value > 0 then
			continue
		end
		nextId += 1
		if nextId == 253 then
			upgraded = true -- upstream promotes Uint8Array -> Uint16Array here
		end
		if nextId == 0xffff then
			break
		end
		self:_floodFill(ids, queue, start, nextId)
	end
	self.ids = ids
	self.landMarker = if upgraded then 0xffff else 0xff
	self.maxId = nextId
	self.parents = {}
	for i = 0, nextId do
		self.parents[i] = i
	end
end

function ConnectedComponents:_floodFill(ids: buffer, queue: buffer, start: number, componentId: number)
	local width = self.width
	local lastRowStart = self.lastRowStart
	local sizes = self.sizes
	local head, tail = 0, 0
	buffer.writei32(queue, 0, start)
	tail = 1
	while head < tail do
		local seed = buffer.readi32(queue, head * 4)
		head += 1
		if readu16(ids, seed * 2) ~= 0 then
			continue
		end
		local rowStart = seed - (seed % width)
		local left = seed
		while left > rowStart and readu16(ids, (left - 1) * 2) == 0 do
			left -= 1
		end
		local rowEnd = rowStart + width - 1
		local right = seed
		while right < rowEnd and readu16(ids, (right + 1) * 2) == 0 do
			right += 1
		end
		sizes[componentId] = (sizes[componentId] or 0) + (right - left + 1)
		for x = left, right do
			writeu16(ids, x * 2, componentId)
			if x >= width then
				local above = x - width
				if readu16(ids, above * 2) == 0 then
					buffer.writei32(queue, tail * 4, above)
					tail += 1
				end
			end
			if x < lastRowStart then
				local below = x + width
				if readu16(ids, below * 2) == 0 then
					buffer.writei32(queue, tail * 4, below)
					tail += 1
				end
			end
		end
	end
end

function ConnectedComponents:_find(id: number): number
	local parents = self.parents
	local root = id
	while parents[root] ~= root do
		root = parents[root]
	end
	local cur = id
	while parents[cur] ~= root do
		local nxt = parents[cur]
		parents[cur] = root
		cur = nxt
	end
	return root
end

function ConnectedComponents:_rootAt(index: number): number
	local id = readu16(self.ids :: buffer, index * 2)
	if id == 0 or id == LAND_STORED then
		return 0
	end
	return self:_find(id)
end

function ConnectedComponents:_allocComponentId(): number
	if self.maxId >= 0xfffe then
		return self.maxId
	end
	self.maxId += 1
	local id = self.maxId
	if id >= 253 then
		self.landMarker = 0xffff
	end
	self.parents[id] = id
	return id
end

-- Incrementally add newly converted water tiles (land -> water).
function ConnectedComponents:addWaterTiles(tiles)
	local ids = self.ids
	if not ids then
		return
	end
	local width = self.width
	for _, tile in tiles do
		if readu16(ids, tile * 2) ~= LAND_STORED then
			continue
		end
		local x = tile % width
		local r0, r1, r2, r3 = 0, 0, 0, 0
		if tile >= width then
			r0 = self:_rootAt(tile - width)
		end
		if tile < self.lastRowStart then
			r1 = self:_rootAt(tile + width)
		end
		if x > 0 then
			r2 = self:_rootAt(tile - 1)
		end
		if x < width - 1 then
			r3 = self:_rootAt(tile + 1)
		end
		local canon = 0
		for _, r in { r0, r1, r2, r3 } do
			if r ~= 0 and (canon == 0 or r < canon) then
				canon = r
			end
		end
		if canon == 0 then
			local id = self:_allocComponentId()
			writeu16(ids, tile * 2, id)
			self.sizes[id] = 1
			continue
		end
		writeu16(ids, tile * 2, canon)
		self.sizes[canon] = (self.sizes[canon] or 0) + 1
		for _, r in { r0, r1, r2, r3 } do
			if r ~= 0 and r ~= canon and self.parents[r] ~= canon then
				self.parents[r] = canon
				self.sizes[canon] = (self.sizes[canon] or 0) + (self.sizes[r] or 0)
				self.sizes[r] = 0
			end
		end
	end
end

function ConnectedComponents:getComponentId(tile: number): number
	local ids = self.ids
	if not ids then
		return 0
	end
	local id = readu16(ids, tile * 2)
	if id == 0 then
		return 0
	end
	if id == LAND_STORED then
		return self.landMarker
	end
	return self:_find(id)
end

function ConnectedComponents:getComponentSize(componentId: number): number
	if componentId <= 0 or componentId > self.maxId then
		return 0
	end
	return self.sizes[self:_find(componentId)] or 0
end

return ConnectedComponents
