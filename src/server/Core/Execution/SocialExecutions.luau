-- Port of the player-to-player executions of OpenFrontIO:
--   alliance/AllianceRequestExecution.ts, AllianceRejectExecution.ts,
--   BreakAllianceExecution.ts, AllianceExtensionExecution.ts,
--   EmojiExecution.ts, EmbargoExecution.ts, EmbargoAllExecution.ts,
--   TargetPlayerExecution.ts, QuickChatExecution.ts,
--   DonateGoldExecution.ts, DonateTroopExecution.ts.

local Shared = game:GetService("ReplicatedStorage").Shared
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)
local Emojis = require(Shared.Data.Emojis)
local Core = script.Parent.Parent
local GameTypes = require(Core.GameTypes)
local ExecUtil = require(script.Parent.ExecUtil)

local UnitType = GameTypes.UnitType
local PlayerType = GameTypes.PlayerType
local MessageType = GameTypes.MessageType
local Difficulty = GameTypes.Difficulty
local AllPlayers = GameTypes.AllPlayers

local function NationEmoji()
	return require(script.Parent.NationEmojiBehavior)
end

-- Instant / one-shot execution boilerplate.
local function oneShot(class)
	class.__index = class
	function class:isActive(): boolean
		return self._active
	end
	function class:activeDuringSpawnPhase(): boolean
		return false
	end
	return class
end

local M = {}

-- EmojiExecution ---------------------------------------------------------------------

local EmojiExecution = oneShot({})
M.EmojiExecution = EmojiExecution

function EmojiExecution.new(requestor, recipientID, emoji: number)
	return setmetatable({ requestor = requestor, recipientID = recipientID, emoji = emoji, _active = true }, EmojiExecution)
end
function EmojiExecution:init(mg, _ticks: number)
	self.mg = mg
	self.random = PseudoRandom.new(mg:ticks())
	if self.recipientID ~= AllPlayers and not mg:hasPlayer(self.recipientID) then
		warn(`EmojiExecution: recipient {self.recipientID} not found`)
		self._active = false
		return
	end
	self.recipient = if self.recipientID == AllPlayers then AllPlayers else mg:player(self.recipientID)
end
function EmojiExecution:tick(_ticks: number)
	local emoji = Emojis.flat[self.emoji + 1]
	if emoji ~= nil and self.requestor:canSendEmoji(self.recipient) then
		self.requestor:sendEmoji(self.recipient, emoji)
		NationEmoji().respondToEmoji(self.mg, self.random, self.requestor, self.recipient, emoji)
	end
	self._active = false
end

-- AllianceRequestExecution -------------------------------------------------------------

local AllianceRequestExecution = oneShot({})
M.AllianceRequestExecution = AllianceRequestExecution

function AllianceRequestExecution.new(requestor, recipientID: string)
	return setmetatable({ requestor = requestor, recipientID = recipientID, req = nil, _active = true }, AllianceRequestExecution)
end
function AllianceRequestExecution:init(mg, _ticks: number)
	self.mg = mg
	if not mg:hasPlayer(self.recipientID) then
		warn(`AllianceRequestExecution recipient {self.recipientID} not found`)
		return
	end
	local recipient = mg:player(self.recipientID)
	if not self.requestor:canSendAllianceRequest(recipient) then
		self._active = false
		return
	end
	local incoming = nil
	for _, r in recipient:outgoingAllianceRequests() do
		if r:recipient() == self.requestor then
			incoming = r
			break
		end
	end
	if incoming then
		-- Pending request the other way: accept it instead.
		self._active = false
		incoming:accept()
		self.requestor:updateRelation(recipient, 100)
		recipient:updateRelation(self.requestor, 100)
		-- Only automatic (temporary) embargoes end.
		if self.requestor:hasEmbargoAgainst(recipient) then
			self.requestor:endTemporaryEmbargo(recipient)
		end
		if recipient:hasEmbargoAgainst(self.requestor) then
			recipient:endTemporaryEmbargo(self.requestor)
		end
		self:_cancelNukesBetweenAlliedPlayers(recipient)
	else
		self.req = self.requestor:createAllianceRequest(recipient)
	end
end
function AllianceRequestExecution:tick(_ticks: number)
	local req = self.req
	if req and (req:status() == "accepted" or req:status() == "rejected") then
		self._active = false
		return
	end
	if self.mg:ticks() - (if req then req:createdAt() else 0) > self.mg:config():allianceRequestDuration() then
		if req then
			req:reject()
		end
		self._active = false
	end
end

