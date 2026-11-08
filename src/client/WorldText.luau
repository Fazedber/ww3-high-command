-- World-space text, ported from upstream WorldTextPass +
-- AttackingTroopsController:
--   * conquest popup: "+ 1.2K" gold at the conquered player's name location
--     (+8 tiles down), world scale 6, white, fades over 2.5 s
--   * bonus popup:    "+ 45K" over a port tile (-3 tiles), rises 3 tiles/s,
--     fades over 1.5 s
--   * attack troop labels: troops at each attack's clustered front
--     positions, constant 17 px on screen, aquarius (#3fa9f5) for ours,
--     red-400 (#f87171) for incoming; positions ease over 250 ms and snap
--     on jumps over 200 tiles
-- The MSDF text is approximated with Builder Sans Bold + a black outline.

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Style = require(script.Parent.Style)

local CONQUEST_LIFETIME = 2.5
local CONQUEST_Y_OFFSET = 8
local CONQUEST_SCALE = 6 -- world units (tiles) of font size
local BONUS_LIFETIME = 1.5
local BONUS_RISE = 3 -- tiles / s
local BONUS_Y_OFFSET = -3
local BONUS_SCALE = 6
local LABEL_PX = 17
local ANIM_SECONDS = 0.25
local SNAP_DISTANCE = 200
local OUTGOING = Color3.fromHex("#3fa9f5")
local INCOMING = Color3.fromHex("#f87171")

local function formatGold(gold: number): string
	if gold >= 1000000 then
		return string.format("%.1fM", gold / 1000000)
	elseif gold >= 1000 then
		return string.format("%.1fK", gold / 1000)
	end
	return tostring(gold)
end

local WorldText = {}
WorldText.__index = WorldText

function WorldText.new(mapLayer: GuiObject, camera)
	local container = Style.frame(mapLayer, "WorldText")
	container.Size = UDim2.fromScale(1, 1)
	container.ZIndex = 9
	return setmetatable({ container = container, camera = camera, popups = {}, labels = {} }, WorldText)
end

local function makeText(parent: Instance, text: string, color: Color3, outline: number): TextLabel
	local l = Style.text(parent, "Text", text, 14, Style.font.bold, color)
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.ZIndex = 9
	local s = Instance.new("UIStroke")
	s.Color = Color3.new(0, 0, 0)
	s.Thickness = outline
	s.Parent = l
	return l
end

function WorldText:conquest(x: number, y: number, gold: number)
	local l = makeText(self.container, "+ " .. formatGold(gold), Color3.new(1, 1, 1), 2)
	table.insert(self.popups, { label = l, x = x, y = y + CONQUEST_Y_OFFSET, t0 = os.clock(), life = CONQUEST_LIFETIME, rise = 0, scale = CONQUEST_SCALE })
end

function WorldText:bonus(x: number, y: number, gold: number)
	local sign = if gold >= 0 then "+" else "-"
	local l = makeText(self.container, sign .. " " .. formatGold(math.abs(gold)), Color3.new(1, 1, 1), 2)
	table.insert(self.popups, { label = l, x = x, y = y + BONUS_Y_OFFSET, t0 = os.clock(), life = BONUS_LIFETIME, rise = BONUS_RISE, scale = BONUS_SCALE })
end

-- Attack labels from Net.Me: rows { id, troops, front = { tiles } } per
-- direction. `map` converts tiles to x, y.
function WorldText:setAttacks(map, outgoing, incoming)
	local now = os.clock()
	local seen = {}
	local function sync(rows, isIncoming: boolean)
		for _, row in rows or {} do
			if not row.front or #row.front == 0 then
				continue
			end
			seen[row.id] = true
			local entry = self.labels[row.id]
			if entry == nil then
				entry = { slots = {} }
				self.labels[row.id] = entry
			end
			entry.text = Format.renderTroops(row.troops)
			entry.color = if isIncoming then INCOMING else OUTGOING
			-- Trim / add slots, animating kept ones towards the new cluster.
			for i = #entry.slots, #row.front + 1, -1 do
				entry.slots[i].label:Destroy()
				entry.slots[i] = nil
			end
			for i, tile in row.front do
				local x, y = map:x(tile), map:y(tile)
				local slot = entry.slots[i]
				if slot == nil then
					slot = { label = makeText(self.container, entry.text, entry.color, 1.2), cx = x, cy = y, sx = x, sy = y, dx = x, dy = y, t0 = now }
					slot.label.TextSize = LABEL_PX
					entry.slots[i] = slot
				else
					local jump = math.abs(x - slot.cx) + math.abs(y - slot.cy)
					if jump > SNAP_DISTANCE then
						slot.cx, slot.cy, slot.sx, slot.sy = x, y, x, y
					else
						slot.sx, slot.sy = slot.cx, slot.cy
					end
					slot.dx, slot.dy, slot.t0 = x, y, now
				end
				slot.label.Text = entry.text
				slot.label.TextColor3 = entry.color
			end
		end
	end
	sync(outgoing, false)
	sync(incoming, true)
	for id, entry in self.labels do
		if not seen[id] then
			for _, slot in entry.slots do
				slot.label:Destroy()
			end
			self.labels[id] = nil
		end
	end
end

function WorldText:clearAttacks()
	self:setAttacks(nil, {}, {})
end

function WorldText:render()
	local camera = self.camera
	local now = os.clock()
	local keep = {}
	for _, p in self.popups do
		local age = now - p.t0
		if age >= p.life then
			p.label:Destroy()
			continue
		end
		local pos = camera:screenPos(p.x, p.y - p.rise * age)
		p.label.Position = UDim2.fromOffset(pos.X, pos.Y)
		p.label.TextSize = math.max(8, p.scale * camera.zoom)
		local fade = age / p.life
		p.label.TextTransparency = fade
		p.label:FindFirstChildOfClass("UIStroke").Transparency = fade
		table.insert(keep, p)
	end
	self.popups = keep
	for _, entry in self.labels do
		for _, slot in entry.slots do
			local a = math.clamp((now - slot.t0) / ANIM_SECONDS, 0, 1)
			slot.cx = slot.sx + (slot.dx - slot.sx) * a
			slot.cy = slot.sy + (slot.dy - slot.sy) * a
			local pos = camera:screenPos(slot.cx, slot.cy)
			slot.label.Position = UDim2.fromOffset(pos.X, pos.Y)
		end
	end
end

return WorldText
