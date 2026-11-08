-- Bottom HUD column, ported from upstream index.html + ControlPanel.ts
-- (desktop layout):
--
--   [tutorial panel]                                   (TutorialPanel.luau)
--   ┌ bg-gray-800/92 rounded-lg ───────────────────────────────────┐
--   │ [⚠ notification]                                              │
--   │ [+358/s] [████ 3.05K / 12.1K 🪖] [🪙 1.60K]                   │
--   │ [⚔ 20% (610)] [────●────────────── slider]                    │
--   ├ border-t white/10 ────────────────────────────────────────────┤
--   │ hotbar: 1 🏢 0 │ 2 🏭 0 │ 3 ⚓ 0 │ …                  (BuildMenu) │
--   └───────────────────────────────────────────────────────────────┘
--
-- Attack ratio: slider, T / Y (∓10 %, upstream attackRatioIncrement) and
-- Shift + wheel; 1 % → +10 % lands on 10 %, like upstream.

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Icons = require(script.Parent.Icons)
local Style = require(script.Parent.Style)
local Locale = require(script.Parent:WaitForChild("Locale"))

local C, F = Style.color, Style.font

local WIDTH = 560 -- scaled up, one-row hotbar needs the extra width
local RATIO_INCREMENT = 10 -- UserSettings.attackRatioIncrement default
local LOW_TROOPS_TEXT = nil -- filled from the Roblox locale in ControlPanel.new

local ControlPanel = {}
ControlPanel.__index = ControlPanel

