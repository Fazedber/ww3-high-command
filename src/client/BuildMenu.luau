-- Build controls, ported from upstream UnitDisplay.ts (hotbar),
-- InputHandler.ts (build keybinds) and BuildPreviewController.ts (ghost):
--   * hotbar under the control panel: hotkey, icon, total levels owned;
--     greyed (opacity-40) when it can't be afforded; hover tooltip with
--     name [key], description and price
--   * Digit1..Digit0 / numpad pick the ghost; the same key again toggles the
--     x5 upgrade multiplier (setGhostStructure); Esc clears it
--   * the ghost follows the cursor with the unit icon, the cost label and the
--     range circle (defense post); a click upgrades the structure in range or
--     builds, and clears the ghost (bombs keep it); a click where nothing can
--     be built just clears it
--   * right click cancels the ghost (the radial menu is RadialMenu.luau)
-- Availability comes from Net.Query (PlayerImpl:buildableUnits on the server).

local UserInputService = game:GetService("UserInputService")

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Icons = require(script.Parent.Icons)
local Style = require(script.Parent.Style)
local Lang = require(script.Parent.Lang)
local Locale = require(script.Parent.Locale)

local C, F = Style.color, Style.font

-- UserSettings default keybinds + UnitDisplay order, icons and texts (en.json).
local ITEMS = {
	{ unit = "City", key = Enum.KeyCode.One, numpad = Enum.KeyCode.KeypadOne, hotkey = "1", icon = "city", count = true, desc = "Increases max population" },
	{ unit = "Factory", key = Enum.KeyCode.Two, numpad = Enum.KeyCode.KeypadTwo, hotkey = "2", icon = "factory", count = true, desc = "Creates railroads and spawns trains" },
	{ unit = "Port", key = Enum.KeyCode.Three, numpad = Enum.KeyCode.KeypadThree, hotkey = "3", icon = "port", count = true, desc = "Sends trade ships to generate gold" },
	{ unit = "Defense Post", key = Enum.KeyCode.Four, numpad = Enum.KeyCode.KeypadFour, hotkey = "4", icon = "defensePost", count = true, desc = "Increases defenses of nearby borders" },
	{ unit = "Missile Silo", key = Enum.KeyCode.Five, numpad = Enum.KeyCode.KeypadFive, hotkey = "5", icon = "missileSilo", count = true, desc = "Used to launch nukes" },
	{ unit = "SAM Launcher", key = Enum.KeyCode.Six, numpad = Enum.KeyCode.KeypadSix, hotkey = "6", icon = "samLauncher", count = true, desc = "Defends against incoming nukes" },
	{ unit = "Warship", key = Enum.KeyCode.Seven, numpad = Enum.KeyCode.KeypadSeven, hotkey = "7", icon = "warship", count = true, desc = "Captures trade ships, destroys ships and boats", hint = "⇧ Hold Shift and drag to select multiple warships at once" },
	{ unit = "Atom Bomb", key = Enum.KeyCode.Eight, numpad = Enum.KeyCode.KeypadEight, hotkey = "8", icon = "atomBomb", count = false, desc = "Small explosion" },
	{ unit = "Hydrogen Bomb", key = Enum.KeyCode.Nine, numpad = Enum.KeyCode.KeypadNine, hotkey = "9", icon = "hydrogenBomb", count = false, desc = "Large explosion" },
	{ unit = "MIRV", key = Enum.KeyCode.Zero, numpad = Enum.KeyCode.KeypadZero, hotkey = "0", icon = "mirv", count = false, desc = "Huge explosion, only targets selected player" },
}
local ITEM_BY_UNIT = {}
for _, item in ITEMS do
	ITEM_BY_UNIT[item.unit] = item
end

-- Tutorial highlight names (Tutorial.ts) -> unit.
local HIGHLIGHT_UNIT = {
	city = "City",
	factory = "Factory",
	port = "Port",
	defense_post = "Defense Post",
	silo = "Missile Silo",
	sam = "SAM Launcher",
	warship = "Warship",
	atom = "Atom Bomb",
	hydrogen = "Hydrogen Bomb",
	mirv = "MIRV",
}

