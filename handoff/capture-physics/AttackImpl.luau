-- Port of OpenFrontIO src/core/game/AttackImpl.ts.

local Shared = game:GetService("ReplicatedStorage").Shared
local JSSet = require(Shared.JSSet)
local Util = require(Shared.Util)

local AttackImpl = {}
AttackImpl.__index = AttackImpl

function AttackImpl.new(id: string, target, attacker, troops: number, sourceTile: number?, border, mg)
	return setmetatable({
		_id = id,
		_target = target,
		_attacker = attacker,
		_troops = troops,
		_sourceTile = sourceTile,
		_border = border or JSSet.new(),
		_mg = mg,
		_isActive = true,
		_borderSize = 0,
		_retreating = false,
		_retreated = false,
	}, AttackImpl)
end

function AttackImpl:sourceTile(): number?
	return self._sourceTile
end
function AttackImpl:target()
	return self._target
end
function AttackImpl:attacker()
	return self._attacker
end
function AttackImpl:troops(): number
	return self._troops
end
function AttackImpl:setTroops(troops: number)
	self._troops = math.max(0, troops)
end
function AttackImpl:isActive(): boolean
	return self._isActive
end
function AttackImpl:id(): string
	return self._id
end

local function without(list, item)
	local out = {}
	for _, v in list do
		if v ~= item then
			table.insert(out, v)
		end
	end
	return out
end

function AttackImpl:delete()
	if self._target:isPlayer() then
		self._target._incomingAttacks = without(self._target._incomingAttacks, self)
	end
	self._attacker._outgoingAttacks = without(self._attacker._outgoingAttacks, self)
	self._isActive = false
end

function AttackImpl:orderRetreat()
	self._retreating = true
end
function AttackImpl:executeRetreat()
	self._retreated = true
end
function AttackImpl:retreating(): boolean
	return self._retreating
end
function AttackImpl:retreated(): boolean
	return self._retreated
end

function AttackImpl:borderSize(): number
	return self._borderSize
end

function AttackImpl:clearBorder()
	self._borderSize = 0
	self._border:clear()
end

function AttackImpl:addBorderTile(tile: number)
	if not self._border:has(tile) then
		self._borderSize += 1
		self._border:add(tile)
	end
end

function AttackImpl:removeBorderTile(tile: number)
	if self._border:has(tile) then
		self._borderSize -= 1
		self._border:delete(tile)
	end
end

-- Top 2 clustered positions of the attack's border (for troop labels).
-- If the second cluster is too small, only the largest one is returned.
function AttackImpl:clusteredPositions(): { number }
	if self._borderSize == 0 then
		local tile = self:sourceTile()
		return if tile ~= nil then { tile } else {}
	end
	return self:_clusterBorderTiles(30, 2)
end

function AttackImpl:_clusterBorderTiles(minSize: number, maxClusters: number): { number }
	local map = self._mg:map()
	local border = self._border
	local visited = {}
	local clusters = {}

	for startTile in border do
		if visited[startTile] then
			continue
		end
		local queue = { startTile }
		visited[startTile] = true
		local qi = 1
		local sumX, sumY, count = 0, 0, 0

		while qi <= #queue do
			local t = queue[qi]
			qi += 1
			sumX += map:x(t)
			sumY += map:y(t)
			count += 1
			map:forEachNeighborWithDiag(t, function(neighbor)
				if border:has(neighbor) and not visited[neighbor] then
					visited[neighbor] = true
					table.insert(queue, neighbor)
				end
			end)
		end

		-- Pick the real border tile closest to the centroid.
		local cx, cy = sumX / count, sumY / count
		local best, bestDist = queue[1], math.huge
		for _, t in queue do
			local dx = map:x(t) - cx
			local dy = map:y(t) - cy
			local dist = dx * dx + dy * dy
			if dist < bestDist then
				bestDist = dist
				best = t
			end
		end
		table.insert(clusters, { tile = best, size = count })
	end

	Util.sort(clusters, function(a, b)
		return b.size - a.size
	end)

	if #clusters == 0 then
		return {}
	elseif #clusters == 1 then
		return { clusters[1].tile }
	end
	local out = {}
	for _, c in clusters do
		if c.size >= minSize and #out < maxClusters then
			table.insert(out, c.tile)
		end
	end
	if #out == 0 then
		-- Always keep at least the largest cluster even if below minSize.
		return { clusters[1].tile }
	end
	return out
end

return AttackImpl
