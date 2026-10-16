-- Run with Lua 5.1 from the repository root.
local source = arg[1] or "StatsPro_Forever.lua"
local secret = setmetatable({}, {
    __add = function() error("secret arithmetic") end,
    __mul = function() error("secret arithmetic") end,
    __lt = function() error("secret comparison") end,
    __tostring = function() error("secret formatting") end,
})
GetBuildInfo = function() return "1.60.1", "70338", "Oct 10 2026", 16001 end
WOW_PROJECT_ID = 18
issecretvalue = function(value) return rawequal(value, secret) end
UnitGUID = function() return "Player-fixture" end
CR_HIT_MELEE, CR_HIT_RANGED, CR_HIT_SPELL = 6, 7, 8
local function Load()
    local addon = {}
    assert(loadfile(source))("StatsPro", addon)
    return addon.forever
end
local F = Load()
assert(F.enabled)
assert(F.ReadContext().specID == 1 and F.ReadContext().specName == "Character")
WOW_PROJECT_ID = 1
assert(not Load().enabled)
WOW_PROJECT_ID = 18
GetBuildInfo = function() return "1.60.1", "future", "future", 16002 end
assert(not Load().enabled)
GetBuildInfo = function() return "1.60.1", "70338", "Oct 10 2026", 16001 end
local catalogue = {}
for _, rows in pairs(F.rows) do
    for _, row in ipairs(rows) do
        assert(not catalogue[row.key], "duplicate stat")
        catalogue[row.key] = row
        assert(type(row.Read) == "function" and row.showKey == "show" .. row.key)
        assert(F.defaults[row.showKey] ~= nil)
    end
end
local count = 0
for _ in pairs(catalogue) do count = count + 1 end
assert(count == 46, "catalogue completeness")
local function Expect(key, expected, expectedState)
    local value, state = catalogue[key].Read()
    assert(rawequal(value, expected), key .. " value")
    assert(state == expectedState, key .. " state")
end
UnitStat = function(unit, index)
    assert(unit == "player")
    return index, index * 10, 0, 0
end
Expect("Spirit", 50, "clean")
Expect("Strength", 10, "clean")
UnitStat = function() return 12, secret, 0, 0 end
Expect("Intellect", secret, "secret")
UnitArmor = function() return 20, 200, 50, 150 end
Expect("Armor", 200, "clean")
UnitAttackPower = function() return 100, 20, -30 end
Expect("AttackPower", 90, "clean")
UnitAttackPower = function() return 100, 0, -300 end
Expect("AttackPower", 0, "clean")
UnitRangedAttackPower = function() return 100, 0, -300 end
Expect("RangedAttackPower", 0, "clean")
UnitAttackPower = function() return 100, 20, -30 end
UnitRangedAttackPower = function() return 300, 20, -30 end
GetOverrideAPBySpellPower = function() return 0.5 end
GetSpellBonusDamage = function(school) return school == 6 and 400 or 500 end
GetSpellBonusHealing = function() return 450 end
Expect("AttackPower", 200, "clean")
Expect("RangedAttackPower", 200, "clean")
GetSpellBonusHealing = function() return 30 end
Expect("AttackPower", 15, "clean")
GetSpellBonusHealing = function() return -30 end
Expect("AttackPower", 0, "clean")
Expect("RangedAttackPower", 0, "clean")
GetSpellBonusHealing = function() return 450 end
GetSpellBonusDamage = function(school) return school == 6 and -40 or 500 end
Expect("AttackPower", 0, "clean")
Expect("RangedAttackPower", 0, "clean")
for school = 2, 7 do
    GetSpellBonusDamage = function(index) return index == school and secret or 500 end
    Expect("AttackPower", nil, "unknown")
    Expect("RangedAttackPower", nil, "unknown")
end
GetSpellBonusDamage = function() return 400 end
GetSpellBonusHealing = function() return secret end
Expect("AttackPower", nil, "unknown")
GetSpellBonusHealing = function() return 450 end
for _, result in ipairs({ secret, math.huge, 0 / 0, false, "invalid" }) do
    GetOverrideAPBySpellPower = function() return result end
    Expect("AttackPower", nil, "unknown")
