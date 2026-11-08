-- Port of renderNumber / renderTroops / formatPercentage from
-- OpenFrontIO src/client/Utils.ts. Troops display divided by 10, as upstream.

local Format = {}

local function fixed(v: number, digits: number): string
	return string.format(`%.{digits}f`, v)
end

function Format.renderNumber(num: number, fixedPoints: number?): string
	num = math.max(num, 0)
	if num >= 10000000000 then
		return fixed(math.floor(num / 100000000) / 10, fixedPoints or 1) .. "B"
	elseif num >= 1000000000 then
		return fixed(math.floor(num / 10000000) / 100, fixedPoints or 2) .. "B"
	elseif num >= 10000000 then
		return fixed(math.floor(num / 100000) / 10, fixedPoints or 1) .. "M"
	elseif num >= 1000000 then
		return fixed(math.floor(num / 10000) / 100, fixedPoints or 2) .. "M"
	elseif num >= 100000 then
		return tostring(math.floor(num / 1000)) .. "K"
	elseif num >= 10000 then
		return fixed(math.floor(num / 100) / 10, fixedPoints or 1) .. "K"
	elseif num >= 1000 then
		return fixed(math.floor(num / 10) / 100, fixedPoints or 2) .. "K"
	end
	return tostring(math.floor(num))
end

function Format.renderTroops(troops: number): string
	return Format.renderNumber(troops / 10)
end

function Format.formatPercentage(value: number): string
	local perc = value * 100
	if perc ~= perc then
		return "0%"
	end
	return fixed(perc, 1) .. "%"
end

return Format
