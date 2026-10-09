local _, ns = ...

-- Recipe states, in display order.
ns.STATE_KNOWN, ns.STATE_NOW, ns.STATE_LATER = 1, 2, 3

-- Difficulty as the trade skill window colors it.
ns.DIFF_RED, ns.DIFF_ORANGE, ns.DIFF_YELLOW, ns.DIFF_GREEN, ns.DIFF_GRAY, ns.DIFF_NONE = 1, 2, 3, 4, 5, 6

function ns.GetDifficulty(recipe, rank)
	local minSkill, yellowAt, grayAt = recipe[2], recipe[3], recipe[4]
	if rank < minSkill then
		return ns.DIFF_RED
	end
	if grayAt == 0 then
		return ns.DIFF_NONE
	end
	if rank >= grayAt then
		return ns.DIFF_GRAY
	end
	if yellowAt > 0 and rank < yellowAt then
		return ns.DIFF_ORANGE
	end
	-- Green starts halfway between yellow and gray.
	local greenAt = math.floor((yellowAt + grayAt) / 2)
	if rank >= greenAt then
		return ns.DIFF_GREEN
	end
	return ns.DIFF_YELLOW
end

-- Recipes that use itemID, grouped by profession: { [profID] = { {spellID, count, recipe}, ... } }
function ns.GetUsesByProfession(itemID)
	local byProf, seen, any = {}, {}, false
	ns.ForEachRecipeUsing(itemID, function(spellID, count)
		local recipe = ns.GetRecipe(spellID)
		if not recipe then
			return
		end
		if seen[spellID] then
			-- Same item in two reagent slots of one recipe.
			seen[spellID].count = seen[spellID].count + count
			return
		end
		local list = byProf[recipe[1]]
		if not list then
			list = {}
			byProf[recipe[1]] = list
		end
		local use = { spellID = spellID, count = count, recipe = recipe }
		list[#list + 1] = use
		seen[spellID] = use
		any = true
	end)
	return any and byProf or nil
end

local function SortRecipes(a, b)
	if a.state ~= b.state then
		return a.state < b.state
	end
	if a.gray ~= b.gray then
		return not a.gray
	end
	if a.recipe[2] ~= b.recipe[2] then
		return a.recipe[2] < b.recipe[2]
	end
	return a.spellID < b.spellID
end

-- Classifies the recipes of one profession for one character.
-- Returns { recipes = sorted list, known = n, now = n, later = n } or nil if
-- nothing is left after filtering.
function ns.ClassifyRecipes(uses, rank, known, ignoreGray)
	local result = { recipes = {}, known = 0, now = 0, later = 0 }
	for _, use in ipairs(uses) do
		local recipe = use.recipe
		local difficulty = ns.GetDifficulty(recipe, rank)
		local gray = difficulty == ns.DIFF_GRAY
		if not (ignoreGray and gray) then
			local state
			if known and known[use.spellID] then
				state = ns.STATE_KNOWN
				result.known = result.known + 1
			elseif rank >= recipe[2] then
				state = ns.STATE_NOW
				result.now = result.now + 1
			else
				state = ns.STATE_LATER
				result.later = result.later + 1
			end
			result.recipes[#result.recipes + 1] = {
				spellID = use.spellID,
				count = use.count,
				recipe = recipe,
				state = state,
				difficulty = difficulty,
				gray = gray,
			}
		end
	end
	if #result.recipes == 0 then
		return nil
	end
	table.sort(result.recipes, SortRecipes)
	return result
end

local function SortByName(a, b)
	return a.name < b.name
end

-- Builds everything the tooltip needs to say about an item.
-- Returns nil when the item is not a reagent for any known recipe, otherwise:
-- {
--   mine   = { { profID, name, rank, planned, recipes, known, now, later }, ... },
--   alts   = { { profID, name, chars = { {name, rank}, ... } }, ... },
--   others = { { profID, name }, ... },   -- professions none of your characters have
-- }
function ns.BuildReport(itemID)
	local byProf = ns.GetUsesByProfession(itemID)
	if not byProf then
		return nil
	end
	local settings = ns.settings
	local me = ns.GetMyChar()
	local myProfs = me and me.profs or {}
	local myKnown = me and me.known or {}
	local report = { mine = {}, alts = {}, others = {} }

	for profID, uses in pairs(byProf) do
		local name = ns.GetProfessionName(profID)
		local mineEntry = myProfs[profID]
		local planned = not mineEntry and settings.manual[profID]
		local handled = false

		if mineEntry or planned then
			local rank = mineEntry and mineEntry.rank or 0
			local result = ns.ClassifyRecipes(uses, rank, myKnown, settings.ignoreGray)
			if result then
				result.profID, result.name, result.rank, result.planned = profID, name, rank, planned and true or false
				report.mine[#report.mine + 1] = result
				handled = true
			end
		end

		if not handled and settings.includeAlts and ns.db then
			local alt = { profID = profID, name = name, chars = {} }
			for key, char in pairs(ns.db.chars) do
				local entry = key ~= ns.myCharKey and char.profs and char.profs[profID]
				if entry and ns.IsUsableAlt(char, me) then
					local result = ns.ClassifyRecipes(uses, entry.rank or 0, char.known, settings.ignoreGray)
					if result then
						alt.chars[#alt.chars + 1] = { name = char.name or key, rank = entry.rank or 0, result = result }
					end
				end
			end
			if #alt.chars > 0 then
				table.sort(alt.chars, function(a, b)
					if a.rank ~= b.rank then
						return a.rank > b.rank
					end
					return a.name < b.name
				end)
				report.alts[#report.alts + 1] = alt
				handled = true
			end
		end

		if not handled then
			report.others[#report.others + 1] = { profID = profID, name = name }
		end
	end

	table.sort(report.mine, SortByName)
	table.sort(report.alts, SortByName)
	table.sort(report.others, SortByName)
	return report
end
