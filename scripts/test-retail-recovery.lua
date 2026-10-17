-- Retail language previews must work independently of the installed client locale.
local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
for _, client in ipairs({ "enUS", "ruRU" }) do
    local activated = {}
    local env, addon, test = fixtures.loadStatsPro(client, {
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
print("Retail cross-language cold-font regressions passed")

-- A client exposing only the namespaced money API must still render both gear rows.
for _, mode in ipairs({ "modern", "modern-only", "legacy", "missing", "throwing" }) do
    local env, addon, test = fixtures.loadStatsPro("enUS", {
        statsProDB = { showDurability = true, showRepairCost = true },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 70, 100 end
        end,
        getTooltipInventoryItem = function() return { repairCost = 4458354 } end,
    })
    local legacy = env.GetCoinTextureString
    if mode ~= "legacy" then env.GetCoinTextureString = nil end
    if mode == "modern" or mode == "modern-only" then
        env.C_CurrencyInfo = { GetCoinTextureString = legacy }
        if mode == "modern" then env.GetCoinTextureString = function() error("modern API must take priority") end end
    elseif mode == "throwing" then
        env.C_CurrencyInfo = { GetCoinTextureString = function() error("formatter unavailable") end }
    end
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(addon:RunUpdateStatsSafe(), mode .. ": repair formatting must not abort HUD rendering")
    assert(env.StatsProFrame:IsShown(), mode .. ": HUD remains visible")
    local state = test.durabilityState()
    assert(state.durabilityValue == 70 and state.repairCost == 4458354, mode .. ": gear data remains complete")
    local text = test.formatRepairCost(4458354, 15)
    assert(text == ((mode == "modern" or mode == "modern-only" or mode == "legacy") and "coin:4458354:15" or "?"), mode .. ": repair display")
end
print("Retail money API and HUD recovery regressions passed")

-- A styled FontString can retain its own font even while GetFontObject still
-- identifies the shared parent. Changing that parent must not strand Settings.
for _, failFirst in ipairs({ false, true }) do
    local env, addon, test = fixtures.loadStatsPro("enUS")
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
print("Retail Settings inherited-override recovery regressions passed")
