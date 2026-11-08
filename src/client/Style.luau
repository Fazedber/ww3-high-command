-- Upstream Tailwind palette and small GUI helpers, so HUD code can be written
-- class-for-class against OpenFront's markup (bg-gray-800/92, border-slate-500…).

local Style = {}

local function hex(s: string): Color3
	return Color3.fromHex(s)
end

Style.color = {
	gray200 = hex("#ece8ff"),
	gray300 = hex("#cfcdf0"),
	gray400 = hex("#9a9ac8"),
	gray500 = hex("#6c6e9c"),
	gray600 = hex("#34386e"),
	gray700 = hex("#1e2152"),
	gray800 = hex("#0e1030"),
	gray900 = hex("#060718"),
	slate400 = hex("#b4b4de"),
	slate500 = hex("#5a5c8c"),
	green400 = hex("#96c86e"),
	orange300 = hex("#f2c9a0"),
	orange400 = hex("#8a8ff0"),
	yellow300 = hex("#f6dcc0"),
	yellow400 = hex("#f2c9a0"),
	blue300 = hex("#a8acf6"),
	blue400 = hex("#8a8ff0"),
	red500 = hex("#d63028"),
	malibuBlue = hex("#5b60d6"),
	aquarius = hex("#b0b4f8"),
	cyberYellow = hex("#f2c9a0"),
	white = hex("#ece8ff"),
}

-- Tailwind's default sans stack renders as Segoe UI / system-ui; Builder Sans
-- is Roblox's closest match.
local FAMILY = "rbxasset://fonts/families/BuilderSans.json"
Style.font = {
	medium = Font.fromEnum(Enum.Font.Arcade),
	semibold = Font.fromEnum(Enum.Font.Arcade),
	bold = Font.fromEnum(Enum.Font.Arcade),
	extrabold = Font.fromEnum(Enum.Font.Arcade),
}

function Style.corner(parent: Instance, px: number): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, math.min(px, 2)) -- pixel look: near-square corners
	c.Parent = parent
	return c
end

function Style.stroke(parent: Instance, color: Color3, thickness: number?, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

-- Text shadow (drop-shadow-[0_1px_1px_rgba(0,0,0,0.8)]) approximated by a
-- contextual stroke.
function Style.textShadow(label: TextLabel, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Color = Color3.new(0, 0, 0)
	s.Thickness = 1
	s.Transparency = transparency or 0.45
	s.Parent = label
	return s
end

function Style.padding(parent: Instance, x: number, y: number?, top: number?, bottom: number?): UIPadding
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, x)
	p.PaddingRight = UDim.new(0, x)
	p.PaddingTop = UDim.new(0, top or y or x)
	p.PaddingBottom = UDim.new(0, bottom or y or x)
	p.Parent = parent
	return p
end

function Style.row(parent: Instance, gap: number, align: Enum.VerticalAlignment?): UIListLayout
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal
	l.Padding = UDim.new(0, gap)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.VerticalAlignment = align or Enum.VerticalAlignment.Center
	l.Parent = parent
	return l
end

function Style.column(parent: Instance, gap: number): UIListLayout
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Vertical
	l.Padding = UDim.new(0, gap)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = parent
	return l
end

function Style.frame(parent: Instance?, name: string, bg: Color3?, bgAlpha: number?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	if bg then
		f.BackgroundColor3 = bg
		f.BackgroundTransparency = 1 - (bgAlpha or 1)
	else
		f.BackgroundTransparency = 1
	end
	f.Parent = parent
	return f
end

function Style.text(parent: Instance?, name: string, s: string, size: number, font: Font?, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.FontFace = font or Style.font.bold
	l.TextSize = size
	l.TextColor3 = color or Style.color.white
	l.Text = s
	l.AutomaticSize = Enum.AutomaticSize.XY
	l.Size = UDim2.fromOffset(0, 0)
	l.Parent = parent
	return l
end

function Style.button(parent: Instance?, name: string, s: string, size: number, font: Font?, color: Color3?): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.BorderSizePixel = 0
	b.BackgroundTransparency = 1
	b.AutoButtonColor = false
	b.FontFace = font or Style.font.semibold
	b.TextSize = size
	b.TextColor3 = color or Style.color.white
	b.Text = s
	b.AutomaticSize = Enum.AutomaticSize.XY
	b.Size = UDim2.fromOffset(0, 0)
	b.Parent = parent
	return b
end

-- Upstream `.tutorial-highlight`: a gold ring pulsing between 2 and 4 px
-- (1.2 s ease-in-out). Returns a stop function.
function Style.pulseRing(target: GuiObject): () -> ()
	local ring = Instance.new("UIStroke")
	ring.Name = "TutorialHighlight"
	ring.Color = Style.color.cyberYellow
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ring.Parent = target
	local alive = true
	task.spawn(function()
		local t0 = os.clock()
		while alive and ring.Parent do
			local phase = ((os.clock() - t0) % 1.2) / 1.2
			local k = 0.5 - 0.5 * math.cos(phase * 2 * math.pi) -- 0 → 1 → 0
			ring.Thickness = 2 + 2 * k
			ring.Transparency = 0.1 * (1 - k)
			task.wait()
		end
	end)
	return function()
		alive = false
		ring:Destroy()
	end
end

return Style
