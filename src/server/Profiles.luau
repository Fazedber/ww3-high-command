-- Player profiles in a DataStore: owned and equipped cosmetics, match
-- statistics, settings, and the purchase receipts already granted.
--
-- One profile per UserId, loaded on join and saved every SAVE_EVERY
-- seconds, when the player leaves and when the server closes. A session
-- lock (jobId + time) keeps two servers from writing the same profile; a
-- lock older than LOCK_STALE is taken over (the old server crashed).
--
-- The module is required once per server, so profiles survive the match
-- restarts (GameServer re-clones itself, this module stays loaded).

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Profiles = {}

local STORE_NAME = "Profiles_v1"
local SAVE_EVERY = 60
local LOCK_STALE = 5 * 60
local MAX_RECEIPTS = 100

local store = nil
pcall(function()
	store = DataStoreService:GetDataStore(STORE_NAME)
end)

local function defaultProfile()
	return {
		version = 1,
		owned = {}, -- itemId -> true
		equipped = {}, -- slot -> itemId
		stats = { games = 0, wins = 0, bestPct = 0 },
		settings = {},
		receipts = {}, -- ordered list of granted PurchaseIds
		trials = {}, -- itemId -> os.time() the free trial (rewarded ad) ends
		rebirths = 0, -- banked Rebirth purchases
		daily = { day = 0, streak = 0 }, -- daily login reward (UTC day number, consecutive days)
	}
end

local profiles = {} -- userId -> { data, loaded, dirty }
local loadedSignal = Instance.new("BindableEvent")

local function key(userId: number): string
	return `u{userId}`
end

local function reconcile(data)
	local d = defaultProfile()
	if type(data) ~= "table" then
		return d
	end
	for k, v in d do
		if type(data[k]) ~= type(v) then
			data[k] = v
		end
	end
	for k, v in d.stats do
		if type(data.stats[k]) ~= "number" then
			data.stats[k] = v
		end
	end
	return data
end

local function load(player: Player)
	local userId = player.UserId
	local entry = { data = defaultProfile(), loaded = false, dirty = false }
	profiles[userId] = entry
	if store == nil then
		entry.loaded = true -- Studio without API access: in-memory only
		loadedSignal:Fire(userId)
		return
	end
	local gotProfile = false
	for attempt = 1, 5 do
		local ok, result = pcall(function()
			return store:UpdateAsync(key(userId), function(old)
				old = reconcile(old)
				local lock = old.lock
				if lock and lock.jobId ~= game.JobId and os.time() - (lock.time or 0) < LOCK_STALE then
					return nil -- another live server holds it; retry
				end
				old.lock = { jobId = game.JobId, time = os.time() }
				return old
			end)
		end)
		if ok and result then
			entry.data = reconcile(result)
			gotProfile = true
			break
		end
		task.wait(if ok then 3 else 1 + attempt)
	end
	-- Never overwrite a saved profile with defaults when the load failed: play in memory only.
	entry.readOnly = not gotProfile
	if entry.readOnly then
		warn("[Profiles] load failed for " .. userId .. "; saves disabled this session")
	end
	entry.loaded = true
	if player.Parent == nil then
		return -- left while loading
	end
	loadedSignal:Fire(userId)
end

local function save(userId: number, release: boolean): boolean
	local entry = profiles[userId]
	if entry == nil or not entry.loaded or store == nil then
		return true
	end
	if entry.readOnly then
		return false -- receipts stay NotProcessedYet until a real profile loads
	end
	local snapshot = table.clone(entry.data)
	local ok = pcall(function()
		store:UpdateAsync(key(userId), function(old)
			old = reconcile(old)
			local lock = old.lock
			if lock and lock.jobId ~= game.JobId and os.time() - (lock.time or 0) < LOCK_STALE then
				return nil -- someone else took over; don't clobber
			end
			snapshot.lock = if release then nil else { jobId = game.JobId, time = os.time() }
			return snapshot
		end)
	end)
	if ok then
		entry.dirty = false
	end
	return ok
end

-- The profile of a loaded player (waits up to `timeout` s for the load).
function Profiles.get(userId: number, timeout: number?)
	local entry = profiles[userId]
	local deadline = os.clock() + (timeout or 0)
	while (entry == nil or not entry.loaded) and os.clock() < deadline do
		task.wait(0.1)
		entry = profiles[userId]
	end
	return if entry and entry.loaded then entry.data else nil
end

function Profiles.markDirty(userId: number)
	local entry = profiles[userId]
	if entry then
		entry.dirty = true
	end
end

function Profiles.saveNow(userId: number): boolean
	return save(userId, false)
end

function Profiles.onLoaded(fn: (number) -> ())
	return loadedSignal.Event:Connect(fn)
end

-- Receipts: MarketplaceService.ProcessReceipt idempotency.
function Profiles.hasReceipt(data, purchaseId: string): boolean
	return table.find(data.receipts, purchaseId) ~= nil
end
function Profiles.addReceipt(data, purchaseId: string)
	table.insert(data.receipts, purchaseId)
	while #data.receipts > MAX_RECEIPTS do
		table.remove(data.receipts, 1)
	end
end

local started = false
function Profiles.start()
	if started then
		return
	end
	started = true
	Players.PlayerAdded:Connect(load)
	for _, p in Players:GetPlayers() do
		task.spawn(load, p)
	end
	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		save(userId, true)
		profiles[userId] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(SAVE_EVERY)
			for userId, entry in profiles do
				if entry.dirty then
					task.spawn(save, userId, false)
				end
			end
		end
	end)
	if not RunService:IsStudio() then
		game:BindToClose(function()
			local pending = 0
			for userId in profiles do
				pending += 1
				task.spawn(function()
					save(userId, true)
					pending -= 1
				end)
			end
			local deadline = os.clock() + 25
			while pending > 0 and os.clock() < deadline do
				task.wait(0.1)
			end
		end)
	end
end

return Profiles
