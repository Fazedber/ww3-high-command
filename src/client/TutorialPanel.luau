-- In-game tutorial, ported from upstream Tutorial.ts (steps + progress) and
-- hud/layers/TutorialPanel.ts (panel, map markers, texts from en.json).
-- Shown every game until "Don't show again" (saved server-side, upstream
-- keeps it in localStorage). Steps that don't fit the game's config are
-- skipped, so "Step n of N" adapts exactly like upstream.

local Format = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Format"))
local Style = require(script.Parent.Style)
local Lang = require(script.Parent.Lang)

local C, F = Style.color, Style.font

-- en.json "tutorial" (desktop texts; touch variants below).
local T = {
	title = "Tutorial",
	complete = "You're ready! Good luck out there.",
	go_to = "Go to",
	got_it = "Got it",
	hide_for_game = "Hide for this game",
	never_show = "Don't show again",
	skip = "Skip",
	close = "Close tutorial",
	step_counter = "Step {current} of {total}",
	step = {
		alliance_info = "Allies can't attack each other. You can break an alliance at any time — but doing so marks you as a traitor.",
		atom_info = "Atom Bomb — small tactical strikes that take out structures.",
		attack_nations = "Nations have cut you off from the tribes. Attack a neighboring nation instead — they're stronger than tribes, so bring plenty of troops. The nearest ones are marked with a target. Conquer them until you have {cost} gold for a City.",
		attack_ratio = "The attack ratio bar sets how many of your troops are sent out with each attack. Drag the slider to adjust it.",
		attack_wilderness = "The pulsing ring marks your territory. Click on the unclaimed land next to it to attack and expand.",
		buy_city = "You can afford a City! Press {key} (or click the City icon under the control panel), then click your territory to place it. Cities raise your max troops.",
		buy_defense_post = "Now build a Defense Post: press {key}, then click your territory near a border. Attacks on the land around it are much slower and cost the enemy far more troops.",
		buy_factory = "Now build a Factory: press {key}, then click your territory to place it.",
		buy_port = "Next, build a Port: press {key}, then click your coastline to place it.",
		buy_silo = "Finally, build a Missile Silo: press {key}, then click your territory to place it. Silos launch atom bombs, hydrogen bombs and MIRVs.",
		buy_warship = "Now build a Warship: press {key}, then click open water near your port. Warships capture trade ships and protect your waters.",
		capture_tribes = "Capturing tribes is a great way to earn gold — the nearest ones are marked with a target on the map. Conquer them until you have {cost} gold for a City.",
		earn_gold = "Attack neighbors to steal their land, conquer them to take their gold. You need {cost} for a {unit}.",
		factory_info = "Factories are connected to cities and other factories by tracks, and spawn trains that grant gold.",
		hydrogen_info = "Hydrogen Bomb — large strategic strikes that weaken the enemy.",
		launch_atom = "Your silo is armed! Press {key}, then click a neighbor's territory to launch an Atom Bomb.",
		mirv_info = "MIRV — a massive missile attack to cripple your enemy.",
		no_coast = "You have no coastline yet. Water access is very important — it lets you send boats, build ports and trade by sea. Expand your territory until it reaches the coast.",
		port_info_ships = "Ports send out trade ships, which earn you gold.",
		port_info_warships = "Ports can also be used to construct warships.",
		propose_alliance = "Nations make strong allies. Right-click the nation marked with a target and propose an alliance.",
		sam_info = "SAM Launcher — defends against nuclear strikes by shooting down incoming missiles.",
		send_boat = "Boats send your troops across water. Right-click an enemy coastline across the water to open the radial menu, then select the boat.",
		silo_loading = "Your Missile Silo is loading — a nuke can be launched once it's fully ready.",
		spawn = "Click anywhere on the map to pick where you spawn.",
		spawn_wait = "Spot picked! You can still move it until the timer runs out — the game starts then.",
		traitor_info = "Traitors get a large defense debuff for 30 seconds, so be careful.",
		troop_rate = "This is your troop growth rate. Growth slows down and turns orange once your troops approach half of your max.",
		troops = "Keep an eye on your troop count. Attacking with too few troops leaves you weak — let them regrow between attacks.",
	},
	step_touch = {
		attack_wilderness = "The pulsing ring marks your territory. Tap the unclaimed land next to it, then tap the sword in the middle of the menu to attack.",
		buy_city = "You can afford a City! Tap your territory, open the wrench (Build) menu and pick City. Cities raise your max troops.",
		buy_defense_post = "Now build a Defense Post: tap your territory near a border, open the wrench menu and pick Defense Post. Attacks on the land around it are much slower and cost the enemy far more troops.",
		buy_factory = "Now build a Factory: tap your territory, open the wrench menu and pick Factory.",
		buy_port = "Next, build a Port: tap your coastline, open the wrench menu and pick Port.",
		buy_silo = "Finally, build a Missile Silo: tap your territory, open the wrench menu and pick Missile Silo. Silos launch atom bombs, hydrogen bombs and MIRVs.",
		buy_warship = "Now build a Warship: tap open water near your port, open the sword menu and pick Warship. Warships capture trade ships and protect your waters.",
		launch_atom = "Your silo is armed! Tap a neighbor's territory, open the sword menu and pick Atom Bomb.",
		propose_alliance = "Nations make strong allies. Tap the nation marked with a target, then tap the handshake to propose an alliance.",
		send_boat = "Boats send your troops across water. Tap an enemy coastline across the water to open the radial menu, then select the boat.",
		spawn = "Tap anywhere on the map to pick where you spawn.",
	},
}

