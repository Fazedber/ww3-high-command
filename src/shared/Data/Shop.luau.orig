-- Cosmetics shop catalogue (our own designs; upstream's premium patterns are
-- proprietary and not used). Everything here is cosmetic or a lobby
-- convenience: nothing changes the simulation (no pay-to-win).
--
-- productId / passId / SUBSCRIPTION_ID come from the Creator Dashboard
-- (Monetization). 0 / "" = not set up yet (the shop shows "Soon").
--
-- Patterns work like upstream's (PatternDecoder): the territory fill uses
-- the player's colour on primary cells and their border colour on the
-- others. rows: "#" = secondary cell; each cell covers 2^scale tiles.

local Shop = {}

-- Game passes -----------------------------------------------------------------------

Shop.PASSES = {
	supporter = { id = 1995368447, price = 199, name = "Supporter", desc = "Gold name and a thank-you from us" },
	color = { id = 1994426454, price = 149, name = "Custom colour", desc = "Pick your own territory colour (free for all)" },
	host = { id = 1994144462, price = 199, name = "Host Pass", desc = "All settings in your private matches: bots, gold, units" },
	flag = { id = 1994168457, price = 99, name = "Flag Pass", desc = "Show a country flag next to your name" },
}
Shop.SUPPORTER_PASS_ID = Shop.PASSES.supporter.id -- legacy name
Shop.SUPPORTER_PRICE = Shop.PASSES.supporter.price

-- Monthly subscription: every cosmetic and every pass perk while active.
Shop.SUBSCRIPTION_ID = "EXP-182183396271849982"
Shop.SUBSCRIPTION_PRICE = "R$ 399"

-- Developer products that are not single items.
Shop.DAILY_DEAL = { productId = 3714542965, price = 39 } -- today's featured item, cheaper
Shop.AD_REWARD = { productId = 3714542970, price = 25 } -- 24 h trial of a random cosmetic
Shop.TRIAL_SECONDS = 24 * 3600
-- Rebirth: after dying, come back with the biggest territory you had this match.
-- Bought rebirths are banked in the profile until used.
Shop.REBIRTH = { productId = 3714569822, price = 49 }

-- Items ------------------------------------------------------------------------------

Shop.items = {
	{ id = "pattern_stripes", kind = "pattern", name = "Stripes", price = 49, productId = 3714528403, scale = 1,
		rows = { "########", "        ", "        ", "        ", "########", "        ", "        ", "        " } },
	{ id = "pattern_checker", kind = "pattern", name = "Checker", price = 49, productId = 3714528650, scale = 1,
		rows = { "####    ", "####    ", "####    ", "####    ", "    ####", "    ####", "    ####", "    ####" } },
	{ id = "pattern_dots", kind = "pattern", name = "Dots", price = 49, productId = 3714528785, scale = 1,
		rows = { "        ", " ##     ", " ##     ", "        ", "        ", "     ## ", "     ## ", "        " } },
	{ id = "pattern_diagonal", kind = "pattern", name = "Diagonal", price = 79, productId = 3714528846, scale = 1,
		rows = { "##      ", " ##     ", "  ##    ", "   ##   ", "    ##  ", "     ## ", "      ##", "#      #" } },
	{ id = "pattern_bricks", kind = "pattern", name = "Bricks", price = 79, productId = 3714529041, scale = 1,
		rows = { "########", "   #    ", "   #    ", "   #    ", "########", "#       ", "#       ", "#       " } },
	{ id = "pattern_grid", kind = "pattern", name = "Grid", price = 79, productId = 3714542882, scale = 1,
		rows = { "########", "#       ", "#       ", "#       ", "#       ", "#       ", "#       ", "#       " } },
	{ id = "pattern_zigzag", kind = "pattern", name = "Zigzag", price = 79, productId = 3714542913, scale = 1,
		rows = { "#       ", " #     #", "  #   # ", "   # #  ", "    #   ", "        ", "        ", "        " } },
	{ id = "pattern_waves", kind = "pattern", name = "Waves", price = 99, productId = 3714529127, scale = 1,
		rows = { "        ", "##    ##", "  #  #  ", "   ##   ", "        ", "##    ##", "  #  #  ", "   ##   " } },
	{ id = "pattern_diamonds", kind = "pattern", name = "Diamonds", price = 99, productId = 3714529205, scale = 1,
		rows = { "   #    ", "  # #   ", " #   #  ", "#     # ", " #   #  ", "  # #   ", "   #    ", "        " } },
	{ id = "pattern_crosses", kind = "pattern", name = "Crosses", price = 99, productId = 3714529357, scale = 1,
		rows = { "        ", "   #    ", "   #    ", " #####  ", "   #    ", "   #    ", "        ", "        " } },
	{ id = "pattern_rings", kind = "pattern", name = "Rings", price = 99, productId = 3714542916, scale = 1,
		rows = { "  ####  ", " #    # ", "#      #", "#      #", "#      #", "#      #", " #    # ", "  ####  " } },
	{ id = "pattern_tartan", kind = "pattern", name = "Tartan", price = 99, productId = 3714542923, scale = 1,
		rows = { "## #  # ", "## #  # ", "########", "## #  # ", "## #  # ", "########", "## #  # ", "## #  # " } },
	{ id = "name_gold", kind = "nameColor", name = "Gold name", price = 99, productId = 3714529419, color = { 255, 214, 90 } },
	{ id = "name_cyan", kind = "nameColor", name = "Cyan name", price = 99, productId = 3714529488, color = { 94, 234, 212 } },
	{ id = "name_pink", kind = "nameColor", name = "Pink name", price = 99, productId = 3714529566, color = { 244, 114, 182 } },
	{ id = "name_red", kind = "nameColor", name = "Red name", price = 99, productId = 3714542927, color = { 248, 113, 113 } },
	{ id = "name_purple", kind = "nameColor", name = "Purple name", price = 99, productId = 3714542931, color = { 192, 132, 252 } },
	-- Nuke blast colours (flash, shockwave ring).
	{ id = "blast_plasma", kind = "explosion", name = "Plasma blast", price = 79, productId = 3714542934, flash = { 200, 230, 255 }, ring = { 80, 160, 255 } },
	{ id = "blast_toxic", kind = "explosion", name = "Toxic blast", price = 79, productId = 3714542939, flash = { 220, 255, 190 }, ring = { 90, 220, 70 } },
	{ id = "blast_void", kind = "explosion", name = "Void blast", price = 79, productId = 3714542942, flash = { 235, 210, 255 }, ring = { 170, 90, 255 } },
	{ id = "blast_solar", kind = "explosion", name = "Solar blast", price = 79, productId = 3714542944, flash = { 255, 250, 210 }, ring = { 255, 210, 40 } },
}

