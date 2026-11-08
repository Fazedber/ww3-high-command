-- Port of upstream hud/layers/SendResourceModal.ts: send troops or gold to
-- another player. Presets (10/25/50/75/100 %), a slider, a "Send · Keep"
-- summary and Cancel / Send. Troops are capped by the receiver's free
-- capacity (maxTroops - troops); the keep amount turns amber below 30 %.

local UserInputService = game:GetService("UserInputService")
local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Style = require(script.Parent.Style)
local Modal = require(script.Parent.Modal)
local Lang = require(script.Parent.Lang)

local F = Style.font
local Z = Modal.zinc

local PRESETS = { 10, 25, 50, 75, 100 }

local SendResourceModal = {}

-- opts = { gui, mode = "troops" | "gold", total, capacity?, targetName,
--          targetAlive, onSend(amount) }
function SendResourceModal.open(opts)
	local troops = opts.mode == "troops"
	local fmt = if troops then Format.renderTroops else Format.renderNumber
	local fill = if troops then Color3.fromRGB(168, 85, 247) else Color3.fromRGB(234, 179, 8)
	local total = math.max(0, opts.total or 0)
	local hardMax = if opts.capacity then math.min(total, math.max(0, opts.capacity)) else total
	if not opts.targetAlive then
		hardMax = 0
	end
	local amount = math.floor(hardMax * 0.5)

	local _, card, close = Modal.open(opts.gui, "SendResource", 380, 130)
	local title = Style.text(card, "Title", (if troops then "Send Troops to " else "Send Gold to ") .. opts.targetName, 18, F.bold, Z.z50)
	title.LayoutOrder = 1
	title.ZIndex = card.ZIndex + 1
	local avail = Style.text(card, "Available", `{if troops then "🛡️" else "💰"} {fmt(total)}`, 14, F.semibold, Z.z300)
	avail.LayoutOrder = 2
	avail.ZIndex = card.ZIndex + 1

	if not opts.targetAlive then
		local note = Style.text(card, "Dead", "Target is dead — nothing can be sent.", 14, F.medium, Color3.fromHex("#fde68a"))
		note.LayoutOrder = 3
		note.ZIndex = card.ZIndex + 1
	end

	local presets = Style.frame(card, "Presets")
	presets.LayoutOrder = 4
	presets.Size = UDim2.new(1, 0, 0, 32)
	presets.ZIndex = card.ZIndex + 1
	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(6, 0)
	grid.CellSize = UDim2.new(0.2, -5, 1, 0)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = presets
	local presetButtons = {}

	local track = Style.frame(card, "Track", Color3.new(1, 1, 1), 0.22)
	track.LayoutOrder = 5
	track.Size = UDim2.new(1, 0, 0, 8)
	track.Active = true
	track.ZIndex = card.ZIndex + 1
	Style.corner(track, 4)
	local bar = Style.frame(track, "Fill", fill, 1)
	bar.ZIndex = track.ZIndex + 1
	Style.corner(bar, 4)
	local knob = Style.frame(track, "Knob", fill, 1)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.fromOffset(18, 18)
	knob.ZIndex = track.ZIndex + 2
	Style.corner(knob, 9)
	Style.stroke(knob, Z.z900, 3)
	local pctLabel = Style.text(card, "Percent", "", 13, F.semibold, Z.z200)
	pctLabel.LayoutOrder = 6
	pctLabel.ZIndex = card.ZIndex + 1

	local capNote = Style.text(card, "Cap", "", 12, F.medium, Color3.fromHex("#fcd34d"))
	capNote.LayoutOrder = 7
	capNote.ZIndex = card.ZIndex + 1
	capNote.Visible = false

	local summary = Instance.new("TextLabel")
	summary.Name = "Summary"
	summary.BackgroundTransparency = 1
	summary.RichText = true
	summary.FontFace = F.medium
	summary.TextSize = 14
	summary.TextColor3 = Z.z200
	summary.AutomaticSize = Enum.AutomaticSize.Y
	summary.Size = UDim2.new(1, 0, 0, 0)
	summary.LayoutOrder = 8
	summary.ZIndex = card.ZIndex + 1
	summary.Parent = card

	local actions = Style.frame(card, "Actions")
	actions.LayoutOrder = 9
	actions.Size = UDim2.new(1, 0, 0, 40)
	actions.ZIndex = card.ZIndex + 1
	local al = Style.row(actions, 8)
	al.HorizontalAlignment = Enum.HorizontalAlignment.Right
	local function actionButton(name: string, text: string, bg: Color3, order: number)
		local b = Style.button(actions, name, text, 14, F.semibold)
		b.AutomaticSize = Enum.AutomaticSize.None
		b.Size = UDim2.fromOffset(96, 40)
		b.BackgroundColor3 = bg
		b.BackgroundTransparency = 0
		b.LayoutOrder = order
		b.ZIndex = actions.ZIndex + 1
		Style.corner(b, 8)
		return b
	end
	local cancel = actionButton("Cancel", "Cancel", Z.z800, 1)
	Style.stroke(cancel, Z.z700, 1)
	local send = actionButton("Send", "Send", Color3.fromHex("#4f46e5"), 2)

	local function percentOf(n: number): number
		return if total > 0 then math.floor(n / total * 100 + 0.5) else 0
	end
	local function paint()
		amount = math.clamp(amount, 0, hardMax)
		local pct = percentOf(amount)
		bar.Size = UDim2.fromScale(pct / 100, 1)
		knob.Position = UDim2.fromScale(pct / 100, 0.5)
		pctLabel.Text = `{pct}% • {fmt(amount)}`
		for p, b in presetButtons do
			local active = pct == p
			b.BackgroundColor3 = if active then Color3.fromHex("#4f46e5") else Z.z800
		end
		local keep = math.max(0, total - amount)
		local belowMinKeep = troops and keep < math.floor(total * 0.3)
		summary.Text = `Send <font color="#818cf8"><b>{fmt(amount)}</b></font> · Keep <font color="{if belowMinKeep then "#fbbf24" else "#34d399"}"><b>{fmt(keep)}</b></font>`
		summary.TextXAlignment = Enum.TextXAlignment.Center
		if opts.capacity and troops and opts.capacity < total then
			capNote.Text = Lang.t("Receiver can accept only {amount} right now.", { amount = fmt(math.max(0, opts.capacity)) })
			capNote.Visible = true
		end
		local disabled = total <= 0 or amount <= 0
		send.BackgroundTransparency = if disabled then 0.5 else 0
		send.TextTransparency = if disabled then 0.5 else 0
	end

	for i, p in PRESETS do
		local b = Style.button(presets, `P{p}`, `{p}%`, 13, F.semibold)
		b.AutomaticSize = Enum.AutomaticSize.None
		b.LayoutOrder = i
		b.BackgroundTransparency = 0
		b.ZIndex = presets.ZIndex + 1
		Style.corner(b, 8)
		presetButtons[p] = b
		b.Activated:Connect(function()
			amount = math.floor(total * p / 100)
			paint()
		end)
	end

	local dragging = false
	local function setFromX(x: number)
		local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		amount = math.floor(total * rel)
		paint()
	end
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	local moveConn = UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	local endConn = UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	card.Destroying:Connect(function()
		moveConn:Disconnect()
		endConn:Disconnect()
	end)

	cancel.Activated:Connect(close)
	send.Activated:Connect(function()
		amount = math.clamp(amount, 0, hardMax)
		if amount > 0 then
			opts.onSend(amount)
			close()
		end
	end)
	paint()
	return close
end

return SendResourceModal
