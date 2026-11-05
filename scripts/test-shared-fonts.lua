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
local function equal(left,right)
    if type(left)~=type(right) then return false end
    if type(left)~='table' then return left==right end
    for key,value in pairs(left) do if not equal(value,right[key]) then return false end end
    for key in pairs(right) do if left[key]==nil then return false end end
    return true
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
    addon.sharedFonts.snapshot.links={}
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
for _,forever in ipairs({false,true}) do
    local env,addon=fixtures.loadStatsPro('enUS',{
        forever=forever,statsProDB={fontSize=14},testSharedFontsNotice=true,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD');env.__flushTimers(.6)
    local notice=assert(addon.sharedFonts.notice)
    check(notice.copy:IsEnabled(),'published collection link enables copy on both clients')
    notice.copy.scripts.OnClick()
    check(addon.developerLinks.sharedFonts.url=='https://www.curseforge.com/wow/addons/antrakt-fonts',
        'actual generated catalogue hands off the exact published CurseForge project')
    local popup=env.__staticPopups[addon.developerLinks.popupKey]
    check(popup and popup:IsVisible(),'published collection link opens the real copy dialog')
    check(env.StatsProDB.account.sharedFontsNotice=='acknowledged','successful published-link handoff acknowledges once')
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
    local noticeClose=host.sharedFonts.notice.x
    check(noticeClose.statsProModernClose==true,'font information uses the unclipped window close control')
    check(noticeClose.statsProCloseText:GetText()=='×' and noticeClose.statsProCloseText:GetPoint()=='CENTER',
        'close glyph is naturally centered without narrow shell-label insets')
    check(not noticeClose.statsProText and not noticeClose.statsProTooltipProvider,
        'close glyph never relies on a truncated-label tooltip')
    noticeClose.scripts.OnEnter(noticeClose)
    check(noticeClose.statsProCloseHover:IsShown() and noticeClose.statsProCloseText:GetText()=='×',
        'hover highlights the existing close glyph instead of revealing a label')
    noticeClose.scripts.OnLeave(noticeClose)
    check(not noticeClose.statsProCloseHover:IsShown() and noticeClose.statsProCloseText:GetText()=='×',
        'leaving retains the same close glyph without hover background')
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
    host.sharedFonts.notice.x.scripts.OnClick()
    check(not host.sharedFonts.notice:IsVisible(),'window close glyph dismisses font information')
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
-- Existing users receive one shared explanation even when the provider is ready.
local function readyProvider()
    return {GetCatalog=function()
        return {formatMajor=1,catalogRevision=string.rep('a',64),fonts=clone(snapshot.fonts)}
    end}
end
for _,forever in ipairs({false,true}) do
    local env,host,test=fixtures.loadStatsPro('enUS',{
        forever=forever,statsProDB={fontSize=14},sharedProvider=readyProvider(),testSharedFontsNotice=true,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD');env.__flushTimers(.6)
    check(host.sharedFonts.notice and host.sharedFonts.notice:IsVisible(),'existing account receives the ready-provider migration explanation')
    check(env.StatsProDB.account.sharedFontsNotice==nil,'ready display does not fabricate acknowledgement')
    check(host.sharedFonts.notice.body:GetText()==host.sharedFonts.Message('enUS','ready'),'ready popup explains the installed shared package')
    check(not host.sharedFonts.notice.copy:IsShown() and not host.sharedFonts.notice.copy:IsEnabled(),'ready popup has no download or activation action')
    check(test.validateRegistry(env.StatsProDB),'pending ready metadata remains a valid registry')
    local peerShown,peerAcknowledged=false,false
    host.sharedFonts.coordinator:Register('PendingPeer',{
        state=nil,canShow=function() return true end,show=function() peerShown=true;return true end,
        acknowledge=function() peerAcknowledged=true;return true end,dismiss=function() peerShown=false end,
    })
    host.sharedFonts.coordinator:RequestShow()
    check(not peerShown and not peerAcknowledged,'ready explanation retains one host without premature peer acknowledgement')
    host.sharedFonts.notice.close.scripts.OnClick()
    check(env.StatsProDB.account.sharedFontsNotice=='acknowledged' and peerAcknowledged,'one explicit close acknowledges all pending peers')
    local originalLinks=host.sharedFonts.snapshot.links
    host.sharedFonts.snapshot.links={github='https://example.org/fonts'}
    check(not host.sharedFonts.CopyLink(),'even a valid URL cannot reopen a ready-provider download action')
    host.sharedFonts.snapshot.links=originalLinks
    local saved=clone(env.StatsProDB)
    local reloaded,reloadedHost,reloadedTest=fixtures.loadStatsPro('enUS',{
        forever=forever,statsProDB=clone(saved),sharedProvider=readyProvider(),testSharedFontsNotice=true,
        unitGUID=function() return 'Player-1-READY-POLICY' end, specIndex=1,specID=73,specName='Protection',specRole='TANK',primaryStat=1,
    })
    reloaded.__fireEvent('PLAYER_ENTERING_WORLD');reloaded.__flushTimers(.6)
    check(reloaded.StatsProDB.account.sharedFontsNotice=='acknowledged','explicit acknowledgement survives a ready-provider reload')
    check(not reloadedHost.sharedFonts.notice,'reload does not build an acknowledged migration window')
    local removed,removedHost,removedTest=fixtures.loadStatsPro('enUS',{
        forever=forever,statsProDB=clone(saved),testSharedFontsNotice=true,
    })
    removed.__fireEvent('PLAYER_ENTERING_WORLD');removed.__flushTimers(.6)
    check(removed.StatsProDB.account.sharedFontsNotice=='acknowledged' and not removedHost.sharedFonts.notice,'later provider removal does not reopen a resolved campaign')
    removedHost:OpenConfigMenu()
    check(removedHost.sharedFonts.marker:IsShown() and removedHost.sharedFonts.marker.statsProSharedFontText~=nil,'later removal retains Font settings guidance')
    removedHost.sharedFonts.marker.scripts.OnClick()
    check(removedHost.sharedFonts.notice:IsVisible(),'acknowledged account may manually open collection details')
    removedHost.sharedFonts.notice.close.scripts.OnClick()
    check(removed.StatsProDB.account.sharedFontsNotice=='acknowledged','explicit manual close may acknowledge a satisfied account')
    local state=reloadedTest.profileState()
    check(reloadedTest.profileOps.resetProfile(state.profileID),'ordinary profile reset succeeds')
    check(reloaded.StatsProDB.account.sharedFontsNotice=='acknowledged','profile reset preserves acknowledgement')
    check(reloadedTest.appearancePresets.startPreview('high-contrast'),'appearance preset preview starts')
    check(reloadedTest.appearancePresets.applyPreview(),'appearance preset applies')
    check(reloadedTest.appearancePresets.startPreview('default'),'appearance reset preview starts')
    check(reloadedTest.appearancePresets.applyPreview(),'appearance reset applies')
    check(reloaded.StatsProDB.account.sharedFontsNotice=='acknowledged','appearance reset preserves acknowledgement')
    local stripped={sharedFontsNotice='satisfied',fontSize=14}
    check(reloadedHost.dbRuntime.StripAccountSettings(stripped) and stripped.sharedFontsNotice==nil,'profile import excludes campaign metadata')
    local text=reloadedTest.profileTransfer.serialize('Ready profile',reloadedTest.profileState().settings,{appearance=true,layout=true,stats=true})
    local transferred=reloadedTest.profileTransfer.parse(text)
    check(transferred and transferred.values.sharedFontsNotice==nil,'profile export excludes campaign metadata')
    local context=reloadedTest.profileRuntimeState()
    check(reloadedTest.profileOps.importTransferToContext(transferred,transferred.sections,context.activeGUID,context.activeSpecID),'ordinary profile import succeeds')
    check(reloaded.StatsProDB.account.sharedFontsNotice=='acknowledged','profile import preserves account acknowledgement')
    for _,prior in ipairs({'fresh','acknowledged'}) do
        local db=clone(saved);db.account.sharedFontsNotice=prior
        local keep,keepHost=fixtures.loadStatsPro('enUS',{forever=forever,statsProDB=db,sharedProvider=readyProvider(),testSharedFontsNotice=true})
        keep.__fireEvent('PLAYER_ENTERING_WORLD');keep.__flushTimers(.6)
        check(keep.StatsProDB.account.sharedFontsNotice==prior and not keepHost.sharedFonts.notice,'ready provider preserves existing '..prior..' campaign state')
    end
    local late,lateHost=fixtures.loadStatsPro('enUS',{forever=forever,statsProDB={fontSize=14},testSharedFontsNotice=true})
    late.__fireEvent('PLAYER_ENTERING_WORLD');late.__flushTimers(.6)
    check(lateHost.sharedFonts.notice:IsVisible(),'not-ready pending account shows its one automatic notice')
    late.AntraktFonts=readyProvider();lateHost.fontRuntime.RefreshSharedCatalog(true)
    check(lateHost.sharedFonts.notice:IsVisible(),'late ready provider preserves the unacknowledged explanation')
    check(lateHost.sharedFonts.notice.body:GetText()==lateHost.sharedFonts.Message('enUS','ready')
        and not lateHost.sharedFonts.notice.copy:IsShown(),'late provider refreshes the explanation and removes the stale download action')
    check(late.StatsProDB.account.sharedFontsNotice==nil,'late provider arrival never acknowledges the campaign')
    local oldDB=clone(saved);oldDB.account.sharedFontsNotice='satisfied'
    local legacy,legacyHost=fixtures.loadStatsPro('enUS',{forever=forever,statsProDB=oldDB,sharedProvider=readyProvider(),testSharedFontsNotice=true})
    legacy.__fireEvent('PLAYER_ENTERING_WORLD');legacy.__flushTimers(.6)
    check(legacyHost.sharedFonts.notice:IsVisible() and legacy.StatsProDB.account.sharedFontsNotice=='satisfied','legacy automatic resolution still needs one real explanation')
    legacyHost.sharedFonts.notice.close.scripts.OnClick()
    check(legacy.StatsProDB.account.sharedFontsNotice=='acknowledged','legacy resolution persists only an explicit acknowledgement')
    local denied,deniedHost=fixtures.loadStatsPro('enUS',{forever=forever,statsProDB={fontSize=14},sharedProvider=readyProvider(),testSharedFontsNotice=true})
    denied.__fireEvent('PLAYER_ENTERING_WORLD');denied.__flushTimers(.6)
    local original=deniedHost.dbRuntime.GetWritableRoot
    deniedHost.dbRuntime.GetWritableRoot=function() return nil end
    deniedHost.sharedFonts.notice.close.scripts.OnClick()
    check(denied.StatsProDB.account.sharedFontsNotice==nil,'failed acknowledgement persistence does not fabricate saved success')
    deniedHost.dbRuntime.GetWritableRoot=original
    deniedHost.sharedFonts.RequestNotice()
    check(denied.StatsProDB.account.sharedFontsNotice=='acknowledged' and not deniedHost.sharedFonts.notice:IsVisible(),'later safe lifecycle retries acknowledgement without another popup')
    local failed,failedHost=fixtures.loadStatsPro('enUS',{
        forever=forever,statsProDB={font='Interface\\AddOns\\StatsPro\\fonts\\PT_Sans-Web-Regular.ttf'},
        sharedProvider=readyProvider(),testSharedFontsNotice=true,
        isKnownFontFile=function(path) return not path:lower():find('pt_sans',1,true) end,
        setFontResult=function(_,path) return not path:lower():find('pt_sans',1,true) end,
    })
    failed.__fireEvent('PLAYER_ENTERING_WORLD');failed.__flushTimers(.6)
    check(failedHost.sharedFonts.notice.body:GetText():find(failedHost.sharedFonts.Message('enUS','assetUnavailable'),1,true),
        'a rejected selected asset keeps truthful repair guidance instead of a ready success message')
    check(not failedHost.sharedFonts.notice.copy:IsShown(),'an installed collection asset error does not offer a duplicate download')
    local bad,badHost=fixtures.loadStatsPro('ruRU',{forever=forever,statsProDB={fontSize=14},sharedProvider={GetCatalog=function()return {formatMajor=2}end},testSharedFontsNotice=true})
    bad.__fireEvent('PLAYER_ENTERING_WORLD');bad.__flushTimers(.6)
    check(badHost.sharedFonts.notice.body:GetText()==badHost.sharedFonts.Message('ruRU','incompatible'),'incompatible automatic notice uses its translated explanation')
    local readonly,readonlyHost,readonlyTest=fixtures.loadStatsPro('enUS',{forever=forever,testSharedFontsNotice=true})
    readonly.__fireEvent('PLAYER_ENTERING_WORLD');readonly.__flushTimers(.6);readonlyHost:OpenConfigMenu()
    local before=clone(readonly.StatsProDB)
    readonlyHost.dbRuntime.GetWritableRoot=function() return nil end
    readonlyHost.sharedFonts.marker.scripts.OnClick()
    check(readonlyHost.sharedFonts.notice and readonlyHost.sharedFonts.notice:IsVisible(),'read-only database still permits manual font information')
    readonlyHost.sharedFonts.notice.close.scripts.OnClick()
    check(readonly.StatsProDB.account.sharedFontsNotice==before.account.sharedFontsNotice,'read-only manual acknowledgement never writes account metadata')
    check(not readonlyTest.profileState().settings.sharedFontsNotice,'read-only information never writes profile metadata')
    local futureDB=clone(saved);futureDB.dbVersion=futureDB.dbVersion+100
    local futureBefore=clone(futureDB)
    local future,futureHost,futureTest=fixtures.loadStatsPro('enUS',{forever=forever,statsProDB=futureDB,testSharedFontsNotice=true})
    future.__fireEvent('PLAYER_ENTERING_WORLD');future.__flushTimers(.6)
    check(futureTest.dbCompatibilityState().readOnly,'actual future schema enters compatibility mode')
    check(not futureHost.sharedFonts.notice,'future schema has no automatic migration popup')
    futureHost:OpenConfigMenu()
    check(futureHost.sharedFonts.marker:IsEnabled(),'manual info marker remains enabled in future-schema mode')
    futureHost.sharedFonts.marker.scripts.OnClick()
    check(futureHost.sharedFonts.notice and futureHost.sharedFonts.notice:IsVisible(),'future-schema mode permits actual manual information')
    futureHost.sharedFonts.notice.close.scripts.OnClick()
    check(equal(future.StatsProDB,futureBefore),'future-schema information and close preserve every saved byte/value')
end
for _,forever in ipairs({false,true}) do
    for _,case in ipairs({
        {name='missing',exists=false,state=0,expected='provider-unavailable',key='settingsMissing'},
        {name='disabled',exists=true,state=0,expected='provider-disabled',key='disabled'},
        {name='enabled but not loaded',exists=true,state=2,expected='provider-not-loaded',key='notLoaded'},
        {name='still loading',exists=true,state=2,loading=true,loaded=false,expected='provider-not-loaded',key='notLoaded'},
        {name='incomplete modern load result',exists=true,state=2,partialLoaded=true,expected='provider-not-loaded',key='notLoaded'},
        {name='loaded with no catalogue',exists=true,state=2,loading=true,loaded=true,expected='provider-incompatible',key='incompatible'},
        {name='unknown existence',exists='error',state=0,expected='provider-not-loaded',key='notLoaded'},
        {name='restricted character',exists=true,state=0,unsafeGUID=true,expected='provider-not-loaded',key='notLoaded'},
        {name='failed current character',exists=true,state=0,failedGUID=true,expected='provider-not-loaded',key='notLoaded'},
        {name='failed enable query',exists=true,state='error',expected='provider-not-loaded',key='notLoaded'},
        {name='global some but current disabled',exists=true,state=0,expected='provider-disabled',key='disabled'},
    }) do
        local env,host=fixtures.loadStatsPro('enUS',{forever=forever,testSharedFontsNotice=true})
        local calls=0
        rawset(env,'UnitGUID',function()
            if case.failedGUID then error('guid query failed') end
            return case.unsafeGUID and {} or 'Player-FontStateFixture'
        end)
        rawset(env.C_AddOns,'DoesAddOnExist',function(name)
            calls=calls+1;check(name=='AntraktFonts','only the package identity is queried')
            if case.exists=='error' then error('existence query failed') end
            return case.exists
        end)
        rawset(env.C_AddOns,'GetAddOnEnableState',function(name,character)
            calls=calls+1
            check(name=='AntraktFonts' and character=='Player-FontStateFixture','enabled state uses the current character GUID')
            if case.state=='error' then error('enable query failed') end
            return case.state
        end)
        rawset(env.C_AddOns,'IsAddOnLoaded',function()
            calls=calls+1
            if case.partialLoaded then return true end
            return case.loading or false,case.loaded or false
        end)
        host.sharedFonts.Refresh()
        check(host.sharedFonts.status==case.expected,case.name..' has an honest package state')
        check(host.sharedFonts.Guidance()==host.sharedFonts.Message('enUS',case.key),case.name..' uses the matching settings instruction')
        if case.unsafeGUID or case.failedGUID then
            -- The profile UI also needs a usable identity; exercise the notice's
            -- renderer independently while the identity query is inconclusive.
            host.sharedFonts.ShowNotice(function() end,function() end)
        else
            env.__fireEvent('PLAYER_ENTERING_WORLD');env.__flushTimers(.6)
            host:OpenConfigMenu()
            host.sharedFonts.marker.scripts.OnClick()
        end
        local notice=assert(host.sharedFonts.notice,case.name..': manual information opens')
        local bodyKey=case.key=='settingsMissing' and 'missing' or case.key
        check(notice.body:GetText()==host.sharedFonts.Message('enUS',bodyKey),case.name..' uses the same state in the information window')
        if case.expected=='provider-not-loaded' then
            check(not notice.copy:IsShown(),case.name..' never asks for an unnecessary download')
        elseif case.expected=='provider-disabled' then
            check(notice.copy:IsShown() and notice.copy:GetText()==host.sharedFonts.Message('enUS','enable'),
                'disabled package offers enable instead of download')
        end
        local before=calls
        for _=1,10 do host.sharedFonts.UpdateGuidance();host:RunUpdateStatsSafe() end
        check(calls==before,'settings refresh and HUD work never poll installation metadata')
    end
end
for _,forever in ipairs({false,true}) do
    local env,host=fixtures.loadStatsPro('enUS',{forever=forever})
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    rawset(env,"UnitGUID",function() return 'Player-FontStateFixture' end)
    env.C_AddOns.DoesAddOnExist=nil
    rawset(env.C_AddOns,"GetNumAddOns",function() return 2 end)
    rawset(env.C_AddOns,'GetAddOnInfo',function(index)
        check(type(index)=='number','fallback existence enumerates instead of accepting echoed names')
        return index==1 and 'OtherMedia' or 'AntraktFonts'
    end)
    rawset(env,'GetAddOnEnableState',function(character,name)
        check(character=='Player-FontStateFixture' and name=='AntraktFonts','legacy enable query preserves shim argument order')
        return 0
    end)
    host.sharedFonts.Refresh()
    check(host.sharedFonts.status=='provider-disabled','bounded indexed discovery supports missing modern existence API')
    rawset(env.C_AddOns,"GetNumAddOns",function() return 2000 end)
    host.sharedFonts.Refresh()
    check(host.sharedFonts.status=='provider-not-loaded','oversized addon discovery fails closed')
    env.C_AddOns.GetNumAddOns=nil
    rawset(env.C_AddOns,"GetAddOnInfo",function(name) return name end)
    host.sharedFonts.Refresh()
    check(host.sharedFonts.status=='provider-not-loaded','an echoed missing name never proves installation')
    rawset(env.C_AddOns,"DoesAddOnExist",function() return true end)
    rawset(env.C_AddOns,"GetAddOnEnableState",function() error('modern query failed') end)
    rawset(env,"GetAddOnEnableState",function() error('legacy fallback must not override an existing modern method') end)
    host.sharedFonts.Refresh()
    check(host.sharedFonts.status=='provider-not-loaded','a failed modern query is not replaced by conflicting legacy evidence')
    rawset(env.C_AddOns,"GetAddOnEnableState",function() return 0 end)
    local secretGUID='Player-RestrictedFontState'
    rawset(env,"UnitGUID",function() return secretGUID end)
    rawset(env,"issecretvalue",function(value) return value==secretGUID end)
    host.sharedFonts.Refresh()
    check(host.sharedFonts.status=='provider-not-loaded','restricted current character never becomes disabled evidence')
    rawset(env,"issecretvalue",function() return false end)
    rawset(env,"UnitGUID",function() return 'Player-FontStateFixture' end)
    host:OpenConfigMenu()
    check(host.sharedFonts.status=='provider-disabled','opening Settings refreshes an existing disabled package')
    host:OpenConfigMenu()
    rawset(env.C_AddOns,"DoesAddOnExist",function() return false end)
    host:OpenConfigMenu()
    check(host.sharedFonts.status=='provider-unavailable','opening Settings refreshes an absent package without changing provider identity')
    local cached=host.settingsUI.fontPicker.BuildFontsList(host)
    local calls=0
    local added=clone(snapshot.fonts[1])
    added.id,added.name,added.file='late-face','Late Face','Late.ttf'
    added.path='Interface\\AddOns\\AntraktFonts\\fonts\\Late.ttf'
    local fonts=clone(snapshot.fonts);fonts[#fonts+1]=added
    env.AntraktFonts={GetCatalog=function() calls=calls+1;return {formatMajor=1,catalogRevision=string.rep('b',64),fonts=fonts} end}
    host:OpenConfigMenu();host:OpenConfigMenu()
    check(host.sharedFonts.status=='available','a valid late provider wins over contradictory installation metadata')
    local refreshed=host.settingsUI.fontPicker.BuildFontsList(host)
    check(refreshed~=cached,'late provider invalidates cached picker independently of LSM registration callbacks')
    check(calls==1,'Settings reuse a compatible catalogue without repeated GetCatalog clones')
    rawset(env,'C_AddOns',123)
    rawset(env,"DoesAddOnExist",function() return false end)
    check(host.sharedFonts.InstallationStatus()=='provider-not-loaded','an invalid modern namespace never falls through to conflicting legacy metadata')
end
for _,forever in ipairs({false,true}) do
    local preferred=snapshot.fonts[1].path
    local env,host,test=fixtures.loadStatsPro('enUS',{
        forever=forever,statsProDB={font=preferred},isKnownFontFile=function() return true end,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    rawset(env,"UnitGUID",function() return 'Player-FontStateFixture' end)
    rawset(env.C_AddOns,"DoesAddOnExist",function() return true end)
    rawset(env.C_AddOns,"GetAddOnEnableState",function() return 0 end)
    host.sharedFonts.Refresh()
    check(host.sharedFonts.status=='provider-disabled','disabled package is distinguished even with directly readable assets')
    check(host.fontRuntime.usablePath(preferred)==preferred,'disabled package never blocks a directly usable selected file')
    check(test.profileState().settings.font==preferred,'installation guidance never rewrites the saved selected path')
    check(host.sharedFonts.Guidance()==host.sharedFonts.Message('enUS','disabled'),'working selected face gets only the accurate enable hint')
    rawset(env,"issecretvalue",function(value) return value==true end)
    check(host.sharedFonts.InstallationStatus()=='provider-not-loaded','restricted existence booleans are not installation proof')
    rawset(env,"issecretvalue",function(value) return value==0 end)
    check(host.sharedFonts.InstallationStatus()=='provider-not-loaded','restricted enable values are not disablement proof')
end
for _,forever in ipairs({false,true}) do
    local env,host=fixtures.loadStatsPro('enUS',{forever=forever,isKnownFontFile=function() return true end})
    env.__fireEvent('PLAYER_ENTERING_WORLD');env.__flushTimers(.6)
    host:OpenConfigMenu()
    local previous=host.settingsUI.fontPicker.BuildFontsList(host)
    local calls=0
    env.AntraktFonts={GetCatalog=function()
        calls=calls+1
        return {formatMajor=1,catalogRevision=string.rep('c',64),fonts=clone(snapshot.fonts)}
    end}
    env.__fireEvent('ADDON_LOADED','OtherAddon')
    check(calls==0,'unrelated addon loads do not discover the font provider')
    env.__fireEvent('ADDON_LOADED','AntraktFonts')
    check(calls==0,'provider loading event only marks coalesced work')
    host:RunUpdateStatsSafe()
    check(host.sharedFonts.status=='available','provider event refreshes an already open Settings window without LSM callbacks')
    check(not host.sharedFonts.marker:IsShown(),'late compatible provider removes the install marker immediately on the safe tick')
    check(host.settingsUI.fontPicker.BuildFontsList(host)~=previous,'provider event invalidates an already built picker')
    for _=1,10 do host:RunUpdateStatsSafe() end
    check(calls==1,'one load event never causes catalogue polling on later HUD ticks')
end
for _,forever in ipairs({false,true}) do
    for _,case in ipairs({'reload','enable-error','enable-ignored','save-error','missing-save',
        'missing-enable','modern-invalid','combat','unknown-combat','addon-list','unknown-list','missing',
        'unsafe-guid','legacy','combat-during-query','save-disables','save-combat','reload-error','missing-reload'}) do
        local combat=false
        local env,host,test=fixtures.loadStatsPro('enUS',{
            forever=forever,testSharedFontsNotice=true,statsProDB={fontSize=14},
            inCombatLockdown=function() return combat end,
        })
        env.__fireEvent('PLAYER_ENTERING_WORLD');env.__flushTimers(.6)
        local before=clone(test.profileState().settings)
        local enabled,enableCalls,saveCalls,loadCalls,reloadCalls=0,0,0,0,0
        local armed=false
        rawset(env,'UnitGUID',function() return case=='unsafe-guid' and {} or 'Player-EnableFontFixture' end)
        rawset(env.C_AddOns,'DoesAddOnExist',function() return case~='missing' end)
        rawset(env.C_AddOns,'IsAddOnLoaded',function() return false,false end)
        local function enable(name,guid)
            check(name=='AntraktFonts' and guid=='Player-EnableFontFixture','enable changes only this package for the current character')
            enableCalls=enableCalls+1
            if case=='enable-error' then error('enable failed') end
            if case~='enable-ignored' then enabled=2 end
        end
        local function state(name,guid)
            check(name=='AntraktFonts' and guid=='Player-EnableFontFixture','enable result is checked for the same character')
            if armed and case=='combat-during-query' then combat=true end
            return enabled
        end
        rawset(env.C_AddOns,'GetAddOnEnableState',state)
        rawset(env.C_AddOns,'EnableAddOn',enable)
        rawset(env.C_AddOns,'SaveAddOns',function(...)
            check(select('#',...)==0,'save receives no expanded method-selection return')
            saveCalls=saveCalls+1
            if case=='save-error' then error('save failed') end
            if case=='save-disables' then enabled=0 end
            if case=='save-combat' then combat=true end
        end)
        rawset(env.C_AddOns,'LoadAddOn',function() loadCalls=loadCalls+1;error('ordinary collection requires reload') end)
        rawset(env,'ReloadUI',function()
            if case=='reload-error' then error('reload failed') end
            reloadCalls=reloadCalls+1
        end)
        if case=='legacy' then
            env.C_AddOns.EnableAddOn=nil;rawset(env,'EnableAddOn',enable)
            env.C_AddOns.GetAddOnEnableState=nil
            rawset(env,'GetAddOnEnableState',function(guid,name) return state(name,guid) end)
        elseif case=='missing-save' then env.C_AddOns.SaveAddOns=nil
        elseif case=='missing-reload' then env.ReloadUI=nil
        elseif case=='missing-enable' then env.C_AddOns.EnableAddOn=nil
        elseif case=='modern-invalid' then
            rawset(env.C_AddOns,'EnableAddOn',false)
            rawset(env,'EnableAddOn',function() error('invalid modern method must not fall through') end)
        elseif case=='combat' then combat=true
        elseif case=='unknown-combat' then host.profileRuntime.ReadCombatState=function() return nil end
        elseif case=='addon-list' then rawset(env,'AddonList',{IsShown=function() return true end})
        elseif case=='unknown-list' then rawset(env,'AddonList',{}) end
        host.sharedFonts.Refresh()
        host.sharedFonts.ShowNotice(function() end,function() end)
        local notice=host.sharedFonts.notice
        -- Call the saved enable callback even if an external state change hides it.
        notice.action='enable'
        if case~='missing' and case~='unsafe-guid' then
            notice:Hide();notice.copy.scripts.OnClick()
            check(enableCalls==0 and saveCalls==0,'hidden notice cannot enable a package through its saved handler')
            notice:Show()
        end
        armed=true;notice.copy.scripts.OnClick()
        check(reloadCalls==((case=='reload' or case=='legacy') and 1 or 0),'only a successful explicit enable click reloads immediately')
        check(equal(before,test.profileState().settings),'enable never rewrites font/profile settings')
        if case=='reload' or case=='legacy' then
            check(enabled==2 and notice.action=='reload','if a mock reload returns, recovery still describes the enabled state')
            check(notice.body:GetText()==host.sharedFonts.Message('enUS','reloadRequired'),'reload has localized truthful guidance')
            check(saveCalls==1,'explicit enable saves one successful transaction')
            check(loadCalls==0,'non-demand or unknown packages never use a live load')
            notice:Hide();notice.copy.scripts.OnClick();check(reloadCalls==1,'hidden notice cannot reload through its saved handler')
            notice:Show()
            combat=true;notice.copy.scripts.OnClick();check(reloadCalls==1,'combat blocks an existing reload button')
            combat=false
            rawset(env.C_AddOns,'GetAddOnEnableState',function() combat=true;return enabled end)
            local saved=saveCalls
            notice.copy.scripts.OnClick()
            check(reloadCalls==1 and saveCalls==saved,'combat changed during reload discovery blocks save and reload')
            if case=='legacy' then env.C_AddOns.GetAddOnEnableState=nil
            else rawset(env.C_AddOns,'GetAddOnEnableState',state) end
            combat=false;notice.copy.scripts.OnClick();check(reloadCalls==2,'a recovery reload still validates before acting')
            rawset(env.C_AddOns,'SaveAddOns',function() enabled=0 end)
            notice.copy.scripts.OnClick()
            check(reloadCalls==2,'a changed enable state during save blocks the reload')
            enabled=2
            rawset(env.C_AddOns,'SaveAddOns',function() combat=true end)
            notice.copy.scripts.OnClick()
            check(reloadCalls==2,'combat entered during save blocks the reload')
            combat=false
            enabled=0;notice.copy.scripts.OnClick();check(reloadCalls==2,'stale reload cannot reload a disabled package')
        elseif case=='save-error' then
            check(enabled==2 and saveCalls==1 and loadCalls==0 and notice.action~='reload','failed save never loads or claims reload readiness')
        elseif case=='save-disables' or case=='save-combat' or case=='reload-error' then
            check(saveCalls==1 and loadCalls==0 and reloadCalls==0,'state changed during saving or reload failure never produces a successful reload')
        else
            check(enabled==0 and saveCalls==0 and loadCalls==0,'blocked or failed enable has no save/load effects: '..case)
        end
    end
end
print('Shared fonts: ' .. checks .. ' checks passed')
