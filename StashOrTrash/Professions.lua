local _, ns = ...

local SafeCall = ns.SafeCall
local POISONS = 40

---------------------------------------------------------------------------
-- Which professions does the logged-in character have?
---------------------------------------------------------------------------

local function GetChildSkill(profID)
	-- Forever tracks skill on a child skill line (e.g. 2937 under Alchemy 171).
	local best, bestMax = 0, 0
	local ids = { profID }
	for _, child in ipairs(ns.Professions[profID].children) do
		ids[#ids + 1] = child
	end
	for _, id in ipairs(ids) do
		local info = C_TradeSkillUI and SafeCall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, id)
		if type(info) == "table" and (info.skillLevel or 0) > best then
			best, bestMax = info.skillLevel, info.maxSkillLevel or 0
		end
	end
	return best, bestMax
end

-- Classic Era has no GetProfessions(); professions are rows of the Skills list,
-- identified only by their (localized) name. Collapsed headers hide their rows,
-- so expand them for the scan and collapse them again afterwards.
local function DetectFromSkillLines()
	local found, reopened = {}, {}
	local i = 1
	while i <= (SafeCall(GetNumSkillLines) or 0) do
		local name, isHeader, isExpanded, rank, _, _, maxRank = SafeCall(GetSkillLineInfo, i)
		if isHeader then
			if not isExpanded and type(ExpandSkillHeader) == "function" then
				-- Expanding fires SKILL_LINES_CHANGED; don't rescan because of our own change.
				ns.ignoreSkillEventsUntil = GetTime() + 2
				ExpandSkillHeader(i)
				reopened[name] = true
			end
		else
			local parent = ns.ProfessionFromName(name)
			if parent then
				found[parent] = { rank = rank or 0, max = maxRank or 0 }
			end
		end
		i = i + 1
	end
	if next(reopened) and type(CollapseSkillHeader) == "function" then
		-- Bottom-up, so collapsing doesn't shift the rows still to visit.
		for j = (SafeCall(GetNumSkillLines) or 0), 1, -1 do
			local name, isHeader = SafeCall(GetSkillLineInfo, j)
			if isHeader and reopened[name] then
				CollapseSkillHeader(j)
			end
		end
	end
	return found
end

-- Forever: GetProfessions() returns prof1, prof2, firstAid, fishing, cooking.
-- Any slot may be nil. Returns nil if the API is missing or fails.
local function DetectFromProfessionSlots()
	if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then
		return nil
	end
	local packed = { pcall(GetProfessions) }
	if not packed[1] then
		return nil
	end
	local found = {}
	for i = 2, table.maxn(packed) do
		local index = packed[i]
		if index then
			local name, _, rank, maxRank, _, _, skillLine = SafeCall(GetProfessionInfo, index)
			local parent = ns.ParentOf[skillLine] or ns.ProfessionFromName(name)
			if parent then
				rank, maxRank = rank or 0, maxRank or 0
				if rank == 0 then
					rank, maxRank = GetChildSkill(parent)
				end
				found[parent] = { rank = rank, max = maxRank }
			end
		end
	end
	return found
end

local function Count(t)
	local n = 0
	for _ in pairs(t or {}) do
		n = n + 1
	end
	return n
end

-- Returns { [profID] = { rank = n, max = n } }, or nil if no API is available.
-- Every available source is used and merged: the Classic Era client defines
-- GetProfessions() too, but it returns nothing there, so it can't be trusted
-- to be the only source.
function ns.DetectProfessions()
	local fromSlots = DetectFromProfessionSlots()
	local fromSkills = type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function"
		and DetectFromSkillLines() or nil
	ns.lastDetection = { slots = fromSlots and Count(fromSlots), skills = fromSkills and Count(fromSkills) }
	if not fromSlots and not fromSkills then
		return nil
	end

	local found = {}
	for _, source in ipairs({ fromSlots or {}, fromSkills or {} }) do
		for profID, entry in pairs(source) do
			if not found[profID] or entry.rank > found[profID].rank then
				found[profID] = entry
			end
		end
	end

	-- Rogue poisons are not one of Forever's profession slots.
	if not found[POISONS] and select(2, UnitClass("player")) == "ROGUE" then
		local rank, maxRank = GetChildSkill(POISONS)
		if rank > 0 then
			found[POISONS] = { rank = rank, max = maxRank }
		end
	end
	return found
end