local UNIT_NAMES = {
	City = "City",
	Factory = "Factory",
	Port = "Port",
	["Defense Post"] = "Defense Post",
	Warship = "Warship",
	["Missile Silo"] = "Missile Silo",
	["Atom Bomb"] = "Atom Bomb",
}
local HOTKEYS = { -- HOTKEY_FALLBACKS
	buildCity = "1",
	buildFactory = "2",
	buildPort = "3",
	buildDefensePost = "4",
	buildWarship = "7",
	buildMissileSilo = "5",
	buildAtomBomb = "8",
}

-- Tutorial.ts TUTORIAL_STEPS -----------------------------------------------------------

local STEPS = {
	{ id = "spawn", isDone = function(c)
		return c.hasSpawned and not c.inSpawnPhase
	end },
	{ id = "attack_wilderness", highlight = "territory", isDone = function(c)
		return c.attacking
	end },
	{ id = "troops", highlight = "troops", manual = true },
	{ id = "troop_rate", highlight = "troop_rate", manual = true },
	{ id = "attack_ratio", highlight = "attack_ratio", isDone = function(c)
		return c.attackRatioMoved
	end },
	{
		id = "capture_tribes",
		highlight = "tribes",
		applies = function(c)
			return c.botsExist and not c.cityDisabled
		end,
		isDone = function(c)
			return c.cities > 0 or (c.cityCost ~= nil and c.gold >= c.cityCost)
		end,
	},
	{
		id = "buy_city",
		highlight = "city",
		unit = "City",
		hotkey = "buildCity",
		applies = function(c)
			return not c.cityDisabled
		end,
		isDone = function(c)
			return c.cities > 0
		end,
	},
	{
		id = "propose_alliance",
		highlight = "nation",
		applies = function(c)
			return c.nationsExist and not c.alliancesDisabled
		end,
		isDone = function(c)
			return c.allied
		end,
	},
	{
		id = "alliance_info",
		bullets = { "alliance_info", "traitor_info" },
		applies = function(c)
			return c.nationsExist and not c.alliancesDisabled
		end,
		manual = true,
	},
	{
		id = "buy_factory",
		highlight = "factory",
		unit = "Factory",
		hotkey = "buildFactory",
		applies = function(c)
			return not c.factoryDisabled
		end,
		isDone = function(c)
			return c.factories > 0
		end,
	},
	{ id = "factory_info", applies = function(c)
		return not c.factoryDisabled
	end, manual = true },
	{
		id = "send_boat",
		applies = function(c)
			return not c.boatsDisabled
		end,
		isDone = function(c)
			return c.boatSent
		end,
	},
	{
		id = "buy_port",
		highlight = "port",
		unit = "Port",
		hotkey = "buildPort",
		applies = function(c)
			return not c.portDisabled
		end,
		isDone = function(c)
			return c.ports > 0
		end,
	},
	{
		id = "port_info",
		bullets = { "port_info_ships", "port_info_warships" },
		applies = function(c)
			return not c.portDisabled
		end,
		manual = true,
	},
	{
		id = "buy_defense_post",
		highlight = "defense_post",
		unit = "Defense Post",
		hotkey = "buildDefensePost",
		applies = function(c)
			return not c.defensePostDisabled
		end,
		isDone = function(c)
			return c.defensePosts > 0
		end,
	},
	{
		id = "buy_warship",
		highlight = "warship",
		unit = "Warship",
		hotkey = "buildWarship",
		applies = function(c)
			return not c.warshipDisabled and not c.portDisabled
		end,
		isDone = function(c)
			return c.warships > 0
		end,
	},
	{
		id = "buy_silo",
		highlight = "silo",
		unit = "Missile Silo",
		hotkey = "buildMissileSilo",
		applies = function(c)
			return not c.siloDisabled
		end,
		isDone = function(c)
			return c.silos > 0
		end,
	},
	{
		id = "launch_atom",
		highlight = "atom",
		unit = "Atom Bomb",
		hotkey = "buildAtomBomb",
		applies = function(c)
			return not c.siloDisabled and not c.atomDisabled
		end,
		isDone = function(c)
			return c.atomLaunched
		end,
	},
	{ id = "atom_info", highlight = "atom", applies = function(c)
		return not c.siloDisabled and not c.atomDisabled
	end, manual = true },
	{ id = "hydrogen_info", highlight = "hydrogen", applies = function(c)
		return not c.siloDisabled and not c.hydrogenDisabled
	end, manual = true },
	{ id = "mirv_info", highlight = "mirv", applies = function(c)
		return not c.siloDisabled and not c.mirvDisabled
	end, manual = true },
	{ id = "sam_info", highlight = "sam", applies = function(c)
		return not c.samDisabled
	end, manual = true },
}