-- Category tint for hotbar icons: economy = peach, defence = lavender, offence = rose.
local TINT = {
	City = Color3.fromRGB(242, 201, 160),
	Factory = Color3.fromRGB(242, 201, 160),
	Port = Color3.fromRGB(242, 201, 160),
	["Defense Post"] = Color3.fromRGB(160, 170, 255),
	["SAM Launcher"] = Color3.fromRGB(160, 170, 255),
	["Missile Silo"] = Color3.fromRGB(255, 150, 160),
	Warship = Color3.fromRGB(255, 150, 160),
	["Atom Bomb"] = Color3.fromRGB(255, 150, 160),
	["Hydrogen Bomb"] = Color3.fromRGB(255, 150, 160),
	MIRV = Color3.fromRGB(255, 150, 160),
}
-- Land structures obey structureMinDist (15 tiles) from every other structure.
local LAND_STRUCT = { City = true, Factory = true, Port = true, ["Defense Post"] = true, ["Missile Silo"] = true, ["SAM Launcher"] = true }
local MIN_DIST = 15

-- Ghost range circle (BuildPreviewController): defensePostRange, samRange(1),
-- nuke outer blast radius.
local RANGE = { ["Defense Post"] = 30, ["SAM Launcher"] = 50, ["Atom Bomb"] = 30, ["Hydrogen Bomb"] = 100 }
local QUERY_INTERVAL = 0.12 -- s between ghost availability queries
local OK_COLOR = C.green400
local UPGRADE_COLOR = C.blue400
local BAD_COLOR = C.red500

local BuildMenu = {}
BuildMenu.__index = BuildMenu
BuildMenu.ITEMS = ITEMS

-- deps: { gui, hotbarParent, camera, map, net, unitLayer, tileAt(Vector2) -> tile?,
--         mousePos() -> Vector2, mySmallID() -> number?, myColor() -> Color3?, canAct() -> boolean }
function BuildMenu.new(deps)
	local self = setmetatable({
		deps = deps,
		costs = {}, -- unit -> gold
		disabled = {}, -- unit -> true (config / not ported yet)
		gold = 0,
		selected = nil :: string?,
		multiplier = 1, -- uiState.upgradeMultiplier
		ghostTile = nil :: number?,
		ghostInfo = nil,
		queryBusy = false,
		lastQuery = 0,
		buttons = {},
		highlight = nil :: string?,
	}, BuildMenu)
	self:_buildHotbar()
	self:_buildGhost()
	self:_bindKeys()
	return self
end

-- Hotbar ---------------------------------------------------------------------------

