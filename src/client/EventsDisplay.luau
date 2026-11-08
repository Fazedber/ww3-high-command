-- Event feed, ported from upstream hud/layers/EventsDisplay.ts (bottom
-- right, w-96): server messages (DisplayEvent / UnitIncoming, alliance,
-- donation, emoji and chat events) for us, plus ActionableEvents.ts: alliance
-- requests (Focus / Accept / Reject) and renewal prompts (Focus / Request to
-- renew / Ignore) as cards with a yellow left border above the feed.
--   * tier 1 (nukes inbound / detonated, naval invasion, conquests, …):
--     bg-gray-800 panel with a red left border, text-lg
--   * tier 2 (everything else): bg-gray-800/92, text-sm, last 4 only
--   * events expire after 80 ticks; inbound warnings also when the unit is gone
--   * clicking a row focuses the player / unit
-- Colours: getMessageTypeClasses (severityColors).

local Style = require(script.Parent.Style)
local Lang = require(script.Parent.Lang)

local C, F = Style.color, Style.font

-- GameTypes.MessageType values.
local MT = {
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
}

local TIER_1 = {
	[MT.NUKE_INBOUND] = true,
	[MT.HYDROGEN_BOMB_INBOUND] = true,
	[MT.MIRV_INBOUND] = true,
	[MT.NUKE_DETONATED] = true,
	[MT.NAVAL_INVASION_INBOUND] = true,
	[MT.ATTACK_REQUEST] = true,
	[MT.ALLIANCE_ACCEPTED] = true,
	[MT.ALLIANCE_REJECTED] = true,
	[MT.ALLIANCE_BROKEN] = true,
	[MT.RENEW_ALLIANCE] = true,
	[MT.CONQUERED_PLAYER] = true,
	[MT.CHAT] = true,
	[MT.DONATION_RECEIVED] = true,
}

local INBOUND = {
	[MT.NUKE_INBOUND] = true,
	[MT.HYDROGEN_BOMB_INBOUND] = true,
	[MT.MIRV_INBOUND] = true,
	[MT.NAVAL_INVASION_INBOUND] = true,
}

local RED, YELLOW, GREEN, GRAY, BLUE = Color3.fromHex("#f87171"), C.yellow400, C.green400, C.gray200, C.blue400
local function severity(t: number): Color3
	if t == MT.SAM_HIT or t == MT.CAPTURED_ENEMY_UNIT or t == MT.CONQUERED_PLAYER or t == MT.ALLIANCE_ACCEPTED then
		return GREEN
	elseif t == MT.ATTACK_FAILED or t == MT.ALLIANCE_REJECTED or t == MT.ALLIANCE_BROKEN or t == MT.UNIT_DESTROYED or t == MT.NUKE_DETONATED then
		return RED
	elseif t == MT.ATTACK_CANCELLED or t == MT.ATTACK_REQUEST or t == MT.DONATION_SENT or t == MT.DONATION_RECEIVED then
		return BLUE
	elseif INBOUND[t] or t == MT.SAM_MISS or t == MT.ALLIANCE_EXPIRED or t == MT.RENEW_ALLIANCE then
		return YELLOW
	elseif t == MT.CHAT or t == MT.ALLIANCE_REQUEST then
		return GRAY
	end
	return C.white
end

