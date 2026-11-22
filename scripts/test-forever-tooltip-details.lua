-- Run with Lua 5.1 from the repo root against the assembled Forever module.
local source = arg[1] or "StatsPro_Forever.lua"
local secret = setmetatable({}, {
    __add = function() error("secret arithmetic") end,
    __mul = function() error("secret arithmetic") end,
    __lt = function() error("secret comparison") end,
    __tostring = function() error("secret formatting") end,
})
local ratingReads, offhandReads, hasteReads = 0, 0, 0
local modifiers = { melee = 3, offhand = 4, ranged = -1, spell = 2 }
local class = "MAGE"
local agilityCritReads = 0
local agilityCrit = 0.0125
local rangedCrit = 5.45
local hasShield = true
local onAgilityCrit
local primary = { 79, 25, 35, 25, 40 }
local env = setmetatable({
    GetBuildInfo = function() return "1.60.1", "71037", "Nov 20 2026", 16001 end,
    WOW_PROJECT_ID = 18,
    issecretvalue = function(value) return rawequal(value, secret) end,
    UnitClass = function() return "Mage", class end,
    UnitStat = function(_, index) return 15, primary[index] end,
    UnitHPPerStamina = function() return 10 end,
    GetSpellCritChanceFromStat = function(index, intellect)
        assert(index == 4 and intellect == 25)
        return 0.0325
    end,
    GetDodgeChanceFromAttribute = function() return 0.0425 end,
    GetDodgeChance = function() return 7.2 end,
    GetCritChance = function() return 4.97 end,
    GetRangedCritChance = function() return rangedCrit end,
    GetSpellCritChance = function() return 5.89 end,
    GetCritChanceFromStat = function(index, agility)
        assert(index == 2 and agility == primary[2])
        agilityCritReads = agilityCritReads + 1
        if onAgilityCrit then onAgilityCrit() end
        return agilityCrit
    end,
    GetHealthRegenFromSpirit = function() return 8 end,
    GetHealthRegen = function() return 14 end,
    GetManaRegenFromSpirit = function() return 3 end,
    GetManaRegen = function() return 6, 2 end,
    GetBlockChance = function() return 6.5 end,
    GetShieldBlock = function() return 27 end,
    UnitLevel = function() return 60 end,
    UnitEffectiveLevel = function() return 60 end,
    UnitDefenseSkill = function() return 300, 7 end,
    UnitArmor = function() return 1300, 1305 end,
    Enum = { Damageclass = { Frost = 5 } },
    UnitResistance = function(_, school)
        assert(school == 5)
        return 59, 1, 60
    end,
    C_PaperDollInfo = {
        GetArmorEffectiveness = function(armor, level)
            assert(armor == 1305 and level == 60)
            return 0.1
        end,
        GetArmorEffectivenessAgainstTarget = function(armor)
            assert(armor == 1305)
            return secret
        end,
        OffhandHasShield = function() return hasShield end,
    },
    CR_HIT_MELEE = 6, CR_HIT_RANGED = 7, CR_HIT_SPELL = 8,
    GetCombatRatingBonus = function(rating)
        ratingReads = ratingReads + 1
        return rating - 4
    end,
    GetHitModifier = function() return modifiers.melee end,
    GetOffhandHitModifier = function()
        offhandReads = offhandReads + 1
        return modifiers.offhand
    end,
    GetRangedHitModifier = function() return modifiers.ranged end,
    GetSpellHitModifier = function() return modifiers.spell end,
    GetRangedHaste = function()
        hasteReads = hasteReads + 1
        return 11, 7
    end,
}, { __index = _G })
env._G = env
local addon = {}
setfenv(assert(loadfile(source)), env)("StatsPro", addon)
local F = addon.forever
assert(F.enabled)

local rows = {}
for _, group in pairs(F.rows) do
    for _, row in ipairs(group) do rows[row.key] = row end
end

