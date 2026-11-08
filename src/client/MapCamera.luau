-- Pan / zoom camera over a 2D map made of image tiles, with click detection.
-- Controls match OpenFront: drag to pan, wheel / pinch to zoom toward the
-- cursor, click (press + release without dragging) to act on a tile.

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local ZOOM_STEP = 1.15
local MAX_ZOOM = 40 -- screen pixels per map tile
local DRAG_THRESHOLD = 4 -- pixels before a press becomes a pan

local MapCamera = {}
MapCamera.__index = MapCamera

-- background: full-screen Frame the map is drawn in. W, H: map size in tiles.
function MapCamera.new(background: Frame, W: number, H: number)
	local root = Instance.new("Frame")
	root.Name = "MapRoot"
	root.BackgroundTransparency = 1
	root.Parent = background

	local self = setmetatable({
		background = background,
		root = root,
		W = W,
		H = H,
		zoom = 1,
		panX = 0,
		panY = 0,
		minZoom = 0.1,
		_tiles = {},
		_connections = {},
		onClick = nil :: ((Vector2) -> ())?,
		onTap = nil :: ((Vector2) -> ())?,
		onRightClick = nil :: ((Vector2) -> ())?,
		onShiftScroll = nil :: ((number) -> ())?,
		onHover = nil :: ((Vector2) -> ())?,
		onChanged = nil :: (() -> ())?,
	}, MapCamera)
	self:_bindInput()
	table.insert(
		self._connections,
		background:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:fit()
		end)
	)
	return self
end

-- Registers an image covering map tiles [x0, x0+w) x [y0, y0+h).
function MapCamera:addTile(label: GuiObject, x0: number, y0: number, w: number, h: number)
	label.Parent = self.root
	table.insert(self._tiles, { label = label, x0 = x0, y0 = y0, w = w, h = h })
	self:apply()
end

function MapCamera:apply()
	local zoom = self.zoom
	self.root.Position = UDim2.fromOffset(math.round(self.panX), math.round(self.panY))
	self.root.Size = UDim2.fromOffset(math.round(self.W * zoom), math.round(self.H * zoom))
	-- Snap tile edges to whole pixels so neighbouring tiles never leave a seam.
	for _, t in self._tiles do
		local left = math.floor(t.x0 * zoom)
		local top = math.floor(t.y0 * zoom)
		t.label.Position = UDim2.fromOffset(left, top)
		t.label.Size = UDim2.fromOffset(math.floor((t.x0 + t.w) * zoom) - left, math.floor((t.y0 + t.h) * zoom) - top)
	end
	if self.onChanged then
		self.onChanged()
	end
end

function MapCamera:fit()
	local view = self.background.AbsoluteSize
	if view.X == 0 or view.Y == 0 then
		return
	end
	self.zoom = math.min(view.X / self.W, view.Y / self.H) * 0.95
	self.minZoom = self.zoom * 0.5
	self.panX = (view.X - self.W * self.zoom) / 2
	self.panY = (view.Y - self.H * self.zoom) / 2
	self:apply()
end

-- Set zoom to `newZoom`, keeping the map point under `anchor` (screen px) fixed.
function MapCamera:zoomAt(anchor: Vector2, newZoom: number)
	newZoom = math.clamp(newZoom, self.minZoom, MAX_ZOOM)
	local k = newZoom / self.zoom
	self.panX = anchor.X - (anchor.X - self.panX) * k
	self.panY = anchor.Y - (anchor.Y - self.panY) * k
	self.zoom = newZoom
	self:apply()
end

-- Centre the view on map tile (x, y), zooming in to at least minZoom.
function MapCamera:centerOn(x: number, y: number, minZoom: number?)
	local size = self.background.AbsoluteSize
	self.zoom = math.clamp(math.max(self.zoom, minZoom or 0), self.minZoom, MAX_ZOOM)
	self.panX = size.X / 2 - (x + 0.5) * self.zoom
	self.panY = size.Y / 2 - (y + 0.5) * self.zoom
	self:apply()
end

-- Map coordinates under a screen position (may be off the map).
function MapCamera:mapPos(p: Vector2): (number, number)
	return math.floor((p.X - self.panX) / self.zoom), math.floor((p.Y - self.panY) / self.zoom)
end