function ns.ScanProfessions()
	local char = ns.GetMyChar()
	if not char then
		return
	end
	local found = ns.DetectProfessions()
	if not found then
		return
	end
	-- Right after login the API can briefly report no professions. Only believe
	-- "you have none" if it is still true a few seconds later.
	if next(found) == nil and next(char.profs) ~= nil and not ns.emptyScanSeen then
		ns.emptyScanSeen = true
		C_Timer.After(5, ns.ScanProfessions)
		return
	end
	ns.emptyScanSeen = nil
	-- Poisons can only be confirmed from the trade skill window on some builds; keep what it recorded.
	if not found[POISONS] and char.profs[POISONS] and char.class == "ROGUE" then
		found[POISONS] = char.profs[POISONS]
	end
	-- Dropping a profession forgets its recipes. An empty result can also mean the
	-- client has not loaded profession data yet, so never purge on that alone.
	for profID in pairs(char.profs) do
		if not found[profID] and next(found) ~= nil then
			for spellID in pairs(char.known) do
				local recipe = ns.GetRecipe(spellID)
				if not recipe or recipe[1] == profID then
					char.known[spellID] = nil
				end
			end
		end
	end
	char.profs = found
	char.updated = time()
end

---------------------------------------------------------------------------
-- Which recipes does the logged-in character know?
---------------------------------------------------------------------------

function ns.IsSpellKnown(spellID)
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		local ok, known = pcall(C_SpellBook.IsSpellKnown, spellID)
		if ok and not ns.IsSecret(known) then
			return known == true
		end
	end
	if type(IsPlayerSpell) == "function" then
		local ok, known = pcall(IsPlayerSpell, spellID)
		return ok and known == true
	end
	return false
end

local function RefreshKnownFrom(recipes, char)
	for spellID, recipe in pairs(recipes) do
		if char.profs[recipe[1]] and not char.known[spellID] and ns.IsSpellKnown(spellID) then
			char.known[spellID] = true
		end
	end
end

function ns.RefreshKnownRecipes()
	local char = ns.GetMyChar()
	if not char then
		return
	end
	RefreshKnownFrom(ns.Recipes, char)
	RefreshKnownFrom(ns.db.extraRecipes, char)
end

---------------------------------------------------------------------------
-- Trade skill window: authoritative skill level, learned recipes, and any
-- recipe missing from the shipped data (the beta keeps changing).
---------------------------------------------------------------------------

local function IsBasicReagentSlot(slot)
	local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
	if basic and slot.reagentType ~= nil then
		return slot.reagentType == basic
	end
	return slot.required ~= false
end

