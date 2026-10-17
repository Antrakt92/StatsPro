-- Shared recovery must work independently of client language and addon flavor.
local forever = arg and arg[1] == "forever"
assert(not arg or not arg[1] or forever, "expected optional forever flavor")
local flavor = forever and "Forever" or "Retail"
local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
local function loadStatsPro(locale, options)
    options = options or {}
    options.forever = forever
    local env, addon, test = fixtures.loadStatsPro(locale, options)
    assert((addon.forever and addon.forever.enabled == true or false) == forever,
        "recovery fixture loads the requested flavor")
    return env, addon, test
end
for _, client in ipairs({ "enUS", "ruRU" }) do
    local activated = {}
    local env, addon, test = loadStatsPro(client, {
        lsmFonts = {},
        isKnownFontFile = function() return true end,
        setFontResult = function(_, path) return activated[path] == true end,
        fontObjectSetFontResult = function(object, path)
            if object.name == "StatsProFontAssetActivator" then activated[path] = true end
            return true
        end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    addon:OpenConfigMenu()
    for index, entry in ipairs(test.configFontState().entries) do
        if index > 22 then break end
        local path, size, flags = entry.region:GetFont()
        entry.region:SetFont(path, size, flags)
    end
    for _, locale in ipairs({ "ruRU", "koKR", "zhCN", "zhTW", "enUS" }) do
        addon.settingsUI.localization.Preview(addon, locale)
        local requirement = test.registrySnapshot().localeGlyphReq[locale]
        local state = test.panelFontState()
        assert(test.fontSupports(state.mainAppliedFont, requirement), client .. ": readable HUD for " .. locale)
        for _, entry in ipairs(test.configFontState().entries) do
            assert(test.fontSupports(entry.actualFont, requirement), client .. ": readable Settings for " .. locale)
        end
        addon.settingsUI.localization.CancelPreview(addon)
    end
end
print(flavor .. " cross-language cold-font regressions passed")

-- A client exposing only the namespaced money API must still render both gear rows.
for _, mode in ipairs({ "modern", "modern-only", "legacy", "missing", "throwing",
    "nil-return", "number-return", "empty-return", "secret-return" }) do
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { showDurability = true, showRepairCost = true },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 70, 100 end
        end,
        getTooltipInventoryItem = function() return { repairCost = 4458354 } end,
        issecretvalue = function(value) return value == "restricted-money" end,
    })
    local legacy = env.GetCoinTextureString
    if mode ~= "legacy" then env.GetCoinTextureString = nil end
    if mode == "modern" or mode == "modern-only" then
        env.C_CurrencyInfo = { GetCoinTextureString = legacy }
        if mode == "modern" then env.GetCoinTextureString = function() error("modern API must take priority") end end
    elseif mode == "throwing" then
        env.C_CurrencyInfo = { GetCoinTextureString = function() error("formatter unavailable") end }
    elseif mode:find("-return", 1, true) then
        env.C_CurrencyInfo = { GetCoinTextureString = function()
            if mode == "number-return" then return 42 end
            if mode == "empty-return" then return "" end
            if mode == "secret-return" then return "restricted-money" end
        end }
    end
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(addon:RunUpdateStatsSafe(), mode .. ": repair formatting must not abort HUD rendering")
    assert(env.StatsProFrame:IsShown(), mode .. ": HUD remains visible")
    local state = test.durabilityState()
    assert(state.durabilityValue == 70 and state.repairCost == 4458354, mode .. ": gear data remains complete")
    local text = test.formatRepairCost(4458354, 15)
    assert(text == ((mode == "modern" or mode == "modern-only" or mode == "legacy") and "coin:4458354:15" or "?"), mode .. ": repair display")
end
print(flavor .. " money API and HUD recovery regressions passed")