-- Screen position of the centre of map tile (x, y).
function MapCamera:screenPos(x: number, y: number): Vector2
	return Vector2.new(self.panX + (x + 0.5) * self.zoom, self.panY + (y + 0.5) * self.zoom)
end

-- Mouse position in the space of an IgnoreGuiInset ScreenGui.
local function mousePos(): Vector2
	return UserInputService:GetMouseLocation()
end

-- Touch InputObject positions exclude the top bar inset; shift them back.
local function touchPos(p: Vector3 | Vector2): Vector2
	return Vector2.new(p.X, p.Y) + GuiService:GetGuiInset()
end

function MapCamera:_bindInput()
	local dragging, dragMoved = false, false
	local dragButton: Enum.UserInputType? = nil
	local dragStart, panStart = Vector2.zero, Vector2.zero
	local panButtons = {
		[Enum.UserInputType.MouseButton1] = true,
		[Enum.UserInputType.MouseButton2] = true,
		[Enum.UserInputType.MouseButton3] = true,
	}

	local function connect(signal, fn)
		table.insert(self._connections, signal:Connect(fn))
	end

	connect(UserInputService.InputBegan, function(input, processed)
		if processed then
			return
		end
		if panButtons[input.UserInputType] then
			dragging, dragMoved = true, false
			dragButton = input.UserInputType
			dragStart = mousePos()
			panStart = Vector2.new(self.panX, self.panY)
		end
	end)

	connect(UserInputService.InputEnded, function(input)
		if panButtons[input.UserInputType] and input.UserInputType == dragButton then
			local still = dragging and not dragMoved
			dragging = false
			dragButton = nil
			if still and input.UserInputType == Enum.UserInputType.MouseButton1 and self.onClick then
				self.onClick(mousePos())
			elseif still and input.UserInputType == Enum.UserInputType.MouseButton2 and self.onRightClick then
				self.onRightClick(mousePos())
			end
		end
	end)

	connect(UserInputService.InputChanged, function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			local p = mousePos()
			if dragging then
				local delta = p - dragStart
				if dragMoved or delta.Magnitude > DRAG_THRESHOLD then
					dragMoved = true
					self.panX = panStart.X + delta.X
					self.panY = panStart.Y + delta.Y
					self:apply()
				end
			end
			if self.onHover then
				self.onHover(p)
			end
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
			-- Shift + wheel changes the attack ratio instead (upstream onShiftScroll).
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
				if self.onShiftScroll then
					self.onShiftScroll(input.Position.Z)
				end
				return
			end
			local factor = if input.Position.Z > 0 then ZOOM_STEP else 1 / ZOOM_STEP
			self:zoomAt(mousePos(), self.zoom * factor)
			if self.onHover then
				self.onHover(mousePos())
			end
		end
	end)

	-- Touch: tap to act, one-finger pan, two-finger pinch zoom.
	connect(UserInputService.TouchTap, function(positions, processed)
		if processed or #positions ~= 1 then
			return
		end
		-- Upstream TouchEvent: touch taps get their own handler (radial menu).
		local handler = self.onTap or self.onClick
		if handler then
			handler(touchPos(positions[1]))
		end
	end)

	local touchPanStart = Vector2.zero
	connect(UserInputService.TouchPan, function(positions, translation, _velocity, state, processed)
		if processed or #positions ~= 1 then
			return
		end
		if state == Enum.UserInputState.Begin then
			touchPanStart = Vector2.new(self.panX, self.panY)
		elseif state == Enum.UserInputState.Change then
			self.panX = touchPanStart.X + translation.X
			self.panY = touchPanStart.Y + translation.Y
			self:apply()
		end
	end)

	local pinchZoom = self.zoom
	connect(UserInputService.TouchPinch, function(positions, scale, _velocity, state, processed)
		if processed or #positions < 2 then
			return
		end
		if state == Enum.UserInputState.Begin then
			pinchZoom = self.zoom
		elseif state == Enum.UserInputState.Change then
			local center = (touchPos(positions[1]) + touchPos(positions[2])) / 2
			self:zoomAt(center, pinchZoom * scale)
		end
	end)
end

function MapCamera:destroy()
	for _, c in self._connections do
		c:Disconnect()
	end
	self.root:Destroy()
end

return MapCamera
