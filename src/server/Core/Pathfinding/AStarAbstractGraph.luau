--!native
-- Port of OpenFrontIO src/core/pathfinding/algorithms/AStar.AbstractGraph.ts.
-- A* over the abstract water graph (gScore is float32, as upstream).

local MinHeap = require(script.Parent.MinHeap)

local readu32, writeu32 = buffer.readu32, buffer.writeu32
local readf32, writef32 = buffer.readf32, buffer.writef32
local readi32, writei32 = buffer.readi32, buffer.writei32

local AStarAbstractGraph = {}
AStarAbstractGraph.__index = AStarAbstractGraph

function AStarAbstractGraph.new(graph, config)
	local n = math.max(1, graph.nodeCount)
	return setmetatable({
		graph = graph,
		heuristicWeight = config and config.heuristicWeight or 1,
		maxIterations = config and config.maxIterations or 100000,
		_stamp = 1,
		_closed = buffer.create(n * 4),
		_gStamp = buffer.create(n * 4),
		_g = buffer.create(n * 4),
		_cameFrom = buffer.create(n * 4),
		_startNode = buffer.create(n * 4),
		_numNodes = graph.nodeCount,
		-- Lazy duplicates can exceed numNodes: one push per directed relaxation.
		queue = MinHeap.new(math.max(1, graph.nodeCount + graph.edgeCount * 2)),
	}, AStarAbstractGraph)
end

function AStarAbstractGraph:findPath(start, goal: number)
	if type(start) == "table" then
		return self:_findPathMultiSource(start, goal)
	end
	return self:_findPathSingle(start, goal)
end

function AStarAbstractGraph:_bumpStamp(): number
	self._stamp += 1
	if self._stamp > 0xffffffff then
		buffer.fill(self._closed, 0, 0)
		buffer.fill(self._gStamp, 0, 0)
		self._stamp = 1
	end
	return self._stamp
end

-- Shared A* loop; `multi` propagates the winning start node.
function AStarAbstractGraph:_run(starts: { number }, goalId: number, multi: boolean)
	local stamp = self:_bumpStamp()
	local graph = self.graph
	local closed, gStamp, g, cameFrom, startNode = self._closed, self._gStamp, self._g, self._cameFrom, self._startNode
	local queue = self.queue
	local weight = self.heuristicWeight

	local goalNode = graph:getNode(goalId)
	if not goalNode then
		return nil
	end
	local goalX, goalY = goalNode.x, goalNode.y

	queue:clear()
	if multi then
		for _, startId in starts do
			local node = graph:getNode(startId)
			if not node then
				continue
			end
			writef32(g, startId * 4, 0)
			writeu32(gStamp, startId * 4, stamp)
			writei32(cameFrom, startId * 4, -1)
			writei32(startNode, startId * 4, startId)
			queue:push(startId, weight * (math.abs(node.x - goalX) + math.abs(node.y - goalY)))
		end
	else
		local startId = starts[1]
		local startNodeObj = graph:getNode(startId)
		if not startNodeObj then
			return nil
		end
		writef32(g, startId * 4, 0)
		writeu32(gStamp, startId * 4, stamp)
		writei32(cameFrom, startId * 4, -1)
		queue:push(startId, weight * (math.abs(startNodeObj.x - goalX) + math.abs(startNodeObj.y - goalY)))
	end

	local iterations = self.maxIterations
	while not queue:isEmpty() do
		iterations -= 1
		if iterations <= 0 then
			return nil
		end
		local current = queue:pop()
		if readu32(closed, current * 4) == stamp then
			continue
		end
		writeu32(closed, current * 4, stamp)
		if current == goalId then
			return self:_buildPathFromGoal(goalId)
		end
		local currentG = readf32(g, current * 4)
		local currentStart = if multi then readi32(startNode, current * 4) else 0
		for _, edge in graph:getNodeEdges(current) do
			local neighbor = if edge.nodeA == current then edge.nodeB else edge.nodeA
			if readu32(closed, neighbor * 4) == stamp then
				continue
			end
			local tentativeG = currentG + edge.cost
			if readu32(gStamp, neighbor * 4) ~= stamp or tentativeG < readf32(g, neighbor * 4) then
				writei32(cameFrom, neighbor * 4, current)
				writef32(g, neighbor * 4, tentativeG)
				writeu32(gStamp, neighbor * 4, stamp)
				if multi then
					writei32(startNode, neighbor * 4, currentStart)
				end
				local nn = graph:getNode(neighbor)
				if nn then
					queue:push(neighbor, tentativeG + weight * (math.abs(nn.x - goalX) + math.abs(nn.y - goalY)))
				end
			end
		end
	end
	return nil
end

function AStarAbstractGraph:_findPathSingle(startId: number, goalId: number)
	return self:_run({ startId }, goalId, false)
end

function AStarAbstractGraph:_findPathMultiSource(startIds: { number }, goalId: number)
	if #startIds == 0 then
		return nil
	end
	if #startIds == 1 then
		return self:_findPathSingle(startIds[1], goalId)
	end
	return self:_run(startIds, goalId, true)
end

function AStarAbstractGraph:_buildPathFromGoal(goalId: number)
	local path = {}
	local current = goalId
	local maxLen = self._numNodes
	while current ~= -1 do
		if current < 0 or current >= maxLen then
			return nil
		end
		table.insert(path, current)
		if #path > maxLen then
			return nil
		end
		current = readi32(self._cameFrom, current * 4)
	end
	-- reverse
	local n = #path
	for i = 1, n // 2 do
		path[i], path[n - i + 1] = path[n - i + 1], path[i]
	end
	return path
end

return AStarAbstractGraph