local function build(key, state, value, detail)
    local entries = {}
    F.BuildStatTooltip({ key = key, state = state, value = value, detail = detail }, function(label, text)
        assert(not entries[label], "duplicate detail: " .. label)
        assert(type(text) == "string" and not env.issecretvalue(text))
        entries[label] = text
    end)
    return entries
end

local sample = {}
local melee, meleeState, meleeSuffix, meleeDetail = rows.MeleeHit.Read(sample)
local offhand, offhandState, offhandSuffix, offhandDetail = rows.OffhandHit.Read(sample)
assert(melee == 5 and meleeState == "clean" and meleeSuffix == nil)
assert(offhand == 6 and offhandState == "clean" and offhandSuffix == nil)
assert(ratingReads == 1 and offhandReads == 1, "selected melee channels share one rating read")
modifiers.offhand = 999
local hit = build("MeleeHit", "clean", melee, meleeDetail)
assert(hit["Hit from Rating"] == "2.00%" and hit["Hit Modifier"] == "3.00%")
hit = build("OffhandHit", "clean", offhand, offhandDetail)
assert(hit["Hit from Rating"] == "2.00%" and hit["Hit Modifier"] == "4.00%")
assert(ratingReads == 1 and offhandReads == 1, "hover does not resample hit")
local function checkChannel(key, expected, modifier)
    local value, state, _, detail = rows[key].Read(sample)
    assert(value == expected and state == "clean")
    local info = build(key, state, value, detail)
    assert(info["Hit Modifier"] == modifier)
end
checkChannel("RangedHit", 2, "-1.00%")
checkChannel("SpellHit", 6, "2.00%")
assert(next(build("OffhandHit", "stale", offhand, offhandDetail)) == nil)
modifiers.offhand = secret
local _, restrictedState, _, restrictedHit = rows.OffhandHit.Read({})
assert(restrictedState == "unknown" and restrictedHit == nil)
local _, _, suffix = rows.MeleeHit.Read()
assert(suffix == nil, "standalone readings do not overload the visibility key")

local haste, hasteState, hasteSuffix, hasteDetail = rows.RangedHaste.Read()
assert(haste == 18 and hasteState == "clean" and hasteSuffix == nil and hasteReads == 1)
local hasteEntries = build("RangedHaste", hasteState, haste, hasteDetail)
assert(hasteEntries["Base Ranged Haste"] == "11.00%" and hasteEntries["Ammo Haste"] == "7.00%")
assert(hasteReads == 1, "hover does not resample ranged haste")
env.GetRangedHaste = function() return secret, 0 end
local protected, protectedState, _, protectedDetail = rows.RangedHaste.Read()
assert(protectedState == "secret" and rawequal(protected, secret))
assert(protectedDetail == nil)

assert(build("Stamina", "clean", 35)["Health from Stamina"] == "170")
assert(next(build("Stamina", "clean", 36)) == nil)
primary[3] = 12
assert(build("Stamina", "clean", 12)["Health from Stamina"] == "12")
assert(next(build("Stamina", "secret", secret)) == nil)
local intellect = build("Intellect", "clean", 25)
assert(intellect["Mana from Intellect"] == "95" and intellect["Spell Crit from Intellect"] == "3.25%")
assert(next(build("Intellect", "clean", 26)) == nil)
class = "WARRIOR"
assert(not build("Intellect", "clean", 25)["Mana from Intellect"])
class = "MAGE"
local spirit = build("Spirit", "clean", 40)
assert(spirit["Health Regen from Spirit / 5 sec (standing)"] == "30.00" and spirit["Health Regen / 5 sec"] == "70.00")
assert(spirit["Mana Regen from Spirit / 5 sec"] == "15.00" and spirit["Mana Regen / 5 sec"] == "30.00")
assert(next(build("Spirit", "clean", 39)) == nil, "different current spirit cannot supplement the last render")
assert(build("Strength", "clean", 79)["Block Value from Strength"] == "3")
assert(next(build("Strength", "clean", 78)) == nil)
hasShield = false
assert(not build("Strength", "clean", 79)["Block Value from Strength"])
local agility = build("Agility", "clean", 25)
assert(agility["Dodge from Agility"] == "4.25%")
assert(agility["Physical Crit from Agility"] == "1.25%" and agilityCritReads == 1)
local earlierAgility = build("Agility", "clean", 26)
assert(earlierAgility["Base Armor from Agility"] == "52" and not earlierAgility["Physical Crit from Agility"])
assert(agilityCritReads == 1, "a different current Agility must not be used to supplement an old reading")
for key, total in pairs({ MeleeCrit = 4.97, RangedCrit = 5.45 }) do
    local crit = build(key, "clean", total)
    assert(crit["Physical Crit from Agility"] == agility["Physical Crit from Agility"])
    assert(not crit["Melee Crit"] and not crit["Ranged Crit"] and not crit["Spell Crit"],
        "other critical chances are not sources of the hovered total")
    assert(next(build(key, "clean", total + 1)) == nil)
