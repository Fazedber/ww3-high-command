-- Units drawn over the map. Mobile units use the upstream sprites
-- (Sprites.luau, UnitPass): boats, trade ships, warships, nukes, MIRV
-- warheads, SAM missiles and shells, one sprite pixel per tile, coloured by
-- owner; nukes / missiles flicker, a warship with a target turns red and its
-- centre blinks while it retreats. Ships interpolate between ticks, nukes
-- replay their motion plan (Parabola.motionPath) against the estimated tick.
-- Structures are owner-coloured badges with the upstream icon and level.
-- Detonations play a flash + shockwave (render-settings nukeShockwave*).
-- TODO(port): trains; incoming-nuke trajectory telegraph; H-bomb glow.

local Parabola = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Parabola"))

local Icons = require(script.Parent.Icons)
local Sprites = require(script.Parent.Sprites)

-- FLICKER_TYPES (UnitPass).
local FLICKER = {
	["Atom Bomb"] = true,
	["Hydrogen Bomb"] = true,
	MIRV = true,
	["MIRV Warhead"] = true,
	SAMMissile = true,
	Shell = true,
}
local ANGRY = Color3.new(0.784, 0, 0) -- render-settings unit.angry
local UNTARGETABLE_ALPHA = 0.6
-- Config.nukeMagnitudes outer radius, in tiles.
local BLAST_RADIUS = { ["Atom Bomb"] = 30, ["Hydrogen Bomb"] = 100, ["MIRV Warhead"] = 24 }
-- NukeTelegraphPass: NUKE_MAGNITUDES circles at the target of a nuke in
-- flight, coloured by launcher (render-settings nukeTelegraph: self green,
-- ally yellow, enemy red; alpha 0.85 pulsing +-0.1, inner fill 0.6 fainter).
local NUKE_MAG = { ["Atom Bomb"] = { 12, 30 }, ["Hydrogen Bomb"] = { 80, 100 }, ["MIRV Warhead"] = { 16, 24 } }
local TELEGRAPH_COLORS = { [0] = Color3.new(0, 1, 0), Color3.new(1, 1, 0), Color3.new(1, 0, 0) }
local function circle(parent: Instance, name: string, color: Color3, filled: boolean)
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.BackgroundTransparency = if filled then 0.75 else 1
	f.ZIndex = 4
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = f
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = 1.5
	s.Parent = f
	f.Parent = parent
	return f, s
end
local SHOCKWAVE_SECONDS = 1.5 -- nukeShockwaveDurationMs
local SHOCKWAVE_FACTOR = 1.5 -- nukeShockwaveRadiusFactor

local TICK_SECONDS = 0.1
local MIN_STRUCT, MAX_STRUCT = 9, 30 -- px, structures

-- Structure icons (tools/pack-icons.mjs).
local BUILD_BAR = Color3.fromRGB(90, 200, 110) -- construction progress
local RELOAD_BAR = Color3.fromRGB(255, 196, 60) -- missile reload
local STRUCTURE_ICON = {
	City = "city",
	Factory = "factory",
	Port = "port",
	["Defense Post"] = "defensePost",
	["Missile Silo"] = "missileSilo",
	["SAM Launcher"] = "samLauncher",
}

local UnitLayer = {}
UnitLayer.__index = UnitLayer

function UnitLayer.new(parent: GuiObject, camera, gameMap)
	local container = Instance.new("Frame")
	container.Name = "Units"
	container.BackgroundTransparency = 1
	container.Size = UDim2.fromScale(1, 1)
	container.ZIndex = 6
	container.Parent = parent
	return setmetatable({
		container = container,
		camera = camera,
		map = gameMap,
		units = {}, -- id -> entry
		colors = {}, -- smallID -> territory Color3
		borders = {}, -- smallID -> border Color3
		onChanged = nil :: (() -> ())?, -- structures added / removed / upgraded
	}, UnitLayer)
end

function UnitLayer:setOwnerColor(smallID: number, rgb: { number }, border: { number }?)
	self.colors[smallID] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	local b = border or rgb
	self.borders[smallID] = Color3.fromRGB(b[1], b[2], b[3])
end

