-- Client entry point: receives the match from the server, draws the map and
-- territories, and turns clicks into intents (spawn / attack), like OpenFront.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ColorAllocator = require(Shared:WaitForChild("ColorAllocator"))
local GameMap = require(Shared:WaitForChild("GameMap"))
local MapLoader = require(Shared:WaitForChild("MapLoader"))
local Net = require(Shared:WaitForChild("Net"))
local TerrainColors = require(Shared:WaitForChild("TerrainColors"))
local Shop = require(Shared:WaitForChild("Data"):WaitForChild("Shop"))

-- PlayerScripts are copied one by one: wait for every client module before
-- requiring any (modules require their siblings without WaitForChild).
-- tools/build.mjs checks this list against src/client.
local CLIENT_MODULES = { "ShopScreen", "HighCommand", "LeaderSelect", "Locale", "Audio", "AttacksDisplay", "BuildMenu", "ChatModal", "ControlPanel", "EmojiTable", "EventsDisplay", "FlagAtlas", "Hud", "Icons", "Lang", "LobbyScreen", "MapCamera", "Modal", "NameLayer", "NukePreview", "PlayerPanel", "RadialMenu", "SendResourceModal", "SpawnRing", "Sprites", "Style", "TerritoryRenderer", "TutorialPanel", "UnitLayer", "WorldText" }
for _, name in CLIENT_MODULES do
	script.Parent:WaitForChild(name)
end

local Lang = require(script.Parent:WaitForChild("Lang"))
local Locale = require(script.Parent:WaitForChild("Locale"))
Lang.init() -- before any GUI exists, so auto-localisation sees every label
local Audio = require(script.Parent:WaitForChild("Audio"))
local AttacksDisplay = require(script.Parent:WaitForChild("AttacksDisplay"))
local BuildMenu = require(script.Parent:WaitForChild("BuildMenu"))
local ControlPanel = require(script.Parent:WaitForChild("ControlPanel"))
local EventsDisplay = require(script.Parent:WaitForChild("EventsDisplay"))
local Icons = require(script.Parent:WaitForChild("Icons"))
local Format = require(Shared:WaitForChild("Format"))
local Hud = require(script.Parent:WaitForChild("Hud"))
local LobbyScreen = require(script.Parent:WaitForChild("LobbyScreen"))
local MapCamera = require(script.Parent:WaitForChild("MapCamera"))
local NameLayer = require(script.Parent:WaitForChild("NameLayer"))
local NukePreview = require(script.Parent:WaitForChild("NukePreview"))
local TerritoryRenderer = require(script.Parent:WaitForChild("TerritoryRenderer"))
local RadialMenu = require(script.Parent:WaitForChild("RadialMenu"))
local SpawnRing = require(script.Parent:WaitForChild("SpawnRing"))
local TutorialPanel = require(script.Parent:WaitForChild("TutorialPanel"))
local UnitLayer = require(script.Parent:WaitForChild("UnitLayer"))
local WorldText = require(script.Parent:WaitForChild("WorldText"))
local PlayerPanel = require(script.Parent:WaitForChild("PlayerPanel"))
local EmojiTable = require(script.Parent:WaitForChild("EmojiTable"))
local ChatModal = require(script.Parent:WaitForChild("ChatModal"))

local player = Players.LocalPlayer
workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
-- Keys 1..0 are build hotkeys (upstream), not backpack slots.
game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
-- Our own leaderboard replaces Roblox's player list (it covered the top right).
game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
-- No avatar: hide the touch thumbstick and jump button.
game:GetService("GuiService").TouchControlsEnabled = false

-- GUI ----------------------------------------------------------------------------

-- Roblox's own chat/player list used to draw over the HUD (a dark chat button
-- sat right on top of the leader card), so hide them for this game.
pcall(function()
	local StarterGui = game:GetService("StarterGui")
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
end)
pcall(function()
	local tcs = game:GetService("TextChatService")
	tcs.ChatWindowConfiguration.Enabled = false
	tcs.ChatInputBarConfiguration.Enabled = false
end)
task.defer(function()
	local chat = Players.LocalPlayer:WaitForChild("PlayerGui"):FindFirstChild("Chat")
	if chat then
		chat.Enabled = false
	end
end)

local gui = Instance.new("ScreenGui")
gui.Name = "OpenFront"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local bg = { 10, 10, 28 } -- matches TerritoryRenderer.PALETTE.backgroundColor
local background = Instance.new("Frame")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.BackgroundColor3 = Color3.fromRGB(bg[1], bg[2], bg[3])
background.BorderSizePixel = 0
background.Parent = gui

-- CRT scanlines over the battlefield (digital-war look).
local staleCrt = Players.LocalPlayer:WaitForChild("PlayerGui"):FindFirstChild("CRT")
if staleCrt then
	staleCrt:Destroy()
end
local crt = Instance.new("ScreenGui")
crt.Name = "CRT"
crt.IgnoreGuiInset = true
crt.ResetOnSpawn = false
crt.DisplayOrder = 1000
crt.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
local crtScan = Instance.new("ImageLabel")
crtScan.Name = "Scanlines"
crtScan.Size = UDim2.fromScale(1, 1)
crtScan.BackgroundTransparency = 1
crtScan.Image = "rbxassetid://91232121836387"
crtScan.ScaleType = Enum.ScaleType.Tile
crtScan.TileSize = UDim2.fromOffset(8, 8)
crtScan.ImageTransparency = 0.86
crtScan.Parent = crt

-- Spawn marker: big pulsing crosshair drawn above everything (even above the
-- leader picker), so the player always sees the chosen spawn point.
local staleMarker = Players.LocalPlayer:WaitForChild("PlayerGui"):FindFirstChild("SpawnMarker")
if staleMarker then
	staleMarker:Destroy()
end
local markerGui = Instance.new("ScreenGui")
markerGui.Name = "SpawnMarker"
markerGui.IgnoreGuiInset = true
markerGui.ResetOnSpawn = false
markerGui.DisplayOrder = 470
markerGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
local marker = Instance.new("Frame")
marker.Name = "Marker"
marker.AnchorPoint = Vector2.new(0.5, 0.5)
marker.Size = UDim2.fromOffset(64, 64)
marker.BackgroundTransparency = 1
marker.Visible = false
marker.ZIndex = 5
marker.Parent = markerGui
local markerRing = Instance.new("Frame")
markerRing.Size = UDim2.fromScale(1, 1)
markerRing.BackgroundTransparency = 1
markerRing.Parent = marker
local ringCorner = Instance.new("UICorner")
ringCorner.CornerRadius = UDim.new(1, 0)
ringCorner.Parent = markerRing
local ringStroke = Instance.new("UIStroke")
ringStroke.Color = Color3.fromRGB(138, 143, 240)
ringStroke.Thickness = 3
ringStroke.Parent = markerRing
local markerDot = Instance.new("Frame")
markerDot.Size = UDim2.fromOffset(8, 8)
markerDot.AnchorPoint = Vector2.new(0.5, 0.5)
markerDot.Position = UDim2.fromScale(0.5, 0.5)
markerDot.BackgroundColor3 = Color3.fromRGB(255, 240, 228)
markerDot.BorderSizePixel = 0
markerDot.Parent = marker
local markerLabel = Instance.new("TextLabel")
markerLabel.Name = "Label"
markerLabel.AnchorPoint = Vector2.new(0.5, 1)
markerLabel.Position = UDim2.new(0.5, 0, 0, -8)
markerLabel.Size = UDim2.fromOffset(180, 20)
markerLabel.BackgroundColor3 = Color3.fromRGB(12, 8, 6)
markerLabel.BackgroundTransparency = 0.15
markerLabel.BorderSizePixel = 0
markerLabel.Font = Enum.Font.Arcade
markerLabel.TextSize = 13
markerLabel.TextColor3 = Color3.fromRGB(242, 201, 160)
markerLabel.Text = ""
markerLabel.Parent = marker
local markerCorner = Instance.new("UICorner")
markerCorner.CornerRadius = UDim.new(0, 2)
markerCorner.Parent = markerLabel
for _, side in ipairs({ "Top", "Bottom", "Left", "Right" }) do
	local bar = Instance.new("Frame")
	bar.BackgroundColor3 = Color3.fromRGB(138, 143, 240)
	bar.BorderSizePixel = 0
	bar.ZIndex = 6
	bar.Parent = marker
	if side == "Top" or side == "Bottom" then
		bar.Size = UDim2.fromOffset(2, 12)
		bar.AnchorPoint = Vector2.new(0.5, 0)
		bar.Position = if side == "Top" then UDim2.new(0.5, 0, 0, -14) else UDim2.new(0.5, 0, 1, 2)
	else
		bar.Size = UDim2.fromOffset(12, 2)
		bar.AnchorPoint = Vector2.new(0, 0.5)
		bar.Position = if side == "Left" then UDim2.new(0, -14, 0.5, 0) else UDim2.new(1, 2, 0.5, 0)
	end
end
-- On-map copy (same local coordinate space as SpawnRing, which is known-good).
local mapMarker = marker:Clone()
mapMarker.Name = "MapMarker"
mapMarker.Visible = false
mapMarker.ZIndex = 7
for _, d in ipairs(mapMarker:GetDescendants()) do
	if d:IsA("GuiObject") then
		d.ZIndex = (d.ZIndex or 0) + 2
	end
end
mapMarker.Parent = background
local mapRingStroke = mapMarker:FindFirstChild("Frame") and mapMarker.Frame:FindFirstChildWhichIsA("UIStroke")
local mapRingFrame = mapMarker:FindFirstChild("Frame")
if mapRingFrame then
	local st = mapRingFrame:FindFirstChildWhichIsA("UIStroke")
	if st then
		mapRingStroke = st
	end
end