function BuildMenu:_buildHotbar()
	-- Tooltip: bg-gray-800/90 rounded-sm p-1 text-xs text-gray-200 text-center w-max
	local tip = Style.frame(self.deps.gui, "BuildTooltip", C.gray800, 0.9)
	tip.AnchorPoint = Vector2.new(0.5, 1)
	tip.AutomaticSize = Enum.AutomaticSize.XY
	tip.Visible = false
	tip.ZIndex = 40
	Style.corner(tip, 2)
	Style.padding(tip, 4)
	local tipLayout = Style.column(tip, 0)
	tipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	local tipTitle = Style.text(tip, "Title", "", 14, F.bold, C.gray200)
	tipTitle.LayoutOrder = 1
	tipTitle.ZIndex = 41
	local tipDesc = Style.text(tip, "Desc", "", 12, F.medium, C.gray200)
	tipDesc.LayoutOrder = 2
	tipDesc.ZIndex = 41
	local descPad = Style.padding(tipDesc, 8)
	descPad.PaddingTop = UDim.new(0, 12) -- mb-1 + p-2
	local tipHint = Style.text(tip, "Hint", "", 10, F.medium, Color3.fromHex("#67e8f9"))
	tipHint.LayoutOrder = 3
	tipHint.ZIndex = 41
	Style.padding(tipHint, 8, 4)
	local costRow = Style.frame(tip, "Cost")
	costRow.LayoutOrder = 4
	costRow.AutomaticSize = Enum.AutomaticSize.XY
	Style.row(costRow, 4).HorizontalAlignment = Enum.HorizontalAlignment.Center
	local coin = Icons.label(costRow, "goldCoin", 19)
	coin.LayoutOrder = 1
	coin.ZIndex = 41
	local costText = Style.text(costRow, "Text", "", 12, F.medium, C.yellow300)
	costText.LayoutOrder = 2
	costText.ZIndex = 41
	self.tip, self.tipTitle, self.tipDesc, self.tipHint, self.tipCost = tip, tipTitle, tipDesc, tipHint, costText

	for i, item in ITEMS do
		-- flex-col items-center relative > border border-slate-500 rounded-sm px-0.5 pb-0.5 flex items-center gap-0.5
		local b = Instance.new("TextButton")
		b.Name = item.unit
		b.LayoutOrder = i
		b.Text = ""
		b.AutoButtonColor = false
		b.BorderSizePixel = 0
		b.BackgroundColor3 = Color3.fromRGB(10, 12, 32)
		b.BackgroundTransparency = 0.15
		b.AutomaticSize = Enum.AutomaticSize.None
		b.Size = UDim2.fromScale(1, 1)
		Style.corner(b, 2)
		local stroke = Style.stroke(b, Color3.fromRGB(45, 48, 110))
		stroke.Thickness = 2
		stroke.Transparency = 0.15
		local scale = Instance.new("UIScale")
		scale.Parent = b

		-- Dark pixel plate with a thick dark-grey border.
		b.BackgroundColor3 = Color3.fromRGB(10, 12, 32)
		b.BackgroundTransparency = 0.15
		-- Hotkey in the top-left corner.
		local key = Style.text(b, "Key", item.hotkey, 11, F.medium, C.gray400)
		key.AnchorPoint = Vector2.new(0, 0)
		key.Position = UDim2.fromOffset(3, 0)
		key.Size = UDim2.fromOffset(14, 14)
		key.TextXAlignment = Enum.TextXAlignment.Left
		key.TextYAlignment = Enum.TextYAlignment.Top
		key.ZIndex = 3
		-- Big, crisp unit icon centred in the cell.
		local icon = Icons.label(b, item.icon, 32, { white = true })
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.52)
		icon.ZIndex = 2
		icon.ImageColor3 = TINT[item.unit] or Color3.new(1, 1, 1)
		local count = nil
		if item.count then
			count = Style.text(b, "Count", "", 11, F.medium, C.gray300)
			count.AnchorPoint = Vector2.new(1, 1)
			count.Position = UDim2.new(1, -3, 1, -1)
			count.Size = UDim2.fromOffset(26, 14)
			count.TextXAlignment = Enum.TextXAlignment.Right
			count.TextYAlignment = Enum.TextYAlignment.Bottom
			count.ZIndex = 3
		end
		b.Parent = self.deps.hotbarParent

		b.Activated:Connect(function()
			-- Click toggles; only affordable units can be picked.
			if self.selected == item.unit then
				self:select(nil)
			elseif self:canBuild(item.unit) then
				self:select(item.unit)
			end
		end)
		b.MouseEnter:Connect(function()
			self.hovered = item.unit
			self:_refreshTip()
			self:_refreshButton(item)
		end)
		b.MouseLeave:Connect(function()
			if self.hovered == item.unit then
				self.hovered = nil
				self:_refreshTip()
				self:_refreshButton(item)
			end
		end)
		self.buttons[item.unit] = { button = b, stroke = stroke, icon = icon, key = key, count = count, scale = scale }
	end

	-- Adaptive hotbar grid: 8 columns on wide panels, 4 on narrow ones. The panel
	-- height is computed from the row count so nothing overflows the screen.
	local parent = self.deps.hotbarParent
	local grid = Instance.new("UIGridLayout")
	grid.Name = "HotbarGrid"
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.CellPadding = UDim2.fromOffset(2, 2)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.VerticalAlignment = Enum.VerticalAlignment.Bottom
	grid.FillDirectionMaxCells = 8
	grid.Parent = parent
	local function relayout()
		local w = parent.AbsoluteSize.X
		if w <= 0 then
			return
		end
		if self._gridWidth == w then
			return
		end
		self._gridWidth = w
		local cols = if w >= 520 then #ITEMS else 5
		local cellW = math.max(40, math.floor((w - 12 - (cols - 1) * 2) / cols))
		local cellH = 46
		local rows = math.ceil(#ITEMS / cols)
		grid.FillDirectionMaxCells = cols
		grid.CellSize = UDim2.fromOffset(cellW, cellH)
		parent.AutomaticSize = Enum.AutomaticSize.None
		parent.Size = UDim2.new(1, 0, 0, rows * cellH + (rows - 1) * 2 + 2)
	end
	relayout()
	parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
end

-- UnitDisplay.canBuild: affordable, bombs need a silo, warships a port.
function BuildMenu:canBuild(unit: string): boolean
	if self.disabled[unit] then
		return false
	end
	local cost = self.costs[unit]
	if cost == nil or cost > self.gold then
		return false
	end
	local me = self.deps.mySmallID()
	if unit == "Atom Bomb" or unit == "Hydrogen Bomb" or unit == "MIRV" then
		return me ~= nil and self.deps.unitLayer:totalLevels(me, "Missile Silo") > 0
	elseif unit == "Warship" then
		return me ~= nil and self.deps.unitLayer:totalLevels(me, "Port") > 0
	end
	return true
end

function BuildMenu:_refreshTip()
	local item = self.hovered and ITEM_BY_UNIT[self.hovered]
	self.tip.Visible = item ~= nil
	if not item then
		return
	end
	self.tipTitle.Text = Lang.t("{unit} [{key}]", { unit = Lang.t(item.unit), key = item.hotkey })
	self.tipDesc.Text = item.desc
	self.tipHint.Visible = item.hint ~= nil
	self.tipHint.Text = item.hint or ""
	self.tipCost.Text = Format.renderNumber(self.costs[item.unit] or 0)
	-- absolute bottom-full left-1/2 -translate-x-1/2 mb-1
	local b = self.buttons[item.unit].button
	-- Keep the tooltip inside the viewport (it used to hang off the screen edge
	-- for buttons near the left/right border).
	local vp = workspace.CurrentCamera.ViewportSize
	local tipW = self.tip.AbsoluteSize.X
	local x = b.AbsolutePosition.X + b.AbsoluteSize.X / 2
	x = math.clamp(x, tipW / 2 + 6, vp.X - tipW / 2 - 6)
	self.tip.Position = UDim2.fromOffset(x, b.AbsolutePosition.Y - 4)
end

function BuildMenu:_refreshButton(item)
	local b = self.buttons[item.unit]
	local me = self.deps.mySmallID()
	local selected = self.selected == item.unit
	local highlighted = self.highlight ~= nil and HIGHLIGHT_UNIT[self.highlight] == item.unit
	local dim = if self:canBuild(item.unit) then 0 else 0.6 -- opacity-40
	b.icon.ImageTransparency = dim
	b.key.TextTransparency = dim
	b.stroke.Transparency = dim
	if b.count then
		b.count.TextTransparency = dim
		local n = if me then self.deps.unitLayer:totalLevels(me, item.unit) else 0
		b.count.Text = if n and n > 0 then Format.renderNumber(n) else ""
	end
	-- selected: bg-slate-400/20; hover: bg-gray-800 (or gray-400/10 when selected);
	-- tutorial: scale-130, border gold, bg gold/25
	if highlighted then
		b.button.BackgroundColor3 = C.cyberYellow
		b.button.BackgroundTransparency = 0.75
		b.stroke.Color = C.cyberYellow
		b.stroke.Transparency = 0
		b.scale.Scale = 1.3
	else
		b.stroke.Color = Color3.fromRGB(45, 48, 110)
		b.stroke.Thickness = 2
		b.scale.Scale = 1
		if selected then
			b.stroke.Color = Color3.fromRGB(138, 143, 240)
			b.button.BackgroundColor3 = Color3.fromRGB(36, 40, 100)
			b.button.BackgroundTransparency = if self.hovered == item.unit then 0.9 else 0.8
		elseif self.hovered == item.unit then
			b.button.BackgroundColor3 = C.gray800
			b.button.BackgroundTransparency = 0
		else
			b.button.BackgroundTransparency = 1
		end
	end
end

-- Prices / disabled units from Net.Me, and our gold from Stats.
function BuildMenu:setInfo(info)
	self.costs = info.costs or self.costs
	self.disabled = info.disabled or self.disabled
	self:refresh()
end

function BuildMenu:setGold(gold: number)
	self.gold = gold
	self:refresh()
end

function BuildMenu:refresh()
	for _, item in ITEMS do
		-- renderUnitItem: config-disabled units are not shown. Units that are
		-- only waiting for the port (nukes, SAM, warship, factory) stay visible
		-- and greyed so the bar matches upstream's full layout.
		self.buttons[item.unit].button.Visible = true
		self:_refreshButton(item)
	end
	if not self.deps.canAct() and self.selected then
		self:select(nil)
	end
	if self.tip.Visible then
		self:_refreshTip()
	end
end

-- Tutorial hotbar highlight (+ bobbing ▼ arrow above the button).
function BuildMenu:setHighlight(target: string?)
	if self.highlight == target then
		return
	end
	self.highlight = target
	if self.arrow then
		self.arrow:Destroy()
		self.arrow = nil
	end
	local unit = target and HIGHLIGHT_UNIT[target]
	local b = unit and self.buttons[unit]
	if b then
		local arrow = Style.text(self.deps.gui, "TutorialArrow", "▼", 15, F.bold, C.cyberYellow)
		arrow.AnchorPoint = Vector2.new(0.5, 1)
		arrow.ZIndex = 45
		Style.textShadow(arrow, 0.1)
		self.arrow = arrow
		task.spawn(function()
			local t0 = os.clock()
			while self.arrow == arrow do
				local btn = b.button
				local bob = 2.5 - 2.5 * math.cos(((os.clock() - t0) % 0.8) / 0.8 * 2 * math.pi)
				local top = btn.AbsolutePosition.Y - btn.AbsoluteSize.Y * 0.3 -- scaled from the bottom
				arrow.Position = UDim2.fromOffset(btn.AbsolutePosition.X + btn.AbsoluteSize.X / 2, top - 3 - bob)
				task.wait()
			end
		end)
	end
	self:refresh()
end

-- Ghost ----------------------------------------------------------------------------------

function BuildMenu:_buildGhost()
	local ghost = Style.frame(self.deps.gui, "BuildGhost", C.gray800, 0.85)
	ghost.AnchorPoint = Vector2.new(0.5, 0.5)
	ghost.ZIndex = 20
	ghost.Visible = false
	Style.corner(ghost, 6)
	self.ghostStroke = Style.stroke(ghost, C.white, 2)
	local icon = Icons.label(ghost, "city", 32, { white = true })
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(0.75, 0.75)
	icon.ZIndex = 21
	local caption = Style.text(ghost, "Cost", "", 13, F.bold, C.yellow300)
	caption.AnchorPoint = Vector2.new(0.5, 0)
	caption.Position = UDim2.new(0.5, 0, 1, 4)
	caption.ZIndex = 21
	Style.textShadow(caption, 0.1)
	-- Range circle (upstream rangeRadius), centred on the upgrade target when upgrading.
	local range = Style.frame(self.deps.gui, "BuildRange")
	range.AnchorPoint = Vector2.new(0.5, 0.5)
	range.ZIndex = 19
	range.Visible = false
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0.5, 0)
	rc.Parent = range
	Style.stroke(range, C.white, 1.5, 0.3)
	self.ghost, self.ghostIcon, self.ghostCaption, self.ghostRange = ghost, icon, caption, range
	-- No-build zones: a red disc of structureMinDist around each nearby structure.
	self.blockFrames = {}
	for i = 1, 16 do
		local f = Style.frame(self.deps.gui, "BuildBlocker" .. i, Color3.fromRGB(255, 80, 90), 0.1)
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.ZIndex = 18
		f.Visible = false
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(0.5, 0)
		fc.Parent = f
		Style.stroke(f, Color3.fromRGB(255, 110, 120), 1, 0.45)
		self.blockFrames[i] = f
	end
