-- Port of upstream hud/layers/ChatModal.ts: quick chat. Columns Category →
-- Phrase → Player (phrases with [P1] need a player; search box and "sort by
-- territory"), a preview line and Send. Sends category.key (+ player).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local QuickChat = require(Shared:WaitForChild("Data"):WaitForChild("QuickChat"))
local Style = require(script.Parent.Style)
local Modal = require(script.Parent.Modal)
local Lang = require(script.Parent.Lang)

local F = Style.font
local Z = Modal.zinc
local SELECTED = Color3.fromHex("#4f46e5")

local ChatModal = {}

ChatModal.categories = QuickChat

-- Phrase text for a "category.key" (used by the events feed too).
function ChatModal.phraseText(category: string, key: string): string?
	for _, c in QuickChat do
		if c.id == category then
			for _, p in c.phrases do
				if p.key == key then
					return p.text
				end
			end
		end
	end
	return nil
end

-- opts = { gui, recipientName, players() -> { { smallID, name, tiles, color } },
--          onSend(key, playerSmallID?) }
function ChatModal.open(opts)
	local _, card, close = Modal.open(opts.gui, "ChatModal", 640, 125)
	local title = Style.text(card, "Title", Lang.t("Quick Chat — {name}", { name = opts.recipientName }), 18, F.bold, Z.z50)
	title.LayoutOrder = 1
	title.ZIndex = card.ZIndex + 1

	local cols = Style.frame(card, "Columns")
	cols.LayoutOrder = 2
	cols.Size = UDim2.new(1, 0, 0, 300)
	cols.ZIndex = card.ZIndex + 1
	Style.row(cols, 8, Enum.VerticalAlignment.Top)

	local preview = Style.text(card, "Preview", "Build your message...", 15, F.semibold, Z.z200)
	preview.LayoutOrder = 3
	preview.ZIndex = card.ZIndex + 1
	preview.TextWrapped = true

	local sendRow = Style.frame(card, "SendRow")
	sendRow.LayoutOrder = 4
	sendRow.Size = UDim2.new(1, 0, 0, 40)
	sendRow.ZIndex = card.ZIndex + 1
	local send = Style.button(sendRow, "Send", "Send", 15, F.semibold)
	send.AutomaticSize = Enum.AutomaticSize.None
	send.AnchorPoint = Vector2.new(1, 0)
	send.Position = UDim2.fromScale(1, 0)
	send.Size = UDim2.fromOffset(110, 40)
	send.BackgroundColor3 = SELECTED
	send.BackgroundTransparency = 0
	send.ZIndex = sendRow.ZIndex + 1
	Style.corner(send, 8)

	local state = { category = nil, phrase = nil, player = nil, search = "", sortByTerritory = false }

	local function column(name: string, order: number, widthScale: number)
		local col = Style.frame(cols, name)
		col.LayoutOrder = order
		col.Size = UDim2.new(widthScale, -6, 1, 0)
		col.ZIndex = cols.ZIndex + 1
		Style.column(col, 6)
		return col
	end
	local catCol = column("Category", 1, 0.25)
	local phraseCol = column("Phrase", 2, 0.4)
	local playerCol = column("Player", 3, 0.35)

	local function header(col, text)
		local h = Style.text(col, "Header", text, 13, F.bold, Z.z400)
		h.LayoutOrder = 0
		h.ZIndex = col.ZIndex + 1
	end
	local function scroller(col, order: number, height: number)
		local s = Instance.new("ScrollingFrame")
		s.BackgroundTransparency = 1
		s.BorderSizePixel = 0
		s.LayoutOrder = order
		s.Size = UDim2.new(1, 0, 0, height)
		s.AutomaticCanvasSize = Enum.AutomaticSize.Y
		s.CanvasSize = UDim2.fromOffset(0, 0)
		s.ScrollBarThickness = 4
		s.ZIndex = col.ZIndex + 1
		s.Parent = col
		Style.column(s, 4)
		return s
	end
	local function option(parent, text: string, order: number, selected: boolean, border: Color3?)
		local b = Style.button(parent, "Option", text, 13, F.semibold)
		b.AutomaticSize = Enum.AutomaticSize.Y
		b.Size = UDim2.new(1, -6, 0, 30)
		b.TextWrapped = true
		b.LayoutOrder = order
		b.BackgroundColor3 = if selected then SELECTED else Z.z800
		b.BackgroundTransparency = 0
		b.ZIndex = parent.ZIndex + 1
		Style.corner(b, 6)
		Style.padding(b, 6, 4)
		if border then
			Style.stroke(b, border, 2)
		end
		return b
	end

	local render
	local function phraseDef()
		if not state.category then
			return nil
		end
		for _, p in state.category.phrases do
			if p.key == state.phrase then
				return p
			end
		end
		return nil
	end
	local function refreshPreview()
		local p = phraseDef()
		if not p then
			preview.Text = "Build your message..."
		else
			local name = if state.player then state.player.name else "[P1]"
			preview.Text = (string.gsub(p.text, "%[P1%]", function()
				return name
			end))
		end
		local ok = p ~= nil and (not p.requiresPlayer or state.player ~= nil)
		send.BackgroundTransparency = if ok then 0 else 0.5
		send.TextTransparency = if ok then 0 else 0.5
		return ok
	end

	function render()
		for _, col in { catCol, phraseCol, playerCol } do
			for _, c in col:GetChildren() do
				if c:IsA("GuiObject") then
					c:Destroy()
				end
			end
		end
		header(catCol, "Category")
		for i, c in QuickChat do
			option(catCol, c.name, i, state.category == c).Activated:Connect(function()
				state.category = c
				state.phrase = nil
				state.player = nil
				render()
			end)
		end
		if state.category then
			header(phraseCol, "Phrase")
			local s = scroller(phraseCol, 1, 270)
			for i, p in state.category.phrases do
				option(s, p.text, i, state.phrase == p.key).Activated:Connect(function()
					state.phrase = p.key
					if not p.requiresPlayer then
						state.player = nil
					end
					render()
				end)
			end
		end
		local p = phraseDef()
		if p and p.requiresPlayer then
			header(playerCol, "Player")
			local sortBtn = option(playerCol, (if state.sortByTerritory then "☑ " else "☐ ") .. "Sort by territory", 1, false)
			sortBtn.Activated:Connect(function()
				state.sortByTerritory = not state.sortByTerritory
				render()
			end)
			local box = Instance.new("TextBox")
			box.Name = "Search"
			box.PlaceholderText = "Search..."
			box.Text = state.search
			box.ClearTextOnFocus = false
			box.FontFace = F.medium
			box.TextSize = 13
			box.TextColor3 = Color3.new(1, 1, 1)
			box.BackgroundColor3 = Z.z800
			box.Size = UDim2.new(1, -6, 0, 28)
			box.LayoutOrder = 2
			box.ZIndex = playerCol.ZIndex + 1
			box.Parent = playerCol
			Style.corner(box, 6)
			box.FocusLost:Connect(function()
				state.search = box.Text
				render()
			end)
			local s = scroller(playerCol, 3, 190)
			local list = opts.players()
			local q = string.lower(state.search)
			local filtered = {}
			for _, pl in list do
				if q == "" or string.find(string.lower(pl.name), q, 1, true) then
					table.insert(filtered, pl)
				end
			end
			table.sort(filtered, function(a, b)
				if state.sortByTerritory and a.tiles ~= b.tiles then
					return a.tiles > b.tiles
				end
				return string.lower(a.name) < string.lower(b.name)
			end)
			for i, pl in filtered do
				option(s, pl.name, i, state.player and state.player.smallID == pl.smallID, pl.color).Activated:Connect(function()
					state.player = pl
					render()
				end)
			end
		end
		refreshPreview()
	end

	send.Activated:Connect(function()
		if not refreshPreview() then
			return
		end
		opts.onSend(`{state.category.id}.{state.phrase}`, state.player and state.player.smallID)
		close()
	end)
	render()
	return close
end

return ChatModal