end
GetOverrideAPBySpellPower = function() return nil end
Expect("AttackPower", nil, "unknown")
GetOverrideAPBySpellPower = function() error("unavailable") end
Expect("AttackPower", nil, "unknown")
GetOverrideAPBySpellPower = function() return 1e308 end
GetSpellBonusDamage = function() return 1e308 end
GetSpellBonusHealing = function() return 1e308 end
Expect("AttackPower", nil, "unknown")
for _, multiplier in ipairs({ 0, -1 }) do
    GetOverrideAPBySpellPower = function() return multiplier end
    Expect("AttackPower", 90, "clean")
    Expect("RangedAttackPower", 290, "clean")
end
GetOverrideAPBySpellPower = nil
Expect("AttackPower", 90, "clean")
UnitDefenseSkill = function() return 5, -10 end
Expect("Defense", 0, "clean")
for index = 1, 3 do
    UnitAttackPower = function()
        local values = { 100, 20, -30 }
        values[index] = secret
        return unpack(values)
    end
    Expect("AttackPower", nil, "unknown")
end
UnitAttackPower = function() return 100, nil, 0 end
Expect("AttackPower", nil, "unknown")
GetRangedHaste = function() return 4, 10 end
Expect("RangedHaste", 14, "clean")
GetRangedHaste = function() return 4, secret end
Expect("RangedHaste", nil, "unknown")
GetCombatRatingBonus = function(index) assert(index == CR_HIT_MELEE) return 3 end
GetHitModifier = function() return -1 end
Expect("MeleeHit", 2, "clean")
GetOffhandHitModifier = function() return 5 end
Expect("OffhandHit", 8, "clean")
assert(catalogue.OffhandHit.kind == "percent" and catalogue.OffhandHit.colorKey == "foreverHit")
assert(F.defaults.showOffhandHit == false, "new optional row preserves existing selections")
GetOffhandHitModifier = function() return secret end
Expect("OffhandHit", nil, "unknown")
GetOffhandHitModifier = function() return 0 / 0 end
Expect("OffhandHit", nil, "unknown")
GetOffhandHitModifier = function() error("unsupported API") end
Expect("OffhandHit", nil, "unknown")
GetOffhandHitModifier = nil
Expect("OffhandHit", nil, "unknown")
GetOffhandHitModifier = function() return 5 end
GetCombatRatingBonus = function() return secret end
Expect("OffhandHit", nil, "unknown")
GetCombatRatingBonus = function(index) assert(index == CR_HIT_MELEE) return 3 end
GetHitModifier = function() return secret end
Expect("MeleeHit", nil, "unknown")
CR_HIT_MELEE = nil
Expect("MeleeHit", nil, "unknown")
GetManaRegen = function() return 2, 0.5 end
Expect("ManaRegenMP5", 10, "clean")
Expect("CastingManaRegenMP5", 2.5, "clean")
GetManaRegen = function() return secret, secret end
Expect("ManaRegen", secret, "secret")
Expect("ManaRegenMP5", nil, "unknown")
GetManaRegen = function() return 2, nil end
Expect("ManaRegen", 2, "clean")
Expect("CastingManaRegen", nil, "unknown")
GetManaRegen = function() return 1e308, 1e308 end
Expect("ManaRegenMP5", nil, "unknown")
GetCritChance = nil
Expect("MeleeCrit", nil, "unknown")
GetCritChance = function() error("unsupported API") end
Expect("MeleeCrit", nil, "unknown")
GetCritChance = function() return 0 / 0 end
Expect("MeleeCrit", nil, "unknown")
GetCritChance = function() return math.huge end
Expect("MeleeCrit", nil, "unknown")
GetCritChance = function() return 0 end
Expect("MeleeCrit", 0, "clean")
GetSpellBonusDamage = function(school) return school * 20 end
Expect("SpellPowerHoly", 40, "clean")
Expect("SpellPowerArcane", 140, "clean")
GetExpertise = function() return 1, 2, 3 end
Expect("OffhandExpertise", 2, "clean")
Expect("RangedExpertise", 3, "clean")
Enum = { Damageclass = { Holy = 2, Arcane = 7 } }
UnitResistance = function(unit, school)
    assert(unit == "player")
    return 10, 20, school * 30, 40
end
Expect("HolyResistance", 60, "clean")
Expect("ArcaneResistance", 210, "clean")
Expect("FireResistance", nil, "unknown")
issecretvalue = nil
Expect("MeleeCrit", nil, "unknown")
assert(F.ReadContext() == nil)
for _, result in ipairs({ "false", 0, {} }) do
    issecretvalue = function() return result end
    Expect("MeleeCrit", nil, "unknown")
    assert(F.ReadContext() == nil)
