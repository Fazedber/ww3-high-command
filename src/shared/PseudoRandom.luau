--!native
-- Port of OpenFrontIO src/core/PseudoRandom.ts (sfc32 seeded by splitmix32).
--
-- Must produce the exact same stream as upstream: attack spread, bot
-- behaviour and spawns all draw from it.
--
-- Porting notes:
--  * JS keeps state as signed int32 (`| 0`); here state is unsigned 32-bit.
--    Every operation is mod 2^32, where the two are equivalent.
--  * Math.imul(a, b) needs the low 32 bits of a 64-bit product; a double only
--    holds 53 bits, so imul is built from 16-bit halves.
--  * Array helpers are 1-based (Luau arrays); the random draws are identical.

local band, bxor, bor = bit32.band, bit32.bxor, bit32.bor
local lshift, rshift = bit32.lshift, bit32.rshift

local TWO32 = 4294967296
local POW36_8 = 2821109907456 -- 36 ^ 8

local function imul(a: number, b: number): number
	local aHi, aLo = rshift(a, 16), band(a, 0xffff)
	local bHi, bLo = rshift(b, 16), band(b, 0xffff)
	-- Only the low 16 bits of the cross terms survive the << 16.
	local mid = (aHi * bLo + aLo * bHi) % 65536
	return (aLo * bLo + mid * 65536) % TWO32
end

-- JS ToInt32 as an unsigned 32-bit value (truncate toward zero, wrap mod 2^32).
local function toUint32(x: number): number
	if x ~= x or x == math.huge or x == -math.huge then
		return 0
	end
	local t = if x >= 0 then math.floor(x) else math.ceil(x)
	return t % TWO32
end

local PseudoRandom = {}
PseudoRandom.__index = PseudoRandom
PseudoRandom._imul = imul -- exposed for tests

function PseudoRandom.new(seed: number)
	-- The seed is truncated to 32 bits: seeds congruent mod 2^32 produce
	-- identical streams, and fractional parts are discarded.
	local h = toUint32(seed)
	local function split(): number
		h = (h + 0x9e3779b9) % TWO32
		local t = bxor(h, rshift(h, 16))
		t = imul(t, 0x21f0aaad)
		t = bxor(t, rshift(t, 15))
		t = imul(t, 0x735a2d97)
		return bxor(t, rshift(t, 15))
	end
	local self = setmetatable({ s0 = 0, s1 = 0, s2 = 0, s3 = 0 }, PseudoRandom)
	self.s0 = split()
	self.s1 = split()
	self.s2 = split()
	self.s3 = split()
	-- Warm up to diffuse low-entropy seeds (sequential ints, small numbers).
	for _ = 1, 12 do
		self:next()
	end
	return self
end

-- Next pseudorandom number in [0, 1).
function PseudoRandom:next(): number
	local s0, s1, s2, s3 = self.s0, self.s1, self.s2, self.s3
	local t = (s0 + s1 + s3) % TWO32
	self.s3 = (s3 + 1) % TWO32
	self.s0 = bxor(s1, rshift(s1, 9))
	self.s1 = (s2 + lshift(s2, 3)) % TWO32
	s2 = bor(lshift(s2, 21), rshift(s2, 11))
	self.s2 = (s2 + t) % TWO32
	return t / TWO32
end

-- Random integer in [min, max).
function PseudoRandom:nextInt(min: number, max: number): number
	local lo = math.floor(min)
	local hi = math.floor(max)
	return math.floor(self:next() * (hi - lo)) + lo
end

-- Random float in [min, max).
function PseudoRandom:nextFloat(min: number, max: number): number
	return self:next() * (max - min) + min
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

-- Random ID: 8 characters, base-36, zero-padded (Number.toString(36)).
function PseudoRandom:nextID(): string
	local n = math.floor(self:next() * POW36_8)
	local out = {}
	repeat
		local d = n % 36
		table.insert(out, 1, string.sub(DIGITS, d + 1, d + 1))
		n = n // 36
	until n == 0
	local s = table.concat(out)
	return string.rep("0", 8 - #s) .. s
end

-- Random element of a (1-based) array.
function PseudoRandom:randElement<T>(arr: { T }): T
	if #arr == 0 then
		error("array must not be empty")
	end
	return arr[self:nextInt(0, #arr) + 1]
end

-- Random element of a JSSet, in insertion order like a JS Set.
function PseudoRandom:randFromSet(set: any): any
	local size = set:size()
	if size == 0 then
		error("set must not be empty")
	end
	local index = self:nextInt(0, size)
	local i = 0
	for item in set do
		if i == index then
			return item
		end
		i += 1
	end
	error("Unexpected error selecting element from set")
end

-- True with probability 1/odds.
function PseudoRandom:chance(odds: number): boolean
	return self:nextInt(0, odds) == 0
end

-- Shuffled copy (Fisher-Yates, same draws as upstream).
function PseudoRandom:shuffleArray<T>(array: { T }): { T }
	local result = table.clone(array)
	for i = #result - 1, 1, -1 do
		local j = self:nextInt(0, i + 1)
		result[i + 1], result[j + 1] = result[j + 1], result[i + 1]
	end
	return result
end

return PseudoRandom
