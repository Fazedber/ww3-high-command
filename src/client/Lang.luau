-- UI localisation. English is the source language; Shared/Data/Translations
-- (tools/pack-lang.mjs) maps source strings to other locales. init() picks
-- the player's locale and watches PlayerGui: any label or button whose text
-- is exactly a known source string is shown translated (also when the text
-- changes later). Text built at runtime goes through Lang.t(template, params).

local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")

local Lang = {}
local map: { [string]: string } = {}
local locale = "en"

local function hook(obj: Instance)
	if obj:IsA("TextLabel") or obj:IsA("TextButton") then
		obj.AutoLocalize = false
		local function apply()
			local tr = map[obj.Text]
			if tr then
				obj.Text = tr
			end
		end
		apply()
		obj:GetPropertyChangedSignal("Text"):Connect(apply)
	elseif obj:IsA("TextBox") then
		obj.AutoLocalize = false
		local tr = map[obj.PlaceholderText]
		if tr then
			obj.PlaceholderText = tr
		end
	end
end

function Lang.init()
	if locale ~= "en" or next(map) then
		return
	end
	local id = string.lower(LocalizationService.RobloxLocaleId) -- e.g. "pl-pl"
	local short = string.sub(id, 1, 2)
	if short == "en" then
		return
	end
	local entries = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Translations"))
	for _, e in entries do
		local v = e.values[id] or e.values[short]
		if v then
			map[e.source] = v
		end
	end
	if next(map) == nil then
		return
	end
	locale = short
	local gui = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, d in gui:GetDescendants() do
		hook(d)
	end
	gui.DescendantAdded:Connect(hook)
end

-- Two-letter language in use ("en" when untranslated).
function Lang.locale(): string
	return locale
end

-- Translate English source text, then fill {name} placeholders.
function Lang.t(source: string, params: { [string]: any }?): string
	local text = map[source] or source
	if params then
		text = string.gsub(text, "{(%w+)}", function(k)
			local v = params[k]
			return if v ~= nil then tostring(v) else "{" .. k .. "}"
		end)
	end
	return text
end

return Lang
