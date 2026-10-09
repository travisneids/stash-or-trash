-- Minimal WoW client mock: just enough of the Forever (Mainline) API surface
-- for Stash or Trash to load and run outside the game. Tests tweak `Mock.state` and
-- the stubbed functions to simulate different characters.

Mock = { printed = {}, timers = {}, frames = {}, settings = {}, tooltipCallbacks = {} }

local state
function Mock.Reset()
	state = {
		name = "Tester",
		realm = "Testrealm",
		class = "PRIEST",
		faction = "Alliance",
		shift = false,
		-- index -> { name, icon, rank, maxRank, numSpells, spellOffset, skillLine }
		professionInfo = {},
		-- the 5 values GetProfessions() returns on Forever: prof1, prof2, firstAid, fishing, cooking
		professionSlots = {},
		knownSpells = {},
		skillLineInfo = {}, -- skillLineID -> ProfessionInfo table
		tradeSkill = nil, -- see tests
		secretValues = {},
		-- Classic Era
		skillLines = {}, -- { name, header = bool, expanded = bool, rank, max }
		classicTrade = nil, -- { name, rank, max, recipes = { { name, kind, link } } }
		craft = nil, -- same shape, for the Craft (Enchanting) window
		hardcore = false,
		selfFound = false,
		dead = false,
		time = 1000,
		interface = 16001,
	}
	Mock.state = state
	Mock.printed = {}
	Mock.timers = {}
	Mock.tooltipCallbacks = {}
	Mock.settings = { categories = {}, settings = {}, controls = 0 }
end
Mock.Reset()

-- Lua / WoW global helpers ---------------------------------------------------

function wipe(t)
	for k in pairs(t) do
		t[k] = nil
	end
	return t
end

function time()
	return 1700000000
end

function GetTime()
	return state.time
end

function GetBuildInfo()
	return "1.0.0", "1", "Jan 1 2026", state.interface
end

