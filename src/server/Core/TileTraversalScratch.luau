-- Port of OpenFrontIO src/core/game/TileTraversalScratch.ts.
--
-- Shared per-game traversal scratch: a generation-stamped visited buffer
-- (u32 per tile) plus a reusable stack, so flood fills allocate nothing per
-- query. A pass must run to completion before another starts.

local TileTraversalScratch = {}

local scratches = setmetatable({}, { __mode = "k" })

function TileTraversalScratch.get(game)
	local totalTiles = game:width() * game:height()
	local scratch = scratches[game]
	if scratch == nil or scratch.size < totalTiles then
		scratch = {
			visited = buffer.create(totalTiles * 4), -- u32 per tile
			clusterIndexMap = buffer.create(totalTiles * 4), -- i32 per tile
			stack = {},
			gen = 0,
			size = totalTiles,
		}
		scratches[game] = scratch
	end
	return scratch
end

-- Starts a new traversal pass and returns its generation stamp.
function TileTraversalScratch.bump(scratch): number
	scratch.gen += 1
	if scratch.gen == 0xffffffff then
		buffer.fill(scratch.visited, 0, 0)
		scratch.gen = 1
	end
	return scratch.gen
end

return TileTraversalScratch
