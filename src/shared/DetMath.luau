--!native
-- Port of OpenFrontIO src/core/DetMath.ts.
--
-- Deterministic replacements for the transcendental math functions. Upstream
-- uses them so every client computes the same bits; we keep them so the port
-- produces the same numbers as the original game (troop growth, attack
-- losses, nuke edges all truncate, so last-bit differences matter).
-- Only + - * / and bit views are used, which IEEE 754 rounds exactly.
--
-- Float64 bit views: upstream aliases a Float64Array with a Uint32Array;
-- here an 8-byte buffer does the same (little-endian: low word at 0, high at 4).

local DetMath = {}

local view = buffer.create(8)
local writef64, readf64 = buffer.writef64, buffer.readf64
local readu32, writeu32 = buffer.readu32, buffer.writeu32
local band, bor, rshift, lshift = bit32.band, bit32.bor, bit32.rshift, bit32.lshift

local LO, HI = 0, 4 -- byte offsets of the 32-bit words
local INF = math.huge

local LN2 = 0.6931471805599453
local LOG2E = 1.4426950408889634
local SQRT2 = 1.4142135623730951
local PI = 3.141592653589793
local PI_2 = 1.5707963267948966
local PI_4 = 0.7853981633974483
local TAN_PI_8 = 0.41421356237309503

-- 2 ^ n for integer n; exact, saturating to inf / 0 like Math.pow.
function DetMath.pow2(n: number): number
	if n > 1023 then
		return INF
	end
	if n < -1022 then
		return 0
	end
	writeu32(view, HI, lshift(n + 1023, 20))
	writeu32(view, LO, 0)
	return readf64(view, 0)
end
local pow2 = DetMath.pow2

-- e ^ x.
function DetMath.exp(x: number): number
	if x > 709 then
		return INF
	end
	if x < -708 then
		return 0
	end
	-- x = n ln2 + r, |r| <= ln2 / 2
	local n = math.floor(x * LOG2E + 0.5)
	local r = x - n * LN2
	-- Taylor to r^8; same association order as upstream.
	local p = 1
		+ r
			* (1 + r * (1 / 2 + r * (1 / 6 + r * (1 / 24 + r * (1 / 120 + r * (1 / 720 + r * (1 / 5040 + r * (1 / 40320))))))))
	return p * pow2(n)
end
local exp = DetMath.exp

-- Natural log of x > 0.
function DetMath.log(x: number): number
	if x <= 0 then
		return if x == 0 then -INF else 0 / 0
	end
	local e = 0
	if x < 2.2250738585072014e-308 then
		-- Subnormal: scale into the normal range first.
		x *= 18014398509481984 -- 2 ^ 54
		e = -54
	end
	writef64(view, 0, x)
	local hi = readu32(view, HI)
	e += band(rshift(hi, 20), 0x7ff) - 1023
	writeu32(view, HI, bor(band(hi, 0x000fffff), 0x3ff00000))
	local m = readf64(view, 0) -- [1, 2)
	if m > SQRT2 then
		m *= 0.5
		e += 1
	end
	-- log(m) = 2 atanh(s), s = (m - 1) / (m + 1), |s| <= 0.172
	local s = (m - 1) / (m + 1)
	local z = s * s
	local series = 1 + z * (1 / 3 + z * (1 / 5 + z * (1 / 7 + z * (1 / 9 + z * (1 / 11 + z * (1 / 13))))))
	return e * LN2 + 2 * s * series
end
local log = DetMath.log

-- x ^ y for x >= 0.
function DetMath.pow(x: number, y: number): number
	if y == 0 or x == 1 then
		return 1
	end
	if x == 0 then
		return if y > 0 then 0 else INF
	end
	if x < 0 then
		return 0 / 0
	end
	return exp(y * log(x))
end

-- atan(z) for z in [0, 1].
local function atanUnit(z: number): number
	-- Fold [tan(pi/8), 1] onto [-tan(pi/8), tan(pi/8)] around pi/4.
	local base = 0
	if z > TAN_PI_8 then
		base = PI_4
		z = (z - 1) / (z + 1)
	end
	local w = z * z
	local series = 1
		- w * (1 / 3 - w * (1 / 5 - w * (1 / 7 - w * (1 / 9 - w * (1 / 11 - w * (1 / 13 - w * (1 / 15 - w / 17)))))))
	return base + z * series
end

-- Angle of (x, y) in (-pi, pi], like Math.atan2 (ignoring signed zeros).
function DetMath.atan2(y: number, x: number): number
	if y == 0 then
		return if x >= 0 then 0 else PI
	end
	if x == 0 then
		return if y > 0 then PI_2 else -PI_2
	end
	local ax = if x < 0 then -x else x
	local ay = if y < 0 then -y else y
	local a = if ay <= ax then atanUnit(ay / ax) else PI_2 - atanUnit(ax / ay)
	if x < 0 then
		a = PI - a
	end
	return if y < 0 then -a else a
end

return DetMath