-- en.json "events_display" / "unit_type" (the keys the simulation emits).
local TEXTS = {
	["events_display.atom_bomb_detonated"] = "{name} - atom bomb detonated",
	["events_display.hydrogen_bomb_detonated"] = "{name} - hydrogen bomb detonated",
	["events_display.attack_cancelled_retreat"] = "Attack cancelled, {troops} soldiers killed during retreat",
	["events_display.conquered_no_gold"] = "Conquered {name} (didn't play, no gold awarded)",
	["events_display.missile_intercepted"] = "SAM intercepted {unit}",
	["events_display.no_boats_available"] = "No boats available, max {max}",
	["events_display.received_gold_from_conquest"] = "Conquered {name}, received {gold} gold",
	["events_display.received_gold_from_player"] = "Received {gold} gold from {name}",
	["events_display.received_troops_from_player"] = "Received {troops} troops from {name}",
	["events_display.trade_ship_captured"] = "Your trade ship was captured by {name}",
	["events_display.unit_destroyed"] = "Your {unit} was destroyed",
	["events_display.unit_voluntarily_deleted"] = "Unit voluntarily deleted",
	["events_display.betrayed_you"] = "{name} broke their alliance with you",
	["events_display.alliance_request_status"] = "{name} {status} your alliance request",
	["events_display.alliance_request_sent"] = "Alliance request sent to {name}.",
	["events_display.betrayal_description"] = "You broke your alliance with {name}, making you a TRAITOR ({malusPercent}% defense debuff for {durationText})",
	["events_display.alliance_expired"] = "Your alliance with {name} expired",
	["events_display.sent_gold_to_player"] = "Sent {gold} gold to {name}",
	["events_display.sent_troops_to_player"] = "Sent {troops} troops to {name}",
	["events_display.attack_request"] = "{name} requests you attack {target}",
	["events_display.sent_emoji"] = "Sent {name}: {emoji}",
	["events_display.request_alliance"] = "{name} requests an alliance!",
	["events_display.about_to_expire"] = "Your alliance with {name} is about to expire!",
}
local UNIT_NAMES = {
	["unit_type.atom_bomb"] = "Atom Bomb",
	["unit_type.boat"] = "Boat",
	["unit_type.city"] = "City",
	["unit_type.defense_post"] = "Defense Post",
	["unit_type.factory"] = "Factory",
	["unit_type.hydrogen_bomb"] = "Hydrogen Bomb",
	["unit_type.mirv"] = "MIRV",
	["unit_type.missile_silo"] = "Missile Silo",
	["unit_type.port"] = "Port",
	["unit_type.sam_launcher"] = "SAM Launcher",
	["unit_type.warship"] = "Warship",
}

local function translate(message: string, params): string
	local text = Lang.t(TEXTS[message] or message)
	return (string.gsub(text, "{(%w+)}", function(k)
		local v = params and params[k]
		if type(v) == "string" and UNIT_NAMES[v] then
			return Lang.t(UNIT_NAMES[v])
		end
		return if v ~= nil then tostring(v) else "{" .. k .. "}"
	end))
end

local EventsDisplay = {}
EventsDisplay.__index = EventsDisplay

-- deps: { gui, tickNow() -> number, unitActive(id) -> boolean,
--         playerName(smallID) -> string?, focusPlayer(smallID), focusUnit(id), visible() -> boolean }
function EventsDisplay.new(deps)
	local self = setmetatable({ deps = deps, events = {}, dirty = true }, EventsDisplay)
	local column = Style.frame(deps.gui, "EventsDisplay")
	column.AnchorPoint = Vector2.new(1, 1)
	column.Position = UDim2.new(1, -8, 1, -8)
	column.Size = UDim2.fromOffset(384, 0) -- min-[1200px]:w-96
	column.AutomaticSize = Enum.AutomaticSize.Y
	column.ZIndex = 20
	local layout = Style.column(column, 4)
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	self.column = column

	local function panel(name: string, order: number, alpha: number, borderLeft: boolean)
		-- Outer frame (background, red left border) + padded row list; the
		-- border stays out of the list layout. Returns the list frame.
		local outer = Style.frame(column, name, C.gray800, alpha)
		outer.LayoutOrder = order
		outer.Size = UDim2.fromScale(1, 0)
		outer.AutomaticSize = Enum.AutomaticSize.Y
		outer.Active = true
		outer.Visible = false
		outer.ClipsDescendants = true
		Style.corner(outer, 8)
		if borderLeft then
			local bar = Style.frame(outer, "Border", Color3.fromHex("#ef4444"), 1)
			bar.Size = UDim2.new(0, 4, 1, 0)
		end
		local p = Style.frame(outer, "Rows")
		p.Size = UDim2.fromScale(1, 0)
		p.AutomaticSize = Enum.AutomaticSize.Y
		Style.padding(p, if borderLeft then 10 else 6, 2)
		Style.column(p, 0)
		return p
	end
	self.tier2 = panel("Tier2", 1, 0.92 * 0.9, false)
	self.tier1 = panel("Tier1", 2, 1, true)
	self.actionable = {}
	self.alliancesCheckedAt = {} -- allianceID -> tick prompted
	local act = Style.frame(column, "Actionable")
	act.LayoutOrder = 0
	act.Size = UDim2.fromScale(1, 0)
	act.AutomaticSize = Enum.AutomaticSize.Y
	Style.column(act, 8)
	self.actPanel = act

	task.spawn(function()
		while column.Parent do
			self:_expire()
			if self.dirty then
				self:_render()
			end
			task.wait(0.1)
		end
	end)
	return self
end