local function stroked(parent: Instance, thickness: number, color: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color or Color3.fromRGB(18, 20, 50)
	s.Parent = parent
	return s
end

local function textLabel(parent: Instance, name: string): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.ZIndex = 7
	stroked(label, 1.2)
	label.Parent = parent
	return label
end

-- Health bar (BarPass) and selection ring for a warship sprite frame.
local function addWarshipExtras(frame: Frame)
	local bar = Instance.new("Frame")
	bar.Name = "Health"
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0.85, 0)
	bar.Size = UDim2.new(0.7, 0, 0, 3)
	bar.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.ZIndex = 11
	bar.Parent = frame
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.ZIndex = 12
	fill.Parent = bar
	local ring = Instance.new("Frame")
	ring.Name = "Selected"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(1.1, 1.1)
	ring.BackgroundTransparency = 1
	ring.Visible = false
	ring.ZIndex = 6
	local rs = Instance.new("UIStroke")
	rs.Color = Color3.new(1, 1, 1)
	rs.Thickness = 1.5
	rs.Parent = ring
	ring.Parent = frame
	return bar, fill, ring
end

local function makeStructure(parent: Instance, id: number, icon: string)
	local frame = Instance.new("Frame")
	frame.Name = `Structure{id}`
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BorderSizePixel = 0
	frame.ZIndex = 5
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.25, 0)
	corner.Parent = frame
	local stroke = stroked(frame, 1.5, Color3.new(1, 1, 1))
	local g = Icons.label(frame, icon, 18, { white = true })
	g.AnchorPoint = Vector2.new(0.5, 0.5)
	g.Position = UDim2.fromScale(0.5, 0.5)
	g.Size = UDim2.fromScale(0.78, 0.78)
	g.ZIndex = 6
	local level = textLabel(frame, "Level")
	level.AnchorPoint = Vector2.new(0, 1)
	level.Position = UDim2.fromScale(0.72, 0.28)
	level.AutomaticSize = Enum.AutomaticSize.XY
	level.TextColor3 = Color3.fromRGB(242, 201, 160)
	level.ZIndex = 7
	-- Reload bar under the icon (SAM / silo missiles reloading).
	local reload = Instance.new("Frame")
	reload.Name = "Reload"
	reload.AnchorPoint = Vector2.new(0.5, 0)
	reload.Position = UDim2.new(0.5, 0, 1, 2)
	reload.Size = UDim2.new(1, 0, 0, 3)
	reload.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	reload.BorderSizePixel = 0
	reload.Visible = false
	reload.ZIndex = 7
	local rfill = Instance.new("Frame")
	rfill.Name = "Fill"
	rfill.BorderSizePixel = 0
	rfill.BackgroundColor3 = Color3.fromRGB(255, 196, 60)
	rfill.Size = UDim2.fromScale(0, 1)
	rfill.ZIndex = 8
	rfill.Parent = reload
	reload.Parent = frame
	frame.Parent = parent
	return frame, g, level, stroke, reload, rfill
end