print = function(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	Mock.printed[#Mock.printed + 1] = table.concat(parts, " ")
end

function issecretvalue(value)
	return state.secretValues[value] == true
end

-- Frames & events -------------------------------------------------------------

local KNOWN_EVENTS = {
	ADDON_LOADED = true, PLAYER_LOGIN = true, SKILL_LINES_CHANGED = true,
	LEARNED_SPELL_IN_SKILL_LINE = true, CHAT_MSG_SKILL = true, NEW_RECIPE_LEARNED = true,
	TRADE_SKILL_SHOW = true, TRADE_SKILL_LIST_UPDATE = true, TRADE_SKILL_DATA_SOURCE_CHANGED = true,
	MODIFIER_STATE_CHANGED = true, PLAYER_DEAD = true,
}
-- Events only one client has.
local FOREVER_ONLY_EVENTS = { LEARNED_SPELL_IN_SKILL_LINE = true, TRADE_SKILL_DATA_SOURCE_CHANGED = true }
local ERA_ONLY_EVENTS = { TRADE_SKILL_UPDATE = true, CRAFT_SHOW = true, CRAFT_UPDATE = true }
Mock.KNOWN_EVENTS = KNOWN_EVENTS

function CreateFrame()
	local frame = { events = {}, scripts = {} }
	function frame:RegisterEvent(event)
		if not KNOWN_EVENTS[event] then
			error("Attempt to register unknown event \"" .. event .. "\"")
		end
		self.events[event] = true
	end
	function frame:UnregisterEvent(event)
		self.events[event] = nil
	end
	function frame:SetScript(name, fn)
		self.scripts[name] = fn
	end
	Mock.frames[#Mock.frames + 1] = frame
	return frame
end

function Mock.Fire(event, ...)
	for _, frame in ipairs(Mock.frames) do
		if frame.events[event] and frame.scripts.OnEvent then
			frame.scripts.OnEvent(frame, event, ...)
		end
	end
end

C_Timer = {}
function C_Timer.After(delay, fn)
	Mock.timers[#Mock.timers + 1] = { delay = delay, fn = fn }
end

function Mock.RunTimers()
	local guard = 0
	while #Mock.timers > 0 do
		local timer = table.remove(Mock.timers, 1)
		timer.fn()
		guard = guard + 1
		assert(guard < 100, "timer loop")
	end
end

-- Unit / character --------------------------------------------------------------

function UnitName()
	return state.name
end
function GetRealmName()
	return state.realm
end
function UnitClass()
	return state.class:sub(1, 1) .. state.class:sub(2):lower(), state.class
end
function UnitFactionGroup()
	return state.faction
end
function IsShiftKeyDown()
	return state.shift
end
function UnitIsDeadOrGhost()
	return state.dead
end

C_GameRules = {}
function C_GameRules.IsHardcoreActive()
	return state.hardcore
end
C_PlayerInfo = {}
function C_PlayerInfo.IsSelfFoundActive()
	return state.selfFound
end

-- Professions --------------------------------------------------------------------

function GetProfessions()
	local s = state.professionSlots
	return s[1], s[2], s[3], s[4], s[5]
end

function GetProfessionInfo(index)
	local p = state.professionInfo[index]
	if not p then
		return nil
	end
	return p.name, p.icon or 0, p.rank, p.maxRank, 2, 0, p.skillLine, 0, nil, nil, p.name
end

-- Adds a profession to the next free slot: Mock.AddProfession("Alchemy", 171, 120, 150, slot)
function Mock.AddProfession(name, skillLine, rank, maxRank, slot)
	local index = #state.professionInfo + 1
	state.professionInfo[index] = { name = name, skillLine = skillLine, rank = rank, maxRank = maxRank }
	state.professionSlots[slot] = index
	return index
end

C_SpellBook = {}
function C_SpellBook.IsSpellKnown(spellID)
	return state.knownSpells[spellID] == true
end

C_Spell = {}
function C_Spell.GetSpellName()
	return nil -- force the addon to use its bundled English names
end

C_Item = {}
function C_Item.GetItemInfoInstant(link)
	return tonumber(tostring(link):match("item:(%d+)"))
end

Enum = {
	TooltipDataType = { Item = 0, Spell = 1, Unit = 2 },
	CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 },
}

C_TradeSkillUI = {}
function C_TradeSkillUI.GetProfessionInfoBySkillLineID(skillLineID)
	return state.skillLineInfo[skillLineID]
		or { professionID = skillLineID, skillLevel = 0, maxSkillLevel = 0, professionName = "" }
end
function C_TradeSkillUI.GetTradeSkillDisplayName(skillLineID)
	return state.displayNames and state.displayNames[skillLineID] -- nil: use bundled English names
end
local function TS()
	return state.tradeSkill or {}
end
function C_TradeSkillUI.IsTradeSkillLinked()
	return TS().linked or false
end
function C_TradeSkillUI.IsTradeSkillGuild()
	return false
end
function C_TradeSkillUI.IsNPCCrafting()
	return false
end
function C_TradeSkillUI.GetBaseProfessionInfo()
	return TS().base
end
function C_TradeSkillUI.GetChildProfessionInfo()
	return TS().child
end
-- Forever's UI uses GetFilteredRecipeIDs; GetAllRecipeIDs is deliberately absent.
function C_TradeSkillUI.GetFilteredRecipeIDs()
	return TS().recipeIDs or {}
end
function C_TradeSkillUI.GetRecipeInfo(recipeID)
	return TS().recipeInfo and TS().recipeInfo[recipeID]
end
function C_TradeSkillUI.GetRecipeSchematic(recipeID)
	return TS().schematics and TS().schematics[recipeID]
end

-- Classic Era skills list -------------------------------------------------------

-- Visible rows, honoring collapsed headers.
local function VisibleSkillLines()
	local rows, hidden = {}, false
	for _, line in ipairs(state.skillLines) do
		if line.header then
			rows[#rows + 1] = line
			hidden = not line.expanded
		elseif not hidden then
			rows[#rows + 1] = line
		end
	end
	return rows
end

local era = {}
function era.GetNumSkillLines()
	return #VisibleSkillLines()
end
function era.GetSkillLineInfo(index)
	local line = VisibleSkillLines()[index]
	if not line then
		return nil
	end
	-- skillName, header, isExpanded, skillRank, numTempPoints, skillModifier, skillMaxRank, ...
	return line.name, line.header and 1 or nil, line.expanded and 1 or nil, line.rank or 0, 0, 0, line.max or 0
end
function era.ExpandSkillHeader(index)
	VisibleSkillLines()[index].expanded = true
	Mock.skillHeaderToggles = (Mock.skillHeaderToggles or 0) + 1
end
function era.CollapseSkillHeader(index)
	VisibleSkillLines()[index].expanded = false
	Mock.skillHeaderToggles = (Mock.skillHeaderToggles or 0) + 1
end
function era.GetTradeSkillLine()
	local t = state.classicTrade
	if not t then
		return "UNKNOWN", 0, 0
	end
	return t.name, t.rank, t.max
end
function era.GetNumTradeSkills()
	return state.classicTrade and #state.classicTrade.recipes or 0
end
function era.GetTradeSkillInfo(i)
	local r = state.classicTrade.recipes[i]
	return r.name, r.kind, 0, false
end
function era.GetTradeSkillRecipeLink(i)
	return state.classicTrade.recipes[i].link
end
function era.GetCraftDisplaySkillLine()
	local c = state.craft
	if not c or not c.name then
		return nil
	end
	return c.name, c.rank, c.max
end
function era.GetNumCrafts()
	return state.craft and #state.craft.recipes or 0
end
function era.GetCraftInfo(i)
	local r = state.craft.recipes[i]
	return r.name, "", r.kind, 0, false
end
function era.GetCraftItemLink(i)
	return state.craft.recipes[i].link
end

-- Switches the global API between the Forever and Classic Era clients.
local saved
function Mock.UseClient(flavor)
	if not saved then
		saved = {
			GetProfessions = GetProfessions,
			GetProfessionInfo = GetProfessionInfo,
			TradeSkillUI = C_TradeSkillUI,
		}
	end
	local isEra = flavor == "era"
	for name, fn in pairs(era) do
		_G[name] = isEra and fn or nil
	end
	-- The real Era client defines GetProfessions() (its world map calls it) but
	-- it returns nothing there.
	GetProfessions = isEra and function() end or saved.GetProfessions
	GetProfessionInfo = isEra and function() end or saved.GetProfessionInfo
	if isEra then
		-- Era's C_TradeSkillUI only has a couple of helpers.
		C_TradeSkillUI = { GetTradeSkillDisplayName = saved.TradeSkillUI.GetTradeSkillDisplayName }
	else
		C_TradeSkillUI = saved.TradeSkillUI
	end
	for event in pairs(FOREVER_ONLY_EVENTS) do
		KNOWN_EVENTS[event] = not isEra or nil
	end
	for event in pairs(ERA_ONLY_EVENTS) do
		KNOWN_EVENTS[event] = isEra or nil
	end
	state.interface = isEra and 11509 or 16001
	Mock.flavor = flavor
end

-- Tooltips -----------------------------------------------------------------------

TooltipDataProcessor = {}
function TooltipDataProcessor.AddTooltipPostCall(dataType, fn)
	Mock.tooltipCallbacks[#Mock.tooltipCallbacks + 1] = { type = dataType, fn = fn }
end

function Mock.NewTooltip(name)
	local tooltip = { name = name, lines = {}, shown = true, refreshed = 0 }
	function tooltip:AddLine(text, r, g, b, wrap)
		self.lines[#self.lines + 1] = { left = text, color = { r, g, b } }
	end
	function tooltip:AddDoubleLine(left, right, lr, lg, lb, rr, rg, rb)
		self.lines[#self.lines + 1] = { left = left, right = right, color = { lr, lg, lb }, rightColor = { rr, rg, rb } }
	end
	function tooltip:IsShown()
		return self.shown
	end
	function tooltip:IsForbidden()
		return self.forbidden == true
	end
	function tooltip:RefreshData()
		self.refreshed = self.refreshed + 1
	end
	function tooltip:Text()
		local out = {}
		for _, line in ipairs(self.lines) do
			out[#out + 1] = line.left .. (line.right and line.right ~= "" and (" | " .. line.right) or "")
		end
		return table.concat(out, "\n")
	end
	return tooltip
end

-- Simulates the client showing an item tooltip.
function Mock.ShowItem(tooltip, itemID)
	tooltip.lines = {}
	for _, cb in ipairs(Mock.tooltipCallbacks) do
		if cb.type == Enum.TooltipDataType.Item then
			cb.fn(tooltip, { id = itemID, type = Enum.TooltipDataType.Item })
		end
	end
	return tooltip
end

GameTooltip = Mock.NewTooltip("GameTooltip")
ItemRefTooltip = Mock.NewTooltip("ItemRefTooltip")

-- Settings -------------------------------------------------------------------------

Settings = { VarType = { Boolean = "boolean", String = "string", Number = "number" } }

local function NewCategory(name, parent)
	local category = { name = name, parent = parent, id = #Mock.settings.categories + 1 }
	function category:GetID()
		return self.id
	end
	Mock.settings.categories[#Mock.settings.categories + 1] = category
	local layout = { initializers = {} }
	function layout:AddInitializer(init)
		self.initializers[#self.initializers + 1] = init
	end
	return category, layout
end

function Settings.RegisterVerticalLayoutCategory(name)
	return NewCategory(name)
end
function Settings.RegisterVerticalLayoutSubcategory(parent, name)
	return NewCategory(name, parent)
end
function Settings.RegisterAddOnSetting(category, variable, key, tbl, varType, name, default)
	assert(type(tbl) == "table", "variableTbl must be a table")
	assert(Mock.settings.settings[variable] == nil, "duplicate setting variable " .. variable)
	if tbl[key] == nil then
		tbl[key] = default
	end
	assert(type(tbl[key]) == varType, ("setting %s has type %s, expected %s"):format(variable, type(tbl[key]), varType))
	local setting = { variable = variable, key = key, tbl = tbl, name = name, category = category }
	Mock.settings.settings[variable] = setting
	return setting
end
local function Control()
	Mock.settings.controls = Mock.settings.controls + 1
	return {}
end
Settings.CreateCheckbox = Control
Settings.CreateSlider = Control
function Settings.CreateDropdown(category, setting, options)
	Mock.settings.lastDropdownOptions = options()
	return Control()
end
function Settings.CreateSliderOptions(min, max, step)
	return { min = min, max = max, step = step, SetLabelFormatter = function() end }
end
function Settings.CreateControlTextContainer()
	local c = { data = {} }
	function c:Add(value, label)
		self.data[#self.data + 1] = { value = value, label = label }
	end
	function c:GetData()
		return self.data
	end
	return c
end
function Settings.RegisterAddOnCategory(category)
	Mock.settings.registered = category
end
function Settings.OpenToCategory(id)
	Mock.settings.opened = id
end
function CreateSettingsListSectionHeaderInitializer(text)
	return { header = text }
end
MinimalSliderWithSteppersMixin = { Label = { Right = 1 } }

SlashCmdList = {}

-- Loading ---------------------------------------------------------------------------

-- Loads the addon the way the client does: every file in .toc order with (addonName, ns).
function Mock.LoadAddon(root, addonName, tocName)
	local ns = {}
	local files = {}
	for line in io.lines(root .. "/" .. (tocName or addonName) .. ".toc") do
		line = line:gsub("\r", "")
		if line ~= "" and not line:match("^#") then
			files[#files + 1] = line:gsub("\\", "/")
		end
	end
	for _, file in ipairs(files) do
		local chunk, err = loadfile(root .. "/" .. file)
		if not chunk then
			error("failed to compile " .. file .. ": " .. tostring(err))
		end
		chunk(addonName, ns)
	end
	return ns, files
end
