-- Live performance telemetry (Roblox port, not upstream). Once a minute each
-- running match writes a summary to the "Telemetry_v1" DataStore so lag
-- reports can be diagnosed from the Creator Hub (Data Stores manager)
-- without asking players for console screenshots:
--   key "job_<JobId>"  last 30 minute rows of this server
--   key "recent"       the 40 most recent { job, t } entries (newest last)
-- Rows: server tick cost (avg / max / ticks over 100 ms), units, players,
-- and each client's own report (fps, worst frame, ping, received kbps,
-- memory, touch device). Nothing personal: user ids are not stored.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Telemetry = {}

local store = nil
if not RunService:IsStudio() then
	pcall(function()
		store = DataStoreService:GetDataStore("Telemetry_v1")
	end)
end

local window = { n = 0, total = 0, max = 0, slow = 0, frameMax = 0, frameSlow = 0 }
-- Whole server frames (Heartbeat dt): catches stalls outside the tick itself
-- (GC, engine work) that freeze replication for everyone.
game:GetService("RunService").Heartbeat:Connect(function(dt)
	if dt > window.frameMax then
		window.frameMax = dt
	end
	if dt > 0.25 then
		window.frameSlow += 1
	end
end)
local clients: { [Player]: any } = {}
local rows = {}
local jobKey = "job_" .. (if game.JobId ~= "" then game.JobId else "studio")
local registered = false

function Telemetry.tick(ms: number)
	window.n += 1
	window.total += ms
	if ms > window.max then
		window.max = ms
	end
	if ms > 100 then
		window.slow += 1
	end
end

local function num(v, lo, hi): number?
	if type(v) ~= "number" or v ~= v then
		return nil
	end
	return math.clamp(math.floor(v * 10 + 0.5) / 10, lo, hi)
end

-- A client's periodic report (validated; unknown fields dropped).
function Telemetry.client(player: Player, r)
	if type(r) ~= "table" then
		return
	end
	clients[player] = {
		fps = num(r.fps, 0, 1000),
		minFps = num(r.minFps, 0, 1000),
		maxFrame = num(r.maxFrame, 0, 60000),
		ping = num(r.ping, 0, 60000),
		recv = num(r.recv, 0, 1e6),
		mem = num(r.mem, 0, 1e6),
		touch = r.touch == true,
		gapMax = num(r.gapMax, 0, 60000),
		gaps = num(r.gaps, 0, 10000),
		t = os.clock(),
	}
end

function Telemetry.removePlayer(player: Player)
	clients[player] = nil
end

-- Called about once a minute with match context.
function Telemetry.flush(ctx)
	local w = window
	window = { n = 0, total = 0, max = 0, slow = 0, frameMax = 0, frameSlow = 0 }
	if w.n == 0 then
		return
	end
	local cl = {}
	for _, c in clients do
		if os.clock() - c.t < 90 then
			table.insert(cl, { c.fps, c.minFps, c.maxFrame, c.ping, c.recv, c.mem, c.touch, c.gapMax, c.gaps })
		end
	end
	local row = {
		t = os.time(),
		mode = ctx.mode,
		map = ctx.map,
		tick = ctx.tick,
		avg = math.floor(w.total / w.n * 10) / 10,
		max = math.floor(w.max),
		slow = w.slow,
		n = w.n,
		frameMax = math.floor(w.frameMax * 1000),
		frameSlow = w.frameSlow,
		units = ctx.units,
		players = ctx.players,
		alive = ctx.alive,
		clients = cl, -- { fps, minFps, maxFrameMs, pingMs, recvKbps, memMB, touch, maxStatsGapMs (normal 500), statsGapsOver1s }
	}
	table.insert(rows, row)
	if #rows > 30 then
		table.remove(rows, 1)
	end
	if store == nil then
		return
	end
	local snapshot = table.clone(rows)
	task.spawn(function()
		pcall(store.SetAsync, store, jobKey, snapshot)
		if not registered then
			registered = true
			pcall(store.UpdateAsync, store, "recent", function(list)
				list = if type(list) == "table" then list else {}
				table.insert(list, { job = jobKey, t = os.time() })
				while #list > 40 do
					table.remove(list, 1)
				end
				return list
			end)
		end
	end)
end

return Telemetry