-- Apply one unit update { id, unitType, ownerID, pos, troops, isActive,
-- isRetreating, level, underConstruction, markedForDeletion }.
function UnitLayer:apply(u)
	local e = self.units[u.id]
	if not u.isActive then
		if u.reachedTarget and BLAST_RADIUS[u.unitType] then
			self:explode(u.targetTile or u.pos, BLAST_RADIUS[u.unitType], u.ownerID)
		end
		if e then
			e.frame:Destroy()
			if e.telegraph then
				e.telegraph.inner:Destroy()
				e.telegraph.outer:Destroy()
			end
			self.units[u.id] = nil
			if e.isStructure and self.onChanged then
				self.onChanged()
			end
		end
		return
	end
	local icon = STRUCTURE_ICON[u.unitType]
	if icon then
		self:_applyStructure(e, u, icon)
		return
	end
	local spriteKey = u.unitType
	if u.unitType == "Train" then
		spriteKey = if u.trainType == "Engine" or u.trainType == "TailEngine"
			then "TrainEngine"
			elseif u.loaded then "TrainCarriageLoaded"
			else "TrainCarriage"
		if e and e.spriteKey ~= spriteKey then
			-- Loaded state changed: swap the sprite.
			e.frame:Destroy()
			self.units[u.id] = nil
			e = nil
		end
	end
	if not Sprites.has(spriteKey) then
		return
	end
	local now = os.clock()
	if e == nil then
		local frame, bands = Sprites.make(self.container, spriteKey, `Unit{u.id}`)
		e = {
			spriteKey = spriteKey,
			frame = frame,
			bands = bands,
			sprite = true,
			flicker = FLICKER[u.unitType] == true,
			hash = (u.id * 0.618) % 1, -- per-unit flicker phase
			from = u.pos,
			to = u.pos,
			t0 = now,
			unitType = u.unitType,
			warship = u.unitType == "Warship",
		}
		if e.warship then
			e.hbar, e.hfill, e.ring = addWarshipExtras(frame)
		end
		local mag = NUKE_MAG[u.unitType]
		if mag and u.targetTile then
			local color = TELEGRAPH_COLORS[if self.relationOf then self.relationOf(u.ownerID) else 2]
			local inner, innerStroke = circle(self.container, "TelegraphInner", color, true)
			local outer, outerStroke = circle(self.container, "TelegraphOuter", color, false)
			e.telegraph = { inner = inner, outer = outer, innerStroke = innerStroke, outerStroke = outerStroke, tile = u.targetTile, mag = mag }
		end
		if u.plan then
			local p = u.plan
			e.planned = true
			e.path = Parabola.motionPath(self.map, p.src, p.dst, p.speed, p.directionUp)
			e.startTick = p.startTick
		end
		self.units[u.id] = e
	elseif not e.planned and e.to ~= u.pos then
		e.from = e.to
		e.to = u.pos
		e.t0 = now
	end
	e.ownerID = u.ownerID
	e.pos = u.pos
	e.troops = u.troops
	e.targetTile = u.targetTile
	e.angry = u.targetUnitId ~= nil
	e.retreating = u.warshipRetreating == true or u.isRetreating == true
	e.untargetable = u.targetable == false
	if e.warship then
		local hp, max = u.health or 1, u.maxHealth or 1
		local frac = math.clamp(hp / math.max(1, max), 0, 1)
		e.hbar.Visible = frac < 1
		e.hfill.Size = UDim2.fromScale(frac, 1)
		e.hfill.BackgroundColor3 = Color3.fromRGB(230, 60, 50):Lerp(Color3.fromRGB(80, 210, 90), frac)
		e.ring.Visible = self.selected == u.id
	end
	self:_paintSprite(e, 0)
end

-- unit.frag.glsl colouring for one sprite at estimated tick `tick`.
function UnitLayer:_paintSprite(e, tick: number)
	local territory = self.colors[e.ownerID] or Color3.new(1, 1, 1)
	local border = self.borders[e.ownerID] or territory
	local center = nil
	if e.flicker then
		territory, border = Sprites.flicker(tick, e.hash)
	elseif e.warship and e.angry then
		territory = ANGRY
	end
	if e.retreating and (tick * 0.07) % 1 >= 0.5 then
		center = Color3.new(0, 0, 0)
	end
	Sprites.paint(e.bands, territory, border, center)
	Sprites.setTransparency(e.bands, if e.flicker and e.untargetable then 1 - UNTARGETABLE_ALPHA else 0)
end

-- Flash + expanding shockwave ring over a blast of `radius` tiles.
function UnitLayer:explode(tile: number, radius: number, ownerID: number?)
	-- Cosmetic blast colours (shop): explosionColors[ownerID] = { flash, ring }.
	local custom = ownerID and self.explosionColors and self.explosionColors[ownerID]
	local camera, map = self.camera, self.map
	local x, y = map:x(tile), map:y(tile)
	local flash = Instance.new("Frame")
	flash.Name = "Explosion"
	flash.AnchorPoint = Vector2.new(0.5, 0.5)
	flash.BorderSizePixel = 0
	flash.BackgroundColor3 = if custom then custom.flash else Color3.fromRGB(255, 240, 200)
	flash.ZIndex = 9
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0.5, 0)
	fc.Parent = flash
	local ring = Instance.new("Frame")
	ring.Name = "Shockwave"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 9
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0.5, 0)
	rc.Parent = ring
	local rs = Instance.new("UIStroke")
	rs.Color = if custom then custom.ring else Color3.fromRGB(255, 170, 60)
	rs.Thickness = 3
	rs.Parent = ring
	flash.Parent = self.container
	ring.Parent = self.container
	local entry = { flash = flash, ring = ring, stroke = rs, x = x, y = y, radius = radius, t0 = os.clock() }
	self.explosions = self.explosions or {}
	table.insert(self.explosions, entry)
	self:_placeExplosion(entry)
end

