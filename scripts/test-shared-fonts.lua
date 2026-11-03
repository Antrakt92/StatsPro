local fixtures = assert(loadfile('scripts/smoke.lua'))('fixtures')
local checks = 0
local function check(value, message)
    checks = checks + 1
    assert(value, message)
end
for _, forever in ipairs({ false, true }) do
    local preferred = 'Interface\\AddOns\\StatsPro\\fonts\\PT_Sans-Web-Regular.ttf'
    local env, addon, test = fixtures.loadStatsPro('enUS', {
        forever = forever, statsProDB = { font = preferred },
        isKnownFontFile = function(path)
            return not path:lower():find('pt_sans', 1, true)
        end,
    })
    check(addon.AntraktFontCatalog ~= nil, 'snapshot loads even without the optional provider')
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    check(test.profileState().settings.font == preferred, 'missing collection never replaces the saved preference')
    check(addon.sharedFonts ~= nil, 'shared font adapter is initialized')
    check(addon.sharedFonts.status == 'provider-unavailable', 'provider absence has an explicit state')
    check(addon.fontRuntime.preferredPath() == preferred, 'preferred caption retains the original choice')
    check(test.panelFontState().mainAppliedFont ~= preferred, 'missing selected file renders a temporary baseline')
end
local snapshot = assert(loadfile('AntraktFontCatalog.lua'))()
local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = clone(child) end
    return result
