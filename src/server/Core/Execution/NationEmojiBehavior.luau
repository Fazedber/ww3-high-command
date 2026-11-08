-- Port of OpenFrontIO src/core/execution/nation/NationEmojiBehavior.ts:
-- the emoji sets nations use, their casual emoji habits, and how they
-- respond to emojis / MIRVs.

local Shared = game:GetService("ReplicatedStorage").Shared
local Util = require(Shared.Util)
local Emojis = require(Shared.Data.Emojis)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)

local PlayerType = GameTypes.PlayerType
local Relation = GameTypes.Relation
local AllPlayers = GameTypes.AllPlayers

local function ids(list: { string }): { number }
	local out = {}
	for _, e in list do
		local id = Emojis.index[e]
		assert(id ~= nil, `emoji {e} not in table`)
		table.insert(out, id)
	end
	return out
end

local M = {}

M.EMOJI_ASSIST_ACCEPT = ids({ "\u{1f44d}", "\u{1f91d}", "\u{1f3af}" })
M.EMOJI_ASSIST_RELATION_TOO_LOW = ids({ "\u{1f971}", "\u{1f926}\u{200d}\u{2642}\u{fe0f}" })
M.EMOJI_ASSIST_TARGET_ME = ids({ "\u{1f97a}", "\u{1f480}" })
M.EMOJI_ASSIST_TARGET_ALLY = ids({ "\u{1f54a}\u{fe0f}", "\u{1f44e}" })
M.EMOJI_AGGRESSIVE_ATTACK = ids({ "\u{1f608}" })
M.EMOJI_ATTACK = ids({ "\u{1f621}" })
M.EMOJI_WARSHIP_RETALIATION = ids({ "\u{26f5}" })
M.EMOJI_NUKE = ids({ "\u{2622}\u{fe0f}", "\u{1f4a5}" })
M.EMOJI_GOT_INSULTED = ids({ "\u{1f595}", "\u{1f621}", "\u{1f921}", "\u{1f61e}", "\u{1f62d}" })
M.EMOJI_LOVE = ids({ "\u{2764}\u{fe0f}", "\u{1f60a}", "\u{1f970}" })
M.EMOJI_CONFUSED = ids({ "\u{2753}", "\u{1f921}" })
M.EMOJI_BRAG = ids({ "\u{1f451}", "\u{1f947}", "\u{1f4aa}" })
M.EMOJI_CHARM_ALLIES = ids({ "\u{1f91d}", "\u{1f607}", "\u{1f4aa}" })
M.EMOJI_CLOWN = ids({ "\u{1f921}", "\u{1f926}\u{200d}\u{2642}\u{fe0f}" })
M.EMOJI_RAT = ids({ "\u{1f400}" })
M.EMOJI_OVERWHELMED = ids({ "\u{1f480}", "\u{1f198}", "\u{1f631}", "\u{1f97a}", "\u{1f62d}", "\u{1f61e}", "\u{1fae1}", "\u{1f44b}" })
M.EMOJI_CONGRATULATE = ids({ "\u{1f44f}" })
M.EMOJI_SCARED_OF_THREAT = ids({ "\u{1f64f}", "\u{1f97a}" })
M.EMOJI_BORED = ids({ "\u{1f971}" })
M.EMOJI_HANDSHAKE = ids({ "\u{1f91d}" })
M.EMOJI_DONATION_OK = ids({ "\u{1f44d}" })
M.EMOJI_DONATION_TOO_SMALL = ids({ "\u{2753}", "\u{1f971}" })
M.EMOJI_GREET = ids({ "\u{1f44b}" })

local function EmojiExecution()
	return require(script.Parent.SocialExecutions).EmojiExecution
end

-- NationEmojiBehavior ------------------------------------------------------------

local Behavior = {}
Behavior.__index = Behavior

function M.new(random, game, player)
	return setmetatable({ random = random, game = game, player = player, lastEmojiSent = {}, gameOver = false }, Behavior)