function ControlPanel.new(gui: ScreenGui)
	local self = setmetatable({
		ratio = 0.2, -- UserSettings.attackRatio default
		onRatioChanged = nil :: ((number) -> ())?,
		troops = 0,
		maxTroops = 1,
		attackingTroops = 0,
		gold = 0,
		troopRate = 0,
		rateIncreasing = true,
		visible = false,
		highlights = {}, -- target -> stop()
	}, ControlPanel)
	LOW_TROOPS_TEXT = Locale.pick(
		"У тебя очень мало войск — всегда оставляй часть армии на оборону.",
		"You are very low on troops - You should always keep some troops for defense."
	)

	-- Column pinned bottom-centre; children stack upwards.
	local column = Style.frame(gui, "BottomHud")
	column.AnchorPoint = Vector2.new(0.5, 1)
	column.Position = UDim2.new(0.5, 0, 1, -6)
	column.Size = UDim2.fromOffset(WIDTH, 0)
	column.AutomaticSize = Enum.AutomaticSize.Y
	column.ZIndex = 10
	local colLayout = Style.column(column, 4)
	colLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	self.column = column
	local function fitWidth()
		column.Size = UDim2.fromOffset(math.min(WIDTH, gui.AbsoluteSize.X - 16), 0)
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitWidth)
	fitWidth()

	-- Slot for the tutorial panel (TutorialPanel parents into it).
	local tutorialSlot = Style.frame(column, "TutorialSlot")
	tutorialSlot.LayoutOrder = 1
	tutorialSlot.Size = UDim2.fromScale(1, 0)
	tutorialSlot.AutomaticSize = Enum.AutomaticSize.Y
	self.tutorialSlot = tutorialSlot

	-- pointer-events-auto bg-gray-800/92 backdrop-blur-sm rounded-lg shadow-lg
	local panel = Style.frame(column, "ControlPanel", Color3.fromRGB(10, 12, 32), 0.97)
	panel.LayoutOrder = 2
	panel.Size = UDim2.fromScale(1, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Active = true
	panel.Visible = false
	Style.corner(panel, 2)
	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(38, 42, 92)
	panelStroke.Thickness = 2
	panelStroke.Transparency = 0
	panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	panelStroke.Parent = panel
	Style.column(panel, 0)
	self.panel = panel

	-- control-panel: relative w-full text-sm px-2 py-1
	local body = Style.frame(panel, "Body")
	body.LayoutOrder = 1
	body.Size = UDim2.fromScale(1, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	Style.padding(body, 8, 4)
	Style.column(body, 4) -- mb-1 between rows
	self:_buildNotification(body)
	self:_buildRow1(body)
	self:_buildRow2(body)

	-- unit-display: border-t border-white/10 p-0.5 w-full
	local hotbar = Style.frame(panel, "UnitDisplay")
	hotbar.LayoutOrder = 2
	hotbar.Size = UDim2.fromScale(1, 0)
	hotbar.AutomaticSize = Enum.AutomaticSize.Y
	local rule = Style.frame(hotbar, "BorderTop", C.white, 0.1)
	rule.Size = UDim2.new(1, 0, 0, 1)
	local hotbarInner = Style.frame(hotbar, "Items")
	hotbarInner.Position = UDim2.fromOffset(0, 1)
	hotbarInner.Size = UDim2.fromScale(1, 0)
	hotbarInner.AutomaticSize = Enum.AutomaticSize.Y
	Style.padding(hotbarInner, 2)
	-- The unit buttons are laid out by an adaptive UIGridLayout in BuildMenu,
	-- so they always stay inside the panel (no more icons off the screen edge).
	self.hotbarParent = hotbarInner
	self.hotbarFrame = hotbar

	self:_bindKeys()
	self:setRatio(self.ratio)
	return self
end

-- Rows -------------------------------------------------------------------------------

function ControlPanel:_buildNotification(body: Frame)
	-- flex items-center gap-1.5 px-1.5 py-1 rounded-md border text-xs font-medium
	-- border-orange-400/60 bg-orange-400/10 text-orange-300
	local n = Style.frame(body, "Notification", C.orange400, 0.1)
	n.LayoutOrder = 0
	n.Size = UDim2.fromScale(1, 0)
	n.AutomaticSize = Enum.AutomaticSize.Y
	n.Visible = false
	Style.corner(n, 6)
	Style.stroke(n, C.orange400, 1, 0.4)
	Style.padding(n, 6, 4)
	Style.row(n, 6)
	local icon = Style.text(n, "Icon", "⚠", 12, F.medium, C.orange300)
	icon.LayoutOrder = 1
	local t = Style.text(n, "Text", LOW_TROOPS_TEXT, 12, F.medium, C.orange300)
	t.LayoutOrder = 2
	t.AutomaticSize = Enum.AutomaticSize.Y
	t.Size = UDim2.new(1, -20, 0, 0)
	t.TextWrapped = true
	t.TextXAlignment = Enum.TextXAlignment.Left
	self.notification = n
end

function ControlPanel:_buildRow1(body: Frame)
	local row = Style.frame(body, "Row1")
	row.LayoutOrder = 1
	row.Size = UDim2.new(1, 0, 0, 24)
	Style.row(row, 6)

	-- Troop rate: w-[5.5rem] border rounded-md font-bold text-sm py-0.5 px-1
	local rate = Style.frame(row, "TroopRate")
	rate.LayoutOrder = 1
	rate.Size = UDim2.fromOffset(112, 24)
	Style.corner(rate, 6)
	local rateStroke = Style.stroke(rate, C.green400)
	Style.padding(rate, 4, 2)
	Style.row(rate, 4)
	local rateIcon = Icons.label(rate, "soldier", 20, { white = true })
	rateIcon.LayoutOrder = 1
	local rateText = Style.text(rate, "Text", "+0/s", 13, F.bold, C.green400)
	rateText.LayoutOrder = 2
	self.rateBox, self.rateStroke, self.rateIcon, self.rateText = rate, rateStroke, rateIcon, rateText

	-- Troop count: plain label (the old cap bar is gone — the army just grows).
	local troopsLabel = Style.text(row, "TroopsLabel", "0", 17, F.bold)
	troopsLabel.LayoutOrder = 2
	troopsLabel.AutomaticSize = Enum.AutomaticSize.XY
	self.troopsLabel = troopsLabel

	-- Troop bar: flex-1, h-6 border border-gray-600 rounded-md bg-gray-900/60
	local bar = Style.frame(row, "TroopBar", C.gray900, 0.6)
	bar.LayoutOrder = 2
	bar.Size = UDim2.fromOffset(0, 24)
	bar.ClipsDescendants = true
	Style.corner(bar, 6)
	Style.stroke(bar, C.gray600)
	local grow = Instance.new("UIFlexItem")
	grow.FlexMode = Enum.UIFlexMode.Fill
	grow.Parent = bar
	local green = Style.frame(bar, "Troops", C.malibuBlue, 1) -- bg-malibu-blue
	green.Size = UDim2.fromScale(0, 1)
	local orange = Style.frame(bar, "Attacking", C.aquarius, 1) -- bg-aquarius
	orange.Size = UDim2.fromScale(0, 1)
	self.barGreen, self.barOrange = green, orange

	-- absolute inset-0 flex items-center text-lg font-bold
	local overlay = Style.frame(bar, "Text")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = 2
	Style.row(overlay, 0)
	local left = Style.frame(overlay, "Left")
	left.LayoutOrder = 1
	left.Size = UDim2.fromScale(0, 1)
	local lf = Instance.new("UIFlexItem")
	lf.FlexMode = Enum.UIFlexMode.Fill
	lf.Parent = left
	local troopsText = Style.text(left, "Troops", "0", 18, F.bold)
	troopsText.AnchorPoint = Vector2.new(1, 0.5)
	troopsText.Position = UDim2.new(1, -2, 0.5, 0) -- pr-0.5
	troopsText.ZIndex = 3
	Style.textShadow(troopsText)
	local slash = Style.text(overlay, "Slash", "/", 18, F.bold)
	slash.LayoutOrder = 2
	slash.ZIndex = 3
	Style.padding(slash, 2, 0) -- px-0.5
	Style.textShadow(slash)
	local right = Style.frame(overlay, "Right")
	right.LayoutOrder = 3
	right.Size = UDim2.fromScale(0, 1)
	local rf = Instance.new("UIFlexItem")
	rf.FlexMode = Enum.UIFlexMode.Fill
	rf.Parent = right
	Style.padding(right, 2, 0).PaddingRight = UDim.new(0, 0)
	Style.row(right, 8) -- gap-0.5 + ml-1.5 before the icon
	local maxText = Style.text(right, "Max", "0", 18, F.bold)
	maxText.LayoutOrder = 1
	maxText.AutomaticSize = Enum.AutomaticSize.None
	maxText.Size = UDim2.fromOffset(56, 24) -- w-[3.5rem]
	maxText.TextXAlignment = Enum.TextXAlignment.Left
	maxText.ZIndex = 3
	Style.textShadow(maxText)
	local soldier = Icons.label(right, "soldier", 34, { white = true })
	soldier.LayoutOrder = 2
	soldier.ZIndex = 3
	self.troopsText, self.maxText = troopsText, maxText
	-- No artificial cap strip: the army simply grows; hide the "/ max" part
	-- and the progress fill so the panel reads "troops + soldier + rate".
	slash.Visible = false
	maxText.Visible = false
	green.Visible = false
	orange.Visible = false
	bar.Visible = false -- no cap strip at all
	-- Keep the troop count readable: anchor it to the right side of the bar.
	troopsText.AnchorPoint = Vector2.new(1, 0.5)
	troopsText.Position = UDim2.new(1, -6, 0.5, 0)
	troopsText.Size = UDim2.fromOffset(160, 24)
	troopsText.TextXAlignment = Enum.TextXAlignment.Right

	-- Gold: border rounded-md border-yellow-400 font-bold text-yellow-400 text-sm py-0.5 px-1 min-w-[4.5rem]
	-- (relative: the gain pip sits outside the content flow)
	local gold = Style.frame(row, "Gold")
	gold.LayoutOrder = 3
	gold.Size = UDim2.fromOffset(0, 24)
	gold.AutomaticSize = Enum.AutomaticSize.X
	Style.corner(gold, 6)
	Style.stroke(gold, C.yellow400)
	local content = Style.frame(gold, "Content")
	content.Size = UDim2.fromOffset(72, 24) -- min-w-[4.5rem]
	content.AutomaticSize = Enum.AutomaticSize.X
	Style.padding(content, 4, 2)
	Style.row(content, 4)
	local coin = Icons.label(content, "goldCoin", 22, { white = true })
	coin.LayoutOrder = 1
	local goldText = Style.text(content, "Text", "0", 14, F.bold, C.yellow400)
	goldText.LayoutOrder = 2
	self.goldBox, self.goldText = gold, goldText

	-- gold-gain-pop: absolute -top-5 right-[5px] text-green-400 text-sm font-extrabold
	local pop = Style.text(gold, "GoldGain", "", 14, F.extrabold, C.green400)
	pop.AnchorPoint = Vector2.new(1, 1)
	pop.Position = UDim2.new(1, -5, 0, 0)
	pop.Visible = false
	pop.ZIndex = 5
	Style.textShadow(pop, 0.1)
	self.goldPop = pop
end

function ControlPanel:_buildRow2(body: Frame)
	local row = Style.frame(body, "Row2")
	row.LayoutOrder = 2
	row.Size = UDim2.new(1, 0, 0, 24)
	Style.row(row, 6)

	-- border border-gray-600 rounded-md px-1 py-0.5 text-sm font-bold text-white w-[8rem]
	local box = Style.frame(row, "AttackRatio")
	box.LayoutOrder = 1
	box.Size = UDim2.fromOffset(128, 24)
	Style.corner(box, 6)
	Style.stroke(box, C.gray600)
	Style.padding(box, 4, 2)
	Style.row(box, 4)
	local sword = Icons.label(box, "sword", 20, { white = true })
	sword.LayoutOrder = 1
	local ratioText = Style.text(box, "Text", "20% (0)", 14, F.bold)
	ratioText.LayoutOrder = 2
	self.ratioBox, self.ratioText = box, ratioText

	-- input[type=range] min=1 max=100, flex-1 h-1.5 accent-aquarius
	local hit = Style.frame(row, "Slider")
	hit.LayoutOrder = 2
	hit.Size = UDim2.fromOffset(0, 24)
	hit.Active = true
	local grow = Instance.new("UIFlexItem")
	grow.FlexMode = Enum.UIFlexMode.Fill
	grow.Parent = hit
	local track = Style.frame(hit, "Track", Color3.fromRGB(239, 239, 239), 1)
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 0, 0.5, 0)
	track.Size = UDim2.new(1, 0, 0, 6)
	Style.corner(track, 3)
	local fill = Style.frame(track, "Fill", C.aquarius, 1)
	fill.Size = UDim2.fromScale(0.2, 1)
	Style.corner(fill, 3)
	local thumb = Style.frame(track, "Thumb", C.aquarius, 1)
	thumb.AnchorPoint = Vector2.new(0.5, 0.5)
	thumb.Size = UDim2.fromOffset(16, 16)
	Style.corner(thumb, 8)
	self.sliderHit, self.sliderTrack, self.sliderFill, self.sliderThumb = hit, track, fill, thumb

	local dragging = false
	local function setFromX(x: number)
		local rel = (x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X)
		local pct = math.clamp(math.floor(rel * 99 + 1 + 0.5), 1, 100) -- min=1 max=100
		self:_changeRatio(pct / 100)
	end
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

-- Attack ratio ---------------------------------------------------------------------------

function ControlPanel:setRatio(ratio: number)
	self.ratio = ratio
	local pct = math.floor(ratio * 100 + 0.5)
	local rel = (pct - 1) / 99
	self.sliderFill.Size = UDim2.fromScale(rel, 1)
	self.sliderThumb.Position = UDim2.fromScale(rel, 0.5)
	self:_refreshRatioText()
end

function ControlPanel:_changeRatio(ratio: number)
	if ratio == self.ratio then
		return
	end
	self:setRatio(ratio)
	if self.onRatioChanged then
		self.onRatioChanged(ratio)
	end
end

-- Upstream AttackRatioEvent handling (delta in percent).
function ControlPanel:stepRatio(deltaPct: number)
	local r = self.ratio + deltaPct / 100
	r = math.clamp(r, 0.01, 1)
	-- Float noise aside, upstream snaps 1 % + 10 % to 10 %.
	r = math.floor(r * 100 + 0.5) / 100
	if r == 0.11 and self.ratio == 0.01 then
		r = 0.1
	end
	self:_changeRatio(r)
end

function ControlPanel:_refreshRatioText()
	self.ratioText.Text = `{math.floor(self.ratio * 100 + 0.5)}% ({Format.renderTroops(self.troops * self.ratio)})`
end

function ControlPanel:_bindKeys()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if input.KeyCode == Enum.KeyCode.T then -- attackRatioDown
			self:stepRatio(-RATIO_INCREMENT)
		elseif input.KeyCode == Enum.KeyCode.Y then -- attackRatioUp
			self:stepRatio(RATIO_INCREMENT)
		end
	end)
