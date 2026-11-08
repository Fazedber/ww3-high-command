-- In-game HUD: spawn countdown, leaderboard, hover info and the winner banner.
-- The control panel lives in ControlPanel.luau.

local GuiService = game:GetService("GuiService")

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Lang = require(script.Parent.Lang)
local Icons = require(script.Parent:WaitForChild("Icons"))
local Locale = require(script.Parent:WaitForChild("Locale"))
local FlagAtlas = require(script.Parent:WaitForChild("FlagAtlas"))

local PANEL_COLOR = Color3.fromRGB(10, 12, 32)
local PANEL_TRANSPARENCY = 0.12
local TEXT = Color3.fromRGB(244, 236, 226)
local MUTED = Color3.fromRGB(128, 128, 172)
local ACCENT = Color3.fromRGB(138, 143, 240)
local FONT = Enum.Font.Arcade
local FONT_BOLD = Enum.Font.Arcade

local Hud = {}
Hud.__index = Hud

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function padding(parent: Instance, px: number)
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	p.PaddingTop = UDim.new(0, px)
	p.PaddingBottom = UDim.new(0, px)
	p.Parent = parent
end

local function panel(parent: Instance, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = PANEL_COLOR
	f.BackgroundTransparency = PANEL_TRANSPARENCY
	f.BorderSizePixel = 0
	f.Active = true -- sink input so clicks on panels don't reach the map
	corner(f, 2)
	f.BackgroundColor3 = Color3.fromRGB(10, 12, 32)
	f.BackgroundTransparency = 0.03
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(45, 48, 110)
	st.Thickness = 2
	st.Transparency = 0.1
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = f
	f.Parent = parent
	return f
end

local function label(parent: Instance, name: string, text: string, size: number, font: Enum.Font?, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font or FONT
	l.TextSize = size
	l.TextColor3 = color or TEXT
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	l.Parent = parent
	return l
end

function Hud.new(gui: ScreenGui)
	local self = setmetatable({ gui = gui }, Hud)

	-- Spawn countdown: big digits in the middle of the screen. The top bar
	-- belongs to Roblox (logo / menu top left), so nothing goes up there.
	local countdown = Instance.new("Frame")
	countdown.Name = "Countdown"
	countdown.AnchorPoint = Vector2.new(0.5, 0.5)
	countdown.Position = UDim2.fromScale(0.5, 0.45)
	countdown.Size = UDim2.fromOffset(420, 130)
	countdown.BackgroundTransparency = 1
	countdown.Visible = false
	countdown.Parent = gui
	local digits = label(countdown, "Digits", "", 96, FONT_BOLD)
	digits.Size = UDim2.new(1, 0, 0, 96)
	digits.TextXAlignment = Enum.TextXAlignment.Center
	local digitsStroke = Instance.new("UIStroke")
	digitsStroke.Thickness = 3
	digitsStroke.Transparency = 0.2
	digitsStroke.Parent = digits
	local subtitle = label(countdown, "Subtitle", "", 22, FONT_BOLD)
	subtitle.Position = UDim2.fromOffset(0, 100)
	subtitle.Size = UDim2.new(1, 0, 0, 26)
	subtitle.TextXAlignment = Enum.TextXAlignment.Center
	local subtitleStroke = Instance.new("UIStroke")
	subtitleStroke.Thickness = 2
	subtitleStroke.Transparency = 0.3
	subtitleStroke.Parent = subtitle
	self.countdown, self.countdownDigits, self.countdownSubtitle = countdown, digits, subtitle

	-- Panels at the top sit below Roblox's top bar.
	local topInset = GuiService:GetGuiInset().Y + 8

	-- CROWN WORLD: the current ruler of the world (top centre, under Roblox bar).
	local crown = Instance.new("Frame")
	crown.Name = "Crown"
	crown.AnchorPoint = Vector2.new(0.5, 0)
	crown.Position = UDim2.new(0.5, 0, 0, topInset + 34)
	crown.Size = UDim2.fromOffset(330, 28)
	crown.BackgroundColor3 = PANEL_COLOR
	crown.BackgroundTransparency = 0.15
	crown.BorderSizePixel = 0
	crown.Visible = false
	corner(crown, 8)
	local crownStroke = Instance.new("UIStroke")
	crownStroke.Thickness = 1
	crownStroke.Color = Color3.fromRGB(242, 201, 160)
	crownStroke.Transparency = 0.35
	crownStroke.Parent = crown
	local crownText = label(crown, "Text", "", 16, FONT_BOLD, Color3.fromRGB(138, 143, 240))
	crownText.Size = UDim2.new(1, 0, 1, 0)
	crownText.TextXAlignment = Enum.TextXAlignment.Center
	crown.Parent = gui
	crown.Visible = false -- the ruler now lives in the leaderboard header (edge layout)
	self.crownFrame, self.crownText = crown, crownText


	-- Leaderboard, top right.
	local board = panel(gui, "Leaderboard")
	board.AnchorPoint = Vector2.new(1, 0)
	board.Position = UDim2.new(1, -8, 0, topInset + 4)
	board.Size = UDim2.fromOffset(236, 0)
	local boardScale = Instance.new("UIScale")
	boardScale.Scale = 1.05
	boardScale.Parent = board
	board.AutomaticSize = Enum.AutomaticSize.Y
	padding(board, 10)
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = board
	-- Header toggles the rows (upstream GameLeftSidebar leaderboard toggle);
	-- collapsed from the start on phone-sized screens.
	local header = Instance.new("TextButton")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Font = FONT_BOLD
	header.TextSize = 15
	header.TextColor3 = TEXT
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Size = UDim2.new(1, 0, 0, 20)
	header.TextTruncate = Enum.TextTruncate.AtEnd
	header.LayoutOrder = 0
	header.Parent = board
	local viewport = workspace.CurrentCamera.ViewportSize
	self.boardOpen = viewport.Y >= 500 and viewport.X >= 900
	self.board, self.boardHeader = board, header
	header.Activated:Connect(function()
		self.boardOpen = not self.boardOpen
		self:_paintBoard()
	end)
	self.boardRows = {}
	for i = 1, 10 do
		local row = Instance.new("Frame")
		row.Name = `Row{i}`
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 18)
		row.LayoutOrder = i
		row.Parent = board
		local name = label(row, "Name", "", 13)
		name.Size = UDim2.new(0.6, 0, 1, 0)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		local pct = label(row, "Pct", "", 13, FONT, MUTED)
		pct.Position = UDim2.fromScale(0.6, 0)
		pct.Size = UDim2.new(0.2, 0, 1, 0)
		pct.TextXAlignment = Enum.TextXAlignment.Right
		local tr = label(row, "Troops", "", 13, FONT, MUTED)
		tr.Position = UDim2.fromScale(0.8, 0)
		tr.Size = UDim2.new(0.2, 0, 1, 0)
		tr.TextXAlignment = Enum.TextXAlignment.Right
		row.Visible = false
		self.boardRows[i] = { frame = row, name = name, pct = pct, troops = tr }
	end

	-- Hover info, bottom left.
	local hover = panel(gui, "Hover")
	hover.AnchorPoint = Vector2.new(0, 1)
	hover.Position = UDim2.new(0, 12, 1, -12)
	hover.AutomaticSize = Enum.AutomaticSize.XY
	hover.Active = false
	padding(hover, 6)
	local hoverText = label(hover, "Text", "", 14)
	hoverText.AutomaticSize = Enum.AutomaticSize.XY
	hover.Visible = false
	self.hover, self.hoverText = hover, hoverText

	-- End-of-life modal (upstream WinModal): "You died" / winner, one button.
	local modal = panel(gui, "EndModal")
	modal.AnchorPoint = Vector2.new(0.5, 0.5)
	modal.Position = UDim2.fromScale(0.5, 0.42)
	modal.Size = UDim2.fromOffset(360, 0)
	modal.AutomaticSize = Enum.AutomaticSize.Y
	modal.ZIndex = 20
	padding(modal, 22)
	local modalLayout = Instance.new("UIListLayout")
	modalLayout.SortOrder = Enum.SortOrder.LayoutOrder
	modalLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	modalLayout.Padding = UDim.new(0, 16)
	modalLayout.Parent = modal
	local modalTitle = label(modal, "Title", "", 34, FONT_BOLD)
	modalTitle.Size = UDim2.new(1, 0, 0, 40)
	modalTitle.TextXAlignment = Enum.TextXAlignment.Center
	modalTitle.TextWrapped = true
	modalTitle.ZIndex = 21
	modalTitle.LayoutOrder = 1
	local modalButton = Instance.new("TextButton")
	modalButton.Name = "Button"
	modalButton.Size = UDim2.fromOffset(200, 44)
	modalButton.BackgroundColor3 = ACCENT
	modalButton.BorderSizePixel = 0
	modalButton.Font = FONT_BOLD
	modalButton.TextSize = 18
	modalButton.TextColor3 = Color3.new(1, 1, 1)
	modalButton.AutoButtonColor = true
	modalButton.ZIndex = 21
	modalButton.LayoutOrder = 2
	corner(modalButton, 8)
	modalButton.Parent = modal
	modalButton.Activated:Connect(function()
		modal.Visible = false
	end)
	-- Optional second action (e.g. "Find new match").
	local modalButton2 = modalButton:Clone()
	modalButton2.Name = "Button2"
	modalButton2.BackgroundColor3 = Color3.fromRGB(46, 50, 100)
	modalButton2.LayoutOrder = 3
	modalButton2.Visible = false
	modalButton2.Parent = modal
	modalButton2.Activated:Connect(function()
		modal.Visible = false
		if self.modalAction2 then
			self.modalAction2()
		end
	end)
	-- Optional third action (Rebirth on the death screen), gold.
	local modalButton3 = modalButton:Clone()
	modalButton3.Name = "Button3"
	modalButton3.BackgroundColor3 = Color3.fromRGB(202, 138, 4)
	modalButton3.LayoutOrder = 1
	modalButton3.Visible = false
	modalButton3.Parent = modal
	modalButton3.Activated:Connect(function()
		if self.modalAction3 then
			self.modalAction3()
		end
	end)
	modal.Visible = false
	self.modal, self.modalTitle, self.modalButton, self.modalButton2, self.modalButton3 = modal, modalTitle, modalButton, modalButton2, modalButton3
	-- LEADER CARD (top left): clean pixel-bordered panel, no overlapping icons.
	local card = Instance.new("Frame")
	card.Name = "LeaderCard"
	card.Position = UDim2.new(0, 8, 0, 70)
	card.Size = UDim2.fromOffset(300, 132)
	card.BackgroundColor3 = Color3.fromRGB(10, 12, 32)
	card.BackgroundTransparency = 0.02
	card.BorderSizePixel = 0
	card.Visible = false
	card.Parent = gui
	corner(card, 2)
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = Color3.fromRGB(38, 42, 92)
	cardStroke.Thickness = 2
	cardStroke.Transparency = 0
	cardStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	cardStroke.Parent = card

	local portrait = Instance.new("ImageLabel")
	portrait.Name = "Portrait"
	portrait.Position = UDim2.fromOffset(8, 8)
	portrait.Size = UDim2.fromOffset(64, 88)
	portrait.BackgroundColor3 = Color3.fromRGB(14, 16, 40)
	portrait.Image = ""
	portrait.ScaleType = Enum.ScaleType.Crop
	portrait.Parent = card
	corner(portrait, 2)
	local portraitStroke = Instance.new("UIStroke")
	portraitStroke.Color = Color3.fromRGB(45, 48, 110)
	portraitStroke.Thickness = 1
	portraitStroke.Parent = portrait

	local flag = Instance.new("ImageLabel")
	flag.Name = "Flag"
	flag.AnchorPoint = Vector2.new(1, 0)
	flag.Position = UDim2.new(1, -8, 0, 8)
	flag.Size = UDim2.fromOffset(28, 19)
	flag.BackgroundColor3 = Color3.fromRGB(14, 16, 40)
	flag.Parent = card
	corner(flag, 1)
	local flagStroke = Instance.new("UIStroke")
	flagStroke.Color = Color3.fromRGB(45, 48, 110)
	flagStroke.Thickness = 1
	flagStroke.Parent = flag

	local cardName = label(card, "Name", "", 16, FONT_BOLD, Color3.fromRGB(244, 236, 226))
	cardName.Position = UDim2.fromOffset(82, 6)
	cardName.Size = UDim2.fromOffset(186, 20)
	cardName.TextTruncate = Enum.TextTruncate.AtEnd
	local cardTitle = label(card, "Title", "", 10, FONT, MUTED)
	cardTitle.Position = UDim2.fromOffset(82, 27)
	cardTitle.Size = UDim2.fromOffset(186, 13)
	cardTitle.TextTruncate = Enum.TextTruncate.AtEnd

	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Position = UDim2.fromOffset(82, 46)
	divider.Size = UDim2.fromOffset(206, 1)
	divider.BackgroundColor3 = Color3.fromRGB(38, 42, 92)
	divider.BorderSizePixel = 0
	divider.Parent = card

	local goldTint = Color3.fromRGB(255, 236, 200)
	local troopsIcon = Icons.label(card, "soldier", 22, { white = true })
	troopsIcon.Position = UDim2.fromOffset(82, 53)
	local troopsText = label(card, "Troops", "", 15, FONT_BOLD, Color3.fromRGB(244, 236, 226))
	troopsText.Position = UDim2.fromOffset(108, 51)
	troopsText.Size = UDim2.fromOffset(78, 20)
	local goldIcon = Icons.label(card, "goldCoin", 20, { white = true })
	goldIcon.Position = UDim2.fromOffset(190, 54)
	local goldText = label(card, "Gold", "0", 13, FONT_BOLD, goldTint)
	goldText.Position = UDim2.fromOffset(214, 53)
	goldText.Size = UDim2.fromOffset(80, 18)

	local cityIcon = Icons.label(card, "city", 20, { color = Color3.fromRGB(190, 192, 230) })
	cityIcon.Position = UDim2.fromOffset(82, 84)
	local citiesText = label(card, "Cities", "0", 11, FONT, TEXT)
	citiesText.Position = UDim2.fromOffset(106, 82)
	citiesText.Size = UDim2.fromOffset(28, 16)
	local factoryIcon = Icons.label(card, "factory", 20, { color = Color3.fromRGB(190, 192, 230) })
	factoryIcon.Position = UDim2.fromOffset(140, 84)
	local factoriesText = label(card, "Factories", "0", 11, FONT, TEXT)
	factoriesText.Position = UDim2.fromOffset(164, 82)
	factoriesText.Size = UDim2.fromOffset(28, 16)
	local portIcon = Icons.label(card, "port", 20, { color = Color3.fromRGB(190, 192, 230) })
	portIcon.Position = UDim2.fromOffset(198, 84)
	local portsText = label(card, "Ports", "0", 11, FONT, TEXT)
	portsText.Position = UDim2.fromOffset(222, 82)
	portsText.Size = UDim2.fromOffset(28, 16)

	local changeButton = Instance.new("TextButton")
	changeButton.Name = "Change"
	changeButton.BackgroundTransparency = 1
	changeButton.Text = ""
	changeButton.Size = UDim2.fromScale(1, 1)
	changeButton.Parent = card
	changeButton.Activated:Connect(function()
		if self.onLeaderClick then
			self.onLeaderClick()
		end
	end)
	-- Hover captions for the unlabeled stat icons (what each number means).
	do
		local Locale = require(script.Parent:WaitForChild("Locale"))
		local tip = label(card, "StatTip", "", 11, FONT, TEXT)
		tip.Position = UDim2.fromOffset(82, 106)
		tip.Size = UDim2.fromOffset(208, 20)
		tip.TextXAlignment = Enum.TextXAlignment.Left
		tip.Visible = false
		local function hit(x, y, w, h, text)
			local b = Instance.new("TextButton")
			b.BackgroundTransparency = 1
			b.Text = ""
			b.Position = UDim2.fromOffset(x, y)
			b.Size = UDim2.fromOffset(w, h)
			b.ZIndex = 5
			b.Parent = card
			b.MouseEnter:Connect(function()
				tip.Text = text
				tip.Visible = true
			end)
			b.MouseLeave:Connect(function()
				tip.Visible = false
			end)
			b.Activated:Connect(function()
				if self.onLeaderClick then
					self.onLeaderClick()
				end
			end)
		end
		hit(82, 50, 104, 24, Locale.pick("ВОЙСКА — твоя армия, растёт со временем", "TROOPS — your army, grows over time"))
		hit(188, 50, 100, 24, Locale.pick("ЗОЛОТО — на постройки и оружие", "GOLD — spend on buildings and weapons"))
		hit(82, 80, 54, 24, Locale.pick("ГОРОДА — больше населения и дохода", "CITIES — more population and income"))
		hit(138, 80, 56, 24, Locale.pick("ФАБРИКИ — поезда везут золото", "FACTORIES — trains carry gold"))
		hit(196, 80, 56, 24, Locale.pick("ПОРТЫ — торговые и боевые корабли", "PORTS — trade and war ships"))
	end
	self.leaderCard, self.leaderPortrait, self.leaderFlag = card, portrait, flag
	self.leaderName, self.leaderTitle = cardName, cardTitle
	self.leaderTroops, self.leaderGold = troopsText, goldText
	self.leaderCities, self.leaderFactories, self.leaderPorts = citiesText, factoriesText, portsText


	-- MENU button: always available, returns to the High Command main menu.
	local menuButton = Instance.new("TextButton")
	menuButton.Name = "MenuButton"
	menuButton.AnchorPoint = Vector2.new(0, 0)
	menuButton.Position = UDim2.new(0, 8, 0, topInset + 4 + 100 + 6)
	menuButton.Size = UDim2.fromOffset(84, 28)
	menuButton.BackgroundColor3 = PANEL_COLOR
	menuButton.BackgroundTransparency = 0.12
	menuButton.BorderSizePixel = 0
	menuButton.Font = FONT_BOLD
	menuButton.TextSize = 14
	menuButton.TextColor3 = Color3.fromRGB(168, 172, 246)
	menuButton.Text = Locale.pick("МЕНЮ", "MENU")
	menuButton.Visible = false
	corner(menuButton, 5)
	local menuStroke = Instance.new("UIStroke")
	menuStroke.Color = Color3.fromRGB(138, 143, 240)
	menuStroke.Thickness = 1
	menuStroke.Transparency = 0.4
	menuStroke.Parent = menuButton
	menuButton.Parent = gui
	menuButton.Activated:Connect(function()
		if self.onMenuClick then
			self.onMenuClick()
		end
	end)
	self.menuButton = menuButton

	-- Top panels are pinned to the REAL topbar inset: reading the inset once at
	-- startup could return 0 (before the top bar loads), which clipped the card.
	local function layoutTop()
		local inset = 0
		pcall(function()
			inset = GuiService:GetGuiInset().Y
		end)
		local top = inset + 8
		board.Position = UDim2.new(1, -8, 0, top + 4)
		card.Position = UDim2.new(0, 8, 0, top + 4)
		menuButton.Position = UDim2.new(0, 8, 0, top + 4 + card.AbsoluteSize.Y + 6)
	end
	layoutTop()
	task.spawn(function()
		for _ = 1, 5 do
			task.wait(0.4)
			layoutTop()
		end
	end)
	pcall(function()
		GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(layoutTop)
	end)

	self:_paintBoard()

	return self
end

-- CROWN WORLD banner text; pass nil to hide the banner.
function Hud:setCrown(text: string?)
	-- Edge layout: the ruler is shown in the leaderboard header instead of a
	-- banner in the middle of the screen. Keep only the short name there.
	if text == nil or text == "" then
		self.rulerText = ""
		self:_paintBoard()
		return
	end
	local short = text:gsub("^[^%w]+", "")
	short = short:gsub(" rules the world.*$", "")
	short = short:gsub(" overthrew .*$", "")
	short = short:gsub(" claims the crown.*$", "")
	short = short:gsub("%s+$", "")
	self.rulerText = short
	self:_paintBoard()
end

-- Big centred countdown; pass nil seconds to hide it.
function Hud:setCountdown(seconds: (number | string)?, subtitle: string?)
	self.countdown.Visible = seconds ~= nil
	if seconds ~= nil then
		self.countdownDigits.Text = tostring(seconds)
		self.countdownSubtitle.Text = subtitle or ""
	end
end

function Hud:_paintBoard()
	local ruler = self.rulerText
	if ruler and ruler ~= "" then
		self.boardHeader.Text = (if self.boardOpen then "–  " else "+  ") .. ruler
	else
		self.boardHeader.Text = (if self.boardOpen then "–  " else "+  ") .. Lang.t("Leaderboard")
	end
	self.board.Size = UDim2.fromOffset(if self.boardOpen then 260 else 150, 0)
	for i, r in self.boardRows do
		r.frame.Visible = self.boardOpen and self.boardData ~= nil and self.boardData[i] ~= nil
	end
end

-- rows: { { name, pct (0-1), troops, isMe } }
function Hud:setLeaderboard(rows)
	self.boardData = rows
	for i, r in self.boardRows do
		local data = rows[i]
		r.frame.Visible = self.boardOpen and data ~= nil
		if data then
			r.name.Text = (if data.crown then "👑 " else "") .. `{i}. {data.name}`
			r.name.Font = if data.isMe then FONT_BOLD else FONT
			r.name.TextColor3 = if data.isMe then ACCENT else TEXT
			r.pct.Text = Format.formatPercentage(data.pct)
			r.troops.Text = Format.renderTroops(data.troops)
		end
	end
end

function Hud:setHover(text: string?)
	self.hover.Visible = text ~= nil and text ~= ""
	if text then
		self.hoverText.Text = text
	end
end

-- Modal with a title and one dismiss button (upstream WinModal texts:
-- "You died" + "Spectate", "You Won!" / "X has won!" + "OK"; no "Keep Playing"
-- on Roblox servers, a new match follows).
-- secondText / secondAction: optional second button (matchmaking).
function Hud:showModal(title: string, buttonText: string, isWin: boolean?, secondText: string?, secondAction: (() -> ())?, thirdText: string?, thirdAction: (() -> ())?)
	self.modalButton3.Visible = thirdText ~= nil
	self.modalButton3.Text = thirdText or ""
	self.modalAction3 = thirdAction
	self.modalButton2.Visible = secondText ~= nil
	self.modalButton2.Text = secondText or ""
	self.modalAction2 = secondAction
	self.modalTitle.Text = title
	self.modalTitle.TextColor3 = if isWin then Color3.fromRGB(242, 201, 160) else TEXT
	self.modalButton.Text = buttonText
	self.modal.Visible = true
end

-- LEADER CARD: portrait + flag of the chosen leader, army and buildings summary.
function Hud:setOnLeaderClick(fn)
	self.onLeaderClick = fn
end

function Hud:setLeader(leader, flagCode: string?)
	if leader == nil then
		return
	end
	self.leaderPortrait.Image = leader.portrait
	self.leaderName.Text = Locale.pick(leader.name, leader.name_en or leader.name)
	self.leaderTitle.Text = Locale.pick(leader.title, leader.title_en or leader.title)
	FlagAtlas.apply(self.leaderFlag, flagCode)
	self.leaderCard.Visible = true
end

function Hud:setLeaderStats(troops: number, maxTroops: number, gold: number, units: any?)
	self.leaderTroops.Text = Format.renderTroops(troops or 0)
	self.leaderGold.Text = Format.renderNumber(gold or 0)
	local u = units or {}
	local function count(v)
		local n = tonumber(v) or 0
		return if n > 0 then tostring(n) else ""
	end
	self.leaderCities.Text = count(u.City)
	self.leaderFactories.Text = count(u.Factory)
	self.leaderPorts.Text = count(u.Port)
end

function Hud:setLeaderVisible(visible: boolean)
	self.leaderCard.Visible = visible
end

function Hud:setMenuCallback(fn)
	self.onMenuClick = fn
	self.menuButton.Visible = true
end

return Hud
