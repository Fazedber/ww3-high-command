-- Port of OpenFrontIO src/core/game/WaterManager.ts (navigation parts).
--
-- Owns the minimap water navigation: connected components, the abstract
-- water graph and the hierarchical A* built on it, plus component lookups
-- used when choosing where boats can launch / land.
-- TODO(port): water nukes — queued land->water conversion, terrain fixup
-- (ocean bit, magnitude, shoreline, minimap) and throttled graph rebuilds.

local AbstractGraph = require(script.Parent.AbstractGraph)
local AStarWaterHierarchical = require(script.Parent.AStarWaterHierarchical)
local BFSGrid = require(script.Parent.BFSGrid)
local ConnectedComponents = require(script.Parent.ConnectedComponents)

local WaterManager = {}
WaterManager.__index = WaterManager

function WaterManager.new(map, miniMap, disableNavMesh: boolean)
	local self = setmetatable({
		map = map,
		miniMap = miniMap,
		disableNavMesh = disableNavMesh,
		_graph = nil,
		_hpa = nil,
		_cc = nil,
		_bfs = nil,
		_version = 0,
	}, WaterManager)
	if not disableNavMesh then
		self._cc = ConnectedComponents.new(miniMap)
		self._cc:initialize()
		self._bfs = BFSGrid.new(miniMap:width() * miniMap:height())
		local builder = AbstractGraph.Builder.new(miniMap, AbstractGraph.Builder.CLUSTER_SIZE, nil, nil, self._cc, self._bfs)
		self._graph = builder:build()
		self._hpa = AStarWaterHierarchical.new(miniMap, self._graph, { cachePaths = true })
	end
	return self
end

-- Returns tiles whose terrain changed this tick (none until water nukes).
function WaterManager:tick(_currentTick: number): { number }
	return {}
end

function WaterManager:queueTile(_tile: number)
	error("TODO(port): water nukes")
end

function WaterManager:waterGraphVersion(): number
	return self._version
end

function WaterManager:miniWaterHPA()
	return self._hpa
end

function WaterManager:miniWaterGraph()
	return self._graph
end

function WaterManager:_miniTileOf(tile: number): number
	return self.miniMap:ref(self.map:x(tile) // 2, self.map:y(tile) // 2)
end

function WaterManager:getWaterComponent(tile: number): number?
	local graph = self._graph
	if not graph then
		return 0 -- permissive fallback with disableNavMesh
	end
	local mini = self.miniMap
	local miniTile = self:_miniTileOf(tile)
	if mini:isWater(miniTile) then
		return graph:getComponentId(miniTile)
	end
	-- Shore tile: find a water neighbour (minimap resolution loss).
	for _, n in mini:neighbors(miniTile) do
		if mini:isWater(n) then
			return graph:getComponentId(n)
		end
	end
	-- 2-hop neighbours for narrow straits.
	for _, n in mini:neighbors(miniTile) do
		for _, n2 in mini:neighbors(n) do
			if mini:isWater(n2) then
				return graph:getComponentId(n2)
			end
		end
	end
	return nil
end

function WaterManager:hasWaterComponent(tile: number, component: number): boolean
	local graph = self._graph
	if not graph then
		return true
	end
	local mini = self.miniMap
	local miniTile = self:_miniTileOf(tile)
	if mini:isWater(miniTile) and graph:getComponentId(miniTile) == component then
		return true
	end
	for _, n in mini:neighbors(miniTile) do
		if mini:isWater(n) and graph:getComponentId(n) == component then
			return true
		end
	end
	for _, n in mini:neighbors(miniTile) do
		for _, n2 in mini:neighbors(n) do
			if mini:isWater(n2) and graph:getComponentId(n2) == component then
				return true
			end
		end
	end
	return false
end

-- Approximate full-map water tiles in the component containing `tile`.
function WaterManager:getWaterComponentSize(tile: number): number?
	local id = self:getWaterComponent(tile)
	if id == nil then
		return nil
	end
	if not self._graph then
		return 0
	end
	return self._graph:getComponentSize(id) * 4
end

return WaterManager
