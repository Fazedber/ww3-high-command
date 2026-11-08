-- Checks the Luau port against golden vectors produced by the original
-- OpenFrontIO TypeScript (tools/gen-vectors.mts). Run in Studio:
--   return require(game.ServerStorage.Tests.CoreSpec)()

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local V = require(script.Parent.Vectors)

local DetMath = require(Shared.DetMath)
local FlatBinaryHeap = require(Shared.FlatBinaryHeap)
local PseudoRandom = require(Shared.PseudoRandom)
local Util = require(Shared.Util)

local scratch = buffer.create(8)
local function f64(w: { number }): number
	buffer.writeu32(scratch, 4, w[1])
	buffer.writeu32(scratch, 0, w[2])
	return buffer.readf64(scratch, 0)
end
local function sameBits(x: number, w: { number }): boolean
	buffer.writef64(scratch, 0, x)
	return buffer.readu32(scratch, 4) == w[1] and buffer.readu32(scratch, 0) == w[2]
end

return function()
	local results = {}
	local function suite(name: string)
		local s = { name = name, pass = 0, fail = 0, failures = {} }
		table.insert(results, s)
		return function(ok: boolean, detail: string)
			if ok then
				s.pass += 1
			else
				s.fail += 1
				if #s.failures < 5 then
					table.insert(s.failures, detail)
				end
			end
		end
	end

	-- DetMath: bit-exact against upstream.
	do
		local check = suite("DetMath")
		for _, c in V.detmath.exp do
			local x = f64(c[1])
			local got = DetMath.exp(x)
			check(sameBits(got, c[2]), `exp({x}) = {got}, want {f64(c[2])}`)
		end
		for _, c in V.detmath.log do
			local x = f64(c[1])
			local got = DetMath.log(x)
			check(sameBits(got, c[2]), `log({x}) = {got}, want {f64(c[2])}`)
		end
		for _, c in V.detmath.pow do
			local x, y = f64(c[1]), f64(c[2])
			local got = DetMath.pow(x, y)
			check(sameBits(got, c[3]), `pow({x}, {y}) = {got}, want {f64(c[3])}`)
		end
		for _, c in V.detmath.pow2 do
			local got = DetMath.pow2(c[1])
			check(sameBits(got, c[2]), `pow2({c[1]}) = {got}, want {f64(c[2])}`)
		end
		for _, c in V.detmath.atan2 do
			local y, x = f64(c[1]), f64(c[2])
			local got = DetMath.atan2(y, x)
			check(sameBits(got, c[3]), `atan2({y}, {x}) = {got}, want {f64(c[3])}`)
		end
		for _, c in V.detmath.sigmoid do
			local got = Util.sigmoid(f64(c[1]), f64(c[2]), f64(c[3]))
			check(sameBits(got, c[4]), `sigmoid = {got}, want {f64(c[4])}`)
		end
	end

	-- PseudoRandom: identical streams for every seed shape.
	do
		local check = suite("PseudoRandom")
		for _, c in V.prng do
			local seed = f64(c.seed)
			local r = PseudoRandom.new(seed)
			for i, w in c.next do
				local got = r:next()
				check(sameBits(got, w), `seed {seed} next #{i} = {got}, want {f64(w)}`)
			end
			for i, want in c.ints do
				local got = r:nextInt(0, 7)
				check(got == want, `seed {seed} nextInt #{i} = {got}, want {want}`)
			end
			for i, want in c.ids do
				local got = r:nextID()
				check(got == want, `seed {seed} nextID #{i} = {got}, want {want}`)
			end
			local shuffled = r:shuffleArray({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
			local got, want = table.concat(shuffled, ","), table.concat(c.shuffled, ",")
			check(got == want, `seed {seed} shuffle = {got}, want {want}`)
		end
	end

	-- simpleHash: int32 wraparound and UTF-16 code units.
	do
		local check = suite("simpleHash")
		for _, c in V.hashes do
			local got = Util.simpleHash(c[1])
			check(got == c[2], `simpleHash({c[1]}) = {got}, want {c[2]}`)
		end
	end

	-- FlatBinaryHeap: same dequeue order, including float32 ties and grow().
	do
		local check = suite("FlatBinaryHeap")
		local heap = FlatBinaryHeap.new(4)
		for i, op in V.heapOps do
			if op[1] == "e" then
				heap:enqueue(op[2], f64(op[3]))
			else
				local got = heap:dequeue()
				check(got == op[2], `op #{i} dequeue = {got}, want {op[2]}`)
			end
		end
		check(heap:size() == 0, `heap not empty at end: {heap:size()}`)
	end

	-- Util.sort: stable like JS Array.prototype.sort.
	do
		local check = suite("Util.sort")
		local items = {}
		for i, k in V.sort.keys do
			table.insert(items, { id = i, key = k })
		end
		Util.sort(items, function(a, b)
			return a.key - b.key
		end)
		local got = {}
		for _, o in items do
			table.insert(got, o.id)
		end
		check(table.concat(got, ",") == table.concat(V.sort.expected, ","), "stable order differs")
	end

	local total, failed = 0, 0
	local lines = {}
	for _, s in results do
		total += s.pass + s.fail
		failed += s.fail
		table.insert(lines, string.format("%-16s %4d pass  %d fail", s.name, s.pass, s.fail))
		for _, f in s.failures do
			table.insert(lines, "    " .. f)
		end
	end
	table.insert(lines, string.format("TOTAL %d checks, %d failed", total, failed))
	return table.concat(lines, "\n")
end
