-- Right-click radial menu, ported from upstream hud/layers/RadialMenu.ts +
-- RadialMenuElements.ts + MainRadialMenu.ts:
--   * centre button (sword, #0f2744, r 30): attack the clicked tile (spawn
--     during the spawn phase); becomes "back" while a submenu is open
--   * main ring (radius 40..95, 4 slots, first slot centred at the top,
--     padAngle 0.03, opacity 0.82 / 0.4 disabled):
--       own territory: info, delete, alliance, build
--       elsewhere:     info, boat | break alliance, request | extend
--                      alliance, attack | donate gold (friendly)
--   * submenus (radius 75..140, main ring shrinks to 0.65): build → the
--     structures, attack → nukes + warship; each leaf builds or upgrades
-- Ring sectors are baked into EditableImages (cropped to their bounding box)
-- since Roblox UI has no arc primitive; hit-testing is done in polar space.
-- TODO(port): bulk-amount sub-submenus.

local AssetService = game:GetService("AssetService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Audio = require(script.Parent.Audio)
local Icons = require(script.Parent.Icons)
local Style = require(script.Parent.Style)

local C, F = Style.color, Style.font

local COLORS = {
	build = Color3.fromHex("#e6c74a"),
	building = Color3.fromHex("#1e3a5f"),
	boat = Color3.fromHex("#2a82c9"),
	disabled = Color3.fromHex("#94a3b8"),
	ally = Color3.fromHex("#4ade80"),
	breakAlly = Color3.fromHex("#dc2626"),
	breakAllyNoDebuff = Color3.fromHex("#d97706"),
	donateGold = Color3.fromHex("#f59e0b"),
	delete = Color3.fromHex("#ef4444"),
	info = Color3.fromHex("#475569"),
	attack = Color3.fromHex("#ef4444"),
	center = Color3.fromHex("#0f2744"),
	disabledGrey = Color3.fromRGB(128, 128, 128),
}

local PAD_ANGLE = 0.03
local ICON_SIZE = 42
local CENTER_R = 30
local CENTER_ICON = 48
local SUB_SHRINK = 0.65

local function ringRadii(level: number): (number, number)
	local inner = if level == 0 then 40 else 50 + 25
	local width = if level == 0 then 55 else 65
	return inner, inner + width
end

-- Upstream flattenedBuildTable order, split like createMenuElements.
local BUILD_ITEMS = {
	{ unit = "City", icon = "city", desc = "Increases max population", countable = true },
	{ unit = "Factory", icon = "factory", desc = "Creates railroads and spawns trains", countable = true },
	{ unit = "Port", icon = "port", desc = "Sends trade ships to generate gold", countable = true },
	{ unit = "Defense Post", icon = "defensePost", desc = "Increases defenses of nearby borders", countable = true },
	{ unit = "Missile Silo", icon = "missileSilo", desc = "Used to launch nukes", countable = true },
	{ unit = "SAM Launcher", icon = "samLauncher", desc = "Defends against incoming nukes", countable = true },
}
local ATTACK_ITEMS = {
	{ unit = "Atom Bomb", icon = "atomBomb", desc = "Small explosion" },
	{ unit = "Hydrogen Bomb", icon = "hydrogenBomb", desc = "Large explosion" },
	{ unit = "MIRV", icon = "mirv", desc = "Huge explosion, only targets selected player" },
	{ unit = "Warship", icon = "warship", desc = "Captures trade ships, destroys ships and boats", countable = true },
}

-- Sector masks ---------------------------------------------------------------------------

local sectorCache = {}

-- d3 angle convention: 0 at 12 o'clock, clockwise; x = sin a, y = -cos a.
local function bakeSector(inner: number, outer: number, a0: number, a1: number)
	local key = string.format("%d:%d:%.4f:%.4f", inner, outer, a0, a1)
	local cached = sectorCache[key]
	if cached then
		return cached
	end
	-- d3 pads each side by a constant distance at padRadius = sqrt(i² + o²).
	local gap = PAD_ANGLE * math.sqrt(inner * inner + outer * outer) / 2
	-- Bounding box of the sector (corners + axis crossings).
	local xs, ys = {}, {}
	local function addPoint(a, r)
		table.insert(xs, math.sin(a) * r)
		table.insert(ys, -math.cos(a) * r)
	end
	for _, r in { inner, outer } do
		addPoint(a0, r)
		addPoint(a1, r)
	end
	for k = -4, 8 do
		local a = k * math.pi / 2
		if a > a0 and a < a1 then
			addPoint(a, outer)
		end
	end
	local minX, maxX = math.floor(math.min(table.unpack(xs))) - 1, math.ceil(math.max(table.unpack(xs))) + 1
	local minY, maxY = math.floor(math.min(table.unpack(ys))) - 1, math.ceil(math.max(table.unpack(ys))) + 1
	local w, h = maxX - minX, maxY - minY
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	local px = buffer.create(w * h * 4)
	local mid = (a0 + a1) / 2
	local half = (a1 - a0) / 2
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local cx, cy = minX + x + 0.5, minY + y + 0.5
			local r = math.sqrt(cx * cx + cy * cy)
			local alpha = 0
			if r >= inner - 0.5 and r <= outer + 0.5 then
				-- Angle relative to the sector's middle, in (-pi, pi].
				local a = math.atan2(cx, -cy) - mid
				a = (a + math.pi) % (2 * math.pi) - math.pi
				if math.abs(a) <= half then
					-- Perpendicular distance to the nearer edge line.
					local edge = r * math.sin(half - math.abs(a))
					local ea = math.clamp(edge - gap + 0.5, 0, 1)
					local ra = math.clamp(math.min(r - inner + 0.5, outer - r + 0.5), 0, 1)
					alpha = math.min(ea, ra)
				end
			end
			local o = (y * w + x) * 4
			buffer.writeu8(px, o, 255)
			buffer.writeu8(px, o + 1, 255)
			buffer.writeu8(px, o + 2, 255)
			buffer.writeu8(px, o + 3, math.floor(alpha * 255 + 0.5))
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), px)
	cached = { image = img, x = minX, y = minY, w = w, h = h }
	sectorCache[key] = cached
	return cached
