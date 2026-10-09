local _, ns = ...

local COLOR_PROF = { 1, 0.82, 0 }
local COLOR_ALT = { 0.45, 0.75, 1 }
local COLOR_DIM = { 0.6, 0.6, 0.6 }
local COLOR_UNUSED = { 0.75, 0.55, 0.55 }

-- Matches the trade skill window's difficulty colors.
local DIFFICULTY_COLORS = {
	[ns.DIFF_RED] = { 0.9, 0.3, 0.3 },
	[ns.DIFF_ORANGE] = { 1, 0.5, 0.25 },
	[ns.DIFF_YELLOW] = { 1, 1, 0 },
	[ns.DIFF_GREEN] = { 0.25, 0.75, 0.25 },
	[ns.DIFF_GRAY] = { 0.5, 0.5, 0.5 },
	[ns.DIFF_NONE] = { 0.9, 0.9, 0.9 },
}

local function Icon(profID)
	local info = ns.Professions[profID]
	return (info and info.icon and info.icon > 0) and ("|T" .. info.icon .. ":0|t ") or ""
end

local function CountsText(result)
	local parts = {}
	if result.known > 0 then
		parts[#parts + 1] = "|cff40ff40" .. result.known .. " known|r"
	end
	if result.now > 0 then
		parts[#parts + 1] = "|cffffffff" .. result.now .. " learnable|r"
	end
	if result.later > 0 then
		parts[#parts + 1] = "|cff999999" .. result.later .. " later|r"
	end
	return table.concat(parts, " · ")
end
ns.CountsText = CountsText

local function StateText(entry)
	if entry.state == ns.STATE_KNOWN then
		return "known", 0.25, 1, 0.25
	elseif entry.state == ns.STATE_NOW then
		return "learnable", 1, 1, 1
	end
	return "req. " .. entry.recipe[2], 0.9, 0.3, 0.3
end

local function AddRecipeLines(tooltip, result, limit)
	local shown = math.min(#result.recipes, limit)
	for i = 1, shown do
		local entry = result.recipes[i]
		local name = ns.GetRecipeName(entry.spellID)
		if entry.count > 1 then
			name = name .. " x" .. entry.count
		end
		local color = entry.state == ns.STATE_LATER and DIFFICULTY_COLORS[ns.DIFF_RED] or DIFFICULTY_COLORS[entry.difficulty]
		local right, rr, rg, rb = StateText(entry)
		tooltip:AddDoubleLine("    " .. name, right, color[1], color[2], color[3], rr, rg, rb)
	end
	if #result.recipes > shown then
		tooltip:AddLine("    ...and " .. (#result.recipes - shown) .. " more", COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3])
	end
end

local function ShouldListRecipes()
	local mode = ns.settings.recipeList
	if mode == ns.LIST_ALWAYS then
		return true
	elseif mode == ns.LIST_SHIFT then
		return IsShiftKeyDown() and true or false
	end
	return false
end

-- Adds Stash or Trash's lines for itemID. Returns true if anything was added.
function ns.AddToTooltip(tooltip, itemID)
	local report = ns.BuildReport(itemID)
	if not report then
		return false
	end
	local settings = ns.settings
	local listRecipes = ShouldListRecipes()
	local limit = math.max(1, settings.maxRecipes or 8)
	local added = false

	for _, result in ipairs(report.mine) do
		local left = Icon(result.profID) .. result.name
		if result.planned then
			left = left .. " |cff999999(planned)|r"
		end
		local right = settings.showCounts and CountsText(result) or ""
		tooltip:AddDoubleLine(left, right, COLOR_PROF[1], COLOR_PROF[2], COLOR_PROF[3], 1, 1, 1)
		if listRecipes then
			AddRecipeLines(tooltip, result, limit)
		end
		added = true
	end

	for _, alt in ipairs(report.alts) do
		local names = {}
		for i, char in ipairs(alt.chars) do
			names[i] = char.name .. " (" .. char.rank .. ")"
		end
		tooltip:AddDoubleLine(Icon(alt.profID) .. alt.name, table.concat(names, ", "),
			COLOR_ALT[1], COLOR_ALT[2], COLOR_ALT[3], COLOR_ALT[1], COLOR_ALT[2], COLOR_ALT[3])
		if listRecipes then
			-- Recipes from the point of view of the highest-skilled alt.
			AddRecipeLines(tooltip, alt.chars[1].result, limit)
		end
		added = true
	end

	if added then
		if settings.recipeList == ns.LIST_SHIFT and not listRecipes then
			tooltip:AddLine("Hold Shift to list recipes", COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3])
		end
	elseif settings.showUnused then
		tooltip:AddLine("Not used by your professions", COLOR_UNUSED[1], COLOR_UNUSED[2], COLOR_UNUSED[3])
		if settings.showOtherProfessions and #report.others > 0 then
			local names = {}
			for i, other in ipairs(report.others) do
				names[i] = other.name
			end
			tooltip:AddLine("Used in " .. table.concat(names, ", "), COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3], true)
		end
		added = true
	end
	return added
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

-- Tooltips we added lines to, so Shift can refresh them.
local touched = setmetatable({}, { __mode = "k" })

local function Process(tooltip, itemID)
	if not ns.settings or not ns.settings.enabled then
		return
	end
	if tooltip.IsForbidden and tooltip:IsForbidden() then
		return
	end
	if type(itemID) ~= "number" or ns.IsSecret(itemID) then
		return
	end
	local ok, added = pcall(ns.AddToTooltip, tooltip, itemID)
	touched[tooltip] = ok and added or nil
	if not ok and ns.settings.debug then
		ns.Print("tooltip error:", added)
	end
end

function ns.HookTooltips()
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
			Process(tooltip, data and data.id)
		end)
		return "TooltipDataProcessor"
	end
	-- Fallback for clients without the tooltip data API.
	local function OnTooltipSetItem(tooltip)
		local _, link = tooltip:GetItem()
		local itemID = link and C_Item and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(link)
		Process(tooltip, itemID)
	end
	for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
		if tooltip and tooltip.HookScript then
			pcall(tooltip.HookScript, tooltip, "OnTooltipSetItem", OnTooltipSetItem)
		end
	end
	return "OnTooltipSetItem"
end

ns.RegisterEvent("MODIFIER_STATE_CHANGED", function(_, key)
	if not ns.settings or ns.settings.recipeList ~= ns.LIST_SHIFT then
		return
	end
	if key ~= "LSHIFT" and key ~= "RSHIFT" then
		return
	end
	for tooltip in pairs(touched) do
		if tooltip:IsShown() and tooltip.RefreshData then
			pcall(tooltip.RefreshData, tooltip)
		end
	end
end)
