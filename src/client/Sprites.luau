-- Mobile-unit sprites, ported from upstream UnitPass + unit.frag.glsl.
-- The grayscale atlas (tools/pack-sprites.mjs) is split once into four
-- white masks by gray band:
--   > 0.6   (180) territory colour
--   > 0.45  (130) mix(territory, border, 0.5)
--   > 0.34  (100) centre accent (territory, blinking black when retreating)
--   else    (70)  border colour
-- A sprite instance is four stacked ImageLabels (one per band) showing the
-- unit's 13x13 atlas cell, pixelated, one sprite pixel per map tile.

local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")

local Data = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Sprites"))

local Sprites = {}
Sprites.CELL = Data.cell

local COLUMN = {}
for i, name in Data.order do
	COLUMN[name] = i - 1
end

local BANDS = { "territory", "spawn", "center", "border" }
local masks = nil

local function bake()
	local src = EncodingService:Base64Decode(buffer.fromstring(Data.rgba))
	local w, h = Data.width, Data.height
	masks = {}
	local bufs = {}
	for _, band in BANDS do
		bufs[band] = buffer.create(w * h * 4)
	end
	for i = 0, w * h - 1 do
		local o = i * 4
		local a = buffer.readu8(src, o + 3)
		if a >= 3 then
			local gray = buffer.readu8(src, o) / 255
			local band = if gray > 0.6 then "territory" elseif gray > 0.45 then "spawn" elseif gray > 0.34 then "center" else "border"
			local b = bufs[band]
			buffer.writeu8(b, o, 255)
			buffer.writeu8(b, o + 1, 255)
			buffer.writeu8(b, o + 2, 255)
			buffer.writeu8(b, o + 3, a)
		end
	end
	for _, band in BANDS do
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), bufs[band])
		masks[band] = img
	end
end

function Sprites.has(unitType: string): boolean
	return COLUMN[unitType] ~= nil
end

-- A sprite frame for `unitType` (anchor centre). Returns the frame and its
-- band labels { territory, spawn, center, border }. `crop` shows only the
-- centred crop x crop pixels (HUD icons of small sprites).
function Sprites.make(parent: Instance, unitType: string, name: string, crop: number?)
	if masks == nil then
		bake()
	end
	local col = COLUMN[unitType]
	assert(col ~= nil, `no sprite for {unitType}`)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundTransparency = 1
	local bands = {}
	for i, band in BANDS do
		local l = Instance.new("ImageLabel")
		l.Name = band
		l.BackgroundTransparency = 1
		l.Size = UDim2.fromScale(1, 1)
		l.ImageContent = Content.fromObject(masks[band])
		local size = crop or Data.cell
		local inset = (Data.cell - size) // 2
		l.ImageRectOffset = Vector2.new(col * Data.cell + inset, inset)
		l.ImageRectSize = Vector2.new(size, size)
		l.ResampleMode = Enum.ResamplerMode.Pixelated
		l.ZIndex = 6 + i
		l.Parent = frame
		bands[band] = l
	end
	frame.Parent = parent
	return frame, bands
end

-- Colour a sprite's bands (unit.frag.glsl).
function Sprites.paint(bands, territory: Color3, border: Color3, center: Color3?)
	bands.territory.ImageColor3 = territory
	bands.spawn.ImageColor3 = territory:Lerp(border, 0.5)
	bands.center.ImageColor3 = center or territory
	bands.border.ImageColor3 = border
end

function Sprites.setTransparency(bands, t: number)
	for _, l in bands do
		l.ImageTransparency = t
	end
end

-- Nukes / missiles flicker red → orange → yellow → white (flickerSpeed 0.3
-- per tick, per-unit phase offset).
local FLICKER = {
	Color3.new(1, 0, 0),
	Color3.new(1, 0.5, 0),
	Color3.new(1, 1, 0),
	Color3.new(1, 1, 1),
}
function Sprites.flicker(tick: number, hash: number): (Color3, Color3)
	local phase = (tick * 0.3 + hash) % 1
	local idx = math.floor(phase * 4) % 4
	return FLICKER[idx + 1], FLICKER[(idx + 2) % 4 + 1]
end

return Sprites
