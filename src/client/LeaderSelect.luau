-- LeaderSelect: pre-game "choose your leader + flag" screen.
-- 20 blocky leader portraits, any country flag from the flag atlas.
-- Calls back with (leaderId, flagCode) when confirmed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Leaders = require(Shared:WaitForChild("Data"):WaitForChild("Leaders"))
local FlagAtlas = require(script.Parent:WaitForChild("FlagAtlas"))
local Locale = require(script.Parent:WaitForChild("Locale"))
local L = Locale.pick

local P = {
	gold = Color3.fromRGB(138, 143, 240),
	goldDim = Color3.fromRGB(45, 48, 110),
	parchment = Color3.fromRGB(244, 236, 226),
	dim = Color3.fromRGB(128, 128, 172),
	dark = Color3.fromRGB(5, 6, 20),
	panel = Color3.fromRGB(14, 16, 40),
	panel2 = Color3.fromRGB(18, 20, 50),
}
local SERIF = Font.fromEnum(Enum.Font.Arcade)
local SERIF_BOLD = Font.fromEnum(Enum.Font.Arcade)
local SMALL = Font.fromEnum(Enum.Font.Arcade)

local LeaderSelect = {}
LeaderSelect.__index = LeaderSelect

local function corner(o, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 4)
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

local function label(parent, name, text, size, color, font)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.FontFace = font or SERIF
	l.TextSize = size
	l.TextColor3 = color or P.parchment
	l.Text = text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