function EventsDisplay:add(evt)
	-- Captured trade-ship gold is the gold pip in the control panel instead.
	if evt.message == "events_display.received_gold_from_captured_ship" then
		return
	end
	local params = evt.params or {}
	if evt.focusPlayerID and params.name ~= nil and not evt.keepNames then
		params = table.clone(params)
		params.name = self.deps.playerName(evt.focusPlayerID) or params.name
	end
	table.insert(self.events, {
		description = if evt.type == "Incoming" or evt.raw then evt.message else translate(evt.message, params),
		type = evt.messageType,
		createdAt = self.deps.tickNow(),
		focusID = evt.focusPlayerID,
		unitID = evt.unitID,
	})
	if #self.events > 30 then
		table.remove(self.events, 1)
	end
	self.dirty = true
end

function EventsDisplay:_expire()
	local now = self.deps.tickNow()
	local keep = {}
	for _, e in self.events do
		local expired = now - e.createdAt >= 80
		local unitGone = INBOUND[e.type] and e.unitID ~= nil and not self.deps.unitActive(e.unitID)
		if not expired and not unitGone then
			table.insert(keep, e)
		end
	end
	if #keep ~= #self.events then
		self.events = keep
		self.dirty = true
	end
	for _, c in self.actionable do
		if c.duration and now - c.createdAt >= c.duration then
			self.dirty = true
			break
		end
	end
end

function EventsDisplay:_row(parent: Frame, e, order: number, big: boolean)
	local b = Style.button(parent, "Row", e.description, if big then 18 else 14, if big then F.medium else F.medium, severity(e.type))
	b.LayoutOrder = order
	b.AutomaticSize = Enum.AutomaticSize.Y
	b.Size = UDim2.fromScale(1, 0)
	b.TextWrapped = true
	b.TextXAlignment = Enum.TextXAlignment.Left
	Style.padding(b, 4, 4)
	b.Activated:Connect(function()
		if e.focusID then
			self.deps.focusPlayer(e.focusID)
		elseif e.unitID then
			self.deps.focusUnit(e.unitID)
		end
	end)
end

function EventsDisplay:_render()
	self.dirty = false
	self:_renderActionable()
	for _, p in { self.tier1, self.tier2 } do
		for _, c in p:GetChildren() do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
	end
	local visible = self.deps.visible()
	local t1, t2 = {}, {}
	for _, e in self.events do
		table.insert(if TIER_1[e.type] then t1 else t2, e)
	end
	while #t2 > 4 do
		table.remove(t2, 1)
	end
	for i, e in t1 do
		self:_row(self.tier1, e, i, true)
	end
	for i, e in t2 do
		self:_row(self.tier2, e, i, false)
	end
	self.tier1.Parent.Visible = visible and #t1 > 0
	self.tier2.Parent.Visible = visible and #t2 > 0
end

function EventsDisplay:refresh()
	self.dirty = true
end

-- ActionableEvents -------------------------------------------------------------------------

local BUTTON_COLORS = {
	gray = C.gray500,
	green = Color3.fromHex("#16a34a"),
	blue = Color3.fromHex("#3b82f6"),
}

function EventsDisplay:_addActionable(card)
	table.insert(self.actionable, card)
	self.dirty = true
end

function EventsDisplay:_removeActionable(pred: (any) -> boolean)
	local keep = {}
	for _, c in self.actionable do
		if not pred(c) then
			table.insert(keep, c)
		end
	end
	if #keep ~= #self.actionable then
		self.actionable = keep
		self.dirty = true
	end
end

-- AllianceRequest update addressed to us.
function EventsDisplay:allianceRequest(requestor: number, duration: number)
	local deps = self.deps
	if deps.alive and not deps.alive() then
		return
	end
	local name = deps.playerName(requestor) or "?"
	self:_removeActionable(function(c)
		return c.type == MT.ALLIANCE_REQUEST and c.requestorID == requestor
	end)
	self:_addActionable({
		description = translate("events_display.request_alliance", { name = name }),
		type = MT.ALLIANCE_REQUEST,
		createdAt = deps.tickNow(),
		duration = duration,
		priority = 0,
		focusID = requestor,
		requestorID = requestor,
		buttons = {
			{ text = "Focus", color = "gray", preventClose = true, action = function()
				deps.focusPlayer(requestor)
			end },
			{ text = "Accept", color = "green", action = function()
				deps.sendIntent({ type = "alliance_request", target = requestor })
			end },
			{ text = "Reject", color = "blue", action = function()
				deps.sendIntent({ type = "alliance_reject", target = requestor })
			end },
		},
	})
end

function EventsDisplay:allianceRequestResolved(requestor: number)
	self:_removeActionable(function(c)
		return c.type == MT.ALLIANCE_REQUEST and c.focusID == requestor
	end)
end

function EventsDisplay:allianceGone(allianceID: number)
	self:_removeActionable(function(c)
		return c.type == MT.RENEW_ALLIANCE and c.allianceID == allianceID
	end)
	self.alliancesCheckedAt[allianceID] = nil