end

-- Menu -----------------------------------------------------------------------------------------

local RadialMenu = {}
RadialMenu.__index = RadialMenu

-- deps: { gui, net, buildMenu, mySmallID(), ratio(), onClose? }
function RadialMenu.new(deps)
	local self = setmetatable({ deps = deps, open = false, levels = {}, hovered = nil }, RadialMenu)

	local root = Style.frame(deps.gui, "RadialMenu")
	root.Size = UDim2.fromOffset(0, 0)
	root.ZIndex = 50
	root.Visible = false
	self.root = root

	-- Centre button.
	local center = Instance.new("TextButton")
	center.Name = "Center"
	center.Text = ""
	center.AutoButtonColor = false
	center.AnchorPoint = Vector2.new(0.5, 0.5)
	center.Size = UDim2.fromOffset(CENTER_R * 2, CENTER_R * 2)
	center.BackgroundColor3 = COLORS.center
	center.BorderSizePixel = 0
	center.ZIndex = 55
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0.5, 0)
	cc.Parent = center
	center.Parent = root
	self.center = center
	self.centerIcon = nil

	-- Tooltip (radial-tooltip): title / description / cost / count.
	local tip = Style.frame(deps.gui, "RadialTooltip", Color3.fromRGB(20, 20, 20), 0.9)
	tip.AutomaticSize = Enum.AutomaticSize.XY
	tip.Visible = false
	tip.ZIndex = 60
	Style.corner(tip, 6)
	Style.padding(tip, 8, 6)
	Style.column(tip, 2)
	self.tip = tip

	UserInputService.InputChanged:Connect(function(input)
		if self.open and input.UserInputType == Enum.UserInputType.MouseMovement then
			self:_hover(UserInputService:GetMouseLocation())
		end
	end)
	UserInputService.InputBegan:Connect(function(input)
		if not self.open then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			local p = if input.UserInputType == Enum.UserInputType.Touch
				then Vector2.new(input.Position.X, input.Position.Y) + game:GetService("GuiService"):GetGuiInset()
				else UserInputService:GetMouseLocation()
			self:_click(p)
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:close()
		end
	end)
	return self
end

function RadialMenu:isOpen(): boolean
	return self.open
end

function RadialMenu:close()
	if not self.open then
		return
	end
	self.open = false
	self.root.Visible = false
	self.tip.Visible = false
	for _, lvl in self.levels do
		lvl.frame:Destroy()
	end
	self.levels = {}
	self.closedAt = os.clock()
	if self.deps.onClose then
		self.deps.onClose()
	end
end

