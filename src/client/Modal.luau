-- Shared pieces of upstream's zinc modals (PlayerPanel, EmojiTable,
-- SendResourceModal, ChatModal): the dimmed click-to-close backdrop
-- (fixed inset-0 bg-black/15), the bg-zinc-900/95 rounded card with its
-- round close button, dividers and the ActionButton variants.

local Style = require(script.Parent.Style)
local Icons = require(script.Parent.Icons)

local F = Style.font

local Modal = {}

Modal.zinc = {
	z50 = Color3.fromHex("#fafafa"),
	z100 = Color3.fromHex("#f4f4f5"),
	z200 = Color3.fromHex("#e4e4e7"),
	z300 = Color3.fromHex("#d4d4d8"),
	z400 = Color3.fromHex("#a1a1aa"),
	z600 = Color3.fromHex("#52525b"),
	z700 = Color3.fromHex("#3f3f46"),
	z800 = Color3.fromHex("#27272a"),
	z900 = Color3.fromHex("#18181b"),
}
local Z = Modal.zinc

-- ActionButton text colours (components/ui/ActionButton.ts).
Modal.variant = {
	normal = Color3.new(1, 1, 1),
	red = Color3.fromHex("#f87171"),
	green = Color3.fromHex("#34d399"),
	yellow = Color3.fromHex("#f59e0b"),
	indigo = Color3.fromHex("#818cf8"),
	sky = Color3.fromHex("#38bdf8"),
}

-- Backdrop + centred card. Returns backdrop, card (a vertical list with
-- padding), and a close() that destroys it. z: base ZIndex.
function Modal.open(gui: Instance, name: string, width: number, z: number, onClose: (() -> ())?)
	local backdrop = Instance.new("TextButton")
	backdrop.Name = name
	backdrop.Text = ""
	backdrop.AutoButtonColor = false
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.85
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.ZIndex = z
	backdrop.Parent = gui

	local card = Instance.new("TextButton") -- swallows clicks inside the card
	card.Name = "Card"
	card.Text = ""
	card.AutoButtonColor = false
	card.BackgroundColor3 = Z.z900
	card.BackgroundTransparency = 0.05
	card.BorderSizePixel = 0
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(width, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.ZIndex = z + 1
	card.Parent = backdrop
	Style.corner(card, 16)
	Style.stroke(card, Color3.new(1, 1, 1), 1, 0.95)
	Style.padding(card, 20, 18)
	Style.column(card, 8)

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		backdrop:Destroy()
		if onClose then
			onClose()
		end
	end
	backdrop.Activated:Connect(close)

	local x = Style.button(backdrop, "Close", "×", 20, F.bold)
	x.AutomaticSize = Enum.AutomaticSize.None
	x.Size = UDim2.fromOffset(28, 28)
	x.BackgroundColor3 = Z.z700
	x.BackgroundTransparency = 0
	x.ZIndex = z + 5
	Style.corner(x, 14)
	x.Activated:Connect(close)
	-- Keep the close button on the card's top-right corner.
	local function place()
		local p, s = card.AbsolutePosition - backdrop.AbsolutePosition, card.AbsoluteSize
		x.Position = UDim2.fromOffset(p.X + s.X - 38, p.Y + 10)
	end
	card:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	card:GetPropertyChangedSignal("AbsolutePosition"):Connect(place)
	task.defer(place)
	return backdrop, card, close
end

function Modal.divider(parent: Instance, order: number)
	local d = Style.frame(parent, "Divider", Color3.new(1, 1, 1), 0.1)
	d.LayoutOrder = order
	d.Size = UDim2.new(1, 0, 0, 1)
	d.ZIndex = parent.ZIndex + 1
	return d
end

-- Horizontal row of equal-width children (grid auto-cols-fr grid-flow-col).
function Modal.buttonRow(parent: Instance, order: number, count: number)
	local row = Style.frame(parent, "Row")
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, 58)
	row.ZIndex = parent.ZIndex + 1
	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(4, 0)
	-- One spare pixel per cell so rounding never wraps the last button.
	grid.CellSize = UDim2.new(1 / math.max(1, count), -4 * (count - 1) / math.max(1, count) - 1, 1, 0)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = row
	return row
end

-- ActionButton: icon over a label, bg-white/4, border-white/10, rounded-lg.
function Modal.actionButton(parent: Instance, order: number, icon: string, label: string, variant: string?, disabled: boolean?, onClick: () -> ())
	local color = Modal.variant[variant or "normal"]
	local b = Instance.new("TextButton")
	b.Name = label
	b.Text = ""
	b.AutoButtonColor = false
	b.BackgroundColor3 = Color3.new(1, 1, 1)
	b.BackgroundTransparency = 0.96
	b.BorderSizePixel = 0
	b.LayoutOrder = order
	b.ZIndex = parent.ZIndex + 1
	b.Parent = parent
	Style.corner(b, 8)
	Style.stroke(b, Color3.new(1, 1, 1), 1, 0.9)
	local ic = Icons.label(b, icon, 20, { color = Z.z400 })
	ic.AnchorPoint = Vector2.new(0.5, 0)
	ic.Position = UDim2.new(0.5, 0, 0, 7)
	ic.ZIndex = b.ZIndex + 1
	local t = Style.text(b, "Label", label, 14, F.semibold, color)
	t.AutomaticSize = Enum.AutomaticSize.None
	t.AnchorPoint = Vector2.new(0.5, 1)
	t.Position = UDim2.new(0.5, 0, 1, -6)
	t.Size = UDim2.new(1, -4, 0, 18)
	t.TextTruncate = Enum.TextTruncate.AtEnd
	t.ZIndex = b.ZIndex + 1
	if disabled then
		b.BackgroundTransparency = 0.98
		t.TextTransparency = 0.5
		ic.ImageTransparency = 0.5
	else
		b.MouseEnter:Connect(function()
			b.BackgroundTransparency = 0.9
		end)
		b.MouseLeave:Connect(function()
			b.BackgroundTransparency = 0.96
		end)
		b.Activated:Connect(onClick)
	end
	return b
end

-- renderDuration (client/Utils.ts): "1h 2min 5s" with trailing zeros dropped.
function Modal.duration(totalSeconds: number): string
	local whole = math.floor(totalSeconds)
	if whole <= 0 then
		return "0s"
	end
	local h, m, s = whole // 3600, (whole % 3600) // 60, whole % 60
	local parts = {}
	if h > 0 then
		table.insert(parts, `{h}h`)
	end
	if m > 0 then
		table.insert(parts, `{m}min`)
	end
	if s > 0 or #parts == 0 then
		table.insert(parts, `{s}s`)
	end
	return table.concat(parts, " ")
end

-- PlayerPanel.getExpiryColorClass.
function Modal.expiryColor(seconds: number?): Color3
	if seconds == nil then
		return Color3.new(1, 1, 1)
	elseif seconds <= 30 then
		return Color3.fromHex("#f87171")
	elseif seconds <= 60 then
		return Color3.fromHex("#facc15")
	end
	return Color3.fromHex("#34d399")
end

return Modal
