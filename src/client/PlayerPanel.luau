-- Port of upstream hud/layers/PlayerPanel.ts: the player info panel (radial
-- "info"). Identity (name, Nation / Tribe chip, traitor badge, a nation's
-- relation to us), gold and troops, rocket-arc toggle (own panel),
-- betrayals and trading state, the alliance list with expiry timers, our
-- alliance's time left, and the actions: chat, emojis, target, send troops /
-- gold, stop / start trading, break alliance, send alliance (own panel:
-- stop / start trading with all). Data comes from the server's "player"
-- query and refreshes every second while open.

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Style = require(script.Parent.Style)
local Modal = require(script.Parent.Modal)
local SendResourceModal = require(script.Parent.SendResourceModal)
local ChatModal = require(script.Parent.ChatModal)

local F = Style.font
local Z = Modal.zinc

local RELATION = {
	[0] = { name = "Hostile", color = Color3.fromHex("#fecaca") },
	[1] = { name = "Distrustful", color = Color3.fromHex("#fca5a5") },
	[2] = { name = "Neutral", color = Color3.fromHex("#e4e4e7") },
	[3] = { name = "Friendly", color = Color3.fromHex("#a7f3d0") },
}

local PlayerPanel = {}
PlayerPanel.__index = PlayerPanel

-- Everything the panel displays, at display resolution (seconds, rounded numbers).
local function signature(d): string
	if d == nil then
		return ""
	end
	local parts = { d.name, Format.renderNumber(d.gold or 0), Format.renderTroops(d.troops or 0), tostring(d.betrayals), tostring(d.embargoAgainstMe), tostring(d.relationToMe), tostring(d.isAlliedWithMe), tostring(d.canSendEmojiAllPlayers), tostring(d.canEmbargoAll) }
	if d.traitorTicks then
		table.insert(parts, tostring(math.ceil(d.traitorTicks / 10)))
	end
	for _, a in d.alliances do
		table.insert(parts, a.name .. ":" .. math.floor((a.expiresAt - d.tick) / 10))
	end
	local i = d.interaction
	if i then
		for _, k in { "canSendEmoji", "canTarget", "canSendAllianceRequest", "canBreakAlliance", "canDonateGold", "canDonateTroops", "canEmbargo" } do
			table.insert(parts, tostring(i[k]))
		end
		if i.allianceInfo then
			table.insert(parts, tostring(math.floor((i.allianceInfo.expiresAt - d.tick) / 10)))
		end
	end
	return table.concat(parts, "|")
end

-- deps = { gui, net, emojiTable, players() (for chat), rocketUp() -> bool,
--          setRocketUp(bool), onAllianceRequestSent(name) }
function PlayerPanel.new(deps)
	return setmetatable({ deps = deps, closeFn = nil, tile = nil, data = nil }, PlayerPanel)
end

function PlayerPanel:isVisible(): boolean
	return self.closeFn ~= nil
end

function PlayerPanel:hide()
	if self.closeFn then
		local f = self.closeFn
		self.closeFn = nil
		f()
	end
end

function PlayerPanel:show(tile: number)
	self:hide()
	self.tile = tile
	local data = self.deps.net.Query:InvokeServer({ kind = "player", tile = tile })
	if data == nil then
		return
	end
	self:_render(data)
	local token = {}
	self.token = token
	task.spawn(function()
		while self.token == token and self.closeFn do
			task.wait(1)
			if self.token ~= token or not self.closeFn then
				break
			end
			local fresh = self.deps.net.Query:InvokeServer({ kind = "player", tile = tile })
			if self.token ~= token or not self.closeFn then
				break
			end
			if fresh == nil then
				self:hide()
				break
			end
			-- Re-render only when something shown changed (upstream re-renders per tick).
			if signature(fresh) ~= signature(self.data) then
				self:_render(fresh)
			end
		end
	end)
end

function PlayerPanel:_intent(t)
	self.deps.net.Intent:FireServer(t)
end

