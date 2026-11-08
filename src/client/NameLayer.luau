-- Player names + troop counts drawn over territories, like OpenFront's
-- NamePass. Placement (x, y, size in map tiles) comes from the server's
-- NameBoxCalculator; on screen the name is size * zoom pixels tall and the
-- troop line below it troopSizeMultiplier (0.6) of that.
-- Status icons (StatusIconProgram / PlayerIcons.ts) sit in a centred row
-- statusRowOffset (1.4) name heights above the name, each 1.1 name heights
-- tall with 0.15 gaps, the emoji last; targeted players keep their icons at
-- any zoom.

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Icons = require(script.Parent.Icons)
local FlagAtlas = require(script.Parent.FlagAtlas)

local MIN_TEXT = 7 -- px; smaller names are hidden (upstream culls tiny names too)
local MAX_TEXT = 100 -- Roblox TextSize cap
local TROOP_SIZE_MULTIPLIER = 0.6 -- render-settings.json name.troopSizeMultiplier
local BOT_SHADE = 0.4 -- render-settings.json name.nameShadeBot
local STATUS_ROW_OFFSET = 1.4 -- render-settings.json name.statusRowOffset
local ICON_SCALE = 1.1
local MIN_ICON = 12 -- px, targeted players' icons never shrink below this

local NameLayer = {}
NameLayer.__index = NameLayer

function NameLayer.new(parent: GuiObject, camera)
	local container = Instance.new("Frame")
	container.Name = "Names"
	container.BackgroundTransparency = 1
	container.Size = UDim2.fromScale(1, 1)
	container.ZIndex = 5
	container.Parent = parent
	return setmetatable({ container = container, camera = camera, entries = {} }, NameLayer)
end

local function makeText(parent: Instance, name: string): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.AutomaticSize = Enum.AutomaticSize.XY
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.ZIndex = 5
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Parent = l
	l.Parent = parent
	return l
end

-- color: territory { r, g, b } 0-255, used for the text outline.
function NameLayer:setPlayer(smallID: number, displayName: string, color: { number }, isBot: boolean)
	local e = self.entries[smallID]
	if e == nil then
		e = {
			name = makeText(self.container, `Name{smallID}`),
			troops = makeText(self.container, `Troops{smallID}`),
			x = 0,
			y = 0,
			size = 0,
			alive = false,
			icons = {}, -- { { icon, color } }
			emoji = nil,
			targeted = false,
			iconFrames = {},
		}
		self.entries[smallID] = e
	end
	local outline = Color3.fromRGB(color[1], color[2], color[3])
	local shade = if isBot then BOT_SHADE else 0
	local fill = Color3.new(shade, shade, shade)
	for _, l in { e.name, e.troops } do
		l.TextColor3 = fill
		l:FindFirstChildOfClass("UIStroke").Color = outline
	end
	e.name.Text = displayName
	if e.nameColor then
		e.name.TextColor3 = Color3.fromRGB(e.nameColor[1], e.nameColor[2], e.nameColor[3])
	end
	self:_place(e)
end

-- Cosmetic flag left of the name (Flag Pass); nil removes it.
function NameLayer:setFlag(smallID: number, code: string?)
	local e = self.entries[smallID]
	if e == nil then
		return
	end
	if code and e.flag == nil then
		local f = Instance.new("ImageLabel")
		f.Name = "Flag"
		f.BackgroundTransparency = 1
		f.AnchorPoint = Vector2.new(1, 0.5)
		f.ZIndex = 5
		f.Parent = self.container
		e.flag = f
	end
	if e.flag then
		FlagAtlas.apply(e.flag, code)
		e.flagCode = code
		self:_place(e)
	end
end

-- Cosmetic name colour (shop / supporter); nil restores the default.
function NameLayer:setNameColor(smallID: number, rgb: { number }?)
	local e = self.entries[smallID]
	if e then
		e.nameColor = rgb
		if rgb then
			e.name.TextColor3 = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		else
			e.name.TextColor3 = e.troops.TextColor3
		end
	end
end

function NameLayer:setPlacement(smallID: number, x: number, y: number, size: number)
	local e = self.entries[smallID]
	if e then
		e.x, e.y, e.size = x, y, size
		self:_place(e)
	end
