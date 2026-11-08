-- Cross-server matchmaking (Roblox side; upstream's lobby server has no
-- counterpart here).
--
-- Every public server runs matches back to back: a 60 s lobby, the match,
-- then a new lobby. While a server is in its lobby it lists itself in a
-- MemoryStore sorted map, so players who land in a match that is already
-- running (or who died) can be sent to a lobby that is about to start.
-- When no lobby is listed, a fresh reserved server is created and acts as a
-- public lobby. "Create private match" reserves a server whose lobby is run
-- by the player who created it.
--
-- Nothing here works in Studio (no TeleportService / MemoryStore there);
-- callers check Matchmaking.available().

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Matchmaking = {}

local LIST_NAME = "OpenFrontLobbies"
local ENTRY_TTL = 30 -- seconds; refreshed every few seconds while listed
local MIN_SECONDS_LEFT = 12 -- don't send players to a lobby about to start

local lobbies = nil
pcall(function()
	lobbies = MemoryStoreService:GetSortedMap(LIST_NAME)
end)

function Matchmaking.available(): boolean
	return not RunService:IsStudio() and lobbies ~= nil
end

-- What kind of server this is, from the first player's teleport data:
--   "custom"  – a private match created with "Create private match" (host
--               in TeleportData), or a VIP server (host = owner)
--   "public"  – everything else, including reserved overflow lobbies.
function Matchmaking.serverKind(): (string, number?)
	if game.PrivateServerOwnerId ~= 0 then
		return "custom", game.PrivateServerOwnerId
	end
	if game.PrivateServerId ~= "" then
		for _, p in Players:GetPlayers() do
			local data = p:GetJoinData().TeleportData
			if type(data) == "table" and data.solo then
				return "solo", tonumber(data.host)
			elseif type(data) == "table" and data.custom then
				return "custom", tonumber(data.host)
			end
		end
	end
	return "public", nil
end

-- This server's listing key and how others reach it.
local function selfEntry()
	if game.PrivateServerId ~= "" then
		return { kind = "reserved", code = Matchmaking.accessCode }
	end
	return { kind = "public", jobId = game.JobId }
end

-- Reserved servers only learn their access code from the teleport data we
-- attach when creating them.
function Matchmaking.learnAccessCode()
	for _, p in Players:GetPlayers() do
		local data = p:GetJoinData().TeleportData
		if type(data) == "table" and type(data.code) == "string" then
			Matchmaking.accessCode = data.code
			return
		end
	end
end

-- List (or refresh) this server as a lobby starting at unix time startsAt.
function Matchmaking.publish(startsAt: number, players: number, maxPlayers: number)
	if not Matchmaking.available() then
		return
	end
	local entry = selfEntry()
	if entry.kind == "reserved" and not entry.code then
		return -- unreachable without its code
	end
	entry.startsAt = startsAt
	entry.players = players
	entry.max = maxPlayers
	pcall(function()
		-- Sort key: fuller lobbies first so players gather.
		lobbies:SetAsync(game.JobId, entry, ENTRY_TTL, -players)
	end)
end

function Matchmaking.unpublish()
	if not Matchmaking.available() then
		return
	end
	pcall(function()
		lobbies:RemoveAsync(game.JobId)
	end)
end

local function teleportToEntry(player: Player, entry): boolean
	local ok = pcall(function()
		if entry.kind == "reserved" then
			TeleportService:TeleportToPrivateServer(game.PlaceId, entry.code, { player }, nil, { code = entry.code })
		else
			TeleportService:TeleportToPlaceInstance(game.PlaceId, entry.jobId, player)
		end
	end)
	return ok
end

-- A new reserved server acting as a public lobby.
local function newPublicLobby(player: Player): boolean
	return (pcall(function()
		local code = TeleportService:ReserveServer(game.PlaceId)
		TeleportService:TeleportToPrivateServer(game.PlaceId, code, { player }, nil, { code = code, publicLobby = true })
	end))
end

-- Send `player` to the best open lobby elsewhere (or a new one).
function Matchmaking.findMatch(player: Player): boolean
	if not Matchmaking.available() then
		return false
	end
	local now = os.time()
	local items = nil
	pcall(function()
		items = lobbies:GetRangeAsync(Enum.SortDirection.Ascending, 50)
	end)
	for _, item in items or {} do
		local e = item.value
		if item.key ~= game.JobId and type(e) == "table" and e.players < e.max and e.startsAt - now >= MIN_SECONDS_LEFT then
			if teleportToEntry(player, e) then
				return true
			end
		end
	end
	return newPublicLobby(player)
end

-- A private match hosted by `player` (they pick the settings and start it).
function Matchmaking.createPrivate(player: Player, duel: boolean?): boolean
	if not Matchmaking.available() then
		return false
	end
	return (pcall(function()
		local code = TeleportService:ReserveServer(game.PlaceId)
		TeleportService:TeleportToPrivateServer(game.PlaceId, code, { player }, nil, { code = code, custom = true, host = player.UserId, duel = duel == true })
	end))
end

-- Singleplayer: a reserved server just for `player` (picks a map, starts).
function Matchmaking.createSolo(player: Player, settings: { [string]: any }?): boolean
	if not Matchmaking.available() then
		return false
	end
	return (pcall(function()
		local code = TeleportService:ReserveServer(game.PlaceId)
		TeleportService:TeleportToPrivateServer(game.PlaceId, code, { player }, nil, { code = code, solo = true, host = player.UserId, settings = settings })
	end))
end

-- Join codes for private matches: 6 letters/digits mapped to the reserved
-- server access code, kept while the lobby exists.
local CODE_TTL = 3 * 60 * 60
local CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" -- no 0/O/1/I
local codes = nil
pcall(function()
	codes = MemoryStoreService:GetSortedMap("OpenFrontJoinCodes")
end)

function Matchmaking.registerJoinCode(): string?
	if not Matchmaking.available() or not codes or not Matchmaking.accessCode then
		return nil
	end
	local rng = Random.new()
	for _ = 1, 5 do
		local chars = table.create(6)
		for i = 1, 6 do
			local k = rng:NextInteger(1, #CODE_CHARS)
			chars[i] = string.sub(CODE_CHARS, k, k)
		end
		local code = table.concat(chars)
		local fresh = false
		pcall(function()
			codes:UpdateAsync(code, function(old)
				if old ~= nil then
					return nil -- taken: leave it alone
				end
				fresh = true
				return Matchmaking.accessCode
			end, CODE_TTL)
		end)
		if fresh then
			return code
		end
	end
	return nil
end

function Matchmaking.joinByCode(player: Player, code: string): boolean
	if not Matchmaking.available() or not codes then
		return false
	end
	local access = nil
	pcall(function()
		access = codes:GetAsync(string.upper(code))
	end)
	if type(access) ~= "string" then
		return false
	end
	return (pcall(function()
		TeleportService:TeleportToPrivateServer(game.PlaceId, access, { player }, nil, { code = access, custom = true })
	end))
end

return Matchmaking
