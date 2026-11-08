-- Port of upstream hud/layers/EmojiTable.ts: a 5-column grid of the emoji
-- table (flattenedEmojiTable order) in a zinc card; picking one calls back
-- with its 0-based index.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Emojis = require(Shared:WaitForChild("Data"):WaitForChild("Emojis"))
local Style = require(script.Parent.Style)
local Modal = require(script.Parent.Modal)

local EmojiTable = {}
EmojiTable.__index = EmojiTable

function EmojiTable.new(gui: Instance)
	return setmetatable({ gui = gui, close = nil }, EmojiTable)
end

function EmojiTable:showTable(onSelect: (number) -> ())
	self:hideTable()
	local _, card, close = Modal.open(self.gui, "EmojiTable", 400, 120)
	self.close = close
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Grid"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.new(1, 0, 0, math.min(420, self.gui.AbsoluteSize.Y - 120))
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 4
	scroll.ZIndex = card.ZIndex + 1
	scroll.Parent = card
	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(8, 8)
	grid.CellSize = UDim2.new(0.2, -8, 0, 64)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll
	for i, emoji in Emojis.flat do
		local b = Style.button(scroll, `Emoji{i}`, emoji, 36)
		b.AutomaticSize = Enum.AutomaticSize.None
		b.LayoutOrder = i
		b.BackgroundColor3 = Modal.zinc.z800
		b.BackgroundTransparency = 0
		b.ZIndex = scroll.ZIndex + 1
		Style.corner(b, 8)
		b.MouseEnter:Connect(function()
			b.BackgroundColor3 = Modal.zinc.z700
		end)
		b.MouseLeave:Connect(function()
			b.BackgroundColor3 = Modal.zinc.z800
		end)
		b.Activated:Connect(function()
			onSelect(i - 1)
		end)
	end
end

function EmojiTable:hideTable()
	if self.close then
		self.close()
		self.close = nil
	end
end

return EmojiTable
