-- Country flags (Shared/Data/Flags, from upstream resources/flags) decoded
-- once into one EditableImage; labels show a flag via ImageRectOffset.

local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")

local Flags = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Flags"))

local FlagAtlas = {}
FlagAtlas.codes = Flags.codes
FlagAtlas.names = Flags.names

local index = {}
for i, code in Flags.codes do
	index[code] = i - 1
end

local image: EditableImage? = nil
local function atlas(): EditableImage?
	if image == nil then
		local rows = math.ceil(#Flags.codes / Flags.cols)
		local size = Vector2.new(Flags.cols * Flags.w, rows * Flags.h)
		local ok, img = pcall(function()
			return AssetService:CreateEditableImage({ Size = size })
		end)
		if not ok or img == nil then
			return nil
		end
		img:WritePixelsBuffer(Vector2.zero, size, EncodingService:Base64Decode(buffer.fromstring(Flags.rgba)))
		image = img
	end
	return image
end

-- Point an ImageLabel at a flag (nil code hides it).
function FlagAtlas.apply(label: ImageLabel, code: string?)
	local i = code and index[code]
	local img = i and atlas()
	if img == nil then
		label.Visible = false
		return
	end
	label.ImageContent = Content.fromObject(img)
	label.ImageRectOffset = Vector2.new((i % Flags.cols) * Flags.w, (i // Flags.cols) * Flags.h)
	label.ImageRectSize = Vector2.new(Flags.w, Flags.h)
	label.ResampleMode = Enum.ResamplerMode.Pixelated
	label.Visible = true
end

return FlagAtlas
