local fixtures = assert(loadfile('scripts/smoke.lua'))('fixtures')
local archon = {}
setfenv(assert(loadfile('StatsPro_ArchonTargets.lua')), archon)()
-- Menu behavior uses shipped profile metadata, but deterministic player targets:
-- a future source outage must not silently change this UI fixture's coverage.
local function menuSnapshot()
    local snapshot = { schemaVersion = 6, source = 'archon', snapshots = {} }
    local paths = {
        mythicPlusCurrent = 'mythic-plus/overview/10/all-dungeons/this-week',
        mythicPlusHighKeys = 'mythic-plus/overview/high-keys/all-dungeons/this-week',
        raidNormal = 'raid/overview/normal/all-bosses',
        raidHeroic = 'raid/overview/heroic/all-bosses',
        raidMythic = 'raid/overview/mythic/all-bosses',
    }
    for key, profile in pairs(archon.StatsProArchonTargets.snapshots) do
        local copy = {}
        for field, value in pairs(profile) do
            if field ~= 'specs' then copy[field] = value end
        end
        copy.specs = { MAGE = {}, PALADIN = {} }
        for _, player in ipairs({
            { 'MAGE', 'mage', 'frost' }, { 'PALADIN', 'paladin', 'protection' },
            { 'PALADIN', 'paladin', 'retribution' },
        }) do
            copy.specs[player[1]][player[3]] = {
                sourceUrl = 'https://www.archon.gg/wow/builds/' .. player[3] .. '/' .. player[2] .. '/' .. paths[key],
                targets = { crit = 100, haste = 200, mastery = 300, versatility = 400 },
                order = { 'crit', 'haste', 'mastery', 'versatility' },
            }
        end
        snapshot.snapshots[key] = copy
    end
    return snapshot
