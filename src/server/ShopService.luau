-- Cosmetics shop, server side: grants developer-product purchases into the
-- player's profile (idempotent by PurchaseId), tracks game passes and the
-- monthly subscription, runs the daily deal and rewarded-ad trials, and
-- validates equip requests. Nothing here affects the simulation.

local AdService = game:GetService("AdService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Shop = require(Shared.Data.Shop)
local Flags = require(Shared.Data.Flags)
local Profiles = require(script.Parent.Profiles)

local ShopService = {}

local passes = {} -- userId -> { [passKey] = true }
local subscribed = {} -- userId -> true
local changed = Instance.new("BindableEvent") -- (userId) cosmetics changed
ShopService.Changed = changed.Event

local FLAG_CODES = {}
for _, code in Flags.codes do
	FLAG_CODES[code] = true
end

-- Perks: passes, plus everything while subscribed.
function ShopService.perks(userId: number)
	local p = passes[userId] or {}
	local plus = subscribed[userId] == true
	return {
		supporter = p.supporter == true,
		color = p.color == true or plus,
		host = p.host == true or plus,
		flag = p.flag == true or plus,
		plus = plus,
	}
end

function ShopService.hasHostPerks(userId: number): boolean
	return ShopService.perks(userId).host
end

local function trialActive(data, itemId: string): boolean
	local t = data.trials and data.trials[itemId]
	return type(t) == "number" and t > os.time()
end

local function owns(userId: number, data, itemId: string): boolean
	return data.owned[itemId] == true or subscribed[userId] == true or trialActive(data, itemId)
end

-- Grant items (and equip the first of each kind) or roll back on save failure.
local function grant(receipt, data, items: { any }, trial: boolean)
	local undo = {}
	for _, item in items do
		if trial then
			undo[item.id] = { trial = data.trials[item.id] }
			data.trials[item.id] = os.time() + Shop.TRIAL_SECONDS
		else
			undo[item.id] = { owned = data.owned[item.id] }
			data.owned[item.id] = true
		end
	end
	if #items == 1 then
		local slot = Shop.SLOTS[items[1].kind]
		if slot then
			data.equipped[slot] = items[1].id
		end
	end
	Profiles.addReceipt(data, receipt.PurchaseId)
	if not Profiles.saveNow(receipt.PlayerId) then
		for id, u in undo do
			if trial then
				data.trials[id] = u.trial
			else
				data.owned[id] = u.owned
			end
		end
		table.remove(data.receipts, table.find(data.receipts, receipt.PurchaseId) :: number)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	changed:Fire(receipt.PlayerId)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processReceipt(receipt)
	local pid = receipt.ProductId
	local item = Shop.byProduct[pid]
	local bundle = Shop.bundleByProduct[pid]
	local isDeal = Shop.DAILY_DEAL.productId ~= 0 and pid == Shop.DAILY_DEAL.productId
	local isAd = Shop.AD_REWARD.productId ~= 0 and pid == Shop.AD_REWARD.productId
	local isRebirth = pid == Shop.REBIRTH.productId
	if not (item or bundle or isDeal or isAd or isRebirth) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local data = Profiles.get(receipt.PlayerId, 15)
	if data == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- not loaded; Roblox retries
	end
	if Profiles.hasReceipt(data, receipt.PurchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if isRebirth then
		data.rebirths = (data.rebirths or 0) + 1
		Profiles.addReceipt(data, receipt.PurchaseId)
		if not Profiles.saveNow(receipt.PlayerId) then
			data.rebirths -= 1
			table.remove(data.receipts, table.find(data.receipts, receipt.PurchaseId) :: number)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		changed:Fire(receipt.PlayerId)
		if ShopService.onRebirthBought then
			task.defer(ShopService.onRebirthBought, receipt.PlayerId)
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if item then
		return grant(receipt, data, { item }, false)
	elseif bundle then
		local list = {}
		for _, it in Shop.items do
			if bundle.kinds[it.kind] then
				table.insert(list, it)
			end
		end
		return grant(receipt, data, list, false)
	elseif isDeal then
		local deal = Shop.dailyItem(data.owned)
		return grant(receipt, data, if deal then { deal } else {}, false)
	else
		-- Rewarded ad (or bought with Robux): a 24 h trial of a random item
		-- the player does not own.
		local pool = {}
		for _, it in Shop.items do
			if not data.owned[it.id] and not trialActive(data, it.id) then
				table.insert(pool, it)
			end
		end
		local pick = if #pool > 0 then pool[Random.new():NextInteger(1, #pool)] else nil
		return grant(receipt, data, if pick then { pick } else {}, true)
	end
end

local function checkPasses(player: Player)
	local userId = player.UserId
	local owned = passes[userId] or {}
	passes[userId] = owned
	for key, pass in Shop.PASSES do
		if pass.id ~= 0 and not owned[key] then
			local ok, has = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(userId, pass.id)
			end)
			if ok and has then
				owned[key] = true
			end
		end
	end
	changed:Fire(userId)
end

local function checkSubscription(player: Player)
	if Shop.SUBSCRIPTION_ID == "" then
		return
	end
	local ok, status = pcall(function()
		return MarketplaceService:GetUserSubscriptionStatusAsync(player, Shop.SUBSCRIPTION_ID)
	end)
	if ok and type(status) == "table" then
		local was = subscribed[player.UserId] == true
		subscribed[player.UserId] = status.IsSubscribed == true or nil
		if was ~= (subscribed[player.UserId] == true) then
			changed:Fire(player.UserId)
		end
	end
end

local started = false
function ShopService.start()
	if started then
		return
	end
	started = true
	MarketplaceService.ProcessReceipt = processReceipt
	Profiles.onLoaded(function(userId)
		changed:Fire(userId)
	end)
	local function onJoin(player: Player)
		checkPasses(player)
		checkSubscription(player)
	end
	Players.PlayerAdded:Connect(onJoin)
	for _, p in Players:GetPlayers() do
		task.spawn(onJoin, p)
	end
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not purchased then
			return
		end
		for key, pass in Shop.PASSES do
			if pass.id == passId then
				passes[player.UserId] = passes[player.UserId] or {}
				passes[player.UserId][key] = true
				changed:Fire(player.UserId)
			end
		end
	end)
	Players.UserSubscriptionStatusChanged:Connect(function(player, subscriptionId)
		if subscriptionId == Shop.SUBSCRIPTION_ID then
			checkSubscription(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		passes[player.UserId] = nil
		subscribed[player.UserId] = nil
	end)
end

function ShopService.isSupporter(userId: number): boolean
	return ShopService.perks(userId).supporter
end

-- What a player shows in the game: { pattern = itemId?, nameColor = {r,g,b}?,
-- explosion = itemId?, color = {r,g,b}?, flag = code?, supporter = bool }.
function ShopService.cosmetics(userId: number)
	local data = Profiles.get(userId)
	local perks = ShopService.perks(userId)
	local out = { supporter = perks.supporter or perks.plus }
	if data then
		local eq = data.equipped
		for _, slot in { "pattern", "explosion" } do
			local id = eq[slot]
			if id and Shop.byId[id] and owns(userId, data, id) then
				out[slot] = id
			end
		end
		local nameColor = eq.nameColor
		if nameColor and Shop.byId[nameColor] and owns(userId, data, nameColor) then
			out.nameColor = Shop.byId[nameColor].color
		end
		if perks.color and type(eq.color) == "number" and Shop.COLORS[eq.color] then
			out.color = Shop.COLORS[eq.color]
		end
		if perks.flag and type(eq.flag) == "string" and FLAG_CODES[eq.flag] then
			out.flag = eq.flag
		end
	end
	if out.nameColor == nil and out.supporter then
		out.nameColor = Shop.byId.name_gold.color
	end
	return out
end

-- Spend one banked rebirth; false when the player has none.
function ShopService.useRebirth(userId: number): boolean
	local data = Profiles.get(userId)
	if data == nil or (data.rebirths or 0) <= 0 then
		return false
	end
	data.rebirths -= 1
	Profiles.markDirty(userId)
	changed:Fire(userId)
	return true
end

function ShopService.rebirths(userId: number): number
	local data = Profiles.get(userId)
	return if data then data.rebirths or 0 else 0
end

-- Shop screen state for a player.
function ShopService.state(userId: number)
	local data = Profiles.get(userId, 5)
	local owned, trials = {}, {}
	if data then
		for id in data.owned do
			owned[id] = true
		end
		for id, t in data.trials do
			if type(t) == "number" and t > os.time() then
				trials[id] = t - os.time()
			end
		end
	end
	local deal = data and Shop.dailyItem(data.owned)
	return {
		owned = owned,
		trials = trials, -- itemId -> seconds left
		equipped = if data then data.equipped else {},
		perks = ShopService.perks(userId),
		supporter = ShopService.perks(userId).supporter,
		daily = deal and deal.id,
		dailySecondsLeft = 86400 - os.time() % 86400,
		rebirths = if data then data.rebirths or 0 else 0,
		loaded = data ~= nil,
	}
end

-- Equip (or unequip with value nil). Slots: pattern / nameColor / explosion
-- (item ids), color (palette index), flag (country code).
function ShopService.equip(userId: number, slot: string, value: any): boolean
	local data = Profiles.get(userId)
	if data == nil then
		return false
	end
	local perks = ShopService.perks(userId)
	if slot == "color" then
		if value ~= nil and not (perks.color and type(value) == "number" and Shop.COLORS[value]) then
			return false
		end
	elseif slot == "flag" then
		if value ~= nil and not (perks.flag and type(value) == "string" and FLAG_CODES[value]) then
			return false
		end
	elseif slot == "pattern" or slot == "nameColor" or slot == "explosion" then
		if value ~= nil then
			local item = type(value) == "string" and Shop.byId[value]
			if not item or Shop.SLOTS[item.kind] ~= slot or not owns(userId, data, value) then
				return false
			end
		end
	else
		return false
	end
	data.equipped[slot] = value
	Profiles.markDirty(userId)
	changed:Fire(userId)
	return true
end

-- Rewarded video: the client checked availability; show it from the server.
function ShopService.showRewardedAd(player: Player): boolean
	if Shop.AD_REWARD.productId == 0 then
		return false
	end
	local ok, result = pcall(function()
		local reward = AdService:CreateAdRewardFromDevProductId(Shop.AD_REWARD.productId)
		return AdService:ShowRewardedVideoAdAsync(player, reward)
	end)
	return ok and result == Enum.ShowAdResult.ShowCompleted
end

-- Daily login reward: once per UTC day. Cosmetics only (no pay-to-win): a free 24 h trial of a
-- random cosmetic the player does not own (72 h on every 7th consecutive day), equipped at once.
local DAY = 86400
function ShopService.dailyStatus(userId: number)
	local data = Profiles.get(userId, 5)
	if data == nil then
		return nil
	end
	local d = data.daily or { day = 0, streak = 0 }
	local today = os.time() // DAY
	local streak = d.streak or 0
	if (d.day or 0) < today - 1 then
		streak = 0 -- missed a day
	end
	local canClaim = (d.day or 0) < today
	return {
		canClaim = canClaim,
		streak = streak,
		nextStreak = if canClaim then streak + 1 else streak,
		secondsLeft = DAY - os.time() % DAY,
	}
end

-- Returns ok, itemId?, streak?, hours?.
function ShopService.claimDaily(userId: number)
	local data = Profiles.get(userId, 5)
	if data == nil then
		return false
	end
	data.daily = data.daily or { day = 0, streak = 0 }
	local d = data.daily
	local today = os.time() // DAY
	if (d.day or 0) >= today then
		return false
	end
	local streak = if d.day == today - 1 then (d.streak or 0) + 1 else 1
	local hours = if streak % 7 == 0 then 72 else 24
	local pool = {}
	for _, it in Shop.items do
		if not data.owned[it.id] and not trialActive(data, it.id) then
			table.insert(pool, it)
		end
	end
	local pick = if #pool > 0 then pool[Random.new():NextInteger(1, #pool)] else nil
	d.day, d.streak = today, streak
	if pick then
		data.trials[pick.id] = os.time() + hours * 3600
		local slot = Shop.SLOTS[pick.kind]
		if slot then
			data.equipped[slot] = pick.id
		end
	end
	Profiles.markDirty(userId)
	Profiles.saveNow(userId)
	changed:Fire(userId)
	return true, pick and pick.id, streak, hours
end
return ShopService
