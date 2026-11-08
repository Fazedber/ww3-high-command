-- Port of OpenFrontIO src/core/game/TeamAssignment.ts: splitting players
-- into teams (pinned slots, clans together, friends preferred, nations
-- shuffled last) and resolving the team list from the lobby setting.

local Shared = game:GetService("ReplicatedStorage").Shared
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local GameTypes = require(script.Parent.GameTypes)

local ColoredTeams = GameTypes.ColoredTeams
local PlayerType = GameTypes.PlayerType

local TeamAssignment = {}

function TeamAssignment.getMaxTeamSize(numPlayers: number, numTeams: number): number
	return math.ceil(numPlayers / numTeams)
end

-- Returns a list of { player = PlayerInfo, team = Team | "kicked" } in the
-- order upstream's Map receives them (its iteration order).
function TeamAssignment.assignTeams(players, teams: { string }, isDuosTriosQuads: boolean, maxTeamSize: number?)
	maxTeamSize = maxTeamSize or TeamAssignment.getMaxTeamSize(#players, #teams)
	local order, result = {}, {}
	local function set(p, team)
		if result[p] == nil then
			table.insert(order, p)
		end
		result[p] = team
	end
	local teamPlayerCount = {}
	local function count(t)
		return teamPlayerCount[t] or 0
	end

	-- Matchmade pins (teamIndex), honoured unconditionally.
	local unpinned = {}
	for _, p in players do
		local pinned = if p.teamIndex ~= nil then teams[p.teamIndex + 1] else nil
		if pinned == nil then
			table.insert(unpinned, p)
			continue
		end
		set(p, pinned)
		teamPlayerCount[pinned] = count(pinned) + 1
	end

	-- Clans are strict: all on one team, overflow kicked.
	local clanOrder, clanGroups, nonClan = {}, {}, {}
	for _, p in unpinned do
		if p.clanTag and p.clanTag ~= "" then
			if clanGroups[p.clanTag] == nil then
				clanGroups[p.clanTag] = {}
				table.insert(clanOrder, p.clanTag)
			end
			table.insert(clanGroups[p.clanTag], p)
		else
			table.insert(nonClan, p)
		end
	end
	local sortedClans = {}
	for _, tag in clanOrder do
		table.insert(sortedClans, clanGroups[tag])
	end
	Util.sort(sortedClans, function(a, b)
		return #b - #a
	end)
	for _, clan in sortedClans do
		local team, teamSize = nil, 0
		for _, t in teams do
			local c = count(t)
			if team ~= nil and teamSize <= c then
				continue
			end
			teamSize = c
			team = t
		end
		if team == nil then
			continue
		end
		for _, player in clan do
			if teamSize < maxTeamSize then
				teamSize += 1
				set(player, team)
			else
				set(player, "kicked")
			end
		end
		teamPlayerCount[team] = teamSize
	end

	-- Friends: soft preference for the team holding most of them.
	local present = {}
	for _, p in players do
		if p.clientID ~= nil then
			present[p.clientID] = true
		end
	end
	local friendGraph = {}
	local function addEdge(a, b)
		friendGraph[a] = friendGraph[a] or {}
		friendGraph[a][b] = true
	end
	for _, p in players do
		if p.clientID == nil then
			continue
		end
		for _, friendID in p.friends or {} do
			if present[friendID] then
				addEdge(p.clientID, friendID)
				addEdge(friendID, p.clientID)
			end
		end
	end
	local teamByClientID = {}
	for _, p in order do
		local t = result[p]
		if p.clientID ~= nil and t ~= "kicked" then
			teamByClientID[p.clientID] = t
		end
	end

	local function placePlayer(p)
		local myFriends = if p.clientID ~= nil then friendGraph[p.clientID] else nil
		local bestTeam, bestFriendCount = nil, -1
		local bestSize = if isDuosTriosQuads then -1 else math.huge
		for _, t in teams do
			local size = count(t)
			if size >= maxTeamSize then
				continue
			end
			local friendsOnTeam = 0
			if myFriends then
				for friendID in myFriends do
					if teamByClientID[friendID] == t then
						friendsOnTeam += 1
					end
				end
			end
			if friendsOnTeam > bestFriendCount or (friendsOnTeam == bestFriendCount and (if isDuosTriosQuads then size > bestSize else size < bestSize)) then
				bestFriendCount = friendsOnTeam
				bestSize = size
				bestTeam = t
			end
		end
		if bestTeam == nil then
			set(p, "kicked")
			return
		end
		teamPlayerCount[bestTeam] = count(bestTeam) + 1
		set(p, bestTeam)
		if p.clientID ~= nil then
			teamByClientID[p.clientID] = bestTeam
		end
	end

	local nationPlayers, otherPlayers = {}, {}
	for _, p in nonClan do
		table.insert(if p.playerType == PlayerType.Nation then nationPlayers else otherPlayers, p)
	end
	if #nationPlayers > 0 then
		local random = PseudoRandom.new(Util.simpleHash(nationPlayers[1].id))
		nationPlayers = random:shuffleArray(nationPlayers)
	end
	for _, p in otherPlayers do
		placePlayer(p)
	end
	for _, p in nationPlayers do
		placePlayer(p)
	end

	local out = {}
	for _, p in order do
		table.insert(out, { player = p, team = result[p] })
	end
	return out
end

function TeamAssignment.resolveTeamsList(config, totalPlayers: number): { string }
	if config == GameTypes.HumansVsNations then
		return { ColoredTeams.Humans, ColoredTeams.Nations }
	end
	local numTeams
	if type(config) ~= "number" then
		local divisor = if config == GameTypes.Duos then 2 elseif config == GameTypes.Trios then 3 elseif config == GameTypes.Quads then 4 else 0
		if divisor == 0 then
			error(`Unknown TeamCountConfig {config}`)
		end
		-- At least 2, even when attendance can't fill two teams.
		numTeams = math.max(2, math.ceil(totalPlayers / divisor))
	else
		numTeams = config
	end
	if numTeams < 2 then
		error(`Too few teams: {numTeams}`)
	end
	if numTeams < 8 then
		local teams = { ColoredTeams.Red, ColoredTeams.Blue }
		if numTeams >= 3 then
			table.insert(teams, ColoredTeams.Yellow)
		end
		if numTeams >= 4 then
			table.insert(teams, ColoredTeams.Green)
		end
		if numTeams >= 5 then
			table.insert(teams, ColoredTeams.Purple)
		end
		if numTeams >= 6 then
			table.insert(teams, ColoredTeams.Orange)
		end
		if numTeams >= 7 then
			table.insert(teams, ColoredTeams.Teal)
		end
		return teams
	end
	local teams = table.create(numTeams)
	for i = 1, numTeams do
		teams[i] = `Team {i}`
	end
	return teams
end

return TeamAssignment
