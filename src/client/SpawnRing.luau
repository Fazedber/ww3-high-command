-- The local player's spawn ring, ported from upstream SpawnOverlayPass +
-- spawn-overlay.frag.glsl (render-settings spawnOverlay):
--   * centred on the spawn tile; radii selfMinRad 10 .. selfMaxRad 30 tiles,
--     both scaled 0.5 → 1.15 by the breath (0.5 + 0.5·sin, animSpeed 0.008/ms)
--   * alpha profile: transparent at the centre ramping to solid at the inner
--     radius, solid for the first 10 % of the band, then fading out
--   * colour pulses white → gold (1, 0.84, 0), opacity 65 % → 100 %
-- Shown during the spawn phase and while the tutorial points at "territory".
-- The profile only depends on r / maxR, so it is baked once into a small
-- EditableImage and scaled / tinted per frame.

local AssetService = game:GetService("AssetService")

local MIN_RAD, MAX_RAD = 10, 30
local ANIM_SPEED = 0.008 -- per ms
local SOLID_END = 0.1
local GOLD = Color3.new(0.54, 0.56, 0.94) -- fire palette (was gold)
local SIZE = 256

local SpawnRing = {}
SpawnRing.__index = SpawnRing

local function bakeProfile()
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(SIZE, SIZE) })
	local px = buffer.create(SIZE * SIZE * 4)
	local c = (SIZE - 1) / 2
	local inner = MIN_RAD / MAX_RAD
	for y = 0, SIZE - 1 do
		for x = 0, SIZE - 1 do
			local r = math.sqrt((x - c) ^ 2 + (y - c) ^ 2) / c -- 0..1 at maxR
			local t = (r - inner) / (1 - inner)
			local alpha = 0
			if r < inner then
				alpha = r / inner
			elseif t < SOLID_END then
				alpha = 1
			elseif t < 1 then
				alpha = 1 - (t - SOLID_END) / (1 - SOLID_END)
			end
			local o = (y * SIZE + x) * 4
			buffer.writeu8(px, o, 255)
			buffer.writeu8(px, o + 1, 255)
			buffer.writeu8(px, o + 2, 255)
			buffer.writeu8(px, o + 3, math.floor(math.clamp(alpha, 0, 1) * 255 + 0.5))
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(SIZE, SIZE), px)
	return img
end

function SpawnRing.new(mapLayer: GuiObject, camera, gameMap)
	local label = Instance.new("ImageLabel")
	label.Name = "SpawnRing"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.ImageContent = Content.fromObject(bakeProfile())
	label.ZIndex = 4
	label.Visible = false
	label.Parent = mapLayer
	return setmetatable({ label = label, camera = camera, map = gameMap, tile = nil, animTime = 0, last = os.clock() }, SpawnRing)
end

-- Tile to ring, or nil to hide.
function SpawnRing:set(tile: number?)
	self.tile = tile
	self.label.Visible = tile ~= nil
end

function SpawnRing:render()
	local now = os.clock()
	self.animTime += (now - self.last) * 1000 * ANIM_SPEED
	self.last = now
	if self.tile == nil then
		return
	end
	local breath = 0.5 + 0.5 * math.sin(self.animTime)
	local scale = 0.5 + 0.65 * breath
	local camera, map = self.camera, self.map
	local p = camera:screenPos(map:x(self.tile), map:y(self.tile))
	local d = 2 * MAX_RAD * scale * camera.zoom
	local label = self.label
	label.Position = UDim2.fromOffset(p.X, p.Y)
	label.Size = UDim2.fromOffset(d, d)
	label.ImageColor3 = Color3.new(1, 1, 1):Lerp(GOLD, breath)
	label.ImageTransparency = 1 - (0.78 + 0.22 * breath)
end

return SpawnRing