function PlayerPanel:_render(d)
	-- Rebuild in place (keeps the backdrop while refreshing).
	if self.closeFn then
		self.rebuilding = true
		self.closeFn()
		self.rebuilding = false
	end
	self.data = d
	local backdrop, card, close = Modal.open(self.deps.gui, "PlayerPanel", 380, 100, function()
		if not self.rebuilding then
			self.closeFn = nil
			self.token = nil
		end
	end)
	self.closeFn = close
	local z = card.ZIndex + 1
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end
	local function txt(parent, name, s, size, font, color)
		local l = Style.text(parent, name, s, size, font, color)
		l.ZIndex = z
		return l
	end

	if d.traitorTicks then
		-- traitor-ring: red glow around the card.
		Style.stroke(card, Color3.fromRGB(239, 68, 68), 2, 0.5)
	end

	-- Identity ------------------------------------------------------------------------
	local idRow = Style.frame(card, "Identity")
	idRow.LayoutOrder = nextOrder()
	idRow.Size = UDim2.new(1, -30, 0, 30)
	idRow.ZIndex = z
	Style.row(idRow, 10)
	local name = txt(idRow, "Name", d.name, 20, F.bold, Z.z50)
	name.LayoutOrder = 1
	name.TextTruncate = Enum.TextTruncate.AtEnd
	if d.playerType == "NATION" or d.playerType == "BOT" then
		local nation = d.playerType == "NATION"
		local chip = txt(idRow, "Chip", (if nation then "🏛️ Nation" else "⚔️ Tribe"), 12, F.semibold, if nation then Color3.fromHex("#c7d2fe") else Color3.fromHex("#e9d5ff"))
		chip.LayoutOrder = 2
		chip.BackgroundColor3 = if nation then Color3.fromHex("#6366f1") else Color3.fromHex("#a855f7")
		chip.BackgroundTransparency = 0.9
		Style.corner(chip, 10)
		Style.padding(chip, 8, 2)
		Style.stroke(chip, if nation then Color3.fromHex("#818cf8") else Color3.fromHex("#c084fc"), 1, 0.75)
	end
	if d.traitorTicks then
		local secs = math.ceil(d.traitorTicks / 10)
		local badge = txt(card, "Traitor", `Traitor · {Modal.duration(secs)}`, 14, F.semibold, Color3.fromHex("#fecaca"))
		badge.LayoutOrder = nextOrder()
		badge.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
		badge.BackgroundTransparency = 0.9
		Style.corner(badge, 10)
		Style.padding(badge, 10, 2)
		Style.stroke(badge, Color3.fromHex("#f87171"), 1, 0.7)
	end
	if d.relationToMe ~= nil and not d.traitorTicks and not d.isAlliedWithMe and not d.isSelf then
		local rel = RELATION[d.relationToMe] or RELATION[2]
		local pill = txt(card, "Relation", rel.name, 14, F.semibold, rel.color)
		pill.LayoutOrder = nextOrder()
		pill.BackgroundColor3 = rel.color
		pill.BackgroundTransparency = 0.9
		Style.corner(pill, 10)
		Style.padding(pill, 10, 2)
	end
	Modal.divider(card, nextOrder())

	-- Resources -------------------------------------------------------------------------
	local res = Style.frame(card, "Resources")
	res.LayoutOrder = nextOrder()
	res.Size = UDim2.new(1, 0, 0, 34)
	res.ZIndex = z
	local rl = Style.row(res, 8)
	rl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	for i, spec in { { "💰", Format.renderNumber(d.gold or 0), "Gold" }, { "🛡️", Format.renderTroops(d.troops or 0), "Troops" } } do
		local box = Style.frame(res, spec[3], Color3.new(1, 1, 1), 0.04)
		box.LayoutOrder = i
		box.Size = UDim2.new(0.5, -4, 1, 0)
		box.ZIndex = z
		Style.corner(box, 8)
		local l = txt(box, "Text", `{spec[1]}  <b>{spec[2]}</b>  {spec[3]}`, 15, F.medium, Color3.new(1, 1, 1))
		l.RichText = true
		l.AnchorPoint = Vector2.new(0.5, 0.5)
		l.Position = UDim2.fromScale(0.5, 0.5)
	end

	if d.isSelf then
		Modal.divider(card, nextOrder())
		local up = self.deps.rocketUp()
		local b = Style.button(card, "RocketArc", "", 14)
		b.AutomaticSize = Enum.AutomaticSize.None
		b.Size = UDim2.new(1, 0, 0, 48)
		b.BackgroundColor3 = Color3.new(1, 1, 1)
		b.BackgroundTransparency = 0.95
		b.LayoutOrder = nextOrder()
		b.ZIndex = z
		Style.corner(b, 12)
		local t1 = txt(b, "Title", "Flip rocket trajectory", 14, F.semibold, Color3.new(1, 1, 1))
		t1.Position = UDim2.fromOffset(12, 6)
		local t2 = txt(b, "Sub", if up then "Upward arc" else "Downward arc", 12, F.medium, Z.z300)
		t2.Position = UDim2.fromOffset(12, 26)
		local t3 = txt(b, "Icon", "🔀", 18, F.medium)
		t3.AnchorPoint = Vector2.new(1, 0.5)
		t3.Position = UDim2.new(1, -12, 0.5, 0)
		b.Activated:Connect(function()
			self.deps.setRocketUp(not self.deps.rocketUp())
			self:_render(self.data)
		end)
	end

	-- Stats -------------------------------------------------------------------------------
	Modal.divider(card, nextOrder())
	local function statRow(label: string, value: string, color: Color3)
		local row = Style.frame(card, label)
		row.LayoutOrder = nextOrder()
		row.Size = UDim2.new(1, 0, 0, 22)
		row.ZIndex = z
		txt(row, "Label", label, 15, F.medium, Z.z100)
		local v = txt(row, "Value", value, 14, F.semibold, color)
		v.AnchorPoint = Vector2.new(1, 0)
		v.Position = UDim2.fromScale(1, 0)
	end
	statRow("⚠️  Betrayals", tostring(d.betrayals or 0), Z.z200)
	if d.embargoAgainstMe then
		statRow("⚓  Trading", "Stopped", Color3.fromHex("#fbbf24"))
	else
		statRow("⚓  Trading", "Active", Color3.fromHex("#60a5fa"))
	end

	-- Alliances ---------------------------------------------------------------------------
	Modal.divider(card, nextOrder())
	local ahead = Style.frame(card, "AlliancesHeader")
	ahead.LayoutOrder = nextOrder()
	ahead.Size = UDim2.new(1, 0, 0, 22)
	ahead.ZIndex = z
	txt(ahead, "Title", "Alliances", 15, F.medium, Z.z200)
	local count = txt(ahead, "Count", tostring(#d.alliances), 12, F.medium, Z.z100)
	count.AnchorPoint = Vector2.new(1, 0)
	count.Position = UDim2.fromScale(1, 0)
	count.BackgroundColor3 = Color3.new(1, 1, 1)
	count.BackgroundTransparency = 0.9
	Style.corner(count, 10)
	Style.padding(count, 6, 1)
	local box = Style.frame(card, "AlliancesList", Z.z800, 0.7)
	box.LayoutOrder = nextOrder()
	box.Size = UDim2.new(1, 0, 0, 0)
	box.AutomaticSize = Enum.AutomaticSize.Y
	box.ZIndex = z
	Style.corner(box, 8)
	Style.padding(box, 8)
	local wrap = Style.row(box, 6)
	wrap.Wraps = true
	local allies = table.clone(d.alliances)
	table.sort(allies, function(a, b)
		if a.expiresAt ~= b.expiresAt then
			return a.expiresAt < b.expiresAt
		end
		return string.lower(a.name) < string.lower(b.name)
	end)
	if #allies == 0 then
		txt(box, "None", "None", 14, F.medium, Z.z400)
	end
	for i, a in allies do
		local secs = math.max(0, math.floor((a.expiresAt - d.tick) / 10))
		local chip = txt(box, "Ally", `{a.name}  <font color="#{Modal.expiryColor(secs):ToHex()}" size="11"><b>{Modal.duration(secs)}</b></font>`, 14, F.medium, Z.z100)
		chip.RichText = true
		chip.LayoutOrder = i
		chip.BackgroundColor3 = Color3.new(1, 1, 1)
		chip.BackgroundTransparency = 0.95
		Style.corner(chip, 6)
		Style.padding(chip, 8, 3)
		Style.stroke(chip, Color3.new(1, 1, 1), 1, 0.9)
	end
	local interaction = d.interaction
	if interaction and interaction.allianceInfo then
		local secs = math.max(0, math.floor((interaction.allianceInfo.expiresAt - d.tick) / 10))
		statRow("Alliance Expires In", Modal.duration(secs), Modal.expiryColor(secs))
	end

	-- Actions -----------------------------------------------------------------------------
	Modal.divider(card, nextOrder())
	local deps = self.deps
	local canSendEmoji = if d.isSelf then d.canSendEmojiAllPlayers else interaction and interaction.canSendEmoji
	local row1 = {}
	table.insert(row1, { "chat", "Chat", "normal", false, function()
		close()
		ChatModal.open({
			gui = deps.gui,
			recipientName = d.name,
			players = deps.players,
			onSend = function(key, playerSmallID)
				self:_intent({ type = "quick_chat", target = d.smallID, key = key, chatTarget = playerSmallID })
			end,
		})
	end })
	if canSendEmoji then
		table.insert(row1, { "emoji", "Emojis", "normal", false, function()
			close()
			deps.emojiTable:showTable(function(index)
				self:_intent({ type = "emoji", target = if d.isSelf then 0 else d.smallID, emoji = index })
				deps.emojiTable:hideTable()
			end)
		end })
	end
	if interaction and interaction.canTarget then
		table.insert(row1, { "target", "Target", "normal", false, function()
			self:_intent({ type = "target_player", target = d.smallID })
			close()
		end })
	end
	if interaction and interaction.canDonateTroops then
		table.insert(row1, { "donateTroop", "Troops", "normal", false, function()
			self:openSend("troops", d)
		end })
	end
	if interaction and interaction.canDonateGold then
		table.insert(row1, { "donateGold", "Gold", "normal", false, function()
			self:openSend("gold", d)
		end })
	end
	local r1 = Modal.buttonRow(card, nextOrder(), #row1)
	for i, b in row1 do
		Modal.actionButton(r1, i, b[1], b[2], b[3], b[4], b[5])
	end
	Modal.divider(card, nextOrder())
	local row2 = {}
	if not d.isSelf and interaction then
		if interaction.canEmbargo then
			table.insert(row2, { "stopTrading", "Stop Trading", "yellow", false, function()
				self:_intent({ type = "embargo", target = d.smallID, action = "start" })
				close()
			end })
		else
			table.insert(row2, { "startTrading", "Start Trading", "green", false, function()
				self:_intent({ type = "embargo", target = d.smallID, action = "stop" })
				close()
			end })
		end
		if interaction.canBreakAlliance then
			table.insert(row2, { "traitor", "Break Alliance", "red", false, function()
				self:_intent({ type = "break_alliance", target = d.smallID })
				close()
			end })
		end
		if interaction.canSendAllianceRequest then
			table.insert(row2, { "alliance", "Send Alliance", "indigo", false, function()
				self:_intent({ type = "alliance_request", target = d.smallID })
				if deps.onAllianceRequestSent then
					deps.onAllianceRequestSent(d.smallID, d.name)
				end
				close()
			end })
		end
	elseif d.isSelf then
		local cooldown = not d.canEmbargoAll
		table.insert(row2, { "stopTrading", if cooldown then "Stop Trading with All ⏳" else "Stop Trading with All", "yellow", cooldown, function()
			self:_intent({ type = "embargo_all", action = "start" })
			close()
		end })
		table.insert(row2, { "startTrading", if cooldown then "Start Trading with All ⏳" else "Start Trading with All", "green", cooldown, function()
			self:_intent({ type = "embargo_all", action = "stop" })
			close()
		end })
	end
	if #row2 > 0 then
		local r2 = Modal.buttonRow(card, nextOrder(), #row2)
		for i, b in row2 do
			Modal.actionButton(r2, i, b[1], b[2], b[3], b[4], b[5])
		end
	end
	return backdrop
end

-- SendResourceModal for the panel's player (also the radial "donate gold").
function PlayerPanel:openSend(mode: string, d)
	self:hide()
	SendResourceModal.open({
		gui = self.deps.gui,
		mode = mode,
		total = if mode == "troops" then d.myTroops else d.myGold,
		capacity = if mode == "troops" then d.capacity else nil,
		targetName = d.name,
		targetAlive = true,
		onSend = function(amount)
			self:_intent({ type = if mode == "troops" then "donate_troops" else "donate_gold", target = d.smallID, amount = amount })
		end,
	})
end

function PlayerPanel:openSendGoldAt(tile: number)
	local d = self.deps.net.Query:InvokeServer({ kind = "player", tile = tile })
	if d then
		self:openSend("gold", d)
	end
end

return PlayerPanel