-- New allies' nukes at each other are destroyed in flight.
function AllianceRequestExecution:_cancelNukesBetweenAlliedPlayers(recipient)
	local mg = self.mg
	local order, neutralized = {}, {}
	local function bump(launcher)
		if neutralized[launcher] == nil then
			neutralized[launcher] = 0
			table.insert(order, launcher)
		end
		neutralized[launcher] += 1
	end
	local warheadOrder, warheadLaunchers = {}, {}
	for _, launcher in { self.requestor, recipient } do
		local other = if launcher == self.requestor then recipient else self.requestor
		for _, unit in launcher:units({ UnitType.AtomBomb, UnitType.HydrogenBomb, UnitType.MIRV, UnitType.MIRVWarhead }) do
			if not unit:isActive() or unit:reachedTarget() then
				continue
			end
			local targetTile = unit:targetTile()
			if unit:type() == UnitType.MIRV then
				-- The captured target player at launch (tile owners may change).
				local target = unit:targetPlayer() or (if targetTile then mg:owner(targetTile) else nil)
				if target ~= other then
					continue
				end
			elseif unit:type() == UnitType.MIRVWarhead then
				if not targetTile or mg:owner(targetTile) ~= other then
					continue
				end
			else
				if not targetTile then
					continue
				end
				local magnitude = mg:config():nukeMagnitudes(unit:type())
				if not ExecUtil.wouldNukeBreakAlliance(mg, targetTile, magnitude, { [other:smallID()] = true }, mg:config():nukeAllianceBreakThreshold()) then
					continue
				end
			end
			unit:delete(false)
			if unit:type() == UnitType.MIRVWarhead then
				if not warheadLaunchers[launcher] then
					warheadLaunchers[launcher] = true
					table.insert(warheadOrder, launcher)
				end
			else
				bump(launcher)
			end
		end
	end
	for _, launcher in warheadOrder do
		bump(launcher)
	end
	for _, launcher in order do
		local count = neutralized[launcher]
		local other = if launcher == self.requestor then recipient else self.requestor
		mg:displayMessage(
			"events_display.alliance_nukes_destroyed_outgoing",
			MessageType.ALLIANCE_ACCEPTED,
			launcher:id(),
			nil,
			{ name = other:displayName(), count = count },
			nil,
			other:id()
		)
		mg:displayMessage(
			"events_display.alliance_nukes_destroyed_incoming",
			MessageType.ALLIANCE_ACCEPTED,
			other:id(),
			nil,
			{ name = launcher:displayName(), count = count },
			nil,
			launcher:id()
		)
	end
end

-- AllianceRejectExecution ----------------------------------------------------------------

local AllianceRejectExecution = oneShot({})
M.AllianceRejectExecution = AllianceRejectExecution

function AllianceRejectExecution.new(requestorID: string, recipient)
	return setmetatable({ requestorID = requestorID, recipient = recipient, _active = true }, AllianceRejectExecution)
end
function AllianceRejectExecution:init(mg, _ticks: number)
	if not mg:hasPlayer(self.requestorID) then
		self._active = false
		return
	end
	local requestor = mg:player(self.requestorID)
	if not requestor:isFriendly(self.recipient) then
		for _, ar in requestor:outgoingAllianceRequests() do
			if ar:recipient() == self.recipient then
				ar:reject()
				break
			end
		end
	end
	self._active = false
end
function AllianceRejectExecution:tick(_ticks: number) end

-- BreakAllianceExecution -------------------------------------------------------------------

local BreakAllianceExecution = oneShot({})
M.BreakAllianceExecution = BreakAllianceExecution

function BreakAllianceExecution.new(requestor, recipientID: string)
	return setmetatable({ requestor = requestor, recipientID = recipientID, recipient = nil, _active = true }, BreakAllianceExecution)
end
function BreakAllianceExecution:init(mg, _ticks: number)
	if not mg:hasPlayer(self.recipientID) then
		self._active = false
		return
	end
	self.recipient = mg:player(self.recipientID)
	self.mg = mg
end
function BreakAllianceExecution:tick(_ticks: number)
	local alliance = self.requestor:allianceWith(self.recipient)
	if alliance ~= nil then
		self.requestor:breakAlliance(alliance)
		self.recipient:updateRelation(self.requestor, -100)
		for _, n in self.requestor:nearby() do
			if n:isPlayer() and not n:isOnSameTeam(self.recipient) then
				n:updateRelation(self.requestor, -40)
			end
		end
	end
	self._active = false
end

-- AllianceExtensionExecution -----------------------------------------------------------------

local AllianceExtensionExecution = oneShot({})
M.AllianceExtensionExecution = AllianceExtensionExecution

function AllianceExtensionExecution.new(from, toID: string)
	return setmetatable({ from = from, toID = toID, _active = false }, AllianceExtensionExecution)
