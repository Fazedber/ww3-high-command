--!native
-- Port of OpenFrontIO src/core/pathfinding/algorithms/AbstractGraph.ts
-- (AbstractGraph + AbstractGraphBuilder).
--
-- The water graph used by hierarchical A*: the minimap is cut into 32x32
-- clusters; gateway nodes sit in the middle of every water span crossing a
-- cluster boundary, and nodes of one cluster are joined by edges costing the
-- BFS distance between them.
--
-- Node and edge ids are 0-based and assigned in upstream's order (edges in
-- BFS discovery order), because A* tie-breaking depends on them.
-- TODO(port): partial rebuild after water nukes (computePartialRebuildInfo).

local BFSGrid = require(script.Parent.BFSGrid)
local ConnectedComponents = require(script.Parent.ConnectedComponents)

local REJECT = BFSGrid.REJECT

-- AbstractGraph -------------------------------------------------------------------

local AbstractGraph = {}
AbstractGraph.__index = AbstractGraph

function AbstractGraph.new(clusterSize: number, clustersX: number, clustersY: number)
	return setmetatable({
		clusterSize = clusterSize,
		clustersX = clustersX,
		clustersY = clustersY,
		_nodes = {}, -- id -> node { id, x, y, tile, componentId }
		_edges = {}, -- id -> edge { id, nodeA, nodeB, cost, clusterX, clusterY }
		_nodeEdgeIds = {}, -- nodeId -> { edgeId }
		_clusters = {}, -- key -> { x, y, nodeIds }
		_pathCache = {}, -- edgeId * 2 + direction -> path
		nodeCount = 0,
		edgeCount = 0,
		_waterComponents = nil,
	}, AbstractGraph)
end

function AbstractGraph:getNode(id: number)
	return self._nodes[id]
end

function AbstractGraph:getEdge(id: number)
	return self._edges[id]
end