end

-- Upstream nameLocation(): map x, y and font size; nil until placed.
function NameLayer:placement(smallID: number): (number?, number?, number?)
	local e = self.entries[smallID]
	if e == nil or (e.x == 0 and e.y == 0 and e.size == 0) then
		return nil, nil, nil
	end
	return e.x, e.y, e.size
end

function NameLayer:setTroops(smallID: number, troops: number, alive: boolean)
	local e = self.entries[smallID]
	if e then
		local text = Format.renderTroops(troops)
		if e.troops.Text ~= text then -- setting Text re-lays out the label
			e.troops.Text = text
		end
		if e.alive ~= alive then
			e.alive = alive
			self:_place(e)
		end
	end
end

function NameLayer:_place(e)
	local px = e.size * self.camera.zoom
	local visible = e.alive and px >= MIN_TEXT
	e.name.Visible = visible
	if e.flag then
		e.flag.Visible = visible and e.flagCode ~= nil
	end
	e.troops.Visible = visible and px * TROOP_SIZE_MULTIPLIER >= MIN_TEXT * 0.8
	local p = self.camera:screenPos(e.x, e.y)
	if e.iconFrames then
		self:_placeIcons(e, px, p)
	end
	if not visible then
		return
	end
	local nameSize = math.min(MAX_TEXT, px)
	e.name.TextSize = nameSize
	e.name.Position = UDim2.fromOffset(p.X, p.Y)
	e.troops.TextSize = math.min(MAX_TEXT, px * TROOP_SIZE_MULTIPLIER)
	e.troops.Position = UDim2.fromOffset(p.X, p.Y + nameSize * 0.9)
	if e.flag and e.flagCode then
		-- The name is centred; its width comes from the last layout.
		local h = nameSize * 0.75
		e.flag.Size = UDim2.fromOffset(h * 1.5, h)
		e.flag.Position = UDim2.fromOffset(p.X - e.name.AbsoluteSize.X / 2 - h * 0.25, p.Y)
	end
end

-- icons: list of { icon = Icons name, color = Color3? } in status-row order;
-- emoji: text or nil; targeted: keep visible at any zoom.
function NameLayer:setIcons(smallID: number, icons, emoji: string?, targeted: boolean)
	local e = self.entries[smallID]
	if e == nil then
		return
	end
	local key = emoji or ""
	for _, ic in icons do
		key ..= "|" .. ic.icon
	end
	if key == e.iconKey and targeted == e.targeted then
		return
	end
	e.iconKey = key
	e.targeted = targeted
	for _, f in e.iconFrames do
		f:Destroy()
	end
	e.iconFrames = {}
	for _, ic in icons do
		local l = Icons.label(self.container, ic.icon, 32, if ic.color then { color = ic.color } else nil)
		l.AnchorPoint = Vector2.new(0, 0.5)
		l.ZIndex = 6
		table.insert(e.iconFrames, l)
	end
	if emoji then
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Text = emoji
		t.TextScaled = true
		t.AnchorPoint = Vector2.new(0, 0.5)
		t.ZIndex = 6
		t.Parent = self.container
		table.insert(e.iconFrames, t)
	end
	self:_place(e)
end

function NameLayer:_placeIcons(e, px: number, p: Vector2)
	local n = #e.iconFrames
	if n == 0 then
		return
	end
	local visible = e.alive and (px >= MIN_TEXT or e.targeted)
	local size = math.max(if e.targeted then MIN_ICON else 0, math.min(MAX_TEXT, px) * ICON_SCALE)
	local gap = size * 0.15
	local total = n * size + (n - 1) * gap
	local y = p.Y - math.max(px, if e.targeted then MIN_ICON else 0) * STATUS_ROW_OFFSET
	for i, f in e.iconFrames do
		f.Visible = visible
		f.Size = UDim2.fromOffset(size, size)
		f.Position = UDim2.fromOffset(p.X - total / 2 + (i - 1) * (size + gap), y)
	end
end

-- Re-layout everything (camera moved / zoomed).
function NameLayer:refresh()
	for _, e in self.entries do
		self:_place(e)
	end
end

return NameLayer
