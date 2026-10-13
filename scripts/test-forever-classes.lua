-- Run the actual shared HUD/profile services for every supported Forever class.
local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
local checks = 0
local function check(value, label)
    checks = checks + 1
    assert(value, label)
end
local classes = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
for _, class in ipairs(classes) do
    local env, addon, test = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-Matrix-" .. class end,
        unitClass = function() return class, class, 1 end,
        foreverAPIs = {
            UnitClass = function() return class, class, 1 end,
            UnitStat = function(_, index) return index, 20 + index, 0, 0 end,
            GetCritChance = function() return 5 end,
            GetRangedCritChance = function() return 5 end,
            GetSpellCritChance = function() return 5 end,
            GetCombatRatingBonus = function() return 1 end,
            GetHitModifier = function() return 0 end,
            GetRangedHitModifier = function() return 0 end,
            GetSpellHitModifier = function() return 0 end,
            CR_HIT_MELEE = 101, CR_HIT_RANGED = 102, CR_HIT_SPELL = 103,
            GetMeleeHaste = function() return 2 end,
            GetRangedHaste = function() return 2, 10 end,
            UnitSpellHaste = function() return 2 end,
            UnitAttackPower = function() return 20, 2, -1 end,
            UnitRangedAttackPower = function() return 20, 2, -1 end,
            GetSpellBonusDamage = function(school) return school * 10 end,
            GetSpellBonusHealing = function() return 30 end,
            GetSpellPenetration = function() return 1 end,
            GetArmorPenetration = function() return 1 end,
            GetExpertise = function() return 1, 1, 1 end,
            UnitArmor = function() return 10, 47, 47, 47 end,
            UnitDefenseSkill = function() return 5, 1 end,
            GetDodgeChance = function() return 5 end,
            GetParryChance = function() return 5 end,
            GetBlockChance = function() return 5 end,
            GetShieldBlock = function() return 10 end,
            UnitResistance = function() return 0, 10, 10, 0 end,
            Enum = { Damageclass = { Holy = 1, Fire = 2, Nature = 3, Frost = 4, Shadow = 5, Arcane = 6 } },
            GetManaRegen = function() return 6, 1 end,
            GetUnitSpeed = function() return 0, 7 end,
        },
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    check(env.StatsProFrame:IsShown(), class .. " starts with a visible HUD")
    check(test.profileRuntimeState().activeSpecName == "Character", class .. " uses explicit character scope")
    for _, id in ipairs(test.hudPresets.order()) do
        check(test.hudPresets.startPreview(id), class .. " previews " .. id)
        check(test.hudPresets.applyPreview(), class .. " applies " .. id)
        check(test.hudPresets.currentID() == id, class .. " detects " .. id)
        for _, block in ipairs(test.buildRenderBlocks()) do
            check(#block.labels == #block.ratings and #block.labels == #block.values,
                class .. " aligned columns for " .. id)
            for _, target in ipairs(block.targetRows or {}) do check(target == false, class .. " no Archon targets") end
        end
    end
    local settings = test.profileState().settings
    settings.showOffensive, settings.showDefensive, settings.showTertiary = true, true, true
    settings.hideZeroOffensive, settings.hideZeroDefensive, settings.hideZeroTertiary = false, false, false
    for _, rows in pairs(addon.forever.rows) do
        for _, row in ipairs(rows) do settings[row.showKey] = true end
    end
    test.cacheSettings()
    local blocks = test.buildRenderBlocks()
    local total = #blocks[1].labels + #blocks[2].labels + #blocks[3].labels + #blocks[4].labels
    check(total == 45, class .. " can select all 45 supported rows")
    for _, rows in pairs(addon.forever.rows) do
        for _, row in ipairs(rows) do
            check(settings.colors[row.colorKey] ~= nil, class .. " editable color for " .. row.key)
        end
    end
    local exported = test.profileTransfer.serialize(class .. " matrix", settings,
        { stats = true, layout = true, appearance = true })
    check(type(exported) == "string", class .. " all-row profile exports")
    check(test.profileTransfer.parse(exported) ~= nil, class .. " all-row profile roundtrips")
    addon:OpenConfigMenu()
    for _, locale in ipairs({ "enUS", "enGB", "deDE", "esES", "esMX", "frFR", "itIT", "ptBR", "ruRU", "koKR", "zhCN", "zhTW" }) do
        env.StatsProDB.account.forceLocale = locale
        for _, style in ipairs({ "full", "short", "hidden" }) do
            settings.labelStyle = style
            test.cacheSettings()
            if style == "full" then addon.profileRuntime.RefreshConfigControls() end
            local translated = test.buildRenderBlocks()
            local seen, groupOrder = {}, { "character", "offensive", "utility", "defensive" }
            for index, group in ipairs(groupOrder) do
                local block = translated[index]
                check(#block.labels == #addon.forever.rows[group]
                    and #block.labels == #block.values and #block.labels == #block.ratings,
                    class .. " columns remain aligned: " .. locale .. " " .. style .. " " .. group)
                for rowIndex, row in ipairs(addon.forever.rows[group]) do
                    local label = block.labels[rowIndex]:gsub("|cff%x%x%x%x%x%x", ""):gsub("|r", "")
                    if style == "hidden" then
                        check(label == "", class .. " hidden label retains its value: " .. row.key)
                    else
                        check(label ~= "" and not seen[label],
                            class .. " distinguishable " .. locale .. " " .. style .. " label: " .. row.key .. " " .. label)
                        seen[label] = true
                        if style == "full" then
                            check(label == addon.forever.Translate(row.label, locale) .. ":",
                                class .. " actual HUD uses localized label: " .. locale .. " " .. row.key)
                            local control = env["StatsProForever" .. row.key]
                            local controlText = env["StatsProForever" .. row.key .. "Text"]
                            check(control and controlText and controlText:GetText() == addon.forever.Translate(row.label, locale),
                                class .. " Settings refreshes its localized label: " .. locale .. " " .. row.key)
                            check(control.statsProTooltipProvider() == controlText:GetText(),
                                class .. " tooltip follows Settings language: " .. locale .. " " .. row.key)
                        end
                    end
                    check(block.ratings[rowIndex] ~= "" or block.values[rowIndex] ~= "",
                        class .. " localized row retains a value: " .. locale .. " " .. style .. " " .. row.key)
                end
            end
        end
    end
    collectgarbage("collect")
end
print("StatsPro Forever all-class integration: PASS (" .. checks .. " checks, 9 classes)")
