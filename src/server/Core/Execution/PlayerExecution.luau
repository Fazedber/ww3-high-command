--!native
-- Port of OpenFrontIO src/core/execution/PlayerExecution.ts.
--
-- Per player, every tick: troop & gold growth, alliance / embargo expiry,
-- structure capture, and (every ~20 ticks) cluster analysis that hands a
-- fully surrounded enclave to the player surrounding it.
--
-- Porting note: upstream packs cluster bounding boxes into a flat Int32Array;
-- here each cluster's box is a { minX, minY, maxX, maxY } table. Same values.

local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local PlayerImpl = require(Core.PlayerImpl)
local Scratch = require(Core.TileTraversalScratch)
local ExecUtil = require(script.Parent.ExecUtil)
local Util = require(game:GetService("ReplicatedStorage").Shared.Util)

local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType
local Structures = GameTypes.Structures
local OrderedMap = PlayerImpl.OrderedMap

local readu32, writeu32 = buffer.readu32, buffer.writeu32
local readi32, writei32 = buffer.readi32, buffer.writei32

local PlayerExecution = {}
PlayerExecution.__index = PlayerExecution

local TICKS_PER_CLUSTER_CALC = 20

function PlayerExecution.new(player)
	return setmetatable({
		player = player,
		_lastCalc = 0,
		_active = true,
		_nbuf = { 0, 0, 0, 0 },
		_nbuf8 = { 0, 0, 0, 0, 0, 0, 0, 0 },
	}, PlayerExecution)
end

function PlayerExecution:activeDuringSpawnPhase(): boolean
	return false
end

function PlayerExecution:init(mg, ticks: number)
	self.mg = mg
	self.map = mg:map()
	self.config = mg:config()
	self._lastCalc = ticks + (Util.simpleHash(self.player:id()) % TICKS_PER_CLUSTER_CALC)
end

function PlayerExecution:tick(ticks: number)
	local player = self.player
	local mg = self.mg
	player:decayRelations()
	for _, u in player:units() do
		if not Structures.has(u:type()) then
			continue
		end
		local owner = mg:owner(u:tile())
		if not owner:isPlayer() then
			u:delete()
			continue
		end
		if owner == player then
			continue
		end
		local captor = mg:player(owner:id())
		if u:type() == UnitType.DefensePost then
			u:delete(true, captor)
		else
			captor:captureUnit(u)
		end
	end

	if not player:isAlive() then
		self:_removeOnDeath()
		self._active = false
		local stillStanding = 0
		for _, p in mg:players() do
			if p:type() ~= PlayerType.Bot then
				stillStanding += 1
			end
		end
		mg:stats():recordDeathPosition(player, stillStanding + 1)
		mg:stats():playerKilled(player, ticks)
		return
	end

	local troopInc = self.config:troopIncreaseRate(player)
	player:addTroops(troopInc)
	local goldFromWorkers = self.config:goldAdditionRate(player)
	player:addGold(goldFromWorkers)
	mg:stats():goldWork(player, goldFromWorkers)

	for _, alliance in player:alliances() do
		if alliance:expiresAt() <= mg:ticks() then
			alliance:expire()
		end
	end

	for _, embargo in player:getEmbargoes() do
		if embargo.isTemporary and mg:ticks() - embargo.createdAt > self.config:temporaryEmbargoDuration() then
			player:stopEmbargo(embargo.target)
		end
	end

	if ticks - self._lastCalc > TICKS_PER_CLUSTER_CALC or player:numTilesOwned() < 100 then
		if player:lastTileChange() >= self._lastCalc then
			self._lastCalc = ticks
			self:_removeClusters()
		end
	end
end

function PlayerExecution:_state()
	return Scratch.get(self.mg)
end

function PlayerExecution:_bump(): number
	return Scratch.bump(self:_state())
end

