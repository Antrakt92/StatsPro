-- Luacheck config for StatsPro WoW addon (Lua 5.1 + WoW 12.x retail API).
-- Run from repo root: `luacheck StatsPro.lua`

std = "lua51"
max_line_length = false  -- existing code uses long WHY/WARNING comment lines
codes = true             -- show error codes (W113 etc.) so we can `ignore` precisely

-- WoW callback signatures often have unused `self`/`event`/`...` slots.
ignore = {
    "212/self",   -- unused 'self'
    "212/event",  -- unused 'event'
    "212/_.*",    -- unused vars prefixed with _
    "611",        -- line consists of only whitespace (style, not bug)
    "612",        -- trailing whitespace (style)
    "614",        -- trailing whitespace in comment (style)
}

-- Globals StatsPro itself defines/mutates (must be in `globals`, not `read_globals`).
globals = {
    -- SavedVariables + legacy carry-over
    "StatsProDB",
    -- Slash registration
    "SLASH_STATSPRO1", "SLASH_STATSPRO2",
    "SlashCmdList",  -- Blizzard table; addon adds keys, so it's writable for us
    -- Explicit support bridge exposed on a named global.
    "StatsProCloseColorPicker",
}

-- WoW API surface (read-only). Curated to what StatsPro touches; add more as
-- new APIs are referenced.
read_globals = {
    -- Frame / UI
    "CreateFrame", "UIParent", "BackdropTemplateMixin",
    "SettingsPanel", "HideUIPanel", "Settings",
    "C_Timer", "C_AddOns", "InCombatLockdown",
    "UIDropDownMenu_SetText", "CloseDropDownMenus",
    "DurabilityFrame", "MERCHANT_SHOW", "PaperDollFrame_GetArmorReduction",
    "GameFontNormalLarge", "GameFontHighlight", "GameFontHighlightSmall",
    -- Stat APIs (12.x retail)
    "GetCritChance", "GetSpellCritChance", "GetRangedCritChance",
    "GetHaste", "GetMeleeHaste", "GetSpellHaste", "GetRangedHaste",
    "GetMasteryEffect", "GetMastery",
    "GetVersatilityBonus", "GetCombatRating", "GetCombatRatingBonus",
    "GetCombatRatingBonusForCombatRatingValue",
    "GetDodgeChance", "GetParryChance", "GetBlockChance",
    "GetLifesteal", "GetAvoidance", "GetSpeed", "GetUnitSpeed",
    "IsSwimming", "IsFlying", "IsFalling",
    "GetAverageItemLevel",
    "UnitStat", "UnitArmor", "UnitEffectiveLevel", "UnitClass", "UnitRace", "UnitSex",
    "UnitGUID", "UnitFullName", "GetServerTime",
    -- Spec / class
    "GetSpecialization", "GetSpecializationInfo", "GetSpecializationRole",
    "C_PaperDollInfo", "C_SpecializationInfo",
    -- Inventory / tooltips
    "GetInventoryItemDurability", "GetInventoryItemLink",
    "GameTooltip", "C_TooltipInfo", "TooltipUtil", "GetCoinTextureString",
    -- Combat ratings constants (CR_*)
    "CR_CRIT_MELEE", "CR_CRIT_RANGED", "CR_CRIT_SPELL",
    "CR_HASTE_MELEE", "CR_HASTE_RANGED", "CR_HASTE_SPELL",
    "CR_MASTERY", "CR_VERSATILITY_DAMAGE_DONE", "CR_VERSATILITY_DAMAGE_TAKEN",
    "CR_LIFESTEAL", "CR_AVOIDANCE", "CR_SPEED",
    "CR_DODGE", "CR_PARRY", "CR_BLOCK",
    -- Durability slot enum
    "DURABILITY_SLOT_MIN", "DURABILITY_SLOT_MAX",
    -- Misc Blizzard globals
    "GetLocale", "STANDARD_TEXT_FONT", "ITEM_QUALITY_COLORS",
    "LibStub", "issecretvalue", "CopyTable",
    "WrapTextInColorCode", "FONT_COLOR_CODE_CLOSE",
    "Mixin", "CreateFromMixins",
    -- Blizzard table-helper aliases (faster than table.* in 12.x)
    "tinsert", "tremove", "wipe", "tContains",
    -- Sound API
    "PlaySound", "SOUNDKIT", "PlaySoundFile",
    -- Color picker (legacy global API)
    "ColorPickerFrame", "OpenColorPicker",
    -- UIDropDownMenu helpers (legacy template, still used in 12.x)
    "UIDropDownMenu_Initialize", "UIDropDownMenu_SetWidth",
    "UIDropDownMenu_JustifyText", "UIDropDownMenu_CreateInfo",
    "UIDropDownMenu_AddButton", "UIDropDownMenu_SetSelectedValue",
    "DropDownList1", "UIDROPDOWNMENU_OPEN_MENU", "UISpecialFrames",
    -- Legacy AddOn API (kept for older clients before C_AddOns)
    "GetAddOnMetadata", "IsAddOnLoaded",
    -- Math / string helpers usually in std but listed for safety
    "string", "math", "table", "tostring", "tonumber", "type", "pairs", "ipairs",
    "select", "pcall", "xpcall", "next", "unpack", "rawget", "rawset", "setmetatable",
    "getmetatable", "print",
}