function LeaderSelect.new(opts)
	local self = setmetatable({ selected = nil, flag = nil, onConfirm = opts.onConfirm }, LeaderSelect)

	local gui = Instance.new("ScreenGui")
	gui.Name = "LeaderSelect"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 400
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	self.gui = gui

	local shade = Instance.new("Frame")
	shade.Name = "Shade"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.2
	shade.BorderSizePixel = 0
	shade.Parent = gui
	self.shade = shade

	local root = Instance.new("Frame")
	root.Name = "Panel"
	root.Size = UDim2.fromOffset(780, 640)
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.BackgroundColor3 = P.panel
	root.BackgroundTransparency = 0
	root.BorderSizePixel = 0
	root.Parent = gui
	corner(root, 4)
	stroke(root, P.gold, 2)
	local inner = Instance.new("Frame")
	inner.Size = UDim2.new(1, -12, 1, -12)
	inner.Position = UDim2.fromOffset(6, 6)
	inner.BackgroundTransparency = 1
	inner.Parent = root
	stroke(inner, Color3.fromRGB(58, 72, 88), 1, 0.2)
	self.root = root

	-- responsive scale
	local uiscale = Instance.new("UIScale")
	uiscale.Parent = root
	local function fit()
		local vp = workspace.CurrentCamera.ViewportSize
		if vp.X >= 1000 then
			-- Wide screens: dock to the bottom-right, the map stays visible.
			uiscale.Scale = math.min(1, vp.Y / 700)
			root.AnchorPoint = Vector2.new(1, 1)
			root.Position = UDim2.new(1, -16, 1, -16)
		else
			uiscale.Scale = math.min(vp.X / 810, vp.Y / 680)
			root.AnchorPoint = Vector2.new(0.5, 0.5)
			root.Position = UDim2.fromScale(0.5, 0.5)
		end
	end
	fit()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)

	local title = label(root, "Title", L("ВЫБЕРИ СВОЕГО ЛИДЕРА", "CHOOSE YOUR LEADER"), 30, P.parchment, SERIF)
	title.Position = UDim2.fromOffset(24, 16)
	title.Size = UDim2.fromOffset(520, 34)
	local sub = label(root, "Sub", L("Кто поведёт твою нацию? Флаг — любой страны, даже если воюешь за другую.", "Who will lead your nation? Pick any country flag, even a foreign one."), 14, P.dim, SMALL)
	sub.Position = UDim2.fromOffset(24, 52)
	sub.Size = UDim2.fromOffset(560, 18)

	-- selected preview (right side)
	local preview = Instance.new("Frame")
	preview.Position = UDim2.fromOffset(556, 16)
	preview.Size = UDim2.fromOffset(200, 150)
	preview.BackgroundColor3 = P.panel2
	preview.BorderSizePixel = 0
	preview.Parent = root
	corner(preview, 4)
	stroke(preview, P.goldDim, 1, 0.3)
	local pPortrait = Instance.new("ImageLabel")
	pPortrait.Name = "Portrait"
	pPortrait.Position = UDim2.fromOffset(8, 8)
	pPortrait.Size = UDim2.fromOffset(72, 92)
	pPortrait.BackgroundColor3 = Color3.fromRGB(12, 16, 22)
	pPortrait.BackgroundTransparency = 0
	pPortrait.Image = ""
	pPortrait.ScaleType = Enum.ScaleType.Crop
	pPortrait.Parent = preview
	corner(pPortrait, 3)
	stroke(pPortrait, P.goldDim, 1)
	local pFlag = Instance.new("ImageLabel")
	pFlag.Name = "Flag"
	pFlag.Position = UDim2.fromOffset(168, 8)
	pFlag.Size = UDim2.fromOffset(24, 16)
	pFlag.BackgroundColor3 = Color3.fromRGB(12, 16, 22)
	pFlag.BackgroundTransparency = 0.2
	pFlag.Image = ""
	pFlag.Parent = preview
	stroke(pFlag, P.goldDim, 1, 0.2)
	local pName = label(preview, "Name", "", 12, P.parchment, SERIF)
	pName.Position = UDim2.fromOffset(88, 6)
	pName.Size = UDim2.fromOffset(76, 34)
	pName.TextWrapped = true
	pName.TextYAlignment = Enum.TextYAlignment.Top
	local pTitle = label(preview, "Title", "", 9, P.dim, SMALL)
	pTitle.Position = UDim2.fromOffset(88, 40)
	pTitle.Size = UDim2.fromOffset(76, 24)
	pTitle.TextWrapped = true
	pTitle.TextYAlignment = Enum.TextYAlignment.Top
	local pFlagName = label(preview, "FlagName", "", 9, P.gold, SMALL)
	pFlagName.Position = UDim2.fromOffset(88, 68)
	pFlagName.Size = UDim2.fromOffset(76, 14)
	self.preview = { portrait = pPortrait, flag = pFlag, name = pName, title = pTitle, flagName = pFlagName }

	-- leaders grid
	local gridTitle = label(root, "GridTitle", L("ЛИДЕР (20)", "LEADER (20)"), 14, P.gold, SMALL)
	gridTitle.Position = UDim2.fromOffset(24, 84)
	gridTitle.Size = UDim2.fromOffset(300, 16)
	local grid = Instance.new("ScrollingFrame")
	grid.Position = UDim2.fromOffset(24, 106)
	grid.Size = UDim2.fromOffset(520, 232)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 4
	grid.ScrollBarImageColor3 = P.goldDim
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.CanvasSize = UDim2.new(0, 0, 0, 0)
	grid.Parent = root
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.fromOffset(100, 108)
	gl.CellPadding = UDim2.fromOffset(6, 6)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = grid
	self.leaderButtons = {}

	for _, leader in ipairs(Leaders) do
		local card = Instance.new("TextButton")
		card.Name = "L" .. leader.id
		card.BackgroundColor3 = P.panel2
		card.BackgroundTransparency = 0
		card.BorderSizePixel = 0
		card.Text = ""
		card.AutoButtonColor = false
		card.LayoutOrder = leader.id
		card.Parent = grid
		corner(card, 3)
		local st = stroke(card, Color3.fromRGB(58, 72, 88), 1, 0.3)
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Position = UDim2.fromOffset(4, 4)
		img.Size = UDim2.fromOffset(92, 78)
		img.ScaleType = Enum.ScaleType.Crop
		img.Image = leader.portrait
		img.Parent = card
		corner(img, 2)
		local nm = label(card, "Name", Locale.pick(leader.name, leader.name_en or leader.name), 10, P.parchment, SERIF)
		nm.Position = UDim2.fromOffset(4, 84)
		nm.Size = UDim2.fromOffset(92, 22)
		nm.TextWrapped = true
		nm.TextXAlignment = Enum.TextXAlignment.Center
		nm.TextYAlignment = Enum.TextYAlignment.Top
		card.Activated:Connect(function()
			self:_selectLeader(leader)
		end)
		table.insert(self.leaderButtons, { id = leader.id, frame = card, stroke = st })
	end

	-- flags
	local flagTitle = label(root, "FlagTitle", L("ФЛАГ СТРАНЫ (любой)", "COUNTRY FLAG (any)"), 14, P.gold, SMALL)
	flagTitle.Position = UDim2.fromOffset(24, 348)
	flagTitle.Size = UDim2.fromOffset(300, 16)
	local flagsFrame = Instance.new("ScrollingFrame")
	flagsFrame.Position = UDim2.fromOffset(24, 370)
	flagsFrame.Size = UDim2.fromOffset(730, 150)
	flagsFrame.BackgroundColor3 = Color3.fromRGB(16, 21, 28)
	flagsFrame.BackgroundTransparency = 0
	flagsFrame.BorderSizePixel = 0
	flagsFrame.ScrollBarThickness = 4
	flagsFrame.ScrollBarImageColor3 = P.goldDim
	flagsFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	flagsFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	flagsFrame.Parent = root
	corner(flagsFrame, 3)
	local fl = Instance.new("UIGridLayout")
	fl.CellSize = UDim2.fromOffset(54, 46)
	fl.CellPadding = UDim2.fromOffset(5, 5)
	fl.SortOrder = Enum.SortOrder.LayoutOrder
	fl.Parent = flagsFrame
	self.flagButtons = {}
	local codes = FlagAtlas.codes
	for i, code in ipairs(codes) do
		local b = Instance.new("TextButton")
		b.Name = code
		b.BackgroundColor3 = Color3.fromRGB(30, 38, 48)
		b.BackgroundTransparency = 0
		b.BorderSizePixel = 0
		b.Text = ""
		b.AutoButtonColor = false
		b.LayoutOrder = i
		b.Parent = flagsFrame
		corner(b, 2)
		local st = stroke(b, Color3.fromRGB(58, 72, 88), 1, 0.35)
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Position = UDim2.fromOffset(5, 4)
		img.Size = UDim2.fromOffset(44, 29)
		img.Parent = b
		FlagAtlas.apply(img, code)
		local codeLabel = label(b, "Code", string.upper(code), 9, P.dim, SMALL)
		codeLabel.Position = UDim2.fromOffset(0, 33)
		codeLabel.Size = UDim2.fromOffset(54, 12)
		codeLabel.TextXAlignment = Enum.TextXAlignment.Center
		b.Activated:Connect(function()
			self:_selectFlag(code)
		end)
		table.insert(self.flagButtons, { code = code, frame = b, stroke = st })
	end

	-- buttons
	local randomBtn = Instance.new("TextButton")
	randomBtn.Name = "Random"
	randomBtn.Position = UDim2.fromOffset(24, 572)
	randomBtn.Size = UDim2.fromOffset(210, 44)
	randomBtn.BackgroundColor3 = P.panel2
	randomBtn.BorderSizePixel = 0
	randomBtn.FontFace = SERIF
	randomBtn.TextSize = 17
	randomBtn.TextColor3 = P.gold
	randomBtn.Text = L("СЛУЧАЙНЫЙ ВЫБОР", "RANDOM PICK")
	randomBtn.Parent = root
	corner(randomBtn, 3)
	stroke(randomBtn, P.goldDim, 1, 0.2)
	randomBtn.Activated:Connect(function()
		self:_selectLeader(Leaders[math.random(1, #Leaders)])
		self:_selectFlag(codes[math.random(1, #codes)])
	end)

	local confirm = Instance.new("TextButton")
	confirm.Name = "Confirm"
	confirm.Position = UDim2.fromOffset(520, 566)
	confirm.Size = UDim2.fromOffset(236, 50)
	confirm.BackgroundColor3 = Color3.fromRGB(70, 56, 32)
	confirm.BorderSizePixel = 0
	confirm.FontFace = SERIF
	confirm.TextSize = 22
	confirm.TextColor3 = P.parchment
	confirm.Text = L("ПРИМЕНИТЬ", "APPLY")
	confirm.Parent = root
	corner(confirm, 3)
	stroke(confirm, P.gold, 2)
	confirm.Activated:Connect(function()
		if self.selected == nil or self.flag == nil then
			return
		end
		self.gui.Enabled = false
		if self.onConfirm then
			self.onConfirm(self.selected.id, self.flag)
		end
	end)
	self.confirm = confirm

	local hint = label(root, "Hint", L("Потом можно нажать на карточку лидера в левом верхнем углу, чтобы сменить.", "Later click the leader card in the top-left corner to change."), 11, P.dim, SMALL)
	hint.Position = UDim2.fromOffset(24, 610)
	hint.Size = UDim2.fromOffset(730, 16)

	self:_selectLeader(Leaders[math.random(1, #Leaders)])
	self:_selectFlag(codes[math.random(1, #codes)])

	return self
end

function LeaderSelect:_selectLeader(leader)
	self.selected = leader
	for _, b in ipairs(self.leaderButtons) do
		local on = b.id == leader.id
		b.stroke.Color = on and P.gold or Color3.fromRGB(58, 72, 88)
		b.stroke.Thickness = on and 2 or 1
		b.frame.BackgroundColor3 = on and Color3.fromRGB(52, 44, 30) or P.panel2
	end
	self.preview.portrait.Image = leader.portrait
	self.preview.name.Text = Locale.pick(leader.name, leader.name_en or leader.name)
	self.preview.title.Text = Locale.pick(leader.title, leader.title_en or leader.title)
end

function LeaderSelect:_selectFlag(code)
	self.flag = code
	for _, b in ipairs(self.flagButtons) do
		local on = b.code == code
		b.stroke.Color = on and P.gold or Color3.fromRGB(58, 72, 88)
		b.stroke.Thickness = on and 2 or 1
		b.frame.BackgroundColor3 = on and Color3.fromRGB(52, 44, 30) or Color3.fromRGB(30, 38, 48)
	end
	FlagAtlas.apply(self.preview.flag, code)
	local nm = FlagAtlas.names[code] or string.upper(code)
	self.preview.flagName.Text = nm
end

function LeaderSelect:open()
	self.gui.Enabled = true
end

function LeaderSelect:close()
	self.gui.Enabled = false
end

function LeaderSelect:isOpen(): boolean
	return self.gui.Enabled
end

function LeaderSelect:getSelection()
	return self.selected and self.selected.id, self.flag
end

return LeaderSelect