end

-- Shift + wheel (MapCamera.onShiftScroll): wheel up raises the ratio.
function ControlPanel:shiftScroll(z: number)
	self:stepRatio(if z > 0 then RATIO_INCREMENT else -RATIO_INCREMENT)
end

-- State ------------------------------------------------------------------------------------

function ControlPanel:setVisible(visible: boolean)
	self.visible = visible
	self.panel.Visible = visible
end

-- From Stats: our troops and gold.
function ControlPanel:setStats(troops: number, gold: number)
	self.troops, self.gold = troops, gold
	self:_refresh()
end

-- From Net.Me: max troops, growth per second, troops in outgoing attacks.
function ControlPanel:setInfo(info)
	local rate = info.troopRate or 0
	self.rateIncreasing = rate >= self.troopRate -- updateTroopIncrease
	self.troopRate = rate
	self.maxTroops = info.maxTroops or self.maxTroops
	self.attackingTroops = info.attackingTroops or 0
	self:_refresh()
end

function ControlPanel:_refresh()
	-- calculateTroopBar
	local base = math.max(self.maxTroops, 1)
	local greenPct = math.clamp(self.troops / base * 100, 0, 100)
	local orangePct = math.clamp(self.attackingTroops / base * 100, 0, 100 - greenPct)
	self.barGreen.Size = UDim2.fromScale(greenPct / 100, 1)
	self.barOrange.Position = UDim2.fromScale(greenPct / 100, 0)
	self.barOrange.Size = UDim2.fromScale(orangePct / 100, 1)
	self.troopsText.Text = Format.renderTroops(self.troops)
	self.maxText.Text = Format.renderTroops(self.maxTroops)
	if self.troopsLabel then
		self.troopsLabel.Text = Format.renderTroops(self.troops)
	end

	local rateColor = if self.rateIncreasing then C.green400 else C.orange400
	self.rateStroke.Color = rateColor
	-- soldier glyph keeps its green tint; the growth-rate text/stroke carry the colour
	self.rateText.TextColor3 = rateColor
	self.rateText.Text = `+{Format.renderTroops(self.troopRate)}/s`

	self.goldText.Text = Format.renderNumber(self.gold)
	self:_refreshRatioText()

	-- computeNotification: low troops (< 1k shown) warning.
	self.notification.Visible = self.troops < 10000 and self.troops > 0
