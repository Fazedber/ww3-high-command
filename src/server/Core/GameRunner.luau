-- Port of OpenFrontIO src/core/GameRunner.ts (createGameRunner + GameRunner)
-- and src/core/execution/ExecutionManager.ts (Executor).
--
-- gameStart = {
--   gameID: string,
--   config: GameConfig (see Config.luau),
--   players: { { username, clientID, isLobbyCreator?, clanTag?, friends?, teamIndex? } },
--   tribes: { { name } }?,  -- purchased tribe names
-- }
-- Intents mirror upstream's wire intents: { type = "attack" | "spawn" |
-- "cancel_attack" | "boat" | "cancel_boat", clientID, ... }.

local Shared = game:GetService("ReplicatedStorage").Shared
local MapLoader = require(Shared.MapLoader)
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local Config = require(script.Parent.Config)
local GameImpl = require(script.Parent.GameImpl)
local GameTypes = require(script.Parent.GameTypes)
local NationCreation = require(script.Parent.NationCreation)
local Exec = script.Parent.Execution
local AttackExecution = require(Exec.AttackExecution)
local SmallExecutions = require(Exec.SmallExecutions)
local SpawnExecution = require(Exec.SpawnExecution)
local TribeSpawner = require(Exec.TribeSpawner)
local TransportShipExecution = require(Exec.TransportShipExecution)
local ConstructionExecution = require(Exec.ConstructionExecution)
local StructureExecutions = require(Exec.StructureExecutions)

local PlayerType = GameTypes.PlayerType
local GameType = GameTypes.GameType

-- Executor ----------------------------------------------------------------------

local Executor = {}
Executor.__index = Executor

function Executor.new(mg, gameID: string, purchasedTribeNames: { string }?, mapThemes: { string }?)
	return setmetatable({
		mg = mg,
		gameID = gameID,
		purchasedTribeNames = purchasedTribeNames or {},
		mapThemes = mapThemes,
		-- Add one to avoid id collisions with tribes.
		random = PseudoRandom.new(Util.simpleHash(gameID) + 1),
	}, Executor)
end

function Executor:createExec(intent)
	local player = self.mg:playerByClientID(intent.clientID)
	if not player then
		warn(`player with clientID {intent.clientID} not found`)
		return SmallExecutions.NoOpExecution.new()
	end
	local t = intent.type
	if t == "attack" then
		return AttackExecution.new(intent.troops, player, intent.targetID, nil, nil, intent.focusTile)
	elseif t == "cancel_attack" then
		return SmallExecutions.RetreatExecution.new(player, intent.attackID)
	elseif t == "spawn" then
		-- fromIntent: subject to the spawn-phase gate.
		return SpawnExecution.new(self.gameID, player:info(), intent.tile, true)
	elseif t == "boat" then
		return TransportShipExecution.new(player, intent.dst, intent.troops)
	elseif t == "cancel_boat" then
		return SmallExecutions.BoatRetreatExecution.new(player, intent.unitID)
	elseif t == "build_unit" then
		return ConstructionExecution.new(player, intent.unit, intent.tile, intent.rocketDirectionUp, intent.amount)
	elseif t == "move_warship" then
		local MoveWarshipExecution = require(script.Parent.Execution.WarshipExecution).MoveWarshipExecution
		return MoveWarshipExecution.new(player, intent.unitIds, intent.tile)
	elseif t == "upgrade_structure" then
		return StructureExecutions.UpgradeStructureExecution.new(player, intent.unitId, intent.amount)
	elseif t == "delete_unit" then
		return StructureExecutions.DeleteUnitExecution.new(player, intent.unitId)
	end
	local Social = require(script.Parent.Execution.SocialExecutions)
	if t == "allianceRequest" then
		return Social.AllianceRequestExecution.new(player, intent.recipient)
	elseif t == "allianceReject" then
		return Social.AllianceRejectExecution.new(intent.requestor, player)
	elseif t == "breakAlliance" then
		return Social.BreakAllianceExecution.new(player, intent.recipient)
	elseif t == "allianceExtension" then
		return Social.AllianceExtensionExecution.new(player, intent.recipient)
	elseif t == "targetPlayer" then
		return Social.TargetPlayerExecution.new(player, intent.target)
	elseif t == "emoji" then
		return Social.EmojiExecution.new(player, intent.recipient, intent.emoji)
	elseif t == "donate_troops" then
		return Social.DonateTroopsExecution.new(player, intent.recipient, intent.troops)
	elseif t == "donate_gold" then
		return Social.DonateGoldExecution.new(player, intent.recipient, intent.gold)
	elseif t == "embargo" then
		return Social.EmbargoExecution.new(player, intent.targetID, intent.action)
	elseif t == "embargo_all" then
		return Social.EmbargoAllExecution.new(player, intent.action)
	elseif t == "quick_chat" then
		return Social.QuickChatExecution.new(player, intent.recipient, intent.quickChatKey, intent.target)
	end
	-- TODO(port): disconnect marking, pause.
	warn(`TODO(port): intent type {t}`)
	return SmallExecutions.NoOpExecution.new()