function UnitLayer:_placeExplosion(ex): boolean
	local a = (os.clock() - ex.t0) / SHOCKWAVE_SECONDS
	if a >= 1 then
		ex.flash:Destroy()
		ex.ring:Destroy()
		return false
	end
	local camera = self.camera
	local p = camera:screenPos(ex.x, ex.y)
	local rpx = ex.radius * camera.zoom
	-- Flash: full blast disc, gone in the first 40 %.
	local fa = math.clamp(a / 0.4, 0, 1)
	ex.flash.Position = UDim2.fromOffset(p.X, p.Y)
	ex.flash.Size = UDim2.fromOffset(rpx * 2 * (0.6 + 0.4 * fa), rpx * 2 * (0.6 + 0.4 * fa))
	ex.flash.BackgroundTransparency = 0.15 + 0.85 * fa
	-- Shockwave: grows to radius x factor, fading out.
	local ease = 1 - (1 - a) * (1 - a)
	local d = rpx * 2 * SHOCKWAVE_FACTOR * ease
	ex.ring.Position = UDim2.fromOffset(p.X, p.Y)
	ex.ring.Size = UDim2.fromOffset(d, d)
	ex.stroke.Transparency = a
	return true
end

function UnitLayer:_applyStructure(e, u, icon: string)
	if e == nil then
		local frame, g, level, stroke, reload, rfill = makeStructure(self.container, u.id, icon)
		e = { frame = frame, glyph = g, levelLabel = level, stroke = stroke, reload = reload, reloadFill = rfill, isStructure = true, pos = u.pos }
		self.units[u.id] = e
	end
	e.unitType, e.ownerID, e.pos = u.unitType, u.ownerID, u.pos
	e.level = u.level or 1
	e.missileTimers = u.missileTimers
	e.reloadTicks = u.reloadTicks
	e.underConstruction = u.underConstruction == true
	e.buildStart, e.buildTicks = u.buildStart, u.buildTicks
	local color = self.colors[u.ownerID] or Color3.new(1, 1, 1)
	e.frame.BackgroundColor3 = color:Lerp(Color3.new(0, 0, 0), 0.25)
	-- Structures being built are drawn faded until they finish.
	local building = u.underConstruction == true
	e.frame.BackgroundTransparency = if building then 0.55 else 0
	e.stroke.Transparency = if building then 0.5 else 0
	-- Marked for deletion (removed when the 30 s mark expires): red outline.
	e.stroke.Color = if u.markedForDeletion then Color3.fromRGB(230, 70, 70) else Color3.new(1, 1, 1)
	e.stroke.Thickness = if u.markedForDeletion then 2.5 else 1.5
	e.glyph.ImageTransparency = if building then 0.4 else 0
	self:_paintReload(e)
	e.levelLabel.Text = if e.level > 1 then tostring(e.level) else ""
	self:_place(e)
	if self.onChanged then
		self.onChanged()
	end
end

-- Whether a player has any active unit of a type (ships included).
function UnitLayer:hasUnit(ownerID: number, unitType: string): boolean
	for _, e in self.units do
		if e.ownerID == ownerID and e.unitType == unitType then
			return true
		end
	end
	return false
end

-- Own warships within manhattan `radius` of a tile, nearest first
-- (WarshipSelectionController.findWarshipsNearCell).
function UnitLayer:warshipsNear(ownerID: number, tile: number, radius: number): { number }
	local map = self.map
	local found = {}
	for id, e in self.units do
		if e.warship and e.ownerID == ownerID and e.pos then
			local d = math.abs(map:x(e.pos) - map:x(tile)) + math.abs(map:y(e.pos) - map:y(tile))
			if d <= radius then
				table.insert(found, { id = id, d = d })
			end
		end
	end
	table.sort(found, function(a, b)
		return a.d < b.d
	end)
	local ids = {}
	for i, f in found do
		ids[i] = f.id
	end
	return ids
end

function UnitLayer:moveMarker(tile: number)
	local ring, stroke = circle(self.container, "MoveMarker", Color3.fromRGB(34, 211, 238), false)
	stroke.Thickness = 2.5
	ring.ZIndex = 9
	self.markers = self.markers or {}
	table.insert(self.markers, { ring = ring, stroke = stroke, tile = tile, t0 = os.clock() })
end

function UnitLayer:setSelected(id: number?)
	self.selected = id
	for uid, e in self.units do
		if e.warship then
			e.ring.Visible = uid == id
		end
	end
end

-- Our transport boats { id, troops, targetTile } (AttacksDisplay).
function UnitLayer:boatsOf(ownerID: number)
	local out = {}
	for id, e in self.units do
		if e.unitType == "Transport" and e.ownerID == ownerID then
			table.insert(out, { id = id, troops = e.troops or 0, targetTile = e.targetTile })
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

