-- Game icons from game-icons.net (CC BY 3.0, authors: lorc, delapouite,
-- sbed, skoll and others). Rendered as WHITE glyphs on a transparent background
-- so they can be tinted and they never show a white square.
local Icons = {}

local FIRE = Color3.fromRGB(255, 240, 228)
local WHITE = Color3.new(1, 1, 1)

Icons.ASSETS = {
	city = "rbxassetid://83731987999161",
	factory = "rbxassetid://76040094826642",
	port = "rbxassetid://119088379623981",
	defensePost = "rbxassetid://93260943581706",
	missileSilo = "rbxassetid://103073803665750",
	samLauncher = "rbxassetid://121100759628129",
	warship = "rbxassetid://91225896059012",
	atomBomb = "rbxassetid://85079097627660",
	hydrogenBomb = "rbxassetid://79506063882016",
	mirv = "rbxassetid://108357643342922",
	soldier = "rbxassetid://136976703611578",
	sword = "rbxassetid://118175950523968",
	swordWhite = "rbxassetid://107339591395105",
	goldCoin = "rbxassetid://111078127940488",
	crown = "rbxassetid://92731467740026",
	traitor = "rbxassetid://101300489298072",
	disconnected = "rbxassetid://116043530750829",
	alliance = "rbxassetid://98911931871742",
	allianceRequest = "rbxassetid://103817950839505",
	targetRed = "rbxassetid://128923914928309",
	embargo = "rbxassetid://111343452295944",
	info = "rbxassetid://89023528159416",
	x = "rbxassetid://117154453020256",
	build = "rbxassetid://86911050766851",
	boat = "rbxassetid://130784473489663",
	donateGold = "rbxassetid://114575659942086",
	map = "rbxassetid://128009681573631",
	solo = "rbxassetid://97317368689314",
	online = "rbxassetid://73783191643084",
	duel = "rbxassetid://117398459300658",
	settings = "rbxassetid://122771959167892",
	shop = "rbxassetid://114773835409743",
	flag = "rbxassetid://85866636589363",
	star = "rbxassetid://102861611789756",
	arrowRight = "rbxassetid://118744332698445",
	chevron = "rbxassetid://98986986680790",
	Aa = "rbxassetid://78911896593446",
	sound = "rbxassetid://71542258606131",
}

-- Pixel-art icons drawn in code (clearer than the generic glyphs for the two
-- numbers players read most): gold = coin with a bar, troops = helmeted soldier.
local AssetService = game:GetService("AssetService")
-- Custom pixel glyphs were dropped: they clashed with the game-icons set. Gold and troops use
-- the same icon style as everything else, tinted for quick reading.
local PIXEL = {}
local DEFAULT_TINT = {
	soldier = Color3.fromRGB(150, 224, 120),
	goldCoin = Color3.fromRGB(255, 208, 96),
}
local pixelCache: { [string]: Content? } = {}
local function pixelContent(name: string): Content?
	if pixelCache[name] ~= nil then
		return pixelCache[name]
	end
	local def = PIXEL[name]
	local ok, content = pcall(function()
		local h, w = #def.rows, #def.rows[1]
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
		local px = buffer.create(w * h * 4)
		for y = 1, h do
			for x = 1, w do
				local c = if string.sub(def.rows[y], x, x) == "x" then { 255, 255, 255 } else nil
				if c then
					local o = ((y - 1) * w + (x - 1)) * 4
					buffer.writeu8(px, o, c[1])
					buffer.writeu8(px, o + 1, c[2])
					buffer.writeu8(px, o + 2, c[3])
					buffer.writeu8(px, o + 3, 255)
				end
			end
		end
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), px)
		return Content.fromObject(img)
	end)
	pixelCache[name] = if ok then content else false :: any
	return pixelCache[name]
end
local FALLBACK = Icons.ASSETS.star or Icons.ASSETS.city

function Icons.label(parent: Instance?, name: string, px: number, opts: { white: boolean?, color: Color3? }?): ImageLabel
	local l = Instance.new("ImageLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromOffset(px, px)
	l.Image = Icons.ASSETS[name] or FALLBACK
	l.ScaleType = Enum.ScaleType.Fit
	l.ResampleMode = Enum.ResamplerMode.Default
	if opts and opts.color then
		l.ImageColor3 = opts.color
	elseif opts and opts.white then
		l.ImageColor3 = WHITE
	else
		l.ImageColor3 = FIRE
	end
	local pix = if PIXEL[name] then pixelContent(name) else nil
	if pix then
		l.ImageContent = pix
		l.ImageColor3 = if opts and opts.color then opts.color else PIXEL[name].tint
		l.ResampleMode = Enum.ResamplerMode.Pixelated
	end
	local tint = DEFAULT_TINT[name]
	if tint and not (opts and opts.color) then
		l.ImageColor3 = tint
	end
	l.Parent = parent
	return l
end

return Icons
