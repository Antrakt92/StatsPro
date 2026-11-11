local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")

local function loadStatsPro(forever, options)
    options = options or {}
    options.forever = forever
    options.unitGUID = function() return "Player-SelfTest-Regression" end
    options.getSpecialization = function() return 1 end
    options.specID = 73
    options.specRole = "TANK"
    local env, addon, test = fixtures.loadStatsPro(options.locale or "enUS", options)
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    return env, addon, test
end

local function expectProbe(probe, wantedStatus, wantedValue, label)
    local status, value = probe()
    assert(status == wantedStatus and value == wantedValue, label)
end

for _, forever in ipairs({ false, true }) do
    local secret = {}
    local mode, wear = "normal", 70
    local combat = false
    local slot, tooltipReads = forever and 18 or 1, 0
    local env, addon, test = loadStatsPro(forever, {
        statsProDB = { showDurability = true, showRepairCost = true },
        inCombatLockdown = function() return combat end,
        issecretvalue = function(value) return rawequal(value, secret) end,
        getInventoryItemDurability = function(index)
            if index ~= slot then return nil, nil end
            if mode == "throw" then error("wear read failed") end
            if mode == "partial" then return wear end
            if mode == "restricted-wear" then return secret, 100 end
            if mode == "uncached" then return nil, nil end
            return wear, 100
        end,
        getTooltipInventoryItem = function()
            tooltipReads = tooltipReads + 1
            return { repairCost = mode == "restricted-cost" and secret or 300 }
        end,
    })
    local guided = addon.selfTest
    expectProbe(guided.ProbeDurability, 0, 70, "valid wear is clean")
    expectProbe(guided.ProbeRepair, 0, 300, "read repair is clean")
    combat = true
    env.__fireEvent("PLAYER_REGEN_DISABLED")
    expectProbe(guided.ProbeRepair, 2, nil, "out-of-combat price is unknown in a new phase")
    env.__fireEvent("MERCHANT_SHOW")
    assert(addon:RunUpdateStatsSafe())
    expectProbe(guided.ProbeRepair, 0, 300, "fresh combat price is clean")
    combat = false
    env.__fireEvent("PLAYER_REGEN_ENABLED")
    combat, mode = true, "restricted-cost"
    env.__fireEvent("PLAYER_REGEN_DISABLED")
    expectProbe(guided.ProbeRepair, 2, nil, "price from a previous encounter is unknown")
    env.__fireEvent("MERCHANT_SHOW")
    assert(addon:RunUpdateStatsSafe())
    expectProbe(guided.ProbeRepair, 1, nil, "fresh combat tooltip cost is protected")
    combat, mode = false, "normal"
    env.__fireEvent("PLAYER_REGEN_ENABLED")
    wear = 50
    expectProbe(guided.ProbeDurability, 0, 50, "fresh valid wear beats cached wear")
    mode = "throw"
    expectProbe(guided.ProbeDurability, 2, nil, "live wear error does not reuse cached wear")
    mode = "partial"
    expectProbe(guided.ProbeDurability, 2, nil, "half wear pair is unknown")
    mode = "restricted-wear"
    expectProbe(guided.ProbeDurability, 1, nil, "protected wear stays secret")
    mode = "uncached"
    env.GetInventoryItemID = function(_, index) if index == slot then return 42 end end
    env.C_Item = { IsItemDataCachedByID = function() return false end }
    expectProbe(guided.ProbeDurability, 2, nil, "uncached equipped wear is unknown")
    mode = "restricted-cost"
    env.__fireEvent("MERCHANT_SHOW")
    expectProbe(guided.ProbeRepair, 2, nil, "dirty repair does not reuse the cached cost")
    assert(addon:RunUpdateStatsSafe())
    expectProbe(guided.ProbeRepair, 1, nil, "protected tooltip cost stays secret with clean wear")

    guided.CaptureEnv()
    local settings = test.profileState().settings
    local before = tooltipReads
    settings.showRepairCost = false
    test.cacheSettings()
    env.__fireEvent("MERCHANT_SHOW")
    assert(addon:RunUpdateStatsSafe())
    assert(tooltipReads == before, "disabled repair performs no tooltip reads")
    expectProbe(guided.ProbeRepair, 2, nil, "unread repair cost is not a clean zero")
    assert(guided.TakeSample(false, false))
    assert(guided.samples[1].rows.repair.s == 2, "a captured repair row remains truthful after being disabled")
end