-- Open at screen point p for map tile `tile`; `info` is the Net.Query result.
function RadialMenu:openAt(p: Vector2, tile: number, info)
	self:close()
	self.open = true
	self.tile = tile
	self.info = info
	self.center.Position = UDim2.fromOffset(0, 0)
	local screen = self.deps.gui.AbsoluteSize
	-- Keep the full submenu (radius 140) on screen.
	local m = 145
	self.origin = Vector2.new(math.clamp(p.X, m, math.max(m, screen.X - m)), math.clamp(p.Y, m, math.max(m, screen.Y - m)))
	self.root.Position = UDim2.fromOffset(self.origin.X, self.origin.Y)
	self.root.Visible = true
	self:_renderLevel(0, self:_rootItems())
	self:_setCenter(false)
end

-- Element lists -------------------------------------------------------------------------------

function RadialMenu:_buildable(unit: string)
	for _, u in self.info.units do
		if u.unit == unit then
			return u
		end
	end
	return nil
end

function RadialMenu:_unitItems(defs, color)
	local items = {}
	local bm = self.deps.buildMenu
	for _, def in defs do
		if bm.disabled[def.unit] then
			continue -- getAllEnabledUnits: config-disabled units are left out
		end
		local bu = self:_buildable(def.unit)
		local enabled = bu ~= nil and (bu.canBuild or bu.canUpgrade)
		local me = self.deps.mySmallID()
		local tooltip = {
			{ text = def.unit, kind = "title" },
			{ text = def.desc, kind = "description" },
			{ text = `{Format.renderNumber(bm.costs[def.unit] or (bu and bu.cost) or 0)} gold`, kind = "cost" },
		}
		if def.countable and me then
			table.insert(tooltip, { text = `{bm.deps.unitLayer:totalLevels(me, def.unit)}x`, kind = "count" })
		end
		table.insert(items, {
			id = def.unit,
			icon = def.icon,
			color = if enabled then color else COLORS.building,
			disabled = not enabled,
			tooltip = tooltip,
			action = function()
				self.deps.net.Intent:FireServer({ type = "place", unit = def.unit, tile = self.tile, rocketDirectionUp = self.deps.rocketUp == nil or self.deps.rocketUp() })
				self:close()
			end,
		})
	end
	return items
end

function RadialMenu:_rootItems()
	local info = self.info
	local me = self.deps.mySmallID()
	local own = me ~= nil and info.ownerSmallID == me
	local interaction = info.interaction
	local items = {
		{
			id = "info",
			icon = "info",
			color = COLORS.info,
			disabled = info.ownerSmallID == 0 or info.inSpawnPhase,
			action = function()
				local tile = self.tile
				self:close()
				self.deps.playerPanel:show(tile)
			end,
		},
	}
	local function allyRequest()
		return {
			id = "ally",
			icon = "alliance",
			color = COLORS.ally,
			disabled = not (interaction and interaction.canSendAllianceRequest),
			action = function()
				self.deps.net.Intent:FireServer({ type = "alliance_request", target = info.ownerSmallID })
				if self.deps.onAllianceRequestSent then
					self.deps.onAllianceRequestSent(info.ownerSmallID)
				end
				self:close()
			end,
		}
	end
	if own then
		table.insert(items, {
			id = "delete",
			icon = "x",
			color = COLORS.delete,
			disabled = info.deleteUnit == nil,
			tooltip = { { text = "Delete unit", kind = "title" }, { text = "Delete the closest structure of yours", kind = "description" } },
			action = function()
				self.deps.net.Intent:FireServer({ type = "delete_at", tile = self.tile })
				self:close()
			end,
		})
		table.insert(items, allyRequest())
		table.insert(items, {
			id = "build",
			icon = "build",
			color = COLORS.build,
			disabled = info.inSpawnPhase,
			submenu = function()
				return self:_unitItems(BUILD_ITEMS, COLORS.building)
			end,
		})
	else
		local isAllied = interaction and interaction.isAllied
		local disconnected = interaction and interaction.isDisconnected
		if isAllied and not disconnected then
			table.insert(items, {
				id = "break",
				icon = "traitor",
				color = if info.ownerIsTraitor or disconnected then COLORS.breakAllyNoDebuff else COLORS.breakAlly,
				disabled = not interaction.canBreakAlliance,
				action = function()
					self.deps.net.Intent:FireServer({ type = "break_alliance", target = info.ownerSmallID })
					self:close()
				end,
			})
		else
			table.insert(items, {
				id = "boat",
				icon = "boat",
				color = COLORS.boat,
				disabled = not info.canBoat,
				action = function()
					self.deps.net.Intent:FireServer({ type = "boat_at", tile = self.tile, ratio = self.deps.ratio() })
					self:close()
				end,
			})
		end
		local ext = interaction and interaction.allianceInfo
		if ext and ext.inExtensionWindow then
			table.insert(items, {
				id = "extend",
				icon = "alliance",
				color = COLORS.ally,
				disabled = not ext.canExtend,
				action = function()
					self.deps.net.Intent:FireServer({ type = "alliance_extend", target = info.ownerSmallID })
					self:close()
				end,
			})
		else
			table.insert(items, allyRequest())
		end
		-- Friendly, connected target without buildable attacks: donate gold.
		local hasBuildableAttacks = false
		for _, bu in info.units or {} do
			if (bu.unit == "Atom Bomb" or bu.unit == "Hydrogen Bomb" or bu.unit == "MIRV" or bu.unit == "Warship") and bu.canBuild then
				hasBuildableAttacks = true
				break
			end
		end
		if interaction and interaction.isFriendly and not disconnected and not hasBuildableAttacks then
			table.insert(items, {
				id = "donateGold",
				icon = "donateGold",
				color = COLORS.donateGold,
				disabled = info.inSpawnPhase or not interaction.canDonateGold,
				action = function()
					local tile = self.tile
					self:close()
					self.deps.playerPanel:openSendGoldAt(tile)
				end,
			})
		else
			table.insert(items, {
				id = "attack",
				icon = "swordWhite",
				color = COLORS.attack,
				disabled = info.inSpawnPhase,
				submenu = function()
					return self:_unitItems(ATTACK_ITEMS, COLORS.attack)
				end,
			})
		end
	end
	return items
