-- In-game HUD: spawn countdown, leaderboard, hover info and the winner banner.
-- The control panel lives in ControlPanel.luau.

local GuiService = game:GetService("GuiService")

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Lang = require(script.Parent.Lang)

local PANEL_COLOR = Color3.fromRGB(24, 26, 32)
local PANEL_TRANSPARENCY = 0.2
local TEXT = Color3.fromRGB(235, 235, 240)
local MUTED = Color3.fromRGB(160, 165, 175)
local ACCENT = Color3.fromRGB(70, 140, 255)
local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

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
	corner(f, 8)
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


	-- Leaderboard, top right.
	local board = panel(gui, "Leaderboard")
	board.AnchorPoint = Vector2.new(1, 0)
	board.Position = UDim2.new(1, -12, 0, topInset)
	board.Size = UDim2.fromOffset(260, 0)
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
	modalButton2.BackgroundColor3 = Color3.fromRGB(55, 65, 81)
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
	self:_paintBoard()

	return self
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
	self.boardHeader.Text = (if self.boardOpen then "–  " else "+  ") .. Lang.t("Leaderboard")
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
			r.name.Text = `{i}. {data.name}`
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
	self.modalTitle.TextColor3 = if isWin then Color3.fromRGB(255, 214, 90) else TEXT
	self.modalButton.Text = buttonText
	self.modal.Visible = true
end

return Hud
