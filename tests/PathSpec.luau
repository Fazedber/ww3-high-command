-- Checks the water pathfinding port against tools/golden-paths.mts:
-- the minimap water graph must be identical and every boat route equal.
--   return require(game.ServerStorage.Tests.PathSpec)()

local EncodingService = game:GetService("EncodingService")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = game:GetService("ReplicatedStorage").Shared

local V = require(script.Parent.PathVectors)

local function sha(s: string): string
	local h = EncodingService:ComputeBufferHash(buffer.fromstring(s), Enum.HashAlgorithm.Sha256)
	local out = table.create(buffer.len(h))
	for i = 0, buffer.len(h) - 1 do
		out[i + 1] = string.format("%02x", buffer.readu8(h, i))
	end
	return table.concat(out)
end

return function()
	local Core = ServerScriptService.Core
	local GameRunner = require(Core.GameRunner)
	local PathFinder = require(Core.Pathfinding.PathFinder)

	local t0 = os.clock()
	local runner = GameRunner.create({
		gameID = "paths",
		config = {
			gameMap = "World",
			difficulty = "Medium",
			gameType = "Private",
			gameMode = "Free For All",
			gameMapSize = "Compact",
			bots = 0,
			disabledUnits = {},
			nations = "disabled",
		},
		players = {},
	}, game:GetService("ServerStorage").Maps.World)
	local setupMs = (os.clock() - t0) * 1000
	local game = runner.game
	local graph = game:miniWaterGraph()
	local lines = {}
	local fails = 0
	local function check(ok: boolean, msg: string)
		if not ok then
			fails += 1
			if fails <= 12 then
				table.insert(lines, "  FAIL " .. msg)
			end
		end
	end

	-- Graph fingerprint
	local nodes = {}
	for id = 0, graph.nodeCount - 1 do
		local n = graph:getNode(id)
		table.insert(nodes, `{n.id},{n.x},{n.y},{n.tile},{n.componentId}`)
	end
	local edges = {}
	for id = 0, graph.edgeCount - 1 do
		local e = graph:getEdge(id)
		table.insert(edges, `{e.id},{e.nodeA},{e.nodeB},{e.cost},{e.clusterX},{e.clusterY}`)
	end
	local clusters = {}
	for cy = 0, graph.clustersY - 1 do
		for cx = 0, graph.clustersX - 1 do
			table.insert(clusters, table.concat(graph:getCluster(cx, cy).nodeIds, ","))
		end
	end
	check(graph.nodeCount == V.graph.nodeCount, `nodeCount {graph.nodeCount} != {V.graph.nodeCount}`)
	check(graph.edgeCount == V.graph.edgeCount, `edgeCount {graph.edgeCount} != {V.graph.edgeCount}`)
	check(sha(table.concat(nodes, ";")) == V.graph.nodesSha, "nodes differ")
	check(sha(table.concat(edges, ";")) == V.graph.edgesSha, "edges differ")
	check(sha(table.concat(clusters, "|")) == V.graph.clustersSha, "clusters differ")
	local mini = game:miniMap()
	check(graph:getComponentId(mini:ref(250, 100)) == V.graph.landComponentId, "land component marker differs")
	table.insert(lines, string.format("graph: %d nodes, %d edges (setup %.0f ms)", graph.nodeCount, graph.edgeCount, setupMs))

	-- Routes
	local routeOk, t1 = 0, os.clock()
	for i, q in V.queries do
		local pf = PathFinder.WaterPathFinder.new(game)
		local ok, p = pcall(function()
			return pf:findPath(q.from, q.to)
		end)
		if not ok then
			check(false, `route #{i} threw: {p}`)
			continue
		end
		local len = if p then #p else -1
		local good = len == q.len and (p == nil or sha(table.concat(p, ",")) == q.hash)
		if good then
			routeOk += 1
		else
			local head = if p then table.concat(table.move(p, 1, math.min(5, #p), 1, {}), ",") else "nil"
			check(false, `route #{i} {q.from}->{q.to}: len {len} vs {q.len}; head {head} vs {table.concat(q.head, ",")}`)
		end
	end
	table.insert(lines, string.format("routes: %d / %d identical (%.1f ms avg)", routeOk, #V.queries, (os.clock() - t1) * 1000 / #V.queries))
	table.insert(lines, `TOTAL failures: {fails}`)
	return table.concat(lines, "\n")
end