end

function BuildMenu:_positionGhost(mouse: Vector2?)
	local camera, map = self.deps.camera, self.deps.map
	local p = mouse or self.deps.mousePos()
	if self.snapTile and self.snapFor == self.ghostTile then
		p = camera:screenPos(map:x(self.snapTile), map:y(self.snapTile))
	end
	self.ghost.Position = UDim2.fromOffset(p.X, p.Y)
end

function BuildMenu:_placeBlockers()
	local tiles = self.ghostBlockers
	local show = self.selected ~= nil and tiles ~= nil and self.ghost.Visible
	local camera, map = self.deps.camera, self.deps.map
	for i, f in ipairs(self.blockFrames) do
		local t = show and tiles[i]
		if t then
			local p = camera:screenPos(map:x(t), map:y(t))
			local d = 2 * MIN_DIST * camera.zoom
			f.Position = UDim2.fromOffset(p.X, p.Y)
			f.Size = UDim2.fromOffset(d, d)
			f.Visible = true
		else
			f.Visible = false
		end
	end
end

-- uiState.ghostStructure; picking the same unit again toggles x5 (setGhostStructure).
function BuildMenu:select(unit: string?)
	if unit ~= nil and unit == self.selected then
		self.multiplier = if self.multiplier == 1 then 5 else 1
		self:_updateGhost()
		return
	end
	self.multiplier = 1
	self.selected = unit
	self.ghostTile, self.ghostInfo = nil, nil
	self.snapTile, self.snapFor, self.ghostBlockers = nil, nil, nil
	self.ghost.Visible = false
	self:_placeBlockers()
	if self.deps.renderer then
		self.deps.renderer:setGhostRails(nil, nil)
	end
	self.ghostRange.Visible = false
	if unit then
		local item = ITEM_BY_UNIT[unit]
		self.ghostIcon:Destroy()
		local icon = Icons.label(self.ghost, item.icon, 32, { white = true })
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(0.75, 0.75)
		icon.ZIndex = 21
		self.ghostIcon = icon
		self:hover(self.deps.mousePos())
	end
	self:refresh()