end
function AllianceExtensionExecution:init(mg, _ticks: number)
	if not mg:hasPlayer(self.toID) then
		return
	end
	local to = mg:player(self.toID)
	if not self.from:isAlive() or not to:isAlive() then
		return
	end
	local alliance = self.from:allianceWith(to)
	if not alliance then
		return
	end
	local wasOnlyOneAgreed = alliance:onlyOneAgreedToExtend()
	alliance:addExtensionRequest(self.from)
	if alliance:bothAgreedToExtend() then
		alliance:extend()
		mg:displayMessage("events_display.alliance_renewed", MessageType.ALLIANCE_ACCEPTED, self.from:id(), nil, { name = to:displayName() }, nil, to:id())
		mg:displayMessage("events_display.alliance_renewed", MessageType.ALLIANCE_ACCEPTED, self.toID, nil, { name = self.from:displayName() }, nil, self.from:id())
	elseif alliance:onlyOneAgreedToExtend() and not wasOnlyOneAgreed then
		mg:displayMessage("events_display.wants_to_renew_alliance", MessageType.RENEW_ALLIANCE, self.toID, nil, { name = self.from:displayName() }, nil, self.from:id())
	end
end
function AllianceExtensionExecution:tick(_ticks: number) end

-- Embargo --------------------------------------------------------------------------------------

local EmbargoExecution = oneShot({})
M.EmbargoExecution = EmbargoExecution

function EmbargoExecution.new(player, targetID: string, action: string)
	return setmetatable({ player = player, targetID = targetID, action = action, _active = true }, EmbargoExecution)
end
function EmbargoExecution:init(mg, _ticks: number)
	if not mg:hasPlayer(self.targetID) then
		self._active = false
		return
	end
	self.target = mg:player(self.targetID)
end
function EmbargoExecution:tick(_ticks: number)
	if self.action == "start" then
		self.player:addEmbargo(self.target, false)
	else
		self.player:stopEmbargo(self.target)
	end
	self._active = false
end

local EmbargoAllExecution = oneShot({})
M.EmbargoAllExecution = EmbargoAllExecution

function EmbargoAllExecution.new(player, action: string)
	return setmetatable({ player = player, action = action, _active = false }, EmbargoAllExecution)
end
function EmbargoAllExecution:init(mg, _ticks: number)
	local me = self.player
	if not me:canEmbargoAll() then
		return
	end
	for _, p in mg:players() do
		if p:id() == me:id() or p:type() == PlayerType.Bot or me:isOnSameTeam(p) then
			continue
		end
		if self.action == "start" then
			if not me:hasEmbargoAgainst(p) then
				me:addEmbargo(p, false)
			end
		elseif me:hasEmbargoAgainst(p) then
			me:stopEmbargo(p)
		end
	end
	me:recordEmbargoAll()
end
function EmbargoAllExecution:tick(_ticks: number) end

-- TargetPlayerExecution ----------------------------------------------------------------------------

local TargetPlayerExecution = oneShot({})
M.TargetPlayerExecution = TargetPlayerExecution

function TargetPlayerExecution.new(requestor, targetID: string)
	return setmetatable({ requestor = requestor, targetID = targetID, _active = true }, TargetPlayerExecution)
end
function TargetPlayerExecution:init(mg, _ticks: number)
	if not mg:hasPlayer(self.targetID) then
		self._active = false
		return
	end
	self.target = mg:player(self.targetID)
end
function TargetPlayerExecution:tick(_ticks: number)
	if self.requestor:canTarget(self.target) then
		self.requestor:target(self.target)
		self.target:updateRelation(self.requestor, -40)
	end
	self._active = false
end

-- QuickChatExecution --------------------------------------------------------------------------------

local QuickChatExecution = oneShot({})
M.QuickChatExecution = QuickChatExecution

function QuickChatExecution.new(sender, recipientID: string, key: string, target: string?)
	return setmetatable({ sender = sender, recipientID = recipientID, key = key, target = target, _active = true }, QuickChatExecution)
end
function QuickChatExecution:init(mg, _ticks: number)
	self.mg = mg
	if not mg:hasPlayer(self.recipientID) then
		self._active = false
		return
	end
	self.recipient = mg:player(self.recipientID)
end
function QuickChatExecution:tick(_ticks: number)
	if not self.sender:canSendQuickChat(self.recipient) then
		self._active = false
		return
	end
	-- "category.key" -> { category, key }
	local category, key = string.match(self.key, "^([^%.]*)%.?(.*)$")
	self.sender:recordQuickChat(self.recipient)
	self.mg:displayChat(key, category, self.target, self.recipient:id(), true, self.sender:id())
	self.mg:displayChat(key, category, self.target, self.sender:id(), false, self.recipient:id())
	self._active = false
