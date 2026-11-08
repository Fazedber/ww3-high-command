--!native
-- Port of OpenFrontIO src/core/pathfinding/algorithms/AStar.ts (generic A*
-- with an adapter) and BucketQueue from PriorityQueue.ts.
--
-- adapter = {
--   neighbors(self, node, buf) -> count   (writes 1-based into buf)
--   cost(self, from, to, prev?) -> number
--   heuristic(self, node, goal) -> number
--   numNodes(self), maxPriority(self), maxNeighbors(self)
-- }
-- Nodes are 0-based integers, like upstream.

local readu32, writeu32 = buffer.readu32, buffer.writeu32
local readi32, writei32 = buffer.readi32, buffer.writei32

-- BucketQueue: O(1) push/pop for integer priorities; LIFO within a bucket.
local BucketQueue = {}
BucketQueue.__index = BucketQueue

function BucketQueue.new(maxPriority: number)
	local maxBucket = maxPriority + 1
	return setmetatable({
		buckets = {}, -- bucket -> { nodes }
		bucketSizes = table.create(maxBucket, 0),
		bucketStamp = table.create(maxBucket, 0),
		stamp = 0,
		maxBucket = maxBucket,
		minBucket = maxBucket,
		size = 0,
	}, BucketQueue)
end

function BucketQueue:push(node: number, priority: number)
	-- JS \`priority | 0\` (priorities are non-negative here).
	local bucket = math.min(math.floor(priority), self.maxBucket - 1)
	local i = bucket + 1
	local list = self.buckets[i]
	if list == nil then
		list = {}
		self.buckets[i] = list
	end
	local size = if self.bucketStamp[i] == self.stamp then self.bucketSizes[i] else 0
	list[size + 1] = node
	self.bucketSizes[i] = size + 1
	self.bucketStamp[i] = self.stamp
	self.size += 1
	if bucket < self.minBucket then
		self.minBucket = bucket
	end
end

function BucketQueue:pop(): number
	while self.minBucket < self.maxBucket do
		local i = self.minBucket + 1
		if self.bucketStamp[i] == self.stamp then
			local size = self.bucketSizes[i]
			if size > 0 then
				self.bucketSizes[i] = size - 1
				self.size -= 1
				return self.buckets[i][size]
			end
		end
		self.minBucket += 1
	end
	return -1
end

function BucketQueue:isEmpty(): boolean
	return self.size == 0
end

function BucketQueue:clear()
	self.stamp += 1
	self.minBucket = self.maxBucket
	self.size = 0
end

-- AStar -------------------------------------------------------------------------------

local AStar = {}
AStar.__index = AStar
AStar.BucketQueue = BucketQueue

function AStar.new(adapter, maxIterations: number?)
	local n = adapter:numNodes()
	return setmetatable({
		adapter = adapter,
		maxIterations = maxIterations or 500000,
		stamp = 1,
		closedStamp = buffer.create(n * 4),
		gScoreStamp = buffer.create(n * 4),
		gScore = buffer.create(n * 4),
		cameFrom = buffer.create(n * 4),
		queue = BucketQueue.new(adapter:maxPriority()),
		neighborBuffer = table.create(adapter:maxNeighbors(), 0),
	}, AStar)
end

function AStar:findPath(start, goal: number): { number }?
	self.stamp += 1
	local stamp = self.stamp
	local adapter = self.adapter
	local closedStamp, gScoreStamp, gScore, cameFrom = self.closedStamp, self.gScoreStamp, self.gScore, self.cameFrom
	local queue = self.queue
	local buf = self.neighborBuffer

	queue:clear()
	local starts = if type(start) == "table" then start else { start }
	for _, s in starts do
		writeu32(gScore, s * 4, 0)
		writeu32(gScoreStamp, s * 4, stamp)
		writei32(cameFrom, s * 4, -1)
		queue:push(s, adapter:heuristic(s, goal))
	end

	local iterations = self.maxIterations
	while not queue:isEmpty() do
		iterations -= 1
		if iterations <= 0 then
			return nil
		end
		local current = queue:pop()
		if readu32(closedStamp, current * 4) == stamp then
			continue
		end
		writeu32(closedStamp, current * 4, stamp)
		if current == goal then
			return self:_buildPath(goal)
		end

		local currentG = readu32(gScore, current * 4)
		local prev = readi32(cameFrom, current * 4)
		local count = adapter:neighbors(current, buf)
		for i = 1, count do
			local neighbor = buf[i]
			if readu32(closedStamp, neighbor * 4) == stamp then
				continue
			end
			local tentativeG = currentG + adapter:cost(current, neighbor, if prev == -1 then nil else prev)
			if readu32(gScoreStamp, neighbor * 4) ~= stamp or tentativeG < readu32(gScore, neighbor * 4) then
				writei32(cameFrom, neighbor * 4, current)
				writeu32(gScore, neighbor * 4, tentativeG)
				writeu32(gScoreStamp, neighbor * 4, stamp)
				queue:push(neighbor, tentativeG + adapter:heuristic(neighbor, goal))
			end
		end
	end
	return nil
end

function AStar:_buildPath(goal: number): { number }
	local rev = {}
	local current = goal
	while current ~= -1 do
		table.insert(rev, current)
		current = readi32(self.cameFrom, current * 4)
	end
	local n = #rev
	local path = table.create(n)
	for i = 1, n do
		path[i] = rev[n - i + 1]
	end
	return path
end

return AStar