end

function Behavior:maybeSendCasualEmoji()
	if self.gameOver then
		return
	end
	self:_checkOverwhelmedByAttacks()
	self:_checkVerySmallAttack()
	self:_congratulateWinner()
	self:_brag()
	self:_charmAllies()
	self:_annoyTraitors()
	self:_findRat()
	self:_greetNearbyPlayers()
end

function Behavior:_checkOverwhelmedByAttacks()
	if not self.random:chance(16) then
		return
	end
	local incoming = self.player:incomingAttacks()
	if #incoming == 0 then
		return
	end
	local total = 0
	for _, a in incoming do
		total += a:troops()
	end
	if total >= self.player:troops() * 3 then
		self:sendEmoji(AllPlayers, M.EMOJI_OVERWHELMED)
	end
end

function Behavior:_checkVerySmallAttack()
	if not self.random:chance(8) then
		return
	end
	local incoming = self.player:incomingAttacks()
	if #incoming == 0 then
		return
	end
	local ours = self.player:troops()
	if ours <= 0 then
		return
	end
	for _, attack in incoming do
		local attacker = attack:attacker()
		if attacker:type() ~= PlayerType.Human then
			continue
		end
		if attack:troops() < ours * 0.1 then
			self:maybeSendEmoji(attacker, if self.random:chance(2) then M.EMOJI_CONFUSED else M.EMOJI_BORED)
		end
	end
end

function Behavior:_congratulateWinner()
	local winner = self.game:getWinner()
	if winner == nil then
		return
	end
	self.gameOver = true
	if self.game:config():gameConfig().gameMode == GameTypes.GameMode.Team then
		if winner == self.player:team() then
			return
		end
		self:sendEmoji(AllPlayers, M.EMOJI_CONGRATULATE)
	else
		if type(winner) == "string" then
			return
		end
		local nations = {}
		for _, p in self.game:players() do
			if p:type() == PlayerType.Nation then
				table.insert(nations, p)
			end
		end
		Util.sort(nations, function(a, b)
			return b:numTilesOwned() - a:numTilesOwned()
		end)
		if nations[1] ~= self.player then
			return
		end
		self:sendEmoji(winner, M.EMOJI_CONGRATULATE)
	end
end

function Behavior:_brag()
	if not self.random:chance(300) then
		return
	end
	local sorted = self.game:players()
	Util.sort(sorted, function(a, b)
		return b:numTilesOwned() - a:numTilesOwned()
	end)
	if #sorted == 0 or sorted[1] ~= self.player then
		return
	end
	self:sendEmoji(AllPlayers, M.EMOJI_BRAG)
end

function Behavior:_charmAllies()
	if not self.random:chance(250) then
		return
	end
	local humans = {}
	for _, p in self.player:allies() do
		if p:type() == PlayerType.Human then
			table.insert(humans, p)
		end
	end
	if #humans == 0 then
		return
	end
	local ally = self.random:randElement(humans)
	self:sendEmoji(ally, if self.random:chance(3) then M.EMOJI_LOVE else M.EMOJI_CHARM_ALLIES)
end

function Behavior:_annoyTraitors()
	if not self.random:chance(40) then
		return
	end
	local traitors = {}
	for _, p in self.game:players() do
		if p:type() == PlayerType.Human and not p:isFriendly(self.player) and p:isTraitor() then
			table.insert(traitors, p)
		end
	end
	if #traitors == 0 then
		return
	end
	self:sendEmoji(self.random:randElement(traitors), M.EMOJI_CLOWN)
end

function Behavior:_findRat()
	if self.game:ticks() < 6000 then
		return
	end
	if not self.random:chance(10000) then
		return
	end
	local threshold = self.game:numLandTiles() * 0.01
	local small = {}
	for _, p in self.game:players() do
		if p:type() == PlayerType.Human and p:numTilesOwned() < threshold and p:numTilesOwned() > 0 then
			table.insert(small, p)
		end
	end
	if #small == 0 then
		return
	end
	self:sendEmoji(self.random:randElement(small), M.EMOJI_RAT)
