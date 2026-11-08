--!native
-- Port of MinHeap from OpenFrontIO src/core/pathfinding/algorithms/PriorityQueue.ts.
--
-- Priorities are stored as float32 (upstream Float32Array) and compared
-- AFTER that rounding, exactly like upstream; nodes are int32.

local MinHeap = {}
MinHeap.__index = MinHeap

local readf32, writef32 = buffer.readf32, buffer.writef32
local readi32, writei32 = buffer.readi32, buffer.writei32

function MinHeap.new(capacity: number)
	return setmetatable({
		_heap = buffer.create(capacity * 4),
		_pri = buffer.create(capacity * 4),
		_capacity = capacity,
		_size = 0,
	}, MinHeap)
end

function MinHeap:push(node: number, priority: number)
	if self._size >= self._capacity then
		warn(`MinHeap capacity exceeded ({self._capacity}). Resizing, but this indicates a bug.`)
		local newCap = self._capacity * 2
		local newHeap = buffer.create(newCap * 4)
		local newPri = buffer.create(newCap * 4)
		buffer.copy(newHeap, 0, self._heap, 0, self._capacity * 4)
		buffer.copy(newPri, 0, self._pri, 0, self._capacity * 4)
		self._heap, self._pri, self._capacity = newHeap, newPri, newCap
	end
	local heap, pri = self._heap, self._pri
	local i = self._size
	self._size = i + 1
	writei32(heap, i * 4, node)
	writef32(pri, i * 4, priority)

	-- Bubble up (compares stored, float32-rounded priorities)
	while i > 0 do
		local parent = (i - 1) // 2
		local pp, pi = readf32(pri, parent * 4), readf32(pri, i * 4)
		if pp <= pi then
			break
		end
		local tmpNode = readi32(heap, parent * 4)
		writei32(heap, parent * 4, readi32(heap, i * 4))
		writef32(pri, parent * 4, pi)
		writei32(heap, i * 4, tmpNode)
		writef32(pri, i * 4, pp)
		i = parent
	end
end

function MinHeap:pop(): number
	local heap, pri = self._heap, self._pri
	local result = readi32(heap, 0)
	local size = self._size - 1
	self._size = size
	if size > 0 then
		writei32(heap, 0, readi32(heap, size * 4))
		writef32(pri, 0, readf32(pri, size * 4))
		-- Bubble down
		local i = 0
		while true do
			local left = i * 2 + 1
			local right = left + 1
			local smallest = i
			if left < size and readf32(pri, left * 4) < readf32(pri, smallest * 4) then
				smallest = left
			end
			if right < size and readf32(pri, right * 4) < readf32(pri, smallest * 4) then
				smallest = right
			end
			if smallest == i then
				break
			end
			local tmpNode, tmpPri = readi32(heap, smallest * 4), readf32(pri, smallest * 4)
			writei32(heap, smallest * 4, readi32(heap, i * 4))
			writef32(pri, smallest * 4, readf32(pri, i * 4))
			writei32(heap, i * 4, tmpNode)
			writef32(pri, i * 4, tmpPri)
			i = smallest
		end
	end
	return result
end

function MinHeap:isEmpty(): boolean
	return self._size == 0
end

function MinHeap:clear()
	self._size = 0
end

return MinHeap
