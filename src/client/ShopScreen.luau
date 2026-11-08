-- Cosmetics shop (Roblox monetisation; upstream's store sells its own
-- proprietary skins). A large panel with category tabs on the left and
-- cards on the right: Featured (subscription banner, deal of the day, free
-- trial, bundles), Passes, Patterns, Name colours, Nuke blasts.
-- Everything is cosmetic or a lobby convenience (no pay-to-win).

local AdService = game:GetService("AdService")
local AssetService = game:GetService("AssetService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Shop = require(Shared:WaitForChild("Data"):WaitForChild("Shop"))
local Style = require(script.Parent.Style)
local Modal = require(script.Parent.Modal)
local Lang = require(script.Parent.Lang)
local FlagAtlas = require(script.Parent.FlagAtlas)

local F = Style.font
local Z = 120 -- base ZIndex

local COL = {
	shade = Color3.fromRGB(3, 4, 16),
	panel = Color3.fromRGB(12, 14, 38),
	side = Color3.fromRGB(8, 9, 28),
	card = Color3.fromRGB(22, 25, 62),
	cardHi = Color3.fromRGB(34, 38, 88),
	preview = Color3.fromRGB(16, 18, 50),
	ocean = Color3.fromRGB(40, 44, 110),
	text = Color3.fromRGB(243, 244, 246),
	sub = Color3.fromRGB(156, 163, 175),
	buy = Color3.fromRGB(0, 176, 111), -- Roblox green
	equip = Color3.fromRGB(91, 96, 214),
	equipped = Color3.fromRGB(46, 50, 100),
	gold = Color3.fromRGB(242, 201, 160),
	goldDark = Color3.fromRGB(150, 100, 70),
	tab = Color3.fromRGB(22, 25, 62),
}

local ShopScreen = {}

local function rgb(c): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function hours(seconds: number): string
	return `{math.max(1, math.ceil(seconds / 3600))} h`
end

-- Pattern swatch drawn like a territory: player colour + border colour cells.
local swatchCache = {}
local function patternSwatch(item)
	local img = swatchCache[item.id]
	if img then
		return img
	end
	local size = 64
	img = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
	local px = buffer.create(size * size * 4)
	local cell = 4
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local cx, cy = (x // cell) % #item.rows[1], (y // cell) % #item.rows
			local secondary = string.sub(item.rows[cy + 1], cx + 1, cx + 1) == "#"
			local o = (y * size + x) * 4
			buffer.writeu8(px, o, if secondary then 29 else 96)
			buffer.writeu8(px, o + 1, if secondary then 78 else 165)
			buffer.writeu8(px, o + 2, if secondary then 216 else 250)
			buffer.writeu8(px, o + 3, 255)
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), px)
	swatchCache[item.id] = img
	return img
end

-- Small helpers ------------------------------------------------------------------------