end
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
    local env, addon, test = fixtures.loadStatsPro('enUS', {
        forever = forever, unitGUID = function() return 'Player-SettingsTimer' end,
        specIndex = 1, specID = 64,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    local slider, window = env.StatsProRefreshSlider, addon.settingsUI.frame
    local after = env.C_Timer.After
    local function tick(elapsed)
        for _, frame in pairs(env.__frames) do
            if frame.scripts and frame.scripts.OnUpdate then frame.scripts.OnUpdate(frame, elapsed) end
        end
    end
    local rejectedDelay = 0.05
    env.C_Timer.After = function(delay, callback)
        if rejectedDelay == 0.05 and delay == rejectedDelay then error('slider timer unavailable') end
        after(delay, callback)
        if rejectedDelay == 0 and delay == rejectedDelay then error('resize timer rejected after enqueue') end
    end
    local oldInterval = test.cachedUpdateInterval()
    check(pcall(slider.scripts.OnValueChanged, slider, 0.25), 'first slider move survives rejected scheduling')
    tick(0.03)
    check(pcall(slider.scripts.OnValueChanged, slider, 0.8), 'new slider move replaces the rejected scheduling')
    tick(0.03)
    check(test.cachedUpdateInterval() == oldInterval, 'superseded slider fallback cannot run before latest grace expires')
    tick(0.03)
    check(math.abs(test.cachedUpdateInterval() - 0.8) < 0.001, 'ticker applies the latest saved refresh interval')

    local oldHeight = window:GetHeight()
    env.UIParent:SetHeight(450)
    local readHeight = env.UIParent.GetHeight
    local reads = 0
    env.UIParent.GetHeight = function(parent)
        reads = reads + 1
        return readHeight(parent)
    end
    rejectedDelay = 0
    check(pcall(env.__fireEvent, 'DISPLAY_SIZE_CHANGED'), 'viewport resize survives rejected scheduling')
    tick(0.01)
    check(window:GetHeight() < oldHeight, 'ticker applies the latest viewport dimensions')
    rejectedDelay = nil
    local beforeLateTimer = reads
    env.__flushTimers(0)
    check(reads == beforeLateTimer, 'late native callback does not repeat the ticker resize')
    env.__flushTimers(0.1)
    check(window:GetHeight() < oldHeight, 'normal settling pass keeps the recovered viewport dimensions')
end
for _, forever in ipairs({ false, true }) do
    local combat = false
    local env, addon, test = fixtures.loadStatsPro('enUS', {
        forever = forever, bundledFonts = true, isKnownFontFile = function() return true end,
        unitClassToken = 'MAGE', specIndex = 1, specID = 64,
        statsProArchonTargets = menuSnapshot(),
        inCombatLockdown = function() return combat end,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    for _, link in ipairs({
        { env.StatsProKoFiLinkButton, 'Developer page', 'https://ko-fi.com/antrakt92' },
        { env.StatsProContactLinkButton, 'Report a bug or suggest a feature',
            'https://github.com/Antrakt92/StatsPro/issues' },
    }) do
        fire(link[1], 'OnEnter')
        check(env.GameTooltip.lines[1].left == link[2], 'header tooltip explains its purpose')
        check(env.GameTooltip.lines[2].left:find(link[3], 1, true), 'header tooltip shows the exact destination')
        check(env.GameTooltip.lines[2].left:find('Click to copy the link.', 1, true), 'header tooltip explains the copy action')
        fire(link[1], 'OnLeave')
        check(not env.GameTooltip:IsShown(), 'leaving header links dismisses their tooltip')
    end
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
-- A selected raid difficulty can disappear for one specialization while the
-- same menu continues to offer the other difficulties and specializations.
do
    local snapshot = menuSnapshot()
    for _, key in ipairs({ 'raidNormal', 'raidHeroic' }) do
        snapshot.snapshots[key].specs.PALADIN.protection = {
            unavailable = 'archon-error-500',
            sourceUrl = 'https://www.archon.gg/wow/builds/protection/paladin/raid/overview/'
                .. (key == 'raidNormal' and 'normal' or 'heroic') .. '/all-bosses',
        }
    end
    local specID = 66
    local env, addon, test = fixtures.loadStatsPro('enUS', {
        unitClassToken = 'PALADIN', specIndex = 1,
        getSpecializationInfo = function() return specID end,
        statsProDB = { targetSnapshot = 'raidNormal' }, statsProArchonTargets = snapshot,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    local dropdown = env.StatsProTargetSnapshotDropdown
    local menu = addon.settingsUI.dropdownMenu
    check(dropdown.dropdownText == 'Raid Normal (Unavailable)', 'unavailable choice keeps its own caption')
    check(menu.Show(addon, dropdown), 'unavailable raid choice still opens the other available target options')
    check(test.cachedTargetSnapshot() == 'raidNormal', 'opening target menu does not replace the unavailable saved difficulty')
    local current
    for _, row in ipairs(menu.buttons) do
        if row.info then
            check(row.info.value ~= 'raidNormal' and row.info.value ~= 'raidHeroic',
                'unavailable Normal and Heroic choices are absent from owned menu')
            check(not row.info.checked and not row.mark:IsShown(),
                'an unavailable saved choice does not mark a different difficulty')
            if row.info.value == 'mythicPlusCurrent' then current = row end
        end
    end
    check(current ~= nil, 'available Mythic Plus target remains selectable')
    fire(current, 'OnClick')
    check(test.getDB('targetSnapshot') == 'mythicPlusCurrent', 'remaining option commits its own difficulty')
    check(not menu.frame:IsShown(), 'remaining option closes the target menu normally')
    specID = 70
    env.__fireEvent('PLAYER_SPECIALIZATION_CHANGED', 'player')
    check(menu.Show(addon, dropdown), 'target menu reopens after specialization change')
    local normal, heroic
    for _, row in ipairs(menu.buttons) do
        if row.info and row.info.value == 'raidNormal' then normal = row end
        if row.info and row.info.value == 'raidHeroic' then heroic = row end
    end
    check(normal ~= nil and heroic ~= nil, 'available raid difficulties return for another specialization')
    fire(normal, 'OnClick')
    check(test.getDB('targetSnapshot') == 'raidNormal', 'restored difficulty can be selected')
    check(dropdown.dropdownText == 'Raid Normal', 'recovered availability restores the ordinary caption')
    check(menu.Show(addon, dropdown), 'available Heroic can be opened before the next specialization change')
    for _, row in ipairs(menu.buttons) do
        if row.info and row.info.value == 'raidHeroic' then heroic = row end
    end
    specID = 66 -- API changed before the specialization event reached the popup.
    fire(heroic, 'OnClick')
    check(test.getDB('targetSnapshot') == 'raidNormal', 'stale unavailable click does not write another difficulty')
    check(dropdown.dropdownText == 'Raid Normal (Unavailable)', 'rejected stale click refreshes the saved caption')
end
-- Distinct addon windows share strata; every control in the focused family
-- must clear the other family's highest child, not just its root panel.
for _, forever in ipairs({ false, true }) do
    local env, addon = fixtures.loadStatsPro('enUS', { forever = forever, bundledFonts = true,
        isKnownFontFile = function() return true end, statsProArchonTargets = archon.StatsProArchonTargets })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    local root = env.StatsProConfigFrame
    local foreign = env.CreateFrame('Frame', nil, env.UIParent)
    local foreignControl = env.CreateFrame('Button', nil, foreign)
    foreignControl:SetFrameLevel(foreign:GetFrameLevel() + 14)
    env.AntraktWindowLayers.Register(foreign)
    env.AntraktWindowLayers.Focus(foreign)
    local function bounds(frame)
        local low, high = frame:GetFrameLevel(), frame:GetFrameLevel()
        for _, child in ipairs({ frame:GetChildren() }) do
            local childLow, childHigh = bounds(child)
            low, high = math.min(low, childLow), math.max(high, childHigh)
        end
        return low, high
    end
    local function checkInFront(front, back, label)
        local low = bounds(front)
        local _, high = bounds(back)
        check(low > high, label)
    end
    checkInFront(foreign, root, 'foreign window owns a coherent band above Settings')
    fire(env.StatsProLanguageDropdown.statsProTrigger, 'OnMouseDown')
    checkInFront(root, foreign, 'clicking a Settings control raises the whole family')
    addon.settingsUI.dropdownMenu.Show(addon, env.StatsProLanguageDropdown)
    check(addon.settingsUI.dropdownMenu.frame:GetFrameLevel() > select(2, bounds(root)),
        'owned language popup remains above every Settings child')
    env.AntraktWindowLayers.Focus(foreign)
    check(not addon.settingsUI.dropdownMenu.frame:IsShown() and not addon.settingsUI.dropdownMenu.catcher:IsShown(),
        'focusing another addon dismisses popup and its screen catcher')
    root:Hide(); root:Show()
    checkInFront(root, foreign, 'reopening Settings raises the full family')
    local rootLevel = root:GetFrameLevel()
    for _ = 1, 100 do
        env.AntraktWindowLayers.Focus(foreign)
        fire(root, 'OnMouseDown')
    end
    check(root:GetFrameLevel() == rootLevel, 'repeated focus compacts levels without unbounded growth')
    addon.settingsUI.fontPicker.Show(addon)
    check(addon.settingsUI.fontPicker.frame:GetFrameStrata() == 'DIALOG', 'font popup shares the family strata')
    env.AntraktWindowLayers.Focus(foreign)
    check(not addon.settingsUI.fontPicker.frame:IsShown() and not addon.settingsUI.fontPicker.catcher:IsShown(),
        'font popup cannot remain above a different focused addon')
    fire(root, 'OnMouseDown')
    local picker = env.ColorPickerFrame
    local oldStrata, oldLevel = picker:GetFrameStrata(), picker:GetFrameLevel()
    local swatch
    for _, frame in ipairs(env.__frames) do if frame.statsProColorKey then swatch = frame; break end end
    fire(assert(swatch), 'OnClick')
    check(picker:IsShown() and picker:GetFrameLevel() > select(2, bounds(root)),
        'owned Blizzard color picker opens above the complete Settings family')
    env.AntraktWindowLayers.Focus(foreign)
    check(not picker:IsShown(), 'other addon focus closes owned color preview')
    check(picker:GetFrameStrata() == oldStrata and picker:GetFrameLevel() == oldLevel,
        'closing owned color picker restores its prior layers')
    local focusedLevel = foreign:GetFrameLevel()
    picker:SetupColorPickerAndShow({ swatchFunc = function() end, cancelFunc = function() end })
    check(foreign:GetFrameLevel() == focusedLevel and root:GetFrameLevel() < foreign:GetFrameLevel(),
        'foreign reuse of the shared picker cannot focus StatsPro')
    picker:Hide()
    check(addon.profileUI.ShowSelfTestExport('SPS1:1 layering', 'report'), 'standalone report opens')
    local dialog = addon.profileUI.operationDialog
    check(dialog:IsVisible(), 'standalone report has visible ancestry')
    check(dialog:GetFrameLevel() > env.StatsProProfileOperationBlocker:GetFrameLevel(),
        'standalone report stays above its own blocker')
    addon.profileUI.CloseOperationDialog()
end
for locale, title in pairs({
    enUS = 'Developer page', ruRU = 'Страница разработчика', deDE = 'Entwicklerseite',
    frFR = 'Page du développeur', esES = 'Página del desarrollador', esMX = 'Página del desarrollador',
    itIT = 'Pagina dello sviluppatore', ptBR = 'Página do desenvolvedor', koKR = '개발자 페이지',
    zhCN = '开发者页面', zhTW = '開發者頁面',
}) do
    local env, addon = fixtures.loadStatsPro(locale, { statsProArchonTargets = archon.StatsProArchonTargets })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    fire(env.StatsProKoFiLinkButton, 'OnEnter')
    check(env.GameTooltip.lines[1].left == title, locale .. ' uses a neutral localized destination title')
    check(env.GameTooltip.lines[2].left:find('https://ko-fi.com/antrakt92', 1, true),
        locale .. ' keeps the exact approved destination')
end
do
    local recoveryCaptions = {
        enUS = 'Recover saved settings...',
        enGB = 'Recover saved settings...',
        ruRU = 'Восстановить сохранённые настройки...',
        deDE = 'Gespeicherte Einstellungen wiederherstellen...',
        frFR = 'Récupérer des paramètres enregistrés...',
        esES = 'Recuperar ajustes guardados...',
        esMX = 'Recuperar ajustes guardados...',
        itIT = 'Recupera impostazioni salvate...',
        ptBR = 'Recuperar configurações salvas...',
        koKR = '저장된 설정 복구...',
        zhCN = '恢复已保存的设置...',
        zhTW = '還原已儲存的設定...',
    }
    for locale, expected in pairs(recoveryCaptions) do
        for _, forever in ipairs({ false, true }) do
            local env, addon = fixtures.loadStatsPro(locale, {
                forever = forever, bundledFonts = true, isKnownFontFile = function() return true end,
                unitClassToken = 'MAGE', specIndex = 1, specID = 64,
            })
            env.__fireEvent('PLAYER_ENTERING_WORLD')
            addon:OpenConfigMenu()
            addon.profileUI.OpenManager(true)
            local recovery = env.StatsProProfileRecoverButton
            check(recovery:GetText() == expected, locale .. ' translates the recovery action')
            local noSettings = recovery.statsProTooltipProvider(recovery)
            local englishCaption = locale == 'enUS' or locale == 'enGB'
            check(type(noSettings) == 'string' and (noSettings
                == 'No saved settings are available to recover.') == englishCaption,
                locale .. ' translates the disabled recovery explanation')
            local inUse = addon.profileUI.OperationErrorText('profile-in-use')
            check(type(inUse) == 'string' and (inUse
                == 'These saved settings are now in use. Choose another setup.') == englishCaption,
                locale .. ' translates the stale recovery explanation')
            addon.profileUI.manager:Hide()
            local view = env.StatsProConfigFrame.tabContents[1].quickSetupView
            view.refreshLayout(true, false)
            local blocked = view.disclosure.statsProTooltipProvider(view.disclosure)
            check(type(blocked) == 'string' and (blocked
                == 'Apply or cancel the preview first.') == englishCaption,
                locale .. ' translates the active preview explanation')
        end
    end
end
do
    local combat = false
    local env, addon = fixtures.loadStatsPro('enUS', {
        forever = true, uiParentWidth = 1280, uiParentHeight = 900,
        inCombatLockdown = function() return combat end,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    addon.profileUI.OpenManager(true)
    env.__flushTimers(0.1)
    local settings, manager = env.StatsProConfigFrame, addon.profileUI.manager
    local function near(actual, expected)
        return math.abs(actual - expected) < 0.001
    end
    local function setMethod(frame, method, implementation)
        frame[method] = implementation
    end
    env.__fireEvent('DISPLAY_SIZE_CHANGED')
    env.__flushTimers(0)
    env.UIParent:SetSize(640, 432)
    env.__flushTimers(0.1)
    check(near(settings:GetHeight(), 388.8), 'Settings catches a late viewport height')
    check(near(manager:GetWidth(), 576) and near(manager:GetHeight(), 367.2),
        'Profile Manager catches a late viewport width and height')

    env.__fireEvent('UI_SCALE_CHANGED')
    env.__flushTimers(0)
    env.UIParent:SetSize(800, 500)
    env.__fireEvent('DISPLAY_SIZE_CHANGED')
    env.__flushTimers(0)
    env.UIParent:SetSize(700, 460)
    combat = true
    env.__flushTimers(0.1)
    check(near(settings:GetHeight(), 414) and near(manager:GetHeight(), 391),
        'new resize replaces stale retry and refreshes shown Settings during combat')

    env.__fireEvent('DISPLAY_SIZE_CHANGED')
    env.__flushTimers(0)
    manager:Hide()
    settings:Hide()
    env.UIParent:SetSize(680, 420)
    env.__flushTimers(0.1)
    check(near(settings:GetHeight(), 414) and near(manager:GetHeight(), 391),
        'settled viewport retry leaves closed windows alone')
    combat = false
    addon:OpenConfigMenu()
    addon.profileUI.OpenManager(true)
    check(near(settings:GetHeight(), 378) and near(manager:GetHeight(), 357),
        'reopening uses current dimensions after a skipped closed-window retry')

    local readHeight = addon.settingsDesign.ReadUIParentHeight
    local reads = 0
    addon.settingsDesign.ReadUIParentHeight = function()
        reads = reads + 1
        if reads == 1 then return nil end
        return readHeight()
    end
    env.UIParent:SetSize(720, 480)
    env.__fireEvent('DISPLAY_SIZE_CHANGED')
    env.__flushTimers(0)
    addon.settingsDesign.ReadUIParentHeight = readHeight
    check(near(settings:GetHeight(), 378) and near(manager:GetHeight(), 408),
        'an unavailable Settings sample cannot block a good manager sample')
    env.__flushTimers(0.1)
    check(near(settings:GetHeight(), 432),
        'Settings retries a missed viewport sample')

    local settingsSize = settings.SetSize
    setMethod(settings, 'SetSize', function()
        setMethod(settings, 'SetSize', settingsSize)
        error('native Settings resize failure')
    end)
    env.UIParent:SetSize(760, 490)
    env.__fireEvent('DISPLAY_SIZE_CHANGED')
    env.__flushTimers(0)
    check(not addon.settingsUI.context.restoringScroll and near(manager:GetHeight(), 416.5),
        'failed Settings SetSize restores scroll guard and leaves manager responsive')
    env.__flushTimers(0.1)
    check(near(settings:GetHeight(), 441), 'Settings recovers from a one-shot native resize failure')

    local managerSize = manager.SetSize
    local managerAttempts = 0
    manager.SetSize = function()
        managerAttempts = managerAttempts + 1
        error('persistent native manager resize failure')
    end
    env.UIParent:SetSize(780, 520)
    env.__fireEvent('DISPLAY_SIZE_CHANGED')
    env.__flushTimers(0)
    env.__flushTimers(1)
    env.__flushTimers(1)
    check(managerAttempts == 2 and near(settings:GetHeight(), 468),
        'manager failures are bounded and do not undo Settings sizing')
    manager.SetSize = managerSize
    env.__fireEvent('UI_SCALE_CHANGED')
    env.__flushTimers(0.1)
    check(near(manager:GetHeight(), 440), 'a new event can recover after the manager retry budget')

    local refreshScroll = addon.settingsUI.RefreshActiveScroll
    local partialRefreshes = 0
    addon.settingsUI.RefreshActiveScroll = function()
        partialRefreshes = partialRefreshes + 1
        return refreshScroll()
    end
    setMethod(settings, 'SetSize', function(self, ...)
        setMethod(settings, 'SetSize', settingsSize)
        settingsSize(self, ...)
        error('native Settings resize partially applied')
    end)
    env.UIParent:SetSize(790, 510)
    env.__fireEvent('DISPLAY_SIZE_CHANGED')
    env.__flushTimers(0)
    check(near(settings:GetHeight(), 459) and not addon.settingsUI.context.restoringScroll,
        'partially applied native resize restores the original scroll guard')
    env.__flushTimers(0.1)
    check(partialRefreshes == 1, 'partially applied resize still refreshes scroll after matching dimensions')
    addon.settingsUI.RefreshActiveScroll = refreshScroll

    local scrollFrame = addon.settingsUI.context.scrollFrame
    local setScroll = scrollFrame.SetVerticalScroll
    local scrollAttempts = 0
    setMethod(scrollFrame, 'SetVerticalScroll', function(self, ...)
        scrollAttempts = scrollAttempts + 1
        if scrollAttempts == 1 then error('native scroll refresh failure') end
        return setScroll(self, ...)
    end)
    env.UIParent:SetSize(800, 475)
    env.__fireEvent('DISPLAY_SIZE_CHANGED')
    env.__flushTimers(0)
    check(not addon.settingsUI.context.restoringScroll and near(settings:GetHeight(), 427.5),
        'failed scroll refresh keeps the new geometry and restores the guard')
    env.__flushTimers(0.1)
    check(scrollAttempts == 2 and not addon.settingsUI.context.restoringScroll,
        'scroll refresh retries when geometry already applied')

    local navigation = addon.settingsUI.context
    settings.SwitchToTab(1)
    setScroll(scrollFrame, 230)
    addon.settingsUI.SaveActiveScroll()
    local failFirstScroll = true
    setMethod(scrollFrame, 'SetVerticalScroll', function(self, ...)
        if failFirstScroll then
            failFirstScroll = false
            error('first native scroll refresh fails after clamp')
        end
        return setScroll(self, ...)
    end)
    setMethod(settings, 'SetSize', function(self, ...)
        setMethod(settings, 'SetSize', settingsSize)
        settingsSize(self, ...)
        setScroll(scrollFrame, 0)
    end)
    env.UIParent:SetSize(810, 485)
    env.__fireEvent('DISPLAY_SIZE_CHANGED')
    env.__flushTimers(0)
    settings.SwitchToTab(2)
    settings.SwitchToTab(1)
    env.__flushTimers(0.1)
    check(near(scrollFrame:GetVerticalScroll(), 230) and near(navigation.scrollOffsets[1], 230),
        'tab switching cannot discard the saved offset after a failed resize refresh')
end
for _, locale in ipairs({ 'enUS', 'deDE', 'ruRU' }) do
    local env, addon = fixtures.loadStatsPro(locale, {
        forever = true, uiParentWidth = 640, uiParentHeight = 432,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    local control = env.StatsProForeverManaRegenMP5
    fire(control, 'OnEnter')
    local title, detail = env.GameTooltip.lines[1], env.GameTooltip.lines[2]
    local localized = addon.forever.Translate(addon.forever.manaRegenTooltip, locale)
        or addon.forever.manaRegenTooltip
    check(title.left == addon.forever.Translate('Mana Regen / 5 sec', locale),
        locale .. ' keeps the mana regeneration tooltip title')
    check(detail.left:find(localized, 1, true) == 1 and detail.wrapText == true,
        locale .. ' wraps adaptive mana regeneration help without dropping text')
    fire(control, 'OnLeave')
    check(not env.GameTooltip:IsShown(), locale .. ' dismisses the mana regeneration tooltip')
end
for _, forever in ipairs({ false, true }) do
    local playerName, realm = 'Охотник', '服务器'
    local fontName, fontPath = 'Шрифт 體', 'Interface\\AddOns\\Media\\Mixed.ttf'
    local env, addon, test = fixtures.loadStatsPro('enUS', {
        forever = forever,
        statsProDB = { font = fontPath },
        lsmFonts = { { name = fontName, path = fontPath } },
        unitGUID = function() return 'Player-1-MIXED-SCRIPT' end,
        unitFullName = function() return playerName, realm end,
        getSpecialization = function() return 1 end,
        specID = 73,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    addon.profileUI.OpenManager(true)
    local baseline = addon.sharedFonts.baseline.path
    local header = env.StatsProActiveProfileButton.statsProText
    local currentRow = addon.profileUI.managerRows[1]
    local row = currentRow.text
    local manage = env.StatsProManageProfilesButton.statsProText
    for _, region in ipairs({ header, row }) do
        check(region:GetText():find(playerName .. '-' .. realm, 1, true), 'profile text keeps mixed-script names')
        check(region:GetFont() == baseline, 'names use a bundled font in English Settings')
    end
    check(manage:GetFont() ~= baseline, 'ordinary Settings controls keep the English UI face')
    local function mismatches()
        return tonumber(addon.fontRuntime.ConfigFontDiagnostic():match('mismatched=(%d+)'))
    end
    check(mismatches() == 0, 'dedicated name fonts do not count as diagnostic mismatches')
    local base = manage:GetFont()
    local preview = 'Fonts\\ARIALN.TTF'
    check(test.applyConfigFont(base, false, preview), 'Settings font preview can apply')
    check(manage:GetFont() == preview and header:GetFont() == baseline and row:GetFont() == baseline,
        'font preview keeps mixed-script names readable')
    check(mismatches() == 0, 'diagnostics accept different effective faces during preview')
    local rowFont, rowSize, rowFlags = row:GetFont()
    row:SetFont(preview, rowSize, rowFlags)
    check(mismatches() == 1, 'diagnostics still detect a name region using the wrong font')
    row:SetFont(rowFont, rowSize, rowFlags)
    check(addon.fontRuntime.ApplyCommittedConfigFont('enUS'), 'Settings fonts can be reapplied')
    check(header:GetFont() == baseline and row:GetFont() == baseline,
        'font refresh keeps Cyrillic-capable faces for names')
    row:SetWidth(40)
    row.GetStringWidth = function() error('must not measure by changing the width') end
    local nameWidthWrites = 0
    local originalSetWidth = row.SetWidth
    row.SetWidth = function(self, width)
        nameWidthWrites = nameWidthWrites + 1
        return originalSetWidth(self, width)
    end
    fire(currentRow, 'OnEnter')
    check(env.GameTooltip:IsShown() and env.GameTooltip.lines[1].left == row:GetText(),
        'hover shows the full clipped character name')
    check(nameWidthWrites == 0, 'measuring an anchored name does not change its layout')
    fire(currentRow, 'OnLeave')
    addon.profileUI.HideManager()
    local picker = addon.settingsUI.fontPicker
    picker.Show(addon)
    local fontRow
    for _, button in ipairs(picker.buttons) do
        if button.fontName == fontName then fontRow = button; break end
    end
    check(fontRow and fontRow.text:GetText() == fontName and fontRow.text:GetFont() == baseline,
        'catalogue renders third-party names written in multiple scripts')
    local caption = env.StatsProFontDropdownText
    check(caption:GetText() == fontName and caption:GetFont() == baseline,
        'collapsed Font field renders the selected name with the same coverage')
end
print('Settings menus: ' .. checks .. ' checks passed')
