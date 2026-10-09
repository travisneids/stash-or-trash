local addonName, ns = ...
_G.StashOrTrash = ns

ns.addonName = addonName

-- Recipe list display modes.
ns.LIST_NEVER, ns.LIST_SHIFT, ns.LIST_ALWAYS = 1, 2, 3

ns.defaults = {
	enabled = true,
	showCounts = true, -- "2 known · 3 now · 4 later" next to each profession
	recipeList = ns.LIST_SHIFT,
	maxRecipes = 8, -- per profession, when listing recipes
	includeAlts = true, -- also consider alts on the same realm and faction
	ignoreGray = false, -- recipes that are gray for you don't count
	showUnused = true, -- say so when none of your professions use the item
	showOtherProfessions = true, -- name the professions that do use it
	manual = {}, -- [professionSkillLineID] = true: treat as yours even if not learned
}

local DB_VERSION = 1

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------

local function IsSecret(value)
	return type(issecretvalue) == "function" and issecretvalue(value)
end
ns.IsSecret = IsSecret

-- Calls an API that may not exist on every client build, returning nothing on failure.
function ns.SafeCall(func, ...)
	if type(func) ~= "function" then
		return
	end
	local results = { pcall(func, ...) }
	if not results[1] then
		return
	end
	return unpack(results, 2, table.maxn(results))
end

function ns.Print(...)
	print("|cff33ff99Stash or Trash|r:", ...)
end

-- child skill line (e.g. 2937 "Alchemy") -> parent (171)
ns.ParentOf = {}
-- lower-case profession name (English and client language) -> parent skill line.
-- Classic Era only identifies professions by their localized name.
ns.ProfessionByName = {}
for id, info in pairs(ns.Professions) do
	ns.ParentOf[id] = id
	for _, child in ipairs(info.children) do
		ns.ParentOf[child] = id
	end
	ns.ProfessionByName[info.name:lower()] = id
end

function ns.ProfessionFromName(name)
	if type(name) ~= "string" or IsSecret(name) then
		return nil
	end
	return ns.ProfessionByName[name:lower()]
end

function ns.AddLocalizedProfessionNames()
	for id in pairs(ns.Professions) do
		local name = ns.GetProfessionName(id)
		if not IsSecret(name) then
			ns.ProfessionByName[name:lower()] = id
		end
	end
end

-- The data file must match the client: Forever is interface 16000+, Era is 1.x.
function ns.DataMatchesClient()
	local interface = select(4, GetBuildInfo())
	if type(interface) ~= "number" then
		return true
	end
	if ns.DataFlavor == "era" then
		return interface < 16000
	end
	return interface >= 16000
end

function ns.GetProfessionName(profID)
	local info = ns.Professions[profID]
	if not info then
		return tostring(profID)
	end
	-- Prefer the client's localized name when it is available.
	if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName then
		local name = ns.SafeCall(C_TradeSkillUI.GetTradeSkillDisplayName, profID)
		if type(name) == "string" and name ~= "" and not IsSecret(name) then
			return name
		end
	end
	return info.name
end

-- Returns the recipe tuple { prof, minSkill, yellowAt, grayAt, name } from the
-- shipped data or from recipes learned at runtime (see Professions.lua).
function ns.GetRecipe(spellID)
	return ns.Recipes[spellID] or (ns.db and ns.db.extraRecipes[spellID])
end

function ns.GetRecipeName(spellID)
	local name = C_Spell and ns.SafeCall(C_Spell.GetSpellName, spellID)
	if type(name) == "string" and name ~= "" and not IsSecret(name) then
		return name
	end
	local recipe = ns.GetRecipe(spellID)
	return recipe and recipe[5] or ("Recipe " .. spellID)
end

-- Recipes discovered at runtime, indexed the same way as ns.Reagents.
ns.ExtraReagents = {}

