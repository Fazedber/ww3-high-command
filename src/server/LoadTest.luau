-- Studio-only load test: fake human players (no Roblox client) driven by
-- simple rules through the same intents a real player sends. Enabled with the
-- GameServer attribute FakeHumans = N; never active on live servers.

local LoadTest = {}

local BUILD = { "City", "City", "Factory", "Port", "Defense Post", "SAM Launcher", "Missile Silo" }

function LoadTest.players(n: number)
	local out = {}
	for i = 1, n do
		table.insert(out, { username = "Load " .. i, clientID = "load" .. i })
	end
	return out
end

local rng = Random.new(1)

local function randomOf(list)
	if #list == 0 then
		return nil
	end
	return list[rng:NextInteger(1, #list)]
end

-- Called once per tick before the tick runs; push(intent) queues an intent.
function LoadTest.drive(mg, n: number, push: (any) -> ())
	local tick = mg:ticks()
	local W, H = mg:map():width(), mg:map():height()
	for i = 1, n do
		local clientID = "load" .. i
		if mg:inSpawnPhase() then
			if tick % 20 == i % 20 then
				-- Pick a random free land tile.
				for _ = 1, 20 do
					local t = mg:ref(rng:NextInteger(0, W - 1), rng:NextInteger(0, H - 1))
					if mg:isLand(t) and not mg:isImpassable(t) and not mg:hasOwner(t) then
						push({ type = "spawn", clientID = clientID, tile = t })
						break
					end
				end
			end
			continue
		end
		-- Each fake player acts every 2 s, staggered.
		if (tick + i * 7) % 20 ~= 0 then
			continue
		end
		local p = mg:playerByClientID(clientID)
		if p == nil or not p:isAlive() then
			continue
		end
		local roll = rng:NextNumber()
		local neighbors = {}
		for _, nb in p:nearby() do
			if nb:isPlayer() and not p:isFriendly(nb) then
				table.insert(neighbors, nb)
			end
		end
		if roll < 0.45 then
			local target = if rng:NextNumber() < 0.5 then randomOf(neighbors) else nil
			push({ type = "attack", clientID = clientID, targetID = target and target:id() or nil, ratio = 0.3 })
		elseif roll < 0.75 then
			local tile = randomOf(p:tiles():toArray())
			if tile then
				push({ type = "build_unit", clientID = clientID, unit = randomOf(BUILD), tile = tile, amount = 1, rocketDirectionUp = true })
			end
		elseif roll < 0.85 then
			-- Nuke a neighbour (needs a silo and gold; the execution validates).
			local target = randomOf(neighbors)
			local tile = target and randomOf(target:borderTiles():toArray())
			if tile then
				local kind = if p:gold() > 5000000 and rng:NextNumber() < 0.3 then "Hydrogen Bomb" else "Atom Bomb"
				push({ type = "build_unit", clientID = clientID, unit = kind, tile = tile, amount = 1, rocketDirectionUp = true })
			end
		elseif roll < 0.92 then
			-- Boat to a random land tile somewhere else.
			local t = mg:ref(rng:NextInteger(0, W - 1), rng:NextInteger(0, H - 1))
			if mg:isLand(t) and mg:owner(t) ~= p then
				push({ type = "boat", clientID = clientID, dst = t, ratio = 0.2 })
			end
		elseif roll < 0.95 and p:gold() > 35000000 then
			local target = randomOf(neighbors)
			local tile = target and randomOf(target:borderTiles():toArray())
			if tile then
				push({ type = "build_unit", clientID = clientID, unit = "MIRV", tile = tile, amount = 1, rocketDirectionUp = true })
			end
		end
	end
end

return LoadTest
