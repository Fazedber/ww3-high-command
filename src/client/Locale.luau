-- Locale: language of our own UI (menus, leader picker, HUD card).
-- Auto-detects Roblox locale (ru-* → Russian) and can be switched at runtime
-- (the menu rebuilds itself with the new strings).

local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")

local Locale = {}
Locale.lang = "en"

local function detect(): string
	local attr = Players.LocalPlayer:GetAttribute("Locale")
	if attr == "ru" or attr == "en" then
		return attr
	end
	local id = string.lower(LocalizationService.RobloxLocaleId or "")
	if string.sub(id, 1, 2) == "ru" then
		return "ru"
	end
	return "en"
end

Locale.lang = detect()

-- pick(ru, en): the string for the current language.
function Locale.pick(ru: string, en: string): string
	if Locale.lang == "ru" then
		return ru
	end
	return en
end

Locale.pick = Locale.pick

function Locale.setLanguage(code: string)
	if code ~= "ru" and code ~= "en" then
		return
	end
	Locale.lang = code
	Players.LocalPlayer:SetAttribute("Locale", code)
end

function Locale.other(): string
	return if Locale.lang == "ru" then "en" else "ru"
end

return Locale
