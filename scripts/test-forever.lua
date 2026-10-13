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
assert(count == 45, "catalogue completeness")
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
    for _, row in pairs(catalogue) do
        assert(type(F.Translate(row.label, locale)) == "string", locale .. " " .. row.label .. " translation")
    end
    for _, label in ipairs({ "Compact", "Physical", "Caster", "Healer", "Tank", "Character", "Utility", "Show Utility Stats", "Select individual stats for your build.", "Character stats and gear HUD for WoW Forever. Open Settings to choose a layout and visible stats." }) do
        assert(type(F.Translate(label, locale)) == "string", locale .. " UI translation")
    end
end
GetLocale = function() return "ruRU" end
SPELL_STAT1_NAME = "Native strength fixture"
assert(F.Translate("Strength", "ruRU") == "Native strength fixture")
assert(F.Translate("Strength", "deDE") ~= "Native strength fixture")
print("Forever stat sources: passed")