end

-- Rendering --------------------------------------------------------------------------------------

function RadialMenu:_renderLevel(level: number, items)
	if self.levels[level] then
		self.levels[level].frame:Destroy()
	end
	local frame = Style.frame(self.root, `Level{level}`)
	frame.Size = UDim2.fromOffset(0, 0)
	frame.ZIndex = 51
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	local inner, outer = ringRadii(level)
	local n = #items
	local offset = -math.pi / n
	local segs = {}
	for i, item in items do
		local a0 = offset + (i - 1) * 2 * math.pi / n
		local a1 = a0 + 2 * math.pi / n
		local sector = bakeSector(inner, outer, a0, a1)
		local img = Instance.new("ImageLabel")
		img.Name = item.id
		img.BackgroundTransparency = 1
		img.ImageContent = Content.fromObject(sector.image)
		img.Position = UDim2.fromOffset(sector.x, sector.y)
		img.Size = UDim2.fromOffset(sector.w, sector.h)
		img.ZIndex = 52
		img.Parent = frame
		local mid = (a0 + a1) / 2
		local rc = (inner + outer) / 2
		local icon = Icons.label(frame, item.icon, ICON_SIZE, { white = item.icon ~= "info" and item.icon ~= "x" })
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromOffset(math.sin(mid) * rc, -math.cos(mid) * rc)
		icon.ZIndex = 53
		icon.ImageTransparency = if item.disabled then 0.5 else 0
		table.insert(segs, { item = item, img = img, a0 = a0, a1 = a1 })
	end
	local lvl = { frame = frame, scale = scale, items = items, segs = segs, level = level, inner = inner, outer = outer }
	self.levels[level] = lvl
	self:_paint(lvl)
	if level > 0 then
		-- Submenu expands from 0.5 while the main ring shrinks to 0.65.
		scale.Scale = 0.5
		TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { Scale = 1 }):Play()
		if self.levels[0] then
			TweenService:Create(self.levels[0].scale, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { Scale = SUB_SHRINK }):Play()
		end
	end
end

function RadialMenu:_paint(lvl)
	for _, seg in lvl.segs do
		local item = seg.item
		local hovered = self.hovered == item and not item.disabled
		local color = if item.disabled then COLORS.disabled else item.color
		if lvl.selected == item then
			color = color:Lerp(Color3.new(1, 1, 1), 0.15)
		end
		seg.img.ImageColor3 = if hovered then color:Lerp(Color3.new(1, 1, 1), 0.25) else color
		seg.img.ImageTransparency = if item.disabled then 0.6 else if hovered then 0.05 else 0.18
	end
end

