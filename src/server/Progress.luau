-- Badges and the global wins leaderboard (Roblox-side progression; not in
-- upstream). Every call is best effort: badge and DataStore outages must
-- never break a match.

local BadgeService = game:GetService("BadgeService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Progress = {}

Progress.BADGES = {
	welcome = 3265846566875513, -- play your first match
	firstWin = 4286641177796228, -- win a match
	nuke = 1992196869727033, -- launch a nuke
	veteran = 2310544451169131, -- play 25 matches
	warlord = 1529243694401040, -- win 10 matches
}
local VETERAN_GAMES = 25
local WARLORD_WINS = 10
Progress.VETERAN_GAMES, Progress.WARLORD_WINS = VETERAN_GAMES, WARLORD_WINS

local awarded: { [string]: boolean } = {} -- "userId:key" this server

-- Award a badge once per server session (Roblox ignores repeats anyway).
function Progress.award(userId: number, key: string)
	local id = Progress.BADGES[key]
	local tag = userId .. ":" .. key
	if id == nil or awarded[tag] then
		return
	end
	awarded[tag] = true
	task.spawn(function()
		local ok, has = pcall(BadgeService.UserHasBadgeAsync, BadgeService, userId, id)
		if ok and has then
			return
		end
		local okAward, err = pcall(BadgeService.AwardBadge, BadgeService, userId, id)
		if not okAward then
			awarded[tag] = nil
			warn("[Progress] badge", key, err)
		end
	end)
end

-- Badges that follow from the profile stats.
function Progress.checkStats(userId: number, stats)
	if (stats.games or 0) >= 1 then
		Progress.award(userId, "welcome")
	end
	if (stats.games or 0) >= VETERAN_GAMES then
		Progress.award(userId, "veteran")
	end
	if (stats.wins or 0) >= 1 then
		Progress.award(userId, "firstWin")
	end
	if (stats.wins or 0) >= WARLORD_WINS then
		Progress.award(userId, "warlord")
	end
end

-- Global leaderboard ------------------------------------------------------------

local winsStore = nil
pcall(function()
	winsStore = DataStoreService:GetOrderedDataStore("Wins_v1")
end)

function Progress.recordWins(userId: number, wins: number)
	if winsStore == nil then
		return
	end
	task.spawn(function()
		pcall(winsStore.SetAsync, winsStore, tostring(userId), wins)
	end)
end

local names: { [number]: string } = {}
local function nameOf(userId: number): string
	if names[userId] == nil then
		local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
		names[userId] = if ok and name then name else "?"
	end
	return names[userId]
end

local top: { { name: string, wins: number } } = {}
local topAt = -math.huge
local refreshing = false

-- Top 10 by wins, refreshed at most every 2 minutes in the background.
function Progress.top(): { { name: string, wins: number } }
	if winsStore and not refreshing and os.clock() - topAt > 120 then
		refreshing = true
		task.spawn(function()
			local ok, pages = pcall(winsStore.GetSortedAsync, winsStore, false, 10)
			if ok and pages then
				local rows = {}
				for _, e in pages:GetCurrentPage() do
					local id = tonumber(e.key)
					if id and e.value > 0 then
						table.insert(rows, { name = nameOf(id), wins = e.value })
					end
				end
				top = rows
			end
			topAt = os.clock()
			refreshing = false
		end)
	end
	return top
end

return Progress