end

-- Last-wins gold pip, 0.25 s pop-in, gone after 2 s (addGoldGain).
function ControlPanel:goldGain(amount: number)
	local pop = self.goldPop
	pop.Text = `+{Format.renderNumber(amount)}`
	pop.Visible = true
	pop.TextTransparency = 1
	pop.Position = UDim2.new(1, -5, 0, 4)
	TweenService:Create(pop, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 0,
		Position = UDim2.new(1, -5, 0, 0),
	}):Play()
	self.goldPopId = (self.goldPopId or 0) + 1
	local id = self.goldPopId
	task.delay(2, function()
		if self.goldPopId == id then
			pop.Visible = false
		end
	end)
end

-- Tutorial highlights on the control panel: "troops", "troop_rate",
-- "attack_ratio", "gold" (ring only, like upstream).
function ControlPanel:setHighlight(target: string?)
	local frames = {
		troops = self.barGreen.Parent,
		troop_rate = self.rateBox,
		attack_ratio = self.ratioBox.Parent,
		gold = self.goldBox,
	}
	for key, stop in self.highlights do
		if key ~= target then
			stop()
			self.highlights[key] = nil
		end
	end
	local f = target and frames[target]
	if f and not self.highlights[target] then
		self.highlights[target] = Style.pulseRing(f)
	end
end

return ControlPanel