local STEP_DONE_LINGER_TICKS = 15
local COMPLETE_LINGER_TICKS = 50
local NEARBY_TRIBE_MARK_COUNT = 3
local COAST_STEPS = { send_boat = true, buy_port = true }
local TOUCH_TEXT_STEPS = {
	spawn = true,
	attack_wilderness = true,
	buy_city = true,
	propose_alliance = true,
	buy_factory = true,
	send_boat = true,
	buy_port = true,
	buy_defense_post = true,
	buy_warship = true,
	buy_silo = true,
	launch_atom = true,
}

-- TutorialProgress ------------------------------------------------------------------------

local Progress = {}
Progress.__index = Progress

function Progress.new()
	return setmetatable({ index = 1, doneTicks = nil, countCtx = nil }, Progress)
end

function Progress:current()
	return STEPS[self.index]
end

function Progress:finished(): boolean
	return self.index > #STEPS
end

function Progress:stepDone(): boolean
	return self.doneTicks ~= nil
end

local function applies(i: number, ctx): boolean
	local a = STEPS[i].applies
	return a == nil or a(ctx)
end

local function applicable(ctx, before: number): number
	local n = 0
	for i = 1, before - 1 do
		if applies(i, ctx) then
			n += 1
		end
	end
	return n
end

function Progress:position(ctx): number
	return applicable(self.countCtx or ctx, self.index) + 1
end