function ns.LearnRecipeFromClient(recipeID, profID, info)
	if ns.Recipes[recipeID] or ns.db.extraRecipes[recipeID] then
		return false
	end
	if info.isDummyRecipe or info.isGatheringRecipe or info.isSalvageRecipe or info.isRecraft then
		return false
	end
	local schematic = SafeCall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then
		return false
	end
	local reagents = {}
	for _, slot in ipairs(schematic.reagentSlotSchematics) do
		local reagent = slot.reagents and slot.reagents[1]
		if reagent and reagent.itemID and IsBasicReagentSlot(slot) then
			reagents[#reagents + 1] = reagent.itemID
			reagents[#reagents + 1] = slot.quantityRequired or 1
		end
	end
	if #reagents == 0 then
		return false
	end
	-- Required skill and difficulty are not exposed here; 0 means "unknown".
	local recipe = { profID, 0, 0, 0, info.name, reagents = reagents }
	ns.db.extraRecipes[recipeID] = recipe
	ns.IndexExtraRecipe(recipeID, recipe)
	return true
end

local function GetRecipeIDs()
	local ids = SafeCall(C_TradeSkillUI.GetAllRecipeIDs)
	if type(ids) ~= "table" then
		ids = SafeCall(C_TradeSkillUI.GetFilteredRecipeIDs)
	end
	return type(ids) == "table" and ids or {}
end

-- Classic Era trade skill and craft (Enchanting) windows ----------------------

local recipeByName = {}

-- The classic windows list recipes by name; map names back to recipe spell IDs.
local function RecipeIDFromName(profID, name)
	if type(name) ~= "string" or ns.IsSecret(name) then
		return nil
	end
	local map = recipeByName[profID]
	if not map then
		map = {}
		for spellID, recipe in pairs(ns.Recipes) do
			if recipe[1] == profID then
				map[recipe[5]:lower()] = spellID
				map[ns.GetRecipeName(spellID):lower()] = spellID
			end
		end
		recipeByName[profID] = map
	end
	return map[name:lower()]
end

local function RecipeIDFromLink(link)
	if type(link) ~= "string" or ns.IsSecret(link) then
		return nil
	end
	local id = tonumber(link:match("enchant:(%d+)")) or tonumber(link:match("spell:(%d+)"))
	return id and ns.GetRecipe(id) and id or nil
end

local function RecordClassicWindow(profName, rank, maxRank, count, getInfo, getLink)
	local char = ns.GetMyChar()
	local profID = ns.ProfessionFromName(profName)
	if not char or not profID then
		return
	end
	local entry = char.profs[profID] or {}
	if (rank or 0) > 0 or not char.profs[profID] then
		entry.rank, entry.max = rank or 0, maxRank or 0
	end
	char.profs[profID] = entry
	for i = 1, count or 0 do
		local name, kind = getInfo(i)
		if name and kind ~= "header" and kind ~= "subheader" then
			local spellID = RecipeIDFromLink(getLink and SafeCall(getLink, i)) or RecipeIDFromName(profID, name)
			if spellID then
				char.known[spellID] = true
			end
		end
	end
	char.updated = time()
end

function ns.ScanClassicTradeSkill()
	local name, rank, maxRank = SafeCall(GetTradeSkillLine)
	if not name or name == "UNKNOWN" then
		return
	end
	RecordClassicWindow(name, rank, maxRank, SafeCall(GetNumTradeSkills), function(i)
		local recipeName, kind = SafeCall(GetTradeSkillInfo, i)
		return recipeName, kind
	end, GetTradeSkillRecipeLink)
end

function ns.ScanCraft()
	-- Also used by Beast Training, which has no skill line and is ignored.
	local name, rank, maxRank = SafeCall(GetCraftDisplaySkillLine)
	if not name then
		return
	end
	RecordClassicWindow(name, rank, maxRank, SafeCall(GetNumCrafts), function(i)
		local craftName, _, craftType = SafeCall(GetCraftInfo, i)
		return craftName, craftType
	end, GetCraftRecipeLink or GetCraftItemLink)
end

function ns.ScanTradeSkill()
	if not (C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo) then
		return ns.ScanClassicTradeSkill()
	end
	-- Only record our own professions, not a linked/guild/NPC window.
	if SafeCall(C_TradeSkillUI.IsTradeSkillLinked) or SafeCall(C_TradeSkillUI.IsTradeSkillGuild)
		or SafeCall(C_TradeSkillUI.IsNPCCrafting) then
		return
	end
	local char = ns.GetMyChar()
	local base = SafeCall(C_TradeSkillUI.GetBaseProfessionInfo)
	if not char or type(base) ~= "table" then
		return
	end
	local profID = ns.ParentOf[base.professionID] or ns.ParentOf[base.parentProfessionID]
	if not profID then
		return
	end

	local rank, maxRank = base.skillLevel or 0, base.maxSkillLevel or 0
	local child = SafeCall(C_TradeSkillUI.GetChildProfessionInfo)
	if type(child) == "table" and (child.skillLevel or 0) > rank then
		rank, maxRank = child.skillLevel, child.maxSkillLevel or maxRank
	end
	local entry = char.profs[profID] or {}
	if rank > 0 or not char.profs[profID] then
		entry.rank, entry.max = rank, maxRank
	end
	char.profs[profID] = entry

	local learnedNew = 0
	for _, recipeID in ipairs(GetRecipeIDs()) do
		local info = SafeCall(C_TradeSkillUI.GetRecipeInfo, recipeID)
		if type(info) == "table" then
			if info.learned then
				char.known[recipeID] = true
			end
			if ns.LearnRecipeFromClient(recipeID, profID, info) then
				learnedNew = learnedNew + 1
			end
		end
	end
	char.updated = time()
	return learnedNew
end

---------------------------------------------------------------------------
-- Event wiring
---------------------------------------------------------------------------

local pending = {}
local function Debounce(key, delay, fn)
	if pending[key] then
		return
	end
	pending[key] = true
	C_Timer.After(delay, function()
		pending[key] = nil
		fn()
	end)
end

local function RefreshAll()
	ns.ScanProfessions()
	ns.RefreshKnownRecipes()
end

function ns.OnLogin()
	ns.GetMyChar()
	-- Profession info is not always ready at PLAYER_LOGIN.
	Debounce("refresh", 3, RefreshAll)
end

local function OnSkillChange()
	if GetTime() < (ns.ignoreSkillEventsUntil or 0) then
		return
	end
	Debounce("refresh", 1, RefreshAll)
end
ns.RegisterEvent("SKILL_LINES_CHANGED", OnSkillChange)
ns.RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE", OnSkillChange)
ns.RegisterEvent("CHAT_MSG_SKILL", OnSkillChange)

ns.RegisterEvent("NEW_RECIPE_LEARNED", function(_, recipeID)
	local char = ns.GetMyChar()
	if char and type(recipeID) == "number" then
		char.known[recipeID] = true
	end
end)

local function OnTradeSkill()
	Debounce("tradeskill", 0.5, ns.ScanTradeSkill)
end
ns.RegisterEvent("TRADE_SKILL_SHOW", OnTradeSkill)
ns.RegisterEvent("TRADE_SKILL_LIST_UPDATE", OnTradeSkill)
ns.RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", OnTradeSkill)
ns.RegisterEvent("TRADE_SKILL_UPDATE", OnTradeSkill) -- Classic Era

local function OnCraft()
	Debounce("craft", 0.5, ns.ScanCraft)
end
ns.RegisterEvent("CRAFT_SHOW", OnCraft) -- Classic Era Enchanting
ns.RegisterEvent("CRAFT_UPDATE", OnCraft)