end

function Behavior:_greetNearbyPlayers()
	if self.game:ticks() > 600 then
		return
	end
	if not self.random:chance(250) then
		return
	end
	local humans = {}
	for _, p in self.player:nearby() do
		if p:isPlayer() and p:type() == PlayerType.Human then
			table.insert(humans, p)
		end
	end
	if #humans == 0 then
		return
	end
	self:sendEmoji(self.random:randElement(humans), M.EMOJI_GREET)
end

function Behavior:maybeSendEmoji(other, list: { number })
	if not self:_shouldSendEmoji(other, true) then
		return
	end
	self:sendEmoji(other, list)
end

function Behavior:maybeSendAttackEmoji(other)
	if not self:_shouldSendEmoji(other, true) then
		return
	end
	-- Good relation: we are probably attacking first (aggressive).
	if self.player:relation(other) >= Relation.Neutral then
		if not self.random:chance(2) then
			return
		end
		self:sendEmoji(other, M.EMOJI_AGGRESSIVE_ATTACK)
		return
	end
	-- Probably retaliating.
	if not self.random:chance(4) then
		return
	end
	self:sendEmoji(other, M.EMOJI_ATTACK)
end

function Behavior:sendEmoji(other, list: { number })
	if not self:_shouldSendEmoji(other, false) then
		return
	end
	if not self.player:canSendEmoji(other) then
		return
	end
	self.game:addExecution(EmojiExecution().new(self.player, if other == AllPlayers then AllPlayers else other:id(), self.random:randElement(list)))
end

function Behavior:_shouldSendEmoji(other, limitByTime: boolean): boolean
	if other == AllPlayers then
		return true
	end
	if self.player:type() == PlayerType.Bot then
		return false
	end
	if other:type() ~= PlayerType.Human then
		return false
	end
	if limitByTime then
		local last = self.lastEmojiSent[other] or -300
		if self.game:ticks() - last <= 300 then
			return false
		end
		self.lastEmojiSent[other] = self.game:ticks()
	end
	return true
end

-- Nations answer insults, clowns and doves.
function M.respondToEmoji(game, random, sender, recipient, emoji: string)
	if recipient == AllPlayers or recipient:type() ~= PlayerType.Nation then
		return
	end
	if not recipient:canSendEmoji(sender) then
		return
	end
	local Exec = EmojiExecution()
	if emoji == "\u{1f595}" then
		recipient:updateRelation(sender, -100)
		game:addExecution(Exec.new(recipient, sender:id(), random:randElement(M.EMOJI_GOT_INSULTED)))
	end
	if emoji == "\u{1f921}" then
		recipient:updateRelation(sender, -10)
		game:addExecution(Exec.new(recipient, sender:id(), random:randElement(M.EMOJI_CONFUSED)))
	end
	if emoji == "\u{1f54a}\u{fe0f}" or emoji == "\u{1f3f3}\u{fe0f}" or emoji == "\u{2764}\u{fe0f}" or emoji == "\u{1f970}" or emoji == "\u{1f44f}" then
		if game:config():gameConfig().difficulty == GameTypes.Difficulty.Easy then
			recipient:updateRelation(sender, 15)
		end
		game:addExecution(
			Exec.new(recipient, sender:id(), if sender:relation(recipient) >= Relation.Neutral then random:randElement(M.EMOJI_LOVE) else random:randElement(M.EMOJI_CONFUSED))
		)
	end
end

function M.respondToMIRV(game, random, mirvTarget)
	if not random:chance(8) then
		return
	end
	if not mirvTarget:canSendEmoji(AllPlayers) then
		return
	end
	game:addExecution(EmojiExecution().new(mirvTarget, AllPlayers, random:randElement(M.EMOJI_OVERWHELMED)))
end

return M