-- Bundles: one developer product granting several items.
Shop.bundles = {
	{ id = "bundle_patterns", name = "All patterns", price = 399, productId = 3714542953, kinds = { pattern = true } },
	{ id = "bundle_everything", name = "Everything bundle", price = 799, productId = 3714542961, kinds = { pattern = true, nameColor = true, explosion = true } },
}

-- Custom territory colours (Custom colour pass): distinct, readable hues.
Shop.COLORS = {
	{ 239, 68, 68 }, { 249, 115, 22 }, { 245, 158, 11 }, { 234, 179, 8 }, { 132, 204, 22 }, { 34, 197, 94 },
	{ 16, 185, 129 }, { 20, 184, 166 }, { 6, 182, 212 }, { 14, 165, 233 }, { 59, 130, 246 }, { 99, 102, 241 },
	{ 139, 92, 246 }, { 168, 85, 247 }, { 217, 70, 239 }, { 236, 72, 153 }, { 244, 63, 94 }, { 190, 18, 60 },
	{ 127, 29, 29 }, { 154, 52, 18 }, { 120, 53, 15 }, { 63, 98, 18 }, { 20, 83, 45 }, { 19, 78, 74 },
	{ 22, 78, 99 }, { 30, 58, 138 }, { 49, 46, 129 }, { 88, 28, 135 }, { 112, 26, 117 }, { 131, 24, 67 },
	{ 250, 250, 250 }, { 212, 212, 216 }, { 161, 161, 170 }, { 82, 82, 91 }, { 39, 39, 42 }, { 254, 240, 138 },
}

Shop.byId = {}
Shop.byProduct = {}
for _, item in Shop.items do
	Shop.byId[item.id] = item
	if item.productId ~= 0 then
		Shop.byProduct[item.productId] = item
	end
end
Shop.bundleByProduct = {}
for _, b in Shop.bundles do
	if b.productId ~= 0 then
		Shop.bundleByProduct[b.productId] = b
	end
end

-- Equip slot per item kind (plus "color" = palette index and "flag" = code).
Shop.SLOTS = { pattern = "pattern", nameColor = "nameColor", explosion = "explosion" }

-- Today's featured item for a player: rotates daily over the items, skipping
-- ones the player already owns (nil when they own everything).
function Shop.dailyItem(owned: { [string]: any }, now: number?)
	local day = math.floor((now or os.time()) / 86400)
	local n = #Shop.items
	for k = 0, n - 1 do
		local item = Shop.items[((day * 7 + k) % n) + 1]
		if not owned[item.id] then
			return item
		end
	end
	return nil
end

return Shop