-- A styled FontString can retain its own font even while GetFontObject still
-- identifies the shared parent. Changing that parent must not strand Settings.
for _, failFirst in ipairs({ false, true }) do
    local env, addon, test = loadStatsPro("enUS")
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    addon:OpenConfigMenu()
    local before = test.configFontState()
    local fail = failFirst
    for _, entry in ipairs(before.entries) do
        local region = entry.region
        local originalGet, originalSet = region.GetFont, region.SetFont
        local font, size, flags = region:GetFont()
        local pinned = true
        region.GetFont = function(self)
            if pinned then return font, size, flags end
            return originalGet(self)
        end
        region.SetFont = function(self, path, height, style)
            if fail and path == "Fonts\\ARIALN.TTF" then return false end
            pinned = false
            return originalSet(self, path, height, style)
        end
    end
    if failFirst then
        assert(not test.applyConfigFont("Fonts\\ARIALN.TTF", true), "failed direct fallback remains atomic")
        for index, entry in ipairs(test.configFontState().entries) do
            assert(entry.actualFont == before.entries[index].actualFont, "fallback failure restores every font")
            assert(entry.actualText == before.entries[index].actualText, "fallback failure preserves every label")
        end
        fail = false
    end
    assert(test.applyConfigFont("Fonts\\ARIALN.TTF", true), "same-owner overrides recover through direct Settings update")
    for _, entry in ipairs(test.configFontState().entries) do
        assert(entry.actualFont == "Fonts\\ARIALN.TTF", "every Settings font updates despite local override")
    end
    assert(test.applyConfigFont("Fonts\\2002.ttf", true), "subsequent Korean switch also updates direct regions")
    for _, entry in ipairs(test.configFontState().entries) do
        assert(entry.actualFont == "Fonts\\2002.ttf", "every Settings font switches to Korean")
    end
end
print(flavor .. " Settings inherited-override recovery regressions passed")

-- EditBox:SetFont requires a flags string even when FontString accepts nil.
-- The hidden profile-transfer input participates in the same Settings transaction.
do
    local env, addon, test = loadStatsPro("enUS", { lsmFonts = { { name = "Chinese", path = "Fonts\\ARHei.TTF" } } })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    addon:OpenConfigMenu()
    local input
    for _, entry in ipairs(test.configFontState().entries) do
        if entry.roleKey == "transferInput" then input = entry.region; break end
    end
    assert(input, "real profile-transfer EditBox is registered")
    local font, size, flags = input:GetFont()
    input:SetFont(font, size, flags or "")
    local originalSet = input.SetFont
    input.SetFont = function(self, path, height, style)
        assert(type(style) == "string", "EditBox flags must be a string")
        return originalSet(self, path, height, style)
    end
    for _, path in ipairs({ "Fonts\\ARHei.TTF", "Fonts\\ARIALN.TTF", "Fonts\\2002.ttf" }) do
        local applied, status = test.applyConfigFont(path, true)
        assert(applied, "hidden EditBox must not roll back Settings font switch: " .. tostring(status) .. " " .. tostring(addon.fontRuntime.configFontFailure) .. " " .. tostring(addon.fontRuntime.configFontFailureChild))
        for _, entry in ipairs(test.configFontState().entries) do
            assert(entry.actualFont == path, "all Settings regions receive selected font")
        end
    end
end
print(flavor .. " EditBox font flags regressions passed")

