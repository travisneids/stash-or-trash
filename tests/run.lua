-- Stash or Trash test suite. Runs on plain Lua 5.1 (the WoW client's version):
--   lua5.1 tests/run.lua            (from the repository root)
-- or, without a system Lua: python3 tests/run_tests.py

local ROOT = (arg and arg[1]) or "."
dofile(ROOT .. "/tests/wow_mock.lua")

local ADDON_DIR = ROOT .. "/StashOrTrash"
local PEACEBLOOM, SILVERLEAF, LINEN_CLOTH, COPPER_BAR, HEARTHSTONE = 2447, 765, 2589, 2840, 6948
local ALCHEMY, FIRST_AID, COOKING, HERBALISM, TAILORING, POISONS = 171, 129, 185, 182, 197, 40

---------------------------------------------------------------------------
-- Tiny test framework
---------------------------------------------------------------------------

local tests, failures = {}, {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function fmt(v)
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function eq(actual, expected, msg)
	if actual ~= expected then
		error((msg or "values differ") .. ": expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
	end
end

local function ok(value, msg)
	if not value then
		error(msg or "expected a truthy value", 2)
	end
end

local function contains(haystack, needle, msg)
	if not haystack:find(needle, 1, true) then
		error((msg or "text missing") .. ": " .. fmt(needle) .. " not in:\n" .. haystack, 2)
	end
end

local function lacks(haystack, needle, msg)
	if haystack:find(needle, 1, true) then
		error((msg or "unexpected text") .. ": " .. fmt(needle) .. " found in:\n" .. haystack, 2)
	end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Fresh client + addon. `setup(state)` runs before login to configure the character.
local function Boot(opts)
	opts = opts or {}
	Mock.Reset()
	Mock.UseClient(opts.flavor or "forever")
	Mock.frames = {}
	Mock.skillHeaderToggles = 0
	StashOrTrashDB = opts.db
	if opts.before then
		opts.before(Mock.state)
	end
	local toc = opts.toc or (opts.flavor == "era" and "StashOrTrash_Vanilla" or "StashOrTrash")
	local ns, files = Mock.LoadAddon(ADDON_DIR, "StashOrTrash", toc)
	Mock.Fire("ADDON_LOADED", "StashOrTrash")
	Mock.Fire("PLAYER_LOGIN")
	Mock.RunTimers()
	return ns, files
end

local function Alchemist(rank)
	return function(s)
		Mock.AddProfession("Alchemy", ALCHEMY, rank, 150, 1)
	end
end

local function Show(itemID, tooltip)
	return Mock.ShowItem(tooltip or GameTooltip, itemID):Text()
end

-- Expected known/learnable/later counts for one profession, computed from the data.
local function ExpectedCounts(ns, itemID, profID, rank, known)
	local k, now, later, seen = 0, 0, 0, {}
	local list = ns.Reagents[itemID]
	for i = 1, #list, 2 do
		local spellID = list[i]
		local recipe = ns.Recipes[spellID]
		if recipe[1] == profID and not seen[spellID] then
			seen[spellID] = true
			if known[spellID] then
				k = k + 1
			elseif rank >= recipe[2] then
				now = now + 1
			else
				later = later + 1
			end
		end
	end
	return k, now, later
end

local function FindMine(report, profID)
	for _, entry in ipairs(report.mine) do
		if entry.profID == profID then
			return entry
		end
	end
end

local function NamesOf(list)
	local names = {}
	for i, entry in ipairs(list) do
		names[i] = entry.name
	end
	return table.concat(names, ",")
end

---------------------------------------------------------------------------
-- Loading & data
---------------------------------------------------------------------------

test("addon loads every .toc file and registers hooks, settings and slash command", function()
	local ns, files = Boot()
	eq(#files, 6, "toc file count")
	ok(ns.DataBuild:match("^1%.60%."), "data comes from a Forever (1.60.x) build")
	eq(#Mock.tooltipCallbacks, 1, "item tooltip post-call registered")
	eq(ns.hookMode, "TooltipDataProcessor")
	ok(Mock.settings.registered, "settings category registered")
	ok(SlashCmdList.STASHORTRASH, "slash command registered")
	ok(type(StashOrTrash_OnAddonCompartmentClick) == "function", "addon compartment handler")
	eq(_G.StashOrTrash, ns, "namespace exposed for debugging")
end)

test("recipe data is internally consistent", function()
	local ns = Boot()
	local recipes, profs = 0, 0
	for _ in pairs(ns.Professions) do
		profs = profs + 1
	end
	eq(profs, 13, "professions (12 + rogue poisons)")
	local used = {}
	for itemID, list in pairs(ns.Reagents) do
		ok(#list > 0 and #list % 2 == 0, "reagent list for " .. itemID .. " is spell/count pairs")
		for i = 1, #list, 2 do
			ok(ns.Recipes[list[i]], "reagent " .. itemID .. " points at unknown recipe " .. list[i])
			ok(list[i + 1] > 0, "positive reagent count")
			used[list[i]] = true
		end
	end
	for spellID, recipe in pairs(ns.Recipes) do
		recipes = recipes + 1
		ok(ns.Professions[recipe[1]], "recipe " .. spellID .. " has a known profession")
		ok(type(recipe[5]) == "string" and recipe[5] ~= "", "recipe " .. spellID .. " has a name")
		ok(recipe[2] >= 0 and recipe[3] >= 0 and recipe[4] >= 0, "recipe " .. spellID .. " skill values")
		ok(used[spellID], "recipe " .. spellID .. " uses at least one reagent")
	end
	ok(recipes > 2000, "expected 2000+ recipes, got " .. recipes)
	-- Spot checks against known Forever data.
	eq(ns.Recipes[3275][1], FIRST_AID, "Linen Bandage is First Aid")
	eq(ns.Recipes[3275][5], "Linen Bandage")
	eq(ns.ParentOf[2937], ALCHEMY, "Forever child skill line maps to its profession")
	eq(ns.ParentOf[ALCHEMY], ALCHEMY)
end)

test("Season of Discovery leftovers are not in the data", function()
	local ns = Boot()
	for spellID, recipe in pairs(ns.Recipes) do
		ok(not recipe[5]:find("%(OLD%)") and not recipe[5]:find("%[DNT%]"), "placeholder recipe " .. spellID)
	end
end)

---------------------------------------------------------------------------
-- Profession detection
---------------------------------------------------------------------------

test("detects professions from GetProfessions, including child skill lines and name fallback", function()
	local ns = Boot({
		before = function()
			Mock.AddProfession("Alchemy", ALCHEMY, 120, 150, 1)
			Mock.AddProfession("First Aid", 2942, 60, 75, 3) -- child skill line id
			Mock.AddProfession("Cooking", 987654, 30, 75, 5) -- unknown id -> match by name
		end,
	})
	local profs = ns.GetMyChar().profs
	eq(profs[ALCHEMY].rank, 120)
	eq(profs[ALCHEMY].max, 150)
	eq(profs[FIRST_AID].rank, 60)
	eq(profs[COOKING].rank, 30)
	eq(profs[TAILORING], nil)
end)

test("falls back to the child skill line when GetProfessionInfo reports rank 0", function()
	local ns = Boot({
		before = function(s)
			Mock.AddProfession("Alchemy", ALCHEMY, 0, 0, 1)
			s.skillLineInfo[2937] = { professionID = 2937, skillLevel = 88, maxSkillLevel = 150 }
		end,
	})
	eq(ns.GetMyChar().profs[ALCHEMY].rank, 88)
	eq(ns.GetMyChar().profs[ALCHEMY].max, 150)
end)

test("rogues get Poisons from its skill line", function()
	local ns = Boot({
		before = function(s)
			s.class = "ROGUE"
			s.skillLineInfo[2988] = { professionID = 2988, skillLevel = 100, maxSkillLevel = 300 }
		end,
	})
	eq(ns.GetMyChar().profs[POISONS].rank, 100)
	-- Non-rogues never get it.
	ns = Boot({
		before = function(s)
			s.skillLineInfo[2988] = { professionID = 2988, skillLevel = 100, maxSkillLevel = 300 }
		end,
	})
	eq(ns.GetMyChar().profs[POISONS], nil)
end)

test("login records known recipes via C_SpellBook.IsSpellKnown", function()
	local ns = Boot({
		before = function(s)
			Alchemist(50)(s)
			s.knownSpells[2331] = true -- Minor Mana Potion
			s.knownSpells[3275] = true -- Linen Bandage (First Aid, not learned -> ignored)
		end,
	})
	local char = ns.GetMyChar()
	ok(char.known[2331], "alchemy recipe recorded")
	eq(char.known[3275], nil, "recipes of professions you don't have are not scanned")
end)

test("dropping a profession forgets it and its recipes", function()
	local ns = Boot({
		before = function(s)
			Alchemist(50)(s)
			s.knownSpells[2331] = true
		end,
	})
	local char = ns.GetMyChar()
	ok(char.known[2331])
	Mock.state.professionInfo = {}
	Mock.state.professionSlots = {}
	Mock.AddProfession("Tailoring", TAILORING, 10, 75, 1)
	ns.ScanProfessions()
	eq(char.profs[ALCHEMY], nil, "alchemy dropped")
	ok(char.profs[TAILORING], "tailoring added")
	eq(char.known[2331], nil, "alchemy recipes forgotten")
end)

test("an empty profession list right after login is double-checked before trusting it", function()
	local ns = Boot({ before = Alchemist(50) })
	local char = ns.GetMyChar()
	Mock.state.professionSlots = {}
	ns.ScanProfessions()
	ok(char.profs[ALCHEMY], "kept after the first empty result")
	eq(#Mock.timers, 1, "re-check scheduled")
	Mock.RunTimers()
	eq(next(char.profs), nil, "accepted once confirmed")
end)

test("NEW_RECIPE_LEARNED marks the recipe known", function()
	local ns = Boot({ before = Alchemist(50) })
	Mock.Fire("NEW_RECIPE_LEARNED", 2332)
	ok(ns.GetMyChar().known[2332])
end)

test("addon still loads if the client lacks some events", function()
	Mock.KNOWN_EVENTS.LEARNED_SPELL_IN_SKILL_LINE = nil
	local okLoad, err = pcall(Boot, { before = Alchemist(10) })
	Mock.KNOWN_EVENTS.LEARNED_SPELL_IN_SKILL_LINE = true
	ok(okLoad, tostring(err))
end)

---------------------------------------------------------------------------
-- Difficulty & classification
---------------------------------------------------------------------------

test("difficulty colors follow the trade skill window thresholds", function()
	local ns = Boot()
	local r = { ALCHEMY, 1, 55, 95, "x" }
	eq(ns.GetDifficulty(r, 0), ns.DIFF_RED)
	eq(ns.GetDifficulty(r, 1), ns.DIFF_ORANGE)
	eq(ns.GetDifficulty(r, 54), ns.DIFF_ORANGE)
	eq(ns.GetDifficulty(r, 55), ns.DIFF_YELLOW)
	eq(ns.GetDifficulty(r, 74), ns.DIFF_YELLOW)
	eq(ns.GetDifficulty(r, 75), ns.DIFF_GREEN)
	eq(ns.GetDifficulty(r, 95), ns.DIFF_GRAY)
	eq(ns.GetDifficulty({ HERBALISM, 1, 0, 0, "x" }, 50), ns.DIFF_NONE)
end)

test("report splits an item's uses into yours and everyone else's", function()
	local ns = Boot({
		before = function(s)
			Alchemist(50)(s)
			s.knownSpells[2331] = true
		end,
	})
	local report = ns.BuildReport(PEACEBLOOM)
	local alchemy = FindMine(report, ALCHEMY)
	ok(alchemy, "alchemy listed as yours")
	local k, now, later = ExpectedCounts(ns, PEACEBLOOM, ALCHEMY, 50, { [2331] = true })
	eq(alchemy.known, k, "known")
	eq(alchemy.now, now, "learnable now")
	eq(alchemy.later, later, "later")
	eq(alchemy.known, 1)
	eq(alchemy.recipes[1].spellID, 2331, "known recipes sort first")
	eq(#report.alts, 0)
	eq(NamesOf(report.others), "Cooking,First Aid,Herbalism")
end)

test("non-reagents have no report", function()
	local ns = Boot({ before = Alchemist(50) })
	eq(ns.BuildReport(HEARTHSTONE), nil)
end)

test("ignoreGray drops recipes you have out-leveled", function()
	local ns = Boot({ before = Alchemist(150) })
	-- Silverleaf: every Alchemy recipe using it is gray by 150? Compute from data instead of assuming.
	local anyActive = false
	local list = ns.Reagents[SILVERLEAF]
	for i = 1, #list, 2 do
		local r = ns.Recipes[list[i]]
		if r[1] == ALCHEMY and ns.GetDifficulty(r, 150) ~= ns.DIFF_GRAY then
			anyActive = true
		end
	end
	ok(FindMine(ns.BuildReport(SILVERLEAF), ALCHEMY), "listed while gray recipes count")
	ns.settings.ignoreGray = true
	local report = ns.BuildReport(SILVERLEAF)
	if anyActive then
		ok(FindMine(report, ALCHEMY), "still listed: some recipes are not gray")
	else
		eq(FindMine(report, ALCHEMY), nil, "all gray -> not yours anymore")
		ok(NamesOf(report.others):find("Alchemy"), "moved to other professions")
	end
	-- A grand master alchemist has out-leveled everything that uses Peacebloom.
	ns = Boot({ before = Alchemist(300) })
	ns.settings.ignoreGray = true
	eq(FindMine(ns.BuildReport(PEACEBLOOM), ALCHEMY), nil)
end)

test("same reagent in two slots of one recipe is counted once with summed quantity", function()
	local ns = Boot({ before = Alchemist(50) })
	ns.Reagents[999] = { 2331, 1, 2331, 2 }
	local uses = ns.GetUsesByProfession(999)
	eq(#uses[ALCHEMY], 1)
	eq(uses[ALCHEMY][1].count, 3)
end)

---------------------------------------------------------------------------
-- Alts & planned professions
---------------------------------------------------------------------------

local function AltDB()
	return {
		chars = {
			["Alty - Testrealm"] = { name = "Alty", realm = "Testrealm", faction = "Alliance", profs = { [ALCHEMY] = { rank = 200, max = 225 } }, known = { [2331] = true } },
			["Hordey - Testrealm"] = { name = "Hordey", realm = "Testrealm", faction = "Horde", profs = { [COOKING] = { rank = 50, max = 75 } }, known = {} },
			["Faraway - Otherrealm"] = { name = "Faraway", realm = "Otherrealm", faction = "Alliance", profs = { [FIRST_AID] = { rank = 50, max = 75 } }, known = {} },
		},
	}
end

local function Tailor(s)
	Mock.AddProfession("Tailoring", TAILORING, 30, 75, 1)
end

test("alts on the same realm and faction count; others don't", function()
	local ns = Boot({ db = AltDB(), before = Tailor })
	local report = ns.BuildReport(PEACEBLOOM)
	eq(#report.mine, 0)
	eq(NamesOf(report.alts), "Alchemy")
	eq(report.alts[1].chars[1].name, "Alty")
	eq(report.alts[1].chars[1].rank, 200)
	eq(NamesOf(report.others), "Cooking,First Aid,Herbalism", "horde and other-realm alts excluded")
	local text = Show(PEACEBLOOM)
	contains(text, "Alchemy | Alty (200)")
	lacks(text, "Not used")
end)

test("includeAlts off ignores alts", function()
	local ns = Boot({ db = AltDB(), before = Tailor })
	ns.settings.includeAlts = false
	eq(#ns.BuildReport(PEACEBLOOM).alts, 0)
	contains(Show(PEACEBLOOM), "Not used by your professions")
end)

test("your own profession wins over an alt's", function()
	local ns = Boot({ db = AltDB(), before = Alchemist(10) })
	local report = ns.BuildReport(PEACEBLOOM)
	ok(FindMine(report, ALCHEMY))
	eq(#report.alts, 0)
end)

test("planned professions count as yours", function()
	local ns = Boot({ before = Tailor })
	ns.settings.manual[FIRST_AID] = true
	local report = ns.BuildReport(PEACEBLOOM)
	local fa = FindMine(report, FIRST_AID)
	ok(fa and fa.planned, "first aid planned")
	eq(fa.known + fa.now, 0, "rank 0: nothing learnable yet")
	ok(fa.later > 0)
	contains(Show(PEACEBLOOM), "First Aid |cff999999(planned)|r")
end)

test("the current character is never listed as its own alt", function()
	-- With ignoreGray, a 300 alchemist's own Alchemy drops out of "mine"; the alt
	-- lookup must not then find the same character in the saved data.
	local ns = Boot({ before = Alchemist(300) })
	ns.settings.ignoreGray = true
	local report = ns.BuildReport(PEACEBLOOM)
	eq(#report.alts, 0)
	lacks(Show(PEACEBLOOM), "Tester")
end)

---------------------------------------------------------------------------
-- Tooltip output
---------------------------------------------------------------------------

test("tooltip shows your profession with counts and a shift hint", function()
	local ns = Boot({
		before = function(s)
			Alchemist(50)(s)
			s.knownSpells[2331] = true
		end,
	})
	local text = Show(PEACEBLOOM)
	contains(text, "Alchemy")
	contains(text, "1 known")
	contains(text, "learnable")
	contains(text, "Hold Shift to list recipes")
	lacks(text, "Minor Mana Potion", "recipes hidden without shift")
	lacks(text, "Not used")
	ns.settings.showCounts = false
	lacks(Show(PEACEBLOOM), "1 known")
end)

test("holding shift lists recipes, capped by maxRecipes", function()
	local ns = Boot({
		before = function(s)
			Alchemist(50)(s)
			s.knownSpells[2331] = true
			s.shift = true
		end,
	})
	ns.settings.maxRecipes = 3
	local text = Show(PEACEBLOOM)
	contains(text, "Minor Mana Potion | known")
	lacks(text, "Hold Shift")
	local total = #FindMine(ns.BuildReport(PEACEBLOOM), ALCHEMY).recipes
	contains(text, "...and " .. (total - 3) .. " more")
end)

test("recipe list modes: always and never", function()
	local ns = Boot({ before = Alchemist(50) })
	ns.settings.recipeList = ns.LIST_ALWAYS
	local text = Show(PEACEBLOOM)
	contains(text, "Minor Mana Potion")
	lacks(text, "Hold Shift")
	ns.settings.recipeList = ns.LIST_NEVER
	text = Show(PEACEBLOOM)
	lacks(text, "Minor Mana Potion")
	lacks(text, "Hold Shift")
end)

test("recipes above your skill show their requirement", function()
	local ns = Boot({ before = Alchemist(1) })
	ns.settings.recipeList = ns.LIST_ALWAYS
	ns.settings.maxRecipes = 30
	-- Minor Rejuvenation Potion needs 40.
	contains(Show(PEACEBLOOM), "Minor Rejuvenation Potion | req. 40")
end)

test("unused items say so and name who could use them", function()
	local ns = Boot({ before = Tailor })
	local text = Show(PEACEBLOOM)
	contains(text, "Not used by your professions")
	contains(text, "Used in Alchemy, Cooking, First Aid, Herbalism")
	ns.settings.showOtherProfessions = false
	lacks(Show(PEACEBLOOM), "Used in")
	ns.settings.showUnused = false
	eq(Show(PEACEBLOOM), "")
end)

test("tooltip stays silent for non-reagents, when disabled, forbidden or secret", function()
	local ns = Boot({ before = Alchemist(50) })
	eq(Show(HEARTHSTONE), "")
	Mock.state.secretValues[PEACEBLOOM] = true
	eq(Show(PEACEBLOOM), "", "secret item id")
	Mock.state.secretValues[PEACEBLOOM] = nil
	GameTooltip.forbidden = true
	eq(Show(PEACEBLOOM), "", "forbidden tooltip")
	GameTooltip.forbidden = nil
	ns.settings.enabled = false
	eq(Show(PEACEBLOOM), "", "disabled")
end)

test("a gathering-heavy item: linen cloth for a tailor", function()
	Boot({ before = Tailor })
	local text = Show(LINEN_CLOTH)
	contains(text, "Tailoring")
end)

test("pressing shift refreshes a Stash or Trash tooltip in shift mode only", function()
	local ns = Boot({ before = Alchemist(50) })
	Show(PEACEBLOOM, GameTooltip)
	GameTooltip.refreshed = 0
	Mock.Fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1)
	eq(GameTooltip.refreshed, 1)
	Mock.Fire("MODIFIER_STATE_CHANGED", "LCTRL", 1)
	eq(GameTooltip.refreshed, 1, "other modifiers ignored")
	ns.settings.recipeList = ns.LIST_ALWAYS
	Mock.Fire("MODIFIER_STATE_CHANGED", "RSHIFT", 1)
	eq(GameTooltip.refreshed, 1, "no refresh outside shift mode")
	ns.settings.recipeList = ns.LIST_SHIFT
	Show(HEARTHSTONE, GameTooltip)
	Mock.Fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1)
	eq(GameTooltip.refreshed, 1, "tooltips without our lines are left alone")
end)

test("a secret player name doesn't break tooltips", function()
	local okBoot, err = pcall(Boot, {
		before = function(s)
			s.secretValues["Tester"] = true
		end,
	})
	ok(okBoot, tostring(err))
	contains(Show(PEACEBLOOM), "Not used by your professions")
end)

---------------------------------------------------------------------------
-- Trade skill window scanning
---------------------------------------------------------------------------

local function TradeSkillState(s)
	s.tradeSkill = {
		base = { professionID = ALCHEMY, skillLevel = 0, maxSkillLevel = 0 },
		child = { professionID = 2937, skillLevel = 145, maxSkillLevel = 150 },
		recipeIDs = { 2331, 999001, 999002 },
		recipeInfo = {
			[2331] = { recipeID = 2331, learned = true, name = "Minor Mana Potion" },
			[999001] = { recipeID = 999001, learned = false, name = "New Forever Brew" },
			[999002] = { recipeID = 999002, learned = true, name = "Dummy", isDummyRecipe = true },
		},
		schematics = {
			[999001] = {
				reagentSlotSchematics = {
					{ reagents = { { itemID = PEACEBLOOM } }, reagentType = 1, quantityRequired = 3 },
					{ reagents = { { itemID = 424242 } }, reagentType = 2, quantityRequired = 1 }, -- finishing: optional
					{ reagents = { { currencyID = 1 } }, reagentType = 1, quantityRequired = 1 },
				},
			},
			[999002] = { reagentSlotSchematics = { { reagents = { { itemID = 1 } }, reagentType = 1, quantityRequired = 1 } } },
		},
	}
end

test("opening a profession records skill, learned recipes and new recipes", function()
	local ns = Boot({ before = Alchemist(10) })
	TradeSkillState(Mock.state)
	Mock.Fire("TRADE_SKILL_SHOW")
	Mock.Fire("TRADE_SKILL_LIST_UPDATE") -- debounced with the first
	eq(#Mock.timers, 1)
	Mock.RunTimers()
	local char = ns.GetMyChar()
	eq(char.profs[ALCHEMY].rank, 145, "child skill level wins")
	ok(char.known[2331])
	local extra = ns.db.extraRecipes[999001]
	ok(extra, "unknown recipe learned from the schematic")
	eq(extra[1], ALCHEMY)
	eq(extra[5], "New Forever Brew")
	eq(#extra.reagents, 2, "only the basic item reagent")
	eq(extra.reagents[1], PEACEBLOOM)
	eq(extra.reagents[2], 3)
	eq(ns.db.extraRecipes[999002], nil, "dummy recipes skipped")
	eq(ns.ExtraReagents[424242], nil, "optional reagents skipped")
	local found = false
	for _, use in ipairs(ns.GetUsesByProfession(PEACEBLOOM)[ALCHEMY]) do
		found = found or use.spellID == 999001
	end
	ok(found, "new recipe shows up for the reagent immediately")
	Mock.state.shift = true
	ns.settings.maxRecipes = 30
	contains(Show(PEACEBLOOM), "New Forever Brew x3")
end)

test("learned recipes survive a reload but are dropped when the data build changes", function()
	local ns = Boot({ before = Alchemist(10) })
	TradeSkillState(Mock.state)
	ns.ScanTradeSkill()
	local db = StashOrTrashDB
	ns = Boot({ db = db, before = Alchemist(10) })
	ok(ns.ExtraReagents[PEACEBLOOM], "re-indexed after reload")
	db.extraBuild = "1.60.0.1"
	ns = Boot({ db = db, before = Alchemist(10) })
	eq(next(ns.db.extraRecipes), nil)
	eq(ns.ExtraReagents[PEACEBLOOM], nil)
end)

test("linked or other players' trade skills are not recorded", function()
	local ns = Boot({ before = Alchemist(10) })
	TradeSkillState(Mock.state)
	Mock.state.tradeSkill.linked = true
	ns.ScanTradeSkill()
	eq(ns.GetMyChar().profs[ALCHEMY].rank, 10)
	eq(ns.GetMyChar().known[2331], nil)
end)

test("a window for an unknown skill line is ignored", function()
	local ns = Boot({ before = Alchemist(10) })
	Mock.state.tradeSkill = { base = { professionID = 123456, skillLevel = 5, maxSkillLevel = 10 } }
	ns.ScanTradeSkill()
	eq(ns.GetMyChar().profs[123456], nil)
end)

test("a rogue's Poisons found via its window is kept across rescans", function()
	local ns = Boot({
		before = function(s)
			s.class = "ROGUE"
		end,
	})
	Mock.state.tradeSkill = { base = { professionID = 2988, skillLevel = 120, maxSkillLevel = 300 }, recipeIDs = {} }
	ns.ScanTradeSkill()
	eq(ns.GetMyChar().profs[POISONS].rank, 120)
	Mock.AddProfession("Alchemy", ALCHEMY, 10, 75, 1)
	ns.ScanProfessions()
	ok(ns.GetMyChar().profs[POISONS], "poisons kept")
	ok(ns.GetMyChar().profs[ALCHEMY])
end)

---------------------------------------------------------------------------
-- Settings & slash commands
---------------------------------------------------------------------------

test("settings register with defaults and keep saved values", function()
	local ns = Boot({ db = { settings = { maxRecipes = 12, recipeList = 3 } } })
	eq(ns.settings.maxRecipes, 12, "saved value kept")
	eq(ns.settings.recipeList, 3)
	eq(ns.settings.includeAlts, true, "missing values defaulted")
	eq(#Mock.settings.lastDropdownOptions, 3)
	local planned = 0
	for variable in pairs(Mock.settings.settings) do
		if variable:match("^STASHORTRASH_PLAN_") then
			planned = planned + 1
		end
	end
	eq(planned, 13, "one planned-profession checkbox per profession")
	eq(ns.settings.manual[ALCHEMY], false)
end)

test("slash commands", function()
	local ns = Boot({ db = AltDB(), before = Alchemist(50) })
	SlashCmdList.STASHORTRASH("")
	eq(Mock.settings.opened, ns.settingsCategory:GetID(), "bare command opens settings")
	Mock.printed = {}
	SlashCmdList.STASHORTRASH("status")
	local out = table.concat(Mock.printed, "\n")
	contains(out, "Alchemy 50/150")
	contains(out, "alt Alty - Testrealm")
	Mock.printed = {}
	SlashCmdList.STASHORTRASH("item |cffffffff|Hitem:2447::::::::60:::::|h[Peacebloom]|h|r")
	contains(table.concat(Mock.printed, "\n"), "Alchemy")
	Mock.printed = {}
	SlashCmdList.STASHORTRASH("item 6948")
	contains(table.concat(Mock.printed, "\n"), "not a reagent")
	SlashCmdList.STASHORTRASH("forget Alty - Testrealm")
	eq(ns.db.chars["Alty - Testrealm"], nil)
	Mock.printed = {}
	SlashCmdList.STASHORTRASH("forget Tester - Testrealm")
	contains(table.concat(Mock.printed, "\n"), "can't forget")
	Mock.printed = {}
	SlashCmdList.STASHORTRASH("nonsense")
	contains(table.concat(Mock.printed, "\n"), "/sot status")
	SlashCmdList.STASHORTRASH("scan")
	StashOrTrash_OnAddonCompartmentClick()
end)

---------------------------------------------------------------------------
-- Classic Era / Hardcore client
---------------------------------------------------------------------------

local function EraSkills(lines)
	return function(s)
		s.skillLines = lines
	end
end

local function EraAlchemist(rank)
	return EraSkills({
		{ name = "Professions", header = true, expanded = true },
		{ name = "Alchemy", rank = rank, max = 150 },
	})
end

test("era: StashOrTrash_Vanilla.toc loads Classic Era data", function()
	local ns, files = Boot({ flavor = "era" })
	eq(#files, 6)
	eq(files[1], "Data/Recipes_Era.lua")
	eq(ns.DataFlavor, "era")
	ok(ns.DataBuild:match("^1%.15%."), "data from a 1.15.x build")
	eq(ns.hookMode, "TooltipDataProcessor")
	local count = 0
	for spellID in pairs(ns.Recipes) do
		count = count + 1
		ok(spellID < 400000, "Season of Discovery recipe " .. spellID .. " leaked into Era data")
	end
	ok(count > 1200 and count < 1400, "vanilla has ~1300 recipes, got " .. count)
	eq(ns.Recipes[2330][1], ALCHEMY, "Minor Healing Potion is still Alchemy in Era")
	eq(ns.Recipes[2336], nil, "never-released Elixir of Tongues excluded")
	eq(ns.Recipes[6619], nil, "never-released Cowardly Flight Potion excluded")
	eq(ns.Recipes[22434], nil, "never-released Charged Scale of Onyxia excluded")
	for _, line in ipairs(Mock.printed) do
		lacks(line, "recipe data is for", "no flavor mismatch warning")
	end
end)

test("era: professions come from the Skills list, collapsed headers are restored", function()
	local ns = Boot({
		flavor = "era",
		before = EraSkills({
			{ name = "Professions", header = true, expanded = false },
			{ name = "Alchemy", rank = 120, max = 150 },
			{ name = "Herbalism", rank = 130, max = 150 },
			{ name = "Secondary Skills", header = true, expanded = true },
			{ name = "First Aid", rank = 75, max = 150 },
			{ name = "Weapon Skills", header = true, expanded = true },
			{ name = "Swords", rank = 50, max = 60 },
		}),
	})
	local profs = ns.GetMyChar().profs
	eq(profs[ALCHEMY].rank, 120, "found under a collapsed header")
	eq(profs[HERBALISM].rank, 130)
	eq(profs[FIRST_AID].rank, 75)
	eq(profs[FIRST_AID].max, 150)
	local count = 0
	for _ in pairs(profs) do
		count = count + 1
	end
	eq(count, 3, "weapon skills ignored")
	eq(Mock.state.skillLines[1].expanded, false, "header collapsed again")
	eq(Mock.skillHeaderToggles, 2)
	-- Our own expand/collapse must not trigger another scan...
	Mock.Fire("SKILL_LINES_CHANGED")
	eq(#Mock.timers, 0)
	-- ...but a real change later does.
	Mock.state.time = Mock.state.time + 5
	Mock.Fire("SKILL_LINES_CHANGED")
	eq(#Mock.timers, 1)
end)

test("era: an empty GetProfessions() doesn't hide the Skills list (regression)", function()
	-- Era defines GetProfessions() but it returns nothing; detection used to stop there,
	-- so professions only appeared after opening their window.
	local ns = Boot({ flavor = "era", before = EraAlchemist(42) })
	ok(type(GetProfessions) == "function", "mock matches the real Era client")
	eq(ns.GetMyChar().profs[ALCHEMY].rank, 42)
	contains(Show(PEACEBLOOM), "Alchemy")
	lacks(Show(PEACEBLOOM), "Not used")
	eq(ns.lastDetection.slots, 0)
	eq(ns.lastDetection.skills, 1)
	SlashCmdList.STASHORTRASH("status")
	contains(table.concat(Mock.printed, "\n"), "profession slots 0, skills list 1")
end)

test("both detection sources are merged, keeping the higher skill", function()
	local ns = Boot({
		before = function(s)
			Mock.AddProfession("Alchemy", ALCHEMY, 100, 150, 1)
			-- A client that has both APIs, each knowing part of the picture.
			GetNumSkillLines = function()
				return 3
			end
			local rows = { { "Professions", 1 }, { "Alchemy", nil, 120, 150 }, { "First Aid", nil, 40, 75 } }
			GetSkillLineInfo = function(i)
				local r = rows[i]
				return r[1], r[2], 1, r[3], 0, 0, r[4]
			end
		end,
	})
	GetNumSkillLines, GetSkillLineInfo = nil, nil
	local profs = ns.GetMyChar().profs
	eq(profs[ALCHEMY].rank, 120)
	eq(profs[FIRST_AID].rank, 40)
end)

test("era: localized profession names are recognized", function()
	local ns = Boot({
		flavor = "era",
		before = function(s)
			s.displayNames = { [ALCHEMY] = "Alchimie" }
			EraSkills({ { name = "Berufe", header = true, expanded = true }, { name = "Alchimie", rank = 33, max = 75 } })(s)
		end,
	})
	eq(ns.GetMyChar().profs[ALCHEMY].rank, 33)
	eq(ns.GetProfessionName(ALCHEMY), "Alchimie")
end)

test("era: rogue Poisons is a skill line", function()
	local ns = Boot({
		flavor = "era",
		before = function(s)
			s.class = "ROGUE"
			EraSkills({ { name = "Class Skills", header = true, expanded = true }, { name = "Poisons", rank = 150, max = 300 } })(s)
		end,
	})
	eq(ns.GetMyChar().profs[POISONS].rank, 150)
end)

test("era: the trade skill window records skill and known recipes by link or name", function()
	local ns = Boot({ flavor = "era", before = EraAlchemist(100) })
	Mock.state.classicTrade = {
		name = "Alchemy", rank = 140, max = 150,
		recipes = {
			{ name = "Elixirs", kind = "header" },
			{ name = "Minor Healing Potion", kind = "trivial", link = "|cffffffff|Henchant:2330|h[Minor Healing Potion]|h|r" },
			{ name = "Elixir of Minor Fortitude", kind = "easy" }, -- no link: matched by name
			{ name = "Something Unknown", kind = "easy" },
		},
	}
	Mock.Fire("TRADE_SKILL_SHOW")
	Mock.Fire("TRADE_SKILL_UPDATE")
	Mock.RunTimers()
	local char = ns.GetMyChar()
	eq(char.profs[ALCHEMY].rank, 140)
	ok(char.known[2330], "by link")
	ok(char.known[2334], "by name")
	ns.settings.recipeList = ns.LIST_ALWAYS
	contains(Show(PEACEBLOOM), "Minor Healing Potion | known")
end)

test("era: the craft window (Enchanting) is scanned, Beast Training is ignored", function()
	local ns = Boot({ flavor = "era" })
	Mock.state.craft = {
		name = "Enchanting", rank = 60, max = 75,
		recipes = { { name = "Enchant Bracer - Minor Health", kind = "optimal", link = "|cffffffff|Henchant:7418|h[Enchant Bracer - Minor Health]|h|r" } },
	}
	Mock.Fire("CRAFT_SHOW")
	Mock.RunTimers()
	local char = ns.GetMyChar()
	eq(char.profs[333].rank, 60)
	ok(char.known[7418])
	contains(Show(10940), "Enchanting", "Strange Dust is an enchanting reagent")
	Mock.state.craft = { name = nil, recipes = { { name = "Growl", kind = "optimal" } } }
	ns.ScanCraft()
	local count = 0
	for _ in pairs(char.profs) do
		count = count + 1
	end
	eq(count, 1, "beast training not recorded as a profession")
end)

test("era: tooltip uses Era recipes (Peacebloom is Alchemy only)", function()
	Boot({ flavor = "era", before = EraSkills({ { name = "Professions", header = true, expanded = true }, { name = "Tailoring", rank = 50, max = 75 } }) })
	local text = Show(PEACEBLOOM)
	contains(text, "Not used by your professions")
	contains(text, "Used in Alchemy")
	lacks(text, "First Aid", "healing potions are Alchemy in Era")
end)

test("era: /sot scan works with the classic API", function()
	Boot({ flavor = "era", before = EraAlchemist(10) })
	SlashCmdList.STASHORTRASH("scan")
	contains(table.concat(Mock.printed, "\n"), "Alchemy 10/150")
end)

local function HardcoreAlts()
	return {
		chars = {
			["Ghosty - Testrealm"] = { name = "Ghosty", realm = "Testrealm", faction = "Alliance", hardcore = true, dead = true, profs = { [ALCHEMY] = { rank = 250, max = 300 } }, known = {} },
			["Solo - Testrealm"] = { name = "Solo", realm = "Testrealm", faction = "Alliance", selfFound = true, profs = { [COOKING] = { rank = 100, max = 150 } }, known = {} },
			["Alive - Testrealm"] = { name = "Alive", realm = "Testrealm", faction = "Alliance", hardcore = true, profs = { [ALCHEMY] = { rank = 80, max = 150 } }, known = {} },
		},
	}
end

test("hardcore: dead and self-found alts don't count", function()
	local ns = Boot({ flavor = "era", db = HardcoreAlts(), before = function(s)
		s.hardcore = true
		EraSkills({ { name = "Professions", header = true, expanded = true }, { name = "Tailoring", rank = 50, max = 75 } })(s)
	end })
	local report = ns.BuildReport(PEACEBLOOM)
	eq(#report.alts, 1)
	eq(report.alts[1].chars[1].name, "Alive", "dead Ghosty skipped")
	ns.Reagents[999] = { 2330, 1, 818, 1 } -- one alchemy + one cooking recipe
	report = ns.BuildReport(999)
	ok(not NamesOf(report.alts):find("Cooking"), "self-found Solo skipped")
	Mock.printed = {}
	SlashCmdList.STASHORTRASH("status")
	local out = table.concat(Mock.printed, "\n")
	contains(out, "Ghosty - Testrealm (Alliance, dead)")
	contains(out, "Solo - Testrealm (Alliance, self-found)")
end)

test("hardcore: dying marks the character dead; dying on a normal realm doesn't", function()
	local ns = Boot({ flavor = "era", before = function(s)
		s.hardcore = true
	end })
	Mock.Fire("PLAYER_DEAD")
	ok(ns.GetMyChar().dead)
	ok(ns.GetMyChar().hardcore)
	ns = Boot({ flavor = "era" })
	Mock.Fire("PLAYER_DEAD")
	eq(ns.GetMyChar().dead, nil)
	-- Logging into an already-dead hardcore character also marks it.
	ns = Boot({ flavor = "era", before = function(s)
		s.hardcore = true
		s.dead = true
	end })
	ok(ns.GetMyChar().dead)
end)

test("self-found: a self-found character ignores all alts", function()
	local ns = Boot({ flavor = "era", db = HardcoreAlts(), before = function(s)
		s.selfFound = true
	end })
	ok(ns.GetMyChar().selfFound)
	eq(#ns.BuildReport(PEACEBLOOM).alts, 0)
end)

test("installing the wrong .toc for the client prints a warning", function()
	Boot({ flavor = "forever", toc = "StashOrTrash_Vanilla" })
	contains(table.concat(Mock.printed, "\n"), "recipe data is for Classic Era")
	Boot({ flavor = "era", toc = "StashOrTrash" })
	contains(table.concat(Mock.printed, "\n"), "recipe data is for WoW Forever")
end)

test("both .toc files list the same addon files apart from the data file", function()
	local function read(name)
		local lines = {}
		for line in io.lines(ADDON_DIR .. "/" .. name .. ".toc") do
			lines[#lines + 1] = line
		end
		return lines
	end
	local forever, era = read("StashOrTrash"), read("StashOrTrash_Vanilla")
	eq(#forever, #era)
	for i = 1, #forever do
		if forever[i]:match("^## Interface") then
			ok(era[i]:match("^## Interface: 115"), "era interface")
		elseif forever[i]:match("^Data") then
			eq(era[i], "Data\\Recipes_Era.lua")
		else
			eq(era[i], forever[i], "toc line " .. i)
		end
	end
end)

---------------------------------------------------------------------------
-- Run
---------------------------------------------------------------------------

local passed = 0
for _, t in ipairs(tests) do
	local success, err = pcall(t.fn)
	if success then
		passed = passed + 1
		io.write("  ok   ", t.name, "\n")
	else
		failures[#failures + 1] = t.name
		io.write("  FAIL ", t.name, "\n       ", tostring(err), "\n")
	end
end
io.write(("\n%d passed, %d failed\n"):format(passed, #failures))
if #failures > 0 then
	error("tests failed", 0)
end
