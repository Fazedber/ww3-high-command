-- HighCommand: собственная оболочка игры в стиле HoI4 (меню, соло, онлайн, 1v1).
-- Заменяет стандартный лобби-экран: сама рулит настройками лобби через Net.Intent.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapCatalog = require(Shared:WaitForChild("Data"):WaitForChild("MapCatalog"))
local Icons = require(script.Parent.Icons)
local Locale = require(script.Parent:WaitForChild("Locale"))
local L = Locale.pick

local P = {
	gold = Color3.fromRGB(138, 143, 240),      -- fire accent
	goldDim = Color3.fromRGB(45, 48, 110),
	parchment = Color3.fromRGB(244, 236, 226),
	text = Color3.fromRGB(232, 226, 214),
	dim = Color3.fromRGB(128, 128, 172),
	dark = Color3.fromRGB(5, 6, 20),
	panel = Color3.fromRGB(10, 12, 32),
	red = Color3.fromRGB(214, 48, 40),
	green = Color3.fromRGB(150, 200, 110),
}
local ICON = {
	solo = "Assets_IconSolo", online = "Assets_IconOnline", duel = "Assets_IconDuel",
	settings = "Assets_IconSettings", crown = "Assets_IconCrown", map = "Assets_IconMap",
	star = "Assets_IconStar", arrowRight = "Assets_IconArrow",
}
-- Asset IDs (загружены из assets_ui).
local A = {
	bg = "rbxassetid://75065617184983",
	panel = "rbxassetid://126316263687056",
	button = "rbxassetid://100489699933263",
	buttonHover = "rbxassetid://123384927098208",
	map = "rbxassetid://112252363227122",
}
local F = {
	title = Font.fromEnum(Enum.Font.Arcade),
	body = Font.fromEnum(Enum.Font.Arcade),
	small = Font.fromEnum(Enum.Font.Arcade),
}
local LOCAL_ID = Players.LocalPlayer.UserId
local D_ORDER = 300

local function fmtGold(n)
	n = math.floor(n or 0)
	if n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	elseif n >= 1000 then
		return string.format("%.1fK", n / 1000)
	end
	return tostring(n)
end

local HighCommand = {}
HighCommand.__index = HighCommand

local function corner(o, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, math.min(r or 2, 2))
	c.Parent = o
end

