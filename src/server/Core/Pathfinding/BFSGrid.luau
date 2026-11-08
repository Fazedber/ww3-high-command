--!native
-- Port of OpenFrontIO src/core/pathfinding/algorithms/BFS.Grid.ts.
-- 4-direction grid BFS with stamp-based visited tracking.
--
-- Visitor protocol (upstream returns R / undefined / null):
--   return a value       -> found, search returns it
--   return nil           -> valid node, explore neighbors
--   return BFSGrid.REJECT -> reject node, don't explore neighbors

local BFSGrid = {}
BFSGrid.__index = BFSGrid

BFSGrid.REJECT = newproxy(false)
local REJECT = BFSGrid.REJECT

local readu32, writeu32 = buffer.readu32, buffer.writeu32
local readi32, writei32 = buffer.readi32, buffer.writei32
local readu16, writeu16 = buffer.readu16, buffer.writeu16

function BFSGrid.new(numNodes: number)
	return setmetatable({
		_stamp = 1,
		_visited = buffer.create(numNodes * 4),
		_queue = buffer.create(numNodes * 4),
		_dist = buffer.create(numNodes * 2), -- u16, like upstream
	}, BFSGrid)
end

function BFSGrid:_nextStamp(): number
	local stamp = self._stamp
	self._stamp += 1
	if self._stamp > 0xffffffff then
		buffer.fill(self._visited, 0, 0)
		self._stamp = 1
	end
	return stamp
end

function BFSGrid:search(width: number, height: number, start: number | { number }, maxDistance: number, isValidNode: (number) -> boolean, visitor: (number, number) -> any): any
	local stamp = self:_nextStamp()
	local lastRowStart = (height - 1) * width
	local visited, queue, dist = self._visited, self._queue, self._dist
	local head, tail = 0, 0

	local starts = if type(start) == "number" then { start } else start
	for _, s in starts do
		writeu32(visited, s * 4, stamp)
		writeu16(dist, s * 2, 0)
		writei32(queue, tail * 4, s)
		tail += 1
	end

	while head < tail do
		local node = readi32(queue, head * 4)
		head += 1
		local d = readu16(dist, node * 2)

		local result = visitor(node, d)
		if result == REJECT then
			continue
		end
		if result ~= nil then
			return result
		end

		local nextDist = d + 1
		if nextDist > maxDistance then
			continue
		end
		local nd = nextDist % 65536 -- Uint16Array store

		local x = node % width
		if node >= width then
			local n = node - width
			if readu32(visited, n * 4) ~= stamp and isValidNode(n) then
				writeu32(visited, n * 4, stamp)
				writeu16(dist, n * 2, nd)
				writei32(queue, tail * 4, n)
				tail += 1
			end
		end
		if node < lastRowStart then
			local s = node + width
			if readu32(visited, s * 4) ~= stamp and isValidNode(s) then
				writeu32(visited, s * 4, stamp)
				writeu16(dist, s * 2, nd)
				writei32(queue, tail * 4, s)
				tail += 1
			end
		end
		if x ~= 0 then
			local wv = node - 1
			if readu32(visited, wv * 4) ~= stamp and isValidNode(wv) then
				writeu32(visited, wv * 4, stamp)
				writeu16(dist, wv * 2, nd)
				writei32(queue, tail * 4, wv)
				tail += 1
			end
		end
		if x ~= width - 1 then
			local ev = node + 1
			if readu32(visited, ev * 4) ~= stamp and isValidNode(ev) then
				writeu32(visited, ev * 4, stamp)
				writeu16(dist, ev * 2, nd)
				writei32(queue, tail * 4, ev)
				tail += 1
			end
		end
	end
	return nil
end

return BFSGrid