end

-- Query what we can do at a tile; cb(result) runs later.
function BuildMenu:query(tile: number, cb)
	self:_query(tile, cb)
end

function BuildMenu:_query(tile: number, cb, ghost: string?)
	task.spawn(function()
		local ok, result = pcall(function()
			return self.deps.net.Query:InvokeServer({ tile = tile, ghost = ghost })
		end)
		cb(if ok then result else nil)
	end)
end

function BuildMenu:_infoFor(result, unit: string)
	if result == nil then
		return nil
	end
	for _, u in result.units do
		if u.unit == unit then
			return u
		end
	end
	return nil
end

-- bulkCost: upgrading n levels at once costs the sum of the next n levels.
local function bulkCost(info, multiplier: number): number
	if info.upgradeCosts and multiplier > 1 then
		return info.upgradeCosts[math.min(multiplier, #info.upgradeCosts)]
	end
	return info.cost
end

function BuildMenu:_updateGhost()
	local info = self.ghostInfo
	local color = BAD_COLOR
	if info and info.canUpgrade then
		color = UPGRADE_COLOR
	elseif info and info.canBuild then
		color = OK_COLOR
	end
	self.ghostStroke.Color = color
	if self.deps.renderer then
		-- Rail preview (GhostPreviewData.ghostRailPaths / overlappingRailroads).
		self.deps.renderer:setGhostRails(info and info.ghostRailPaths, info and info.overlappingRailroads)
	end
	self.ghost.BackgroundColor3 = self.deps.myColor() or C.gray800
	if info then
		local mult = if info.canUpgrade or self.selected == "Atom Bomb" then self.multiplier else 1
		local cost = if self.selected == "Atom Bomb" then info.cost * mult else bulkCost(info, mult)
		self.ghostCaption.Text = (if mult > 1 then `x{mult} ` else "") .. Format.renderNumber(cost)
		self.ghostCaption.TextColor3 = if cost <= self.gold then C.yellow300 else BAD_COLOR
	else
		self.ghostCaption.Text = ""
	end
	-- WYSIWYG: show the ghost where the structure will really appear (the server
	-- moves it to the nearest valid tile), and say why when it cannot be built.
	self.snapTile = if info and info.spawnTile and info.spawnTile ~= self.ghostTile then info.spawnTile else nil
	self.snapFor = self.ghostTile
	if self.snapTile then
		self.ghostCaption.Text = self.ghostCaption.Text .. "  > " .. Locale.pick("ближайшее место", "nearest spot")
	end
	self:_positionGhost()
	self:_placeBlockers()
	self:_placeRange()
end

function BuildMenu:_placeRange()
	local radius = self.selected and RANGE[self.selected]
	local tile = self.ghostTile
	if self.ghostInfo and self.ghostInfo.upgradeTile then
		tile = self.ghostInfo.upgradeTile
	end
	if not radius or not tile or not self.ghost.Visible then
		self.ghostRange.Visible = false
		return
	end
	local camera, map = self.deps.camera, self.deps.map
	local p = camera:screenPos(map:x(tile), map:y(tile))
	local d = radius * 2 * camera.zoom
	self.ghostRange.Position = UDim2.fromOffset(p.X, p.Y)
	self.ghostRange.Size = UDim2.fromOffset(d, d)
	self.ghostRange.Visible = true
end

-- Mouse moved (screen position); only matters while a unit is selected.
function BuildMenu:hover(p: Vector2)
	if not self.selected then
		return
	end
	local tile = self.deps.tileAt(p)
	self.ghost.Visible = tile ~= nil
	if tile == nil then
		self.ghostRange.Visible = false
		return
	end
	local size = math.clamp(self.deps.camera.zoom * 3, 22, 34)
	self.ghost.Size = UDim2.fromOffset(size, size)
	if tile ~= self.ghostTile then
		self.ghostTile = tile
		self:_scheduleQuery()
	end
	self:_positionGhost(p)
	self:_placeBlockers()
	self:_placeRange()
end

function BuildMenu:_scheduleQuery()
	if self.queryBusy then
		self.queryDirty = true
		return
	end
	local wait = QUERY_INTERVAL - (os.clock() - self.lastQuery)
	self.queryBusy = true
	task.delay(math.max(0, wait), function()
		local tile, unit = self.ghostTile, self.selected
		if tile == nil or unit == nil then
			self.queryBusy = false
			return
		end
		self.lastQuery = os.clock()
		self:_query(tile, function(result)
			self.queryBusy = false
			if self.selected == unit and self.ghostTile == tile then
				self.ghostInfo = self:_infoFor(result, unit)
				self:_updateGhost()
			end
			if self.queryDirty then
				self.queryDirty = false
				self:_scheduleQuery()
			end
		end, unit)
	end)
end

-- Left click on the map; returns true when the build menu used it
-- (BuildPreviewController.createStructure).
function BuildMenu:click(tile: number): boolean
	local unit = self.selected
	if not unit then
		return false
	end
	local info = self.ghostInfo
	if info == nil or self.ghostTile ~= tile then
		-- Not resolved for this tile yet: let the server decide.
		self.deps.net.Intent:FireServer({ type = "place", unit = unit, tile = tile, amount = self.multiplier, rocketDirectionUp = self.deps.rocketUp == nil or self.deps.rocketUp() })
		self:select(nil)
		return true
	end
	if info.canUpgrade then
		self.deps.net.Intent:FireServer({ type = "place", unit = unit, tile = tile, amount = self.multiplier, rocketDirectionUp = self.deps.rocketUp == nil or self.deps.rocketUp() })
		self:select(nil)
	elseif info.canBuild then
		-- Atom bombs honour the x5 multiplier (bulk launch), like upstream.
		local amount = if unit == "Atom Bomb" then self.multiplier else nil
		self.deps.net.Intent:FireServer({ type = "place", unit = unit, tile = tile, amount = amount, rocketDirectionUp = self.deps.rocketUp == nil or self.deps.rocketUp() })
		if unit ~= "Atom Bomb" and unit ~= "Hydrogen Bomb" then -- shouldPreserveGhostAfterBuild
			self:select(nil)
		end
	else
		self:select(nil)
	end
	return true
end

-- Keys ------------------------------------------------------------------------------------

function BuildMenu:_bindKeys()
	local byKey = {}
	for _, item in ITEMS do
		byKey[item.key] = item.unit
		byKey[item.numpad] = item.unit
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			self:select(nil)
			return
		end
		local unit = byKey[input.KeyCode]
		-- canUseBuildKeybinds: in game and alive; config-disabled units ignored.
		if unit and self.deps.canAct() and not self.disabled[unit] then
			self:select(unit)
		end
	end)
end

return BuildMenu