function AbstractGraph:getNodeEdges(nodeId: number)
	local ids = self._nodeEdgeIds[nodeId]
	if not ids then
		return {}
	end
	local out = table.create(#ids)
	for _, id in ids do
		local e = self._edges[id]
		if e then
			table.insert(out, e)
		end
	end
	return out
end

function AbstractGraph:getEdgeBetween(nodeA: number, nodeB: number)
	local ids = self._nodeEdgeIds[nodeA]
	if not ids then
		return nil
	end
	for _, id in ids do
		local edge = self._edges[id]
		if edge.nodeA == nodeB or edge.nodeB == nodeB then
			return edge
		end
	end
	return nil
end

function AbstractGraph:getOtherNode(edge, nodeId: number): number
	return if edge.nodeA == nodeId then edge.nodeB else edge.nodeA
end

-- Cached path for an edge, direction-aware (from nodeA or from nodeB).
function AbstractGraph:getCachedPath(edgeId: number, fromNodeId: number)
	local edge = self._edges[edgeId]
	if not edge then
		return nil
	end
	local direction = if fromNodeId == edge.nodeA then 0 else 1
	return self._pathCache[edgeId * 2 + direction]
end

function AbstractGraph:setCachedPath(edgeId: number, fromNodeId: number, path)
	local edge = self._edges[edgeId]
	if not edge then
		return
	end
	local direction = if fromNodeId == edge.nodeA then 0 else 1
	self._pathCache[edgeId * 2 + direction] = path
end

function AbstractGraph:setWaterComponents(wc)
	self._waterComponents = wc
end

function AbstractGraph:getComponentId(tile: number): number
	return if self._waterComponents then self._waterComponents:getComponentId(tile) else 0
end

function AbstractGraph:getComponentSize(componentId: number): number
	return if self._waterComponents then self._waterComponents:getComponentSize(componentId) else 0
end

function AbstractGraph:getClusterKey(cx: number, cy: number): number
	return cy * self.clustersX + cx
end

-- Like upstream's array lookup by key: out-of-range keys read nil, and an
-- out-of-range cx can alias a neighbouring row's cluster, exactly as in JS.
function AbstractGraph:getCluster(cx: number, cy: number)
	return self._clusters[cy * self.clustersX + cx]
end

function AbstractGraph:_addNode(node)
	self._nodes[node.id] = node
	self._nodeEdgeIds[node.id] = {}
	self.nodeCount += 1
end

function AbstractGraph:_addEdge(edge)
	self._edges[edge.id] = edge
	table.insert(self._nodeEdgeIds[edge.nodeA], edge.id)
	table.insert(self._nodeEdgeIds[edge.nodeB], edge.id)
	self.edgeCount += 1
end

-- AbstractGraphBuilder ------------------------------------------------------------

local Builder = {}
Builder.__index = Builder
Builder.CLUSTER_SIZE = 32

function Builder.new(map, clusterSize: number?, _oldGraph, _dirtyMiniTiles, sharedWaterComponents, sharedTileBFS)
	local size = clusterSize or Builder.CLUSTER_SIZE
	local w, h = map:width(), map:height()
	return setmetatable({
		map = map,
		clusterSize = size,
		width = w,
		height = h,
		clustersX = math.ceil(w / size),
		clustersY = math.ceil(h / size),
		tileBFS = sharedTileBFS or BFSGrid.new(w * h),
		sharedWaterComponents = sharedWaterComponents,
		waterComponents = sharedWaterComponents or ConnectedComponents.new(map),
		tileToNode = {},
		nextNodeId = 0,
		nextEdgeId = 0,
		edgeBetween = {},
	}, Builder)
end

function Builder:build()
	local graph = AbstractGraph.new(self.clusterSize, self.clustersX, self.clustersY)
	self.graph = graph
	if not self.sharedWaterComponents then
		self.waterComponents:initialize()
	end
	-- TODO(port): partial rebuild (clean clusters reuse old edge costs).

	for cy = 0, self.clustersY - 1 do
		for cx = 0, self.clustersX - 1 do
			graph._clusters[graph:getClusterKey(cx, cy)] = { x = cx, y = cy, nodeIds = {} }
		end
	end
	for cy = 0, self.clustersY - 1 do
		for cx = 0, self.clustersX - 1 do
			self:_processCluster(cx, cy)
		end
	end
	for cy = 0, self.clustersY - 1 do
		for cx = 0, self.clustersX - 1 do
			local cluster = graph:getCluster(cx, cy)
			if cluster and #cluster.nodeIds > 0 then
				self:_buildClusterConnections(cx, cy)
			end
		end
	end
	graph._pathCache = {}
	graph:setWaterComponents(self.waterComponents)
	return graph
end

function Builder:_getOrCreateNode(x: number, y: number)
	local tile = self.map:ref(x, y)
	local existing = self.tileToNode[tile]
	if existing then
		return existing
	end
	local node = {
		id = self.nextNodeId,
		x = x,
		y = y,
		tile = tile,
		componentId = self.waterComponents:getComponentId(tile),
	}
	self.nextNodeId += 1
	self.graph:_addNode(node)
	self.tileToNode[tile] = node
	return node
end

function Builder:_addNodeToCluster(cx: number, cy: number, node)
	local cluster = self.graph:getCluster(cx, cy)
	if not cluster then
		return
	end
	-- A corner node can be found by both edge scans.
	if not table.find(cluster.nodeIds, node.id) then
		table.insert(cluster.nodeIds, node.id)
	end
end

function Builder:_processCluster(cx: number, cy: number)
	local size = self.clusterSize
	local baseX, baseY = cx * size, cy * size
	if cx < self.clustersX - 1 then
		local edgeX = math.min(baseX + size - 1, self.width - 1)
		for _, node in self:_findNodesOnVerticalEdge(edgeX, baseY) do
			self:_addNodeToCluster(cx, cy, node)
			self:_addNodeToCluster(cx + 1, cy, node)
		end
	end
	if cy < self.clustersY - 1 then
		local edgeY = math.min(baseY + size - 1, self.height - 1)
		for _, node in self:_findNodesOnHorizontalEdge(edgeY, baseX) do
			self:_addNodeToCluster(cx, cy, node)
			self:_addNodeToCluster(cx, cy + 1, node)
		end
	end
end

function Builder:_findNodesOnVerticalEdge(x: number, baseY: number)
	local map = self.map
	local nodes = {}
	local maxY = math.min(baseY + self.clusterSize, self.height)
	local spanStart = -1
	local function tryAddNode(y: number)
		if spanStart == -1 then
			return
		end
		local midY = spanStart + (y - spanStart) // 2
		spanStart = -1
		table.insert(nodes, self:_getOrCreateNode(x, midY))
	end
	for y = baseY, maxY - 1 do
		local tile = map:ref(x, y)
		local isEntrance = map:isWater(tile) and x + 1 < map:width() and map:isWater(map:ref(x + 1, y))
		if isEntrance then
			if spanStart == -1 then
				spanStart = y
			end
		else
			tryAddNode(y)
		end
	end
	tryAddNode(maxY)
	return nodes
end

function Builder:_findNodesOnHorizontalEdge(y: number, baseX: number)
	local map = self.map
	local nodes = {}
	local maxX = math.min(baseX + self.clusterSize, self.width)
	local spanStart = -1
	local function tryAddNode(x: number)
		if spanStart == -1 then
			return
		end
		local midX = spanStart + (x - spanStart) // 2
		spanStart = -1
		table.insert(nodes, self:_getOrCreateNode(midX, y))
	end
	for x = baseX, maxX - 1 do
		local tile = map:ref(x, y)
		local isEntrance = map:isWater(tile) and y + 1 < map:height() and map:isWater(map:ref(x, y + 1))
		if isEntrance then
			if spanStart == -1 then
				spanStart = x
			end
		else
			tryAddNode(x)
		end
	end
	tryAddNode(maxX)
	return nodes
end

function Builder:_buildClusterConnections(cx: number, cy: number)
	local graph = self.graph
	local cluster = graph:getCluster(cx, cy)
	if not cluster then
		return
	end
	local nodes = {}
	for _, id in cluster.nodeIds do
		table.insert(nodes, graph:getNode(id))
	end
	local size = self.clusterSize
	local minX, minY = cx * size, cy * size
	local maxX = math.min(self.width - 1, minX + size - 1)
	local maxY = math.min(self.height - 1, minY + size - 1)

	for i = 1, #nodes do
		local fromNode = nodes[i]
		local targets = {}
		for j = i + 1, #nodes do
			if nodes[i].componentId == nodes[j].componentId then
				table.insert(targets, nodes[j])
			end
		end
		if #targets == 0 then
			continue
		end
		local reachable = self:_findAllReachableNodesInBounds(fromNode.tile, targets, minX, maxX, minY, maxY)
		for _, pair in reachable do
			self:_addOrUpdateEdge(fromNode.id, pair[1], pair[2], cx, cy)
		end
	end
end

function Builder:_addOrUpdateEdge(a: number, b: number, cost: number, cx: number, cy: number)
	local lo, hi = a, b
	if b < a then
		lo, hi = b, a
	end
	local nodeMap = self.edgeBetween[lo]
	if not nodeMap then
		nodeMap = {}
		self.edgeBetween[lo] = nodeMap
	end
	local existing = nodeMap[hi]
	if existing then
		if cost < existing.cost then
			existing.cost = cost
			existing.clusterX = cx
			existing.clusterY = cy
		end
		return
	end
	local edge = { id = self.nextEdgeId, nodeA = lo, nodeB = hi, cost = cost, clusterX = cx, clusterY = cy }
	self.nextEdgeId += 1
	nodeMap[hi] = edge
	self.graph:_addEdge(edge)
end

-- Returns { { nodeId, dist } } in BFS discovery order (upstream Map order).
function Builder:_findAllReachableNodesInBounds(from: number, targets, minX: number, maxX: number, minY: number, maxY: number)
	local map = self.map
	local W = map:width()
	local fromX, fromY = from % W, from // W
	local tileToNodeId = {}
	local maxManhattan = 0
	for _, node in targets do
		tileToNodeId[node.tile] = node.id
		maxManhattan = math.max(maxManhattan, math.abs(node.x - fromX) + math.abs(node.y - fromY))
	end
	local maxDistance = maxManhattan * 4 -- allow path deviation
	local reachable = {}
	local found = 0
	local total = #targets
	self.tileBFS:search(W, map:height(), from, maxDistance, function(tile)
		return map:isWater(tile)
	end, function(tile, dist)
		local x, y = tile % W, tile // W
		local nodeId = tileToNodeId[tile]
		local isStartOrTarget = tile == from or nodeId ~= nil
		if not isStartOrTarget and (x < minX or x > maxX or y < minY or y > maxY) then
			return REJECT
		end
		if nodeId ~= nil then
			table.insert(reachable, { nodeId, dist })
			found += 1
			if found == total then
				return dist -- stop BFS
			end
		end
		return nil
	end)
	return reachable
end

AbstractGraph.Builder = Builder
return AbstractGraph
