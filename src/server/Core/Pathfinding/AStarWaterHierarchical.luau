--!native
-- Port of OpenFrontIO src/core/pathfinding/algorithms/AStar.WaterHierarchical.ts.
--
-- Hierarchical water A* on the minimap: short hops use a bounded local A*;
-- long routes go start -> nearest gateway -> abstract graph -> gateway ->
-- goal, with per-edge segment paths cached on the graph.

local AStarAbstractGraph = require(script.Parent.AStarAbstractGraph)
local AStarWaterBounded = require(script.Parent.AStarWaterBounded)
local BFSGrid = require(script.Parent.BFSGrid)

local REJECT = BFSGrid.REJECT

-- SourceResolver: tiles -> abstract nodes (closest node in the tile's cluster).
local SourceResolver = {}
SourceResolver.__index = SourceResolver

function SourceResolver.new(map, graph)
	return setmetatable({ map = map, graph = graph }, SourceResolver)
end

function SourceResolver:_getClusterNode(tile: number)
	local map, graph = self.map, self.graph
	local x, y = map:x(tile), map:y(tile)
	local cluster = graph:getCluster(x // graph.clusterSize, y // graph.clusterSize)
	if not cluster or #cluster.nodeIds == 0 then
		return nil
	end
	local best, bestDist = nil, math.huge
	for _, id in cluster.nodeIds do
		local node = graph:getNode(id)
		if node then
			local d = math.abs(node.x - x) + math.abs(node.y - y)
			if d < bestDist then
				bestDist = d
				best = node
			end
		end
	end
	return best
end

function SourceResolver:resolveTarget(target: number)
	return self:_getClusterNode(target)
end

-- Returns ordered { nodeIds = {...}, source = { [nodeId] = tile } }, keeping
-- the closest source per node and upstream Map insertion order.
function SourceResolver:resolveSourcesToNodes(sources: { number })
	local order, source, dists = {}, {}, {}
	for _, s in sources do
		local node = self:_getClusterNode(s)
		if node == nil then
			continue
		end
		local d = math.abs(node.x - self.map:x(s)) + math.abs(node.y - self.map:y(s))
		local prev = dists[node.id]
		if prev == nil or d < prev then
			if prev == nil then
				table.insert(order, node.id)
			end
			source[node.id] = s
			dists[node.id] = d
		end
	end
	return order, source
end

local AStarWaterHierarchical = {}
AStarWaterHierarchical.__index = AStarWaterHierarchical

function AStarWaterHierarchical.new(map, graph, options)
	local clusterSize = graph.clusterSize
	local multi = clusterSize * 3
	local shortPathSize = 260 -- 2 * (120 + padding 10)
	return setmetatable({
		map = map,
		graph = graph,
		options = options or {},
		tileBFS = BFSGrid.new(map:width() * map:height()),
		abstractAStar = AStarAbstractGraph.new(graph),
		localAStar = AStarWaterBounded.new(map, clusterSize * clusterSize),
		localAStarMultiCluster = AStarWaterBounded.new(map, multi * multi),
		localAStarShortPath = AStarWaterBounded.new(map, shortPathSize * shortPathSize),
		sourceResolver = SourceResolver.new(map, graph),
	}, AStarWaterHierarchical)
end

-- Swap in a rebuilt graph, keeping the map-sized scratch buffers.
function AStarWaterHierarchical:setGraph(graph)
	self.graph = graph
	self.abstractAStar = AStarAbstractGraph.new(graph)
	self.sourceResolver = SourceResolver.new(self.map, graph)
end

function AStarWaterHierarchical:findPath(from, to: number)
	if type(from) == "table" then
		return self:_findPathMultiSource(from, to)
	end
	return self:findPathSingle(from, to)
end

function AStarWaterHierarchical:_findPathMultiSource(sources: { number }, target: number)
	local shortPath = self:_tryShortPathMultiSource(sources, target)
	if shortPath then
		return shortPath
	end
	local targetNode = self.sourceResolver:resolveTarget(target)
	if not targetNode then
		return nil
	end
	local nodeIds, nodeToSource = self.sourceResolver:resolveSourcesToNodes(sources)
	if #nodeIds == 0 then
		return nil
	end
	local nodePath = self.abstractAStar:findPath(nodeIds, targetNode.id)
	if not nodePath then
		return nil
	end
	return self:findPathSingle(nodeToSource[nodePath[1]], target)
end

function AStarWaterHierarchical:_tryShortPathMultiSource(sources: { number }, target: number)
	local SHORT_PATH_THRESHOLD = 120
	local PADDING = 10
	local map = self.map
	local candidates = {}
	for _, s in sources do
		if map:manhattanDist(s, target) <= SHORT_PATH_THRESHOLD then
			table.insert(candidates, s)
		end
	end
	if #candidates == 0 then
		return nil
	end
	local toX, toY = map:x(target), map:y(target)
	local minX, maxX, minY, maxY = toX, toX, toY, toY
	for _, s in candidates do
		local sx, sy = map:x(s), map:y(s)
		minX = math.min(minX, sx)
		maxX = math.max(maxX, sx)
		minY = math.min(minY, sy)
		maxY = math.max(maxY, sy)
	end
	return self.localAStarShortPath:searchBounded(candidates, target, {
		minX = math.max(0, minX - PADDING),
		maxX = math.min(map:width() - 1, maxX + PADDING),
		minY = math.max(0, minY - PADDING),
		maxY = math.min(map:height() - 1, maxY + PADDING),
	})
end

local function appendFrom(dst: { number }, src: { number }, fromIndex: number)
	for i = fromIndex, #src do
		table.insert(dst, src[i])
	end
end

function AStarWaterHierarchical:findPathSingle(from: number, to: number)
	local map, graph = self.map, self.graph
	local clusterSize = graph.clusterSize

	-- Early exit for very short distances
	if map:manhattanDist(from, to) <= clusterSize then
		local localPath = self:_findLocalPath(from, to, map:x(from) // clusterSize, map:y(from) // clusterSize, true)
		if localPath then
			return localPath
		end
	end

	local startNode = self:_findNearestNode(from)
	local endNode = self:_findNearestNode(to)
	if not startNode or not endNode then
		return nil
	end

	if startNode.id == endNode.id then
		return self:_findLocalPath(from, to, startNode.x // clusterSize, startNode.y // clusterSize, true)
	end

	local nodePath = self.abstractAStar:findPath(startNode.id, endNode.id)
	if not nodePath then
		return nil
	end

	local initialPath = {}

	-- 1. start -> first node
	local firstNode = graph:getNode(nodePath[1])
	local startSegment = self:_findLocalPath(from, firstNode.tile, map:x(from) // clusterSize, map:y(from) // clusterSize)
	if not startSegment then
		return nil
	end
	appendFrom(initialPath, startSegment, 1)

	-- 2. through abstract nodes
	for i = 1, #nodePath - 1 do
		local fromNodeId, toNodeId = nodePath[i], nodePath[i + 1]
		local edge = graph:getEdgeBetween(fromNodeId, toNodeId)
		if not edge then
			return nil
		end
		if self.options.cachePaths then
			local cached = graph:getCachedPath(edge.id, fromNodeId)
			if cached and #cached > 0 then
				appendFrom(initialPath, cached, 2)
				continue
			end
		end
		local segment = self:_findLocalPath(graph:getNode(fromNodeId).tile, graph:getNode(toNodeId).tile, edge.clusterX, edge.clusterY)
		if not segment then
			return nil
		end
		appendFrom(initialPath, segment, 2)
		if self.options.cachePaths then
			graph:setCachedPath(edge.id, fromNodeId, segment)
		end
	end

	-- 3. last node -> end
	local lastNode = graph:getNode(nodePath[#nodePath])
	local endSegment = self:_findLocalPath(lastNode.tile, to, map:x(to) // clusterSize, map:y(to) // clusterSize)
	if not endSegment then
		return nil
	end
	appendFrom(initialPath, endSegment, 2)
	return initialPath
end

function AStarWaterHierarchical:_findNearestNode(tile: number)
	local map, graph = self.map, self.graph
	local clusterSize = graph.clusterSize
	local x, y = map:x(tile), map:y(tile)
	local cx, cy = x // clusterSize, y // clusterSize
	local minX, minY = cx * clusterSize, cy * clusterSize
	local maxX = math.min(map:width() - 1, minX + clusterSize - 1)
	local maxY = math.min(map:height() - 1, minY + clusterSize - 1)
	local cluster = graph:getCluster(cx, cy)
	if not cluster or #cluster.nodeIds == 0 then
		return nil
	end
	local candidates = {}
	for _, id in cluster.nodeIds do
		table.insert(candidates, graph:getNode(id))
	end
	local W = map:width()
	return self.tileBFS:search(W, map:height(), tile, clusterSize * clusterSize, function(t)
		return map:isWater(t)
	end, function(t, _dist)
		local tx, ty = t % W, t // W
		for _, node in candidates do
			if node.x == tx and node.y == ty then
				return node
			end
		end
		if tx < minX or tx > maxX or ty < minY or ty > maxY then
			return REJECT
		end
		return nil
	end)
end

function AStarWaterHierarchical:_findLocalPath(from: number, to: number, cx: number, cy: number, multiCluster: boolean?)
	local map = self.map
	local clusterSize = self.graph.clusterSize
	local minX, minY, maxX, maxY
	if multiCluster then
		-- 3x3 clusters centred on the starting cluster
		minX = math.max(0, (cx - 1) * clusterSize)
		minY = math.max(0, (cy - 1) * clusterSize)
		maxX = math.min(map:width() - 1, (cx + 2) * clusterSize - 1)
		maxY = math.min(map:height() - 1, (cy + 2) * clusterSize - 1)
	else
		minX = cx * clusterSize
		minY = cy * clusterSize
		maxX = math.min(map:width() - 1, minX + clusterSize - 1)
		maxY = math.min(map:height() - 1, minY + clusterSize - 1)
	end
	local astar = if multiCluster then self.localAStarMultiCluster else self.localAStar
	local path = astar:searchBounded(from, to, { minX = minX, maxX = maxX, minY = minY, maxY = maxY })
	if not path or #path == 0 then
		return nil
	end
	-- Node tiles may sit just outside cluster bounds: pin exact endpoints.
	if path[1] ~= from then
		table.insert(path, 1, from)
	end
	if path[#path] ~= to then
		table.insert(path, to)
	end
	return path
end

return AStarWaterHierarchical
