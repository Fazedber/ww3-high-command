-- Enums and value types from OpenFrontIO src/core/game/Game.ts.
-- String enums keep their upstream string values (they appear in configs and
-- wire messages); numeric enums keep their numeric values.

local Util = require(game:GetService("ReplicatedStorage").Shared.Util)

local GameTypes = {}

GameTypes.PlayerType = table.freeze({
	Bot = "BOT",
	Human = "HUMAN",
	Nation = "NATION",
})

GameTypes.Difficulty = table.freeze({
	Easy = "Easy",
	Medium = "Medium",
	Hard = "Hard",
	Impossible = "Impossible",
})

GameTypes.GameType = table.freeze({
	Singleplayer = "Singleplayer",
	Public = "Public",
	Private = "Private",
})

GameTypes.GameMode = table.freeze({
	FFA = "Free For All",
	Team = "Team",
})

GameTypes.GameMapSize = table.freeze({
	Compact = "Compact",
	Normal = "Normal",
})

-- Emoji recipient meaning "everyone" (upstream AllPlayers).
GameTypes.AllPlayers = "AllPlayers"

GameTypes.Relation = table.freeze({
	Hostile = 0,
	Distrustful = 1,
	Neutral = 2,
	Friendly = 3,
})

GameTypes.UnitType = table.freeze({
	TransportShip = "Transport",
	Warship = "Warship",
	Shell = "Shell",
	SAMMissile = "SAMMissile",
	Port = "Port",
	AtomBomb = "Atom Bomb",
	HydrogenBomb = "Hydrogen Bomb",
	TradeShip = "Trade Ship",
	MissileSilo = "Missile Silo",
	DefensePost = "Defense Post",
	SAMLauncher = "SAM Launcher",
	City = "City",
	MIRV = "MIRV",
	MIRVWarhead = "MIRV Warhead",
	Train = "Train",
	Factory = "Factory",
})

local UnitType = GameTypes.UnitType
local function group(types: { string })
	local set = {}
	for _, t in types do
		set[t] = true
	end
	return table.freeze({
		types = table.freeze(types),
		has = function(t: string): boolean
			return set[t] == true
		end,
	})
end

GameTypes.Structures = group({
	UnitType.City,
	UnitType.DefensePost,
	UnitType.SAMLauncher,
	UnitType.MissileSilo,
	UnitType.Port,
	UnitType.Factory,
})

GameTypes.Nukes = group({ UnitType.AtomBomb, UnitType.HydrogenBomb, UnitType.MIRVWarhead, UnitType.MIRV })

GameTypes.BuildableAttacks = group({ UnitType.AtomBomb, UnitType.HydrogenBomb, UnitType.MIRV, UnitType.Warship })

do
	local menus = table.clone(GameTypes.Structures.types)
	table.move(GameTypes.BuildableAttacks.types, 1, #GameTypes.BuildableAttacks.types, #menus + 1, menus)
	GameTypes.BuildMenus = group(menus)
	local buildable = table.clone(menus)
	table.insert(buildable, UnitType.TransportShip)
	GameTypes.PlayerBuildable = group(buildable)
end

GameTypes.ColoredTeams = table.freeze({
	Red = "Red",
	Blue = "Blue",
	Teal = "Teal",
	Purple = "Purple",
	Yellow = "Yellow",
	Orange = "Orange",
	Green = "Green",
	Bot = "Bot",
	Humans = "Humans",
	Nations = "Nations",
})

GameTypes.Duos = "Duos"
GameTypes.Trios = "Trios"
GameTypes.Quads = "Quads"
GameTypes.HumansVsNations = "Humans Vs Nations"

-- Numeric values match upstream `enum MessageType` order.
GameTypes.MessageType = table.freeze({
	ATTACK_FAILED = 0,
	ATTACK_CANCELLED = 1,
	ATTACK_REQUEST = 2,
	CONQUERED_PLAYER = 3,
	MIRV_INBOUND = 4,
	NUKE_INBOUND = 5,
	NUKE_DETONATED = 6,
	HYDROGEN_BOMB_INBOUND = 7,
	NAVAL_INVASION_INBOUND = 8,
	SAM_MISS = 9,
	SAM_HIT = 10,
	CAPTURED_ENEMY_UNIT = 11,
	UNIT_DESTROYED = 12,
	ALLIANCE_ACCEPTED = 13,
	ALLIANCE_REJECTED = 14,
	ALLIANCE_REQUEST = 15,
	ALLIANCE_BROKEN = 16,
	ALLIANCE_EXPIRED = 17,
	DONATION_SENT = 18,
	DONATION_RECEIVED = 19,
	CHAT = 20,
	RENEW_ALLIANCE = 21,
})

export type PlayerInfo = {
	name: string,
	playerType: string,
	clientID: string?, -- nil for tribes / nations
	id: string,
	isLobbyCreator: boolean,
	clanTag: string?,
	friends: { string },
	teamIndex: number?,
	nationFlag: string?,
	displayName: string,
}

function GameTypes.PlayerInfo(
	name: string,
	playerType: string,
	clientID: string?,
	id: string,
	isLobbyCreator: boolean?,
	clanTag: string?,
	friends: { string }?,
	teamIndex: number?,
	nationFlag: string?
): PlayerInfo
	return table.freeze({
		name = name,
		playerType = playerType,
		clientID = clientID,
		id = id,
		isLobbyCreator = isLobbyCreator or false,
		clanTag = clanTag,
		friends = friends or {},
		teamIndex = teamIndex,
		nationFlag = nationFlag,
		displayName = Util.formatPlayerDisplayName(name, clanTag),
	})
end

-- Upstream `class Nation { spawnCell, playerInfo }`.
function GameTypes.Nation(spawnCell: { x: number, y: number }?, playerInfo: PlayerInfo)
	return table.freeze({ spawnCell = spawnCell, playerInfo = playerInfo })
end

return GameTypes