end
for _, forever in ipairs({false, true}) do
    local original = snapshot.fonts[1].aliases[1]
    local calls = 0
    local catalog = {formatMajor=1, catalogRevision=string.rep('a',64), fonts=clone(snapshot.fonts)}
    local future = clone(catalog.fonts[1])
    future.id, future.name, future.file = 'future-face', 'Future Face', 'Future.ttf'
    future.path = 'Interface\\AddOns\\AntraktFonts\\fonts\\Future.ttf'
    catalog.fonts[#catalog.fonts+1] = future
    local provider = {GetCatalog=function() calls=calls+1; return clone(catalog) end}
    local env, addon, test = fixtures.loadStatsPro('enUS', {
        forever=forever, statsProDB={font=original}, sharedProvider=provider,
        lsmFonts={{name=snapshot.fonts[1].name,path='Fonts\\ARIALN.TTF'}},
        isKnownFontFile=function() return true end,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    check(addon.sharedFonts.status=='available', 'new compatible revision is accepted')
    check(addon.sharedFonts.byID['future-face']~=nil, 'future face does not require a new core release')
    check(test.panelFontState().mainAppliedFont==catalog.fonts[1].path, 'owned alias resolves canonical provider despite an occupied LSM name')
    check(test.profileState().settings.font==original, 'canonical runtime path never replaces old saved alias')
    local bootstrapCalls=calls
    for _=1,20 do addon:RunUpdateStatsSafe() end
    check(calls==bootstrapCalls, 'HUD/stat hot paths never clone provider catalogues')
    addon:OpenConfigMenu()
    addon.settingsUI.fontPicker.Show(addon)
    local account=env.StatsProDB.account
    account.fontFavorites={[original:lower()]=true}
    check(addon.settingsUI.fontPicker.Favorites(addon)[addon.sharedFonts.Identity(catalog.fonts[1].path)], 'favorites follow owned aliases')
    check(addon.settingsUI.fontPicker.ToggleFavorite(addon,catalog.fonts[1].path), 'canonical unstar succeeds')
    check(next(account.fontFavorites)==nil,'unstar removes historical alias rather than resurrecting it')
    local before=calls
    env.__registerLSMFont('Other1','Fonts\\ARIALN.TTF')
    env.__registerLSMFont('Other2','Fonts\\MORPHEUS.TTF')
    check(calls==before,'registration bursts defer catalogue clones')
    env.__flushTimers(0)
    check(calls==before+1,'registration bursts refresh provider exactly once')
    local candidate={}
    env.AntraktFonts=nil
    addon.fontRuntime.RefreshSharedCatalog(true)
    check(addon.legacyImport.CopyFont({font=original},candidate) and candidate.font==original,'recognized import survives absent provider')
end
for _, mutate in ipairs({
    function(value) value.formatMajor=2 end,
    function(value) value.fonts[1].path='Interface\\AddOns\\Other\\Foreign.ttf' end,
    function(value) value.fonts[1].cyrillic='true' end,
    function(value) value.fonts[2].id=value.fonts[1].id end,
    function(value) value.fonts[1].latinLocales={unsupported=true} end,
    function(value) value.fonts[300]=clone(value.fonts[1]) end,
}) do
    local catalog={formatMajor=1,catalogRevision=string.rep('a',64),fonts=clone(snapshot.fonts)}
    mutate(catalog)
    local _,addon=fixtures.loadStatsPro('enUS',{sharedProvider={GetCatalog=function() return catalog end}})
    check(addon.sharedFonts.status=='provider-incompatible','malformed provider safely rejects its whole catalogue')
end
for _, forever in ipairs({false,true}) do
    local combat=false
    local env,addon,test=fixtures.loadStatsPro('enUS',{
        forever=forever, statsProDB={fontSize=14}, testSharedFontsNotice=true,
        inCombatLockdown=function() return combat end,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    env.__flushTimers(.6)
    local notice=assert(addon.sharedFonts.notice,'existing account builds transition notice')
    check(notice:IsVisible(),'transition is actually visible')
    check(not notice.copy:IsEnabled(),'null marketplace URLs disable copy truthfully')
    check(env.StatsProDB.account.sharedFontsNotice==nil,'display does not acknowledge')
    combat=true;env.__fireEvent('PLAYER_REGEN_DISABLED')
    check(not notice:IsShown() and env.StatsProDB.account.sharedFontsNotice==nil,'combat suspends without acknowledging')
    combat=false;env.__fireEvent('PLAYER_REGEN_ENABLED')
    check(notice:IsShown(),'notice resumes on the safe lifecycle event')
    notice.scripts.OnKeyDown(notice,'ESCAPE')
    check(not notice:IsShown() and env.StatsProDB.account.sharedFontsNotice=='acknowledged','Escape explicitly acknowledges and closes')
    check(notice.propagateKeyboardInput==false,'handled Escape cannot leak into another window')
    local prefs=test.profileState().root
    check(prefs.account.sharedFontsNotice=='acknowledged','campaign belongs to account metadata')
    check(test.profileState().settings.sharedFontsNotice==nil,'campaign never enters profile settings')
    local env2,addon2=fixtures.loadStatsPro('enUS',{forever=forever,testSharedFontsNotice=true})
    env2.__fireEvent('PLAYER_ENTERING_WORLD');env2.__flushTimers(.6)
    check(env2.StatsProDB.account.sharedFontsNotice=='fresh','fresh account gets a distinct marker')
    check(addon2.sharedFonts.notice==nil,'fresh account has no migration window')
end
for _, forever in ipairs({false,true}) do
    local face=snapshot.fonts[1]
    local _,addon=fixtures.loadStatsPro('enUS',{
        forever=forever, sharedProvider={GetCatalog=function()
            return {formatMajor=1,catalogRevision=string.rep('a',64),fonts=clone(snapshot.fonts)}
        end}, lsmFonts={{name='Different Alias Name',path=face.aliases[1]}},
        isKnownFontFile=function() return true end,
    })
    local count=0
    for _,row in ipairs(addon.settingsUI.fontPicker.BuildFontsList(addon)) do
        if addon.sharedFonts.Identity(row.path)=='owned:'..face.id then count=count+1 end
    end
    check(count==1,'owned identity is deduplicated across differently named legacy LSM aliases')
    for _,failure in ipairs({'throw','missing-edit','hidden-edit','success'}) do
        local env,host=fixtures.loadStatsPro('enUS',{
            forever=forever,statsProDB={fontSize=14},testSharedFontsNotice=true,
        })
        host.sharedFonts.snapshot.links.github='https://example.invalid/fonts'
        env.__fireEvent('PLAYER_ENTERING_WORLD');env.__flushTimers(.6)
        local key=host.developerLinks.popupKey
        local original=env.StaticPopupDialogs[key].OnShow
        env.StaticPopupDialogs[key].OnShow=function(popup,data)
            if failure=='throw' then popup.GetEditBox=function() return nil end end
            original(popup,data)
            if failure=='missing-edit' then popup.GetEditBox=function() return nil end end
            if failure=='hidden-edit' then popup.EditBox:Hide() end
        end
        local notice=host.sharedFonts.notice
        notice.copy.scripts.OnClick()
        local popup=env.__staticPopups[key]
        if failure=='success' then
            check(popup and popup:IsVisible(),'successful copy handoff leaves the actual copy popup visible')
            check(not notice:IsVisible(),'successful copy handoff hides source notice')
            check(env.StatsProDB.account.sharedFontsNotice=='acknowledged','actual copy handoff acknowledges campaign')
        else
            check(not popup or not popup:IsVisible(),'failed copy cleans up only the owned partial popup: '..failure)
            check(env.StatsProDB.account.sharedFontsNotice==nil,'failed copy never acknowledges campaign')
            check(notice:IsVisible(),'failed copy leaves migration guidance available')
        end
    end
end
for _,forever in ipairs({false,true}) do
    local combat=false
    local env,host=fixtures.loadStatsPro('enUS',{
        forever=forever,testSharedFontsNotice=true,inCombatLockdown=function() return combat end,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD');env.__flushTimers(.6)
    host:OpenConfigMenu()
    local marker=assert(host.sharedFonts.marker)
    marker.scripts.OnClick()
    check(host.sharedFonts.notice and host.sharedFonts.notice:IsVisible(),'manual details may open over own Settings after a fresh install')
    local busy,owner=host.sharedFonts.coordinator:RequestShow()
    check(busy and owner=='StatsPro','manual details hold the common coordinator token')
    host.sharedFonts.HideNotice()
    local blocked=false
    host.sharedFonts.coordinator:Register('OtherFontHost',{
        state=nil,canShow=function() return true end,
        show=function() blocked=true;return true end,
        acknowledge=function() return true end,dismiss=function() blocked=false end,
    })
    host.sharedFonts.coordinator:RequestShow()
    check(blocked,'other addon can own the common notification surface')
    marker.scripts.OnClick()
    check(not host.sharedFonts.notice:IsVisible(),'manual details cannot overlap another addon notification')
    host.sharedFonts.coordinator:Register('OtherFontHost',{
        state='fresh',canShow=function() return false end,show=function() return false end,
        acknowledge=function() return true end,dismiss=function() blocked=false end,
    })
    combat=true;marker.scripts.OnClick()
    check(not host.sharedFonts.notice:IsVisible(),'manual details are blocked in combat')
    combat=false;marker.scripts.OnClick()
    host.sharedFonts.notice.close.scripts.OnClick()
    check(env.StatsProDB.account.sharedFontsNotice=='acknowledged','manual acknowledgement persists for a fresh account')
    marker.scripts.OnClick()
    check(host.sharedFonts.notice:IsVisible(),'acknowledged account can reopen manual details')
    host.sharedFonts.HideNotice()
    check(not host.sharedFonts.coordinator:RequestShow(),'manual hide never schedules an acknowledged automatic campaign')
    local requestInfo=host.sharedFonts.coordinator.RequestInfo
    host.sharedFonts.coordinator.RequestInfo=function() error('manual request fixture failure') end
    local safe=pcall(marker.scripts.OnClick)
    check(safe and not host.sharedFonts.manualRequest,'manual request error cannot leak the own-Settings bypass')
    host.sharedFonts.coordinator.RequestInfo=requestInfo
    local pendingEnv,pending=fixtures.loadStatsPro('enUS',{
        forever=forever,statsProDB={fontSize=14},testSharedFontsNotice=true,
    })
    pendingEnv.__fireEvent('PLAYER_ENTERING_WORLD')
    pending:OpenConfigMenu()
    pending.sharedFonts.marker.scripts.OnClick()
    check(pending.sharedFonts.notice:IsVisible(),'pending campaign may be opened manually over own Settings')
    check(pendingEnv.StatsProDB.account.sharedFontsNotice==nil,'manual opening does not acknowledge pending campaign')
    pending.sharedFonts.notice.close.scripts.OnClick()
    check(pendingEnv.StatsProDB.account.sharedFontsNotice=='acknowledged','manual confirmation persists pending campaign')
end
print('Shared fonts: ' .. checks .. ' checks passed')