-- Map tile of a live unit, or nil.
function UnitLayer:unitTile(id: number): number?
	local e = self.units[id]
	return e and (e.to or e.pos)
end

function UnitLayer:isActiveUnit(id: number): boolean
	return self.units[id] ~= nil
end

-- Sum of levels of a player's structures of one type (upstream totalUnitLevels).
function UnitLayer:totalLevels(ownerID: number, unitType: string): number
	local n = 0
	for _, e in self.units do
		if e.isStructure and e.ownerID == ownerID and e.unitType == unitType then
			n += e.level
		end
	end
	return n
end

-- Oldest reloading missile's progress; icon dimmed while every missile reloads.
function UnitLayer:_paintReload(e)
	-- BarPass construction progress: the same bar under the icon, filling up
	-- while the structure is built (every structure type, not just silos).
	if e.underConstruction and e.buildStart and e.buildTicks and e.buildTicks > 0 then
		local tick = if self.tickNow then self.tickNow() else 0
		e.reload.Visible = true
		e.reloadFill.Size = UDim2.fromScale(math.clamp((tick - e.buildStart) / e.buildTicks, 0, 1), 1)
		e.reloadFill.BackgroundColor3 = BUILD_BAR
		return
	end
	e.reloadFill.BackgroundColor3 = RELOAD_BAR
	local timers = e.missileTimers
	if timers == nil or e.reloadTicks == nil or e.underConstruction then
		e.reload.Visible = false
		return
	end
	local tick = if self.tickNow then self.tickNow() else 0
	local frac = math.clamp((tick - timers[1]) / e.reloadTicks, 0, 1)
	e.reload.Visible = true
	e.reloadFill.Size = UDim2.fromScale(frac, 1)
	e.glyph.ImageTransparency = if #timers >= e.level then 0.5 else 0
end

-- Whether the player owns a finished silo with a missile ready.
function UnitLayer:siloReady(ownerID: number): boolean
	for _, e in self.units do
		if e.ownerID == ownerID and e.unitType == "Missile Silo" and not e.underConstruction then
			if e.missileTimers == nil or #e.missileTimers < e.level then
				return true
			end
		end
	end
	return false
end

function UnitLayer:_place(e)
	local camera, map = self.camera, self.map
	local size = math.clamp(camera.zoom * 3, MIN_STRUCT, MAX_STRUCT)
	local p = camera:screenPos(map:x(e.pos), map:y(e.pos))
	e.frame.Position = UDim2.fromOffset(p.X, p.Y)
	if e.placedSize ~= size then
		e.placedSize = size
		e.frame.Size = UDim2.fromOffset(size, size)
		e.levelLabel.TextSize = math.max(9, size * 0.5)
	end
end

-- Batched move (Net.UnitPos, every `interval` seconds): glide there over
-- that interval instead of one tick.
function UnitLayer:movePos(id: number, pos: number)
	local e = self.units[id]
	if e == nil or e.isStructure or e.planned then
		return
	end
	if e.to ~= pos then
		-- Start from where the sprite is drawn now, so a late batch never snaps back.
		local map = self.map
		local a = math.clamp((os.clock() - e.t0) / (e.dur or TICK_SECONDS), 0, 1)
		local fx = map:x(e.from) + (map:x(e.to) - map:x(e.from)) * a
		local fy = map:y(e.from) + (map:y(e.to) - map:y(e.from)) * a
		e.from = map:ref(math.floor(fx + 0.5), math.floor(fy + 0.5))
		e.to = pos
		-- Glide over the time since this unit's previous batch (0.2 s for
		-- warships and boats, 0.4 s for trade ships and trains).
		local now = os.clock()
		e.dur = math.clamp(now - (e.lastBatch or now - 0.2), 0.1, 0.5)
		e.lastBatch = now
		e.t0 = now
	end
	e.pos = pos
end

