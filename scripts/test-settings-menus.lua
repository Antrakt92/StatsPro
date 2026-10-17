local fixtures = assert(loadfile('scripts/smoke.lua'))('fixtures')
local archon = {}
setfenv(assert(loadfile('StatsPro_ArchonTargets.lua')), archon)()
local checks = 0
local function check(ok, message)
    checks = checks + 1
    assert(ok, message)
end
local function fire(control, event)
    if control.scripts[event] then control.scripts[event](control) end
    for _, hook in ipairs(control.hooks[event] or {}) do hook(control) end
end
for _, forever in ipairs({ false, true }) do
    local combat = false
    local env, addon, test = fixtures.loadStatsPro('enUS', {
        forever = forever, bundledFonts = true, isKnownFontFile = function() return true end,
        statsProArchonTargets = archon.StatsProArchonTargets,
        inCombatLockdown = function() return combat end,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    local menu = addon.settingsUI.dropdownMenu
    check(menu ~= nil, 'Settings use addon-owned menus')
    local function clickField(dropdown)
        local trigger = dropdown.statsProTrigger
        local before = env.__nativeDropdownOpens
        fire(trigger, 'OnMouseDown')
        check(env.__nativeDropdownOpens == before, 'press never opens the inherited native list')
        fire(trigger, 'OnMouseUp')
        fire(trigger, 'OnClick')
        check(env.__nativeDropdownOpens == before, 'release opens no native list')
        check(trigger.registeredClicks and trigger.registeredClicks[1] == 'LeftButtonUp',
            'dropdown toggles once on left-button release')
    end
    local settingKeys = { StatsProDisplayModeDropdown = 'displayMode', StatsProLabelStyleDropdown = 'labelStyle',
        StatsProTextOutlineDropdown = 'textOutlineStyle', StatsProTargetSnapshotDropdown = 'targetSnapshot' }
    for _, name in ipairs({ 'StatsProDisplayModeDropdown', 'StatsProLabelStyleDropdown',
        'StatsProTextOutlineDropdown', 'StatsProLanguageDropdown', 'StatsProTargetSnapshotDropdown' }) do
        local dropdown = env[name]
        if dropdown then
            clickField(dropdown)
            check(menu.openDropdown == dropdown and menu.frame:IsShown(), name .. ' opens owned menu')
            check(menu.catcher:IsShown(), 'outside-click catcher is active')
            check(menu.frame.backdrop.edgeFile == 'Interface\\Buttons\\WHITE8X8', 'popup uses a thin matching border')
            local count, selected = 0, 0
            for _, row in ipairs(menu.buttons) do
                if row.info then
                    count = count + 1
                    check(row:GetHeight() == 24, 'options use compact 24-pixel click targets')
                    check(row.statsProMenuSurface.statsProSurfaceRole == 'viewport', 'rows use a flat popup surface')
                    if row.mark:IsShown() then selected = selected + 1 end
                end
            end
            check(count > 0 and selected == 1, 'exactly one current option is marked')
            fire(menu.catcher, 'OnMouseDown')
            check(not menu.frame:IsShown() and not menu.catcher:IsShown(), 'outside click closes only owned popup')
            check(not dropdown.statsProTrigger.statsProActive, 'closing resets trigger state')
            for _, row in ipairs(menu.buttons) do
                check(not row.statsProSelected and not row.mark:IsShown(), 'dismissed menu clears pooled selection state')
            end
            if settingKeys[name] then
                menu.Show(addon, dropdown)
                local alternative
                for _, row in ipairs(menu.buttons) do
                    if row.info and not row.info.checked then alternative = row; break end
                end
                if alternative then
                    local expected = alternative.info.value
                    fire(alternative, 'OnClick')
                    check(test.getDB(settingKeys[name]) == expected, name .. ' commits its own option')
                    check(not menu.frame:IsShown(), 'simple selection closes popup')
                else menu.Hide(addon) end
            end
        end
    end
    clickField(env.StatsProFontDropdown)
    check(addon.settingsUI.fontPicker.frame:IsShown(), 'font field opens its picker directly')
    addon.settingsUI.fontPicker.Hide(addon)
    local language = env.StatsProLanguageDropdown
    local normalProvider = language.statsProBuildOptions
    language.statsProBuildOptions = function(add)
        for i = 1, 20 do add({ text = 'Overflow ' .. i, value = i, checked = i == 17, func = function() end }) end
    end
    menu.Show(addon, language)
    check(menu.scroll.ScrollBar:IsShown(), 'long menu exposes styled scrollbar')
    check(menu.frame:GetHeight() == 12 * 24 + 12, 'long menu keeps compact bounded height')
    check(menu.scroll:GetVerticalScroll() > 0, 'long menu scrolls current option into view')
    menu.Hide(addon)
    language.statsProBuildOptions = normalProvider
    check(menu.Show(addon, language), 'language menu opens')
    check(menu.frame:GetWidth() <= 260, 'ordinary popup avoids oversized minimum width')
    check(not menu.scroll.ScrollBar:IsShown(), 'shorter menu hides unneeded scrollbar')
    check(not menu.buttons[20]:IsShown(), 'pooled overflow rows are hidden on reuse')
    local russian, english
    local fonts = {}
    for _, row in ipairs(menu.buttons) do
        if row.info then
            fonts[row] = { object = row.text:GetFontObject(), path = row.text:GetFont() }
            if row.info.value == 'ruRU' then russian = row end
            if row.info.value == 'enUS' then english = row end
        end
    end
    local savedLocale, savedFont = test.getDB('forceLocale'), test.profileState().settings.font
    fire(assert(russian), 'OnEnter')
    check(addon.settingsUI.localization.previewLocale == 'ruRU', 'owned row previews Russian')
    check(test.getDB('forceLocale') == savedLocale, 'hover does not commit language')
    for row, font in pairs(fonts) do
        check(row.text:GetFontObject() == font.object, 'language names retain their own font object during preview')
        check(row.text:GetFont() == font.path, 'language names retain actual script coverage during preview')
    end
    menu.Hide(addon)
    check(not addon.settingsUI.localization.previewActive, 'dismissal cancels language preview')
    check(test.profileState().settings.font == savedFont, 'dismissal preserves saved HUD font')
    menu.Show(addon, language)
    fire(russian, 'OnEnter')
    fire(russian, 'OnClick')
    check(test.getDB('forceLocale') == 'ruRU', 'owned language button commits selection')
    check(not menu.frame:IsShown(), 'successful selection closes menu')
    check(not addon.settingsUI.localization.previewActive, 'commit clears preview state')
    menu.Show(addon, language)
    local staleClick = english.scripts.OnClick
    menu.Hide(addon)
    menu.Show(addon, language)
    staleClick(english)
    check(test.getDB('forceLocale') == 'ruRU', 'callback from earlier open cannot select a reused row')
    combat = true
    fire(english, 'OnClick')
    check(test.getDB('forceLocale') == 'ruRU', 'combat blocks an already open menu callback')
    menu.Hide(addon)
    check(not menu.Show(addon, language), 'combat blocks opening settings menus')
    combat = false
    menu.Show(addon, language)
    addon.settingsUI.fontPicker.Show(addon)
    check(not menu.frame:IsShown(), 'font picker replaces option menu')
    menu.Show(addon, language)
    check(not addon.settingsUI.fontPicker.frame:IsShown(), 'option menu replaces font picker')
    fire(language.statsProTrigger, 'OnHide')
    check(not menu.frame:IsShown(), 'hidden dropdown owner closes popup')
    menu.Show(addon, language)
    language.statsProTrigger:Disable()
    check(not menu.frame:IsShown() and not menu.catcher:IsShown(), 'disabled dropdown owner closes popup')
    language.statsProTrigger:Enable()
    menu.Show(addon, language)
    menu.frame:Hide()
    env.__flushTimers(0)
    check(addon.settingsUI.context.frame:IsShown(), 'Escape-style popup hide leaves Settings open')
    menu.Show(addon, language)
    local original = env.StatsProDB
    local future = { dbVersion = original.dbVersion + 1, untouched = true }
    env.StatsProDB = future
    fire(english, 'OnClick')
    check(env.StatsProDB == future and future.untouched and future.account == nil,
        'open callback cannot modify replacement or future-version data')
    menu.Hide(addon)
    env.StatsProDB = original
    check(test.getDB('forceLocale') == 'ruRU', 'original committed language survives rejected stale callback')
    local setOwnedFont = addon.fontRuntime.setOwnedFont
    addon.fontRuntime.setOwnedFont = function() return false end
    check(not menu.Show(addon, language), 'font activation failure does not open an unreadable menu')
    check(menu.openDropdown == nil and not menu.frame:IsShown() and not menu.catcher:IsShown(),
        'font activation failure leaves no active popup or click catcher')
    addon.fontRuntime.setOwnedFont = setOwnedFont
    menu.Show(addon, language)
    addon.settingsUI.context.frame:Hide()
    check(not menu.frame:IsShown() and not menu.catcher:IsShown(), 'Settings teardown leaves no orphan popup')
end
print('Settings menus: ' .. checks .. ' checks passed')
