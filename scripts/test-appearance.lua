-- Shared Appearance services under a cold Forever client and sparse media registry.
local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
local activated = {}
local env, addon, test = fixtures.loadStatsPro("enUS", {
    forever = true,
    lsmFonts = {},
    -- A file-table miss does not prevent the attached FontObject from loading
    -- the font. Exercise activation before caching an invalid built-in path.
    isKnownFontFile = function() return false end,
    setFontResult = function(_, path) return activated[path] == true end,
    fontObjectSetFontResult = function(object, path)
        if object.name == "StatsProFontAssetActivator" then activated[path] = true end
        return true
    end,
})
env.__fireEvent("PLAYER_ENTERING_WORLD")
local fonts = addon.settingsUI.fontPicker.BuildFontsList(addon, true)
assert(#fonts >= 4, "cold built-in fonts remain available with an empty SharedMedia registry")
addon:OpenConfigMenu()
-- Native widget styling can make a FontString use a private font object.
-- Its registry entry still refers to the old semantic group. Match the observed
-- partial detachment before switching scripts; assert rollback and recovery too.
local detachedRegion = assert(test.configFontState().entries[1]).region
local oldFont, oldSize, oldFlags = detachedRegion:GetFont()
detachedRegion:SetFont(oldFont, oldSize, oldFlags)
local switched = test.applyConfigFont("Fonts\\ARKai_T.ttf", true)
assert(switched, "Settings font switch survives a detached styled region")
for _, entry in ipairs(test.configFontState().entries) do
    assert(entry.actualFont == "Fonts\\ARKai_T.ttf", "all Settings regions switch together")
end
for _, locale in ipairs({ "ruRU", "koKR", "zhCN", "zhTW" }) do
    local requirement = test.registrySnapshot().localeGlyphReq[locale]
    local path = test.findCompatibleFont("Fonts\\FRIZQT__.TTF", requirement)
    assert(path and test.fontSupports(path, requirement), "compatible client font for " .. locale)
    local info = {}
    addon.settingsUI.localization.MenuInfo(addon, info, locale)
    assert(info.fontObject, "language menu has its own font for " .. locale)
    assert(test.fontSupports(info.fontObject:GetFont(), requirement), "readable menu row for " .. locale)
    -- Match UIDropDownMenu_AddButton's regular-row contract, including its
    -- 16x16 texture. Nested iconInfo is ignored by this native path.
    assert(info.icon and info.tCoordLeft and info.tCoordRight, "cropped texture flag for " .. locale)
    assert((info.tCoordRight - info.tCoordLeft) * 512 ==
        (info.tCoordBottom - info.tCoordTop) * 32, "square crop preserves flag proportions")
    addon.settingsUI.localization.Preview(addon, locale)
    local state = test.panelFontState()
    assert(test.fontSupports(state.mainAppliedFont, requirement), "readable HUD preview for " .. locale)
    for _, entry in ipairs(test.configFontState().entries) do
        assert(test.fontSupports(entry.actualFont, requirement), "readable Settings region for " .. locale)
    end
    addon.settingsUI.localization.CancelPreview(addon)
end
local auto = {}
addon.settingsUI.localization.MenuInfo(addon, auto, "auto")
assert(auto.tCoordLeft == 3 / 512, "Auto uses the client language flag")
local crops = {}
for _, option in ipairs(test.registrySnapshot().languageOptions) do
    local info = {}
    addon.settingsUI.localization.MenuInfo(addon, info, option.value)
    assert(info.icon and info.tCoordLeft, "native icon coordinates for " .. option.value)
    if option.value ~= "auto" then
        assert(not crops[info.tCoordLeft], "distinct flag crop for " .. option.value)
        crops[info.tCoordLeft] = true
    end
end
local image = assert(io.open("textures/language-flags.tga", "rb"))
assert(#image:read("*a") == 18 + 512 * 32 * 4, "complete power-of-two RGBA flag atlas")
image:close()

local rollbackEnv, rollbackAddon, rollbackTest = fixtures.loadStatsPro("enUS", {
    forever = true,
    setFontResult = function(region, path)
        if region.failFontSwitch and path == "Fonts\\ARKai_T.ttf" then
            region.font, region.fontSize, region.fontFlags = nil, nil, nil
            return false
        end
        return true
    end,
})
rollbackEnv.__fireEvent("PLAYER_ENTERING_WORLD")
rollbackAddon:OpenConfigMenu()
local before = rollbackTest.configFontState()
local private = before.entries[1].region
private:SetFont(private:GetFont())
private.failFontSwitch = true
assert(not rollbackTest.applyConfigFont("Fonts\\ARKai_T.ttf", true), "failed detached font aborts switch")
for index, entry in ipairs(rollbackTest.configFontState().entries) do
    assert(entry.actualFont == before.entries[index].actualFont, "group/direct rollback restores every Settings font")
    assert(entry.actualText == before.entries[index].actualText, "rollback preserves Settings text")
end
private.failFontSwitch = false
assert(rollbackTest.applyConfigFont("Fonts\\ARKai_T.ttf", true), "font switch recovers after direct failure")
for _, entry in ipairs(rollbackTest.configFontState().entries) do
    assert(entry.actualFont == "Fonts\\ARKai_T.ttf", "recovery updates all Settings fonts")
end

local warmed = {}
local crossEnv, crossAddon, crossTest = fixtures.loadStatsPro("enUS", {
    forever = true,
    statsProDB = { forceLocale = "zhCN", font = "Fonts\\ARHei.TTF",
        fontBeforeAutoSwitch = "Fonts\\FRIZQT__.TTF" },
    isKnownFontFile = function() return false end,
    setFontResult = function(_, path)
        return path == "Fonts\\ARHei.TTF" or warmed[path] == true
    end,
    fontObjectSetFontResult = function(object, path)
        if object.name == "StatsProFontAssetActivator" then warmed[path] = true end
        return true
    end,
})
crossEnv.__fireEvent("PLAYER_ENTERING_WORLD")
crossAddon:OpenConfigMenu()
local autoChinese = {}
crossAddon.settingsUI.localization.MenuInfo(crossAddon, autoChinese, "auto")
for _, option in ipairs(crossTest.registrySnapshot().languageOptions) do
    if option.value ~= "auto" then
        crossAddon.settingsUI.localization.MenuInfo(crossAddon, {}, option.value)
    end
end
assert(crossTest.fontSupports(autoChinese.fontObject:GetFont(), "Hans"), "Auto sentence uses Chinese glyphs")
crossAddon.settingsUI.localization.Preview(crossAddon, "ruRU")
assert(crossTest.panelFontState().mainAppliedFont == "Fonts\\ARIALN.TTF", "Russian HUD returns to normal Cyrillic face")
assert(crossTest.configFontState().currentFont == "Fonts\\ARIALN.TTF", "Russian Settings uses normal Cyrillic face")
crossAddon.settingsUI.localization.CancelPreview(crossAddon)
crossAddon.settingsUI.localization.Preview(crossAddon, "koKR")
assert(crossTest.fontSupports(crossTest.configFontState().currentFont, "Hangul"), "cold Korean Settings font activates")
assert(crossTest.fontSupports(crossTest.panelFontState().mainAppliedFont, "Hangul"), "cold Korean HUD font activates")
crossAddon.settingsUI.localization.CancelPreview(crossAddon)
local function selectLanguage(locale)
    local dropdown = crossEnv.StatsProLanguageDropdown
    dropdown.dropdownInit()
    for _, info in ipairs(dropdown.dropdownEntries) do
        if info.value == locale then info.func(); return end
    end
    error("language option missing: " .. locale)
end
selectLanguage("ruRU")
assert(crossTest.panelFontState().mainAppliedFont == "Fonts\\ARIALN.TTF", "committed Russian restores normal Cyrillic face")
assert(crossTest.profileState().settings.fontBeforeAutoSwitch == "Fonts\\FRIZQT__.TTF", "Russian fallback preserves original choice")
selectLanguage("enUS")
assert(crossTest.profileState().settings.font == "Fonts\\FRIZQT__.TTF", "English restores original choice")
assert(crossTest.profileState().settings.fontBeforeAutoSwitch == nil, "restored choice clears automatic fallback")
print("Appearance cold-client and cross-language regressions passed")