end
function QuickChatExecution:owner()
	return self.sender
end

-- Donations --------------------------------------------------------------------------------------------

local DonateGoldExecution = oneShot({})
M.DonateGoldExecution = DonateGoldExecution

function DonateGoldExecution.new(sender, recipientID: string, gold: number?)
	return setmetatable({ sender = sender, recipientID = recipientID, gold = if gold ~= nil then Util.toInt(gold) else nil, _active = true }, DonateGoldExecution)
end
function DonateGoldExecution:init(mg, _ticks: number)
	self.mg = mg
	self.random = PseudoRandom.new(mg:ticks())
	if not mg:hasPlayer(self.recipientID) then
		self._active = false
		return
	end
	self.recipient = mg:player(self.recipientID)
	if self.gold == nil then
		self.gold = self.sender:gold() // 3 -- bigint division
	end
end
function DonateGoldExecution:_chunkSize(): number
	local d = self.mg:config():gameConfig().difficulty
	if d == Difficulty.Easy then
		return 2500
	elseif d == Difficulty.Medium then
		return 5000
	elseif d == Difficulty.Hard then
		return 12500
	end
	return 25000
end
function DonateGoldExecution:_relationUpdate(goldSent: number, ticks: number): number
	local chunk = self:_chunkSize()
	-- Chunk size grows every 5 minutes of play.
	local mult = ticks / (3000 + self.mg:config():numSpawnPhaseTurns())
	local adjusted = math.floor(chunk + chunk * mult + 0.5)
	local chunks = goldSent // adjusted
	return math.min(100, chunks * 5)
end
function DonateGoldExecution:tick(ticks: number)
	local sender, recipient = self.sender, self.recipient
	if sender:canDonateGold(recipient) and sender:donateGold(recipient, self.gold) then
		local update = self:_relationUpdate(self.gold, ticks)
		if update > 0 then
			recipient:updateRelation(sender, update)
		end
		-- Only nations answer with an emoji.
		if recipient:type() == PlayerType.Nation and recipient:canSendEmoji(sender) then
			local E = NationEmoji()
			local list = if update >= 50 then E.EMOJI_LOVE elseif update > 0 then E.EMOJI_DONATION_OK else E.EMOJI_DONATION_TOO_SMALL
			self.mg:addExecution(EmojiExecution.new(recipient, sender:id(), self.random:randElement(list)))
		end
	end
	self._active = false
end

local DonateTroopsExecution = oneShot({})
M.DonateTroopsExecution = DonateTroopsExecution

function DonateTroopsExecution.new(sender, recipientID: string, troops: number?)
	return setmetatable({ sender = sender, recipientID = recipientID, troops = troops, _active = true }, DonateTroopsExecution)
end
function DonateTroopsExecution:init(mg, _ticks: number)
	self.mg = mg
	self.random = PseudoRandom.new(mg:ticks())
	if not mg:hasPlayer(self.recipientID) then
		self._active = false
		return
	end
	self.recipient = mg:player(self.recipientID)
	if self.troops == nil then
		self.troops = mg:config():defaultDonationAmount(self.sender)
	end
	local maxDonation = mg:config():maxTroops(self.recipient) - self.recipient:troops()
	self.troops = math.min(self.troops, maxDonation)
	if self.troops <= 0 then
		self._active = false
	end
end
function DonateTroopsExecution:_minTroopsForRelationUpdate(): number
	local d = self.mg:config():gameConfig().difficulty
	local max = self.mg:config():maxTroops(self.recipient)
	if d == Difficulty.Easy then
		return self.random:nextInt(max / 13, max / 11)
	elseif d == Difficulty.Medium then
		return self.random:nextInt(max / 11, max / 9)
	elseif d == Difficulty.Hard then
		return self.random:nextInt(max / 9, max / 7)
	end
	return self.random:nextInt(max / 7, max / 5)
end
function DonateTroopsExecution:tick(_ticks: number)
	local sender, recipient = self.sender, self.recipient
	local minTroops = self:_minTroopsForRelationUpdate()
	if sender:canDonateTroops(recipient) and sender:donateTroops(recipient, self.troops) then
		-- A minimum (randomised) is needed to buy relation.
		if self.troops >= minTroops then
			recipient:updateRelation(sender, 50)
		end
		if recipient:type() == PlayerType.Nation and recipient:canSendEmoji(sender) then
			local E = NationEmoji()
			self.mg:addExecution(
				EmojiExecution.new(recipient, sender:id(), self.random:randElement(if self.troops >= minTroops then E.EMOJI_LOVE else E.EMOJI_DONATION_TOO_SMALL))
			)
		end
	end
	self._active = false
end

return M
