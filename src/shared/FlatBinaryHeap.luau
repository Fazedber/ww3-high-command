--!native
-- Port of OpenFrontIO src/core/execution/utils/FlatBinaryHeap.ts.
--
-- Min-heap of (priority, tile) pairs. Upstream stores priorities in a
-- Float32Array, which rounds every priority to float32 — that rounding
-- decides tie order between tiles, so priorities live in an f32 buffer here
-- too. Tiles (TileRefs, 0-based ints) live in a parallel u32 buffer.

local FlatBinaryHeap = {}
FlatBinaryHeap.__index = FlatBinaryHeap

local readf32, writef32 = buffer.readf32, buffer.writef32
local readu32, writeu32 = buffer.readu32, buffer.writeu32

function FlatBinaryHeap.new(capacity: number?)
	local cap = capacity or 1024
	return setmetatable({
		_pri = buffer.create(cap * 4),
		_tiles = buffer.create(cap * 4),
		_cap = cap,
		_len = 0,
	}, FlatBinaryHeap)
end

-- Remove every element without reallocating.
function FlatBinaryHeap:clear()
	self._len = 0
end

function FlatBinaryHeap:size(): number
	return self._len
end

function FlatBinaryHeap:enqueue(tile: number, priority: number)
	if self._len == self._cap then
		self:_grow()
	end
	local pri, tiles = self._pri, self._tiles
	-- Compare against the float32-rounded value, exactly as upstream compares
	-- a double priority against Float32Array entries.
	local i = self._len
	self._len = i + 1

	-- sift-up
	while i > 0 do
		local parent = (i - 1) // 2
		local pp = readf32(pri, parent * 4)
		if priority >= pp then
			break
		end
		writef32(pri, i * 4, pp)
		writeu32(tiles, i * 4, readu32(tiles, parent * 4))
		i = parent
	end
	writef32(pri, i * 4, priority)
	writeu32(tiles, i * 4, tile)
end

-- Remove and return the lowest-priority tile.
function FlatBinaryHeap:dequeue(): number
	if self._len == 0 then
		error("heap empty")
	end
	local pri, tiles = self._pri, self._tiles
	local topTile = readu32(tiles, 0)

	local len = self._len - 1
	self._len = len
	local lastPri = readf32(pri, len * 4)
	local lastTile = readu32(tiles, len * 4)

	-- sift-down
	local i = 0
	while true do
		local left = i * 2 + 1
		if left >= len then
			break
		end
		local right = left + 1
		local child = left
		if right < len and readf32(pri, right * 4) < readf32(pri, left * 4) then
			child = right
		end
		local cp = readf32(pri, child * 4)
		if lastPri <= cp then
			break
		end
		writef32(pri, i * 4, cp)
		writeu32(tiles, i * 4, readu32(tiles, child * 4))
		i = child
	end
	writef32(pri, i * 4, lastPri)
	writeu32(tiles, i * 4, lastTile)
	return topTile
end

-- Double the underlying storage.
function FlatBinaryHeap:_grow()
	local newCap = self._cap * 2
	local newPri = buffer.create(newCap * 4)
	local newTiles = buffer.create(newCap * 4)
	buffer.copy(newPri, 0, self._pri, 0, self._cap * 4)
	buffer.copy(newTiles, 0, self._tiles, 0, self._cap * 4)
	self._pri = newPri
	self._tiles = newTiles
	self._cap = newCap
end

return FlatBinaryHeap