function Progress:total(ctx): number
	return applicable(self.countCtx or ctx, #STEPS + 1)
end

function Progress:acknowledge()
	local step = self:current()
	if step and step.manual and self.doneTicks == nil then
		self.doneTicks = 0
	end
end

function Progress:skip()
	if self:finished() then
		return
	end
	self.index += 1
	self.doneTicks = nil
end

function Progress:update(ctx)
	if self.countCtx == nil and ctx.hasSpawned then
		self.countCtx = ctx
	end
	if self.doneTicks ~= nil then
		self.doneTicks += 1
		if self.doneTicks < STEP_DONE_LINGER_TICKS then
			return
		end
		self.index += 1
		self.doneTicks = nil
	end
	while not self:finished() and not applies(self.index, ctx) do
		self.index += 1
	end
	local step = self:current()
	if step and step.isDone and step.isDone(ctx) then
		self.doneTicks = 0
	end
end

-- Panel -----------------------------------------------------------------------------------------

local TutorialPanel = {}
TutorialPanel.__index = TutorialPanel

local function interpolate(s: string, vars): string
	return (string.gsub(Lang.t(s), "{(%w+)}", function(k)
		local v = vars[k]
		return if v ~= nil then tostring(v) else "{" .. k .. "}"
	end))
end

-- deps: { slot, mapLayer, camera, net, isTouch, dismissed,
--         context() -> ctx?  (nil while we have no player),
--         namePlacement(smallID) -> (x, y, size)?, mySmallID() -> number?,
--         players() -> { { smallID, type, alive } }, bordering() -> set?,
--         hasCoast() -> boolean?, isFriendly(smallID) -> boolean,
--         setHighlight(target?) }
function TutorialPanel.new(deps)
	local self = setmetatable({
		deps = deps,
		progress = Progress.new(),
		active = not deps.dismissed,
		confirmingClose = false,
		completeTicks = nil,
		highlight = nil,
		ctx = nil,
		lastAttackRatio = nil,
		boatSeen = false,
		atomLaunchSeen = false,
		attackNations = false,
		marked = {}, -- smallIDs with a target crosshair
	}, TutorialPanel)
	self:_build()
	self:_render()
	task.spawn(function()
		while self.frame.Parent do
			self:tick()
			task.wait(0.1) -- one game tick
		end
	end)
	return self
end

function TutorialPanel:_build()
	-- pointer-events-auto w-full rounded-lg bg-gray-800/92 shadow-lg text-white text-base p-2 mb-1
	local frame = Style.frame(self.deps.slot, "TutorialPanel", C.gray800, 0.92)
	frame.Size = UDim2.fromScale(1, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Active = true
	Style.corner(frame, 8)
	Style.padding(frame, 8)
	Style.column(frame, 4) -- mb-1 under the header
	self.frame = frame

	-- Header: flex items-center justify-between gap-2
	local header = Style.frame(frame, "Header")
	header.LayoutOrder = 1
	header.Size = UDim2.new(1, 0, 0, 22)
	local title = Style.text(header, "Title", string.upper(T.title), 14, F.bold, C.cyberYellow)
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.fromScale(0, 0.5)
	local right = Style.frame(header, "Actions")
	right.AnchorPoint = Vector2.new(1, 0.5)
	right.Position = UDim2.fromScale(1, 0.5)
	right.AutomaticSize = Enum.AutomaticSize.XY
	Style.row(right, 8)
	self.actions = right

	local function blueButton(name: string, text: string, order: number)
		-- rounded bg-malibu-blue hover:bg-aquarius px-2 py-0.5 font-semibold text-white
		local b = Style.button(right, name, text, 14, F.semibold)
		b.LayoutOrder = order
		b.BackgroundColor3 = C.malibuBlue
		b.BackgroundTransparency = 0
		Style.corner(b, 4)
		Style.padding(b, 8, 2)
		b.MouseEnter:Connect(function()
			b.BackgroundColor3 = C.aquarius
		end)
		b.MouseLeave:Connect(function()
			b.BackgroundColor3 = C.malibuBlue
		end)
		return b
	end
	self.gotIt = blueButton("GotIt", T.got_it, 1)
	self.gotIt.Activated:Connect(function()
		self.progress:acknowledge()
		self:_render()
	end)
	self.goTo = blueButton("GoTo", T.go_to, 2)
	self.goTo.Activated:Connect(function()
		self:_goTo()
	end)
	-- text-gray-400 hover:text-white underline
	local skip = Style.button(right, "Skip", `<u>{T.skip}</u>`, 14, F.medium, C.gray400)
	skip.RichText = true
	skip.LayoutOrder = 3
	skip.MouseEnter:Connect(function()
		skip.TextColor3 = C.white
	end)
	skip.MouseLeave:Connect(function()
		skip.TextColor3 = C.gray400
	end)
	skip.Activated:Connect(function()
		self.progress:skip()
		self:_render()
	end)
	self.skip = skip
	local counter = Style.text(right, "Counter", "", 14, F.medium, C.gray300)
	counter.LayoutOrder = 4
	self.counter = counter
	local close = Style.button(right, "Close", "×", 20, F.medium, C.gray400) -- ✕ is missing from Roblox fonts
	close.LayoutOrder = 5
	Style.padding(close, 4, 0)
	close.MouseEnter:Connect(function()
		close.TextColor3 = C.white
	end)
	close.MouseLeave:Connect(function()
		close.TextColor3 = C.gray400
	end)
	close.Activated:Connect(function()
		self.confirmingClose = not self.confirmingClose
		self:_render()
	end)

	-- Body: <p class="flex gap-1.5">bullet + text</p>
	local body = Style.frame(frame, "Body")
	body.LayoutOrder = 2
	body.Size = UDim2.fromScale(1, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	self.body = body
	local bullet = Style.text(body, "Bullet", "•", 16, Font.fromEnum(Enum.Font.Gotham)) -- Builder Sans draws • square
	bullet.Position = UDim2.fromOffset(0, 0)
	local text = Style.text(body, "Text", "", 16, F.medium)
	text.AutomaticSize = Enum.AutomaticSize.Y
	text.Size = UDim2.new(1, -14, 0, 0)
	text.Position = UDim2.fromOffset(14, 0)
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.RichText = true
	self.bullet, self.text = bullet, text

	-- Close choice: two bordered buttons (flex-col gap-1.5)
	local choice = Style.frame(frame, "CloseChoice")
	choice.LayoutOrder = 3
	choice.Size = UDim2.fromScale(1, 0)
	choice.AutomaticSize = Enum.AutomaticSize.Y
	choice.Visible = false
	Style.column(choice, 6)
	local function choiceButton(name: string, text: string, order: number, fn)
		-- rounded-md border border-gray-500 hover:bg-gray-700 px-2 py-1
		local b = Style.button(choice, name, text, 16, F.medium)
		b.LayoutOrder = order
		b.AutomaticSize = Enum.AutomaticSize.Y
		b.Size = UDim2.fromScale(1, 0)
		b.BackgroundColor3 = C.gray700
		Style.corner(b, 6)
		Style.stroke(b, C.gray500)
		Style.padding(b, 8, 4)
		b.MouseEnter:Connect(function()
			b.BackgroundTransparency = 0
		end)
		b.MouseLeave:Connect(function()
			b.BackgroundTransparency = 1
		end)
		b.Activated:Connect(fn)
	end
	choiceButton("HideForGame", T.hide_for_game, 1, function()
		self:setActive(false)
	end)
	choiceButton("NeverShow", T.never_show, 2, function()
		self:dismissForever()
	end)
	self.choice = choice

	-- Target crosshairs on the map (the spawn ring is SpawnRing.luau).
	self.crosshairs = {}
end

function TutorialPanel:setActive(active: boolean)
	if self.active == active then
		return
	end
	self.active = active
	if not active then
		self:_setHighlight(nil)
		self:_setMarked({})
		self.ringTarget = nil
	end
	self:_render()
end

function TutorialPanel:dismissForever()
	self.deps.net.Intent:FireServer({ type = "tutorial_dismiss" })
	self:setActive(false)
end

-- Called by Main each time the attack ratio changes (uiState.attackRatio).
function TutorialPanel:setAttackRatio(ratio: number)
	self.attackRatio = ratio
end

function TutorialPanel:tick()
	if not self.active then
		return
	end
	local deps = self.deps
	local ctx = deps.context()
	if ctx == nil or ctx.dead then
		if ctx and ctx.dead then
			self:setActive(false)
		end
		return
	end
	if self.completeTicks ~= nil then
		self.completeTicks += 1
		if self.completeTicks >= COMPLETE_LINGER_TICKS then
			self:dismissForever()
		end
		return
	end
	-- attackRatioMoved / latched boat & atom sightings (buildContext)
	ctx.attackRatioMoved = self.lastAttackRatio ~= nil and self.attackRatio ~= self.lastAttackRatio
	self.lastAttackRatio = self.attackRatio
	self.boatSeen = self.boatSeen or ctx.boatAfloat
	ctx.boatSent = self.boatSeen
	self.atomLaunchSeen = self.atomLaunchSeen or ctx.atomInFlight
	ctx.atomLaunched = self.atomLaunchSeen

	self.progress:update(ctx)
	self.ctx = ctx
	if self.progress:finished() then
		self.completeTicks = 0
		self:_setHighlight(nil)
		self:_setMarked({})
		self.ringTarget = nil
		self:_render()
		return
	end
	local step = self.progress:current()
	local target = if step and not self.progress:stepDone() then step.highlight else nil
	self:_setHighlight(target)
	self:_syncMapMarkers(target)
	self:_render()
end

function TutorialPanel:_setHighlight(target: string?)
	if self.highlight == target then
		return
	end
	self.highlight = target
	self.deps.setHighlight(target)
end

-- Living players of `type`, nearest name location first.
function TutorialPanel:_nearest(ptype: string, mx: number, my: number): { number }
	local list = {}
	for _, p in self.deps.players() do
		if p.type == ptype and p.alive then
			local x, y = self.deps.namePlacement(p.smallID)
			if x and not (x == 0 and y == 0) then
				local dx, dy = x - mx, y - my
				table.insert(list, { id = p.smallID, d = dx * dx + dy * dy })
			end
		end
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local ids = {}
	for i, e in list do
		ids[i] = e.id
	end
	return ids
end

local function take(list: { number }, n: number): { number }
	return table.move(list, 1, math.min(n, #list), 1, {})
end

function TutorialPanel:_syncMapMarkers(target: string?)
	local me = self.deps.mySmallID()
	local mx, my, msize = nil, nil, nil
	if me then
		mx, my, msize = self.deps.namePlacement(me)
	end
	-- Keep our spawn ring up while pointing at our territory (setOwnSpawnRing).
	self.ringTarget = target == "territory"
	if target ~= "tribes" and target ~= "nation" then
		self:_setMarked({})
		return
	end
	if not mx or (mx == 0 and my == 0) then
		return -- keep the last set while our name location is missing
	end
	local ids
	if target == "tribes" then
		local bordering = self.deps.bordering()
		local bots = self:_nearest("BOT", mx, my)
		if bordering == nil then
			self.attackNations = false
			ids = take(bots, NEARBY_TRIBE_MARK_COUNT)
		else
			local borderingBots = {}
			for _, id in bots do
				if bordering[id] then
					table.insert(borderingBots, id)
				end
			end
			if #borderingBots > 0 then
				self.attackNations = false
				ids = take(borderingBots, NEARBY_TRIBE_MARK_COUNT)
			else
				local nations = {}
				for _, id in self:_nearest("NATION", mx, my) do
					if bordering[id] and not self.deps.isFriendly(id) then
						table.insert(nations, id)
					end
				end
				self.attackNations = #nations > 0
				ids = take(if self.attackNations then nations else bots, NEARBY_TRIBE_MARK_COUNT)
			end
		end
	else
		-- TODO(port): nation relations (profile) once nations are ported.
		ids = take(self:_nearest("NATION", mx, my), 1)
	end
	self:_setMarked(ids)
end

function TutorialPanel:_setMarked(ids: { number })
	self.marked = ids
	local keep = {}
	for _, id in ids do
		keep[id] = true
		if not self.crosshairs[id] then
			self.crosshairs[id] = self:_makeCrosshair()
		end
	end
	for id, ch in self.crosshairs do
		if not keep[id] then
			ch:Destroy()
			self.crosshairs[id] = nil
		end
	end
end

function TutorialPanel:_makeCrosshair(): Frame
	-- Target marker: red ring with four ticks.
	local f = Style.frame(self.deps.mapLayer, "TutorialTarget")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.ZIndex = 8
	local ring = Style.frame(f, "Ring")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(0.7, 0.7)
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0.5, 0)
	rc.Parent = ring
	Style.stroke(ring, C.red500, 2.5)
	for i, spec in { { 0.5, 0, 0.5, 0 }, { 0.5, 1, 0.5, 1 }, { 0, 0.5, 0, 0.5 }, { 1, 0.5, 1, 0.5 } } do
		local tick = Style.frame(f, `Tick{i}`, C.red500, 1)
		local vertical = i <= 2
		tick.AnchorPoint = Vector2.new(spec[3], spec[4])
		tick.Position = UDim2.fromScale(spec[1], spec[2])
		tick.Size = if vertical then UDim2.new(0, 3, 0.3, 0) else UDim2.new(0.3, 0, 0, 3)
	end
	return f
end

-- Per frame (Main's RenderStepped): keep map overlays glued to the camera.
function TutorialPanel:renderOverlays()
	local camera = self.deps.camera
	for id, ch in self.crosshairs do
		local x, y, size = self.deps.namePlacement(id)
		ch.Visible = x ~= nil
		if x then
			local p = camera:screenPos(x, y)
			local d = math.clamp(size * 2.5 * camera.zoom, 28, 90)
			ch.Position = UDim2.fromOffset(p.X, p.Y)
			ch.Size = UDim2.fromOffset(d, d)
		end
	end
end

-- GameView.ownSpawnRing(): the tutorial wants our spawn ring shown.
function TutorialPanel:wantsSpawnRing(): boolean
	return self.active and self.ringTarget == true
end

-- Go to: our territory for the ring step, else the nearest marked player.
function TutorialPanel:_goToTarget(): number?
	if self.highlight == "territory" then
		return self.deps.mySmallID()
	end
	return self.marked[1]
end

function TutorialPanel:_goTo()
	local id = self:_goToTarget()
	if id == nil then
		return
	end
	local x, y = self.deps.namePlacement(id)
	if x then
		self.deps.camera:centerOn(x, y, 3)
	end
end

function TutorialPanel:_stepText(step, done: boolean): string
	local ctx = self.ctx
	if not done and step.id == "spawn" and ctx and ctx.hasSpawned then
		return T.step.spawn_wait
	end
	if not done and COAST_STEPS[step.id] and self.deps.hasCoast() == false then
		return T.step.no_coast
	end
	local cost = if step.unit and ctx then ctx.costs[step.unit] else nil
	if not done and cost ~= nil and ctx and ctx.gold < cost then
		return interpolate(T.step.earn_gold, { unit = Lang.t(UNIT_NAMES[step.unit]), cost = Format.renderNumber(cost) })
	end
	if not done and step.id == "launch_atom" and ctx and ctx.siloReady == false then
		return T.step.silo_loading
	end
	local id = if not done and step.id == "capture_tribes" and self.attackNations then "attack_nations" else step.id
	local block = if self.deps.isTouch() and TOUCH_TEXT_STEPS[id] and T.step_touch[id] then T.step_touch else T.step
	return interpolate(block[id], {
		cost = Format.renderNumber(if ctx then ctx.cityCost or 0 else 0),
		key = if step.hotkey then HOTKEYS[step.hotkey] else "",
	})
end

function TutorialPanel:_render()
	self.frame.Visible = self.active
	if not self.active then
		return
	end
	local progress = self.progress
	local step = progress:current()
	local done = progress:stepDone()
	local complete = self.completeTicks ~= nil

	-- Header actions (hidden while confirming close).
	local showActions = not self.confirmingClose and step ~= nil and not complete and not done
	self.gotIt.Visible = showActions and step.manual == true
	local goTarget = if showActions then self:_goToTarget() else nil
	self.goTo.Visible = goTarget ~= nil
	self.skip.Visible = showActions
	if self.ctx and not progress:finished() then
		self.counter.Text = interpolate(T.step_counter, { current = progress:position(self.ctx), total = progress:total(self.ctx) })
		self.counter.Visible = true
	else
		self.counter.Visible = false
	end

	self.choice.Visible = self.confirmingClose
	self.body.Visible = not self.confirmingClose
	if self.confirmingClose then
		return
	end
	if complete then
		self.bullet.Visible = false
		self.text.Position = UDim2.fromOffset(0, 0)
		self.text.Size = UDim2.new(1, 0, 0, 0)
		self.text.Text = T.complete
		self.text.TextColor3 = C.white
		return
	end
	if step == nil then
		return
	end
	self.text.Position = UDim2.fromOffset(14, 0)
	self.text.Size = UDim2.new(1, -14, 0, 0)
	local color = if done then C.green400 else C.white
	self.bullet.TextColor3, self.text.TextColor3 = color, color
	if step.bullets and not done then
		-- list-disc ms-4 flex-col gap-1
		self.bullet.Visible = false
		local lines = {}
		for _, b in step.bullets do
			table.insert(lines, "•  " .. T.step[b])
		end
		self.text.Text = table.concat(lines, "\n")
	elseif step.bullets then
		self.bullet.Visible = true
		self.bullet.Text = "✓"
		local lines = {}
		for _, b in step.bullets do
			table.insert(lines, T.step[b])
		end
		self.text.Text = table.concat(lines, "\n")
	else
		self.bullet.Visible = true
		self.bullet.Text = if done then "✓" else "•"
		self.text.Text = self:_stepText(step, done)
	end
end

return TutorialPanel
