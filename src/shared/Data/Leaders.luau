-- 20 leaders for the leader-select screen and the HUD leader card.
-- Portraits are our own generated art (blocky "Roblox-style" busts).

local Leaders = {
	{ id = 1, name = "Маршал Громов", title = "ЖЕЛЕЗНЫЙ МАРШАЛ", portrait = "rbxassetid://121247977677295", name_en = "Marshal Gromov", title_en = "IRON MARSHAL" },
	{ id = 2, name = "Президент Вольт", title = "ИНЖЕНЕР ПОБЕДЫ", portrait = "rbxassetid://111904757827609", name_en = "President Volt", title_en = "ENGINEER OF VICTORY" },
	{ id = 3, name = "Канцлер Крамер", title = "СТАЛЬНОЙ КАНЦЛЕР", portrait = "rbxassetid://84417746312368", name_en = "Chancellor Kramer", title_en = "STEEL CHANCELLOR" },
	{ id = 4, name = "Генерал Сокол", title = "НЕБЕСНЫЙ ГЕНЕРАЛ", portrait = "rbxassetid://126846517722022", name_en = "General Sokol", title_en = "SKY GENERAL" },
	{ id = 5, name = "Адмирал Шторм", title = "ВЛАДЫКА МОРЕЙ", portrait = "rbxassetid://98162672437266", name_en = "Admiral Storm", title_en = "LORD OF THE SEAS" },
	{ id = 6, name = "Комиссар Заря", title = "КРАСНАЯ ЗАРЯ", portrait = "rbxassetid://90775409174161", name_en = "Commissar Zarya", title_en = "RED DAWN" },
	{ id = 7, name = "Король Людвиг", title = "ПОСЛЕДНИЙ КОРОЛЬ", portrait = "rbxassetid://80087847935111", name_en = "King Ludwig", title_en = "THE LAST KING" },
	{ id = 8, name = "Королева Изабелла", title = "ЖЕЛЕЗНАЯ КОРОЛЕВА", portrait = "rbxassetid://87804228430899", name_en = "Queen Isabella", title_en = "IRON QUEEN" },
	{ id = 9, name = "Премьер Ли", title = "ТИХИЙ ПРЕМЬЕР", portrait = "rbxassetid://135958761102902", name_en = "Premier Li", title_en = "QUIET PREMIER" },
	{ id = 10, name = "Диктатор Векс", title = "ТЕНЬ ПОРЯДКА", portrait = "rbxassetid://130464931920717", name_en = "Dictator Vex", title_en = "SHADOW OF ORDER" },
	{ id = 11, name = "Маршал Кай", title = "СЕВЕРНЫЙ ВОЛК", portrait = "rbxassetid://110558452265829", name_en = "Marshal Kai", title_en = "NORTHERN WOLF" },
	{ id = 12, name = "Президент Роуз", title = "МЕДНАЯ ЛЕДИ", portrait = "rbxassetid://98168070744308", name_en = "President Rose", title_en = "COPPER LADY" },
	{ id = 13, name = "Генерал Тит", title = "ОСАДНЫЙ ГЕНЕРАЛ", portrait = "rbxassetid://115615211748318", name_en = "General Titus", title_en = "SIEGE GENERAL" },
	{ id = 14, name = "Хан Атлас", title = "СТЕПНОЙ ХАН", portrait = "rbxassetid://77294567323392", name_en = "Khan Atlas", title_en = "STEPPE KHAN" },
	{ id = 15, name = "Вождь Орёл", title = "ВОЖДЬ СВОБОДНЫХ", portrait = "rbxassetid://133635745110939", name_en = "Chief Oryol", title_en = "CHIEF OF THE FREE" },
	{ id = 16, name = "Царь Николай", title = "САМОДЕРЖЕЦ", portrait = "rbxassetid://124982109809680", name_en = "Tsar Nikolai", title_en = "AUTOCRAT" },
	{ id = 17, name = "Президент Майя", title = "ОГНЕННАЯ ПРЕЗИДЕНТ", portrait = "rbxassetid://101582240679191", name_en = "President Maya", title_en = "FIERY PRESIDENT" },
	{ id = 18, name = "Легат Марк", title = "ЛЕГИОН", portrait = "rbxassetid://139583111086642", name_en = "Legate Mark", title_en = "LEGION" },
	{ id = 19, name = "Коммодор Блэк", title = "ПИРАТСКИЙ ЛОРД", portrait = "rbxassetid://137132085949236", name_en = "Commodore Black", title_en = "PIRATE LORD" },
	{ id = 20, name = "Судья Кейн", title = "ЗАКОН ВОЙНЫ", portrait = "rbxassetid://93004066848275", name_en = "Judge Kane", title_en = "LAW OF WAR" },
}

Leaders.byId = {}
for _, leader in ipairs(Leaders) do
	Leaders.byId[leader.id] = leader
end

Leaders.DEFAULT_FLAGS = {
	"us", "ru", "de", "fr", "gb", "cn", "jp", "in", "br",
	"ca", "au", "it", "es", "tr", "kr", "mx", "ua", "pl", "eu",
}

return Leaders
