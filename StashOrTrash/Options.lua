local _, ns = ...

---------------------------------------------------------------------------
-- Settings panel (Esc > Options > AddOns > Stash or Trash)
---------------------------------------------------------------------------

local function SectionHeader(layout, text)
	if layout and CreateSettingsListSectionHeaderInitializer then
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
	end
end

function ns.CreateSettings()
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then
		return
	end
	local S = ns.settings
	local category, layout = Settings.RegisterVerticalLayoutCategory("Stash or Trash")

	local function Checkbox(key, name, tooltip)
		local setting = Settings.RegisterAddOnSetting(category, "STASHORTRASH_" .. key:upper(), key, S,
			Settings.VarType.Boolean, name, ns.defaults[key])
		Settings.CreateCheckbox(category, setting, tooltip)
	end

	Checkbox("enabled", "Show on item tooltips",
		"Add Stash or Trash's lines to item tooltips.")
	Checkbox("showCounts", "Show recipe counts",
		"Next to each profession, show how many recipes using the item you already know, can learn at your current skill, and can learn later.")
	Checkbox("ignoreGray", "Ignore gray recipes",
		"Recipes that are gray to you (no more skill-ups) don't count. Useful once you have out-leveled the low-level materials. Note that some gray recipes, like bags and bandages, may still be worth crafting.")

	SectionHeader(layout, "Recipe list")
	do
		local setting = Settings.RegisterAddOnSetting(category, "STASHORTRASH_RECIPELIST", "recipeList", S,
			Settings.VarType.Number, "List recipes", ns.defaults.recipeList)
		local function GetOptions()
			local container = Settings.CreateControlTextContainer()
			container:Add(ns.LIST_NEVER, "Never")
			container:Add(ns.LIST_SHIFT, "While holding Shift")
			container:Add(ns.LIST_ALWAYS, "Always")
			return container:GetData()
		end
		Settings.CreateDropdown(category, setting, GetOptions,
			"Show the individual recipes that use the item, colored like the trade skill window.")
	end
	do
		local setting = Settings.RegisterAddOnSetting(category, "STASHORTRASH_MAXRECIPES", "maxRecipes", S,
			Settings.VarType.Number, "Recipes per profession", ns.defaults.maxRecipes)
		local options = Settings.CreateSliderOptions(1, 30, 1)
		if MinimalSliderWithSteppersMixin then
			options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
		end
		Settings.CreateSlider(category, setting, options,
			"How many recipes to list per profession before summarizing the rest.")
	end

	SectionHeader(layout, "Alts and other professions")
	Checkbox("includeAlts", "Include my alts",
		"Also count professions of your other characters on the same realm and faction. Log in on each alt once (and open its profession windows) so Stash or Trash can learn them. Dead Hardcore characters and Self-Found characters (which can't trade or use the mail) are left out.")
	Checkbox("showUnused", "Say when nothing uses the item",
		"When none of your characters' professions use the item, say so - a good hint to sell it.")
	Checkbox("showOtherProfessions", "Name the professions that do use it",
		"When none of your professions use the item, list the professions that do (handy when selling).")

	-- Planned professions
	local sub = Settings.RegisterVerticalLayoutSubcategory(category, "Planned professions")
	local ids = {}
	for profID in pairs(ns.Professions) do
		ids[#ids + 1] = profID
	end
	table.sort(ids, function(a, b)
		return ns.Professions[a].name < ns.Professions[b].name
	end)
	for _, profID in ipairs(ids) do
		local name = ns.GetProfessionName(profID)
		local setting = Settings.RegisterAddOnSetting(sub, "STASHORTRASH_PLAN_" .. profID, profID, S.manual,
			Settings.VarType.Boolean, name, false)
		Settings.CreateCheckbox(sub, setting,
			"Treat " .. name .. " as one of this account's professions even though you haven't learned it, so its materials are marked as worth keeping.")
	end

	Settings.RegisterAddOnCategory(category)
	ns.settingsCategory = category
end

function ns.OpenSettings()
	if ns.settingsCategory and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(ns.settingsCategory:GetID())
	else
		ns.Print("The settings panel is not available on this client. Use /sot help.")
	end
end

-- Addon compartment (the minimap drop-down), declared in the .toc.
function StashOrTrash_OnAddonCompartmentClick()
	ns.OpenSettings()
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function FormatProfs(char)
	local parts = {}
	for profID, entry in pairs(char.profs or {}) do
		parts[#parts + 1] = ns.GetProfessionName(profID) .. " " .. (entry.rank or 0) .. "/" .. (entry.max or 0)
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function CountKnown(char)
	local n = 0
	for _ in pairs(char.known or {}) do
		n = n + 1
	end
	return n
end

local function PrintStatus()
	local me = ns.GetMyChar()
	local recipes = 0
	for _ in pairs(ns.Recipes) do
		recipes = recipes + 1
	end
	local extra = 0
	for _ in pairs(ns.db.extraRecipes) do
		extra = extra + 1
	end
	ns.Print(("data from build %s: %d recipes (+%d learned in game); tooltip hook: %s"):format(
		ns.DataBuild, recipes, extra, tostring(ns.hookMode)))
	if me then
		ns.Print(("%s: %s; %d known recipes"):format(me.name or "?", FormatProfs(me), CountKnown(me)))
	end
	local detection = ns.lastDetection
	if detection then
		local function Source(n)
			return n and tostring(n) or "n/a"
		end
		ns.Print(("last detection: profession slots %s, skills list %s"):format(Source(detection.slots), Source(detection.skills)))
	end
	local planned = {}
	for profID, on in pairs(ns.settings.manual) do
		if on and ns.Professions[profID] then
			planned[#planned + 1] = ns.GetProfessionName(profID)
		end
	end
	if #planned > 0 then
		table.sort(planned)
		ns.Print("planned: " .. table.concat(planned, ", "))
	end
	for key, char in pairs(ns.db.chars) do
		if key ~= ns.myCharKey then
			local tags = char.faction or "?"
			if char.dead then
				tags = tags .. ", dead"
			elseif char.selfFound then
				tags = tags .. ", self-found"
			end
			ns.Print(("  alt %s (%s): %s"):format(key, tags, FormatProfs(char)))
		end
	end
end

-- Prints the tooltip lines for an item to chat, for debugging.
local function PrintItem(arg)
	local itemID = tonumber(arg) or tonumber(arg:match("item:(%d+)"))
	if not itemID then
		ns.Print("usage: /sot item <itemID or shift-clicked link>")
		return
	end
	local lines = {}
	local fake = {
		AddLine = function(_, text)
			lines[#lines + 1] = text
		end,
		AddDoubleLine = function(_, left, right)
			lines[#lines + 1] = left .. (right ~= "" and ("  -  " .. right) or "")
		end,
	}
	if not ns.AddToTooltip(fake, itemID) then
		ns.Print("item " .. itemID .. " is not a reagent in any known recipe.")
		return
	end
	ns.Print("item " .. itemID .. ":")
	for _, line in ipairs(lines) do
		print("  " .. line)
	end
end

local commands = {
	status = PrintStatus,
	scan = function()
		ns.ScanProfessions()
		ns.RefreshKnownRecipes()
		ns.ScanTradeSkill()
		ns.ScanCraft()
		PrintStatus()
	end,
	item = PrintItem,
	forget = function(arg)
		local key = arg and arg:match("^%s*(.-)%s*$")
		if not key or key == "" or not ns.db.chars[key] then
			ns.Print("usage: /sot forget <Name - Realm> (see /sot status)")
		elseif key == ns.myCharKey then
			ns.Print("can't forget the character you are logged in on.")
		else
			ns.db.chars[key] = nil
			ns.Print("forgot " .. key)
		end
	end,
	debug = function()
		ns.settings.debug = not ns.settings.debug
		ns.Print("debug " .. (ns.settings.debug and "on" or "off"))
	end,
	help = function()
		ns.Print("commands:")
		print("  /sot - open settings")
		print("  /sot status - detected professions, alts, data version")
		print("  /sot scan - re-detect professions and known recipes")
		print("  /sot item <id|link> - print what Stash or Trash says about an item")
		print("  /sot forget <Name - Realm> - stop tracking an alt")
	end,
}

SLASH_STASHORTRASH1 = "/sot"
SLASH_STASHORTRASH2 = "/stashortrash"
SlashCmdList.STASHORTRASH = function(msg)
	local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)$")
	cmd = cmd:lower()
	if cmd == "" then
		ns.OpenSettings()
	elseif commands[cmd] then
		commands[cmd](rest)
	else
		commands.help()
	end
end

function ns.OnInitialize()
	ns.hookMode = ns.HookTooltips()
	ns.CreateSettings()
end