end

function Executor:spawnTribes(numTribes: number)
	local nationCells = {}
	for _, n in self.mg:nations() do
		if n.spawnCell ~= nil then
			table.insert(nationCells, n.spawnCell)
		end
	end
	return TribeSpawner.new(self.mg, self.gameID, nationCells, self.mapThemes)
		:spawnTribes(numTribes, self.purchasedTribeNames)
end

-- GameRunner --------------------------------------------------------------------

local GameRunner = {}
GameRunner.__index = GameRunner
GameRunner.Executor = Executor

function GameRunner.create(gameStart, mapModule: ModuleScript)
	local config = Config.new(gameStart.config)
	local gameMap, miniGameMap, manifest = MapLoader.load(mapModule)
	local random = PseudoRandom.new(Util.simpleHash(gameStart.gameID))

	local humans = {}
	for _, p in gameStart.players or {} do
		table.insert(
			humans,
			GameTypes.PlayerInfo(
				p.username,
				PlayerType.Human,
				p.clientID,
				random:nextID(),
				p.isLobbyCreator or false,
				p.clanTag,
				p.friends or {},
				p.teamIndex
			)
		)
	end

	local nations = NationCreation.createNationsForGame(
		config:gameConfig(),
		manifest.nations or {},
		manifest.additionalNations or {},
		#humans,
		random
	)

	local game = GameImpl.new(humans, nations, gameMap, miniGameMap, config, manifest.teamGameSpawnAreas)
	local purchased = {}
	for _, t in gameStart.tribes or {} do
		table.insert(purchased, t.name)
	end
	local runner = setmetatable({
		game = game,
		manifest = manifest,
		execManager = Executor.new(game, gameStart.gameID, purchased, manifest.themes),
	}, GameRunner)
	runner:init()
	return runner
end

function GameRunner:init()
	local game = self.game
	local config = game:config()
	if config:gameConfig().gameType ~= GameType.Singleplayer then
		game:addExecution(SmallExecutions.SpawnTimerExecution.new())
	end
	if config:spawnNations() then
		local NationExecution = require(Exec.NationExecution)
		local execs = {}
		for _, nation in game:nations() do
			table.insert(execs, NationExecution.new(self.execManager.gameID, nation))
		end
		if #execs > 0 then
			game:addExecution(table.unpack(execs))
		end
	end
	if config:isRandomSpawn() then
		-- PlayerSpawner: a SpawnExecution without a tile per human.
		local execs = {}
		for _, player in game:allPlayers() do
			if player:type() == PlayerType.Human then
				table.insert(execs, SpawnExecution.new(self.execManager.gameID, player:info()))
			end
		end
		if #execs > 0 then
			game:addExecution(table.unpack(execs))
		end
	end
	if config:bots() > 0 then
		-- Roblox port: 250-400 tribe spawns in one tick took ~0.5 s (a visible
		-- freeze at the start of every match); feed them in 10 per tick. The
		-- spawn phase lasts 150-200 ticks, so all are placed within its first
		-- few seconds.
		local tribes = self.execManager:spawnTribes(config:bots())
		local feeder = {
			isActive = function(f)
				return f.next <= #tribes
			end,
			activeDuringSpawnPhase = function()
				return true
			end,
			init = function() end,
			tick = function(f)
				local last = math.min(#tribes, f.next + 9)
				for i = f.next, last do
					game:addExecution(tribes[i])
				end
				f.next = last + 1
			end,
			next = 1,
		}
		game:addExecution(feeder)
	end
	game:addExecution(SmallExecutions.WinCheckExecution.new())
	if not config:isUnitDisabled(GameTypes.UnitType.Factory) then
		local RecomputeRailClusterExecution = require(Exec.TrainExecutions).RecomputeRailClusterExecution
		game:addExecution(RecomputeRailClusterExecution.new(game:railNetwork()))
	end
	-- TODO(port): DoomsdayClockExecution
end

-- Runs one tick with this turn's intents. Returns the tick's game updates.
function GameRunner:executeNextTick(intents: { any }?)
	for _, intent in intents or {} do
		self.game:addExecution(self.execManager:createExec(intent))
	end
	return self.game:executeNextTick()
end

return GameRunner