function PlayerExecution:_removeClusters()
	local clusters, boxes = self:_calculateClusters()
	local player = self.player

	if #clusters == 0 then
		player.largestClusterBoundingBox = nil
		return
	end

	if #clusters == 1 then
		local b = boxes[1]
		player.largestClusterBoundingBox = { min = { x = b[1], y = b[2] }, max = { x = b[3], y = b[4] } }
		local surroundedBy = self:_surroundedBySamePlayer(clusters[1], b)
		if surroundedBy and not surroundedBy:isFriendly(player) then
			self:_removeCluster(clusters[1])
		end
		return
	end

	local largestIndex = 1
	for i = 2, #clusters do
		if #clusters[i] > #clusters[largestIndex] then
			largestIndex = i
		end
	end

	local t = boxes[largestIndex]
	-- A cluster is a "hole" if it is enclosed by another cluster of the SAME
	-- contiguous territory (doughnut borders); bbox containment alone is
	-- insufficient, so containment candidates are confirmed by a flood fill.
	local clusterTerritoryIds: { number }? = nil
	local nextTerritoryId = 1
	local state = self:_state()

	local isLargestHole = false
	for j = 1, #clusters do
		if j ~= largestIndex then
			local bj = boxes[j]
			if bj[1] <= t[1] and bj[2] <= t[2] and bj[3] >= t[3] and bj[4] >= t[4] then
				if not clusterTerritoryIds then
					clusterTerritoryIds = table.create(#clusters, 0)
					for c = 1, #clusters do
						for _, tile in clusters[c] do
							writei32(state.clusterIndexMap, tile * 4, c)
						end
					end
				end
				nextTerritoryId = self:_checkAndAssignTerritory(clusters, largestIndex, j, clusterTerritoryIds, nextTerritoryId)
				if clusterTerritoryIds[largestIndex] == clusterTerritoryIds[j] then
					isLargestHole = true
					break
				end
			end
		end
	end

	if isLargestHole then
		local ids = clusterTerritoryIds :: { number }
		local bestIndex, bestLength = -1, -1
		for i = 1, #clusters do
			if i == largestIndex or #clusters[i] <= bestLength then
				continue
			end
			local isHole = false
			local bi = boxes[i]
			for j = 1, #clusters do
				if j ~= i then
					local bj = boxes[j]
					if bj[1] <= bi[1] and bj[2] <= bi[2] and bj[3] >= bi[3] and bj[4] >= bi[4] then
						nextTerritoryId = self:_checkAndAssignTerritory(clusters, i, j, ids, nextTerritoryId)
						if ids[i] == ids[j] then
							isHole = true
							break
						end
					end
				end
			end
			if not isHole then
				bestLength = #clusters[i]
				bestIndex = i
			end
		end
		if bestIndex ~= -1 then
			largestIndex = bestIndex
		end
	end

	if clusterTerritoryIds then
		for c = 1, #clusters do
			for _, tile in clusters[c] do
				writei32(state.clusterIndexMap, tile * 4, 0)
			end
		end
	end

	local largestCluster = clusters[largestIndex]
	local lb = boxes[largestIndex]
	player.largestClusterBoundingBox = { min = { x = lb[1], y = lb[2] }, max = { x = lb[3], y = lb[4] } }

	local surroundedBy = self:_surroundedBySamePlayer(largestCluster, lb)
	if surroundedBy and not surroundedBy:isFriendly(player) then
		self:_removeCluster(largestCluster)
	end

	for i = 1, #clusters do
		if i == largestIndex then
			continue
		end
		if self:_isSurrounded(clusters[i], boxes[i]) then
			self:_removeCluster(clusters[i])
		end
	end
end

-- Cluster indices are 1-based here; clusterIndexMap stores index (0 = none),
-- matching upstream's stored `c + 1`.
function PlayerExecution:_checkAndAssignTerritory(clusters, cIdxA: number, cIdxB: number, ids: { number }, nextTerritoryId: number): number
	if ids[cIdxA] ~= 0 and ids[cIdxA] == ids[cIdxB] then
		return nextTerritoryId
	end
	if ids[cIdxA] ~= 0 and ids[cIdxB] ~= 0 then
		return nextTerritoryId
	end

	local startIdx = if ids[cIdxB] == 0 then cIdxB else cIdxA
	local territoryId = nextTerritoryId
	nextTerritoryId += 1

	local state = self:_state()
	local visited = state.visited
	local floodGen = self:_bump()
	local stack = state.stack
	table.clear(stack)

	local start = clusters[startIdx][1]
	writeu32(visited, start * 4, floodGen)
	table.insert(stack, start)

	local map = self.map
	local myOwner = self.player:smallID()
	local nbuf8 = self._nbuf8
	ids[startIdx] = territoryId

	while #stack > 0 do
		local tile = table.remove(stack) :: number
		local numNeighbors = map:neighbors8(tile, nbuf8)
		for nIdx = 1, numNeighbors do
			local n = nbuf8[nIdx]
			if readu32(visited, n * 4) == floodGen then
				continue
			end
			if map:ownerID(n) == myOwner then
				writeu32(visited, n * 4, floodGen)
				table.insert(stack, n)
				local cIdx = readi32(state.clusterIndexMap, n * 4)
				if cIdx > 0 then
					ids[cIdx] = territoryId
				end
			end
		end
	end
	return nextTerritoryId
end

-- Returns the single enemy surrounding the cluster (and enclosing its box),
-- or false.
function PlayerExecution:_surroundedBySamePlayer(cluster: { number }, box: { number })
	local enemyId: number? = nil
	local enemyCount = 0
	local minX, minY, maxX, maxY = 1e9, 1e9, -1e9, -1e9
	local map = self.map
	local mySmallID = self.player:smallID()
	local nbuf = self._nbuf
	for _, tile in cluster do
		if map:isOceanShore(tile) or map:isOnEdgeOfMap(tile) then
			return false
		end
		local numNeighbors = map:neighbors4(tile, nbuf)
		for i = 1, numNeighbors do
			local n = nbuf[i]
			local ownerId = map:ownerID(n)
			if ownerId == 0 then
				return false -- unowned neighbor: not fully surrounded
			end
			if ownerId ~= mySmallID then
				if enemyId == nil then
					enemyId = ownerId
					enemyCount = 1
				elseif ownerId ~= enemyId then
					enemyCount = 2
				end
				local px, py = map:x(n), map:y(n)
				if px < minX then
					minX = px
				end
				if py < minY then
					minY = py
				end
				if px > maxX then
					maxX = px
				end
				if py > maxY then
					maxY = py
				end
			end
		end
		if enemyCount ~= 1 then
			return false
		end
	end
	if enemyCount ~= 1 then
		return false
	end
	local enemy = self.mg:playerBySmallID(enemyId :: number)
	if minX <= box[1] and minY <= box[2] and maxX >= box[3] and maxY >= box[4] then
		return enemy
	end
	return false
end

function PlayerExecution:_isSurrounded(cluster: { number }, box: { number }): boolean
	local hasEnemy = false
	local minX, minY, maxX, maxY = 1e9, 1e9, -1e9, -1e9
	local map = self.map
	local mySmallID = self.player:smallID()
	local nbuf = self._nbuf
	for _, tr in cluster do
		if map:isShore(tr) or map:isOnEdgeOfMap(tr) then
			return false
		end
		local numNeighbors = map:neighbors4(tr, nbuf)
		for i = 1, numNeighbors do
			local n = nbuf[i]
			local ownerId = map:ownerID(n)
			if ownerId ~= 0 and ownerId ~= mySmallID then
				hasEnemy = true
				local x, y = map:x(n), map:y(n)
				if x < minX then
					minX = x
				end
				if y < minY then
					minY = y
				end
				if x > maxX then
					maxX = x
				end
				if y > maxY then
					maxY = y
				end
			end
		end
	end
	if not hasEnemy then
		return false
	end
	return minX <= box[1] and minY <= box[2] and maxX >= box[3] and maxY >= box[4]
end

function PlayerExecution:_removeCluster(cluster: { number })
	local mg = self.mg
	local mySmallID = self.player:smallID()
	for _, t in cluster do
		if mg:ownerID(t) ~= mySmallID then
			-- Other removeCluster operations could change tile owners.
			return
		end
	end

	local capturing = self:_getCapturingPlayer(cluster)
	if capturing == nil then
		return
	end

	local firstTile = cluster[1]
	if firstTile == nil then
		return
	end

	-- Verify the land actually changing hands is sealed in (a border cluster
	-- can wrap a hole in the middle of a wide open empire).
	if not self:_isEnclosed(firstTile) then
		return
	end

	local tiles = self:_floodFillWithGen(self:_bump(), self:_state().visited, { firstTile }, false, function(tile)
		return mg:ownerID(tile) == mySmallID
	end)

	if self.player:numTilesOwned() == #tiles then
		mg:conquerPlayer(capturing, self.player)
	end

	for _, tile in tiles do
		capturing:conquer(tile)
	end
end

-- Whether the territory reachable from `start` (own tiles + unclaimed land)
-- can never reach water or the map edge — i.e. is walled in by other players.
function PlayerExecution:_isEnclosed(start: number): boolean
	local map = self.map
	local mySmallID = self.player:smallID()
	local state = self:_state()
	local gen = Scratch.bump(state)
	local visited = state.visited
	local stack = state.stack
	local nbuf = self._nbuf
	table.clear(stack)
	writeu32(visited, start * 4, gen)
	table.insert(stack, start)

	while #stack > 0 do
		local tile = table.remove(stack) :: number
		if map:isOnEdgeOfMap(tile) then
			return false
		end
		local numNeighbors = map:neighbors4(tile, nbuf)
		for i = 1, numNeighbors do
			local n = nbuf[i]
			if readu32(visited, n * 4) == gen then
				continue
			end
			local ownerId = map:ownerID(n)
			if ownerId ~= 0 and ownerId ~= mySmallID then
				continue -- someone else's tile: part of the wall
			end
			if ownerId == 0 and not map:isLand(n) then
				return false -- open water is a way out
			end
			writeu32(visited, n * 4, gen)
			table.insert(stack, n)
		end
	end
	return true
end

function PlayerExecution:_getCapturingPlayer(cluster: { number })
	local neighbors = OrderedMap.new()
	local map = self.map
	local mySmallID = self.player:smallID()
	local nbuf = self._nbuf
	for _, t in cluster do
		local numNeighbors = map:neighbors4(t, nbuf)
		for i = 1, numNeighbors do
			local ownerId = map:ownerID(nbuf[i])
			if ownerId == 0 or ownerId == mySmallID then
				continue
			end
			local owner = self.mg:playerBySmallID(ownerId)
			if not owner:isFriendly(self.player) then
				neighbors:set(owner, (neighbors:get(owner) or 0) + 1)
			end
		end
	end

	if neighbors:size() == 0 then
		return nil
	end

	-- Prefer the neighbor with the largest attack on us.
	local largestNeighborAttack = nil
	local largestTroopCount = 0
	for neighbor in neighbors:entries() do
		for _, attack in neighbor:outgoingAttacks() do
			if attack:target() == self.player and attack:troops() > largestTroopCount then
				largestTroopCount = attack:troops()
				largestNeighborAttack = neighbor
			end
		end
	end
	if largestNeighborAttack ~= nil then
		return largestNeighborAttack
	end

	-- No ongoing attacks: the enemy with the largest border.
	return ExecUtil.getMode(neighbors)
end

function PlayerExecution:_calculateClusters(): ({ { number } }, { { number } })
	local borderTiles = self.player:borderTiles()
	if borderTiles:size() == 0 then
		return {}, {}
	end
	local state = self:_state()
	local visited = state.visited
	-- Stamp every border tile with borderGen, then flood with currentGen.
	local borderGen = self:_bump()
	for tile in borderTiles do
		writeu32(visited, tile * 4, borderGen)
	end
	local currentGen = self:_bump()

	local clusters, boxes = {}, {}
	local function includeFn(tile: number): boolean
		return readu32(visited, tile * 4) == borderGen
	end
	for startTile in borderTiles do
		if readu32(visited, startTile * 4) == currentGen then
			continue
		end
		local box = { 0, 0, 0, 0 }
		local cluster = self:_floodFillWithGen(currentGen, visited, { startTile }, true, includeFn, box)
		table.insert(clusters, cluster)
		table.insert(boxes, box)
	end
	return clusters, boxes
end

-- DFS from startTiles over tiles accepted by includeFn, stamping `visited`
-- with currentGen. Returns tiles in mark order; fills outBox if given.
function PlayerExecution:_floodFillWithGen(
	currentGen: number,
	visited: buffer,
	startTiles: { number },
	diag: boolean,
	includeFn: (number) -> boolean,
	outBox: { number }?
): { number }
	local result = {}
	local stack = self:_state().stack
	table.clear(stack)
	local minX, minY, maxX, maxY = 1e9, 1e9, -1e9, -1e9
	local map = self.map

	for _, start in startTiles do
		if readu32(visited, start * 4) == currentGen then
			continue
		end
		if not includeFn(start) then
			continue
		end
		writeu32(visited, start * 4, currentGen)
		table.insert(result, start)
		table.insert(stack, start)
		if outBox then
			local x, y = map:x(start), map:y(start)
			if x < minX then
				minX = x
			end
			if y < minY then
				minY = y
			end
			if x > maxX then
				maxX = x
			end
			if y > maxY then
				maxY = y
			end
		end
	end

	local nbuf = if diag then self._nbuf8 else self._nbuf
	while #stack > 0 do
		local tile = table.remove(stack) :: number
		local numNeighbors = if diag then map:neighbors8(tile, nbuf) else map:neighbors4(tile, nbuf)
		for i = 1, numNeighbors do
			local neighbor = nbuf[i]
			if readu32(visited, neighbor * 4) == currentGen then
				continue
			end
			if not includeFn(neighbor) then
				continue
			end
			writeu32(visited, neighbor * 4, currentGen)
			table.insert(result, neighbor)
			table.insert(stack, neighbor)
			if outBox then
				local x, y = map:x(neighbor), map:y(neighbor)
				if x < minX then
					minX = x
				end
				if y < minY then
					minY = y
				end
				if x > maxX then
					maxX = x
				end
				if y > maxY then
					maxY = y
				end
			end
		end
	end

	if outBox then
		outBox[1], outBox[2], outBox[3], outBox[4] = minX, minY, maxX, maxY
	end
	return result
end

function PlayerExecution:_removeOnDeath()
	-- Delete remaining gold, non-nuke units and alliances.
	local player = self.player
	player:removeGold(player:gold())
	for _, u in table.clone(player:units()) do
		local t = u:type()
		if t ~= UnitType.AtomBomb and t ~= UnitType.HydrogenBomb and t ~= UnitType.MIRVWarhead and t ~= UnitType.MIRV then
			u:delete()
		end
	end
	player:removeAllAlliances()
end

function PlayerExecution:owner()
	return self.player
end

function PlayerExecution:isActive(): boolean
	return self._active
end

return PlayerExecution
