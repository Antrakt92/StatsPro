-- Exercise the Forever HUD and tooltip against the same native stat reader.
local secret = setmetatable({}, {
    __add = function() error("secret arithmetic") end,
    __mul = function() error("secret arithmetic") end,
    __lt = function() error("secret comparison") end,
    __tostring = function() error("secret formatting") end,
})
local env = setmetatable({}, { __index = _G })
env._G = env
env.GetBuildInfo = function() return "1.60.1", "71037", "", 16001 end
env.WOW_PROJECT_ID = 18
env.issecretvalue = function(value) return rawequal(value, secret) end
local addon = { profileRuntime = {
    ReadBooleanDecision = function(fn)
        if type(fn) ~= "function" then return nil end
        local ok, result = pcall(fn)
        if ok and not env.issecretvalue(result) and type(result) == "boolean" then return result end
    end,
} }
setfenv(assert(loadfile(arg[1] or "StatsPro_Forever.lua")), env)("StatsPro", addon)
local adapter = addon.forever
assert(adapter.enabled)
local sources = {}
for _, row in ipairs(adapter.rows.offensive) do sources[row.key] = row.Read end

local attributes = { 40, 50 }
local melee, ranged, multiplier, converted = 100, 120, 0, false
local calls = 0
env.UnitStat = function(unit, index)
    assert(unit == "player")
    return 1, attributes[index], 0, 0
end
local function originalMelee(index, value)
    calls = calls + 1
    assert(not env.issecretvalue(value))
    return index == 1 and value * 2 or value / 2
end
local meleeContribution = originalMelee
env.GetAttackPowerForStat = function(...) return meleeContribution(...) end
env.GetRangedAttackPowerForStat = function(index, value)
    calls = calls + 1
    assert(not env.issecretvalue(value))
    return index == 1 and 0 or value * 2
end
env.UnitAttackPower = function() return melee, 10, -5 end
env.UnitRangedAttackPower = function() return ranged, 25, -5 end
env.GetOverrideAPBySpellPower = function() return multiplier end
env.HasSPEffectsAttackPower = function() return converted end
env.PlayerEffectiveAttackPower = function() return 700, 800, 900, 105, 140 end