local function stroke(o, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = o
	return s
end

local function text(parent, name, txt, size, color, font)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.FontFace = font or F.body
	l.TextSize = size
	l.TextColor3 = color or P.text
	l.Text = txt or ""
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

local function sliceImage(parent, asset, rect)
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Image = asset
	img.ScaleType = Enum.ScaleType.Slice
	img.SliceCenter = rect or Rect.new(24, 18, 168, 46)
	img.Size = UDim2.fromScale(1, 1)
	img.Parent = parent
	return img
end

local function panel(parent)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = P.panel
	f.BackgroundTransparency = 0.06
	f.BorderSizePixel = 0
	f.Parent = parent
	corner(f, 3)
	stroke(f, P.goldDim, 1, 0.15)
	return f
end

-- Nine-slice button with icon and caption (HoI4-style).
local function makeButton(parent, iconName, caption, order, height)
	local holder = Instance.new("Frame")
	holder.Name = caption:gsub("%s", "_")
	holder.Size = UDim2.new(1, 0, 0, height or 58)
	holder.BackgroundTransparency = 1
	holder.LayoutOrder = order or 0
	holder.Parent = parent
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(10, 12, 32)
	bg.BackgroundTransparency = 0.04
	bg.BorderSizePixel = 0
	bg.Parent = holder
	corner(bg, 2)
	stroke(bg, P.goldDim, 1, 0.1)
	local hover = Instance.new("Frame")
	hover.Size = UDim2.fromScale(1, 1)
	hover.BackgroundColor3 = Color3.fromRGB(138, 143, 240)
	hover.BackgroundTransparency = 1
	hover.BorderSizePixel = 0
	hover.Parent = holder
	corner(hover, 2)
	local icon = Icons.label(holder, iconName, 34, { color = P.gold })
	icon.Position = UDim2.fromOffset(18, 14)
	icon.AnchorPoint = Vector2.new(0, 0)
	local label = text(holder, "Caption", caption, 23, P.parchment, F.title)
	label.Position = UDim2.fromOffset(66, 0)
	label.Size = UDim2.new(1, -80, 1, 0)
	label.TextYAlignment = Enum.TextYAlignment.Center
	local btn = Instance.new("TextButton")
	btn.Name = "Click"
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.Size = UDim2.fromScale(1, 1)
	btn.Parent = holder
	btn.MouseEnter:Connect(function()
		hover.BackgroundTransparency = 0.7
		label.TextColor3 = Color3.fromRGB(236, 232, 255)
		icon.ImageColor3 = Color3.fromRGB(214, 210, 255)
	end)
	btn.MouseLeave:Connect(function()
		hover.BackgroundTransparency = 1
		label.TextColor3 = P.parchment
		icon.ImageColor3 = P.gold
	end)
	return btn, label, icon, holder
end

function HighCommand.new(net, lobbyScreen, opts)
	local self = setmetatable({ net = net, lobby = lobbyScreen, onLocaleChange = opts and opts.onLocaleChange }, HighCommand)

	local gui = Instance.new("ScreenGui")
	gui.Name = "HighCommand"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = D_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	self.gui = gui
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	self.openFront = pg:FindFirstChild("OpenFront")

	-- full-screen background (the scaled root only fits the design area)
	local bgFull = Instance.new("ImageLabel")
	bgFull.Name = "MenuBackground"
	bgFull.Size = UDim2.fromScale(1, 1)
	bgFull.BackgroundTransparency = 1
	-- Pixel world silhouette built from the World map thumbnail (violet, no orange asset).
	bgFull.BackgroundColor3 = Color3.fromRGB(5, 6, 20)
	bgFull.BackgroundTransparency = 0
	bgFull.ScaleType = Enum.ScaleType.Fit
	bgFull.ResampleMode = Enum.ResamplerMode.Pixelated
	bgFull.ImageTransparency = 0.7
	pcall(function()
		local entry
		for _, e in ipairs(MapCatalog) do
			if e.id == "World" then
				entry = e
				break
			end
		end
		local t = entry and entry.thumb
		if not t then
			return
		end
		local z = EncodingService:Base64Decode(buffer.fromstring(t.data))
		local rgb = EncodingService:DecompressBuffer(z, Enum.CompressionAlgorithm.Zstd)
		local px = buffer.create(t.w * t.h * 4)
		for i = 0, t.w * t.h - 1 do
			local r, g, b = buffer.readu8(rgb, i * 3), buffer.readu8(rgb, i * 3 + 1), buffer.readu8(rgb, i * 3 + 2)
			if r > b then
				local k = 0.55 + 0.45 * ((r + g + b) / 765)
				buffer.writeu8(px, i * 4, math.floor(120 * k))
				buffer.writeu8(px, i * 4 + 1, math.floor(126 * k))
				buffer.writeu8(px, i * 4 + 2, math.floor(235 * k))
				buffer.writeu8(px, i * 4 + 3, 255)
			end
		end
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(t.w, t.h) })
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(t.w, t.h), px)
		bgFull.ImageContent = Content.fromObject(img)
	end)
	bgFull.ZIndex = 0
	bgFull.Parent = gui
	local dim = Instance.new("Frame")
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.ZIndex = 0
	dim.Parent = gui
	-- CRT scanlines over the dark digital-war background
	local scan = Instance.new("ImageLabel")
	scan.Name = "Scanlines"
	scan.Size = UDim2.fromScale(1, 1)
	scan.BackgroundTransparency = 1
	scan.Image = "rbxassetid://91232121836387"
	scan.ScaleType = Enum.ScaleType.Tile
	scan.TileSize = UDim2.fromOffset(8, 8)
	scan.ImageTransparency = 0.82
	scan.ZIndex = 3
	scan.Parent = gui

	-- hide Roblox's own topbar/chat: this is our game shell
	local function hideCore()
		pcall(function()
			local sg = game:GetService("StarterGui")
			for _, t in ipairs({ Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Backpack, Enum.CoreGuiType.Chat, Enum.CoreGuiType.Health, Enum.CoreGuiType.EmotesMenu, Enum.CoreGuiType.All }) do
				pcall(sg.SetCoreGuiEnabled, sg, t, false)
			end
			pcall(function()
				sg:SetCore("TopbarEnabled", false)
			end)
			pcall(function()
				local tc = game:GetService("TextChatService")
				if tc.ChatWindowConfiguration then
					tc.ChatWindowConfiguration.Enabled = false
				end
			end)
		end)
	end
	hideCore()
	task.delay(1.5, hideCore)
	task.delay(4, hideCore)

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromOffset(1280, 720)
	root.AnchorPoint = Vector2.new(0, 0)
	root.Position = UDim2.fromOffset(0, 0)
	root.BackgroundTransparency = 1
	root.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = root
	self.root, self.scale = root, scale

	local function fit()
		local vp = workspace.CurrentCamera.ViewportSize
		if vp.X < 8 or vp.Y < 8 then
			vp = gui.AbsoluteSize
		end
		scale.Scale = math.clamp(vp.Y / 720, 0.5, 1.6)
		self.rootW = vp.X / scale.Scale
		root.Size = UDim2.fromOffset(self.rootW, 720)
		if self.layoutMenu then
			self:layoutMenu()
		end
	end
	fit()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)

	-- background
	local bg = Instance.new("ImageLabel")
	bg.Name = "Background"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundTransparency = 1
	bg.Image = A.bg
	bg.ScaleType = Enum.ScaleType.Crop
	bg.ImageTransparency = 1
	bg.ZIndex = 1
	bg.Parent = root
	local shade = Instance.new("Frame")
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 1
	shade.BorderSizePixel = 0
	shade.ZIndex = 2
	shade.Parent = root

	-- Pixel dust (Omarchy-style): scattered square "pixels" drifting out of the right edge.
	local dust = Instance.new("Frame")
	dust.Name = "PixelDust"
	dust.Size = UDim2.fromScale(1, 1)
	dust.BackgroundTransparency = 1
	dust.ZIndex = 2
	dust.Parent = root
	local rng = Random.new(7)
	for i = 1, 90 do
		local s = rng:NextInteger(1, 3) * 6
		local px = Instance.new("Frame")
		px.Size = UDim2.fromOffset(s, s)
		-- denser towards the right and bottom, empty behind the menu text
		local fx = 1 - rng:NextNumber() ^ 2.2
		px.Position = UDim2.new(fx, 0, rng:NextNumber() ^ 0.8, 0)
		px.BackgroundColor3 = if rng:NextNumber() < 0.15 then Color3.fromRGB(242, 201, 160) else P.gold
		px.BackgroundTransparency = 0.78 + 0.18 * rng:NextNumber()
		px.BorderSizePixel = 0
		px.ZIndex = 2
		px.Parent = dust
	end

	-- header
	local emblem = Icons.label(root, "crown", 52, { color = P.gold })
	emblem.Position = UDim2.fromOffset(56, 58)
	emblem.ZIndex = 5
	local title = text(root, "Title", "WW3: HIGH COMMAND", 52, P.gold, F.title)
	title.Position = UDim2.fromOffset(112, 46)
	title.Size = UDim2.fromOffset(700, 62)
	title.ZIndex = 5
	local tStroke = Instance.new("UIStroke")
	tStroke.Color = Color3.fromRGB(20, 22, 60)
	tStroke.Thickness = 2
	tStroke.Parent = title
	local sub = text(root, "Subtitle", L(
		"WAR ROOM  ·  МИРОВОЕ ГОСПОДСТВО  ·  КОМАНДНЫЙ ПУНКТ",
		"WAR ROOM  ·  WORLD DOMINATION  ·  COMMAND POST"
	), 14, Color3.fromRGB(242, 201, 160), F.small)
	sub.Position = UDim2.fromOffset(114, 104)
	sub.Size = UDim2.fromOffset(800, 20)
	sub.ZIndex = 5

	-- left menu buttons
	local menu = Instance.new("Frame")
	menu.Name = "Menu"
	menu.Position = UDim2.fromOffset(56, 186)
	menu.Size = UDim2.fromOffset(400, 480)
	menu.BackgroundTransparency = 1
	menu.ZIndex = 5
	menu.Parent = root
	local ml = Instance.new("UIListLayout")
	ml.Padding = UDim.new(0, 12)
	ml.SortOrder = Enum.SortOrder.LayoutOrder
	ml.Parent = menu

	local buttons = {}
	local buttonOrder = {}
	local function addMenu(id, icon, caption, order)
		local btn, label, icn, holder = makeButton(menu, icon, caption, order, 62)
		btn.ZIndex = 6
		local screenMap = { SOLO = "SETUP" }
		btn.Activated:Connect(function()
			if id == "SHOP" then
				-- Shop lives above the menu (ZIndex 120 inside this gui).
				require(script.Parent.ShopScreen).open(self.gui, self.net)
				return
			end
			self:show(screenMap[id] or id)
		end)
		buttons[id] = { btn = btn, label = label, icon = icn, holder = holder }
		buttonOrder[#buttonOrder + 1] = buttons[id]
	end
	addMenu("SOLO", "solo", L("СОЛО-КАМПАНИЯ", "SOLO CAMPAIGN"), 1)
	addMenu("ONLINE", "online", L("ОНЛАЙН-ВОЙНА", "ONLINE WAR"), 2)
	addMenu("DUEL", "duel", L("ДУЭЛЬ 1×1", "1 vs 1 DUEL"), 3)
	addMenu("SHOP", "shop", L("МАГАЗИН", "SHOP"), 4)
	addMenu("SETTINGS", "settings", L("НАСТРОЙКИ", "SETTINGS"), 5)
	addMenu("CREDITS", "info", L("О ПРОЕКТЕ", "CREDITS"), 6)

	-- "DEAL" tag on the shop button when a daily offer is live (read-only query).
	local dealTag = text(buttons.SHOP.holder, "DealTag", L("СДЕЛКА ДНЯ", "DAILY DEAL"), 11, P.dark, F.small)
	dealTag.AnchorPoint = Vector2.new(1, 0.5)
	dealTag.Position = UDim2.new(1, -12, 0.5, 0)
	dealTag.Size = UDim2.fromOffset(0, 20)
	dealTag.AutomaticSize = Enum.AutomaticSize.X
	dealTag.BackgroundTransparency = 0
	dealTag.BackgroundColor3 = P.gold
	dealTag.TextXAlignment = Enum.TextXAlignment.Center
	dealTag.Visible = false
	dealTag.ZIndex = 7
	corner(dealTag, 3)
	local dealPad = Instance.new("UIPadding")
	dealPad.PaddingLeft = UDim.new(0, 8)
	dealPad.PaddingRight = UDim.new(0, 8)
	dealPad.Parent = dealTag
	task.spawn(function()
		local ok, st = pcall(function()
			return net.Query:InvokeServer({ kind = "shop" })
		end)
		if ok and type(st) == "table" and st.daily and dealTag.Parent and require(Shared:WaitForChild("Data"):WaitForChild("Shop")).DAILY_DEAL.productId ~= 0 then
			dealTag.Visible = true
		end
	end)

	-- Player card (Roblox convention: avatar + name always visible in the shell).
	local card = Instance.new("Frame")
	card.Name = "PlayerCard"
	card.AnchorPoint = Vector2.new(1, 0)
	card.Position = UDim2.new(1, -28, 0, 28)
	card.Size = UDim2.fromOffset(250, 52)
	card.BackgroundColor3 = P.panel
	card.BackgroundTransparency = 0.1
	card.BorderSizePixel = 0
	card.ZIndex = 6
	card.Parent = root
	corner(card, 3)
	stroke(card, P.goldDim, 1, 0.15)
	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.Position = UDim2.fromOffset(6, 6)
	avatar.Size = UDim2.fromOffset(40, 40)
	avatar.BackgroundColor3 = Color3.fromRGB(16, 18, 44)
	avatar.BorderSizePixel = 0
	avatar.ZIndex = 7
	avatar.Parent = card
	corner(avatar, 2)
	task.spawn(function()
		local ok, img = pcall(function()
			return Players:GetUserThumbnailAsync(LOCAL_ID, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and avatar.Parent then
			avatar.Image = img
		end
	end)
	local who = text(card, "Name", Players.LocalPlayer.DisplayName, 17, P.parchment, F.title)
	who.Position = UDim2.fromOffset(54, 6)
	who.Size = UDim2.new(1, -62, 0, 22)
	who.TextTruncate = Enum.TextTruncate.AtEnd
	who.ZIndex = 7
	local rank = text(card, "Rank", L("КОМАНДУЮЩИЙ", "COMMANDER"), 12, P.gold, F.small)
	rank.Position = UDim2.fromOffset(54, 28)
	rank.Size = UDim2.new(1, -62, 0, 16)
	rank.ZIndex = 7

	-- Daily login reward (cosmetic trial, streak), under the player card.
	local ShopData = require(Shared:WaitForChild("Data"):WaitForChild("Shop"))
	local dailyBtn = Instance.new("TextButton")
	dailyBtn.Name = "DailyReward"
	dailyBtn.AnchorPoint = Vector2.new(1, 0)
	dailyBtn.Position = UDim2.new(1, -28, 0, 86)
	dailyBtn.Size = UDim2.fromOffset(250, 38)
	dailyBtn.BackgroundColor3 = P.panel
	dailyBtn.BackgroundTransparency = 0.1
	dailyBtn.BorderSizePixel = 0
	dailyBtn.AutoButtonColor = false
	dailyBtn.FontFace = F.small
	dailyBtn.TextSize = 12
	dailyBtn.TextColor3 = P.parchment
	dailyBtn.TextWrapped = true
	dailyBtn.Text = ""
	dailyBtn.Visible = false
	dailyBtn.ZIndex = 6
	dailyBtn.Parent = root
	corner(dailyBtn, 3)
	local dailyStroke = stroke(dailyBtn, P.goldDim, 1, 0.15)
	local dailyState = nil
	local function paintDaily(note)
		if note then
			dailyBtn.Text = note
			dailyBtn.Visible = true
			return
		end
		if not dailyState then
			dailyBtn.Visible = false
			return
		end
		dailyBtn.Visible = true
		if dailyState.canClaim then
			dailyBtn.Text = L("ЕЖЕДНЕВНАЯ НАГРАДА · ДЕНЬ ", "DAILY REWARD · DAY ") .. tostring(dailyState.nextStreak) .. L("\nНАЖМИ, ЧТОБЫ ЗАБРАТЬ", "\nTAP TO CLAIM")
			dailyBtn.BackgroundColor3 = P.gold
			dailyBtn.BackgroundTransparency = 0
			dailyBtn.TextColor3 = P.dark
			dailyStroke.Color = Color3.fromRGB(236, 232, 255)
		else
			local s = dailyState.secondsLeft or 0
			dailyBtn.Text = L("СЕРИЯ: ", "STREAK: ") .. tostring(dailyState.streak or 0) .. L(" · СЛЕДУЮЩАЯ ЧЕРЕЗ ", " · NEXT IN ") .. string.format("%dh %dm", s // 3600, (s % 3600) // 60)
			dailyBtn.BackgroundColor3 = P.panel
			dailyBtn.BackgroundTransparency = 0.1
			dailyBtn.TextColor3 = P.dim
			dailyStroke.Color = P.goldDim
		end
	end
	local function refreshDaily()
		local ok, st = pcall(function()
			return net.Query:InvokeServer({ kind = "daily" })
		end)
		dailyState = if ok and type(st) == "table" then st else nil
		paintDaily()
	end
	task.spawn(refreshDaily)
	dailyBtn.Activated:Connect(function()
		if dailyState and dailyState.canClaim then
			net.Intent:FireServer({ type = "claim_daily" })
		end
	end)
	net.Event.OnClientEvent:Connect(function(evt)
		if type(evt) ~= "table" or evt.type ~= "DailyClaimed" then
			return
		end
		if evt.ok then
			local item = evt.item and ShopData.byId[evt.item]
			local name = if item then item.name else L("награда", "reward")
			paintDaily(L("ПОЛУЧЕНО: ", "CLAIMED: ") .. tostring(name) .. " · " .. tostring(evt.hours or 24) .. L(" Ч\nСЕРИЯ: ", " H\nSTREAK: ") .. tostring(evt.streak or 1))
			task.delay(6, refreshDaily)
		else
			refreshDaily()
		end
	end)

	local version = text(root, "Version", L(
		"СБОРКА 0.3 · РАБОЧАЯ ВЕРСИЯ",
		"BUILD 0.3 · WORK IN PROGRESS"
	), 12, P.dim, F.small)
	version.Position = UDim2.new(0, 56, 1, -22)
	version.Size = UDim2.fromOffset(900, 18)
	version.Text = "© OpenFront and Contributors · AGPL-3.0  ·  " .. version.Text
	version.ZIndex = 5

	-- content area
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(480, 166)
	content.Size = UDim2.fromOffset(680, 530)
	content.BackgroundTransparency = 1
	content.ZIndex = 5
	content.Parent = root
	self.content = content

	local screens = {}
	local function newScreen(name)
		local f = Instance.new("Frame")
		f.Name = name
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundTransparency = 1
		f.Visible = false
		f.ZIndex = 6
		f.Parent = content
		screens[name] = f
		return f
	end

	-- ================= MAIN =================
	local main = newScreen("MAIN")
	local mainPanel = panel(main)
	mainPanel.Position = UDim2.fromOffset(0, 0)
	mainPanel.Size = UDim2.fromOffset(660, 300)
	local mainTitle = text(mainPanel, "Title", L("КОМАНДУЙ МИРОМ", "COMMAND THE WORLD"), 30, P.parchment, F.title)
	mainTitle.Position = UDim2.fromOffset(28, 22)
	mainTitle.Size = UDim2.fromOffset(600, 34)
	local mainBody = text(mainPanel, "Body", L(
		"Выбери войну. Захвати 80% мира — и корона твоя.",
		"Choose a war. Conquer 80% of the world. The crown is yours."
	), 18, P.parchment, F.body)
	mainBody.Position = UDim2.fromOffset(30, 64)
	mainBody.Size = UDim2.fromOffset(590, 50)
	mainBody.TextWrapped = true
	local tips = text(mainPanel, "Tips", L(
		"· СОЛО-КАМПАНИЯ — карта, режим и война против ботов\n" ..
		"· ОНЛАЙН-ВОЙНА — общий мир, случайные игроки и нации\n" ..
		"· ДУЭЛЬ 1×1 — приватная арена для тебя и друга\n" ..
		"· КОРОНА МИРА — захвати больше всех земли и стань правителем",
		"· SOLO CAMPAIGN — pick a map, a mode and fight the bots\n" ..
		"· ONLINE WAR — shared world, random players and nations\n" ..
		"· 1 vs 1 DUEL — private arena for you and a friend\n" ..
		"· WORLD CROWN — own the most land and rule the world"
	), 16, Color3.fromRGB(176, 180, 230), F.body)
	tips.Position = UDim2.fromOffset(30, 118)
	tips.Size = UDim2.fromOffset(600, 110)
	tips.TextWrapped = true
	tips.TextYAlignment = Enum.TextYAlignment.Top
	-- Server status (public lobby countdown / private match code), filled from Net.Lobby.
	local mainStatus = text(mainPanel, "Status", "", 15, P.gold, F.small)
	mainStatus.Position = UDim2.fromOffset(30, 236)
	mainStatus.Size = UDim2.fromOffset(600, 48)
	mainStatus.TextWrapped = true
	mainStatus.TextYAlignment = Enum.TextYAlignment.Top
	self.mainStatus = mainStatus

	-- ================= SETUP (solo / private) =================
	local setup = newScreen("SETUP")
	local setupPanel = panel(setup)
	setupPanel.Size = UDim2.fromScale(1, 1)
	local setupTitle = text(setupPanel, "Title", L("СОЛО-КАМПАНИЯ", "SOLO CAMPAIGN"), 28, P.parchment, F.title)
	setupTitle.Position = UDim2.fromOffset(24, 16)
	setupTitle.Size = UDim2.fromOffset(500, 30)
	local back = text(setupPanel, "Back", L("‹  НАЗАД", "‹  BACK"), 16, P.gold, F.small)
	back.Position = UDim2.fromOffset(24, 46)
	back.Size = UDim2.fromOffset(120, 18)
	back.ZIndex = 8
	local backBtn = Instance.new("TextButton")
	backBtn.BackgroundTransparency = 1
	backBtn.Text = ""
	backBtn.Size = UDim2.fromOffset(120, 24)
	backBtn.Position = UDim2.fromOffset(20, 40)
	backBtn.Parent = setupPanel
	backBtn.Activated:Connect(function()
		self:show("MAIN")
	end)

	-- map grid
	local grid = Instance.new("ScrollingFrame")
	grid.Name = "Maps"
	grid.Position = UDim2.fromOffset(24, 78)
	grid.Size = UDim2.fromOffset(400, 330)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 4
	grid.ScrollBarImageColor3 = P.goldDim
	grid.CanvasSize = UDim2.new(0, 0, 0, 0)
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.ZIndex = 7
	grid.Parent = setupPanel
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.fromOffset(122, 92)
	self.gridLayout = gl
	gl.CellPadding = UDim2.fromOffset(8, 8)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = grid
	local gridPad = Instance.new("UIPadding")
	gridPad.PaddingLeft = UDim.new(0, 4)
	gridPad.PaddingTop = UDim.new(0, 4)
	gridPad.PaddingRight = UDim.new(0, 4)
	gridPad.Parent = grid

	local thumbCache = {}
	local function thumb(entry)
		if thumbCache[entry.id] ~= nil then
			return thumbCache[entry.id]
		end
		local t = entry.thumb
		if not t then
			thumbCache[entry.id] = false
			return false
		end
		local z = EncodingService:Base64Decode(buffer.fromstring(t.data))
		local rgb = EncodingService:DecompressBuffer(z, Enum.CompressionAlgorithm.Zstd)
		local px = buffer.create(t.w * t.h * 4)
		for i = 0, t.w * t.h - 1 do
			buffer.writeu8(px, i * 4, buffer.readu8(rgb, i * 3))
			buffer.writeu8(px, i * 4 + 1, buffer.readu8(rgb, i * 3 + 1))
			buffer.writeu8(px, i * 4 + 2, buffer.readu8(rgb, i * 3 + 2))
			buffer.writeu8(px, i * 4 + 3, 255)
		end
		-- Never let a thumbnail kill the menu (EditableImage disabled / out of budget).
		local ok, img = pcall(function()
			local e = AssetService:CreateEditableImage({ Size = Vector2.new(t.w, t.h) })
			if e then
				e:WritePixelsBuffer(Vector2.zero, Vector2.new(t.w, t.h), px)
			end
			return e
		end)
		if not ok or img == nil then
			thumbCache[entry.id] = false
			return false
		end
		thumbCache[entry.id] = img
		return img
	end

	self.selectedMap = "World"
	local mapCards = {}
	local sorted = table.clone(MapCatalog)
	table.sort(sorted, function(a, b)
		return (a.name or a.id) < (b.name or b.id)
	end)
	for i, entry in ipairs(sorted) do
		local card = Instance.new("Frame")
		card.Name = entry.id
		card.BackgroundColor3 = Color3.fromRGB(16, 18, 44)
		card.BackgroundTransparency = 0.1
		card.BorderSizePixel = 0
		card.LayoutOrder = i
		card.ZIndex = 7
		card.Parent = grid
		corner(card, 2)
		local cs = stroke(card, P.goldDim, 1, 0.4)
		local img = Instance.new("ImageLabel")
		img.BackgroundColor3 = Color3.fromRGB(9, 14, 19)
		img.BackgroundTransparency = 0.1
		img.Size = UDim2.new(1, -12, 0, 49)
		img.Position = UDim2.fromOffset(6, 5)
		img.ScaleType = Enum.ScaleType.Fit
		img.ZIndex = 8
		corner(img, 2)
		stroke(img, Color3.fromRGB(62, 86, 104), 1, 0.35)
		local thumbImage = thumb(entry)
		if thumbImage then
			img.ImageContent = Content.fromObject(thumbImage)
		else
			img.Image = A.map
			img.ImageColor3 = P.dim
		end
		img.Parent = card
		local nm = text(card, "Name", entry.name or entry.id, 12, P.parchment, F.body)
		nm.Position = UDim2.fromOffset(6, 57)
		nm.Size = UDim2.new(1, -12, 0, 24)
		nm.TextXAlignment = Enum.TextXAlignment.Center
		nm.TextWrapped = true
		nm.ZIndex = 8
		local btn = Instance.new("TextButton")
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.Size = UDim2.fromScale(1, 1)
		btn.ZIndex = 9
		btn.Parent = card
		btn.Activated:Connect(function()
			self.selectedMap = entry.id
			for id, s in pairs(mapCards) do
				s.Color = (id == entry.id) and P.gold or P.goldDim
				s.Thickness = (id == entry.id) and 2 or 1
			end
			self:_paintSetup()
		end)
		mapCards[entry.id] = cs
	end
	for id, s in pairs(mapCards) do
		s.Color = (id == self.selectedMap) and P.gold or P.goldDim
	end

	-- right options column
	local opts = Instance.new("Frame")
	opts.Position = UDim2.fromOffset(444, 78)
	opts.Size = UDim2.fromOffset(212, 330)
	opts.BackgroundTransparency = 1
	opts.ZIndex = 7
	opts.Parent = setupPanel
	local ol = Instance.new("UIListLayout")
	ol.Padding = UDim.new(0, 6)
	ol.Parent = opts

	local optionLabels = {}
	local function optionRow(key, label, values, default, order, fmt)
		local holder = Instance.new("Frame")
		holder.Size = UDim2.new(1, 0, 0, 56)
		holder.BackgroundTransparency = 1
		holder.LayoutOrder = order
		holder.Parent = opts
		local cap = text(holder, "Label", label, 13, P.dim, F.small)
		cap.Position = UDim2.fromOffset(2, 0)
		cap.Size = UDim2.fromOffset(200, 16)
		local row = Instance.new("Frame")
		row.Position = UDim2.fromOffset(0, 18)
		row.Size = UDim2.fromOffset(212, 32)
		row.BackgroundTransparency = 1
		row.Parent = holder
		local chips = {}
		local current = default
		local function labelOf(v)
			return fmt and fmt(v) or tostring(v)
		end
		local function repaint()
			for i, chip in ipairs(chips) do
				local on = values[i] == current
				chip.bg.BackgroundColor3 = on and P.gold or Color3.fromRGB(38, 44, 54)
				chip.label.TextColor3 = on and P.dark or P.dim
				chip.label.Text = labelOf(values[i])
			end
			self.options[key] = current
		end
		local width = math.floor(212 / math.min(#values, 6))
		for i, value in ipairs(values) do
			local chip = Instance.new("TextButton")
			chip.Size = UDim2.fromOffset(width - 4, 30)
			chip.Position = UDim2.fromOffset((i - 1) * width, 0)
			chip.BackgroundColor3 = Color3.fromRGB(24, 26, 64)
			chip.BorderSizePixel = 0
			chip.Text = ""
			chip.AutoButtonColor = false
			chip.Parent = row
			corner(chip, 2)
			local cLabel = text(chip, "Text", tostring(value), 12, P.dim, F.body)
				cLabel.TextScaled = true
				local cMax = Instance.new("UITextSizeConstraint")
				cMax.MaxTextSize = 12
				cMax.Parent = cLabel
			cLabel.Size = UDim2.fromScale(1, 1)
			cLabel.TextXAlignment = Enum.TextXAlignment.Center
			chips[i] = { bg = chip, label = cLabel }
			chip.Activated:Connect(function()
				current = value
				self.options[key] = value
				repaint()
			end)
		end
		self.options[key] = default
		repaint()
		return holder
	end

	self.options = {}
	optionRow("mode", L("РЕЖИМ", "GAME MODE"), { "ffa", "Duos", "Trios", "Quads" }, "ffa", 1, function(v)
		return v == "ffa" and "FFA" or v
	end)
	optionRow("difficulty", L("СЛОЖНОСТЬ", "DIFFICULTY"), { "Easy", "Medium", "Hard", "Impossible" }, "Medium", 2, function(v)
		return if v == "Impossible" then L("МАКС", "MAX") else v
	end)
	optionRow("startingGold", L("СТАРТОВОЕ ЗОЛОТО", "STARTING GOLD"), { 0, 1000000, 5000000, 25000000 }, 0, 3, function(v)
		return v == 0 and "None" or (v == 1000000 and "1M" or (v == 5000000 and "5M" or "25M"))
	end)
	optionRow("goldMultiplier", L("ДОХОД ЗОЛОТА", "GOLD RATE"), { 1, 2, 5 }, 1, 4, function(v)
		return "×" .. tostring(v)
	end)
	optionRow("bots", L("БОТЫ", "BOTS"), { 0, 100, 250 }, 250, 5)

	local startBtn = Instance.new("TextButton")
	startBtn.Name = "Start"
	startBtn.Size = UDim2.fromOffset(212, 44)
	startBtn.Position = UDim2.fromOffset(444, 420)
	startBtn.BackgroundColor3 = Color3.fromRGB(46, 50, 120)
	startBtn.BackgroundTransparency = 0
	startBtn.BorderSizePixel = 0
	startBtn.FontFace = F.title
	startBtn.TextSize = 20
	startBtn.TextColor3 = P.parchment
	startBtn.Text = L("НАЧАТЬ КАМПАНИЮ", "START CAMPAIGN")
	startBtn.ZIndex = 9
	startBtn.Parent = setupPanel
	corner(startBtn, 2)
	stroke(startBtn, P.gold, 2, 0)
	startBtn.Activated:Connect(function() self:_startMatch(false) end)
	self.startBtn = startBtn

	local nameLabel = text(setupPanel, "MapName", "", 15, P.gold, F.small)
	nameLabel.Position = UDim2.fromOffset(24, 414)
	nameLabel.Size = UDim2.fromOffset(400, 20)
	nameLabel.ZIndex = 8
	self.setupMapLabel = nameLabel

	local notice = text(setupPanel, "Notice", "", 15, Color3.fromRGB(226, 150, 120), F.body)
	notice.Position = UDim2.fromOffset(24, 436)
	notice.Size = UDim2.fromOffset(400, 18)
	notice.TextWrapped = true
	notice.ZIndex = 8
	notice.TextWrapped = false
	self.noticeLabel = notice

	function self:_paintSetup()
		local name = self.selectedMap
		for _, entry in ipairs(MapCatalog) do
			if entry.id == self.selectedMap then
				name = entry.name or entry.id
				break
			end
		end
		self.setupMapLabel.Text = L("КАРТА: ", "MAP: ") .. string.upper(name)
	end
	self:_paintSetup()

	-- ================= ONLINE / DUEL =================
	local function buildMatchScreen(name, titleText, isDuel)
		local s = newScreen(name)
		local p = panel(s)
		p.Size = UDim2.fromScale(1, 1)
		local t = text(p, "Title", titleText, 28, P.parchment, F.title)
		t.Position = UDim2.fromOffset(24, 16)
		t.Size = UDim2.fromOffset(560, 30)
		local b = text(p, "Back", L("‹  НАЗАД", "‹  BACK"), 16, P.gold, F.small)
		b.Position = UDim2.fromOffset(24, 46)
		b.Size = UDim2.fromOffset(120, 18)
		local bb = Instance.new("TextButton")
		bb.BackgroundTransparency = 1
		bb.Text = ""
		bb.Size = UDim2.fromOffset(120, 24)
		bb.Position = UDim2.fromOffset(20, 40)
		bb.Parent = p
		bb.Activated:Connect(function()
			self:show("MAIN")
		end)
		local btns = Instance.new("Frame")
		btns.Position = UDim2.fromOffset(24, 86)
		btns.Size = UDim2.fromOffset(600, 240)
		btns.BackgroundTransparency = 1
		btns.Parent = p
		local bl = Instance.new("UIListLayout")
		bl.Padding = UDim.new(0, 10)
		bl.Parent = btns
		-- Join code of the private match / arena we are on: big, framed and selectable,
		-- so the host sees at once that the new server is theirs and what to send.
		local card = Instance.new("Frame")
		card.Name = "CodeCard"
		-- Last item of the button list, so it sits right under the buttons.
		card.LayoutOrder = 100
		card.Size = UDim2.new(1, 0, 0, 118)
		card.BackgroundColor3 = Color3.fromRGB(20, 22, 60)
		card.BorderSizePixel = 0
		card.Visible = false
		card.Parent = btns
		corner(card, 2)
		stroke(card, P.gold, 2, 0)
		local cap = text(card, "Caption", if isDuel
			then L("ТЫ НА СВОЕЙ АРЕНЕ · КОД ДЛЯ СОПЕРНИКА", "YOU ARE IN YOUR ARENA · CODE FOR YOUR RIVAL")
			else L("ТЫ НА СВОЁМ СЕРВЕРЕ · КОД ДЛЯ ДРУЗЕЙ", "YOU ARE ON YOUR SERVER · CODE FOR FRIENDS"), 16, P.gold, F.small)
		cap.Position = UDim2.fromOffset(16, 10)
		cap.Size = UDim2.new(1, -32, 0, 18)
		local codeBox = Instance.new("TextBox")
		codeBox.Name = "Code"
		codeBox.Position = UDim2.fromOffset(16, 36)
		codeBox.Size = UDim2.fromOffset(260, 66)
		codeBox.BackgroundColor3 = P.dark
		codeBox.BorderSizePixel = 0
		codeBox.FontFace = F.title
		codeBox.TextSize = 48
		codeBox.TextColor3 = P.parchment
		codeBox.TextEditable = false
		codeBox.ClearTextOnFocus = false
		codeBox.Text = ""
		codeBox.Parent = card
		corner(codeBox, 2)
		stroke(codeBox, P.gold, 1, 0.2)
		codeBox.Focused:Connect(function()
			-- select the whole code so Ctrl+C copies it
			codeBox.SelectionStart = 1
			codeBox.CursorPosition = #codeBox.Text + 1
		end)
		local hint = text(card, "Hint", L(
			"Друг: " .. (if isDuel then "1 vs 1 DUEL" else "ONLINE WAR") .. " → поле JOIN CODE → JOIN WAR.\nНажми на код, чтобы выделить (Ctrl+C).",
			"Friend: " .. (if isDuel then "1 vs 1 DUEL" else "ONLINE WAR") .. " → JOIN CODE box → JOIN WAR.\nClick the code to select it (Ctrl+C)."), 14, P.text, F.body)
		hint.Position = UDim2.fromOffset(296, 38)
		hint.Size = UDim2.new(1, -312, 0, 64)
		hint.TextWrapped = true
		hint.TextYAlignment = Enum.TextYAlignment.Top
		local status = text(p, "Status", "", 16, P.gold, F.body)
		status.Position = UDim2.fromOffset(24, 466)
		status.Size = UDim2.new(1, -48, 0, 60)
		status.TextWrapped = true
		status.TextYAlignment = Enum.TextYAlignment.Top
		return s, btns, status, card
	end

	local online, onlineBtns, onlineStatus, onlineCard = buildMatchScreen("ONLINE", L("ОНЛАЙН-ВОЙНА", "ONLINE WAR"))
	self.onlineStatus = onlineStatus
	self.onlineCodeCard = onlineCard
	local quick = Instance.new("Frame")
	quick.Size = UDim2.new(1, 0, 0, 58)
	quick.BackgroundTransparency = 1
	quick.Parent = onlineBtns
	local quickBtn = makeButton(quick, "online", L("БЫСТРАЯ ИГРА", "QUICK MATCH"), 1, 54)
	quickBtn.Size = UDim2.fromScale(1, 1)
	quickBtn.Activated:Connect(function()
		self:_matchmake("find_match", L("Ищу публичный сервер…", "Finding a public server…"))
	end)
	local create = Instance.new("Frame")
	create.Size = UDim2.new(1, 0, 0, 58)
	create.BackgroundTransparency = 1
	create.Parent = onlineBtns
	local createBtn = makeButton(create, "flag", L("СОЗДАТЬ ПРИВАТНЫЙ СЕРВЕР", "CREATE PRIVATE SERVER"), 2, 54)
	createBtn.Size = UDim2.fromScale(1, 1)
	createBtn.Activated:Connect(function()
		self:_matchmake("create_private", L("Создаю приватный сервер…", "Creating a private server…"))
	end)
	self.onlineCreateRow = create
	local joinRow = Instance.new("Frame")
	joinRow.Size = UDim2.new(1, 0, 0, 46)
	joinRow.BackgroundTransparency = 1
	joinRow.Parent = onlineBtns
	local box = Instance.new("TextBox")
	box.Size = UDim2.fromOffset(300, 40)
	box.BackgroundColor3 = Color3.fromRGB(14, 16, 40)
	box.BorderSizePixel = 0
	box.FontFace = F.body
	box.TextSize = 16
	box.TextColor3 = P.parchment
	box.PlaceholderText = L("КОД ДЛЯ ВХОДА", "JOIN CODE")
	box.PlaceholderColor3 = P.dim
	box.Text = ""
	box.ClearTextOnFocus = false
	box.Parent = joinRow
	corner(box, 2)
	stroke(box, P.goldDim, 1, 0.3)
	local joinBtn = Instance.new("TextButton")
	joinBtn.Size = UDim2.fromOffset(160, 40)
	joinBtn.Position = UDim2.fromOffset(312, 0)
	joinBtn.BackgroundColor3 = Color3.fromRGB(46, 50, 120)
	joinBtn.BorderSizePixel = 0
	joinBtn.FontFace = F.title
	joinBtn.TextSize = 18
	joinBtn.TextColor3 = P.parchment
	joinBtn.Text = L("ВОЙТИ В ВОЙНУ", "JOIN WAR")
	joinBtn.Parent = joinRow
	corner(joinBtn, 2)
	stroke(joinBtn, P.gold, 1, 0)
	joinBtn.Activated:Connect(function()
		local code = string.upper((string.gsub(box.Text, "%s", "")))
		if #code > 0 then
			self:_matchmake("join_code", L("Вхожу по коду " .. code .. "…", "Joining with code " .. code .. "…"), { code = code })
		end
	end)

	-- Host of a private match starts it from here (settings = defaults or SOLO screen picks).
	local onlineStart = Instance.new("TextButton")
	onlineStart.Name = "StartPrivate"
	onlineStart.Size = UDim2.fromOffset(280, 44)
	onlineStart.BackgroundColor3 = Color3.fromRGB(46, 50, 120)
	onlineStart.BorderSizePixel = 0
	onlineStart.FontFace = F.title
	onlineStart.TextSize = 19
	onlineStart.TextColor3 = P.parchment
	onlineStart.Text = L("НАЧАТЬ МАТЧ", "START MATCH")
	onlineStart.Visible = false
	onlineStart.Parent = onlineBtns
	corner(onlineStart, 2)
	stroke(onlineStart, P.gold, 2, 0)
	onlineStart.Activated:Connect(function()
		self:_startMatch(true, onlineStatus)
	end)
	self.onlineStartBtn = onlineStart

	local duel, duelBtns, duelStatus, duelCard = buildMatchScreen("DUEL", L("ДУЭЛЬ 1×1", "1 vs 1 DUEL"), true)
	self.duelStatus = duelStatus
	self.duelCodeCard = duelCard
	local dCreate = Instance.new("Frame")
	dCreate.Size = UDim2.new(1, 0, 0, 58)
	dCreate.BackgroundTransparency = 1
	dCreate.Parent = duelBtns
	local dCreateBtn = makeButton(dCreate, "duel", L("СОЗДАТЬ АРЕНУ 1×1", "CREATE 1v1 ARENA"), 1, 54)
	dCreateBtn.Size = UDim2.fromScale(1, 1)
	dCreateBtn.Activated:Connect(function()
		self:_matchmake("create_private", L("Создаю арену 1v1…", "Creating a 1v1 arena…"), { duel = true })
		self.mode = "DUEL"
	end)
	self.duelCreateRow = dCreate
	local dJoinRow = Instance.new("Frame")
	dJoinRow.Size = UDim2.new(1, 0, 0, 46)
	dJoinRow.BackgroundTransparency = 1
	dJoinRow.Parent = duelBtns
	local dBox = box:Clone()
	dBox.Parent = dJoinRow
	local dJoinBtn = joinBtn:Clone()
	dJoinBtn.Parent = dJoinRow
	dJoinBtn.Activated:Connect(function()
		local code = string.upper((string.gsub(dBox.Text, "%s", "")))
		if #code > 0 then
			self:_matchmake("join_code", L("Вхожу по коду " .. code .. "…", "Joining with code " .. code .. "…"), { code = code, duel = true })
		end
	end)
	local duelStart = Instance.new("TextButton")
	duelStart.Size = UDim2.fromOffset(280, 44)
	duelStart.Position = UDim2.fromOffset(0, 120)
	duelStart.BackgroundColor3 = Color3.fromRGB(46, 50, 120)
	duelStart.BorderSizePixel = 0
	duelStart.FontFace = F.title
	duelStart.TextSize = 19
	duelStart.TextColor3 = P.parchment
	duelStart.Text = L("НАЧАТЬ ДУЭЛЬ", "START DUEL")
	duelStart.Parent = duelBtns
	corner(duelStart, 2)
	stroke(duelStart, P.gold, 2, 0)
	duelStart.Activated:Connect(function()
		self:_startMatch(true)
	end)

	-- ================= SETTINGS / CREDITS =================
	local settingsScreen = newScreen("SETTINGS")
	local sp = panel(settingsScreen)
	sp.Size = UDim2.fromScale(1, 1)
	local st = text(sp, "Title", L("НАСТРОЙКИ", "SETTINGS"), 28, P.parchment, F.title)
	st.Position = UDim2.fromOffset(24, 16)
	st.Size = UDim2.fromOffset(500, 30)
	local sb = text(sp, "Back", L("‹  НАЗАД", "‹  BACK"), 16, P.gold, F.small)
	sb.Position = UDim2.fromOffset(24, 46)
	sb.Size = UDim2.fromOffset(120, 18)
	local sbb = Instance.new("TextButton")
	sbb.BackgroundTransparency = 1
	sbb.Text = ""
	sbb.Size = UDim2.fromOffset(120, 24)
	sbb.Position = UDim2.fromOffset(20, 40)
	sbb.Parent = sp
	sbb.Activated:Connect(function()
		self:show("MAIN")
	end)
	local sBody = text(sp, "Body", L(
		"УПРАВЛЕНИЕ\n" ..
		"· ЛКМ по врагу — атака. Первый удар идёт в ту сторону, куда ты кликнул\n" ..
		"· ПКМ по карте — радиальное меню (атака, десант, постройки)\n" ..
		"· Колесо — масштаб · Перетаскивание — сдвиг карты\n" ..
		"· 1–0 — постройки и оружие · Shift+колесо — доля войск\n\n" ..
		"ЗОЛОТО — казна для построек и оружия. ВОЙСКА — армия нации.\n" ..
		"КОРОНА МИРА — владей большей землёй и получай казну короны.",
		"CONTROLS\n" ..
		"· LMB on an enemy — attack. The first strike goes toward the side you clicked\n" ..
		"· RMB on the map — radial menu (attack, boat, build)\n" ..
		"· Wheel — zoom · Drag — pan the map\n" ..
		"· 1–0 — buildings and weapons · Shift+wheel — troop ratio\n\n" ..
		"GOLD — treasury for buildings and weapons. TROOPS — your army.\n" ..
		"WORLD CROWN — own the most land and collect the crown treasury."
	), 16, Color3.fromRGB(176, 180, 230), F.body)
	sBody.Position = UDim2.fromOffset(28, 150)
	sBody.Size = UDim2.new(1, -56, 0, 300)
	-- Working setting: master sound switch (Audio.setMuted), same as the in-game speaker.
	local Audio = require(script.Parent.Audio)
	local soundBtn = Instance.new("TextButton")
	soundBtn.Name = "SoundToggle"
	soundBtn.Position = UDim2.fromOffset(28, 90)
	soundBtn.Size = UDim2.fromOffset(300, 40)
	soundBtn.BackgroundColor3 = Color3.fromRGB(46, 50, 120)
	soundBtn.BorderSizePixel = 0
	soundBtn.FontFace = F.title
	soundBtn.TextSize = 18
	soundBtn.TextColor3 = P.parchment
	soundBtn.ZIndex = 8
	soundBtn.Parent = sp
	corner(soundBtn, 2)
	stroke(soundBtn, P.gold, 1, 0)
	local function paintSound()
		soundBtn.Text = L("ЗВУК: ", "SOUND: ") .. (if Audio.isMuted() then L("ВЫКЛ", "OFF") else L("ВКЛ", "ON"))
	end
	paintSound()
	soundBtn.Activated:Connect(function()
		Audio.setMuted(not Audio.isMuted())
		paintSound()
	end)
	sBody.TextWrapped = true
	sBody.TextYAlignment = Enum.TextYAlignment.Top

	local credits = newScreen("CREDITS")
	local cp = panel(credits)
	cp.Size = UDim2.fromScale(1, 1)
	local ct = text(cp, "Title", L("О ПРОЕКТЕ", "CREDITS"), 28, P.parchment, F.title)
	ct.Position = UDim2.fromOffset(24, 16)
	ct.Size = UDim2.fromOffset(500, 30)
	local cb = text(cp, "Back", L("‹  НАЗАД", "‹  BACK"), 16, P.gold, F.small)
	cb.Position = UDim2.fromOffset(24, 46)
	cb.Size = UDim2.fromOffset(120, 18)
	local cbb = Instance.new("TextButton")
	cbb.BackgroundTransparency = 1
	cbb.Text = ""
	cbb.Size = UDim2.fromOffset(120, 24)
	cbb.Position = UDim2.fromOffset(20, 40)
	cbb.Parent = cp
	cbb.Activated:Connect(function()
		self:show("MAIN")
	end)
	local cBody = text(cp, "Body", L(
		"WW3: HIGH COMMAND — стратегия реального времени о мировом господстве.\n\n" ..
		"Выбери нацию, захватывай регионы, строй города и армии,\n" ..
		"запускай ядерные удары и следи за короной: правитель мира\n" ..
		"получает казну, но становится главной целью для всех.\n\n" ..
		"Играй соло против сотен ботов-наций, в общем онлайне\n" ..
		"или вызови друга на дуэль 1×1.\n\n" ..
		"Победа: контроль 80% мира.",
		"WW3: HIGH COMMAND — a real-time strategy game about world domination.\n\n" ..
		"Pick a nation, capture regions, build cities and armies,\n" ..
		"launch nuclear strikes and watch the crown: the ruler of the world\n" ..
		"gets the treasury, but becomes everyone's main target.\n\n" ..
		"Play solo against hundreds of bot nations, online\n" ..
		"or challenge a friend to a 1v1 duel.\n\n" ..
		"Victory: control 80% of the world."
	), 16, Color3.fromRGB(176, 180, 230), F.body)
	cBody.Position = UDim2.fromOffset(28, 96)
	cBody.Size = UDim2.fromOffset(600, 260)
	local iconCredit = text(cp, "IconsCredit", L("ПО МОТИВАМ OPENFRONT (AGPL-3.0) · ИКОНКИ: GAME-ICONS.NET (CC BY 3.0)", "BASED ON OPENFRONT (AGPL-3.0) · ICONS: GAME-ICONS.NET (CC BY 3.0)") .. (if require(Shared:WaitForChild("GameInfo")).LICENSE ~= "" then "\n" .. require(Shared:WaitForChild("GameInfo")).COPYRIGHT .. " · " .. require(Shared:WaitForChild("GameInfo")).LICENSE .. " · " .. require(Shared:WaitForChild("GameInfo")).SOURCE_URL else ""), 12, P.dim, F.small)
	iconCredit.Position = UDim2.fromOffset(28, 372)
	iconCredit.Size = UDim2.fromOffset(620, 34)
	iconCredit.TextWrapped = true
	iconCredit.TextYAlignment = Enum.TextYAlignment.Top
	cBody.TextWrapped = true
	cBody.TextYAlignment = Enum.TextYAlignment.Top

	-- ================= responsive layout =================
	function self:layoutMenu()
		local rw = self.rootW or 1280
		local compact = rw < 1200
		if compact then
			local btnCount = math.max(1, #buttonOrder)
			local btnW = math.floor((rw - 72 - (btnCount - 1) * 8) / btnCount)
			emblem.Position = UDim2.fromOffset(36, 58)
			title.Position = UDim2.fromOffset(86, 48)
			title.Size = UDim2.fromOffset(rw - 110, 46)
			title.TextSize = 34
			sub.Position = UDim2.fromOffset(88, 98)
			sub.Size = UDim2.fromOffset(rw - 110, 16)
			sub.TextSize = 11
			menu.Position = UDim2.fromOffset(36, 128)
			menu.Size = UDim2.fromOffset(rw - 72, 54)
			ml.FillDirection = Enum.FillDirection.Horizontal
			ml.Padding = UDim.new(0, 8)
			if self.gridLayout then
				self.gridLayout.CellSize = UDim2.fromOffset(106, 84)
			end
			for i, b in ipairs(buttonOrder) do
				b.holder.Size = UDim2.fromOffset(btnW, 54)
				b.icon.Size = UDim2.fromOffset(20, 20)
				b.icon.Position = UDim2.new(0.5, 0, 0, 5)
				b.icon.AnchorPoint = Vector2.new(0.5, 0)
				b.label.Position = UDim2.fromOffset(0, 27)
				b.label.Size = UDim2.new(1, 0, 0, 18)
				b.label.TextSize = 11
				b.label.TextXAlignment = Enum.TextXAlignment.Center
			end
			content.Position = UDim2.fromOffset(36, 196)
			content.Size = UDim2.fromOffset(rw - 72, 500)
			mainPanel.Size = UDim2.fromOffset(rw - 80, 320)
			local cw = rw - 72
			local gridW = math.max(240, cw - 268)
			grid.Position = UDim2.fromOffset(24, 78)
			grid.Size = UDim2.fromOffset(gridW, 340)
			opts.Position = UDim2.fromOffset(24 + gridW + 12, 78)
			opts.Size = UDim2.fromOffset(212, 340)
			startBtn.Position = UDim2.fromOffset(24 + gridW + 12, 430)
			nameLabel.Position = UDim2.fromOffset(24, 430)
			nameLabel.Size = UDim2.fromOffset(gridW, 20)
			notice.Position = UDim2.fromOffset(24, 452)
			notice.Size = UDim2.fromOffset(gridW, 40)
		else
			emblem.Position = UDim2.fromOffset(56, 58)
			title.Position = UDim2.fromOffset(112, 46)
			title.Size = UDim2.fromOffset(700, 62)
			title.TextSize = 52
			sub.Position = UDim2.fromOffset(114, 104)
			sub.Size = UDim2.fromOffset(800, 20)
			sub.TextSize = 15
			menu.Position = UDim2.fromOffset(56, 186)
			menu.Size = UDim2.fromOffset(400, 480)
			ml.FillDirection = Enum.FillDirection.Vertical
			ml.Padding = UDim.new(0, 12)
			for i, b in ipairs(buttonOrder) do
				b.holder.Size = UDim2.new(1, 0, 0, 62)
				b.icon.Size = UDim2.fromOffset(30, 30)
				b.icon.Position = UDim2.fromOffset(18, 14)
				b.icon.AnchorPoint = Vector2.new(0, 0)
				b.label.Position = UDim2.fromOffset(66, 0)
				b.label.Size = UDim2.new(1, -80, 1, 0)
				b.label.TextSize = 23
				b.label.TextXAlignment = Enum.TextXAlignment.Left
			end
			content.Position = UDim2.fromOffset(480, 166)
			content.Size = UDim2.fromOffset(math.max(680, rw - 508), 530)
			mainPanel.Size = UDim2.fromOffset(660, 300)
			grid.Position = UDim2.fromOffset(24, 78)
			grid.Size = UDim2.fromOffset(400, 330)
			opts.Position = UDim2.fromOffset(444, 78)
			opts.Size = UDim2.fromOffset(212, 330)
			startBtn.Position = UDim2.fromOffset(444, 420)
			nameLabel.Position = UDim2.fromOffset(24, 414)
			nameLabel.Size = UDim2.fromOffset(400, 20)
			notice.Position = UDim2.fromOffset(24, 436)
			notice.Size = UDim2.fromOffset(400, 18)
		end
	end
	self:layoutMenu()

	-- BACK TO GAME: only while a match is running behind the menu.
	local backBtn = Instance.new("TextButton")
	backBtn.Name = "BackToGame"
	backBtn.AnchorPoint = Vector2.new(1, 1)
	backBtn.Position = UDim2.new(1, -24, 1, -24)
	backBtn.Size = UDim2.fromOffset(250, 46)
	backBtn.BackgroundColor3 = Color3.fromRGB(8, 9, 28)
	backBtn.BackgroundTransparency = 0.05
	backBtn.BorderSizePixel = 0
	backBtn.FontFace = F.title
	backBtn.TextSize = 19
	backBtn.TextColor3 = Color3.fromRGB(242, 201, 160)
	backBtn.Text = L("ВЕРНУТЬСЯ В ИГРУ", "BACK TO GAME")
	backBtn.Visible = false
	backBtn.ZIndex = 8
	backBtn.Parent = root
	corner(backBtn, 2)
	local backStroke = Instance.new("UIStroke")
	backStroke.Color = P.gold
	backStroke.Thickness = 2
	backStroke.Parent = backBtn
	backBtn.Activated:Connect(function()
		self:hide()
	end)

	-- animated accents: pulsing title rule + ember glow
	task.spawn(function()
		local t = 0
		while gui.Parent do
			t += 0.05
			local k = 0.5 + 0.5 * math.sin(t * 2)
			if tStroke then
				tStroke.Transparency = 0.35 + 0.3 * k
			end
			backStroke.Transparency = 0.2 + 0.4 * k
			task.wait(0.05)
		end
	end)

	-- ================= behaviour =================
	self.screen = "MAIN"
	self.menuOpen = true
	self.matchStarted = false

	function self:_status(label, txt)
		if label then
			label.Text = txt or ""
		end
	end

	function self:show(name)
		self.screen = name
		for key, frame in pairs(screens) do
			frame.Visible = (key == name)
		end
		self.menuOpen = true
		self.gui.Enabled = true
		if self.openFront then
			self.openFront.Enabled = false
		end
		self.root.Visible = true
		self.backToGame.Visible = self.inMatch == true
		if self.lobby and self.lobby.shade then
			pcall(function()
				self.lobby.shade.Visible = false
			end)
		end
	end

	function self:hide()
		self.menuOpen = false
		self.root.Visible = false
		self.gui.Enabled = false
		if self.openFront then
			self.openFront.Enabled = true
		end
	end

	-- Main tells us when a match is actually running (GameState received), so a
	-- fresh "new game" request always goes through restart_match.
	function self:setMatchActive(active: boolean)
		self.inMatch = active
		if self.backToGame then
			self.backToGame.Visible = active and self.menuOpen == true
		end
	end

	function self:isMenuOpen(): boolean
		return self.menuOpen == true
	end

	function self:_set(key, value)
		if self.lobby then
			local ok = pcall(function()
				self.lobby:_set(key, value)
			end)
			if ok then
				return
			end
		end
		if self.net then
			self.net.Intent:FireServer({ type = "lobby_set", key = key, value = value })
		end
	end

	function self:_matchmake(intentType, notice, extra)
		local st = self.lobby and self.lobby.state
		if st and st.canMatchmake ~= true then
			self:_status(self.onlineStatus, L("Матчмейкинг доступен только в опубликованной игре (не в Studio).", "Matchmaking is available only in the published game (not in Studio)."))
			if self.duelStatus then
				self:_status(self.duelStatus, self.onlineStatus.Text)
			end
			return
		end
		local msg = { type = intentType }
		for k, v in extra or {} do
			msg[k] = v
		end
		local label = if msg.duel then self.duelStatus else self.onlineStatus
		-- A teleport takes a few seconds; repeated clicks used to create a chain of
		-- new empty servers. Ignore clicks until it lands or fails.
		if self._mmBusy and os.clock() < self._mmBusy then
			self:_status(label, L("Уже переношу на сервер, подожди…", "Already moving you to a server, hold on…"))
			return
		end
		self._mmBusy = os.clock() + 20
		self.net.Intent:FireServer(msg)
		if notice then
			self:_status(label, notice .. L("  Сейчас будет экран загрузки.", "  A loading screen will appear."))
		end
	end

	local function matchmakeDone(txt)
		self._mmBusy = nil
		-- keep the answer readable instead of the next lobby refresh overwriting it
		self._mmHoldUntil = os.clock() + 5
		if txt then
			self:_status(self.onlineStatus, txt)
			self:_status(self.duelStatus, txt)
		end
	end
	pcall(function()
		game:GetService("TeleportService").TeleportInitFailed:Connect(function(player, result, errorMessage)
			if player == Players.LocalPlayer then
				matchmakeDone(L("Не удалось перейти на сервер: ", "Could not move to the server: ") .. tostring(errorMessage or result) .. L(". Попробуй ещё раз.", ". Try again."))
			end
		end)
	end)
	if self.net and self.net.Event then
		self.net.Event.OnClientEvent:Connect(function(evt)
			if type(evt) ~= "table" then
				return
			elseif evt.type == "AlreadyInLobby" then
				matchmakeDone(L("Ты уже в онлайн-лобби: матч начнётся сам, когда закончится отсчёт.", "You are already in the online lobby: the match starts when the countdown ends."))
			elseif evt.type == "JoinCodeFailed" then
				matchmakeDone(L("Нет матча с таким кодом. Проверь код (буквы и цифры, 6 знаков).", "No match with that code. Check it (6 letters/digits)."))
			elseif evt.type == "MatchmakeFailed" then
				matchmakeDone(L("Не получилось создать сервер, попробуй ещё раз.", "Could not create a server, try again."))
			end
		end)
	end

	-- The options picked on the SOLO CAMPAIGN screen.
	function self:_menuSettings()
		return {
			map = self.selectedMap,
			mode = self.options.mode,
			difficulty = self.options.difficulty,
			startingGold = self.options.startingGold,
			goldMultiplier = self.options.goldMultiplier,
			bots = self.options.bots,
		}
	end

	function self:_startMatch(asDuel, statusLabel)
		if self.inMatch then
			-- Opened from the defeat screen: start a fresh match on this server
			-- WITH the settings picked in the menu (map included).
			self.inMatch = false
			self:hide()
			self.net.Intent:FireServer({ type = "restart_match", settings = self:_menuSettings() })
			return
		end
		local st = self.lobby and self.lobby.state
		if not st then
			self:_status(statusLabel or self.noticeLabel, L("Ждём данные лобби…", "Waiting for lobby data…"))
			return
		end
		if st.mode == "public" and not asDuel then
			-- Public server: open our own singleplayer server; the picked settings travel in
			-- the teleport data and the match starts there automatically.
			if st.canMatchmake ~= true then
				self:_status(self.noticeLabel, L("Одиночный сервер доступен только в опубликованной игре.", "Singleplayer servers work only in the published game."))
				return
			end
			self.net.Intent:FireServer({ type = "play_solo", settings = self:_menuSettings() })
			self:_status(self.noticeLabel, L("Создаю одиночный сервер…", "Creating a singleplayer server…"))
			return
		end
		if st.hostUserId ~= LOCAL_ID then
			self:_status(statusLabel or self.noticeLabel, L("Матч начинает только хост.", "Only the host can start the match."))
			return
		end
		self:_set("map", self.selectedMap)
		self:_set("mode", self.options.mode)
		self:_set("difficulty", self.options.difficulty)
		self:_set("startingGold", self.options.startingGold)
		self:_set("goldMultiplier", self.options.goldMultiplier)
		self:_set("bots", self.options.bots)
		self:_status(statusLabel or (asDuel and self.duelStatus or self.noticeLabel), L("Запускаю войну…", "Starting the war…"))
		task.delay(0.4, function()
			self.net.Intent:FireServer({ type = "lobby_start" })
		end)
	end

	local function refreshFromLobby(st)
		self.lobbyState = st
		if st == nil then
			return
		end
		-- Player card: real career stats from the profile instead of a dummy rank.
		local my = st.stats and st.stats[tostring(LOCAL_ID)]
		if my and rank.Parent then
			rank.Text = L("ПОБЕД: ", "WINS: ") .. tostring(my.wins or 0) .. "  ·  " .. L("ЛУЧШИЙ ", "BEST ") .. tostring(my.bestPct or 0) .. "%"
		end
		if st.starting then
			self:hide()
			self.inMatch = true
			self.matchStarted = true
			-- The lobby countdown is over; don't leave "STARTS IN 1 S" on the menu.
			local live = L("МАТЧ ИДЁТ · «НАЗАД В ИГРУ» ВЕРНЁТ НА КАРТУ", "MATCH IN PROGRESS · \"BACK TO GAME\" RETURNS TO THE MAP")
			if self.mainStatus then
				self.mainStatus.Text = live
			end
			if self.onlineStatus then
				self.onlineStatus.Text = live
			end
			if self.duelStatus then
				self.duelStatus.Text = live
			end
			return
		end
		if st.settings then
			self.inMatch = false
			if self.matchStarted then
				self.matchStarted = false
				self:show("MAIN")
			end
			if self.lobby and self.lobby.shade then
				self.lobby.shade.Visible = false
			end
			-- How did we get to this server? (teleport data attached by Matchmaking)
			if self._td == nil then
				local ok, td = pcall(function()
					return game:GetService("TeleportService"):GetLocalPlayerTeleportData()
				end)
				self._td = if ok and type(td) == "table" then td else false
			end
			local td = self._td or {}
			local isHost = st.hostUserId == LOCAL_ID
			local mapName = st.settings.map
			for _, entry in ipairs(MapCatalog) do
				if entry.id == st.settings.map then
					mapName = entry.name or entry.id
					break
				end
			end
			-- The old lobby screen (countdown, players, code) is hidden by this shell, so the
			-- server state is shown on MAIN and on the ONLINE / DUEL screens instead.
			local statusText = ""
			local screenText = "" -- ONLINE / DUEL screens (the code itself sits in the card there)
			if st.mode == "public" then
				statusText = L("ПУБЛИЧНЫЙ МАТЧ · ИГРОКОВ: ", "PUBLIC MATCH · PLAYERS: ") .. tostring(#(st.players or {}))
				if st.secondsLeft then
					statusText ..= "  ·  " .. L("СТАРТ ЧЕРЕЗ ", "STARTS IN ") .. tostring(st.secondsLeft) .. L(" С", " S")
				end
				statusText ..= "\n" .. L("КАРТА: ", "MAP: ") .. string.upper(tostring(mapName)) .. L("  ·  ИЛИ ВЫБЕРИ СОЛО-КАМПАНИЮ", "  ·  OR PICK SOLO CAMPAIGN")
				screenText = L("ТЫ В ОНЛАЙН-ЛОББИ. ", "YOU ARE IN THE ONLINE LOBBY. ") .. statusText
			elseif st.mode == "custom" and st.canMatchmake == true then
				local code = if st.joinCode then L("КОД: ", "JOIN CODE: ") .. tostring(st.joinCode) .. "  ·  " else ""
				local rest = L("ИГРОКОВ: ", "PLAYERS: ") .. tostring(#(st.players or {})) .. "\n" .. (if isHost
					then L("Отправь код и жми НАЧАТЬ МАТЧ / НАЧАТЬ ДУЭЛЬ, когда все зайдут.", "Send the code, then press START MATCH / START DUEL once everyone is in.")
					else L("Ждём, пока хост начнёт матч…", "Waiting for the host to start…"))
				statusText = code .. rest
				screenText = if st.joinCode then rest else statusText
			end
			if self.mainStatus then
				self.mainStatus.Text = statusText
			end
			local moving = (self._mmBusy ~= nil and os.clock() < self._mmBusy)
				or (self._mmHoldUntil ~= nil and os.clock() < self._mmHoldUntil)
			if self.onlineStatus and screenText ~= "" and not moving then
				self.onlineStatus.Text = screenText
			end
			if self.duelStatus and st.mode == "custom" and screenText ~= "" and not moving then
				self.duelStatus.Text = screenText
			end
			if self.onlineStartBtn then
				self.onlineStartBtn.Visible = st.mode == "custom" and isHost
			end
			-- On our own private server / arena: show the big code card and hide
			-- "create" (pressing it again would just make yet another empty server).
			local inArena = st.mode == "custom" and st.joinCode ~= nil
			for _, card in { self.onlineCodeCard, self.duelCodeCard } do
				if card then
					card.Visible = inArena
					local box = card:FindFirstChild("Code")
					if inArena and box and box.Text ~= tostring(st.joinCode) then
						box.Text = tostring(st.joinCode)
					end
				end
			end
			if self.onlineCreateRow then
				self.onlineCreateRow.Visible = st.mode ~= "custom"
			end
			if self.duelCreateRow then
				self.duelCreateRow.Visible = st.mode ~= "custom"
			end
			-- First lobby state on this server: open the screen that matches how we got here.
			if not self._arrivalHandled then
				self._arrivalHandled = true
				if st.mode == "custom" and (td.custom or td.duel) then
					self:show(if td.duel then "DUEL" else "ONLINE")
				elseif st.mode == "public" and td.publicLobby then
					self:show("ONLINE")
				elseif st.mode == "solo" and not td.settings then
					self:show("SETUP")
				end
			end
		end
	end
	self._refreshFromLobby = refreshFromLobby

	if self.net and self.net.Lobby then
		self.net.Lobby.OnClientEvent:Connect(function(st)
			refreshFromLobby(st)
		end)
	end

	-- Гасим стандартное лобби и показываем наше меню.
	task.spawn(function()
		while gui.Parent do
			if self.menuOpen and self.lobby and self.lobby.shade then
				pcall(function()
					if self.lobby.shade.Visible then
						self.lobby.shade.Visible = false
					end
				end)
			end
			task.wait(0.25)
		end
	end)

	self.backToGame = backBtn
	self:show("MAIN")
	return self
end

return HighCommand
