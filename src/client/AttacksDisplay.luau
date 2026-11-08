-- Attack list above the control panel, ported from upstream
-- hud/layers/AttacksDisplay.ts. One bg-gray-800/92 row per:
--   * incoming attack from a non-tribe player (red, soldier ↓, name,
--     "(retreating...)"), with a retaliate sword button
--   * outgoing attack on a player (aquarius, soldier ↑) with ❌ cancel
--   * outgoing attack on the wilderness, same with "Wilderness"
--   * our transport boats (sprite, troops, destination) with ❌ retreat
-- Clicking a row focuses the other player / the boat.

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Icons = require(script.Parent.Icons)
local Sprites = require(script.Parent.Sprites)
local Style = require(script.Parent.Style)

local C, F = Style.color, Style.font
local RED = Color3.fromHex("#f87171")

local AttacksDisplay = {}
AttacksDisplay.__index = AttacksDisplay

-- deps: { parent (column), net, playerName(smallID), playerType(smallID),
--         myTroops(), ratio(), boats() -> { { id, troops, targetName, ownerID } },
--         focusPlayer(smallID), focusUnit(id), visible(), myColors() -> (Color3, Color3) }
function AttacksDisplay.new(deps)
	local self = setmetatable({ deps = deps, incoming = {}, outgoing = {} }, AttacksDisplay)
	local list = Style.frame(deps.parent, "AttacksDisplay")
	list.LayoutOrder = 0
	list.Size = UDim2.fromScale(1, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	Style.column(list, 4)
	self.list = list
	task.spawn(function()
		while list.Parent do
			self:_render()
			task.wait(0.2)
		end
	end)
	return self
end

function AttacksDisplay:setAttacks(incoming, outgoing)
	self.incoming = incoming or {}
	self.outgoing = outgoing or {}
end

function AttacksDisplay:_row(order: number)
	local row = Style.frame(self.list, "Row", C.gray800, 0.92)
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, 26)
	row.Active = true
	Style.corner(row, 8)
	Style.padding(row, 6, 2)
	local l = Style.row(row, 4)
	l.VerticalAlignment = Enum.VerticalAlignment.Center
	return row
end

local function mainButton(row: Frame, color: Color3, onClick: (() -> ())?)
	local b = Instance.new("TextButton")
	b.Name = "Main"
	b.Text = ""
	b.BackgroundTransparency = 1
	b.AutoButtonColor = false
	b.LayoutOrder = 1
	b.Size = UDim2.new(1, -40, 1, 0)
	b.ClipsDescendants = true
	local l = Style.row(b, 4)
	l.VerticalAlignment = Enum.VerticalAlignment.Center
	b.Parent = row
	if onClick then
		b.Activated:Connect(onClick)
	end
	return b
end

local function soldier(parent: Instance, color: Color3, arrow: string, order: number)
	local icon = Icons.label(parent, "soldier", 18, { white = true })
	icon.LayoutOrder = order
	local a = Style.text(parent, "Arrow", arrow, 14, F.bold, color)
	a.LayoutOrder = order + 1
end

local function rightButton(row: Frame, text: string, onClick: () -> (), boxed: boolean?)
	local b = Style.button(row, "Action", text, 14, F.bold, C.white)
	b.LayoutOrder = 3
	b.AutomaticSize = Enum.AutomaticSize.None
	b.Size = UDim2.fromOffset(32, 22)
	if boxed then
		b.BackgroundColor3 = Color3.fromHex("#7f1d1d")
		b.BackgroundTransparency = 0.5
		Style.corner(b, 8)
		Style.stroke(b, Color3.fromHex("#b91c1c"), 1, 0.5)
	end
	b.Activated:Connect(onClick)
	return b
end

function AttacksDisplay:_render()
	for _, c in self.list:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	if not self.deps.visible() then
		return
	end
	local deps = self.deps
	local order = 0

	-- Incoming, tribes excluded.
	for _, a in self.incoming do
		if deps.playerType(a.other) == "BOT" then
			continue
		end
		order += 1
		local row = self:_row(order)
		local b = mainButton(row, RED, function()
			deps.focusPlayer(a.other)
		end)
		soldier(b, RED, "↓", 1)
		Style.text(b, "Troops", Format.renderTroops(a.troops), 14, F.medium, RED).LayoutOrder = 3
		local name = Style.text(b, "Name", (deps.playerName(a.other) or "") .. (if a.retreating then " (retreating...)" else ""), 14, F.medium, RED)
		name.LayoutOrder = 4
		if not a.retreating then
			local sword = rightButton(row, "", function()
				-- handleRetaliate: min(attack troops, ratio * our troops).
				local troops = deps.myTroops()
				if troops <= 0 then
					return
				end
				local ratio = math.min(deps.ratio(), a.troops / troops)
				deps.net.Intent:FireServer({ type = "attack", targetSmallID = a.other, ratio = math.clamp(ratio, 0.01, 1) })
			end, true)
			local si = Icons.label(sword, "sword", 18, { white = true })
			si.AnchorPoint = Vector2.new(0.5, 0.5)
			si.Position = UDim2.fromScale(0.5, 0.5)
		end
	end

	-- Outgoing (players first, then the wilderness, like upstream).
	local function outgoingRow(a, label: string)
		order += 1
		local row = self:_row(order)
		local b = mainButton(row, C.aquarius, if a.other ~= 0 then function()
			deps.focusPlayer(a.other)
		end else nil)
		soldier(b, C.aquarius, "↑", 1)
		Style.text(b, "Troops", Format.renderTroops(a.troops), 14, F.medium, C.aquarius).LayoutOrder = 3
		Style.text(b, "Name", label, 14, F.medium, C.aquarius).LayoutOrder = 4
		if a.retreating then
			local r = Style.text(row, "Retreating", "(retreating...)", 14, F.medium, C.aquarius)
			r.LayoutOrder = 3
		else
			rightButton(row, "❌", function()
				deps.net.Intent:FireServer({ type = "cancel_attack", attackID = a.id })
			end)
		end
	end
	for _, a in self.outgoing do
		if a.other ~= 0 then
			outgoingRow(a, deps.playerName(a.other) or "")
		end
	end
	for _, a in self.outgoing do
		if a.other == 0 then
			outgoingRow(a, "Wilderness")
		end
	end

	-- Our boats.
	for _, boat in deps.boats() do
		order += 1
		local row = self:_row(order)
		local b = mainButton(row, C.aquarius, function()
			deps.focusUnit(boat.id)
		end)
		local icon, bands = Sprites.make(b, "Transport", "Boat", 5)
		icon.AnchorPoint = Vector2.new(0, 0)
		icon.Size = UDim2.fromOffset(20, 20)
		icon.LayoutOrder = 1
		local t, border = deps.myColors()
		Sprites.paint(bands, t, border)
		local troops = Style.text(b, "Troops", Format.renderTroops(boat.troops), 14, F.medium, C.white)
		troops.LayoutOrder = 2
		Style.text(b, "Target", boat.targetName, 14, F.medium, C.white).LayoutOrder = 3
		rightButton(row, "❌", function()
			deps.net.Intent:FireServer({ type = "cancel_boat", unitID = boat.id })
		end)
	end
end

return AttacksDisplay
