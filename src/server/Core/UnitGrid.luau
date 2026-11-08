--!native
-- Port of OpenFrontIO src/core/game/UnitGrid.ts.
-- Spatial hash of units in 100x100 cells, one insertion-ordered set per unit
-- type per cell (JS Set order matters for nearbyUnits results).

local JSSet = require(game:GetService("ReplicatedStorage").Shared.JSSet)

local UnitGrid = {}
UnitGrid.__index = UnitGrid

local CELL = 100

function UnitGrid.new(gm)
	local rows = math.ceil(gm:height() / CELL)
	local cols = math.ceil(gm:width() / CELL)
	local grid = table.create(rows)
	for y = 1, rows do
		local row = table.create(cols)
		for x = 1, cols do
			row[x] = {} -- unitType -> JSSet
		end
		grid[y] = row
	end
	return setmetatable({ gm = gm, grid = grid, rows = rows, cols = cols }, UnitGrid)
end

function UnitGrid:_cell(gx: number, gy: number)
	if gx >= 0 and gx < self.cols and gy >= 0 and gy < self.rows then
		return self.grid[gy + 1][gx + 1]
	end
	return nil
end

function UnitGrid:addUnit(unit)
	local tile = unit:tile()
	local cell = self:_cell(self.gm:x(tile) // CELL, self.gm:y(tile) // CELL)
	if cell then
		local set = cell[unit:type()]
		if set then
			set:add(unit)
		else
			cell[unit:type()] = JSSet.new({ unit })
		end
	end
end

function UnitGrid:removeUnit(unit)
	self:removeUnitByTile(unit, unit:tile())
end

function UnitGrid:removeUnitByTile(unit, tile: number)
	local cell = self:_cell(self.gm:x(tile) // CELL, self.gm:y(tile) // CELL)
	if cell then
		local set = cell[unit:type()]
		if set then
			set:delete(unit)
		end
	end
end

function UnitGrid:updateUnitCell(unit)
	local newTile, oldTile = unit:tile(), unit:lastTile()
	if newTile == oldTile then
		return
	end
	local gm = self.gm
	if gm:x(oldTile) // CELL ~= gm:x(newTile) // CELL or gm:y(oldTile) // CELL ~= gm:y(newTile) // CELL then
		self:removeUnitByTile(unit, oldTile)
		self:addUnit(unit)
	end
end

function UnitGrid:_cellsInRange(tile: number, range: number): (number, number, number, number)
	local gm = self.gm
	local x, y = gm:x(tile), gm:y(tile)
	local gx, gy = x // CELL, y // CELL
	local startX = math.max(0, gx - math.ceil((range - (x % CELL)) / CELL))
	local endX = math.min(self.cols - 1, gx + math.ceil((range - (CELL - (x % CELL))) / CELL))
	local startY = math.max(0, gy - math.ceil((range - (y % CELL)) / CELL))
	local endY = math.min(self.rows - 1, gy + math.ceil((range - (CELL - (y % CELL))) / CELL))
	return startX, endX, startY, endY
end

-- Returns { { unit, distSquared } } within range, in upstream order.
function UnitGrid:nearbyUnits(tile: number, searchRange: number, types, predicate, includeUnderConstruction: boolean?)
	local gm = self.gm
	local nearby = {}
	local x, y = gm:x(tile), gm:y(tile)
	local startX, endX, startY, endY = self:_cellsInRange(tile, searchRange)
	local r2 = searchRange * searchRange
	local typeList = if type(types) == "table" then types else { types }
	for cy = startY, endY do
		for cx = startX, endX do
			local cell = self.grid[cy + 1][cx + 1]
			for _, t in typeList do
				local set = cell[t]
				if set == nil then
					continue
				end
				for unit in set do
					if not unit:isActive() then
						continue
					end
					if not includeUnderConstruction and unit:isUnderConstruction() then
						continue
					end
					local ut = unit:tile()
					local dx, dy = gm:x(ut) - x, gm:y(ut) - y
					local d2 = dx * dx + dy * dy
					if d2 > r2 then
						continue
					end
					local value = { unit = unit, distSquared = d2 }
					if predicate ~= nil and not predicate(value) then
						continue
					end
					table.insert(nearby, value)
				end
			end
		end
	end
	return nearby
end

function UnitGrid:_inRange(unit, tile: number, r2: number, playerId: string?, includeUnderConstruction: boolean?): boolean
	if not unit:isActive() then
		return false
	end
	if not includeUnderConstruction and unit:isUnderConstruction() then
		return false
	end
	if playerId ~= nil and unit:owner():id() ~= playerId then
		return false
	end
	local gm = self.gm
	local ut = unit:tile()
	local dx, dy = gm:x(ut) - gm:x(tile), gm:y(ut) - gm:y(tile)
	return dx * dx + dy * dy <= r2
end

function UnitGrid:hasUnitNearby(tile: number, searchRange: number, unitType: string, playerId: string?, includeUnderConstruction: boolean?): boolean
	local startX, endX, startY, endY = self:_cellsInRange(tile, searchRange)
	local r2 = searchRange * searchRange
	for cy = startY, endY do
		for cx = startX, endX do
			local set = self.grid[cy + 1][cx + 1][unitType]
			if set then
				for unit in set do
					if self:_inRange(unit, tile, r2, playerId, includeUnderConstruction) then
						return true
					end
				end
			end
		end
	end
	return false
end

function UnitGrid:anyUnitNearby(tile: number, searchRange: number, types, predicate, playerId: string?, includeUnderConstruction: boolean?): boolean
	local startX, endX, startY, endY = self:_cellsInRange(tile, searchRange)
	local r2 = searchRange * searchRange
	for cy = startY, endY do
		for cx = startX, endX do
			local cell = self.grid[cy + 1][cx + 1]
			for _, t in types do
				local set = cell[t]
				if set then
					for unit in set do
						if self:_inRange(unit, tile, r2, playerId, includeUnderConstruction) and predicate(unit) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

return UnitGrid
