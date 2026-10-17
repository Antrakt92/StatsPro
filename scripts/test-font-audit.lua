local fixtures = assert(loadfile('scripts/smoke.lua'))('fixtures')
local checks = 0
local function check(ok, message)
    checks = checks + 1
    assert(ok, message)
end
local function selectLanguage(env, locale)
    env.StatsProLanguageDropdown.dropdownInit()
    for _, entry in ipairs(env.StatsProLanguageDropdown.dropdownEntries) do
        if entry.value == locale then entry.func(); return end
    end
    error('Missing language: ' .. locale)
end
local function catalog(addon)
    local result = {}
    for _, entry in ipairs(addon.settingsUI.fontPicker.BuildFontsList(addon)) do result[entry.name] = entry end
    return result
end
for _, forever in ipairs({ false, true }) do
    local env, addon, test = fixtures.loadStatsPro('enUS', {
        forever = forever, bundledFonts = true, isKnownFontFile = function() return true end,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    for _, choice in ipairs({
        { 'ruRU', 'Neucha' }, { 'ruRU', 'Kosugi Maru' },
        { 'zhCN', 'Ma Shan Zheng' }, { 'zhCN', 'ZCOOL XiaoWei' },
        { 'koKR', 'Do Hyeon' }, { 'koKR', 'Nanum Pen Script' },
    }) do
        selectLanguage(env, choice[1])
        local entry = assert(catalog(addon)[choice[2]], 'Cross-client font is visible')
        check(addon.settingsUI.fontPicker.Pick(addon, entry), 'Visible font can actually be selected: ' .. choice[2])
        check(test.panelFontState().mainAppliedFont == entry.path, 'Selected cross-client font reaches HUD')
        check(test.profileState().settings.font == entry.path, 'Selected cross-client font is saved')
    end
    selectLanguage(env, 'enUS')
    local list = catalog(addon)
    check(list.Neucha ~= nil, 'Neucha is usable for English')
    check(list['Source Han Sans CN'] and not list['Source Han Sans TW'], 'Only one western Sans regional variant')
    check(list['Source Han Serif CN'] and not list['Source Han Serif TW'], 'Only one western Serif regional variant')
    check(not list['Fira Mono'] and not list['Liberation Mono'], 'Retired duplicate roles are absent')
    check(list.Hack and list['PT Mono'], 'Distinct monospaced roles remain')
    check(addon.settingsUI.fontPicker.Pick(addon, list.Neucha), 'Partial Western face can be selected for English')
    local saved = test.profileState().settings.font
    selectLanguage(env, 'frFR')
    check(catalog(addon).Neucha ~= nil and test.profileState().settings.font == saved, 'French retains compatible preference')
    selectLanguage(env, 'ptBR')
    check(not catalog(addon).Neucha and test.profileState().settings.font ~= saved, 'Portuguese hides and replaces incompatible face')
    selectLanguage(env, 'enUS')
    check(catalog(addon).Neucha ~= nil and test.profileState().settings.font == saved, 'English restores original preference')
    for _, locale in ipairs({ 'zhCN', 'zhTW' }) do
        selectLanguage(env, locale)
        local choices = catalog(addon)
        local region = locale == 'zhCN' and 'CN' or 'TW'
        local other = locale == 'zhCN' and 'TW' or 'CN'
        check(choices['Source Han Sans ' .. region] and not choices['Source Han Sans ' .. other], 'Chinese Sans uses matching regional forms')
        check(choices['Source Han Serif ' .. region] and not choices['Source Han Serif ' .. other], 'Chinese Serif uses matching regional forms')
    end
    for _, oldFile in ipairs({ 'FiraMono-Regular.ttf', 'LiberationMono-Regular.ttf' }) do
        local old = 'Interface\\AddOns\\StatsPro\\fonts\\' .. oldFile
        local replacement = 'Interface\\AddOns\\StatsPro\\fonts\\Hack-Regular.ttf'
        local oldEnv, oldAddon, oldTest = fixtures.loadStatsPro('enUS', {
            forever = forever, bundledFonts = true, statsProDB = { font = old, fontBeforeAutoSwitch = old, forceLocale = 'ruRU' },
            isKnownFontFile = function(path) return path ~= old end,
            setFontResult = function(_, path) return path ~= old end,
            fontObjectSetFontResult = function(_, path) return path ~= old end,
        })
        oldEnv.__fireEvent('PLAYER_ENTERING_WORLD')
        check(oldAddon.fontRuntime.catalogEntry(old) == replacement, 'Retired path resolves to retained asset')
        check(oldTest.profileState().settings.font == replacement, 'Saved retired face upgrades to Hack')
        check(oldTest.panelFontState().mainAppliedFont == replacement, 'Retired face renders with compatible replacement')
        check(not oldAddon.fontRuntime.pendingSavedFont, 'Retired path does not enter cold-asset retry loop')
        check(oldAddon.fontRuntime.usablePath(old:gsub('\\', '/'):upper()) == replacement, 'Retired aliases normalize separators and case')
    end
    for _, name in ipairs({ 'SourceHanSansCN-Regular.otf', 'SourceHanSerifTW-Regular.otf' }) do
        local external = 'Interface\\AddOns\\ExternalMedia\\' .. name
        check(not test.fontSupports(external, 'Hangul'), 'External region subset does not claim Korean')
    end
end
for _, forever in ipairs({ false, true }) do
    local function own(path) return type(path) == 'string' and path:find('Interface\\AddOns\\StatsPro\\fonts\\', 1, true) == 1 end
    local env, addon, test = fixtures.loadStatsPro('enUS', {
        forever = forever, bundledFonts = true, isKnownFontFile = own,
        setFontResult = function(_, path) return own(path) end,
        fontObjectSetFontResult = function(_, path) return own(path) end,
    })
    for locale, requirement in pairs({ koKR = 'Hangul', zhCN = 'Hans', zhTW = 'Hant' }) do
        local fallback = test.findCompatibleFont('Interface\\AddOns\\StatsPro\\fonts\\Hack-Regular.ttf', requirement, locale)
        check(fallback and own(fallback) and test.fontSupports(fallback, requirement), 'Bundled fallback works without native ' .. locale .. ' assets')
    end
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    selectLanguage(env, 'koKR')
    check(test.fontSupports(test.panelFontState().mainAppliedFont, 'Hangul'), 'Sparse client language switch renders Korean from bundled assets')
end
print('StatsPro font audit: PASS (' .. checks .. ' checks)')