function ns.IndexExtraRecipe(spellID, recipe)
	local reagents = recipe.reagents
	if not reagents then
		return
	end
	for i = 1, #reagents, 2 do
		local itemID, count = reagents[i], reagents[i + 1]
		local list = ns.ExtraReagents[itemID]
		if not list then
			list = {}
			ns.ExtraReagents[itemID] = list
		end
		list[#list + 1] = spellID
		list[#list + 1] = count
	end
end

-- Calls fn(spellID, countRequired) for every recipe that uses itemID.
function ns.ForEachRecipeUsing(itemID, fn)
	local list = ns.Reagents[itemID]
	if list then
		for i = 1, #list, 2 do
			fn(list[i], list[i + 1])
		end
	end
	list = ns.ExtraReagents[itemID]
	if list then
		for i = 1, #list, 2 do
			if not ns.Recipes[list[i]] then
				fn(list[i], list[i + 1])
			end
		end
	end
end

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

local function ApplyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if target[key] == nil then
			if type(value) == "table" then
				target[key] = {}
				ApplyDefaults(target[key], value)
			else
				target[key] = value
			end
		end
	end
end

function ns.InitDB()
	StashOrTrashDB = type(StashOrTrashDB) == "table" and StashOrTrashDB or {}
	local db = StashOrTrashDB
	db.version = db.version or DB_VERSION
	db.settings = db.settings or {}
	db.chars = db.chars or {}
	db.extraRecipes = db.extraRecipes or {}
	ApplyDefaults(db.settings, ns.defaults)

	-- Data learned on an older build may have been folded into the shipped data since.
	if db.extraBuild ~= ns.DataBuild then
		wipe(db.extraRecipes)
		db.extraBuild = ns.DataBuild
	end

	ns.db = db
	ns.settings = db.settings
	wipe(ns.ExtraReagents)
	for spellID, recipe in pairs(db.extraRecipes) do
		ns.IndexExtraRecipe(spellID, recipe)
	end
end

function ns.GetCharacterKey()
	local name = UnitName("player")
	local realm = GetRealmName and GetRealmName() or ""
	if type(name) ~= "string" or IsSecret(name) or IsSecret(realm) then
		return nil
	end
	return name .. " - " .. realm, name, realm
end

-- The saved record for the logged-in character, created on demand.
function ns.GetMyChar()
	if ns.myChar then
		return ns.myChar
	end
	local key, name, realm = ns.GetCharacterKey()
	if not key or not ns.db then
		return nil
	end
	local char = ns.db.chars[key]
	if not char then
		char = {}
		ns.db.chars[key] = char
	end
	char.name, char.realm = name, realm
	char.class = select(2, UnitClass("player"))
	char.faction = UnitFactionGroup("player")
	ns.UpdateGameRules(char)
	char.profs = char.profs or {}
	char.known = char.known or {}
	ns.myCharKey = key
	ns.myChar = char
	return char
end

-- Classic Hardcore / Self-Found. A dead hardcore character, or a self-found one
-- (no trading or mail), can't make use of materials from its alts.
function ns.UpdateGameRules(char)
	local hardcore = C_GameRules and ns.SafeCall(C_GameRules.IsHardcoreActive)
	local selfFound = C_PlayerInfo and ns.SafeCall(C_PlayerInfo.IsSelfFoundActive)
	char.hardcore = hardcore == true or nil
	char.selfFound = selfFound == true or nil
	if char.hardcore and UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
		char.dead = true
	end
end

-- Can `char` (another character) use materials the logged-in character has?
function ns.IsUsableAlt(char, me)
	if char.dead then
		return false
	end
	if me then
		if me.selfFound or char.selfFound then
			return false
		end
		if char.realm ~= me.realm or char.faction ~= me.faction then
			return false
		end
	end
	return true
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
ns.eventFrame = frame
local handlers = {}

function ns.RegisterEvent(event, handler)
	-- Unknown events raise an error on modern clients; a beta may not have them all.
	if pcall(frame.RegisterEvent, frame, event) then
		handlers[event] = handler
		return true
	end
	return false
end

frame:SetScript("OnEvent", function(_, event, ...)
	local handler = handlers[event]
	if handler then
		handler(event, ...)
	end
end)

ns.RegisterEvent("PLAYER_DEAD", function()
	local char = ns.GetMyChar()
	if char then
		ns.UpdateGameRules(char)
		if char.hardcore then
			char.dead = true
		end
	end
end)

ns.RegisterEvent("ADDON_LOADED", function(_, loaded)
	if loaded ~= addonName then
		return
	end
	frame:UnregisterEvent("ADDON_LOADED")
	ns.InitDB()
	ns.AddLocalizedProfessionNames()
	if ns.OnInitialize then
		ns.OnInitialize()
	end
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
	if not ns.DataMatchesClient() then
		ns.Print(("this client is interface %s but the loaded recipe data is for %s. Make sure StashOrTrash.toc and StashOrTrash_Vanilla.toc are both installed."):format(
			tostring(select(4, GetBuildInfo())), ns.DataFlavor == "era" and "Classic Era" or "WoW Forever"))
	end
	if ns.OnLogin then
		ns.OnLogin()
	end
end)