-- A single unavailable Settings region must not strand committed localization.
do
    local function fixture()
        local state = { failures = 1, attempts = 0, combat = false, specID = 73 }
        local env, addon, test = loadStatsPro("enUS", {
            lsmFonts = {},
            unitGUID = function() return "Player-1-SETTINGS-RECOVERY" end,
            getSpecialization = function() return 1 end,
            getSpecializationInfo = function()
                return state.specID, state.specID == 73 and "Protection" or "Arms",
                    nil, nil, state.specID == 73 and "TANK" or "DAMAGER", 1
            end,
            inCombatLockdown = function() return state.combat end,
        })
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        env.__flushTimers(0)
        addon:OpenConfigMenu()
        local input
        for _, entry in ipairs(test.configFontState().entries) do
            if entry.roleKey == "transferInput" then input = entry.region; break end
        end
        assert(input, "recovery uses the real transfer input")
        input:SetFont(input:GetFont())
        local original = input.SetFont
        input.SetFont = function(self, path, height, flags)
            if path == "Fonts\\ARIALN.TTF" then
                state.attempts = state.attempts + 1
                if state.failures > 0 then state.failures = state.failures - 1; return false end
            end
            return original(self, path, height, flags)
        end
        state.env, state.addon, state.test = env, addon, test
        state.select = function(locale)
            local dropdown = env.StatsProLanguageDropdown
            dropdown.dropdownInit()
            for _, info in ipairs(dropdown.dropdownEntries) do
                if info.value == locale then info.func(); return end
            end
            error("missing language " .. locale)
        end
        state.tick = function() addon:RunUpdateStatsSafe() end
        return state
    end

    local once = fixture()
    local before = once.test.profileState()
    local root, settings, profile = before.root, before.settings, before.root.profiles[before.profileID]
    once.select("ruRU")
    once.tick()
    assert(once.attempts == 2, "one-shot region failure retries automatically")
    assert(once.test.configFontState().currentFont == "Fonts\\ARIALN.TTF", "Settings recovers without manual apply")
    assert(once.test.profileState().root == root and once.test.profileState().settings == settings
        and root.profiles[before.profileID] == profile, "font recovery preserves profile graph identities")
    assert(root.account.forceLocale == "ruRU", "recovery preserves committed locale")
    assert(settings.fontBeforeAutoSwitch == "Fonts\\FRIZQT__.TTF", "recovery preserves original font preference")

    local persistent = fixture()
    persistent.failures = 100
    persistent.select("ruRU")
    for _, delay in ipairs({ 0.2, 1, 3, 5 }) do
        persistent.env.__flushTimers(delay)
        persistent.tick()
    end
    local attempts = persistent.attempts
    for _ = 1, 20 do persistent.env.__flushTimers(10); persistent.tick() end
    assert(attempts == 6 and persistent.attempts == attempts, "persistent Settings failure has a fixed retry budget")

    for _, guard in ipairs({ "combat", "unknown-combat", "transition", "preview", "latest-locale" }) do
        local guarded = fixture()
        guarded.failures = 100
        guarded.select("ruRU")
        local oldAttempts = guarded.attempts
        guarded.failures = 0
        if guard == "combat" then guarded.combat = true
        elseif guard == "unknown-combat" then guarded.combat = nil
        elseif guard == "transition" then guarded.addon.profileRuntime.transitioning = true
        elseif guard == "preview" then guarded.addon.settingsUI.localization.Preview(guarded.addon, "koKR")
        else guarded.select("zhCN") end
        guarded.env.__flushTimers(0.2)
        guarded.tick()
        if guard ~= "latest-locale" then
            assert(guarded.attempts == oldAttempts, guard .. ": retry waits for safe context")
        end
        if guard == "preview" then
            assert(guarded.test.fontSupports(guarded.test.configFontState().currentFont, "Hangul"), "retry preserves hovered script")
            guarded.addon.settingsUI.localization.CancelPreview(guarded.addon)
        elseif guard == "latest-locale" then
            assert(guarded.test.fontSupports(guarded.test.configFontState().currentFont, "Hans"), "old retry cannot restore former locale")
        else
            guarded.combat = false
            guarded.addon.profileRuntime.transitioning = false
        end
        guarded.tick()
        assert(guarded.test.fontSupports(guarded.test.configFontState().currentFont,
            guard == "latest-locale" and "Hans" or "Cyrillic"), guard .. ": recovery uses latest locale")
    end

    local handoff = fixture()
    handoff.failures = 100
    handoff.select("ruRU")
    local old = handoff.test.profileState()
    local oldSettings, oldFont, oldSaved = old.settings, old.settings.font, old.settings.fontBeforeAutoSwitch
    if forever then
        -- Forever routes character/manual profiles without Retail specialization.
        local switched, result = handoff.test.profileOps.enableAccountWide(old.profileID)
        assert(switched and result.created, "manual account-wide switch creates a separate profile")
    else
        handoff.specID = 71
        handoff.env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    end
    handoff.env.__flushTimers(0)
    local current = handoff.test.profileState()
    assert(current.profileID ~= old.profileID and current.settings ~= oldSettings,
        "real profile-context change selects new settings")
    handoff.failures = 0
    handoff.env.__flushTimers(0.2)
    handoff.tick()
    assert(handoff.test.configFontState().currentFont == "Fonts\\ARIALN.TTF", "retry recovers in latest profile")
    assert(handoff.test.profileState().settings == current.settings, "retry preserves new settings identity")
    assert(oldSettings.font == oldFont and oldSettings.fontBeforeAutoSwitch == oldSaved, "retry cannot mutate outgoing settings")
end
print(flavor .. " committed Settings recovery regressions passed")