end

-- Per Me update: drop requests nobody makes any more, prompt renewals
-- (checkForAllianceExpirations) and forget alliances that ended.
function EventsDisplay:updateAlliances(me)
	if not me.alliances then
		return
	end
	local asking = {}
	for _, id in me.requestsIn or {} do
		asking[id] = true
	end
	self:_removeActionable(function(c)
		return c.type == MT.ALLIANCE_REQUEST and not asking[c.requestorID]
	end)
	local deps = self.deps
	local tick, offset = me.tick, me.extensionPromptOffset or 0
	local current = {}
	for _, a in me.alliances do
		current[a.id] = true
		if a.expiresAt > tick + offset then
			continue
		end
		if (self.alliancesCheckedAt[a.id] or 0) >= tick - offset then
			continue
		end
		self.alliancesCheckedAt[a.id] = tick
		local other = a.other
		local name = deps.playerName(other) or "?"
		self:_addActionable({
			description = translate("events_display.about_to_expire", { name = name }),
			type = MT.RENEW_ALLIANCE,
			createdAt = deps.tickNow(),
			focusID = other,
			requestorID = other,
			allianceID = a.id,
			buttons = {
				{ text = "Focus", color = "gray", preventClose = true, action = function()
					deps.focusPlayer(other)
				end },
				{ text = "Request to renew", color = "green", action = function()
					deps.sendIntent({ type = "alliance_extend", target = other })
				end },
				{ text = "Ignore", color = "blue", action = function() end },
			},
		})
	end
	for id in self.alliancesCheckedAt do
		if not current[id] then
			self:allianceGone(id)
		end
	end
end

function EventsDisplay:_renderActionable()
	local panel = self.actPanel
	for _, c in panel:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	local now = self.deps.tickNow()
	local keep = {}
	for _, c in self.actionable do
		if c.duration == nil or now - c.createdAt < c.duration then
			table.insert(keep, c)
		end
	end
	self.actionable = keep
	local sorted = table.clone(keep)
	table.sort(sorted, function(a, b)
		local pa, pb = a.priority or 100000, b.priority or 100000
		if pa == pb then
			return a.createdAt > b.createdAt
		end
		return pa > pb
	end)
	-- ActionableEvents hides entirely once our player is dead.
	local alive = self.deps.alive == nil or self.deps.alive()
	if not alive and #self.actionable > 0 then
		self.actionable = {}
		sorted = {}
	end
	local visible = self.deps.visible()
	panel.Visible = visible and alive and #sorted > 0
	for i, card in sorted do
		-- Card: yellow left border (border-l-4) outside the padded content, so it
		-- never takes part in the content layout.
		local card0 = Style.frame(panel, "Card", C.gray800, 0.92)
		card0.LayoutOrder = i
		card0.Size = UDim2.fromScale(1, 0)
		card0.AutomaticSize = Enum.AutomaticSize.Y
		card0.Active = true
		card0.ClipsDescendants = true
		Style.corner(card0, 8)
		local bar = Style.frame(card0, "Border", C.yellow400, 1)
		bar.Size = UDim2.new(0, 4, 1, 0)
		local f = Style.frame(card0, "Content")
		f.Size = UDim2.fromScale(1, 0)
		f.AutomaticSize = Enum.AutomaticSize.Y
		Style.padding(f, 14, 10)
		Style.column(f, 8)
		local d = Style.button(f, "Description", card.description, 15, F.semibold, severity(card.type))
		d.LayoutOrder = 1
		d.AutomaticSize = Enum.AutomaticSize.Y
		d.Size = UDim2.fromScale(1, 0)
		d.TextWrapped = true
		d.TextXAlignment = Enum.TextXAlignment.Left
		d.Activated:Connect(function()
			self.deps.focusPlayer(card.focusID)
		end)
		local row = Style.frame(f, "Buttons")
		row.LayoutOrder = 2
		row.Size = UDim2.fromScale(1, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		local rl = Style.row(row, 6)
		rl.Wraps = true
		for j, btn in card.buttons do
			local b = Style.button(row, btn.text, btn.text, 13, F.medium)
			b.LayoutOrder = j
			b.BackgroundColor3 = BUTTON_COLORS[btn.color]
			b.BackgroundTransparency = 0
			Style.corner(b, 3)
			Style.padding(b, 12, 4)
			b.Activated:Connect(function()
				btn.action()
				if not btn.preventClose then
					self:_removeActionable(function(c)
						return c == card
					end)
				end
			end)
		end
	end
end

return EventsDisplay