task.spawn(function()
	local t = 0
	while markerGui.Parent do
		t += 0.06
		local k = 0.5 + 0.5 * math.sin(t * 3)
		ringStroke.Transparency = 0.1 + 0.35 * k
		if mapRingStroke then
			mapRingStroke.Transparency = 0.1 + 0.35 * k
		end
		task.wait(0.06)
	end
end)

local hud = Hud.new(gui)
local audioButton = Audio.button(gui, hud.board)
-- Surrender (not in upstream): give up the land and watch / play again.
local surrenderButton = Instance.new("TextButton")
surrenderButton.Name = "Surrender"
surrenderButton.AnchorPoint = Vector2.new(1, 0)
surrenderButton.Size = UDim2.fromOffset(0, 40)
surrenderButton.AutomaticSize = Enum.AutomaticSize.X
surrenderButton.BackgroundColor3 = Color3.fromRGB(10, 12, 32)
surrenderButton.BackgroundTransparency = 0.03
surrenderButton.Font = Enum.Font.Arcade
surrenderButton.TextSize = 15
surrenderButton.TextColor3 = Color3.fromRGB(244, 236, 226)
surrenderButton.Text = Locale.pick("СДАТЬСЯ", "SURRENDER")
surrenderButton.Visible = false
surrenderButton.ZIndex = 50
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 2)
	c.Parent = surrenderButton
	local inner = Instance.new("UIStroke")
	inner.Color = Color3.fromRGB(38, 42, 92)
	inner.Thickness = 2
	inner.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	inner.Parent = surrenderButton
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 12), UDim.new(0, 12)
	pad.Parent = surrenderButton
	local function follow()
		surrenderButton.Position = audioButton.Position - UDim2.fromOffset(48, 0)
	end
	audioButton:GetPropertyChangedSignal("Position"):Connect(follow)
	follow()
end
surrenderButton.Parent = gui
Audio.startMusic()
do
	local pendingSave = nil
	Audio.onChange(function(music, effects)
		-- Save once the player stops clicking.
		pendingSave = { music = music, effects = effects }
		local mine = pendingSave
		task.delay(1.5, function()
			if pendingSave == mine then
				Net.Intent:FireServer({ type = "audio_settings", music = music, effects = effects })
			end
		end)
	end)
end
hud:setCountdown("…", "Waiting for the match to start")
local controlPanel = ControlPanel.new(gui)
gui.Parent = player:WaitForChild("PlayerGui")

-- Match state --------------------------------------------------------------------

-- Lobby until the server starts the match (or we join one in progress).
local lobbyScreen = LobbyScreen.new(gui, Net)
local HighCommand = require(script.Parent:WaitForChild("HighCommand"))
local LeaderSelect = require(script.Parent:WaitForChild("LeaderSelect"))
local LeadersData = require(Shared:WaitForChild("Data"):WaitForChild("Leaders"))
local FlagAtlas = require(script.Parent:WaitForChild("FlagAtlas"))
local highCommand = nil
local leaderSelect = nil
local myIdentity = nil
local pendingSpawnTile: number? = nil
local hoverSpawnTile: number? = nil
local spawnCountdownActive = false
local spawnQueued = false
local spawnQueuedAt = 0
local spawnNoticeUntil = 0
local buildLeaderSelectFn: (() -> ())? = nil

-- Return to the High Command main menu (defeat / victory / HUD menu button).
local function goToMainMenu()
	hud.modal.Visible = false
	if highCommand then
		highCommand:show("MAIN")
	end
end

-- Locale switch rebuilds both screens. HighCommand must exist before the
-- blocking GameState wait, otherwise the main menu only appears after a match.
local function rebuildLocaleUI()
	local ok, err = pcall(function()
		local wasInMatch = highCommand ~= nil and highCommand.inMatch == true
		if highCommand ~= nil and highCommand.gui ~= nil then
			highCommand.gui:Destroy()
		end
		highCommand = HighCommand.new(Net, lobbyScreen, { onLocaleChange = rebuildLocaleUI })
		if wasInMatch then
			highCommand:setMatchActive(true)
		end
		if buildLeaderSelectFn ~= nil then
			buildLeaderSelectFn()
		end
	end)
	if not ok then
		warn("[HighCommand] " .. tostring(err))
	end
end
rebuildLocaleUI()
local state = Net.GameState.OnClientEvent:Wait()
-- A match is already running: the main menu must not cover it (this also
-- covers joining a match in progress / a fresh match after "new game").
if highCommand then
	highCommand:setMatchActive(true)
	highCommand:hide()
end
Audio.load(state.audio)
lobbyScreen:destroy()
-- The server replicates only the selected map.
local gameMap, _mini, manifest = MapLoader.load(Shared:WaitForChild("Maps"):WaitForChild(state.mapId))
local W, H = gameMap:width(), gameMap:height()

local camera = MapCamera.new(background, W, H)
local renderer = TerritoryRenderer.new(camera, gameMap)
local nameLayer = NameLayer.new(background, camera)
local unitLayer = UnitLayer.new(background, camera, gameMap)
local nukePreview = NukePreview.new(background, camera, gameMap)
camera.onChanged = function()
	nameLayer:refresh()
	unitLayer:render()
	if nukePreview.data then
		nukePreview:render()
	end
end
if RunService:IsStudio() then
	-- Test hook (Studio only), like the server's _G.OpenFront.
	_G.OpenFrontClient = { camera = camera, renderer = renderer, unitLayer = unitLayer }
end
local theme = ColorAllocator.Theme.new()

local roster = {} -- smallID -> entry
local stats = {} -- smallID -> { tiles, troops, gold }
local mySmallID: number? = nil
local inSpawnPhase = state.inSpawnPhase
local spawnPhaseTurns = state.spawnPhaseTurns
local tickBase, tickClock = state.tick, os.clock()
local gameOver = false
local haveSpawned = false -- seen our own territory at least once
local shownDeath = false
local matchEndsAt: number? = nil -- set when the match is over

-- ThemeProvider.borderColor for a custom colour: HSL lightness - 0.125
-- (colord darken(borderDarken)).
local function borderColor(rgb: { number }): { number }
	local r, g, b = rgb[1] / 255, rgb[2] / 255, rgb[3] / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local l = (mx + mn) / 2
	local h, s = 0, 0
	if mx ~= mn then
		local d = mx - mn
		s = if l > 0.5 then d / (2 - mx - mn) else d / (mx + mn)
		if mx == r then
			h = (g - b) / d + (if g < b then 6 else 0)
		elseif mx == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h /= 6
	end
	l = math.max(0, l - 0.125)
	local function hue(p, q, t)
		t %= 1
		if t < 1 / 6 then
			return p + (q - p) * 6 * t
		elseif t < 1 / 2 then
			return q
		elseif t < 2 / 3 then
			return p + (q - p) * (2 / 3 - t) * 6
		end
		return p
	end
	if s == 0 then
		local v = math.floor(l * 255 + 0.5)
		return { v, v, v }
	end
	local q = if l < 0.5 then l * (1 + s) else l + s - l * s
	local p = 2 * l - q
	return {
		math.floor(hue(p, q, h + 1 / 3) * 255 + 0.5),
		math.floor(hue(p, q, h) * 255 + 0.5),
		math.floor(hue(p, q, h - 1 / 3) * 255 + 0.5),
	}
end

local function addPlayers(entries)
	for _, e in entries do
		roster[e.smallID] = e
		local c = theme:territoryColor(e.id, e.type, e.team)
		local cos0 = e.cosmetics
		if cos0 and cos0.color and e.team == nil then
			-- Custom colour pass (free for all only; teams keep team colours).
			c = { rgb = cos0.color, border = borderColor(cos0.color) }
		end
		renderer:setPlayerColor(e.smallID, c.rgb, c.border)
		nameLayer:setPlayer(e.smallID, e.name, c.rgb, e.type == "BOT")
		unitLayer:setOwnerColor(e.smallID, c.rgb, c.border)
		local cos = e.cosmetics
		local pattern = cos and cos.pattern and Shop.byId[cos.pattern]
		renderer:setPattern(e.smallID, pattern and pattern.rows, pattern and pattern.scale)
		nameLayer:setNameColor(e.smallID, cos and cos.nameColor)
		nameLayer:setFlag(e.smallID, cos and cos.flag)
		local blast = cos and cos.explosion and Shop.byId[cos.explosion]
		unitLayer.explosionColors = unitLayer.explosionColors or {}
		unitLayer.explosionColors[e.smallID] = blast and {
			flash = Color3.fromRGB(blast.flash[1], blast.flash[2], blast.flash[3]),
			ring = Color3.fromRGB(blast.ring[1], blast.ring[2], blast.ring[3]),
		} or nil
		if e.clientID == state.yourClientID then
			mySmallID = e.smallID
			renderer:setLocalPlayer(e.smallID)
		end
	end
end

addPlayers(state.players)
renderer:loadState(Net.unwrap(state.tiles))
Net.unpackNames(state.names, function(smallID, x, y, size)
	nameLayer:setPlacement(smallID, x, y, size)
end)
-- Units already in the match when we joined: no build/launch cues for them.
local seenUnits = {}
-- Defense coverage (Renderer.updateStructures): finished posts only.
local function defensePost(u)
	if u.unitType == "Defense Post" then
		local live = u.isActive and not u.underConstruction
		renderer:setDefensePost(u.id, if live then u.pos else nil, u.ownerID)
	end
end
for _, u in state.units or {} do
	seenUnits[u.id] = true
	defensePost(u)
	unitLayer:apply(u)
end

-- Railroads (upstream RailroadCache): id -> tiles, drawn by the renderer.
local railroads = {}
local function applyRails(remove, add)
	for _, id in remove or {} do
		local tiles = railroads[id]
		if tiles then
			railroads[id] = nil
			renderer:addRail(tiles, -1)
		end
	end
	for _, r in add or {} do
		if railroads[r.id] == nil then
			railroads[r.id] = r.tiles
			renderer:addRail(r.tiles, 1)
		end
	end
