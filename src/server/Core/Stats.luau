-- Port of OpenFrontIO src/core/game/StatsImpl.ts — attack bookkeeping only.
--
-- Only attack stats feed back into the simulation: GameImpl.conquerPlayer
-- skips the gold transfer for a human who never sent an attack. Everything
-- else upstream records is for the end-of-game stats screen.
-- TODO(port): full stats (gold/units/alliances/kills) for the results screen.

local Stats = {}
Stats.__index = Stats

Stats.ATTACK_INDEX_SENT = 1 -- upstream index 0; Luau arrays are 1-based
Stats.ATTACK_INDEX_RECV = 2
Stats.ATTACK_INDEX_CANCEL = 3
Stats.ATTACK_INDEX_MAX_RECV = 4

function Stats.new()
	return setmetatable({ data = {} }, Stats)
end

-- Stats exist only for players with a clientID (humans), like upstream.
function Stats:_makePlayerStats(player)
	local clientID = player:clientID()
	if clientID == nil then
		return nil
	end
	local data = self.data[clientID]
	if data == nil then
		data = {}
		self.data[clientID] = data
	end
	return data
end

function Stats:getPlayerStats(player)
	local clientID = player:clientID()
	if clientID == nil then
		return nil
	end
	return self.data[clientID]
end

local function addAttack(self, player, index: number, value: number)
	local p = self:_makePlayerStats(player)
	if p == nil then
		return
	end
	p.attacks = p.attacks or { 0 }
	while #p.attacks < index do
		table.insert(p.attacks, 0)
	end
	-- BigInt(Math.floor(value)), as upstream _bigint().
	p.attacks[index] += math.floor(value)
end

local function maxAttack(self, player, index: number, value: number)
	local p = self:_makePlayerStats(player)
	if p == nil then
		return
	end
	p.attacks = p.attacks or { 0 }
	while #p.attacks < index do
		table.insert(p.attacks, 0)
	end
	local v = math.floor(value)
	if v > p.attacks[index] then
		p.attacks[index] = v
	end
end

function Stats:attack(player, target, troops: number)
	addAttack(self, player, Stats.ATTACK_INDEX_SENT, troops)
	if target:isPlayer() then
		addAttack(self, target, Stats.ATTACK_INDEX_RECV, troops)
	end
end

function Stats:attackMaxIncoming(target, troops: number)
	if not target:isPlayer() then
		return
	end
	maxAttack(self, target, Stats.ATTACK_INDEX_MAX_RECV, troops)
end

function Stats:attackCancel(player, target, troops: number)
	addAttack(self, player, Stats.ATTACK_INDEX_CANCEL, troops)
	addAttack(self, player, Stats.ATTACK_INDEX_SENT, -troops)
	if target:isPlayer() then
		addAttack(self, target, Stats.ATTACK_INDEX_RECV, -troops)
	end
end

-- Attacks sent (troops) for a player, 0 when none recorded.
function Stats:attacksSent(player): number
	local p = self:getPlayerStats(player)
	if p == nil or p.attacks == nil then
		return 0
	end
	return p.attacks[Stats.ATTACK_INDEX_SENT] or 0
end

-- MIRV count feeds the MIRV price (Config.unitInfo).
function Stats:numMirvsLaunched(): number
	return self._mirvsLaunched or 0
end

-- Only the MIRV launch count has a simulation effect (the MIRV price);
-- per-player bomb tallies are results-screen data.
function Stats:bombLaunch(_player, _target, nukeType: string)
	if nukeType == "MIRV" then
		self._mirvsLaunched = (self._mirvsLaunched or 0) + 1
	end
end

-- Recorded upstream for the results screen; no simulation effect.
local function noop() end
Stats.boatSendTroops = noop
Stats.boatArriveTroops = noop
Stats.boatDestroyTroops = noop
Stats.boatCapturedTroops = noop
Stats.boatDestroyTrade = noop
Stats.boatSendTrade = noop
Stats.boatArriveTrade = noop
Stats.boatCapturedTrade = noop
Stats.unitBuild = noop
Stats.unitCapture = noop
Stats.unitLose = noop
Stats.unitDestroy = noop
Stats.goldWork = noop
Stats.goldWar = noop
Stats.recordTickSample = noop
Stats.recordFinalTiles = noop
Stats.recordAlliancesAtEnd = noop
Stats.recordKill = noop
Stats.recordKilledBy = noop
Stats.recordDeathPosition = noop
Stats.playerKilled = noop
Stats.betray = noop
Stats.bombLand = noop
Stats.bombIntercept = noop
Stats.allianceFormed = noop
Stats.allianceEnded = noop

return Stats
