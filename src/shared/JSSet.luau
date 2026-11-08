--!native
-- Insertion-ordered set with JavaScript `Set` semantics.
--
-- OpenFrontIO's core relies on JS Set iteration order (insertion order) in
-- simulation code, e.g. which border tile an attack takes first. A plain Luau
-- table iterated with pairs() has no defined order, so ported code uses this.
--
-- Deleted entries leave a tombstone that is skipped during iteration; the
-- backing array is compacted into a fresh array once tombstones dominate.
-- Iterators keep the array they started on, so deleting during iteration is
-- safe (as in JS). Values added during iteration are visited unless a
-- compaction happened mid-iteration.
--
-- Usage:
--   local s = JSSet.new()
--   s:add(5); s:has(5); s:delete(5); s:size()
--   for v in s do ... end

local JSSet = {}
JSSet.__index = JSSet

local TOMB = newproxy(false)

function JSSet.new(values: { any }?)
	local self = setmetatable({
		_items = {} :: { any },
		_index = {} :: { [any]: number },
		_n = 0,
		_size = 0,
	}, JSSet)
	if values then
		for _, v in values do
			self:add(v)
		end
	end
	return self
end

function JSSet:add(v: any)
	if self._index[v] == nil then
		local n = self._n + 1
		self._n = n
		self._items[n] = v
		self._index[v] = n
		self._size += 1
	end
	return self
end

function JSSet:has(v: any): boolean
	return self._index[v] ~= nil
end

function JSSet:delete(v: any): boolean
	local i = self._index[v]
	if i == nil then
		return false
	end
	self._items[i] = TOMB
	self._index[v] = nil
	self._size -= 1
	if self._n > 64 and self._size * 2 < self._n then
		self:_compact()
	end
	return true
end

function JSSet:size(): number
	return self._size
end

function JSSet:clear()
	self._items = {}
	self._index = {}
	self._n = 0
	self._size = 0
end

function JSSet:_compact()
	local items = self._items
	local fresh = table.create(self._size)
	local index = self._index
	local n = 0
	for i = 1, self._n do
		local v = items[i]
		if v ~= TOMB then
			n += 1
			fresh[n] = v
			index[v] = n
		end
	end
	self._items = fresh
	self._n = n
end

function JSSet:__iter()
	local items = self._items
	local i = 0
	return function()
		while true do
			i += 1
			local v = items[i]
			if v == nil then
				return nil
			end
			-- Skip tombstones, and entries deleted after a compaction or clear()
			-- swapped the backing array out from under this iterator. Read
			-- self._index live: clear() replaces the table.
			if v ~= TOMB and self._index[v] ~= nil then
				return v
			end
		end
	end
end

function JSSet:forEach(fn: (any) -> ())
	for v in self do
		fn(v)
	end
end

function JSSet:toArray(): { any }
	local out = table.create(self._size)
	for v in self do
		table.insert(out, v)
	end
	return out
end

return JSSet