end
applyRails(nil, state.rails)
camera:fit()

local function estimatedTick(): number
	return tickBase + math.floor((os.clock() - tickClock) * 10)
end

-- Fractional tick for motion-plan playback (capped one tick ahead of the last update).
unitLayer.tickNow = function(): number
	return tickBase + math.min((os.clock() - tickClock) * 10, 1.5)
end

local terrainNames = {}
for name, value in GameMap.TerrainType do
	terrainNames[value] = name
end

local function tileAtScreen(p: Vector2): number?
	local x, y = camera:mapPos(p)
	if gameMap:isValidCoord(x, y) then
		return gameMap:ref(x, y)
	end
	return nil
end

local function myStats()
	return mySmallID and stats[mySmallID]
end

local myInfo = { disabled = state.disabledUnits or {} } -- latest Net.Me payload
local playAgain
local showDeathModal: () -> () -- defined with the event handlers below

-- Launcher vs local player (NukeTelegraphs.classifyOwner): 0 = self,
-- 1 = teammate or ally, 2 = everyone else (and everything when spectating).
local function relationOf(smallID: number): number
	if mySmallID == nil then
		return 2
	elseif smallID == mySmallID then
		return 0
	end
	local me, them = roster[mySmallID], roster[smallID]
	if me and them and me.team ~= nil and me.team == them.team then
		return 1
	end
	for _, a in myInfo.alliances or {} do
		if a.other == smallID then
			return 1
		end
	end
	return 2
end
unitLayer.relationOf = relationOf
local myBordering = nil -- set of smallIDs we share a border with
local refreshNameIcons -- defined with the name icons below
local shields = {} -- smallID -> os.clock() the Rebirth shield ends

local buildMenu = BuildMenu.new({
	gui = gui,
	hotbarParent = controlPanel.hotbarParent,
	camera = camera,
	map = gameMap,
	net = Net,
	unitLayer = unitLayer,
	tileAt = tileAtScreen,
	mousePos = function()
		return game:GetService("UserInputService"):GetMouseLocation()
	end,
	mySmallID = function()
		return mySmallID
	end,
	myColor = function()
		return mySmallID and unitLayer.colors[mySmallID]
	end,
	-- Upstream hides the build bar during the spawn phase and once we are dead.
	canAct = function()
		local mine = myStats()
		return not inSpawnPhase and not gameOver and mine ~= nil and mine.tiles > 0
	end,
})
unitLayer.onChanged = function()
	buildMenu:refresh()
end

local UserInputService = game:GetService("UserInputService")

-- TutorialPanel.buildContext
local function tutorialContext()
	if mySmallID == nil then
		return nil
	end
	local mine = myStats()
	local disabled = myInfo.disabled or {}
	local costs = myInfo.costs or {}
	local botsExist, nationsExist = false, false
	for smallID, e in roster do
		local s = stats[smallID]
		if s and s.tiles > 0 then
			botsExist = botsExist or e.type == "BOT"
			nationsExist = nationsExist or e.type == "NATION"
		end
	end
	local function has(unitType)
		return unitLayer:totalLevels(mySmallID, unitType)
	end
	return {
		dead = haveSpawned and not inSpawnPhase and (mine == nil or mine.tiles == 0),
		hasSpawned = haveSpawned,
		inSpawnPhase = inSpawnPhase,
		attacking = myInfo.attacking == true,
		boatsDisabled = false,
		boatAfloat = unitLayer:hasUnit(mySmallID, "Transport"),
		botsExist = botsExist,
		nationsExist = nationsExist,
		alliancesDisabled = state.alliancesDisabled == true,
		allied = myInfo.allied == true,
		gold = if mine then mine.gold else 0,
		costs = costs,
		cityCost = costs.City,
		cityDisabled = disabled.City == true,
		cities = has("City"),
		portDisabled = disabled.Port == true,
		ports = has("Port"),
		defensePostDisabled = disabled["Defense Post"] == true,
		defensePosts = has("Defense Post"),
		factoryDisabled = disabled.Factory == true,
		factories = has("Factory"),
		warshipDisabled = disabled.Warship == true,
		warships = if unitLayer:hasUnit(mySmallID, "Warship") then 1 else 0,
		siloDisabled = disabled["Missile Silo"] == true,
		silos = has("Missile Silo"),
		atomDisabled = disabled["Atom Bomb"] == true,
		siloReady = unitLayer:siloReady(mySmallID),
		atomInFlight = unitLayer:hasUnit(mySmallID, "Atom Bomb"),
		hydrogenDisabled = disabled["Hydrogen Bomb"] == true,
		mirvDisabled = disabled.MIRV == true,
		samDisabled = disabled["SAM Launcher"] == true,
	}
end

-- Tutorial panel removed (template leftovers): no-op stub for the call sites.
local tutorial = {
	setAttackRatio = function() end,
	wantsSpawnRing = function()
		return false
	end,
	renderOverlays = function() end,
}
tutorial:setAttackRatio(controlPanel.ratio)
controlPanel.onRatioChanged = function(ratio)
	tutorial:setAttackRatio(ratio)
end
camera.onShiftScroll = function(z)
	controlPanel:shiftScroll(z)
end

local spawnRing = SpawnRing.new(background, camera, gameMap)

-- SPAWN TERRITORY PREVIEW: the exact flood-filled spawn tiles (radius 4 around
-- the clicked tile), painted immediately while the player is choosing.
local spawnPreviewLayer = Instance.new("Frame")
spawnPreviewLayer.Name = "SpawnPreview"
spawnPreviewLayer.Size = UDim2.fromScale(1, 1)
spawnPreviewLayer.BackgroundTransparency = 1
spawnPreviewLayer.ZIndex = 6
spawnPreviewLayer.Parent = background
local spawnPreviewFrames = {}
for i = 1, 160 do
	local f = Instance.new("Frame")
	f.Name = "Tile" .. i
	f.AnchorPoint = Vector2.new(0, 0)
	f.BackgroundColor3 = Color3.fromRGB(138, 143, 240)
	f.BackgroundTransparency = 0.5
	f.BorderSizePixel = 0
	f.Visible = false
	f.ZIndex = 6
	f.Parent = spawnPreviewLayer
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(190, 196, 255)
	st.Thickness = 1
	st.Transparency = 0.35
	st.Parent = f
	spawnPreviewFrames[i] = f
end
local spawnPreviewCache = { center = nil, tiles = nil }
-- Reticle: a fixed-minimum-size pixel square around the chosen spot, so it is
-- visible even at world zoom where the 4-tile territory is ~1 px.
local spawnReticle = Instance.new("Frame")
spawnReticle.Name = "SpawnReticle"
spawnReticle.AnchorPoint = Vector2.new(0.5, 0.5)
spawnReticle.BackgroundTransparency = 1
spawnReticle.BorderSizePixel = 0
spawnReticle.Visible = false
spawnReticle.ZIndex = 7
spawnReticle.Parent = spawnPreviewLayer
local reticleCorner = Instance.new("UICorner")
reticleCorner.CornerRadius = UDim.new(0.5, 0)
reticleCorner.Parent = spawnReticle
local reticleStroke = Instance.new("UIStroke")
reticleStroke.Color = Color3.fromRGB(236, 232, 255)
reticleStroke.Thickness = 2
reticleStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
reticleStroke.Parent = spawnReticle
-- centre dot + expanding "radar ping" ring (military-map language)
local reticleDot = Instance.new("Frame")
reticleDot.AnchorPoint = Vector2.new(0.5, 0.5)
reticleDot.Position = UDim2.fromScale(0.5, 0.5)
reticleDot.Size = UDim2.fromOffset(6, 6)
reticleDot.BackgroundColor3 = Color3.fromRGB(236, 232, 255)
reticleDot.BorderSizePixel = 0
reticleDot.ZIndex = 8
reticleDot.Parent = spawnReticle
local spawnPing = Instance.new("Frame")
spawnPing.Name = "SpawnPing"
spawnPing.AnchorPoint = Vector2.new(0.5, 0.5)
spawnPing.BackgroundTransparency = 1
spawnPing.BorderSizePixel = 0
spawnPing.Visible = false
spawnPing.ZIndex = 7
spawnPing.Parent = spawnPreviewLayer
local pingCorner = Instance.new("UICorner")
pingCorner.CornerRadius = UDim.new(0.5, 0)
pingCorner.Parent = spawnPing
local pingStroke = Instance.new("UIStroke")
pingStroke.Color = Color3.fromRGB(190, 196, 255)
pingStroke.Thickness = 2
pingStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
pingStroke.Parent = spawnPing
local function updateSpawnPreview(center: number?)
	if center == nil then
		for _, f in ipairs(spawnPreviewFrames) do
			f.Visible = false
		end
		spawnReticle.Visible = false
		spawnPing.Visible = false
		return
	end
	do
		-- Centre the marker on the preview shape itself (its centroid), not the raw click tile.
		local cx, cy = nil, nil
		if spawnPreviewCache.center == center then
			cx, cy = spawnPreviewCache.cx, spawnPreviewCache.cy
		end
		if cx == nil then
			cx, cy = gameMap:x(center), gameMap:y(center)
		end
		local rp = camera:screenPos(cx, cy)
		local beat = 0.5 + 0.5 * math.sin(os.clock() * 5)
		local side = math.max(22, 9 * camera.zoom) + 3 * beat
		local locked = pendingSpawnTile ~= nil
		local tint = if locked then Color3.fromRGB(242, 201, 160) else Color3.fromRGB(236, 232, 255)
		spawnReticle.Position = UDim2.fromOffset(rp.X, rp.Y)
		spawnReticle.Size = UDim2.fromOffset(side, side)
		reticleStroke.Color = tint
		reticleDot.BackgroundColor3 = tint
		spawnReticle.Visible = true
		-- ping: a ring grows out of the reticle and fades (faster once locked in)
		local phase = (os.clock() * (if locked then 1.4 else 0.8)) % 1
		local ps = side * (1 + 1.8 * phase)
		spawnPing.Position = UDim2.fromOffset(rp.X, rp.Y)
		spawnPing.Size = UDim2.fromOffset(ps, ps)
		pingStroke.Color = tint
		pingStroke.Transparency = phase
		spawnPing.Visible = true
	end
	if spawnPreviewCache.center ~= center then
		spawnPreviewCache.center = center
		local tiles = {}
		local ok = pcall(function()
			local arr = gameMap:bfs(center, GameMap.euclDistFN(center, 4, true)):toArray()
			for _, t in ipairs(arr) do
				if not gameMap:hasOwner(t) and gameMap:isLand(t) and not gameMap:isImpassable(t) then
					table.insert(tiles, t)
				end
			end
		end)
		spawnPreviewCache.tiles = if ok then tiles else {}
		local sx, sy, n = 0, 0, 0
		for _, tl in ipairs(spawnPreviewCache.tiles) do
			sx += gameMap:x(tl)
			sy += gameMap:y(tl)
			n += 1
		end
		if n > 0 then
			spawnPreviewCache.cx, spawnPreviewCache.cy = sx / n, sy / n
		else
			spawnPreviewCache.cx, spawnPreviewCache.cy = nil, nil
		end
	end
	local tiles = spawnPreviewCache.tiles or {}
	local z = camera.zoom
	-- Soft pulse; a locked-in (pending) spot reads stronger than a mere hover.
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * 5)
	local alpha = if pendingSpawnTile ~= nil then 0.38 + 0.12 * pulse else 0.58 + 0.14 * pulse
	for i, f in ipairs(spawnPreviewFrames) do
		local t = tiles[i]
		if t then
			local p = camera:screenPos(gameMap:x(t), gameMap:y(t))
			f.Position = UDim2.fromOffset(p.X - z / 2, p.Y - z / 2)
			f.Size = UDim2.fromOffset(z, z)
			f.BackgroundTransparency = alpha
			f.Visible = true
		else
			f.Visible = false
		end
	end
