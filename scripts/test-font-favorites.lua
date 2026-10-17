local fixtures = assert(loadfile('scripts/smoke.lua'))('fixtures')
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
    local opts = { forever = forever, bundledFonts = true,
        inCombatLockdown = function() return combat end,
        isKnownFontFile = function() return true end }
    local env, addon, test = fixtures.loadStatsPro('enUS', opts)
    for _, message in ipairs(env.__prints) do
        check(not message:find('FONT_GLYPH_PATTERNS regression', 1, true),
            'loading emits no glyph-pattern regression warning')
    end
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    local picker = addon.settingsUI.fontPicker
    picker.Show(addon)
    local last = picker.buttons[#picker.BuildFontsList(addon)]
    local name, path = last.fontName, last.fontPath
    local settings = test.profileState().settings
    local saved = settings.font
    fire(last.favorite, 'OnEnter')
    check(last.favoriteHover and last.favoriteHover:IsShown(), 'star hover highlights its whole font cell')
    check(last.text.textColor.r == 1 and last.text.textColor.g == 0.8,
        'star hover lights the font name in gold')
    check(not picker.buttons[1].favoriteHover:IsShown(), 'star hover does not highlight a neighboring font')
    check(test.panelFontState().mainAppliedFont == path, 'star hover previews its font')
    check(last.favorite.statsProHovered, 'star hover state participates in row reuse')
    local tooltip = last.favorite.statsProTooltipProvider(last.favorite)
    check(tooltip == 'Add favorite', 'empty star explains its action')
    last.favorite.scripts.OnClick(last.favorite)
    check(picker.frame:IsShown(), 'star keeps picker open')
    check(settings.font == saved, 'star does not select the font')
    check(test.panelFontState().mainAppliedFont == last.fontPath,
        'reordered row previews the font now under the pointer')
    check(last.favoriteHover:IsShown() and last.text.textColor.g == 0.8,
        'favorite sorting retains the hovered cell highlight')
    fire(last.favorite, 'OnLeave')
    check(not last.favoriteHover:IsShown(), 'leaving star clears whole-cell gold highlight')
    check(last.text.textColor.g ~= 0.8, 'leaving star restores the normal font label color')
    env.__flushTimers(0.2)
    check(test.panelFontState().mainAppliedFont == saved, 'leaving star restores committed font')
    check(picker.buttons[1].fontName == name, 'favorite sorts first')
    check(picker.buttons[1].favorite.isFavorite, 'favorite indicator is filled')
    check(env.StatsProDB.account.fontFavorites[path:lower():gsub('/', '\\')] == true,
        'favorite belongs to the account')
    check(settings.fontFavorites == nil, 'favorite does not enter profile settings')
    fire(last.favorite, 'OnEnter')
    last.favorite:Disable()
    check(not last.favoriteHover:IsShown(), 'disabled star clears its cell highlight')
    last.favorite:Enable()
    fire(last.favorite, 'OnEnter')
    fire(last.favorite, 'OnHide')
    check(not last.favoriteHover:IsShown(), 'hiding star clears its cell highlight')
    local account = env.StatsProDB.account
    local favorites = account.fontFavorites
    combat = true
    check(not picker.ToggleFavorite(addon, path), 'combat blocks favorite changes')
    check(account.fontFavorites == favorites, 'combat preserves favorite table identity')
    combat = false
    check(not picker.ToggleFavorite(addon, 'Interface\\AddOns\\Missing\\Absent.ttf'),
        'unoffered font cannot be starred')
    check(account.fontFavorites == favorites, 'unavailable font leaves preferences untouched')
    picker.Hide(addon)
    opts.statsProDB = env.StatsProDB
    local reloadedEnv, reloaded = fixtures.loadStatsPro('enUS', opts)
    reloadedEnv.__fireEvent('PLAYER_ENTERING_WORLD')
    reloaded:OpenConfigMenu()
    local reloadedPicker = reloaded.settingsUI.fontPicker
    reloadedPicker.Show(reloaded)
    check(reloadedPicker.buttons[1].fontName == name, 'favorite survives reload')
    reloadedPicker.buttons[1].favorite.scripts.OnClick(reloadedPicker.buttons[1].favorite)
    check(not reloadedEnv.StatsProDB.account.fontFavorites[path:lower():gsub('/', '\\')],
        'second click removes favorite')
    local previous
    for _, entry in ipairs(reloadedPicker.BuildFontsList(reloaded)) do
        check(not previous or previous <= entry.sortKey, 'removal restores alphabetical order')
        previous = entry.sortKey
    end

    -- Compatibility filtering is stronger than favorite ordering. Switching back
    -- restores the star, without using an incompatible face in the meantime.
    local latinOnly
    for _, entry in ipairs(reloadedPicker.BuildFontsList(reloaded)) do
        if entry.name == 'Bangers' then latinOnly = entry end
    end
    assert(latinOnly)
    check(reloadedPicker.ToggleFavorite(reloaded, latinOnly.path), 'Latin favorite can be added')
    local function language(locale)
        reloadedEnv.StatsProLanguageDropdown.dropdownInit()
        for _, entry in ipairs(reloadedEnv.StatsProLanguageDropdown.dropdownEntries) do
            if entry.value == locale then entry.func(); return end
        end
        error('Missing language: ' .. locale)
    end
    language('ruRU')
    for _, entry in ipairs(reloadedPicker.BuildFontsList(reloaded)) do
        check(entry.name ~= 'Bangers', 'incompatible favorite remains hidden')
    end
    language('enUS')
    check(reloadedPicker.BuildFontsList(reloaded)[1].name == 'Bangers',
        'language switch retains favorites')

    reloadedPicker.Hide(reloaded)
    opts.statsProDB = reloadedEnv.StatsProDB
    opts.statsProDB.dbVersion = opts.statsProDB.dbVersion + 1
    local futureEnv, futureAddon = fixtures.loadStatsPro('enUS', opts)
    futureEnv.__fireEvent('PLAYER_ENTERING_WORLD')
    local preserved = opts.statsProDB.account.fontFavorites
    check(not futureAddon.settingsUI.fontPicker.ToggleFavorite(futureAddon, latinOnly.path),
        'future saved data refuses favorite writes')
    check(opts.statsProDB.account.fontFavorites == preserved, 'future data remains untouched')
end
print('Font favorites: ' .. checks .. ' checks passed')
