-- Port of the simulation helpers from OpenFrontIO src/core/Util.ts.

local DetMath = require(script.Parent.DetMath)

local Util = {}

local TWO32 = 4294967296
local TWO31 = 2147483648
local MAX_SAFE_INTEGER = 9007199254740991

-- JS ToInt32: truncate toward zero, wrap to a signed 32-bit integer.
function Util.toInt32(x: number): number
	if x ~= x or x == math.huge or x == -math.huge then
		return 0
	end
	local t = if x >= 0 then math.floor(x) else math.ceil(x)
	t %= TWO32
	if t >= TWO31 then
		t -= TWO32
	end
	return t
end
local toInt32 = Util.toInt32

function Util.within(value: number, min: number, max: number): number
	return math.min(math.max(value, min), max)
end

function Util.sigmoid(value: number, decayRate: number, midpoint: number): number
	return 1 / (1 + DetMath.exp(-decayRate * (value - midpoint)))
end

-- Upstream converts to BigInt (gold). Gold is a plain integer-valued number
-- here: exact up to 2^53, far beyond any in-game amount.
function Util.toInt(num: number): number
	if num == math.huge then
		return MAX_SAFE_INTEGER
	end
	if num == -math.huge then
		return -MAX_SAFE_INTEGER
	end
	return math.floor(num)
end

-- Iterates UTF-16 code units of a UTF-8 string, like JS charCodeAt.
local function forEachCharCode(str: string, fn: (number) -> ())
	for _, cp in utf8.codes(str) do
		if cp >= 0x10000 then
			local v = cp - 0x10000
			fn(0xd800 + v // 0x400)
			fn(0xdc00 + v % 0x400)
		else
			fn(cp)
		end
	end
end

-- Java-style string hash, identical to upstream (int32 wraparound, then abs).
function Util.simpleHash(str: string): number
	local hash = 0
	forEachCharCode(str, function(char)
		hash = toInt32(toInt32(hash * 32) - hash + char)
	end)
	return math.abs(hash)
end

-- Stable in-place sort with a JS-style comparator (negative / 0 / positive).
-- Ported code must use this instead of table.sort: JS Array.prototype.sort is
-- stable, table.sort is not, and tie order changes simulation outcomes.
function Util.sort<T>(arr: { T }, cmp: (T, T) -> number): { T }
	local n = #arr
	if n < 2 then
		return arr
	end
	-- Bottom-up merge sort.
	local src, dst = arr, table.create(n)
	local width = 1
	while width < n do
		local i = 1
		while i <= n do
			local mid = math.min(i + width, n + 1)
			local hi = math.min(i + 2 * width, n + 1)
			local a, b, k = i, mid, i
			while a < mid and b < hi do
				-- Take from the left run on ties to keep the sort stable.
				if cmp(src[b], src[a]) < 0 then
					dst[k] = src[b]
					b += 1
				else
					dst[k] = src[a]
					a += 1
				end
				k += 1
			end
			while a < mid do
				dst[k] = src[a]
				a += 1
				k += 1
			end
			while b < hi do
				dst[k] = src[b]
				b += 1
				k += 1
			end
			i += 2 * width
		end
		src, dst = dst, src
		width *= 2
	end
	if src ~= arr then
		table.move(src, 1, n, 1, arr)
	end
	return arr
end

-- Upstream findMinimumBy / findClosestBy: first value with the strictly
-- smallest score among candidates, or nil.
function Util.findClosestBy<T>(values: { T }, score: (T) -> number, isCandidate: ((T) -> boolean)?): T?
	local best, bestScore = nil, math.huge
	for _, v in values do
		if isCandidate == nil or isCandidate(v) then
			local s = score(v)
			if s < bestScore then
				bestScore = s
				best = v
			end
		end
	end
	return best
end

-- JS-style comparator sorting tiles by Manhattan distance to `target`.
function Util.distSort(gm, target: number)
	return function(a: number, b: number): number
		return gm:manhattanDist(a, target) - gm:manhattanDist(b, target)
	end
end

function Util.formatPlayerDisplayName(username: string, clanTag: string?): string
	return if clanTag and clanTag ~= "" then `[{clanTag}] {username}` else username
end

return Util