local function frame(parent: Instance, name: string, color: Color3?, z: number?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color or Color3.new()
	f.BackgroundTransparency = if color then 0 else 1
	f.ZIndex = z or Z
	f.Parent = parent
	return f
end

local function text(parent: Instance, name: string, s: string, size: number, font: Font?, color: Color3?, z: number?): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Text = s
	t.TextSize = size
	t.FontFace = font or F.semibold
	t.TextColor3 = color or COL.text
	t.TextWrapped = true
	t.ZIndex = z or Z
	t.Parent = parent
	return t
end

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function gradient(parent: Instance, a: Color3, b: Color3, rotation: number?)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(a, b)
	g.Rotation = rotation or 90
	g.Parent = parent
end

local function pill(parent: Instance, label: string, color: Color3, z: number, onClick: (() -> ())?)
	local b = Instance.new("TextButton")
	b.Name = "Action"
	b.AutoButtonColor = onClick ~= nil
	b.Text = label
	b.TextSize = 15
	b.FontFace = F.bold
	b.TextColor3 = Color3.new(1, 1, 1)
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.ZIndex = z
	b.Parent = parent
	corner(b, 8)
	if onClick then
		b.Activated:Connect(onClick)
	else
		b.TextTransparency = 0.35
	end
	return b
end

-- Shop -----------------------------------------------------------------------------------

function ShopScreen.open(gui: Instance, net)
	local closed = false
	local state = nil
	local adReady = false
	local activeTab = "featured"

	-- Backdrop + panel.
	local shade = Instance.new("TextButton")
	shade.Name = "Shop"
	shade.Text = ""
	shade.AutoButtonColor = false
	shade.BackgroundColor3 = COL.shade
	shade.BackgroundTransparency = 0.35
	shade.BorderSizePixel = 0
	shade.Size = UDim2.fromScale(1, 1)
	shade.ZIndex = Z
	shade.Parent = gui

	local screen = gui.AbsoluteSize
	local compact = screen.X < 760
	local panel = Instance.new("TextButton") -- swallows clicks
	panel.Name = "Panel"
	panel.Text = ""
	panel.AutoButtonColor = false
	panel.BackgroundColor3 = COL.panel
	panel.BorderSizePixel = 0
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(math.min(1040, screen.X - 24), math.min(660, screen.Y - 24))
	panel.ZIndex = Z + 1
	panel.Parent = shade
	corner(panel, 16)
	stroke(panel, Color3.new(1, 1, 1), 1, 0.9)

	local function close()
		if closed then
			return
		end
		closed = true
		shade:Destroy()
	end
	shade.Activated:Connect(close)

	-- Header.
	local header = frame(panel, "Header", nil, Z + 2)
	header.Size = UDim2.new(1, 0, 0, 64)
	local title = text(header, "Title", Lang.t("Shop"), 26, F.bold, COL.text, Z + 2)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Position = UDim2.fromOffset(24, 10)
	title.Size = UDim2.new(0, 200, 0, 30)
	local subtitle = text(header, "Subtitle", Lang.t("Cosmetics only — no pay-to-win"), 14, F.medium, COL.sub, Z + 2)
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Position = UDim2.fromOffset(24, 38)
	subtitle.Size = UDim2.new(1, -120, 0, 18)
	local x = Instance.new("TextButton")
	x.Name = "Close"
	x.Text = "×"
	x.TextSize = 24
	x.FontFace = F.bold
	x.TextColor3 = COL.text
	x.BackgroundColor3 = COL.card
	x.AnchorPoint = Vector2.new(1, 0)
	x.Position = UDim2.new(1, -16, 0, 14)
	x.Size = UDim2.fromOffset(36, 36)
	x.ZIndex = Z + 3
	x.Parent = header
	corner(x, 18)
	x.Activated:Connect(close)

	-- Sidebar tabs.
	local sideW = if compact then 116 else 190
	local side = frame(panel, "Tabs", COL.side, Z + 2)
	side.Position = UDim2.fromOffset(0, 64)
	side.Size = UDim2.new(0, sideW, 1, -64)
	local sideList = Instance.new("UIListLayout")
	sideList.Padding = UDim.new(0, 6)
	sideList.SortOrder = Enum.SortOrder.LayoutOrder
	sideList.Parent = side
	local sidePad = Instance.new("UIPadding")
	sidePad.PaddingTop = UDim.new(0, 14)
	sidePad.PaddingLeft = UDim.new(0, 10)
	sidePad.PaddingRight = UDim.new(0, 10)
	sidePad.Parent = side
	local sideCorner = frame(side, "Corner", COL.side, Z + 1) -- square off the top
	sideCorner.Size = UDim2.new(1, 0, 0, 16)
	sideCorner.Position = UDim2.fromOffset(0, -14)

	-- Content.
	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Position = UDim2.fromOffset(sideW, 64)
	content.Size = UDim2.new(1, -sideW, 1, -64)
	content.CanvasSize = UDim2.fromOffset(0, 0)
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollBarThickness = 6
	content.ScrollBarImageColor3 = COL.sub
	content.ZIndex = Z + 2
	content.Parent = panel
	local contentList = Instance.new("UIListLayout")
	contentList.Padding = UDim.new(0, 16)
	contentList.SortOrder = Enum.SortOrder.LayoutOrder
	contentList.Parent = content
	local contentPad = Instance.new("UIPadding")
	contentPad.PaddingTop = UDim.new(0, 16)
	contentPad.PaddingLeft = UDim.new(0, 18)
	contentPad.PaddingRight = UDim.new(0, 18)
	contentPad.PaddingBottom = UDim.new(0, 18)
	contentPad.Parent = content

	local render

	local function refresh(delay: number?)
		task.delay(delay or 0.3, function()
			if closed then
				return
			end
			local ok, st = pcall(function()
				return net.Query:InvokeServer({ kind = "shop" })
			end)
			if ok and st and not closed then
				state = st
				render()
			end
		end)
	end
	local function equip(slot: string, value)
		net.Intent:FireServer({ type = "equip", slot = slot, value = value })
		refresh()
	end

	-- Card grid inside the content area.
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end
	local function heading(s: string)
		local h = text(content, "Heading", s, 18, F.bold, COL.text, Z + 3)
		h.LayoutOrder = nextOrder()
		h.TextXAlignment = Enum.TextXAlignment.Left
		h.Size = UDim2.new(1, 0, 0, 22)
		return h
	end
	local function grid(cellH: number)
		local g = frame(content, "Grid", nil, Z + 2)
		g.LayoutOrder = nextOrder()
		g.Size = UDim2.new(1, 0, 0, 0)
		g.AutomaticSize = Enum.AutomaticSize.Y
		local l = Instance.new("UIGridLayout")
		l.CellPadding = UDim2.fromOffset(12, 12)
		l.CellSize = UDim2.fromOffset(if compact then 150 else 176, cellH)
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.Parent = g
		return g
	end

	-- A card: preview area on top, name + sub text, action button at the bottom.
	local function card(parent: Instance, name: string, subText: string?, accent: Color3?)
		local c = frame(parent, "Card", COL.card, Z + 3)
		c.LayoutOrder = nextOrder()
		corner(c, 12)
		if accent then
			stroke(c, accent, 2)
		end
		local prev = frame(c, "Preview", COL.preview, Z + 4)
		prev.Position = UDim2.fromOffset(8, 8)
		prev.Size = UDim2.new(1, -16, 0, 104)
		corner(prev, 10)
		local n = text(c, "Name", name, 15, F.bold, COL.text, Z + 4)
		n.Position = UDim2.fromOffset(10, 118)
		n.Size = UDim2.new(1, -20, 0, 20)
		n.TextTruncate = Enum.TextTruncate.AtEnd
		if subText then
			local sLabel = text(c, "Sub", subText, 12, F.medium, COL.sub, Z + 4)
			sLabel.Position = UDim2.fromOffset(10, 138)
			sLabel.Size = UDim2.new(1, -20, 0, 46)
			sLabel.TextYAlignment = Enum.TextYAlignment.Top
		end
		return c, prev
	end
	local function action(c: Frame, label: string, color: Color3, onClick: (() -> ())?)
		local b = pill(c, label, color, Z + 5, onClick)
		b.AnchorPoint = Vector2.new(0.5, 1)
		b.Position = UDim2.new(0.5, 0, 1, -10)
		b.Size = UDim2.new(1, -20, 0, 36)
		return b
	end
	local function buyProduct(c: Frame, productId: number, price: number)
		if productId == 0 then
			return action(c, Lang.t("Soon"), COL.equipped)
		end
		return action(c, `R$ {price}`, COL.buy, function()
			MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
		end)
	end

	-- Previews.
	local function previewItem(prev: Frame, item)
		if item.kind == "pattern" then
			prev.BackgroundColor3 = COL.ocean
			local img = Instance.new("ImageLabel")
			img.BackgroundTransparency = 1
			img.AnchorPoint = Vector2.new(0.5, 0.5)
			img.Position = UDim2.fromScale(0.5, 0.5)
			img.Size = UDim2.fromOffset(84, 84)
			img.ImageContent = Content.fromObject(patternSwatch(item))
			img.ResampleMode = Enum.ResamplerMode.Pixelated
			img.ZIndex = Z + 5
			img.Parent = prev
			corner(img, 10)
			stroke(img, Color3.fromRGB(29, 78, 216), 3)
		elseif item.kind == "explosion" then
			prev.BackgroundColor3 = COL.ocean
			local ring = frame(prev, "Ring", nil, Z + 5)
			ring.AnchorPoint = Vector2.new(0.5, 0.5)
			ring.Position = UDim2.fromScale(0.5, 0.5)
			ring.Size = UDim2.fromOffset(84, 84)
			corner(ring, 42)
			stroke(ring, rgb(item.ring), 5)
			local flash = frame(prev, "Flash", rgb(item.flash), Z + 6)
			flash.AnchorPoint = Vector2.new(0.5, 0.5)
			flash.Position = UDim2.fromScale(0.5, 0.5)
			flash.Size = UDim2.fromOffset(46, 46)
			flash.BackgroundTransparency = 0.1
			corner(flash, 23)
		else
			local sample = text(prev, "Sample", Players.LocalPlayer.DisplayName, 22, F.bold, rgb(item.color), Z + 5)
			sample.Size = UDim2.fromScale(1, 1)
			sample.TextTruncate = Enum.TextTruncate.AtEnd
			local s = Instance.new("UIStroke")
			s.Color = Color3.new(0, 0, 0)
			s.Thickness = 1.5
			s.Parent = sample
		end
	end
	local function glyph(prev: Frame, s: string, size: number, color: Color3?)
		local g = text(prev, "Glyph", s, size, F.bold, color or COL.text, Z + 5)
		g.Size = UDim2.fromScale(1, 1)
		return g
	end

	-- Pickers ------------------------------------------------------------------------
	local function picker(titleText: string, cellW: number, build: (Instance, () -> ()) -> ())
		local _, pcard, pclose = Modal.open(gui, "Picker", math.min(560, screen.X - 40), Z + 20)
		local t = Style.text(pcard, "Title", titleText, 18, F.bold, COL.text)
		t.LayoutOrder = 1
		t.ZIndex = pcard.ZIndex + 1
		local s = Instance.new("ScrollingFrame")
		s.BackgroundTransparency = 1
		s.BorderSizePixel = 0
		s.LayoutOrder = 2
		s.Size = UDim2.new(1, 0, 0, math.min(380, screen.Y - 160))
		s.AutomaticCanvasSize = Enum.AutomaticSize.Y
		s.CanvasSize = UDim2.fromOffset(0, 0)
		s.ScrollBarThickness = 4
		s.ZIndex = pcard.ZIndex + 1
		s.Parent = pcard
		local g = Instance.new("UIGridLayout")
		g.CellPadding = UDim2.fromOffset(8, 8)
		g.CellSize = UDim2.fromOffset(cellW, math.floor(cellW * 0.7))
		g.SortOrder = Enum.SortOrder.LayoutOrder
		g.Parent = s
		build(s, pclose)
	end
	local function colorPicker(current: number?)
		picker(Lang.t("Pick your territory colour"), 56, function(s, pclose)
			for i, c in Shop.COLORS do
				local b = Instance.new("TextButton")
				b.Text = ""
				b.BackgroundColor3 = rgb(c)
				b.LayoutOrder = i
				b.ZIndex = s.ZIndex + 1
				b.Parent = s
				corner(b, 8)
				stroke(b, if i == current then Color3.new(1, 1, 1) else Color3.new(0, 0, 0), if i == current then 3 else 1, if i == current then 0 else 0.6)
				b.Activated:Connect(function()
					equip("color", i)
					pclose()
				end)
			end
		end)
	end
	local function flagPicker(current: string?)
		picker(Lang.t("Pick your flag"), 48, function(s, pclose)
			for i, code in FlagAtlas.codes do
				local b = Instance.new("ImageButton")
				b.BackgroundColor3 = COL.card
				b.LayoutOrder = i
				b.ZIndex = s.ZIndex + 1
				b.Parent = s
				FlagAtlas.apply(b :: any, code)
				stroke(b, if code == current then Color3.new(1, 1, 1) else Color3.new(0, 0, 0), if code == current then 3 else 1, if code == current then 0 else 0.6)
				b.Activated:Connect(function()
					equip("flag", code)
					pclose()
				end)
			end
		end)
	end

	-- Sections -------------------------------------------------------------------------
	local function itemGrid(kind: string)
		local g = grid(212)
		local perks = state.perks or {}
		local trials = state.trials or {}
		for _, item in Shop.items do
			if item.kind ~= kind then
				continue
			end
			local slot = Shop.SLOTS[item.kind]
			local owned = state.owned[item.id] or perks.plus
			local trial = trials[item.id]
			local equipped = state.equipped[slot] == item.id
			local sub = if owned then Lang.t("Owned") elseif trial then Lang.t("Trial: {hours} left", { hours = hours(trial) }) else nil
			local c, prev = card(g, Lang.t(item.name), sub, if equipped then COL.equip else nil)
			previewItem(prev, item)
			if owned or trial then
				if equipped then
					action(c, Lang.t("Equipped") .. " ✓", COL.equipped, function()
						equip(slot, nil)
					end)
				else
					action(c, Lang.t("Equip"), COL.equip, function()
						equip(slot, item.id)
					end)
				end
			else
				buyProduct(c, item.productId, item.price)
			end
		end
	end

	local function passCard(g: Instance, key: string)
		local pass = Shop.PASSES[key]
		local perks = state.perks or {}
		local has = perks[key] == true
		local c, prev = card(g, Lang.t(pass.name), Lang.t(pass.desc), if key == "supporter" then COL.gold else nil)
		if key == "supporter" then
			glyph(prev, "★", 56, COL.gold)
		elseif key == "color" then
			local row = frame(prev, "Swatches", nil, Z + 5)
			row.AnchorPoint = Vector2.new(0.5, 0.5)
			row.Position = UDim2.fromScale(0.5, 0.5)
			row.Size = UDim2.fromOffset(120, 56)
			local l = Instance.new("UIGridLayout")
			l.CellSize = UDim2.fromOffset(26, 26)
			l.CellPadding = UDim2.fromOffset(4, 4)
			l.Parent = row
			for _, i in { 1, 3, 6, 9, 11, 13, 16, 36 } do
				local sw = frame(row, "Swatch", rgb(Shop.COLORS[i]), Z + 6)
				corner(sw, 6)
			end
		elseif key == "host" then
			glyph(prev, "👑", 50)
		elseif key == "flag" then
			local f = Instance.new("ImageLabel")
			f.BackgroundTransparency = 1
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.Position = UDim2.fromScale(0.5, 0.5)
			f.Size = UDim2.fromOffset(84, 56)
			f.ZIndex = Z + 5
			f.Parent = prev
			FlagAtlas.apply(f, (state.equipped and state.equipped.flag) or "pl")
			corner(f, 4)
		end
		if has and key == "color" then
			local cur = state.equipped and state.equipped.color
			action(c, Lang.t("Pick colour"), COL.equip, function()
				colorPicker(cur)
			end)
		elseif has and key == "flag" then
			action(c, Lang.t("Pick flag"), COL.equip, function()
				flagPicker(state.equipped and state.equipped.flag)
			end)
		elseif has then
			action(c, Lang.t("Owned") .. " ✓", COL.equipped)
		elseif pass.id ~= 0 then
			action(c, `R$ {pass.price}`, COL.buy, function()
				MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, pass.id)
			end)
		else
			action(c, Lang.t("Soon"), COL.equipped)
		end
	end

	local function plusBanner()
		if Shop.SUBSCRIPTION_ID == "" then
			return
		end
		local perks = state.perks or {}
		local b = frame(content, "Plus", COL.goldDark, Z + 3)
		b.LayoutOrder = nextOrder()
		b.Size = UDim2.new(1, 0, 0, if compact then 170 else 150)
		corner(b, 14)
		gradient(b, Color3.fromRGB(202, 138, 4), Color3.fromRGB(120, 53, 15), 20)
		local star = text(b, "Star", "★", 64, F.bold, Color3.fromRGB(254, 240, 138), Z + 4)
		star.Position = UDim2.fromOffset(18, 0)
		star.Size = UDim2.fromOffset(70, 150)
		local t = text(b, "Title", "Command Plus", 26, F.bold, Color3.new(1, 1, 1), Z + 4)
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.Position = UDim2.fromOffset(96, 18)
		t.Size = UDim2.new(1, -300, 0, 32)
		local d = text(b, "Perks", Lang.t("Every cosmetic, custom colour, flags and Host Pass perks while subscribed."), 14, F.medium, Color3.fromRGB(254, 243, 199), Z + 4)
		d.TextXAlignment = Enum.TextXAlignment.Left
		d.TextYAlignment = Enum.TextYAlignment.Top
		d.Position = UDim2.fromOffset(96, 54)
		d.Size = UDim2.new(1, if compact then -110 else -300, 0, 60)
		local btn
		if perks.plus then
			btn = pill(b, Lang.t("Active") .. " ✓", Color3.fromRGB(120, 53, 15), Z + 5)
		else
			btn = pill(b, Lang.t("Subscribe {price}/month", { price = Shop.SUBSCRIPTION_PRICE }), Color3.fromRGB(12, 14, 38), Z + 5, function()
				MarketplaceService:PromptSubscriptionPurchase(Players.LocalPlayer, Shop.SUBSCRIPTION_ID)
			end)
		end
		if compact then
			btn.AnchorPoint = Vector2.new(0, 1)
			btn.Position = UDim2.new(0, 96, 1, -14)
			btn.Size = UDim2.fromOffset(220, 40)
		else
			btn.AnchorPoint = Vector2.new(1, 0.5)
			btn.Position = UDim2.new(1, -20, 0.5, 0)
			btn.Size = UDim2.fromOffset(230, 46)
		end
	end

	local function featured()
		plusBanner()
		heading(Lang.t("Specials"))
		local g = grid(212)
		local deal = state.daily and Shop.byId[state.daily]
		if deal and Shop.DAILY_DEAL.productId ~= 0 then
			local c, prev = card(g, Lang.t(deal.name), Lang.t("Deal of the day") .. " · " .. Lang.t("{hours} left", { hours = hours(state.dailySecondsLeft or 0) }), COL.gold)
			previewItem(prev, deal)
			local tag = text(prev, "Was", `R$ {deal.price}`, 13, F.bold, Color3.fromRGB(252, 165, 165), Z + 6)
			tag.AnchorPoint = Vector2.new(1, 0)
			tag.Position = UDim2.new(1, -8, 0, 6)
			tag.Size = UDim2.fromOffset(60, 16)
			tag.TextXAlignment = Enum.TextXAlignment.Right
			local strike = frame(tag, "Strike", Color3.fromRGB(252, 165, 165), Z + 7)
			strike.AnchorPoint = Vector2.new(1, 0.5)
			strike.Position = UDim2.fromScale(1, 0.5)
			strike.Size = UDim2.fromOffset(44, 2)
			buyProduct(c, Shop.DAILY_DEAL.productId, Shop.DAILY_DEAL.price)
		end
		if Shop.AD_REWARD.productId ~= 0 and adReady then
			local c, prev = card(g, Lang.t("Free trial"), Lang.t("Watch a short ad and try a random cosmetic for 24 h."), COL.buy)
			glyph(prev, "🎁", 50)
			local b = action(c, Lang.t("Watch ad"), COL.buy, function()
				adReady = false
				net.Intent:FireServer({ type = "watch_ad" })
				refresh(8)
			end)
			pcall(function()
				AdService:RegisterAdOpportunityAsync(b)
			end)
		end
		for _, bundle in Shop.bundles do
			local count, worth = 0, 0
			for _, it in Shop.items do
				if bundle.kinds[it.kind] then
					count += 1
					worth += it.price
				end
			end
			local c, prev = card(g, Lang.t(bundle.name), Lang.t("{count} items (worth R$ {worth})", { count = count, worth = worth }), Color3.fromRGB(129, 140, 248))
			prev.BackgroundColor3 = COL.ocean
			if bundle.id == "bundle_everything" then
				glyph(prev, "💎", 54)
				buyProduct(c, bundle.productId, bundle.price)
				continue
			end
			local k = 0
			for _, it in Shop.items do
				if it.kind == "pattern" and k < 3 then
					k += 1
					local img = Instance.new("ImageLabel")
					img.BackgroundTransparency = 1
					img.AnchorPoint = Vector2.new(0.5, 0.5)
					img.Position = UDim2.new(0.5, (k - 2) * 34, 0.5, (k - 2) * -6)
					img.Size = UDim2.fromOffset(58, 58)
					img.Rotation = (k - 2) * 8
					img.ImageContent = Content.fromObject(patternSwatch(it))
					img.ZIndex = Z + 5 + k
					img.Parent = prev
					corner(img, 8)
					stroke(img, Color3.fromRGB(29, 78, 216), 2)
				end
			end
			buyProduct(c, bundle.productId, bundle.price)
		end
	end

	local TABS = {
		{ id = "featured", label = "Featured", icon = "★" },
		{ id = "passes", label = "Passes", icon = "🎟" },
		{ id = "pattern", label = "Patterns", icon = "▦" },
		{ id = "nameColor", label = "Name colours", icon = "Aa" },
		{ id = "explosion", label = "Nuke blasts", icon = "💥" },
	}
	local tabButtons = {}
	for i, tab in TABS do
		local b = Instance.new("TextButton")
		b.Name = tab.id
		b.LayoutOrder = i
		b.Size = UDim2.new(1, 0, 0, 42)
		b.BackgroundColor3 = COL.tab
		b.BackgroundTransparency = 1
		b.AutoButtonColor = false
		b.Text = if compact then Lang.t(tab.label) else `{tab.icon}   {Lang.t(tab.label)}`
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.TextSize = if compact then 13 else 16
		b.FontFace = F.semibold
		b.TextColor3 = COL.sub
		b.ZIndex = Z + 3
		b.Parent = side
		corner(b, 10)
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 12)
		pad.Parent = b
		b.Activated:Connect(function()
			activeTab = tab.id
			render()
		end)
		tabButtons[tab.id] = b
	end

	function render()
		if closed then
			return
		end
		for id, b in tabButtons do
			local on = id == activeTab
			b.BackgroundTransparency = if on then 0 else 1
			b.TextColor3 = if on then COL.text else COL.sub
		end
		for _, ch in content:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		order = 0
		if state == nil then
			local l = text(content, "Loading", Lang.t("Loading…"), 16, F.medium, COL.sub, Z + 3)
			l.Size = UDim2.new(1, 0, 0, 40)
			return
		end
		if not state.loaded then
			local l = text(content, "Loading", Lang.t("Your profile is still loading…"), 14, F.medium, COL.sub, Z + 3)
			l.LayoutOrder = nextOrder()
			l.Size = UDim2.new(1, 0, 0, 20)
		end
		if activeTab == "featured" then
			featured()
		elseif activeTab == "passes" then
			heading(Lang.t("Passes"))
			local g = grid(236)
			for _, key in { "color", "host", "supporter" } do
				passCard(g, key)
			end
		else
			local label = if activeTab == "pattern" then "Patterns" elseif activeTab == "nameColor" then "Name colours" else "Nuke blasts"
			heading(Lang.t(label))
			itemGrid(activeTab)
		end
		content.CanvasPosition = Vector2.zero
	end

	local conns = {
		MarketplaceService.PromptProductPurchaseFinished:Connect(function(_, _, purchased)
			if purchased then
				refresh(2) -- the server grants it in ProcessReceipt
			end
		end),
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(_, _, purchased)
			if purchased then
				refresh(1)
			end
		end),
	}
	pcall(function()
		table.insert(conns, MarketplaceService.PromptSubscriptionPurchaseFinished:Connect(function()
			refresh(2)
		end))
	end)
	shade.Destroying:Connect(function()
		closed = true
		for _, c in conns do
			c:Disconnect()
		end
	end)

	render()
	refresh(0)
	if Shop.AD_REWARD.productId ~= 0 then
		task.spawn(function()
			-- Ask for an ad only when the shop opens (AdService guidance).
			local ok, result = pcall(function()
				return AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)
			end)
			if ok and result and result.AdAvailabilityResult == Enum.AdAvailabilityResult.IsAvailable then
				adReady = true
				refresh(0)
			end
		end)
	end
	return close
end

return ShopScreen