-- Per-frame: interpolate ship positions and scale everything with zoom.
function UnitLayer:render()
	local camera, map = self.camera, self.map
	local now = os.clock()
	local tick = if self.tickNow then self.tickNow() else 0
	-- One sprite pixel per tile (never below one screen pixel).
	local cellPx = Sprites.CELL * math.max(camera.zoom, 1)
	-- Structures never move: re-place them only when the camera did (late in
	-- a match there are thousands, and setting Position / Size / TextSize on
	-- each every frame was a large part of the frame).
	local camMoved = camera.zoom ~= self._camZ or camera.panX ~= self._camX or camera.panY ~= self._camY
	self._camZ, self._camX, self._camY = camera.zoom, camera.panX, camera.panY
	for _, e in self.units do
		if e.isStructure then
			if camMoved then
				self:_place(e)
			end
			if e.missileTimers or e.underConstruction then
				self:_paintReload(e)
			end
			continue
		end
		local x, y
		if e.planned then
			-- Tile index on the plan: 0 = launch tile until startTick.
			local t = math.max(0, tick - e.startTick + 1)
			local n = #e.path
			local i = math.min(math.floor(t), n - 1)
			local frac = if i >= n - 1 then 0 else t - math.floor(t)
			local pa, pb = e.path[i + 1], e.path[math.min(i + 2, n)]
			x = map:x(pa) + (map:x(pb) - map:x(pa)) * frac
			y = map:y(pa) + (map:y(pb) - map:y(pa)) * frac
		else
			local a = math.clamp((now - e.t0) / (e.dur or TICK_SECONDS), 0, 1)
			x = map:x(e.from) + (map:x(e.to) - map:x(e.from)) * a
			y = map:y(e.from) + (map:y(e.to) - map:y(e.from)) * a
		end
		local p = camera:screenPos(x, y)
		e.frame.Position = UDim2.fromOffset(p.X, p.Y)
		if e.placedSize ~= cellPx then
			e.placedSize = cellPx
			e.frame.Size = UDim2.fromOffset(cellPx, cellPx)
		end
		if e.flicker or e.retreating then
			self:_paintSprite(e, tick)
		end
		local tg = e.telegraph
		if tg then
			-- Hidden until the plan starts (NukeTelegraphs skips future launches).
			local live = not e.planned or tick >= e.startTick
			tg.inner.Visible, tg.outer.Visible = live, live
			if live then
				local c = camera:screenPos(map:x(tg.tile) + 0.5, map:y(tg.tile) + 0.5)
				local a = 0.85 + 0.1 * math.sin(now * 3)
				tg.inner.Position = UDim2.fromOffset(c.X, c.Y)
				tg.outer.Position = tg.inner.Position
				tg.inner.Size = UDim2.fromOffset(tg.mag[1] * 2 * camera.zoom, tg.mag[1] * 2 * camera.zoom)
				tg.outer.Size = UDim2.fromOffset(tg.mag[2] * 2 * camera.zoom, tg.mag[2] * 2 * camera.zoom)
				tg.inner.BackgroundTransparency = 1 - math.max(0, a - 0.6)
				tg.innerStroke.Transparency = 1 - a
				tg.outerStroke.Transparency = 1 - a
			end
		end
	end
	if self.markers then
		local keep = {}
		for _, m in self.markers do
			local a = (now - m.t0) / 1.0
			if a >= 1 then
				m.ring:Destroy()
			else
				local c = camera:screenPos(map:x(m.tile), map:y(m.tile))
				local d = 34 * (1 - 0.6 * a)
				m.ring.Position = UDim2.fromOffset(c.X, c.Y)
				m.ring.Size = UDim2.fromOffset(d, d)
				m.stroke.Transparency = a
				table.insert(keep, m)
			end
		end
		self.markers = if #keep > 0 then keep else nil
	end
	if self.explosions then
		local keep = {}
		for _, ex in self.explosions do
			if self:_placeExplosion(ex) then
				table.insert(keep, ex)
			end
		end
		self.explosions = keep
	end
end


-- Owners of nukes in flight (PlayerIcons nuke icon): smallID -> "me" when a
-- bomb lands on our territory (renderer:ownerAt), else true.
local NUKES = { ["Atom Bomb"] = true, ["Hydrogen Bomb"] = true, ["MIRV"] = true, ["MIRV Warhead"] = true }
function UnitLayer:nukeOwners(renderer, mySmallID: number?)
	local out = {}
	for _, e in self.units do
		if NUKES[e.unitType] and e.ownerID then
			local hitsMe = mySmallID ~= nil and e.targetTile ~= nil and renderer:ownerAt(e.targetTile) == mySmallID
			if hitsMe then
				out[e.ownerID] = "me"
			elseif out[e.ownerID] == nil then
				out[e.ownerID] = true
			end
		end
	end
	return out
end
return UnitLayer