local function lines(key, value, state, detail)
    local result = {}
    if not detail and sources[key] and (state == nil or state == "clean") then
        local _, _, _, sampled = sources[key]()
        detail = sampled
    end
    adapter.BuildAttackPowerTooltip({ key = key, value = value, state = state or "clean", detail = detail }, function(label, text)
        assert(type(label) == "string" and not env.issecretvalue(label))
        assert((text == nil or type(text) == "string") and not env.issecretvalue(text))
        result[#result + 1] = { label, text }
    end)
    return result
end
local function expect(key, value, expected, state)
    local current = lines(key, value, state)
    assert(#current == #expected, key .. " wrong number of rows")
    for index, pair in ipairs(expected) do
        assert(current[index][1] == pair[1] and current[index][2] == pair[2],
            key .. " incorrect row " .. index)
    end
end
local meleeLabel, rangedLabel = "Melee attack power", "Ranged attack power"
local meleeRate, rangedRate = "Melee attack power per point", "Ranged attack power per point"
local strengthLabel, agilityLabel = "Attack power from Strength", "Attack power from Agility"
expect("Strength", 40, { { meleeLabel, "80" }, { meleeRate, "2" }, { rangedLabel, "0" } })
expect("Agility", 50, { { meleeLabel, "25" }, { meleeRate, "0.5" }, { rangedLabel, "100" }, { rangedRate, "2" } })
expect("AttackPower", 105, { { strengthLabel, "80" }, { agilityLabel, "25" } })
expect("RangedAttackPower", 140, { { strengthLabel, "0" }, { agilityLabel, "100" } })

local previousCalls = calls
expect("Strength", 39, {})
expect("Strength", secret, {})
expect("Agility", 50, {}, "stale")
expect("AttackPower", 105, {}, "secret")
expect("RangedAttackPower", 140, {}, "unknown")
expect("RangedAttackPower", 141, {})
assert(calls == previousCalls, "no contribution reads without a matching clean HUD value")

attributes[1] = secret
expect("AttackPower", 105, { { agilityLabel, "25" } })
attributes[1] = 40
meleeContribution = function(_, value) return value * 2 + 10 end
expect("Strength", 40, { { meleeLabel, "90" }, { rangedLabel, "0" } })
meleeContribution = function(_, value) return math.min(value * 2, 80) end
expect("Strength", 40, { { meleeLabel, "80" }, { rangedLabel, "0" } })
meleeContribution = function(_, value)
    if value == 39 then return secret end
    if value == 41 then return nil end
    return value * 2
end
expect("Strength", 40, { { meleeLabel, "80" }, { rangedLabel, "0" } })
local sameValueReads = 0
meleeContribution = function(_, value)
    if value == 40 then sameValueReads = sameValueReads + 1 end
    return value * 2 + (sameValueReads == 2 and 1 or 0)
end
expect("Strength", 40, { { rangedLabel, "0" } })
meleeContribution = function(_, value) return value * 0.07 end
expect("Strength", 40, { { meleeLabel, "2.8" }, { meleeRate, "0.07" }, { rangedLabel, "0" } })
meleeContribution = function(index, value)
    if index == 1 then return secret end
    return originalMelee(index, value)
end
expect("AttackPower", 105, { { agilityLabel, "25" } })
meleeContribution = function(index, value)
    attributes[1] = 41
    return originalMelee(index, value)
end
expect("AttackPower", 105, { { agilityLabel, "25" } })
attributes[1] = 40
meleeContribution = function(index, value)
    melee = 101
    return originalMelee(index, value)
end
expect("AttackPower", 105, {})
melee = 100
meleeContribution = originalMelee

assert(sources.AttackPower() == 105, "clean tuple seeds native AP parity")
melee = secret
assert(sources.AttackPower() == 105, "native total remains displayable when its parity is proved")
expect("AttackPower", 105, {})
expect("Strength", 40, { { rangedLabel, "0" } })
melee = 100

local damage = { [2] = 400, [3] = 410, [4] = 420, [5] = 430, [6] = 440, [7] = 450 }
env.GetSpellBonusDamage = function(school) return damage[school] end
local healing = 350
local function readHealing() return healing end
local healingReader = readHealing
env.GetSpellBonusHealing = function() return healingReader() end
multiplier, converted = 0.5, true
local total, state, _, conversionDetail = sources.AttackPower()
assert(total == 175 and state == "clean" and conversionDetail.mode == "conversion",
    "converted melee HUD total and state are preserved")
assert(sources.RangedAttackPower() == 175, "ranged HUD uses the same conversion")
local conversionLabel, multiplierLabel = "Spell power used for conversion", "Conversion multiplier"
local note = { { "Attack power is based on spell power" } }
expect("Strength", 40, note)
expect("Agility", 50, note)
expect("AttackPower", 175, { { conversionLabel, "350" }, { multiplierLabel, "0.5" } })
expect("RangedAttackPower", 175, { { conversionLabel, "350" }, { multiplierLabel, "0.5" } })
expect("AttackPower", 174, {})
healing = 500
expect("AttackPower", 200, { { conversionLabel, "400" }, { multiplierLabel, "0.5" } })
damage[6] = secret
expect("AttackPower", 200, {})
damage[6] = 440

local healReads = 0
healingReader = function()
    healReads = healReads + 1
    return healReads == 1 and 350 or 349
end
assert(#lines("AttackPower", 175, "clean", conversionDetail) == 0, "conversion basis changed during hover")
healingReader = readHealing
multiplier, converted, melee = 0, false, 195
local _, _, _, weaponDetail = sources.AttackPower()
multiplier, converted = 0.5, true
assert(#lines("AttackPower", 200, "clean", weaponDetail) == 0, "equal totals do not prove an unchanged AP route")
local _, _, _, originalConversion = sources.AttackPower()
healing, multiplier = 200, 1
assert(#lines("AttackPower", 200, "clean", originalConversion) == 0, "equal totals do not prove an unchanged conversion")
multiplier = secret
expect("AttackPower", 200, {})
expect("Strength", 40, note)
converted = secret
expect("Strength", 40, {})
print("StatsPro Forever attack power tooltip sources passed")
