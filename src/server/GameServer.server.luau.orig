-- Runs one OpenFront match per Roblox server.
--
-- The simulation is server-authoritative (Core/GameRunner, a faithful port of
-- OpenFrontIO's deterministic core). Clients send intents and receive only
-- what changed: tile ownership deltas, player stats and events.
--
-- Before each match a lobby lets the host (private server owner, else the
-- earliest player) pick the map and the game settings (upstream
-- SinglePlayerModal / HostLobbyModal); everyone sees them live. The host
-- starts the match; live public servers also auto-start after a countdown.
--
-- Script attributes (optional): AutoStartSeconds (public lobby countdown,
-- default 60), LobbyMode ("public" / "custom", Studio tests).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Shop = require(Shared:WaitForChild("Data"):WaitForChild("Shop"))
local Net = require(Shared.Net)
local GameRunner = require(script.Parent.Core.GameRunner)
local GameTypes = require(script.Parent.Core.GameTypes)
local Util = require(Shared.Util)
local NameBoxCalculator = require(script.Parent.Core.NameBoxCalculator)
local Format = require(Shared.Format)
local Matchmaking = require(script.Parent.Matchmaking)

-- The game is a 2D map: no avatars (and so no touch thumbstick / jump button).
Players.CharacterAutoLoads = false

local AUTO_START_SECONDS = script:GetAttribute("AutoStartSeconds") or (if RunService:IsStudio() then nil else 60)
local PUBLIC_BOTS = 250
local TICK_SECONDS = 0.1 -- Config.msPerTick() = 100
-- Studio load tests: attribute TickSpeed runs the simulation N times faster.
local TICK_SPEED = if RunService:IsStudio() then math.max(1, script:GetAttribute("TickSpeed") or 1) else 1
local TICK_STEP = TICK_SECONDS / TICK_SPEED
local STATS_EVERY = 5 -- ticks between stats broadcasts
local MAX_INTENTS_PER_TICK = 10 -- per player

-- Unit types the build menu may place (upstream BuildMenus order).
local BUILDABLE = { "City", "Factory", "Port", "Defense Post", "Missile Silo", "SAM Launcher", "Warship", "Atom Bomb", "Hydrogen Bomb", "MIRV" }

local function clientIDOf(player: Player): string
	return tostring(player.UserId)
end

-- Profiles (settings, cosmetics, stats) and the cosmetics shop live in
-- modules that outlast match restarts; start() is idempotent.
local Profiles = require(script.Parent.Profiles)
local ShopService = require(script.Parent.ShopService)
local Progress = require(script.Parent.Progress)
local Telemetry = require(script.Parent.Telemetry)
Profiles.start()
ShopService.start()

-- Per-user settings (upstream keeps them in localStorage): the tutorial
-- "Don't show again" flag.
local function loadSettings(player: Player)
	local data = Profiles.get(player.UserId, 5)
	return if data then data.settings else {}
end

local function saveSetting(player: Player, key: string, value: any)
	local data = Profiles.get(player.UserId, 5)
	if data then
		data.settings[key] = value
		Profiles.markDirty(player.UserId)
	end
end

-- Per-player token buckets against remote spam (exploit clients): Query
-- runs buildableUnits, matchmaking calls MemoryStore / ReserveServer.
local buckets = {}
local function allow(player: Player, kind: string, perSecond: number, burst: number): boolean
	local key = player.UserId .. ":" .. kind
	local now = os.clock()
	local b = buckets[key]
	if b == nil then
		b = { tokens = burst, at = now }
		buckets[key] = b
	end
	b.tokens = math.min(burst, b.tokens + (now - b.at) * perSecond)
	b.at = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end
Players.PlayerRemoving:Connect(function(player)
	Telemetry.removePlayer(player)
	local prefix = player.UserId .. ":"
	for key in buckets do
		if string.sub(key, 1, #prefix) == prefix then
			buckets[key] = nil
		end
	end
end)

-- Shop remote calls (lobby and match): Query kind "shop" and intent "equip".
local function shopQuery(player: Player, q)
	if type(q) == "table" and q.kind == "shop" then
		if not allow(player, "shop", 2, 5) then
			return nil
		end
		return ShopService.state(player.UserId)
	end
	return nil
end
Net.Query.OnServerInvoke = shopQuery
Net.Intent.OnServerEvent:Connect(function(player: Player, intent)
	if type(intent) ~= "table" then
		return
	end
	if intent.type == "equip" and type(intent.slot) == "string" and allow(player, "equip", 3, 6) then
		-- value: item id (pattern / nameColor / explosion), palette index
		-- (color) or country code (flag); nil unequips.
		local value = intent.value
		if value == nil and type(intent.itemId) == "string" then
			value = intent.itemId
		end
		if value ~= nil and type(value) ~= "string" and type(value) ~= "number" then
			return
		end
		ShopService.equip(player.UserId, intent.slot, value)
	elseif intent.type == "watch_ad" and allow(player, "ad", 1 / 30, 1) then
		task.spawn(ShopService.showRewardedAd, player)
	end
end)

-- Lobby ---------------------------------------------------------------------------

local ServerStorage = game:GetService("ServerStorage")
local MapCatalog = require(Shared.Data.MapCatalog)

local DIFFICULTIES = { "Easy", "Medium", "Hard", "Impossible" }
local STARTING_GOLD = { 0, 1000000, 5000000, 25000000 }
local GOLD_MULTIPLIER = { 1, 2, 5 }
local MAX_BOTS = 400
-- Units forced off whatever the host picks (none: everything is ported).
local FORCED_OFF: { [string]: boolean } = {}

local lobby = {
	settings = {
		map = "World",
		mode = "ffa", -- "ffa", 2..7 teams, "Duos"/"Trios"/"Quads", "Humans Vs Nations"
		difficulty = "Medium",
		bots = 250,
		nations = 72, -- World's nation count; reset to the map's on map change
		infiniteGold = false,
		infiniteTroops = false,
		instantBuild = false,
		randomSpawn = false,
		startingGold = 0,
		goldMultiplier = 1,
		disabledUnits = {},
	},
	hostUserId = nil :: number?,
	startAt = nil :: number?,
	started = false,
	-- "public": no host, rotating settings, auto start, listed for
	-- matchmaking; "custom": a host picks the settings and starts (VIP and
	-- private-match servers, and Studio for testing).
	mode = "custom",
	joinCode = nil :: string?,
	-- Public lobbies: every player votes for a map and a mode (userId -> value);
	-- the most voted wins, the rotation pick stands when nobody votes.
	votes = { map = {}, mode = {} },
	defaults = { map = "World", mode = "ffa" :: any },
	-- Singleplayer "Play again": restart on this server (no teleport).
	soloReset = false,
}
-- Settings carried over a singleplayer restart (see soloReset).
do
	local saved = script:GetAttribute("Settings")
	if type(saved) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, saved)
		if ok and type(decoded) == "table" then
			for k, v in decoded do
				if lobby.settings[k] ~= nil then
					lobby.settings[k] = v
				end
			end
		end
	end
end

-- Public lobbies rotate maps by their playlist frequency (MapCatalog).
local function rotationMap(): string
	local total = 0
	for _, m in MapCatalog do
		total += m.frequency or 1
	end
	local r = Random.new():NextNumber() * total
	for _, m in MapCatalog do
		r -= m.frequency or 1
		if r <= 0 and ServerStorage.Maps:FindFirstChild(m.id) then
			return m.id
		end
	end
	return "World"
end

local function mapInfo(id: string)
	for _, m in MapCatalog do
		if m.id == id then
			return m
		end
	end
	return nil
end

local function pickHost()
	if lobby.mode == "public" then
		lobby.hostUserId = nil
		return
	end
	if lobby.preferredHost and Players:GetPlayerByUserId(lobby.preferredHost) then
		lobby.hostUserId = lobby.preferredHost
		return
	end
	local owner = game.PrivateServerOwnerId
	if owner ~= 0 and Players:GetPlayerByUserId(owner) then
		lobby.hostUserId = owner
		return
	end
	if lobby.hostUserId and Players:GetPlayerByUserId(lobby.hostUserId) then
		return
	end
	local first = Players:GetPlayers()[1]
	lobby.hostUserId = if first then first.UserId else nil
end

local function isValidMode(value): boolean
	return value == "ffa" or value == "Duos" or value == "Trios" or value == "Quads" or value == "Humans Vs Nations" or (type(value) == "number" and value >= 2 and value <= 7 and value % 1 == 0)
end

-- Vote counts per option (keys as strings, as clients index them).
local function tally(kind: string): { [string]: number }
	local out = {}
	for _, v in lobby.votes[kind] do
		local k = tostring(v)
		out[k] = (out[k] or 0) + 1
	end
	return out
end

-- The winning option: most votes; a tie keeps the current pick if it is
-- among the leaders, else the first leader in catalog / mode order.
local function leader(kind: string, current, order: { any })
	local counts = tally(kind)
	local best = 0
	for _, n in counts do
		best = math.max(best, n)
	end
	if best == 0 then
		return nil
	end
	if counts[tostring(current)] == best then
		return current
	end
	for _, v in order do
		if counts[tostring(v)] == best then
			return v
		end
	end
	return nil
end

local MODE_ORDER = { "ffa", 2, 3, 4, 5, 6, 7, "Duos", "Trios", "Quads", "Humans Vs Nations" }
local function applyVotes()
	local st = lobby.settings
	local mapOrder = {}
	for _, m in MapCatalog do
		table.insert(mapOrder, m.id)
	end
	local map = leader("map", st.map, mapOrder) or lobby.defaults.map
	if map ~= st.map then
		st.map = map
		st.nations = mapInfo(map).nations
	end
	st.mode = leader("mode", st.mode, MODE_ORDER) or lobby.defaults.mode
end

local hostAdvancedFn = nil -- set below (needs ShopService perks)
local function lobbyState()
	local names = {}
	for _, p in Players:GetPlayers() do
		table.insert(names, p.DisplayName)
	end
	return {
		settings = lobby.settings,
		hostUserId = lobby.hostUserId,
		secondsLeft = if lobby.startAt then math.max(0, math.ceil(lobby.startAt - os.clock())) else nil,
		players = names,
		mode = lobby.mode,
		joinCode = lobby.joinCode,
		canMatchmake = Matchmaking.available(),
		votes = if lobby.mode == "public" then { map = tally("map"), mode = tally("mode") } else nil,
		hostAdvanced = hostAdvancedFn and hostAdvancedFn(lobby.hostUserId),
		-- Leaderboard section: global top wins + the stats of everyone here.
		top = Progress.top(),
		stats = (function()
			local out = {}
			for _, p in Players:GetPlayers() do
				local data = Profiles.get(p.UserId)
				if data then
					out[tostring(p.UserId)] = data.stats
				end
			end
			return out
		end)(),
	}
end

local function broadcastLobby()
	Net.Lobby:FireAllClients(lobbyState())
end

-- Validated setting change from the host.
local function setLobbySetting(key: string, value: any)
	local st = lobby.settings
	if key == "map" then
		if type(value) == "string" and mapInfo(value) and ServerStorage.Maps:FindFirstChild(value) then
			st.map = value
			-- Upstream loadNationCount: the slider resets to the map's nations.
			st.nations = mapInfo(value).nations
		end
	elseif key == "mode" then
		if isValidMode(value) then
			st.mode = value
		end
	elseif key == "difficulty" then
		if table.find(DIFFICULTIES, value) then
			st.difficulty = value
		end
	elseif key == "bots" or key == "nations" then
		if type(value) == "number" and value == value then
			st[key] = math.clamp(math.floor(value), 0, MAX_BOTS)
		end
	elseif key == "infiniteGold" or key == "infiniteTroops" or key == "instantBuild" or key == "randomSpawn" then
		if type(value) == "boolean" then
			st[key] = value
		end
	elseif key == "startingGold" then
		if table.find(STARTING_GOLD, value) then
			st.startingGold = value
		end
	elseif key == "goldMultiplier" then
		if table.find(GOLD_MULTIPLIER, value) then
			st.goldMultiplier = value
		end
	elseif key == "unit" then
		-- value = { unit, enabled }
		if type(value) == "table" and table.find(BUILDABLE, value[1]) and type(value[2]) == "boolean" and not FORCED_OFF[value[1]] then
			local list = st.disabledUnits
			local i = table.find(list, value[1])
			if value[2] and i then
				table.remove(list, i)
			elseif not value[2] and not i then
				table.insert(list, value[1])
			end
		end
	end
end

Net.Intent.OnServerEvent:Connect(function(player: Player, intent)
	if type(intent) ~= "table" then
		return
	end
	local mm = intent.type == "find_match" or intent.type == "create_private" or intent.type == "join_code" or intent.type == "play_solo"
	if mm and not allow(player, "matchmaking", 0.2, 2) then
		return -- one teleport request per 5 s (burst 2)
	end
	if intent.type == "find_match" then
		Matchmaking.findMatch(player)
	elseif intent.type == "create_private" then
		Matchmaking.createPrivate(player)
	elseif intent.type == "play_solo" then
		if lobby.mode == "solo" and lobby.started then
			-- Already on our own server: a fresh match right here is much faster
			-- than reserving and teleporting to a new one.
			lobby.soloReset = true
		else
			Matchmaking.createSolo(player)
		end
	elseif intent.type == "join_code" and type(intent.code) == "string" and #intent.code <= 12 then
		local ok = Matchmaking.joinByCode(player, intent.code)
		if not ok then
			Net.Event:FireClient(player, { type = "JoinCodeFailed" })
		end
	end
end)

local voteConn = Net.Intent.OnServerEvent:Connect(function(player: Player, intent)
	if lobby.started or lobby.mode ~= "public" or type(intent) ~= "table" or intent.type ~= "lobby_vote" then
		return
	end
	if not allow(player, "vote", 4, 8) then
		return
	end
	local kind, value = intent.kind, intent.value
	if kind == "map" then
		if not (type(value) == "string" and mapInfo(value) and ServerStorage.Maps:FindFirstChild(value)) then
			return
		end
	else
		return -- only the map is voted on
	end
	-- Clicking your current vote again withdraws it.
	local votes = lobby.votes[kind]
	votes[player.UserId] = if votes[player.UserId] == value then nil else value
	applyVotes()
	broadcastLobby()
end)
-- Settings every host can change; the rest need host perks (Host Pass or
-- the subscription), owning this VIP server, or Studio.
local BASIC_SETTINGS = { map = true, mode = true, difficulty = true }
local function hostAdvanced(userId: number?): boolean
	if userId == nil then
		return false
	end
	return RunService:IsStudio() or game.PrivateServerOwnerId == userId or ShopService.hasHostPerks(userId)
end
hostAdvancedFn = hostAdvanced
local lobbyConn = Net.Intent.OnServerEvent:Connect(function(player: Player, intent)
	if lobby.started or type(intent) ~= "table" or player.UserId ~= lobby.hostUserId then
		return
	end
	if intent.type == "lobby_set" and type(intent.key) == "string" then
		if not BASIC_SETTINGS[intent.key] and not hostAdvanced(player.UserId) then
			Net.Event:FireClient(player, { type = "NeedHostPass" })
			return
		end
		setLobbySetting(intent.key, intent.value)
		broadcastLobby()
	elseif intent.type == "lobby_start" then
		lobby.started = true
	end
end)
local perksConn = ShopService.Changed:Connect(function()
	broadcastLobby()
end)
local joinConn = Players.PlayerAdded:Connect(function()
	pickHost()
	broadcastLobby()
end)
local leaveConn = Players.PlayerRemoving:Connect(function(player)
	lobby.votes.map[player.UserId] = nil
	lobby.votes.mode[player.UserId] = nil
	task.defer(function()
		if lobby.mode == "public" then
			applyVotes()
		end
		pickHost()
		broadcastLobby()
	end)
end)

while #Players:GetPlayers() == 0 do
	Players.PlayerAdded:Wait()
end
Matchmaking.learnAccessCode()
do
	local kind, host = Matchmaking.serverKind()
	-- Attribute LobbyMode ("public" / "custom") overrides, for Studio tests.
	lobby.mode = script:GetAttribute("LobbyMode") or (if RunService:IsStudio() then "custom" else kind)
	lobby.preferredHost = host
end
if lobby.mode == "public" then
	local st0 = lobby.settings
	st0.map = rotationMap()
	st0.nations = mapInfo(st0.map).nations
	st0.bots = PUBLIC_BOTS
	-- Every fourth public match or so is a team game (2-4 teams).
	local rng = Random.new()
	st0.mode = if rng:NextNumber() < 0.25 then rng:NextInteger(2, 4) else "ffa"
	lobby.defaults.map, lobby.defaults.mode = st0.map, st0.mode
elseif Matchmaking.accessCode and lobby.mode ~= "solo" then
	-- Private match: friends join with this code from any lobby.
	lobby.joinCode = Matchmaking.registerJoinCode()
end
pickHost()
if lobby.mode == "public" then
	lobby.startAt = os.clock() + (AUTO_START_SECONDS or 60)
end
broadcastLobby()
local lastBroadcast = os.clock()
while not lobby.started do
	if lobby.startAt and os.clock() >= lobby.startAt then
		lobby.started = true
		break
	end
	if os.clock() - lastBroadcast >= 1 then
		lastBroadcast = os.clock()
		broadcastLobby()
		if lobby.mode == "public" and lobby.startAt and math.floor(lastBroadcast) % 5 == 0 then
			Matchmaking.publish(os.time() + math.ceil(lobby.startAt - os.clock()), #Players:GetPlayers(), Players.MaxPlayers)
		end
	end
	task.wait(0.1)
end
Matchmaking.unpublish()
lobbyConn:Disconnect()
voteConn:Disconnect()
perksConn:Disconnect()
joinConn:Disconnect()
leaveConn:Disconnect()
Net.Lobby:FireAllClients({ starting = true })

-- Only the selected map is replicated to clients.
local st = lobby.settings
local MAP_ID = st.map
local mapsFolder = Shared:FindFirstChild("Maps")
if not mapsFolder then
	mapsFolder = Instance.new("Folder")
	mapsFolder.Name = "Maps"
	mapsFolder.Parent = Shared
end
if not mapsFolder:FindFirstChild(MAP_ID) then
	ServerStorage.Maps[MAP_ID]:Clone().Parent = mapsFolder
end

local gameID = string.sub(HttpService:GenerateGUID(false), 1, 8)
local players = {}
for _, p in Players:GetPlayers() do
	table.insert(players, { username = p.DisplayName, clientID = clientIDOf(p), isLobbyCreator = p.UserId == lobby.hostUserId })
end
-- Studio load test (attribute FakeHumans = N): N scripted human players.
local FAKE_HUMANS = if RunService:IsStudio() then script:GetAttribute("FakeHumans") or 0 else 0
local LoadTest = if FAKE_HUMANS > 0 then require(script.Parent.LoadTest) else nil
if LoadTest then
	for _, fake in LoadTest.players(FAKE_HUMANS) do
		table.insert(players, fake)
	end
end

local disabledUnits = table.clone(st.disabledUnits)
for unit in FORCED_OFF do
	if not table.find(disabledUnits, unit) then
		table.insert(disabledUnits, unit)
	end
end

local runner = GameRunner.create({
	gameID = gameID,
	config = {
		gameMap = MAP_ID,
		difficulty = st.difficulty,
		donateGold = false,
		donateTroops = false,
		-- Singleplayer servers (and solo Studio tests) are upstream Singleplayer:
		-- no 20 s spawn timer, the game starts as soon as the player picks a
		-- location.
		gameType = if lobby.mode == "solo" or (RunService:IsStudio() and #players == 1) then "Singleplayer" else "Public",
		-- Win only at 95 % land with nobody else able to afford a MIRV; no
		-- timers, no "keep playing" (WinCheck:_hasWonRoblox).
		robloxWinRule = true,
		gameMode = if st.mode == "ffa" then "Free For All" else "Team",
		playerTeams = if st.mode == "ffa" then nil else st.mode,
		gameMapSize = "Compact",
		bots = st.bots,
		randomSpawn = st.randomSpawn,
		infiniteGold = st.infiniteGold,
		infiniteTroops = st.infiniteTroops,
		instantBuild = st.instantBuild,
		startingGold = if st.startingGold > 0 then st.startingGold else nil,
		goldMultiplier = if st.goldMultiplier ~= 1 then st.goldMultiplier else nil,
		disabledUnits = disabledUnits,
		-- 0 = disabled, else exactly that many (manifest nations first). The
		-- count is explicit because "default" on a public compact map means 25 %.
		nations = if st.nations == 0 then "disabled" else st.nations,
	},
	players = players,
}, ServerStorage.Maps[MAP_ID])
local BOTS = st.bots
local mg = runner.game
print(`[GameServer] game {gameID} on {MAP_ID} with {#players} human(s) and {BOTS} bots`)

-- Replication ---------------------------------------------------------------------

local rosterSent = 0

local function rosterEntry(p)
	local userId = p:type() == "HUMAN" and tonumber(p:clientID())
	return {
		smallID = p:smallID(),
		id = p:id(),
		name = p:displayName(),
		type = p:type(),
		clientID = p:clientID(),
		team = p:team(),
		-- Cosmetics (pattern id, name colour, supporter badge); humans only.
		cosmetics = if userId then ShopService.cosmetics(userId) else nil,
	}
end

-- Cosmetics bought / equipped / loaded mid-match: resend that roster entry.
ShopService.Changed:Connect(function(userId: number)
	local p = mg:playerByClientID(tostring(userId))
	if p and p:smallID() <= rosterSent then
		Net.Roster:FireAllClients({ rosterEntry(p) })
	end
end)

local function newRosterEntries()
	local all = mg:allPlayers()
	local out = {}
	for i = rosterSent + 1, #all do
		table.insert(out, rosterEntry(all[i]))
	end
	rosterSent = #all
	return out
end

-- Name placements, recomputed when upstream GameRunner recomputes them.
local names = {} -- smallID -> { x, y, size }

local function nameRows(): { { number } }
	local rows = {}
	for smallID, v in names do
		table.insert(rows, { smallID, v.x, v.y, v.size })
	end
	return rows
end

local nameCursor = 0
local function updateNames(wasInSpawnPhase: boolean)
	local changed = {}
	local function set(p, v)
		local old = names[p:smallID()]
		if old == nil or old.x ~= v.x or old.y ~= v.y or old.size ~= v.size then
			names[p:smallID()] = v
			table.insert(changed, { p:smallID(), v.x, v.y, v.size })
		end
	end
	if mg:inSpawnPhase() then
		for _, p in mg:players() do
			if (p:type() == "HUMAN" or p:type() == "NATION") and p:spawnTile() ~= nil then
				set(p, NameBoxCalculator.placeSpawnName(mg, p))
			end
		end
	end
	local spawnJustEnded = wasInSpawnPhase and not mg:inSpawnPhase()
	local players = mg:players()
	if spawnJustEnded or mg:ticks() < 3 then
		for _, p in players do
			set(p, NameBoxCalculator.placeName(mg, p))
		end
	elseif #players > 0 then
		-- Every name is re-placed once per 30 ticks, like upstream, but spread
		-- over the ticks: all ~320 at once took ~80 ms and made the map hitch
		-- every 3 s.
		local count = math.ceil(#players / 30)
		for _ = 1, count do
			nameCursor = nameCursor % #players + 1
			set(players[nameCursor], NameBoxCalculator.placeName(mg, players[nameCursor]))
		end
	end
	if #changed > 0 then
		Net.Names:FireAllClients(Net.packNames(changed))
	end
end

-- Railroads (id -> tiles), rebuilt from the construction / destruction /
-- snap events (upstream RailroadCache) for late joiners.
local railroads = {}

-- Construction progress (BarPass: constructionStartTick = the tick the unit
-- was first seen under construction, duration from unitInfo).
local buildStart: { [number]: number } = {}
local function buildInfo(up)
	if not up.underConstruction then
		buildStart[up.id] = nil
		return nil, nil
	end
	buildStart[up.id] = buildStart[up.id] or mg:ticks()
	return buildStart[up.id], mg:config():unitInfo(up.unitType).constructionDuration or 50
end

local function fullState(forPlayer: Player)
	local roster = {}
	for _, p in mg:allPlayers() do
		table.insert(roster, rosterEntry(p))
	end
	local state = mg:map():tileStateBuffer()
	local copy = buffer.create(buffer.len(state))
	buffer.copy(copy, 0, state)
	return {
		mapId = MAP_ID,
		tick = mg:ticks(),
		inSpawnPhase = mg:inSpawnPhase(),
		spawnPhaseTurns = mg:config():numSpawnPhaseTurns(),
		-- Singleplayer has no spawn timer (upstream GameRunner.init).
		hasSpawnTimer = mg:config():gameConfig().gameType ~= "Singleplayer",
		-- "Play again" after dying / at the end: every server kind can send
		-- players on (singleplayer to a new solo game, the rest to a match).
		canMatchmake = Matchmaking.available(),
		lobbyMode = lobby.mode,
		randomSpawn = mg:config():isRandomSpawn(),
		alliancesDisabled = mg:config():disableAlliances(),
		yourClientID = clientIDOf(forPlayer),
		tutorialDismissed = loadSettings(forPlayer).tutorialDismissed == true,
		audio = loadSettings(forPlayer).audio,
		rebirths = ShopService.rebirths(forPlayer.UserId),
		rebirthPrice = Shop.REBIRTH.price,
		rebirthProduct = Shop.REBIRTH.productId,
		disabledUnits = (function()
			local d = {}
			for _, u in BUILDABLE do
				d[u] = mg:config():isUnitDisabled(u) or nil
			end
			return d
		end)(),
		players = roster,
		tiles = Net.wrap(copy),
		names = Net.packNames(nameRows()),
		rails = (function()
			local list = {}
			for id, tiles in railroads do
				table.insert(list, { id = id, tiles = tiles })
			end
			return list
		end)(),
		units = (function()
			local list = {}
			for _, u in mg:units() do
				local up = u:toUpdate()
				local bStart, bTicks = buildInfo(up)
				table.insert(list, { buildStart = bStart, buildTicks = bTicks, id = up.id, unitType = up.unitType, ownerID = up.ownerID, pos = up.pos, troops = up.troops, isActive = true, isRetreating = up.isRetreating, level = up.level, underConstruction = up.underConstruction, markedForDeletion = up.markedForDeletion ~= false, targetTile = up.targetTile, plan = mg:motionPlan(up.id), health = up.health, maxHealth = up.maxHealth, targetable = up.targetable, targetUnitId = up.targetUnitId, warshipRetreating = up.warshipRetreating, trainType = up.trainType, loaded = up.loaded, missileTimers = up.missileTimers, reloadTicks = up.reloadTicks })
			end
			return list
		end)(),
	}
end

-- Name status icons shared by everyone (StatusIconProgram): traitors and
-- disconnected players; sent when the sets change.
local lastFlags = ""
local function broadcastFlags()
	local traitors, disconnected = {}, {}
	for _, p in mg:players() do
		if p:isTraitor() then
			table.insert(traitors, p:smallID())
		end
		if p:isDisconnected() then
			table.insert(disconnected, p:smallID())
		end
	end
	local key = table.concat(traitors, ",") .. "|" .. table.concat(disconnected, ",")
	if key ~= lastFlags then
		lastFlags = key
		Net.Event:FireAllClients({ type = "Flags", traitors = traitors, disconnected = disconnected })
	end
end

local function statsRows()
	local rows = {}
	for _, p in mg:allPlayers() do
		if p:isAlive() or p:hasSpawned() then
			table.insert(rows, { p:smallID(), p:numTilesOwned(), p:troops(), p:gold() })
		end
	end
	return rows
end

local function sendState(player: Player)
	Net.GameState:FireClient(player, fullState(player))
end

for _, p in Players:GetPlayers() do
	sendState(p)
end
rosterSent = #mg:allPlayers()
Players.PlayerAdded:Connect(function(p)
	-- Late joiners watch; on public servers they are offered (and after a
	-- few seconds sent to) a lobby that is about to start.
	sendState(p)
	if lobby.mode == "public" and Matchmaking.available() then
		Net.Event:FireClient(p, { type = "MatchInProgress", autoSeconds = 8 })
	end
	lastFlags = "" -- resend name flags
end)

-- Intents -------------------------------------------------------------------------

local pending = {} -- queued intents for the next tick
local intentCount = {} -- clientID -> count this tick

-- Tick cost (ms) since match start; read by load tests.
local tickPerf = { n = 0, total = 0, max = 0, slow = 0 }

-- Studio-only handle for debugging from the command bar / MCP.
if RunService:IsStudio() then
	_G.OpenFront = { game = mg, runner = runner, perf = tickPerf }
end

local function isInt(v): boolean
	return type(v) == "number" and v == math.floor(v)
end

-- Upstream radial menu "delete": closest finished structure of ours within
-- manhattan distance 5 of a land tile we own.
local DELETE_SELECTION_RADIUS = 5
local function deletableAt(me, tile: number)
	if mg:inSpawnPhase() or not me:canDeleteUnit() or not mg:isLand(tile) then
		return nil
	end
	local owner = mg:owner(tile)
	if not owner:isPlayer() or owner:id() ~= me:id() then
		return nil
	end
	local mine = {}
	for _, u in me:units() do
		if
			not u:isUnderConstruction()
			and not u:isMarkedForDeletion()
			and GameTypes.Structures.has(u:type())
			and mg:manhattanDist(u:tile(), tile) <= DELETE_SELECTION_RADIUS
		then
			table.insert(mine, u)
		end
	end
	return Util.findClosestBy(mine, function(u)
		return mg:manhattanDist(u:tile(), tile)
	end)
end

-- Build menu query: what the asking player can build / upgrade / delete at a tile.
local interactionFor, playerPanelData
local recentIntents

-- Upstream GameRunner.playerActions().interaction.
function interactionFor(me, other)
	return {
		sharedBorder = me:sharesBorderWith(other),
		canSendEmoji = me:canSendEmoji(other),
		canTarget = me:canTarget(other),
		canSendAllianceRequest = me:canSendAllianceRequest(other),
		canBreakAlliance = me:isAlliedWith(other),
		canDonateGold = me:canDonateGold(other),
		canDonateTroops = me:canDonateTroops(other),
		canEmbargo = not me:hasEmbargoAgainst(other),
		allianceInfo = me:allianceInfo(other),
		isAllied = me:isAlliedWith(other),
		isFriendly = me:isFriendly(other),
		isDisconnected = other:isDisconnected(),
	}
end

-- PlayerPanel data for the tile's owner.
function playerPanelData(me, other, interaction)
	if other == nil then
		return nil
	end
	local alliances = {}
	for _, a in other:alliances() do
		local ally = a:other(other)
		table.insert(alliances, { smallID = ally:smallID(), name = ally:displayName(), expiresAt = a:expiresAt() })
	end
	local relationToMe = nil
	if other:type() == "NATION" then
		relationToMe = other:relation(me)
	end
	return {
		smallID = other:smallID(),
		name = other:displayName(),
		playerType = other:type(),
		isSelf = other == me,
		gold = other:gold(),
		troops = other:troops(),
		betrayals = other:betrayals(),
		traitorTicks = if other:isTraitor() then other:getTraitorRemainingTicks() else nil,
		embargoAgainstMe = other:hasEmbargoAgainst(me),
		alliances = alliances,
		relationToMe = relationToMe,
		isAlliedWithMe = me:isAlliedWith(other),
		tick = mg:ticks(),
		interaction = if other ~= me then interaction else nil,
		canSendEmojiAllPlayers = me:canSendEmoji(GameTypes.AllPlayers),
		canEmbargoAll = me:canEmbargoAll(),
		myGold = me:gold(),
		myTroops = me:troops(),
		capacity = math.max(0, mg:config():maxTroops(other) - other:troops()),
	}
end

-- Death diagnostics (server log): recent intents per clientID and, per
-- living human, the attacks against it on the previous tick.
recentIntents = {} :: { [string]: { string } }
local lastThreats = {}
-- Rebirth snapshot: each human's biggest territory this match (tile list),
-- refreshed when it grows by 3 %.
local peaks: { [string]: { n: number, tiles: { number }, troops: number } } = {}
local requestRebirth, applyRebirth

local function checkHumanDeaths()
	-- The threat snapshot (for the death log) is rebuilt every 10 ticks, not
	-- every tick: formatting every incoming attack of every human 10 times a
	-- second was measurable work on a full server.
	local sample = mg:ticks() % 10 == 0
	for _, p in mg:players() do
		if p:type() ~= "HUMAN" then
			continue
		end
		local clientID = p:clientID()
		if p:numTilesOwned() > 0 and lastThreats[clientID] and not sample then
			continue
		end
		if p:numTilesOwned() > 0 then
			local n = p:numTilesOwned()
			local pk = peaks[clientID]
			if pk == nil or n > pk.n * 1.03 + 10 then
				peaks[clientID] = { n = n, tiles = p:tiles():toArray(), troops = p:troops() }
			end
			local rows = {}
			for _, a in p:incomingAttacks() do
				table.insert(rows, string.format("%s(%s) %d troops", a:attacker():name(), a:attacker():type(), math.floor(a:troops())))
			end
			local out = 0
			for _, a in p:outgoingAttacks() do
				out += a:troops()
			end
			lastThreats[clientID] = { tiles = p:numTilesOwned(), troops = p:troops(), out = out, incoming = rows }
		elseif lastThreats[clientID] then
			local t = lastThreats[clientID]
			lastThreats[clientID] = nil
			warn(string.format(
				"[DeathLog] %s died at tick %d. Before: %d tiles, %d troops home, %d troops attacking. Incoming: %s. Recent intents: %s",
				p:name(),
				mg:ticks(),
				t.tiles,
				math.floor(t.troops),
				math.floor(t.out),
				if #t.incoming > 0 then table.concat(t.incoming, "; ") else "none",
				table.concat(recentIntents[clientID] or {}, " | ")
			))
		end
	end
end

Net.Query.OnServerInvoke = function(player: Player, q)
	local shop = shopQuery(player, q)
	if shop then
		return shop
	end
	local me = mg:playerByClientID(clientIDOf(player))
	if me == nil or type(q) ~= "table" or not isInt(q.tile) or not mg:isValidRef(q.tile) then
		return nil
	end
	-- The build ghost queries ~8/s while hovering; allow bursts, cap abuse.
	if not allow(player, "query", 15, 30) then
		return nil
	end
	local list = {}
	for _, u in BUILDABLE do
		if not mg:config():isUnitDisabled(u) then
			table.insert(list, u)
		end
	end
	local out = {}
	local railsFor = if type(q.ghost) == "string" and table.find(BUILDABLE, q.ghost) then q.ghost else false
	for _, bu in me:buildableUnits(q.tile, list, railsFor) do
		local upgradeTile = nil
		if bu.canUpgrade ~= false then
			local target = mg:unit(bu.canUpgrade)
			upgradeTile = target and target:tile()
		end
		table.insert(out, {
			unit = bu.type,
			cost = bu.cost,
			canBuild = bu.canBuild ~= false,
			canUpgrade = bu.canUpgrade ~= false,
			upgradeCosts = if bu.upgradeCosts then table.move(bu.upgradeCosts, 1, 5, 1, {}) else nil, -- x1 and x5 only
			upgradeTile = upgradeTile,
			-- Build ghost only (q.ghost = the selected unit): rail preview.
			ghostRailPaths = if q.ghost == bu.type and bu.ghostRailPaths and #bu.ghostRailPaths > 0 then bu.ghostRailPaths else nil,
			overlappingRailroads = if q.ghost == bu.type and bu.overlappingRailroads and #bu.overlappingRailroads > 0 then bu.overlappingRailroads else nil,
		})
	end
	local del = deletableAt(me, q.tile)
	local spawnPhase = mg:inSpawnPhase()
	local interaction = nil
	local ownerID = mg:ownerID(q.tile)
	local other = if ownerID ~= 0 then mg:playerBySmallID(ownerID) else nil
	if other then
		interaction = interactionFor(me, other)
	end
	if q.kind == "player" then
		return playerPanelData(me, other, interaction)
	end
	return {
		interaction = interaction,
		ownerIsTraitor = other ~= nil and other:isTraitor(),
		canSendEmojiAllPlayers = me:canSendEmoji(GameTypes.AllPlayers),
		canEmbargoAll = me:canEmbargoAll(),
		units = out,
		deleteUnit = if del then del:type() else nil,
		-- Radial menu (RadialMenuElements): centre attack, boat slot, owner.
		canAttack = not spawnPhase and me:canAttack(q.tile),
		canBoat = not spawnPhase and mg:isLand(q.tile) and me:canBuild("Transport", q.tile) ~= false,
		ownerSmallID = mg:ownerID(q.tile),
		inSpawnPhase = spawnPhase,
	}
end

-- Rebirth: a dead human spends a banked rebirth (bought for Robux) to get
-- back the biggest territory they had this match.
local PlayerExecution = require(script.Parent.Core.Execution.PlayerExecution)
local REBIRTH_SHIELD_TICKS = 100
function requestRebirth(player: Player, me): boolean
	local clientID = clientIDOf(player)
	if mg:inSpawnPhase() or me:isAlive() or peaks[clientID] == nil or mg:getWinner() ~= nil then
		return false
	end
	if not ShopService.useRebirth(player.UserId) then
		return false
	end
	table.insert(pending, { type = "rebirth", clientID = clientID })
	return true
end
function applyRebirth(p)
	local pk = peaks[p:clientID()]
	if pk == nil or p:isAlive() then
		return
	end
	for _, tile in pk.tiles do
		if mg:isLand(tile) and not mg:isImpassable(tile) and mg:owner(tile) ~= p then
			mg:conquer(p, tile)
		end
	end
	if not p:isAlive() then
		return
	end
	p:setTroops(math.max(p:troops(), pk.troops))
	-- 10 s shield: nobody can attack or nuke them (PlayerImpl:isImmune), shown
	-- to everyone.
	p._shieldUntil = mg:ticks() + REBIRTH_SHIELD_TICKS
	Net.Event:FireAllClients({ type = "Shield", smallID = p:smallID(), name = p:displayName(), seconds = REBIRTH_SHIELD_TICKS / 10 })
	-- PlayerExecution stopped when they died; start a fresh one.
	mg:addExecution(PlayerExecution.new(p))
	lastThreats[p:clientID()] = nil
	for _, pl in Players:GetPlayers() do
		if clientIDOf(pl) == p:clientID() then
			Net.Event:FireClient(pl, { type = "Reborn" })
		end
	end
end
-- A rebirth bought from the death screen is used straight away.
ShopService.onRebirthBought = function(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	local me = player and mg:playerByClientID(clientIDOf(player))
	if me then
		requestRebirth(player, me)
	end
end

Net.Intent.OnServerEvent:Connect(function(player: Player, intent)
	if type(intent) ~= "table" then
		return
	end
	local clientID = clientIDOf(player)
	if intent.type == "telemetry" then
		if allow(player, "telemetry", 0.2, 2) then
			Telemetry.client(player, intent)
		end
		return
	end
	if intent.type == "tutorial_dismiss" then
		saveSetting(player, "tutorialDismissed", true)
		return
	elseif intent.type == "audio_settings" then
		-- Music / effects volume (0..1), kept across servers.
		local m, e = intent.music, intent.effects
		if type(m) == "number" and type(e) == "number" and m == m and e == e and allow(player, "audio", 2, 5) then
			saveSetting(player, "audio", { music = math.clamp(m, 0, 1), effects = math.clamp(e, 0, 1) })
		end
		return
	end
	local me = mg:playerByClientID(clientID)
	if me == nil then
		return -- spectator
	end
	local n = (intentCount[clientID] or 0) + 1
	if n > MAX_INTENTS_PER_TICK then
		return
	end
	intentCount[clientID] = n
	-- Death diagnostics: the last few intents of each human.
	local log = recentIntents[clientID] or {}
	recentIntents[clientID] = log
	table.insert(log, string.format("t%d %s tile=%s target=%s ratio=%s", mg:ticks(), tostring(intent.type), tostring(intent.tile), tostring(intent.target or intent.targetSmallID), tostring(intent.ratio)))
	if #log > 12 then
		table.remove(log, 1)
	end

	local t = intent.type
	if t == "surrender" then
		if not mg:inSpawnPhase() and me:isAlive() then
			table.insert(pending, { type = "surrender", clientID = clientID })
		end
		return
	elseif t == "rebirth" then
		requestRebirth(player, me)
		return
	end
	if t == "spawn" then
		if isInt(intent.tile) and mg:isValidRef(intent.tile) then
			table.insert(pending, { type = "spawn", clientID = clientID, tile = intent.tile })
		end
	elseif t == "attack" then
		local ratio = intent.ratio
		local target = intent.targetSmallID
		if type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio > 1 or not isInt(target) or target < 0 then
			return
		end
		local targetID = nil
		if target ~= 0 then
			local tp = mg:playerBySmallID(target)
			if tp == nil then
				return
			end
			targetID = tp:id()
		end
		-- Troops are computed when the intent is applied (see tick loop).
		table.insert(pending, { type = "attack", clientID = clientID, targetID = targetID, ratio = ratio })
	elseif t == "click" then
		-- Upstream ClientGameRunner.inputEvent: land attack when the tile is
		-- attackable, else an auto-boat when a launch shore is within 100 tiles.
		local tile, ratio = intent.tile, intent.ratio
		if not isInt(tile) or not mg:isValidRef(tile) or type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio > 1 then
			return
		end
		if mg:inSpawnPhase() then
			return
		end
		if me:canAttack(tile) then
			local owner = mg:owner(tile)
			table.insert(pending, { type = "attack", clientID = clientID, targetID = owner:id(), ratio = ratio })
		elseif mg:isLand(tile) then
			local spawn = me:canBuild("Transport", tile)
			if spawn ~= false and mg:euclideanDistSquared(tile, spawn) < 100 * 100 then
				table.insert(pending, { type = "boat", clientID = clientID, dst = tile, ratio = ratio })
			end
		end
	elseif t == "attack_at" or t == "boat_at" then
		-- Radial menu: centre button attack / boat slot (no auto-boat range limit).
		local tile, ratio = intent.tile, intent.ratio
		if not isInt(tile) or not mg:isValidRef(tile) or type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio > 1 then
			return
		end
		if mg:inSpawnPhase() then
			return
		end
		if t == "attack_at" then
			if me:canAttack(tile) then
				table.insert(pending, { type = "attack", clientID = clientID, targetID = mg:owner(tile):id(), ratio = ratio })
			end
		elseif mg:isLand(tile) and me:canBuild("Transport", tile) ~= false then
			table.insert(pending, { type = "boat", clientID = clientID, dst = tile, ratio = ratio })
		end
	elseif t == "cancel_attack" then
		if type(intent.attackID) == "string" and #intent.attackID <= 16 then
			table.insert(pending, { type = "cancel_attack", clientID = clientID, attackID = intent.attackID })
		end
	elseif t == "place" then
		-- Build menu placement: upgrade a structure in range when possible,
		-- otherwise build a new one (upstream build ghost behaviour).
		local tile, unitType = intent.tile, intent.unit
		if not isInt(tile) or not mg:isValidRef(tile) or type(unitType) ~= "string" then
			return
		end
		if not table.find(BUILDABLE, unitType) or mg:config():isUnitDisabled(unitType) then
			return
		end
		local bu = me:buildableUnits(tile, { unitType }, false)[1]
		if bu.canUpgrade ~= false then
			local amount = if intent.amount == 5 then 5 else 1 -- uiState.upgradeMultiplier
			table.insert(pending, { type = "upgrade_structure", clientID = clientID, unitId = bu.canUpgrade, amount = amount })
		elseif bu.canBuild ~= false then
			local amount = if unitType == "Atom Bomb" and intent.amount == 5 then 5 else nil
			table.insert(pending, { type = "build_unit", clientID = clientID, unit = unitType, tile = tile, amount = amount, rocketDirectionUp = intent.rocketDirectionUp ~= false })
		end
	elseif t == "move_warship" then
		-- Warship selection: move own warships' patrol point (MoveWarshipExecution
		-- checks ownership and water connectivity).
		local ids = intent.unitIds
		if type(ids) ~= "table" or #ids == 0 or #ids > 100 or not isInt(intent.tile) or not mg:isValidRef(intent.tile) then
			return
		end
		local clean = {}
		for i = 1, math.min(#ids, 100) do
			local id = ids[i]
			if isInt(id) then
				table.insert(clean, id)
			end
		end
		table.insert(pending, { type = "move_warship", clientID = clientID, unitIds = clean, tile = intent.tile })
	elseif t == "delete_at" then
		if isInt(intent.tile) and mg:isValidRef(intent.tile) then
			local u = deletableAt(me, intent.tile)
			if u then
				table.insert(pending, { type = "delete_unit", clientID = clientID, unitId = u:id() })
			end
		end
	elseif t == "cancel_boat" then
		if isInt(intent.unitID) then
			table.insert(pending, { type = "cancel_boat", clientID = clientID, unitID = intent.unitID })
		end
	else
		-- Diplomacy (PlayerPanel / radial / events). Players are addressed by
		-- smallID; the executions validate everything else.
		local function pid(smallID)
			if not isInt(smallID) or smallID <= 0 then
				return nil
			end
			local p = mg:playerBySmallID(smallID)
			return if p and p:isPlayer() and p ~= me then p:id() else nil
		end
		local target = pid(intent.target)
		if t == "alliance_request" and target then
			table.insert(pending, { type = "allianceRequest", clientID = clientID, recipient = target })
		elseif t == "alliance_reject" and target then
			table.insert(pending, { type = "allianceReject", clientID = clientID, requestor = target })
		elseif t == "break_alliance" and target then
			table.insert(pending, { type = "breakAlliance", clientID = clientID, recipient = target })
		elseif t == "alliance_extend" and target then
			table.insert(pending, { type = "allianceExtension", clientID = clientID, recipient = target })
		elseif t == "target_player" and target then
			table.insert(pending, { type = "targetPlayer", clientID = clientID, target = target })
		elseif t == "emoji" and isInt(intent.emoji) and intent.emoji >= 0 then
			local recipient = if intent.target == 0 then GameTypes.AllPlayers else target
			if recipient then
				table.insert(pending, { type = "emoji", clientID = clientID, recipient = recipient, emoji = intent.emoji })
			end
		elseif (t == "donate_troops" or t == "donate_gold") and target then
			local amount = intent.amount
			if type(amount) == "number" and amount == amount and amount > 0 and amount < 1e15 then
				amount = math.floor(amount)
				if t == "donate_troops" then
					table.insert(pending, { type = "donate_troops", clientID = clientID, recipient = target, troops = amount })
				else
					table.insert(pending, { type = "donate_gold", clientID = clientID, recipient = target, gold = amount })
				end
			end
		elseif t == "embargo" and target and (intent.action == "start" or intent.action == "stop") then
			table.insert(pending, { type = "embargo", clientID = clientID, targetID = target, action = intent.action })
		elseif t == "embargo_all" and (intent.action == "start" or intent.action == "stop") then
			table.insert(pending, { type = "embargo_all", clientID = clientID, action = intent.action })
		elseif t == "quick_chat" and target and type(intent.key) == "string" and #intent.key <= 64 then
			local chatTarget = pid(intent.chatTarget)
			table.insert(pending, { type = "quick_chat", clientID = clientID, recipient = target, quickChatKey = intent.key, target = chatTarget })
		end
	end
end)

-- Tick loop -----------------------------------------------------------------------

-- Control panel / hotbar / tutorial data for one human (upstream reads these
-- from its local game view): prices, max troops, troop growth per second,
-- troops out in attacks, and every BORDER_EVERY ticks who we border and
-- whether we own coast (TutorialPanel.refreshBordering).
local BORDER_EVERY = 10
-- Humans that had an outgoing attack on any tick since their last Me message
-- (upstream's tutorial samples every tick; short attacks must not be missed).
local sawAttack = {}
local function attackRows(attacks, incoming: boolean)
	local rows = {}
	for _, a in attacks do
		local other = if incoming then a:attacker() else a:target()
		local row = {
			id = a:id(),
			other = if other:isPlayer() then other:smallID() else 0,
			troops = a:troops(),
			retreating = a:retreating(),
		}
		-- Front-line troop labels (AttackingTroopsController): player vs
		-- player only, incoming attacks from tribes are not labelled.
		if other:isPlayer() and not (incoming and other:type() == "BOT") then
			row.front = a:clusteredPositions()
		end
		table.insert(rows, row)
	end
	return rows
end

local function meInfo(me, withBorders: boolean)
	local config = mg:config()
	local costs, disabled = {}, {}
	for _, u in BUILDABLE do
		costs[u] = config:unitInfo(u).cost(mg, me)
		disabled[u] = config:isUnitDisabled(u) or nil
	end
	local attackingTroops, attacking = 0, sawAttack[me] == true
	sawAttack[me] = nil
	for _, a in me:outgoingAttacks() do
		attackingTroops += a:troops()
		attacking = true
	end
	local info = {
		costs = costs,
		disabled = disabled,
		maxTroops = config:maxTroops(me),
		troopRate = config:troopIncreaseRate(me) * 10,
		attackingTroops = attackingTroops,
		attacking = attacking,
		allied = #me:alliances() > 0,
		-- AttacksDisplay: { id, other (smallID, 0 = wilderness), troops, retreating }.
		incoming = attackRows(me:incomingAttacks(), true),
		outgoing = attackRows(me:outgoingAttacks(), false),
		spawnTile = me:spawnTile(),
		-- ActionableEvents / PlayerPanel: our alliances and who still asks us.
		alliances = (function()
			local rows = {}
			for _, a in me:alliances() do
				local other = a:other(me)
				local info = me:allianceInfo(other)
				table.insert(rows, {
					id = a:id(),
					other = other:smallID(),
					expiresAt = a:expiresAt(),
					inExtensionWindow = info and info.inExtensionWindow,
					canExtend = info and info.canExtend,
				})
			end
			return rows
		end)(),
		requestsIn = (function()
			local ids = {}
			for _, r in me:incomingAllianceRequests() do
				table.insert(ids, r:requestor():smallID())
			end
			return ids
		end)(),
		extensionPromptOffset = config:allianceExtensionPromptOffset(),
		traitorTicks = if me:isTraitor() then me:getTraitorRemainingTicks() else 0,
		-- Name icons from our point of view: transitive targets and embargoes
		-- in either direction (PlayerView.hasEmbargo).
		targets = (function()
			local ids = {}
			for _, t in me:transitiveTargets() do
				table.insert(ids, t:smallID())
			end
			return ids
		end)(),
		embargoes = (function()
			local ids = {}
			for _, p in mg:players() do
				if p ~= me and (me:hasEmbargoAgainst(p) or p:hasEmbargoAgainst(me)) then
					table.insert(ids, p:smallID())
				end
			end
			return ids
		end)(),
		tick = mg:ticks(),
	}
	if withBorders then
		local myID = me:smallID()
		local seen, bordering, coast = {}, {}, false
		for t in me:borderTiles() do
			if mg:isShore(t) then
				coast = true
			end
			for _, n in mg:neighbors(t) do
				local owner = mg:ownerID(n)
				if owner ~= 0 and owner ~= myID and not seen[owner] then
					seen[owner] = true
					table.insert(bordering, owner)
				end
			end
		end
		info.bordering = bordering
		info.hasCoast = coast
	end
	return info
end

local function playerForSmallID(smallID: number): Player?
	local p = mg:playerBySmallID(smallID)
	local clientID = p and p:isPlayer() and p:clientID()
	if not clientID then
		return nil
	end
	for _, plr in Players:GetPlayers() do
		if clientIDOf(plr) == clientID then
			return plr
		end
	end
	return nil
end

local function playerNameBySmallID(smallID: number): string
	local p = mg:playerBySmallID(smallID)
	return if p and p:isPlayer() then p:displayName() else ""
end

local function sendMessage(playerSmallID: number?, evt)
	if playerSmallID == nil then
		Net.Event:FireAllClients(evt)
		return
	end
	local plr = playerForSmallID(playerSmallID)
	if plr then
		Net.Event:FireClient(plr, evt)
	end
end

-- Gold pop next to the gold counter (upstream ControlPanel.addGoldGain).
local function sendGoldGain(playerID, gold: number)
	if gold <= 0 then
		return
	end
	local p = mg:player(playerID)
	local clientID = p and p:clientID()
	if clientID == nil then
		return
	end
	for _, plr in Players:GetPlayers() do
		if clientIDOf(plr) == clientID then
			Net.Event:FireClient(plr, { type = "GoldGain", gold = gold })
		end
	end
end

-- Latest state per unit this tick, sent as one Units message.
local unitChanges, unitOrder = {}, {}
-- Last full state sent per unit; a change that only moves the unit goes to
-- the compact UnitPos stream instead (flushed every POS_EVERY ticks).
local lastSentUnit: { [number]: any } = {}
local posPending: { [number]: number } = {}
local posPendingSlow: { [number]: number } = {}
local POS_EVERY = 2
-- Trade ships and trains (most moving units late in a match, and nobody
-- steers them) are batched half as often.
local POS_EVERY_SLOW = 4
local SLOW_POS = { ["Trade Ship"] = true, Train = true }
local COMPARE_FIELDS = { "unitType", "ownerID", "troops", "isActive", "isRetreating", "level", "underConstruction", "markedForDeletion", "reachedTarget", "targetTile", "health", "maxHealth", "targetable", "targetUnitId", "warshipRetreating", "trainType", "loaded", "reloadTicks", "buildStart", "buildTicks", "plan" }
local function sameArray(a, b): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end
local function onlyMoved(c, prev): boolean
	if prev == nil or c.plan ~= nil then
		return false
	end
	for _, k in COMPARE_FIELDS do
		if c[k] ~= prev[k] then
			return false
		end
	end
	return sameArray(c.missileTimers, prev.missileTimers)
end
-- Units flying on a motion plan (nukes): sent once with the plan, then only
-- when they end; clients replay the path themselves.
local planSent = {}
-- Rail changes this tick (see railroads).
local railAdds, railRemoves = {}, {}

local nukeTypes = { ["Atom Bomb"] = true, ["Hydrogen Bomb"] = true, MIRV = true }
local nukeSeen = {}

local function handleUpdates(updates)
	table.clear(unitChanges)
	table.clear(unitOrder)
	table.clear(railAdds)
	table.clear(railRemoves)
	for _, u in updates do
		if u.type == "Unit" then
			-- "Nuclear Option" badge: a human's first launch.
			if u.isActive and nukeTypes[u.unitType] and not nukeSeen[u.id] then
				nukeSeen[u.id] = true
				local owner = mg:playerBySmallID(u.ownerID)
				if owner and owner:isPlayer() and owner:type() == "HUMAN" then
					Progress.award(tonumber(owner:clientID()) :: number, "nuke")
				end
			end
			local plan = mg:motionPlan(u.id)
			if plan and u.isActive and planSent[u.id] and unitChanges[u.id] == nil then
				continue -- in flight: the client already has the plan
			end
			if not u.isActive then
				planSent[u.id] = nil
				mg:clearMotionPlan(u.id)
			elseif plan then
				planSent[u.id] = true
			end
			if unitChanges[u.id] == nil then
				table.insert(unitOrder, u.id)
			end
			local bStart, bTicks = buildInfo(u)
			if not u.isActive then
				buildStart[u.id] = nil
			end
			unitChanges[u.id] = {
				buildStart = bStart,
				buildTicks = bTicks,
				id = u.id,
				unitType = u.unitType,
				ownerID = u.ownerID,
				pos = u.pos,
				troops = u.troops,
				isActive = u.isActive,
				isRetreating = u.isRetreating,
				level = u.level,
				underConstruction = u.underConstruction,
				markedForDeletion = u.markedForDeletion ~= false,
				reachedTarget = u.reachedTarget,
				targetTile = u.targetTile,
				health = u.health,
				maxHealth = u.maxHealth,
				targetable = u.targetable,
				targetUnitId = u.targetUnitId,
				warshipRetreating = u.warshipRetreating,
				trainType = u.trainType,
				loaded = u.loaded,
				missileTimers = u.missileTimers,
				reloadTicks = u.reloadTicks,
				plan = if u.isActive then plan else nil,
			}
		end
		if u.type == "RailroadConstructionEvent" then
			railroads[u.id] = u.tiles
			table.insert(railAdds, { id = u.id, tiles = u.tiles })
		elseif u.type == "RailroadDestructionEvent" then
			if railroads[u.id] then
				railroads[u.id] = nil
				table.insert(railRemoves, u.id)
			end
		elseif u.type == "RailroadSnapEvent" then
			if railroads[u.originalId] then
				railroads[u.originalId] = nil
				table.insert(railRemoves, u.originalId)
			end
			railroads[u.newId1] = u.tiles1
			railroads[u.newId2] = u.tiles2
			table.insert(railAdds, { id = u.newId1, tiles = u.tiles1 })
			table.insert(railAdds, { id = u.newId2, tiles = u.tiles2 })
		end
		if u.type == "SpawnPhaseEnd" then
			-- A match counts as played once the spawn phase is over.
			for _, p in mg:players() do
				local userId = p:type() == "HUMAN" and tonumber(p:clientID())
				local data = userId and Profiles.get(userId)
				if data then
					data.stats.games += 1
					Profiles.markDirty(userId)
					Progress.checkStats(userId, data.stats)
				end
			end
			Net.Event:FireAllClients({ type = "SpawnPhaseEnd", tick = u.startTick })
		elseif u.type == "Win" then
			local w = u.winner
			Net.Event:FireAllClients({
				type = "Win",
				winnerName = if type(w) == "table" then w:displayName() else tostring(w),
				winnerSmallID = if type(w) == "table" then w:smallID() else nil,
			})
		elseif u.type == "ConquestEvent" then
			-- Conquest popup (WorldTextPass): "+ gold" at the conquered player's name.
			Net.Event:FireAllClients({
				type = "Conquest",
				conqueror = mg:player(u.conquerorId):smallID(),
				conquered = mg:player(u.conqueredId):smallID(),
				gold = u.gold or 0,
			})
			sendGoldGain(u.conquerorId, u.gold or 0)
		elseif u.type == "BonusEvent" then
			sendGoldGain(u.player, u.gold or 0)
			-- Bonus popup ("+ 45K" rising over the port tile).
			if u.tile and (u.gold or 0) ~= 0 then
				Net.Event:FireAllClients({ type = "Bonus", tile = u.tile, gold = u.gold })
			end
		elseif u.type == "DisplayEvent" then
			sendMessage(u.playerID, {
				type = "Message",
				message = u.message,
				messageType = u.messageType,
				params = u.params,
				focusPlayerID = u.focusPlayerID,
				unitID = u.unitID,
			})
		elseif u.type == "AllianceRequest" then
			sendMessage(u.recipientID, { type = "AllianceRequest", requestor = u.requestorID, duration = mg:config():allianceRequestDuration() })
		elseif u.type == "AllianceRequestReply" then
			local r = u.request
			sendMessage(r.requestorID, {
				type = "Message",
				message = "events_display.alliance_request_status",
				params = { name = playerNameBySmallID(r.recipientID), status = if u.accepted then "accepted" else "rejected" },
				messageType = if u.accepted then 13 else 14,
				focusPlayerID = r.recipientID,
			})
			sendMessage(r.recipientID, { type = "AllianceRequestResolved", requestor = r.requestorID })
		elseif u.type == "BrokeAlliance" then
			local betrayed = mg:playerBySmallID(u.betrayedID)
			local traitor = mg:playerBySmallID(u.traitorID)
			sendMessage(u.traitorID, { type = "AllianceGone", allianceID = u.allianceID })
			sendMessage(u.betrayedID, { type = "AllianceGone", allianceID = u.allianceID })
			if betrayed and traitor and not betrayed:isDisconnected() then
				if not betrayed:isTraitor() then
					local config = mg:config()
					local secs = math.floor(config:traitorDuration() * 0.1)
					sendMessage(u.traitorID, {
						type = "Message",
						message = "events_display.betrayal_description",
						params = {
							name = betrayed:displayName(),
							malusPercent = math.floor((1 - config:traitorDefenseDebuff()) * 100 + 0.5),
							durationText = if secs == 1 then "1 second" else `{secs} seconds`,
						},
						messageType = 16,
						focusPlayerID = u.betrayedID,
					})
				end
				sendMessage(u.betrayedID, {
					type = "Message",
					message = "events_display.betrayed_you",
					params = { name = traitor:displayName() },
					messageType = 16,
					focusPlayerID = u.traitorID,
				})
			end
		elseif u.type == "AllianceExpired" then
			local a, b = mg:playerBySmallID(u.player1ID), mg:playerBySmallID(u.player2ID)
			if a and b and a:isAlive() and b:isAlive() then
				for _, pair in { { u.player1ID, b }, { u.player2ID, a } } do
					sendMessage(pair[1], {
						type = "Message",
						message = "events_display.alliance_expired",
						params = { name = pair[2]:displayName() },
						messageType = 17,
						focusPlayerID = pair[2]:smallID(),
					})
				end
			end
		elseif u.type == "AllianceExtension" then
			sendMessage(u.playerID, { type = "AllianceExtended", allianceID = u.allianceID })
		elseif u.type == "DonateEvent" then
			local sender, recipient = mg:player(u.senderId), mg:player(u.recipientId)
			local isGold = u.donationType == "gold"
			local amount = if isGold then Format.renderNumber(u.amount) else Format.renderTroops(u.amount)
			sendMessage(recipient:smallID(), {
				type = "Message",
				message = if isGold then "events_display.received_gold_from_player" else "events_display.received_troops_from_player",
				params = { name = sender:displayName(), gold = amount, troops = amount },
				messageType = 19,
				focusPlayerID = sender:smallID(),
			})
			sendMessage(sender:smallID(), {
				type = "Message",
				message = if isGold then "events_display.sent_gold_to_player" else "events_display.sent_troops_to_player",
				params = { name = recipient:displayName(), gold = amount, troops = amount },
				messageType = 18,
				focusPlayerID = recipient:smallID(),
			})
		elseif u.type == "TargetPlayer" then
			local targeter = mg:playerBySmallID(u.playerID)
			local target = mg:playerBySmallID(u.targetID)
			for _, p in mg:players() do
				if p:type() == "HUMAN" and p:isFriendly(targeter) then
					sendMessage(p:smallID(), {
						type = "Message",
						message = "events_display.attack_request",
						params = { name = targeter:displayName(), target = target:displayName() },
						messageType = 2,
						focusPlayerID = u.targetID,
						keepNames = true,
					})
				end
			end
			-- Target marker over the target's name for the targeter's friends.
			Net.Event:FireAllClients({ type = "Target", player = u.playerID, target = u.targetID, tick = mg:ticks() })
		elseif u.type == "Emoji" then
			local e = u.emoji
			local toAll = e.recipientID == GameTypes.AllPlayers
			local sender = mg:playerBySmallID(e.senderID)
			if not toAll then
				sendMessage(e.recipientID, {
					type = "Message",
					message = `{sender:displayName()}: {e.message}`,
					messageType = 20,
					focusPlayerID = e.senderID,
					raw = true,
				})
				local recipient = mg:playerBySmallID(e.recipientID)
				sendMessage(e.senderID, {
					type = "Message",
					message = "events_display.sent_emoji",
					params = { name = recipient:displayName(), emoji = e.message },
					messageType = 20,
					focusPlayerID = e.recipientID,
				})
			end
			-- Emoji bubble over the sender's name (NameLayer), for its recipients.
			Net.Event:FireAllClients({ type = "Emoji", sender = e.senderID, recipient = if toAll then 0 else e.recipientID, message = e.message, tick = e.createdAt })
		elseif u.type == "DisplayChatEvent" then
			if u.playerID ~= nil then
				local other = mg:player(u.recipient)
				local chatTarget = if u.target then mg:player(u.target) else nil
				sendMessage(u.playerID, {
					type = "Chat",
					category = u.category,
					key = u.key,
					isFrom = u.isFrom,
					other = other and other:displayName(),
					otherSmallID = other and other:smallID(),
					target = chatTarget and chatTarget:displayName(),
				})
			end
		elseif u.type == "UnitIncoming" then
			sendMessage(u.playerID, { type = "Incoming", unitID = u.unitID, message = u.message, messageType = u.messageType })
		end
	end
	if #railAdds > 0 or #railRemoves > 0 then
		-- Removals first: a snap removes the old id and adds two new ones.
		Net.Event:FireAllClients({ type = "Rail", remove = railRemoves, add = railAdds })
	end
	if #unitOrder > 0 then
		-- Split: full states for anything but a plain move.
		local full = table.create(#unitOrder)
		for _, id in unitOrder do
			local c = unitChanges[id]
			if onlyMoved(c, lastSentUnit[id]) then
				if SLOW_POS[c.unitType] then
					posPendingSlow[id] = c.pos
				else
					posPending[id] = c.pos
				end
				lastSentUnit[id].pos = c.pos
			else
				posPending[id] = nil
				posPendingSlow[id] = nil
				lastSentUnit[id] = if c.isActive then c else nil
				table.insert(full, id)
			end
		end
		unitOrder = full
	end
	local flushFast = mg:ticks() % POS_EVERY == 0 and next(posPending) ~= nil
	local flushSlow = mg:ticks() % POS_EVERY_SLOW == 0 and next(posPendingSlow) ~= nil
	if flushFast or flushSlow then
		local ids, positions = {}, {}
		if flushFast then
			for id, pos in posPending do
				table.insert(ids, id)
				table.insert(positions, pos)
			end
			table.clear(posPending)
		end
		if flushSlow then
			for id, pos in posPendingSlow do
				table.insert(ids, id)
				table.insert(positions, pos)
			end
			table.clear(posPendingSlow)
		end
		Net.UnitPos:FireAllClients(Net.packUnitPos(ids, positions))
	end
	if #unitOrder > 0 then
		local list = table.create(#unitOrder)
		for i, id in unitOrder do
			list[i] = unitChanges[id]
		end
		Net.Units:FireAllClients(list)
	end
end

local lastTile, order, states = {}, {}, {}


local function runTick()
	-- Resolve attack troops against current troop counts.
	if LoadTest then
		LoadTest.drive(mg, FAKE_HUMANS, function(it)
			table.insert(pending, it)
		end)
	end
	local intents = pending
	pending = {}
	table.clear(intentCount)
	-- Surrender / Rebirth are not upstream intents: applied here, between ticks.
	for i = #intents, 1, -1 do
		local it = intents[i]
		if it.type == "surrender" or it.type == "rebirth" then
			table.remove(intents, i)
			local p = mg:playerByClientID(it.clientID)
			if p and it.type == "surrender" and p:isAlive() then
				-- Give up: the land goes neutral; PlayerExecution then handles
				-- the death (units, alliances) like any other.
				for _, tile in p:tiles():toArray() do
					mg:relinquish(tile)
				end
				p:setTroops(0)
			elseif p and it.type == "rebirth" then
				applyRebirth(p)
			end
		end
	end
	-- Several clicks can land in one tick; upstream's client prices each one
	-- against the troops left after the previous send, so do the same here
	-- (otherwise five 20 % clicks would send the whole army).
	local remaining = {}
	for _, intent in intents do
		if (intent.type == "attack" or intent.type == "boat") and intent.ratio then
			local me = mg:playerByClientID(intent.clientID)
			if me then
				local left = remaining[me] or me:troops()
				intent.troops = left * intent.ratio
				remaining[me] = left - intent.troops
			else
				intent.troops = 0
			end
		end
	end

	local wasInSpawnPhase = mg:inSpawnPhase()
	local updates = runner:executeNextTick(intents)
	checkHumanDeaths()
	local tick = mg:ticks()

	-- Roster before tiles, so clients know a new player's colour before
	-- drawing their first territory.
	if #mg:allPlayers() > rosterSent then
		Net.Roster:FireAllClients(newRosterEntries())
	end

	-- Tile deltas: keep the last state per tile this tick.
	local flat = mg:tileUpdates()
	table.clear(lastTile)
	table.clear(order)
	table.clear(states)
	for i = 1, #flat, 2 do
		local t = flat[i]
		if lastTile[t] == nil then
			table.insert(order, t)
		end
		lastTile[t] = flat[i + 1] % 65536
	end
	if #order > 0 then
		for i, t in order do
			states[i] = lastTile[t]
		end
		Net.Tick:FireAllClients(Net.packTiles(tick, order, states))
	end

	for _, plr in Players:GetPlayers() do
		local me = mg:playerByClientID(clientIDOf(plr))
		if me and #me:outgoingAttacks() > 0 then
			sawAttack[me] = true
		end
	end

	if tick % STATS_EVERY == 0 then
		Net.Stats:FireAllClients(Net.packStats(tick, statsRows()))
		broadcastFlags()
		for _, plr in Players:GetPlayers() do
			local me = mg:playerByClientID(clientIDOf(plr))
			if me and me:isAlive() then
				Net.Me:FireClient(plr, meInfo(me, tick % BORDER_EVERY == 0))
			end
		end
	end
	updateNames(wasInSpawnPhase)
	handleUpdates(updates)
	return mg:getWinner() == nil
end

local NEXT_MATCH_SECONDS = 20

-- The match is over: tell clients, then restart this script for a new match
-- (a fresh clone re-runs the lobby; the destroyed one takes its connections
-- with it). TODO(port): lobby / matchmaking across servers.
local function recordStats()
	local winner = mg:getWinner()
	local land = mg:numLandTiles()
	for _, p in mg:allPlayers() do
		local userId = p:type() == "HUMAN" and tonumber(p:clientID())
		local data = userId and Profiles.get(userId)
		if data then
			if winner == p then
				data.stats.wins += 1
				Progress.recordWins(userId, data.stats.wins)
			end
			Progress.checkStats(userId, data.stats)
			data.stats.bestPct = math.max(data.stats.bestPct, math.floor(p:numTilesOwned() / math.max(1, land) * 1000) / 10)
			Profiles.markDirty(userId)
		end
	end
end

local function endMatch()
	recordStats()
	Net.Event:FireAllClients({ type = "MatchEnding", seconds = NEXT_MATCH_SECONDS })
	task.delay(NEXT_MATCH_SECONDS, function()
		Net.Event:FireAllClients({ type = "MatchReset" })
		local fresh = script:Clone()
		fresh.Parent = script.Parent
		script:Destroy()
	end)
end

local accumulator = 0
local running = true
local perfWindow = { n = 0, total = 0, max = 0, slow = 0, t = os.clock() }
RunService.Heartbeat:Connect(function(dt)
	if lobby.soloReset and script.Parent then
		lobby.soloReset = false
		running = false
		Net.Event:FireAllClients({ type = "MatchReset" })
		local fresh = script:Clone()
		fresh:SetAttribute("Settings", HttpService:JSONEncode(lobby.settings))
		fresh.Parent = script.Parent
		script:Destroy()
		return
	end
	if not running then
		return
	end
	accumulator += dt
	-- Catch up at most 3 ticks per frame so a hitch can't snowball.
	local steps = 0
	while accumulator >= TICK_STEP and steps < 3 * TICK_SPEED do
		accumulator -= TICK_STEP
		steps += 1
		local t0 = os.clock()
		running = runTick()
		local ms = (os.clock() - t0) * 1000
		tickPerf.n += 1
		tickPerf.total += ms
		tickPerf.max = math.max(tickPerf.max, ms)
		if ms > 100 then
			tickPerf.slow += 1
		end
		-- Once a minute: tick cost summary in the server log (F9 console on live
		-- servers), for diagnosing lag reports.
		Telemetry.tick(ms)
		perfWindow.n += 1
		perfWindow.total += ms
		perfWindow.max = math.max(perfWindow.max, ms)
		if ms > 100 then
			perfWindow.slow += 1
		end
		if os.clock() - perfWindow.t >= 60 then
			print(string.format("[Perf] tick %d: avg %.1f ms, max %.0f ms, %d/%d ticks over 100 ms, %d units, %d humans, Lua %d MB", mg:ticks(), perfWindow.total / perfWindow.n, perfWindow.max, perfWindow.slow, perfWindow.n, #mg:units(), #Players:GetPlayers(), collectgarbage("count") // 1024))
			perfWindow.n, perfWindow.total, perfWindow.max, perfWindow.slow, perfWindow.t = 0, 0, 0, 0, os.clock()
			local alive = 0
			for _, pl in mg:players() do
				if pl:type() == "HUMAN" then
					alive += 1
				end
			end
			Telemetry.flush({ mode = lobby.mode, map = MAP_ID, tick = mg:ticks(), units = #mg:units(), players = #Players:GetPlayers(), alive = alive })
		end
		if not running then
			endMatch()
			break
		end
	end
	if accumulator > TICK_STEP * 3 * TICK_SPEED then
		accumulator = 0
	end
end)
