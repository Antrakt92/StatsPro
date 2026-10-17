-- Shared Appearance services under a cold Forever client and sparse media registry.
local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
local activated = {}
local env, addon, test = fixtures.loadStatsPro("enUS", {
    forever = true,
    lsmFonts = {},
    isKnownFontFile = function() return true end,
    setFontResult = function(_, path) return activated[path] == true end,
    fontObjectSetFontResult = function(object, path)
        if object.name == "StatsProFontAssetActivator" then activated[path] = true end
        return true
    end,
})
env.__fireEvent("PLAYER_ENTERING_WORLD")
local fonts = addon.settingsUI.fontPicker.BuildFontsList(addon, true)
assert(#fonts >= 4, "cold built-in fonts remain available with an empty SharedMedia registry")
for _, locale in ipairs({ "ruRU", "koKR", "zhCN", "zhTW" }) do
    local requirement = test.registrySnapshot().localeGlyphReq[locale]
    local path = test.findCompatibleFont("Fonts\\FRIZQT__.TTF", requirement)
    assert(path and test.fontSupports(path, requirement), "compatible client font for " .. locale)
    local info = {}
    addon.settingsUI.localization.MenuInfo(addon, info, locale)
    assert(info.fontObject, "language menu has its own font for " .. locale)
    assert(test.fontSupports(info.fontObject:GetFont(), requirement), "readable menu row for " .. locale)
    assert(info.icon and info.iconInfo.tSizeX == 18, "texture flag for " .. locale)
    addon.settingsUI.localization.Preview(addon, locale)
    local state = test.panelFontState()
    assert(test.fontSupports(state.mainAppliedFont, requirement), "readable HUD preview for " .. locale)
    addon.settingsUI.localization.CancelPreview(addon)
end
local auto = {}
addon.settingsUI.localization.MenuInfo(addon, auto, "auto")
assert(auto.iconInfo.tCoordLeft == 3 / 512, "Auto uses the client language flag")
local image = assert(io.open("textures/language-flags.tga", "rb"))
assert(#image:read("*a") == 18 + 512 * 32 * 4, "complete power-of-two RGBA flag atlas")
image:close()
print("Appearance cold-client and cross-language regressions passed")