end
issecretvalue = function() return nil end
Expect("MeleeCrit", nil, "unknown")
assert(F.ReadContext() == nil)
issecretvalue = function() error("classification unavailable") end
Expect("MeleeCrit", nil, "unknown")
assert(F.ReadContext() == nil)
issecretvalue = function(value) return rawequal(value, secret) end
GetUnitSpeed = function(unit)
    assert(unit == "player")
    return 0, 7, 4.5, 7
end
Expect("MovementSpeed", 7, "clean")
assert(catalogue.MovementSpeed.label == "Run Speed (yd/sec)")
assert(catalogue.MainhandExpertise.kind == "percent")
UnitGUID = function() return secret end
assert(F.ReadContext() == nil)
for _, id in ipairs(F.presets.order) do
    local values = F.presets.definitions[id].values
    for _, row in pairs(catalogue) do assert(type(values[row.showKey]) == "boolean") end
    assert(values.showMastery == false and values.showVersatility == false)
end
for _, locale in ipairs({ "enUS", "enGB", "ruRU", "deDE", "esES", "esMX", "frFR", "itIT", "ptBR", "koKR", "zhCN", "zhTW" }) do
    local shortLabels = {}
    for _, row in pairs(catalogue) do
        assert(type(F.Translate(row.label, locale)) == "string", locale .. " " .. row.label .. " translation")
        assert(not F.Translate(row.label, locale):find(":"), locale .. " row labels should not add internal colons")
        local short = F.ShortLabel(row.label, locale)
        assert(type(short) == "string" and short ~= "" and not short:find(":"), locale .. " valid short label")
        assert(not shortLabels[short], locale .. " distinct short label " .. short)
        shortLabels[short] = row.label
    end
    for _, label in ipairs({ "Compact", "Physical", "Caster", "Healer", "Tank", "Character", "Utility", "Show Utility Stats", "Select individual stats for your build.", "Character stats and gear HUD for WoW Forever. Open Settings to choose a layout and visible stats." }) do
        assert(type(F.Translate(label, locale)) == "string", locale .. " UI translation")
    end
    local previous = {}
    for _, label in ipairs({ "Return to character settings...", "Make this character independent...", "Shared with %d characters", "Every existing and future character uses these settings." }) do
        local translated = F.Translate(label, locale)
        assert(type(translated) == "string", locale .. " character profile translation")
        if label:find("%%d") then assert(translated:find("%%d"), locale .. " profile count placeholder") end
    end
    local overrideCount = 0
    for original, replacement in pairs(F.textOverrides) do
        overrideCount = overrideCount + 1
        local translated = F.Translate(replacement, locale)
        assert(type(translated) == "string" and translated ~= "", locale .. " complete profile override")
        local expected, actual = {}, {}
        for placeholder in original:gmatch("%%[ds]") do expected[#expected + 1] = placeholder end
        for placeholder in translated:gmatch("%%[ds]") do actual[#actual + 1] = placeholder end
        assert(table.concat(expected) == table.concat(actual), locale .. " profile placeholder order")
    end
    assert(overrideCount == 24, "bounded profile override set")
    assert(type(F.Translate("Collecting 10 out-of-combat samples, then fight a creature to test combat.", locale)) == "string", locale .. " selftest instruction")
    for _, id in ipairs(F.presets.order) do
        local summary = F.Translate(F.presets.definitions[id].summary, locale)
        assert(type(summary) == "string" and not previous[summary], locale .. " distinct preset summaries")
        previous[summary] = true
    end
end
local mage = F.BuildDefaults("MAGE")
assert(mage.showIntellect and mage.showSpirit and mage.showSpellCrit)
assert(not mage.showStrength and not mage.showAgility and not mage.showStamina)
assert(mage.showSpellPowerFire and mage.showSpellPowerFrost and mage.showSpellPowerArcane)
assert(not mage.showSpellPowerHoly and not mage.showSpellPowerNature and not mage.showSpellPowerShadow)
local hunter = F.BuildPresets("HUNTER").definitions.physical.values
assert(hunter.showAgility and hunter.showRangedAttackPower and hunter.showRangedCrit and hunter.showRangedHit and hunter.showRangedHaste)
assert(not hunter.showStrength and not hunter.showAttackPower and not hunter.showMeleeCrit and not hunter.showMeleeHit)
assert(F.BuildDefaults("WARRIOR").showStrength and not F.BuildDefaults("WARRIOR").showIntellect)
assert(F.BuildDefaults("ROGUE").showAgility and not F.BuildDefaults("ROGUE").showStrength)
UnitClass = function() return "Mage", "MAGE", 8 end
local loadedMage = Load()
assert(loadedMage.defaults.showIntellect and not loadedMage.defaults.showStrength)
local classReads = 0
UnitClass = function()
    classReads = classReads + 1
    return "Fixture", classReads == 1 and "MAGE" or "HUNTER"
end
local singleClassSnapshot = Load()
assert(singleClassSnapshot.defaults.showIntellect == singleClassSnapshot.presets.definitions.compact.values.showIntellect,
    "defaults and presets must use the same class snapshot")
assert(classReads == 1, "class should be resolved once")
UnitClass = function() return "Unknown", secret end
local restrictedClass = Load()
assert(restrictedClass.defaults.showStamina and not restrictedClass.defaults.showIntellect)
UnitClass = nil
for _, class in ipairs({ "DRUID", "SHAMAN", "PALADIN" }) do
    local compact = F.BuildDefaults(class)
    assert(compact.showIntellect and not compact.showSpellCrit and not compact.showMeleeCrit)
    local presets = F.BuildPresets(class)
    assert(presets.definitions.physical.values.showMeleeCrit)
    assert(presets.definitions.caster.values.showSpellCrit)
    assert(presets.definitions.healer.values.showHealingPower)
    assert(presets.definitions.tank.values.showArmor)
end
local spellSchools = {
    MAGE = { Fire = true, Frost = true, Arcane = true }, WARLOCK = { Fire = true, Shadow = true },
    PRIEST = { Holy = true, Shadow = true }, DRUID = { Nature = true, Arcane = true },
    SHAMAN = { Fire = true, Frost = true, Nature = true }, PALADIN = { Holy = true },
}
for class, schools in pairs(spellSchools) do
    local caster = F.BuildPresets(class).definitions.caster.values
    for _, school in ipairs({ "Holy", "Fire", "Nature", "Frost", "Shadow", "Arcane" }) do
        assert(caster["showSpellPower" .. school] == (schools[school] == true), class .. " school relevance")
    end
end
local first = F.BuildDefaults("MAGE")
first.showIntellect = false
assert(F.BuildDefaults("MAGE").showIntellect, "defaults must be detached")
for _, class in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
    local presets = F.BuildPresets(class)
    local defaults = F.BuildDefaults(class)
    for _, id in ipairs(presets.order) do
        for _, row in pairs(catalogue) do
            assert(type(presets.definitions[id].values[row.showKey]) == "boolean", class .. " complete preset")
            assert(type(defaults[row.showKey]) == "boolean", class .. " complete defaults")
        end
    end
    presets.definitions.compact.values.showIntellect = not defaults.showIntellect
    assert(defaults.showIntellect ~= presets.definitions.compact.values.showIntellect, "separate default ownership")
end
local existingColors = { stamina = true, crit = true, haste = true, armor = true, dodge = true, parry = true, block = true, speed = true }
for _, row in pairs(catalogue) do
    assert(row.colorKey ~= "mainStat", row.key .. " generic color")
    assert(F.colorDefaults[row.colorKey] or existingColors[row.colorKey], row.key .. " palette")
end
assert(catalogue.Strength.colorKey ~= catalogue.Intellect.colorKey)
assert(catalogue.SpellPowerFire.colorKey ~= catalogue.SpellPowerFrost.colorKey)
assert(catalogue.FireResistance.colorKey ~= catalogue.SpellPowerFire.colorKey)
for _, color in pairs(F.colorDefaults) do
    for _, channel in ipairs({ "r", "g", "b" }) do assert(color[channel] >= 0 and color[channel] <= 1) end
end
GetLocale = function() return "ruRU" end
SPELL_STAT1_NAME = "Native strength fixture"
assert(F.Translate("Strength", "ruRU") == "Native strength fixture")
assert(F.Translate("Strength", "deDE") ~= "Native strength fixture")
local localeReads = 0
GetLocale = function() localeReads = localeReads + 1 return "ruRU" end
for _ = 1, 100 do F.Translate("Fire Spell Power", "ruRU") end
assert(localeReads == 0, "composite labels should not query the native locale")
print("Forever stat sources: passed")