function RadialMenu:_setCenter(back: boolean)
	if self.centerIcon then
		self.centerIcon:Destroy()
	end
	self.back = back
	local attackOk = self.info and (self.info.canAttack or (self.info.inSpawnPhase and self.info.ownerSmallID == 0))
	if self.info and not self.info.inSpawnPhase and self:_friendlyTarget() then
		attackOk = self.info.interaction.canDonateTroops
	end
	local iconName = if back then "back" else "swordWhite"
	local size = if back then CENTER_ICON * 0.8 else CENTER_ICON
	local icon = Icons.label(self.center, iconName, size, { white = true })
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.ZIndex = 56
	self.centerIcon = icon
	self.center.BackgroundColor3 = if back or attackOk then COLORS.center else COLORS.disabledGrey
	icon.ImageTransparency = if back or attackOk then 0 else 0.5
end

-- isFriendlyTarget && !isDisconnectedTarget (RadialMenuElements).
function RadialMenu:_friendlyTarget(): boolean
	local i = self.info and self.info.interaction
	return i ~= nil and i.isFriendly and not i.isDisconnected
end

-- Hit testing ------------------------------------------------------------------------------------

function RadialMenu:_hit(p: Vector2)
	local d = p - self.origin
	local r = d.Magnitude
	if r <= CENTER_R then
		return "center"
	end
	local a = math.atan2(d.X, -d.Y)
	for level = 1, 0, -1 do
		local lvl = self.levels[level]
		if lvl then
			local s = lvl.scale.Scale
			if r >= lvl.inner * s and r <= lvl.outer * s then
				for _, seg in lvl.segs do
					local rel = (a - seg.a0) % (2 * math.pi)
					if rel <= seg.a1 - seg.a0 then
						return seg, lvl
					end
				end
			end
		end
	end
	return nil
end

function RadialMenu:_hover(p: Vector2)
	local seg = self:_hit(p)
	local item = if type(seg) == "table" then seg.item else nil
	if item ~= self.hovered then
		self.hovered = item
		for _, lvl in self.levels do
			self:_paint(lvl)
		end
	end
	self:_showTooltip(item, p)
end

function RadialMenu:_showTooltip(item, p: Vector2)
	local tip = self.tip
	for _, c in tip:GetChildren() do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	if item == nil or item.tooltip == nil then
		tip.Visible = false
		return
	end
	for i, t in item.tooltip do
		local color = if t.kind == "cost" then Color3.fromHex("#f59e0b") elseif t.kind == "count" then Color3.fromHex("#94a3b8") else C.white
		local l = Style.text(tip, t.kind, t.text, if t.kind == "title" then 14 else 12, if t.kind == "title" then F.bold else F.medium, color)
		l.LayoutOrder = i
		l.ZIndex = 61
	end
	tip.Position = UDim2.fromOffset(p.X + 14, p.Y + 14)
	tip.Visible = true
end

function RadialMenu:_click(p: Vector2)
	local seg, lvl = self:_hit(p)
	if seg == "center" then
		if self.back then
			-- Back: drop the submenu, restore the main ring.
			if self.levels[1] then
				self.levels[1].frame:Destroy()
				self.levels[1] = nil
			end
			if self.levels[0] then
				self.levels[0].selected = nil
				TweenService:Create(self.levels[0].scale, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { Scale = 1 }):Play()
				self:_paint(self.levels[0])
			end
			self:_setCenter(false)
			return
		end
		local info = self.info
		if info.inSpawnPhase then
			if info.ownerSmallID == 0 then
				Audio.play("spawn")
				self.deps.net.Intent:FireServer({ type = "spawn", tile = self.tile })
				self:close()
			end
		elseif self:_friendlyTarget() then
			local interaction = info.interaction
			local troops = math.floor(self.deps.ratio() * (self.deps.myTroops() or 0))
			if interaction.canDonateTroops and troops > 0 then
				self.deps.net.Intent:FireServer({ type = "donate_troops", target = info.ownerSmallID, amount = troops })
				self:close()
			end
		elseif info.canAttack then
			self.deps.net.Intent:FireServer({ type = "attack_at", tile = self.tile, ratio = self.deps.ratio() })
			self:close()
		end
		return
	end
	if seg == nil then
		self:close()
		return
	end
	Audio.play("click")
	local item = seg.item
	if item.disabled then
		return
	end
	if item.submenu then
		lvl.selected = item
		self:_paint(lvl)
		self:_renderLevel(1, item.submenu())
		self:_setCenter(true)
	elseif item.action then
		item.action()
	end
end

return RadialMenu