end
local worldText = WorldText.new(background, camera)

local function focusPlayer(smallID: number)
	local x, y = nameLayer:placement(smallID)
	if x then
		camera:centerOn(x, y, 3)
	end
end
local function focusUnit(id: number)
	local tile = unitLayer:unitTile(id)
	if tile then
		camera:centerOn(gameMap:x(tile), gameMap:y(tile), 3)
	end
end
local function playerName(smallID: number): string?
	local e = roster[smallID]
	return e and e.name
end
local function hudVisible(): boolean
	local mine = myStats()
	return not inSpawnPhase and not gameOver and mine ~= nil and mine.tiles > 0
end

local eventsDisplay = EventsDisplay.new({
	gui = gui,
	tickNow = function()
		return tickBase + (os.clock() - tickClock) * 10
	end,
	unitActive = function(id)
		return unitLayer:isActiveUnit(id)
	end,
	playerName = playerName,
	focusPlayer = focusPlayer,
	focusUnit = focusUnit,
	visible = hudVisible,
	sendIntent = function(t)
		Net.Intent:FireServer(t)
	end,
	alive = function()
		local mine = myStats()
		return mine ~= nil and mine.tiles > 0
	end,
})

-- Edge layout: the events feed floats above the bottom HUD (it used to cover
-- the unit hotbar on the right side).
do
	local feed = eventsDisplay
	local function placeFeed()
		local hudHeight = controlPanel and controlPanel.column and controlPanel.column.AbsoluteSize.Y or 170
		local w = math.max(220, math.min(384, gui.AbsoluteSize.X - 24))
		feed.column.Size = UDim2.fromOffset(w, 0)
		feed.column.Position = UDim2.new(1, -8, 1, -(hudHeight + 16))
	end
	placeFeed()
	if controlPanel and controlPanel.column then
		controlPanel.column:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeFeed)
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeFeed)
end

-- uiState.rocketDirectionUp (PlayerPanel toggle, sent with nuke placements).
local rocketUp = true
buildMenu.deps.rocketUp = function()
	return rocketUp
end
buildMenu.deps.renderer = renderer