end
assert(build("SpellCrit", "clean", 5.89)["Spell Crit from Intellect"] == intellect["Spell Crit from Intellect"])
assert(next(build("SpellCrit", "stale", 5.89)) == nil)
onAgilityCrit = function() rangedCrit = 6.45 end
assert(next(build("RangedCrit", "clean", 5.45)) == nil, "a changed total cannot take a newer contribution")
rangedCrit = 5.45
onAgilityCrit = function() primary[2] = 26 end
assert(next(build("RangedCrit", "clean", 5.45)) == nil, "a changed attribute invalidates the contribution")
onAgilityCrit = nil
primary[2] = 25
agilityCrit = secret
assert(not build("Agility", "clean", 25)["Physical Crit from Agility"])
assert(next(build("RangedCrit", "clean", 5.45)) == nil)
primary[4] = secret
assert(next(build("SpellCrit", "clean", 5.89)) == nil)
primary[4] = 25
assert(build("Dodge", "clean", 7.2)["Dodge from Agility"] == agility["Dodge from Agility"])
assert(next(build("Dodge", "clean", 5)) == nil)
for locale, labels in pairs(F.labels) do
    local label = labels["Physical Crit from Agility"]
    assert(type(label) == "string" and label ~= "", "missing Agility crit label for " .. locale)
    assert(labels["Base Armor from Agility"], "missing base Agility armor label for " .. locale)
    assert(labels["Health Regen from Spirit / 5 sec (standing)"], "missing standing Spirit label for " .. locale)
end
assert(build("Block", "clean", 6.5)["Block Value"] == "27")
assert(next(build("Block", "clean", 7.5)) == nil)
assert(build("BlockValue", "clean", 27)["Block"] == "6.50%")
assert(not build("BlockValue", "clean", 27)["Block Value from Strength"])
hasShield = true
assert(build("BlockValue", "clean", 27)["Block Value from Strength"] == "3")
local armor = build("Armor", "clean", 1305)
assert(armor["Base Armor from Agility"] == agility["Base Armor from Agility"])
assert(armor["Damage Reduction at Your Level"] == "10.00%" and not armor["Damage Reduction Against Target"])
assert(next(build("Armor", "clean", 1705)) == nil)
local defense = build("Defense", "clean", 307)
assert(defense["Base Defense"] == "300" and defense["Defense Modifier"] == "+7")
assert(build("FrostResistance", "clean", 60)["Expected Resistance at Your Level"] == "15%")
assert(next(build("FrostResistance", "clean", 45)) == nil)

local itemLevel = build("ItemLevel", "stale", nil, { equipped = 80.8, overall = 100.1 })
assert(itemLevel["Equipped Item Level"] == "(80)" and itemLevel["Overall Item Level"] == "(100)")
local durability = build("Durability", "clean", 75, { average = 75, worst = 50 })
assert(durability["Average Durability"] == "75.0%" and durability["Lowest Durability"] == "50.0%")
assert(next(build("Durability", "unknown", nil, { average = 75, worst = 50 })) == nil)
print("Forever native tooltip detail sources passed")