for _, forever in ipairs({ false, true }) do
    local combat = false
    local env, addon = loadStatsPro(forever, {
        locale = forever and "ruRU" or "enUS",
        inCombatLockdown = function() return combat end,
    })
    local guided = addon.selfTest
    assert(guided.Start())
    for _ = 1, guided.oocTarget do guided.OnTick() end
    local messages = table.concat(env.__prints, "\n")
    if forever then
        assert(not messages:find("Hit a training dummy", 1, true), "Forever prompt does not require a training dummy")
        assert(messages:find("существ", 1, true), "Forever prompt is localized")
    else
        assert(messages:find("Hit a training dummy", 1, true), "Retail combat prompt is retained")
    end
    combat = true
    env.__fireEvent("PLAYER_REGEN_DISABLED")
    combat = false
    env.__fireEvent("PLAYER_REGEN_ENABLED")
    for _ = 1, guided.recoveryNeeded do guided.OnTick() end
    local totals = assert(guided.report).totals
    assert(totals.combat == 0 and totals.recovery == guided.recoveryNeeded
        and not totals.recovered, "combat without a recorded sample cannot report successful recovery")

    rawset(env.C_AddOns, "IsAddOnLoaded", function() return true, false end)
    assert(guided.ReadAddonLoaded("DoYouNeedIt") == false, "loading is not loaded")
    rawset(env.C_AddOns, "IsAddOnLoaded", function() return true, true end)
    assert(guided.ReadAddonLoaded("DoYouNeedIt") == true, "modern loaded result is used")
    env.IsAddOnLoaded = function() return true, true end
    rawset(env.C_AddOns, "IsAddOnLoaded", function() return true end)
    assert(guided.ReadAddonLoaded("DoYouNeedIt") == nil, "malformed modern result cannot fall back")
    rawset(env.C_AddOns, "IsAddOnLoaded", nil)
    assert(guided.ReadAddonLoaded("DoYouNeedIt") == true, "missing modern method uses the legacy alias")
end

for _, scenario in ipairs({ { cycles = 1, ticks = 24 }, { cycles = 25, ticks = 1 } }) do
    local combat = false
    local env, addon, test = loadStatsPro(true, {
        inCombatLockdown = function() return combat end,
    })
    local settings = test.profileState().settings
    for _, rows in pairs(addon.forever.rows) do
        for _, definition in ipairs(rows) do settings[definition.showKey] = true end
    end
    settings.showOffensive, settings.showDefensive, settings.showTertiary = true, true, true
    settings.showDurability, settings.showRepairCost = true, true
    test.cacheSettings()

    local guided = addon.selfTest
    assert(guided.Start())
    for _ = 1, guided.oocTarget do guided.OnTick() end
    for cycle = 1, scenario.cycles do
        combat = true
        env.__fireEvent("PLAYER_REGEN_DISABLED")
        for _ = 1, scenario.ticks do guided.OnTick() end
        combat = false
        env.__fireEvent("PLAYER_REGEN_ENABLED")
        local recoveryTicks = cycle == scenario.cycles and guided.recoveryNeeded or 2
        for _ = 1, recoveryTicks do guided.OnTick() end
    end

    local report = assert(guided.report)
    local payload = assert(guided.BuildPayload())
    local shown, omitted = payload:match("\nshown=(%d+)\nomitted=(%d+)$")
    assert(tonumber(omitted) > 0, "fixture truncates a full Forever diagnostic")
    assert(tonumber(shown) + tonumber(omitted) == #report.samples, "truncation accounts for each sample")
    assert(#payload <= guided.payloadBudget, "footer fits within the copy budget")
    local lastSequence = 0
    for sequence in payload:gmatch("\ns%.(%d+) ") do
        assert(tonumber(sequence) > lastSequence, "selected lines retain chronological order")
        lastSequence = tonumber(sequence)
    end
    local firstCombat, lastCombat
    for _, sample in ipairs(report.samples) do
        if sample.combat then
            firstCombat = firstCombat or sample.seq
            lastCombat = sample.seq
        end
    end
    local function includes(sequence) return payload:find("\ns." .. sequence .. " ", 1, true) end
    assert(includes(firstCombat) and includes(lastCombat), "both combat boundaries survive truncation")
    for sequence = lastCombat + 1, #report.samples do
        assert(includes(sequence), "recovery sample survives truncation")
    end
end

for _, forever in ipairs({ false, true }) do
    local combat = false
    local env, addon = loadStatsPro(forever, { inCombatLockdown = function() return combat end })
    local guided = addon.selfTest
    assert(guided.Start())
    for _ = 1, guided.oocTarget do guided.OnTick() end
    combat = true
    env.__fireEvent("PLAYER_REGEN_DISABLED")
    for _ = 1, guided.combatTimeoutTicks do guided.OnTick() end
    assert(guided.state == "done" and guided.deferredWindow and env.StatsProSelfTest.report)
    env.__fireEvent("PLAYER_REGEN_ENABLED")
    assert(guided.deferredWindow and not env.__lastStaticPopup, "stale combat still defers the report")
    combat = false
    env.__flushTimers(1)
    assert(not guided.deferredWindow and env.__lastStaticPopup.key == "STATSPRO_SELFTEST_COPY",
        "report opens after combat state catches up without a second event")

    assert(guided.Start())
    combat = true
    env.__fireEvent("PLAYER_REGEN_DISABLED")
    guided.Finish("timeout")
    env.__fireEvent("PLAYER_REGEN_ENABLED")
    env.__flushTimers(1)
    assert(guided.deferredWindow and guided.windowRetryToken == nil, "stale combat retry is bounded")
    combat = false
    env.__fireEvent("PLAYER_REGEN_ENABLED")
    assert(not guided.deferredWindow, "later combat end can resume the deferred report")
end

print("StatsPro self-test diagnostics regressions passed")