-- BuildPreviewController.updateNukeTrajectoryPreview: arc from the nearest
-- ready silo (Manhattan, like PlayerImpl.nukeSpawn) to the hovered tile,
-- with every SAM that would engage (not ours, not a teammate or ally).
local NUKE_PREVIEW = { ["Atom Bomb"] = true, ["Hydrogen Bomb"] = true }
local function updateNukePreview(p: Vector2?)
	local sel = buildMenu.selected
	local tile = if p then tileAtScreen(p) else nil
	local best, bestD = nil, math.huge
	if sel and NUKE_PREVIEW[sel] and tile and mySmallID then
		local dx, dy = gameMap:x(tile), gameMap:y(tile)
		for _, e in unitLayer.units do
			if e.ownerID == mySmallID and e.unitType == "Missile Silo" and not e.underConstruction
				and (e.missileTimers == nil or #e.missileTimers < (e.level or 1)) then
				local d = math.abs(gameMap:x(e.pos) - dx) + math.abs(gameMap:y(e.pos) - dy)
				if d < bestD then
					best, bestD = e, d
				end
			end
		end
	end
	if best == nil then
		if nukePreview.data then
			nukePreview:set(nil)
		end
		return
	end
	local sams = {}
	for _, e in unitLayer.units do
		if e.unitType == "SAM Launcher" and e.ownerID ~= mySmallID and relationOf(e.ownerID) ~= 1 then
			table.insert(sams, { x = gameMap:x(e.pos), y = gameMap:y(e.pos), r = NukePreview.samRange(e.level or 1) })
		end
	end
	nukePreview:set({
		srcX = gameMap:x(best.pos),
		srcY = gameMap:y(best.pos),
		dstX = gameMap:x(tile),
		dstY = gameMap:y(tile),
		directionUp = rocketUp,
		sams = sams,
		blocked = gameMap:isImpassable(tile),
	})
end
local emojiTable = EmojiTable.new(gui)
local function onAllianceRequestSent(smallID: number)
	-- Upstream shows "request sent" unless it accepts their pending request.
	for _, id in (myInfo and myInfo.requestsIn) or {} do
		if id == smallID then
			return
		end
	end
	eventsDisplay:add({ type = "Message", message = "events_display.alliance_request_sent", params = { name = playerName(smallID) or "?" }, messageType = 15, focusPlayerID = smallID, keepNames = true })
end
local playerPanel = PlayerPanel.new({
	gui = gui,
	net = Net,
	emojiTable = emojiTable,
	rocketUp = function()
		return rocketUp
	end,
	setRocketUp = function(v)
		rocketUp = v
	end,
	onAllianceRequestSent = function(smallID)
		onAllianceRequestSent(smallID)
	end,
	players = function()
		local list = {}
		for smallID, e in roster do
			local s = stats[smallID]
			if s and s.tiles > 0 and smallID ~= mySmallID then
				table.insert(list, { smallID = smallID, name = e.name, tiles = s.tiles, color = unitLayer.colors[smallID] })
			end
		end
		return list
	end,
})

local attacksDisplay = AttacksDisplay.new({
	parent = controlPanel.column,
	net = Net,
	playerName = playerName,
	playerType = function(smallID)
		local e = roster[smallID]
		return e and e.type
	end,
	myTroops = function()
		local mine = myStats()
		return if mine then mine.troops else 0
	end,
	ratio = function()
		return controlPanel.ratio
	end,
	boats = function()
		if mySmallID == nil then
			return {}
		end
		local out = {}
		for _, b in unitLayer:boatsOf(mySmallID) do
			local target = "Wilderness"
			if b.targetTile then
				local owner = renderer:ownerAt(b.targetTile)
				if owner ~= 0 then
					target = playerName(owner) or ""
				end
			end
			table.insert(out, { id = b.id, troops = b.troops, targetName = target })
		end
		return out
	end,
	focusPlayer = focusPlayer,
	focusUnit = focusUnit,
	visible = hudVisible,
	myColors = function()
		local id = mySmallID or 0
		return unitLayer.colors[id] or Color3.new(1, 1, 1), unitLayer.borders[id] or Color3.new(0, 0, 0)
	end,
})

local radialMenu = RadialMenu.new({
	gui = gui,
	net = Net,
	buildMenu = buildMenu,
	mySmallID = function()
		return mySmallID
	end,
	ratio = function()
		return controlPanel.ratio
	end,
	playerPanel = playerPanel,
	onAllianceRequestSent = onAllianceRequestSent,
	rocketUp = function()
		return rocketUp
	end,
	myTroops = function()
		local mine = myStats()
		return mine and mine.troops
	end,
})

-- Spawn flow: pick a tile -> leader/flag picker (world frozen) -> 3-2-1 -> spawn.
local startSpawnCountdown -- forward declaration (assigned below)

-- Valid spawn tiles for a centre (same rule as the server: radius-4 BFS,
-- filtered to unowned land/islands).
local function spawnTilesAt(center: number): { number }
	local out = {}
	pcall(function()
		local arr = gameMap:bfs(center, GameMap.euclDistFN(center, 4, true)):toArray()
		for _, t in ipairs(arr) do
			if not gameMap:hasOwner(t) and gameMap:isLand(t) and not gameMap:isImpassable(t) then
				table.insert(out, t)
			end
		end
	end)
	return out
end

local function isValidSpawnCenter(center: number): boolean
	if not gameMap:isLand(center) or gameMap:isImpassable(center) then
		return false
	end
	return #spawnTilesAt(center) > 0
end

-- Nearest valid centre around the clicked tile (spiral search).
local function findSpawnCenter(tile: number): number?
	if isValidSpawnCenter(tile) then
		return tile
	end
	local x0, y0 = gameMap:x(tile), gameMap:y(tile)
	local w, h = gameMap:width(), gameMap:height()
	for r = 1, 8 do
		for dx = -r, r do
			for dy = -r, r do
				if math.max(math.abs(dx), math.abs(dy)) == r then
					local x, y = x0 + dx, y0 + dy
					if x >= 0 and y >= 0 and x < w and y < h then
						local c = gameMap:ref(x, y)
						if isValidSpawnCenter(c) then
							return c
						end
					end
				end
			end
		end
	end
	return nil
end

local function chooseSpawnTile(tile: number)
	if spawnQueued or not inSpawnPhase or gameOver then
		return
	end
	local center = findSpawnCenter(tile)
	if center == nil then
		-- Nothing spawnable around the click; let the player try elsewhere.
		spawnNoticeUntil = os.clock() + 2.5
		return
	end
	if renderer:ownerAt(center) ~= 0 then
		return
	end
	pendingSpawnTile = center
	spawnQueued = true
	spawnQueuedAt = os.clock()
	-- Optional leader: assign a random one automatically, change it later from
	-- the HUD leader card.
	if myIdentity == nil then
		local leader = LeadersData[math.random(1, #LeadersData)]
		local codes = FlagAtlas.codes
		local flag = codes[math.random(1, #codes)]
		myIdentity = { leader = leader.id, flag = flag }
		Net.Intent:FireServer({ type = "identity", leader = leader.id, flag = flag })
		if hud then
			hud:setLeader(leader, flag)
			hud:setLeaderVisible(true)
		end
	end
	-- The territory preview is already visible. A short mandatory 3-2-1
	-- countdown follows, then the player spawns exactly there.
	startSpawnCountdown(center)
end

startSpawnCountdown = function(tile: number)
	if spawnCountdownActive then
		return
	end
	spawnCountdownActive = true
	-- Fly the camera in so the claimed area is actually visible during the countdown.
	task.spawn(function()
		local x, y = gameMap:x(tile), gameMap:y(tile)
		local z0 = camera.zoom
		local z1 = math.max(z0, 6)
		local t0 = os.clock()
		while true do
			local k = math.min(1, (os.clock() - t0) / 0.9)
			local e = k * k * (3 - 2 * k)
			camera.zoom = math.clamp(z0 + (z1 - z0) * e, camera.minZoom, 40)
			camera:centerOn(x, y, 0)
			-- Keep the claimed spot below the big countdown digits.
			camera.panY += camera.background.AbsoluteSize.Y * 0.17
			camera:apply()
			if k >= 1 then
				break
			end
			task.wait()
		end
	end)
	local subtitle = Locale.pick("ИГРА НАЧИНАЕТСЯ...", "GAME STARTING...")
	task.spawn(function()
		for i = 3, 1, -1 do
			hud:setCountdown(tostring(i), subtitle)
			task.wait(1)
		end
		hud:setCountdown(nil)
		spawnCountdownActive = false
		Net.Intent:FireServer({ type = "release_spawn" })
		Net.Intent:FireServer({ type = "spawn", tile = tile })
	end)
end

-- LEADER + FLAG: identity picker (portraits, any country flag) and the HUD card.
buildLeaderSelectFn = function()
	if leaderSelect ~= nil and leaderSelect.gui ~= nil then
		leaderSelect.gui:Destroy()
	end
	leaderSelect = LeaderSelect.new({
		onConfirm = function(leaderId, flagCode)
			myIdentity = { leader = leaderId, flag = flagCode }
			Net.Intent:FireServer({ type = "identity", leader = leaderId, flag = flagCode })
			local leader = LeadersData.byId[leaderId]
			if leader then
				hud:setLeader(leader, flagCode)
			end
			local mine = myStats()
			hud:setLeaderStats(mine and mine.troops or 0, myInfo.maxTroops or 0, mine and mine.gold or 0, myInfo.units)
			hud:setLeaderVisible(true)
		end,
	})
	hud:setOnLeaderClick(function()
		leaderSelect:open()
	end)
	if RunService:IsStudio() and _G.OpenFrontClient then
		_G.OpenFrontClient.leaderSelect = leaderSelect
		_G.OpenFrontClient.highCommand = highCommand
		_G.OpenFrontClient.testSpawnAt = function(tile: number)
			chooseSpawnTile(tile)
		end
	end
end
buildLeaderSelectFn()
hud:setMenuCallback(function()
	goToMainMenu()
end)

if RunService:IsStudio() then
	-- Automated tests: fire TestSpawnAt(tile) in PlayerGui to drive the real flow.
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("TestSpawnAt")
	if old then
		old:Destroy()
	end
	local ev = Instance.new("BindableEvent")
	ev.Name = "TestSpawnAt"
	ev.Parent = pg
	ev.Event:Connect(function(tile)
		if type(tile) ~= "number" then
			return
		end
		if tile == -1 then
			-- Automation: find the first unowned spawnable centre.
			local w, h = gameMap:width(), gameMap:height()
			for y = 0, h - 1, 7 do
				for x = 0, w - 1, 7 do
					local c = gameMap:ref(x, y)
					if gameMap:isLand(c) and renderer:ownerAt(c) == 0 and #spawnTilesAt(c) > 0 then
						chooseSpawnTile(c)
						return
					end
				end
			end
			return
		end
		chooseSpawnTile(tile)
	end)
end



local function refreshPanelVisibility()
	local mine = myStats()
	controlPanel:setVisible(not inSpawnPhase and mine ~= nil and mine.tiles > 0)
	surrenderButton.Visible = not inSpawnPhase and not gameOver and mine ~= nil and mine.tiles > 0
end

surrenderButton.Activated:Connect(function()
	hud:showModal(
		Locale.pick("Сдаться? Твоя земля станет нейтральной.", "Surrender? Your land becomes neutral."),
		Locale.pick("Отмена", "Cancel"),
		false,
		Locale.pick("Сдаться", "Surrender"),
		function()
		Net.Intent:FireServer({ type = "surrender" })
	end)
end)

-- Server events ------------------------------------------------------------------

Net.Roster.OnClientEvent:Connect(addPlayers)

-- Red edge flash when we are attacked (paired with the "alert" cue).
local seenIncoming = {}
local alertFlash = Instance.new("Frame")
alertFlash.Name = "AttackFlash"
alertFlash.Size = UDim2.fromScale(1, 1)
alertFlash.BackgroundColor3 = Color3.fromRGB(255, 60, 70)
alertFlash.BackgroundTransparency = 1
alertFlash.BorderSizePixel = 0
alertFlash.Active = false
alertFlash.ZIndex = 30
alertFlash.Parent = gui
local alertFlashStroke = Instance.new("UIStroke")
alertFlashStroke.Color = Color3.fromRGB(255, 70, 80)
alertFlashStroke.Thickness = 10
alertFlashStroke.Transparency = 1
alertFlashStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
alertFlashStroke.Parent = alertFlash
local function alertFlashNow()
	local TweenService = game:GetService("TweenService")
	alertFlash.BackgroundTransparency = 0.88
	alertFlashStroke.Transparency = 0.15
	TweenService:Create(alertFlash, TweenInfo.new(0.9), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(alertFlashStroke, TweenInfo.new(0.9), { Transparency = 1 }):Play()
end
Net.Me.OnClientEvent:Connect(function(info)
	-- bordering / hasCoast only arrive every few updates; keep the last ones.
	if info.bordering then
		local set = {}
		for _, id in info.bordering do
			set[id] = true
		end
		myBordering = set
	else
		info.hasCoast = myInfo.hasCoast
	end
	myInfo = info
	-- New incoming attack from a player/nation: alarm + red edge flash.
	if info.incoming then
		local fresh = false
		for _, a in info.incoming do
			if a.id ~= nil and not seenIncoming[a.id] then
				seenIncoming[a.id] = true
				if a.other ~= nil and a.other ~= 0 and not a.retreating then
					fresh = true
				end
			end
		end
		if fresh and not inSpawnPhase then
			Audio.play("alert")
			alertFlashNow()
		end
	end
	attacksDisplay:setAttacks(info.incoming, info.outgoing)
	worldText:setAttacks(gameMap, info.outgoing, info.incoming)
	controlPanel:setInfo(info)
	buildMenu:setInfo(info)
	if myIdentity then
		local mine = myStats()
		hud:setLeaderStats(mine and mine.troops or 0, info.maxTroops or 0, mine and mine.gold or 0, info.units)
		hud:setLeaderVisible(true)
	end
	eventsDisplay:updateAlliances(info)
	refreshNameIcons()
end)

Net.Names.OnClientEvent:Connect(function(buf)
	Net.unpackNames(buf, function(smallID, x, y, size)
		nameLayer:setPlacement(smallID, x, y, size)
	end)
end)

-- SoundEffectController: launches for everyone, our own builds, detonations.
local LAUNCH_CUE = { ["Atom Bomb"] = "atom-launch", ["Hydrogen Bomb"] = "hydrogen-launch", MIRV = "mirv-launch" }
local BUILD_CUE = {
	City = "build-city",
	Port = "build-port",
	["Defense Post"] = "build-defense-post",
	["SAM Launcher"] = "sam-built",
	["Missile Silo"] = "silo-built",
	Factory = "build-factory",
	Warship = "build-warship",
	Transport = "transport-ship",
}
local function unitSound(u)
	if u.isActive then
		if seenUnits[u.id] then
			return
		end
		seenUnits[u.id] = true
		local cue = LAUNCH_CUE[u.unitType]
		if cue == nil and u.ownerID == mySmallID then
			cue = BUILD_CUE[u.unitType]
		end
		if cue then
			Audio.play(cue)
		end
		return
	end
	seenUnits[u.id] = nil
	if u.reachedTarget then
		if u.unitType == "Atom Bomb" then
			Audio.play("atom-hit")
		elseif u.unitType == "Hydrogen Bomb" then
			Audio.play("hydrogen-hit")
		elseif u.unitType == "MIRV Warhead" then
			-- Hundreds of warheads: at most one boom per half second.
			Audio.play("atom-hit", 0.3)
		end
	end
end

Net.Units.OnClientEvent:Connect(function(list)
	for _, u in list do
		unitSound(u)
		defensePost(u)
		unitLayer:apply(u)
	end
end)

-- Plain moves arrive batched every 2 ticks (server POS_EVERY).
Net.UnitPos.OnClientEvent:Connect(function(buf)
	Net.unpackUnitPos(buf, function(id, pos)
		unitLayer:movePos(id, pos)
	end)
end)

Net.Tick.OnClientEvent:Connect(function(buf)
	local tick = Net.unpackTiles(buf, function(tile, s)
		renderer:setState(tile, s)
	end)
	tickBase, tickClock = tick, os.clock()
end)

-- Name status icons (PlayerIcons.ts): crown, traitor, disconnected, alliance,
-- alliance request, target, embargo, nuke; then the latest emoji for us.
local traitors, disconnected = {}, {}
local crownSmallID = nil
local emojis = {} -- sender smallID -> { message, recipient, tick }
local EMOJI_DURATION = 50 -- Config.emojiMessageDuration
function refreshNameIcons()
	if mySmallID == nil and next(roster) == nil then
		return
	end
	local me = mySmallID
	local info = myInfo or {}
	local function set(list)
		local out = {}
		for _, id in list or {} do
			out[id] = true
		end
		return out
	end
	local allied, asking, targets, embargoes = {}, set(info.requestsIn), set(info.targets), set(info.embargoes)
	for _, a in info.alliances or {} do
		allied[a.other] = true
	end
	local first, best = nil, -1
	for smallID, s in stats do
		if s.tiles > best then
			first, best = smallID, s.tiles
		end
	end
	local nukeOwners = unitLayer:nukeOwners(renderer, me)
	local now = tickBase + (os.clock() - tickClock) * 10
	for smallID in roster do
		local icons = {}
		if smallID == first and best > 0 then
			table.insert(icons, { icon = "crown" })
		end
		if traitors[smallID] then
			table.insert(icons, { icon = "traitor", color = Color3.fromHex("#ef4444") })
		end
		if disconnected[smallID] then
			table.insert(icons, { icon = "disconnected" })
		end
		if allied[smallID] then
			table.insert(icons, { icon = "alliance", color = Color3.fromHex("#4ade80") })
		end
		if asking[smallID] then
			table.insert(icons, { icon = "allianceRequest" })
		end
		if targets[smallID] then
			table.insert(icons, { icon = "targetRed" })
		end
		if embargoes[smallID] then
			table.insert(icons, { icon = "embargo" })
		end
		if shields[smallID] and os.clock() < shields[smallID] then
			table.insert(icons, { icon = "defensePost", color = Color3.fromHex("#22d3ee") })
		end
		local nuke = nukeOwners[smallID]
		if nuke and smallID ~= me then
			table.insert(icons, { icon = if nuke == "me" then "nukeRed" else "atomBomb", color = if nuke == "me" then nil else Color3.new(1, 1, 1) })
		end
		local e = emojis[smallID]
		local emoji = nil
		if e and now - e.tick < EMOJI_DURATION and (e.recipient == 0 or e.recipient == me) then
			emoji = e.message
		end
		nameLayer:setIcons(smallID, icons, emoji, targets[smallID] == true)
	end
end

local function refreshBoard()
	local rows = {}
	for smallID, s in stats do
		local e = roster[smallID]
		if e and s.tiles > 0 then
			table.insert(rows, { name = e.name, pct = s.tiles / gameMap:numLandTiles(), troops = s.troops, isMe = smallID == mySmallID, tiles = s.tiles, smallID = smallID })
		end
	end
	table.sort(rows, function(a, b)
		return a.tiles > b.tiles
	end)
	-- Always show the local player, even outside the top 10.
	local top = {}
	for i = 1, math.min(10, #rows) do
		top[i] = rows[i]
	end
	if mySmallID and #top == 10 then
		local shown = false
		for _, r in top do
			shown = shown or r.isMe
		end
		if not shown then
			for _, r in rows do
				if r.isMe then
					top[10] = r
				end
			end
		end
	end
	-- CROWN WORLD: mark the current ruler, then paint the board and banner.
	if top[1] then
		top[1].crown = true
	end
	hud:setLeaderboard(top)
	if inSpawnPhase or top[1] == nil then
		hud:setCrown(nil)
	else
		local ruler = top[1]
		local entry = ruler.smallID and roster[ruler.smallID]
		local team = entry and entry.team
		if team and team ~= "Bot" and team ~= "Nations" and team ~= "Humans" then
			hud:setCrown(Lang.t("👑 {team} dynasty rules the world", { team = team }))
		else
			hud:setCrown(Lang.t("👑 {name} rules the world", { name = ruler.name }))
		end
	end
end

local prevMyTiles = 0
Net.Stats.OnClientEvent:Connect(function(buf)
	Net.unpackStats(buf, function(smallID, tiles, troops, gold)
		stats[smallID] = { tiles = tiles, troops = troops, gold = gold }
		nameLayer:setTroops(smallID, troops, tiles > 0)
	end)
	local mine = mySmallID and stats[mySmallID]
	if mine then
		-- Pixel "pum" while our territory is growing (conquest); rate-limited in Audio.
		if mine.tiles > prevMyTiles and prevMyTiles > 0 and not inSpawnPhase then
			Audio.play("capture")
		end
		prevMyTiles = mine.tiles
		controlPanel:setStats(mine.troops, mine.gold)
		buildMenu:setGold(mine.gold)
		if myIdentity then
			hud:setLeaderStats(mine.troops, myInfo.maxTroops or 0, mine.gold, myInfo.units)
			hud:setLeaderVisible(true)
		end
		if mine.tiles > 0 then
			haveSpawned = true
		elseif haveSpawned and not inSpawnPhase and not shownDeath and not gameOver then
			-- Upstream WinModal: shown once when our player is no longer alive.
			shownDeath = true
			eventsDisplay:refresh()
			-- The server stops sending Me once we are dead (and drops our
			-- alliances): forget our diplomatic state so no stale icons remain.
			myInfo.alliances, myInfo.requestsIn, myInfo.targets, myInfo.embargoes = {}, {}, {}, {}
			refreshNameIcons()
			Audio.play("defeat")
			showDeathModal()
		end
	end
	refreshPanelVisibility()
	refreshBoard()
end)

-- Death screen: Spectate, Play again and Rebirth (a banked one, or buy one
-- for Robux; the server uses a bought rebirth straight away).
function showDeathModal()
	local rebirthText, rebirthFn = nil, nil
	if not gameOver and (state.rebirthProduct or 0) ~= 0 then
		local banked = state.rebirths or 0
		rebirthText = if banked > 0
			then Lang.t("Rebirth ({count} left)", { count = banked })
			else Lang.t("Rebirth — R$ {price}", { price = state.rebirthPrice or 49 })
		rebirthFn = function()
			if (state.rebirths or 0) > 0 then
				state.rebirths -= 1
				Net.Intent:FireServer({ type = "rebirth" })
			else
				game:GetService("MarketplaceService"):PromptProductPurchase(player, state.rebirthProduct)
			end
		end
	end
	if state.canMatchmake then
		hud:showModal(
			Locale.pick("Ты погиб", "You died"),
			Locale.pick("Наблюдать", "Spectate"),
			false,
			Locale.pick("Играть снова", "Play again"), playAgain,
			Locale.pick("В ГЛАВНОЕ МЕНЮ", "MAIN MENU"), goToMainMenu
		)
	else
		hud:showModal(
			Locale.pick("Ты погиб", "You died"),
			Locale.pick("Наблюдать", "Spectate"),
			false, nil, nil,
			Locale.pick("В ГЛАВНОЕ МЕНЮ", "MAIN MENU"), goToMainMenu
		)
	end
end

-- "Play again": straight to the next match that is about to start (or a
-- fresh singleplayer game when this one was singleplayer).
function playAgain()
	Net.Intent:FireServer({ type = if state.lobbyMode == "solo" then "play_solo" else "find_match" })
end

-- MessageType values (EventsDisplay.MT) that carry a cue.
local MESSAGE_CUE = {
	[4] = "nuke-warning", -- MIRV_INBOUND
	[5] = "nuke-warning", -- NUKE_INBOUND
	[7] = "nuke-warning", -- HYDROGEN_BOMB_INBOUND
	[13] = "alliance-accepted",
	[14] = "alliance-declined",
	[16] = "alliance-broken",
}

Net.Event.OnClientEvent:Connect(function(evt)
	if evt.type == "Crown" then
		-- CROWN WORLD: a new ruler of the world was announced.
		crownSmallID = evt.smallID
		if evt.announce ~= false then
		local text
		if evt.prevName and evt.prevName ~= "" then
			text = Lang.t("⚔️ {name} overthrew {prev} and took the crown!", { name = evt.name, prev = evt.prevName })
		else
			text = Lang.t("👑 {name} claims the crown!", { name = evt.name })
		end
		if evt.leadTeam and evt.leadTeam ~= "Bot" then
			text ..= " · " .. Lang.t("team {team} leads", { team = evt.leadTeam })
		end
		if evt.bonus and evt.bonus > 0 and evt.smallID == mySmallID then
			text ..= " · " .. Lang.t("crown treasury +{gold}", { gold = Format.renderNumber(evt.bonus) })
		end
		eventsDisplay:add({
			type = "Message",
			message = text,
			raw = true,
			messageType = 13,
			focusPlayerID = evt.smallID,
		})
		end
		refreshNameIcons()
	elseif evt.type == "SpawnPhaseEnd" then
		Audio.play("game-start")
		inSpawnPhase = false
		buildMenu:refresh()
		refreshPanelVisibility()
	elseif evt.type == "Reborn" then
		-- Rebirth applied: back in the game with the old territory.
		shownDeath = false
		haveSpawned = true
		hud.modal.Visible = false
		Audio.play("spawn")
		refreshPanelVisibility()
	elseif evt.type == "Shield" then
		-- Someone came back with a Rebirth: shielded for a few seconds.
		shields[evt.smallID] = os.clock() + evt.seconds
		refreshNameIcons()
		task.delay(evt.seconds + 0.1, refreshNameIcons)
		eventsDisplay:add({
			type = "Message",
			message = Lang.t("🛡 {name} is back (Rebirth) and protected for {seconds} s", { name = evt.name, seconds = evt.seconds }),
			raw = true,
			messageType = 13,
			focusPlayerID = evt.smallID,
		})
	elseif evt.type == "MatchEnding" then
		-- No "keep playing" on Roblox servers: a new match starts shortly.
		matchEndsAt = os.clock() + evt.seconds
	elseif evt.type == "MatchReset" then
		-- Fresh match: rebuild the client from scratch (clone this script).
		-- Helper GUIs live outside `gui`, so they must be removed explicitly.
		local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
		for _, helperName in { "LeaderSelect", "HighCommand", "CRT", "SpawnMarker" } do
			local helper = pg:FindFirstChild(helperName)
			if helper then
				helper:Destroy()
			end
		end
		local testEvent = pg:FindFirstChild("TestSpawnAt")
		if testEvent then
			testEvent:Destroy()
		end
		local fresh = script:Clone()
		gui:Destroy()
		fresh.Parent = script.Parent
		script:Destroy()
	elseif evt.type == "AllianceRequest" then
		Audio.play("alliance-suggested")
		eventsDisplay:allianceRequest(evt.requestor, evt.duration)
	elseif evt.type == "AllianceRequestResolved" then
		eventsDisplay:allianceRequestResolved(evt.requestor)
	elseif evt.type == "AllianceGone" or evt.type == "AllianceExtended" then
		eventsDisplay:allianceGone(evt.allianceID)
	elseif evt.type == "Flags" then
		traitors, disconnected = {}, {}
		for _, id in evt.traitors do
			traitors[id] = true
		end
		for _, id in evt.disconnected do
			disconnected[id] = true
		end
		refreshNameIcons()
	elseif evt.type == "Emoji" then
		emojis[evt.sender] = { message = evt.message, recipient = evt.recipient, tick = evt.tick }
		refreshNameIcons()
		task.delay(EMOJI_DURATION / 10 + 0.2, refreshNameIcons)
	elseif evt.type == "Chat" then
		if evt.isFrom then
			Audio.play("message")
		end
		-- DisplayChatEvent: "From X: msg" / "Sent X: msg".
		local text = ChatModal.phraseText(evt.category, evt.key) or evt.key
		if evt.target then
			local target = evt.target
			text = string.gsub(text, "%[P1%]", function()
				return target
			end)
		end
		eventsDisplay:add({
			type = "Message",
			message = (if evt.isFrom then "From " else "Sent ") .. (evt.other or "") .. ": " .. text,
			raw = true,
			messageType = 20,
			focusPlayerID = evt.otherSmallID,
		})
	elseif evt.type == "MatchInProgress" then
		-- Joined a public server mid-match: offer a lobby about to start and go
		-- there automatically unless the player chooses to watch.
		local cancelled = false
		hud:showModal(
		Locale.pick("Матч идёт", "Match in progress"),
		Locale.pick("Смотреть матч", "Watch this match"),
		false,
		Locale.pick("Найти новый матч", "Find new match"),
		function()
			cancelled = true
			Net.Intent:FireServer({ type = "find_match" })
		end)
		local modalButton = hud.modalButton
		local conn
		conn = modalButton.Activated:Connect(function()
			cancelled = true
			conn:Disconnect()
		end)
		task.spawn(function()
			for left = evt.autoSeconds or 8, 1, -1 do
				if cancelled then
					return
				end
				hud.modalTitle.Text = Lang.t("Match in progress — new match in {left} s", { left = left })
				task.wait(1)
			end
			if not cancelled then
				hud.modal.Visible = false
				Net.Intent:FireServer({ type = "find_match" })
			end
		end)
	elseif evt.type == "Rail" then
		applyRails(evt.remove, evt.add)
	elseif evt.type == "GoldGain" then
		controlPanel:goldGain(evt.gold)
	elseif evt.type == "Message" or evt.type == "Incoming" then
		local cue = MESSAGE_CUE[evt.messageType]
		if cue then
			-- Several nukes announced together: one alarm (NUKE_WARNING interval).
			Audio.play(cue, if cue == "nuke-warning" then 1 else nil)
		end
		eventsDisplay:add(evt)
	elseif evt.type == "Conquest" then
		-- Conquest popup at the conquered player's name (our conquests only).
		if evt.conqueror == mySmallID then
			-- Battle cue for a real player, the payout cue for bots and nations.
			local conquered = roster[evt.conquered]
			Audio.play(if conquered and conquered.type == "HUMAN" then "conquered" else "ka-ching")
			local x, y = nameLayer:placement(evt.conquered)
			if x then
				worldText:conquest(x, y, evt.gold or 0)
			end
		end
	elseif evt.type == "Bonus" then
		worldText:bonus(gameMap:x(evt.tile), gameMap:y(evt.tile), evt.gold)
	elseif evt.type == "Win" then
		gameOver = true
		local myTeam = mySmallID and roster[mySmallID] and roster[mySmallID].team
		local again = if state.canMatchmake then Locale.pick("Играть снова", "Play again") else nil
		local againFn = if state.canMatchmake then playAgain else nil
		local won = (evt.winnerSmallID ~= nil and evt.winnerSmallID == mySmallID)
			or (evt.winnerSmallID == nil and myTeam ~= nil and evt.winnerName == myTeam)
		if not shownDeath then
			Audio.play(if won then "victory" else "defeat")
		end
		if evt.winnerSmallID ~= nil and evt.winnerSmallID == mySmallID then
			hud:showModal(Locale.pick("Ты победил!", "You Won!"), Locale.pick("ОК", "OK"), true, again, againFn, Locale.pick("В ГЛАВНОЕ МЕНЮ", "MAIN MENU"), goToMainMenu)
		elseif evt.winnerSmallID == nil and myTeam ~= nil and evt.winnerName == myTeam then
			hud:showModal(Locale.pick("Твоя команда победила!", "Your team won!"), Locale.pick("ОК", "OK"), true, again, againFn, Locale.pick("В ГЛАВНОЕ МЕНЮ", "MAIN MENU"), goToMainMenu)
		else
			hud:showModal(Lang.t("{name} has won!", { name = evt.winnerName }), Locale.pick("ОК", "OK"), false, again, againFn, Locale.pick("В ГЛАВНОЕ МЕНЮ", "MAIN MENU"), goToMainMenu)
		end
	end
end)

-- Input ----------------------------------------------------------------------------

local WARSHIP_SELECTION_RADIUS = 10
-- Selection radius in tiles: at least ~28 screen pixels, so a warship can be
-- picked on a zoomed-out map (10 tiles was ~13 px on the World map).
local function warshipPickRadius(): number
	return math.max(WARSHIP_SELECTION_RADIUS, 28 / math.max(camera.zoom, 0.01))
end
-- Nearest water tile to `tile` within `r` tiles (coast clicks), or nil.
local function nearestWater(tile: number, r: number): number?
	if gameMap:isWater(tile) then
		return tile
	end
	local x0, y0 = gameMap:x(tile), gameMap:y(tile)
	local best, bestD = nil, math.huge
	for dy = -r, r do
		for dx = -r, r do
			local x, y = x0 + dx, y0 + dy
			if x >= 0 and y >= 0 and x < gameMap:width() and y < gameMap:height() then
				local t = gameMap:ref(x, y)
				local d = dx * dx + dy * dy
				if d < bestD and gameMap:isWater(t) then
					best, bestD = t, d
				end
			end
		end
	end
	return best
end
local selectedWarship: number? = nil

camera.onClick = function(p: Vector2)
	if gameOver or mySmallID == nil then
		return
	end
	if highCommand and highCommand:isMenuOpen() then
		return
	end
	if leaderSelect:isOpen() then
		-- The map is dimmed but still clickable: let the player change the spot.
		if inSpawnPhase then
			local t = tileAtScreen(p)
			if t then
				chooseSpawnTile(t)
			end
		end
		return
	end
	-- The radial menu handles its own clicks (on mouse down).
	if radialMenu:isOpen() or (radialMenu.closedAt and os.clock() - radialMenu.closedAt < 0.3) then
		return
	end
	local tile = tileAtScreen(p)
	if tile == nil then
		return
	end
	if buildMenu:click(tile) then
		return
	end
	if inSpawnPhase then
		-- Random spawn: the server places us; no manual pick (upstream disables it).
		if not state.randomSpawn then
			Audio.play("spawn")
			chooseSpawnTile(tile)
		end
		return
	end
	-- Warship select / move (WarshipSelectionController). Roblox port: a ship
	-- near the coast can be picked even when the click lands on shore, and a
	-- destination on land near water sends it to the closest water tile.
	if selectedWarship and unitLayer:isActiveUnit(selectedWarship) then
		local dst = nearestWater(tile, 6)
		if dst then
			Net.Intent:FireServer({ type = "move_warship", unitIds = { selectedWarship }, tile = dst })
			unitLayer:moveMarker(dst)
			Audio.play("click")
			selectedWarship = nil
			unitLayer:setSelected(nil)
			return
		end
		-- Deep inland: drop the selection and treat it as a normal click.
		selectedWarship = nil
		unitLayer:setSelected(nil)
	else
		local near = unitLayer:warshipsNear(mySmallID, tile, warshipPickRadius())
		if near[1] then
			selectedWarship = near[1]
			unitLayer:setSelected(selectedWarship)
			Audio.play("click")
			return
		end
		if gameMap:isWater(tile) then
			return
		end
	end
	-- The server decides land attack vs boat, exactly like the upstream client.
	if renderer:ownerAt(tile) ~= mySmallID then
		Audio.play("attack")
	end
	Net.Intent:FireServer({ type = "click", tile = tile, ratio = controlPanel.ratio })
end

camera.onRightClick = function(p: Vector2)
	if selectedWarship then
		selectedWarship = nil
		unitLayer:setSelected(nil)
		return
	end
	-- A ghost structure is cancelled by right click; otherwise open the radial menu.
	if buildMenu.selected then
		buildMenu:select(nil)
		return
	end
	local tile = tileAtScreen(p)
	if tile ~= nil and not gameOver and mySmallID ~= nil then
		buildMenu:query(tile, function(info)
			if info then
				radialMenu:openAt(p, tile, info)
			end
		end)
	end
end

-- Touch tap (WarshipSelectionController.onTouch): spawn during the spawn
-- phase, place a ghost structure, water taps go to warships, land taps open
-- the radial menu (attack is its centre button).
camera.onTap = function(p: Vector2)
	if gameOver or mySmallID == nil then
		return
	end
	if radialMenu:isOpen() or (radialMenu.closedAt and os.clock() - radialMenu.closedAt < 0.3) then
		return
	end
	local tile = tileAtScreen(p)
	if tile == nil then
		return
	end
	if buildMenu.selected then
		buildMenu:hover(p)
		camera.onClick(p)
		return
	end
	if inSpawnPhase or gameMap:isWater(tile) then
		camera.onClick(p)
		return
	end
	-- A selected warship, or one close to the tap: warship controls, not the radial menu.
	if selectedWarship or (mySmallID and unitLayer:warshipsNear(mySmallID, tile, warshipPickRadius())[1]) then
		camera.onClick(p)
		return
	end
	camera.onRightClick(p)
end

camera.onHover = function(p: Vector2)
	buildMenu:hover(p)
	updateNukePreview(p)
	local tile = tileAtScreen(p)
	if
		inSpawnPhase
		and not gameOver
		and tile ~= nil
		and gameMap:isLand(tile)
		and not gameMap:isImpassable(tile)
		and renderer:ownerAt(tile) == 0
	then
		hoverSpawnTile = tile
	else
		hoverSpawnTile = nil
	end
	if tile == nil then
		hud:setHover(nil)
		return
	end
	local owner = renderer:ownerAt(tile)
	local e = roster[owner]
	if e then
		local s = stats[owner]
		hud:setHover(if s then Lang.t("{name}  ·  {troops} troops", { name = e.name, troops = Format.renderTroops(s.troops) }) else e.name)
	elseif gameMap:isWater(tile) then
		hud:setHover(if gameMap:isOcean(tile) then "Ocean" else "Lake")
	else
		hud:setHover(Lang.t("Unclaimed {terrain}", { terrain = Lang.t(terrainNames[gameMap:terrainType(tile)] or "?") }))
	end
end

if RunService:IsStudio() then
	-- Studio test hook: read-only view for automated players (soak tests).
	_G.OpenFrontClient.buildMenu = buildMenu
	_G.OpenFrontClient.gameMap = gameMap
	_G.OpenFrontClient.snapshot = function()
		return {
			mySmallID = mySmallID,
			inSpawnPhase = inSpawnPhase,
			gameOver = gameOver,
			roster = roster,
			stats = stats,
			myInfo = myInfo,
			bordering = myBordering,
		}
	end
end

-- Structure ambience (AmbienceController): zoomed in (8+ px per tile) near a
-- city / factory / silo / SAM, the matching loop fades in with the zoom.
local AMBIENCE_BY_TYPE = { City = "city", Factory = "factory", ["Missile Silo"] = "missile-silo", ["SAM Launcher"] = "sam-silo" }
local AMBIENCE_ZOOM, AMBIENCE_MAX_ZOOM, AMBIENCE_PEAK, AMBIENCE_RANGE = 8, 20, 0.3, 20
local lastAmbience, lastAmbienceGain = nil, 0
task.spawn(function()
	while gui.Parent do
		task.wait(0.25)
		local track, gain = nil, 0
		if camera.zoom >= AMBIENCE_ZOOM then
			local vp = workspace.CurrentCamera.ViewportSize
			local cx, cy = camera:mapPos(Vector2.new(vp.X / 2, vp.Y / 2))
			local best = AMBIENCE_RANGE * AMBIENCE_RANGE + 1
			for _, e in unitLayer.units do
				local kind = e.isStructure and AMBIENCE_BY_TYPE[e.unitType]
				if kind then
					local dx, dy = gameMap:x(e.pos) - cx, gameMap:y(e.pos) - cy
					local d2 = dx * dx + dy * dy
					if d2 < best then
						best, track = d2, kind
					end
				end
			end
			if track then
				gain = AMBIENCE_PEAK * math.clamp((camera.zoom - AMBIENCE_ZOOM) / (AMBIENCE_MAX_ZOOM - AMBIENCE_ZOOM), 0, 1)
			end
		end
		if track ~= lastAmbience or math.abs(gain - lastAmbienceGain) > 0.01 then
			lastAmbience, lastAmbienceGain = track, gain
			Audio.setAmbience(track, gain)
		end
	end
	Audio.setAmbience(nil, 0)
end)

-- Performance telemetry (server Telemetry.luau): every 20 s this client's
-- frame rate, worst frame, ping, received data and memory.
task.spawn(function()
	local Stats = game:GetService("Stats")
	local UIS = game:GetService("UserInputService")
	-- Gaps between stats updates (Net.Stats, sent every 0.5 s whatever happens
	-- on the map) as this client sees them: the "map stops, then jumps" symptom.
	local lastTick, gapMax, gaps = os.clock(), 0, 0
	local tickConn = Net.Stats.OnClientEvent:Connect(function()
		local now = os.clock()
		local gap = now - lastTick
		lastTick = now
		if gap > gapMax then
			gapMax = gap
		end
		if gap > 1.0 then
			gaps += 1
		end
	end)
	while gui.Parent do
		local frames, worst, minFps = 0, 0, math.huge
		local secondFrames, secondStart = 0, os.clock()
		local conn = RunService.RenderStepped:Connect(function(dt)
			frames += 1
			secondFrames += 1
			if dt > worst then
				worst = dt
			end
			local now = os.clock()
			if now - secondStart >= 1 then
				minFps = math.min(minFps, secondFrames / (now - secondStart))
				secondFrames, secondStart = 0, now
			end
		end)
		task.wait(20)
		conn:Disconnect()
		if not gui.Parent then
			tickConn:Disconnect()
			break
		end
		Net.Intent:FireServer({
			type = "telemetry",
			fps = frames / 20,
			minFps = if minFps == math.huge then 0 else minFps,
			maxFrame = worst * 1000,
			ping = player:GetNetworkPing() * 1000,
			recv = Stats.DataReceiveKbps,
			mem = Stats:GetTotalMemoryUsageMb(),
			touch = UIS.TouchEnabled and not UIS.KeyboardEnabled,
			gapMax = gapMax * 1000,
			gaps = gaps,
		})
		gapMax, gaps = 0, 0
	end
end)

-- Frame loop ------------------------------------------------------------------------

RunService.RenderStepped:Connect(function()
	renderer:flush()
	if nukePreview.data and not NUKE_PREVIEW[buildMenu.selected or ""] then
		nukePreview:set(nil)
	end
	unitLayer:render()
	tutorial:renderOverlays()
	worldText:render()
	-- Spawn ring: during the spawn phase once we picked a spot, and while the
	-- tutorial points at our territory (syncSpawnOverlay).
	local showRing = not gameOver and ((inSpawnPhase and haveSpawned) or tutorial:wantsSpawnRing())
	local ringTile = nil
	if showRing then
		ringTile = myInfo.spawnTile
	end
	local previewTile = nil
	if not gameOver and inSpawnPhase then
		previewTile = pendingSpawnTile or hoverSpawnTile
	end
	updateSpawnPreview(previewTile)
	spawnRing:set(nil)
	spawnRing:render()
	marker.Visible = false
	mapMarker.Visible = false
	if spawnCountdownActive then
		-- Our 3-2-1 countdown owns the big digits.
	elseif inSpawnPhase and not gameOver then
		local mine = mySmallID and stats[mySmallID]
		local chosen = mine ~= nil and mine.tiles > 0
		-- The server rejected the spawn (spot got taken): unlock and ask again.
		if spawnQueued and not chosen and os.clock() - spawnQueuedAt > 1.5 then
			spawnQueued = false
			pendingSpawnTile = nil
			spawnNoticeUntil = os.clock() + 2.5
		end
		local left = math.max(1, math.ceil((spawnPhaseTurns - estimatedTick()) / 10))
		local hint = if os.clock() < spawnNoticeUntil
			then Locale.pick("ТОЧКА ЗАНЯТА — ВЫБЕРИ ДРУГУЮ", "THAT SPOT IS TAKEN — CHOOSE ANOTHER")
			else Locale.pick("Кликни по карте, чтобы выбрать место старта", "Click the map to choose where to start")
		if state.hasSpawnTimer == false then
			hud:setCountdown("", hint)
		else
			hud:setCountdown(left, if chosen then Locale.pick("Место выбрано — приготовься", "Spawn chosen — get ready") else hint)
		end
	elseif matchEndsAt then
		hud:setCountdown(math.max(0, math.ceil(matchEndsAt - os.clock())), Locale.pick("Новый матч скоро начнётся", "New match starting soon"))
	else
		hud:setCountdown(nil)
	end
end)

print(`[Client] joined {manifest.name} {W}x{H}, {#state.players} player(s) in roster, you = {tostring(mySmallID)}`)
