-- Optional font faces shared by both client flavors. Their own licenses apply.
local _, addon = ...
addon.bundledFonts = {
    { name = "DejaVu Sans", file = "DejaVuSans.ttf", cyrillic = true },
    { name = "DejaVu Serif", file = "DejaVuSerif.ttf", cyrillic = true },
    { name = "Gentium", file = "Gentium-Regular.ttf", cyrillic = true },
    { name = "Hack", file = "Hack-Regular.ttf", cyrillic = true },
    { name = "Liberation Mono", file = "LiberationMono-Regular.ttf", cyrillic = true },
    { name = "Liberation Sans", file = "LiberationSans-Regular.ttf", cyrillic = true },
    { name = "Liberation Serif", file = "LiberationSerif-Regular.ttf", cyrillic = true },
    { name = "Noto Sans", file = "NotoSans-Regular.ttf", cyrillic = true },
    { name = "Oswald", file = "Oswald-Regular.ttf", cyrillic = true },
    { name = "Roboto Condensed", file = "RobotoCondensed-Regular.ttf", cyrillic = true },
    { name = "TeX Gyre Adventor", file = "texgyreadventor-regular.otf", cyrillic = false },
    { name = "TeX Gyre Adventor Bold", file = "texgyreadventor-bold.otf", cyrillic = false },
    { name = "PT Sans", file = "PT_Sans-Web-Regular.ttf", cyrillic = true },
    { name = "PT Sans Bold", file = "PT_Sans-Web-Bold.ttf", cyrillic = true },
    { name = "PT Sans Narrow", file = "PT_Sans-Narrow-Web-Regular.ttf", cyrillic = true },
    { name = "PT Sans Narrow Bold", file = "PT_Sans-Narrow-Web-Bold.ttf", cyrillic = true },
    { name = "PT Serif", file = "PT_Serif-Web-Regular.ttf", cyrillic = true },
    { name = "PT Serif Bold", file = "PT_Serif-Web-Bold.ttf", cyrillic = true },
    { name = "Fira Sans", file = "FiraSans-Regular.ttf", cyrillic = true },
    { name = "Fira Sans Bold", file = "FiraSans-Bold.ttf", cyrillic = true },
    { name = "Fira Mono", file = "FiraMono-Regular.ttf", cyrillic = true },
    { name = "Fira Sans Condensed", file = "FiraSansCondensed-Regular.ttf", cyrillic = true },
    { name = "Fira Sans Condensed Bold", file = "FiraSansCondensed-Bold.ttf", cyrillic = true },
    { name = "PT Mono", file = "PTM55FT.ttf", cyrillic = true },
    { name = "Audiowide", file = "Audiowide-Regular.ttf", cyrillic = false },
    { name = "Black Ops One", file = "BlackOpsOne-Regular.ttf", cyrillic = false },
    { name = "Bangers", file = "Bangers-Regular.ttf", cyrillic = false },
    { name = "Special Elite", file = "SpecialElite-Regular.ttf", cyrillic = false },
    { name = "Russo One", file = "RussoOne-Regular.ttf", latin = true, cyrillic = true, hans = false, hant = false, hangul = false, japanese = false },
    { name = "Ruslan Display", file = "RuslanDisplay-Regular.ttf", latin = true, cyrillic = true, hans = false, hant = false, hangul = false, japanese = false },
    { name = "Rubik Mono One", file = "RubikMonoOne-Regular.ttf", latin = true, cyrillic = true, hans = false, hant = false, hangul = false, japanese = false },
    { name = "Marmelad", file = "Marmelad-Regular.ttf", latin = true, cyrillic = true, hans = false, hant = false, hangul = false, japanese = false },
    { name = "Philosopher", file = "Philosopher-Regular.ttf", latin = true, cyrillic = true, hans = false, hant = false, hangul = false, japanese = false },
    { name = "Lobster", file = "Lobster-Regular.ttf", latin = true, cyrillic = true, hans = false, hant = false, hangul = false, japanese = false },
    { name = "Bad Script", file = "BadScript-Regular.ttf", latin = true, cyrillic = true, hans = false, hant = false, hangul = false, japanese = false },
    { name = "Neucha", file = "Neucha.ttf", latin = false, cyrillic = true, hans = false, hant = false, hangul = false, japanese = false },
    { name = "Old Standard TT", file = "OldStandard-Regular.ttf", latin = true, cyrillic = true, hans = false, hant = false, hangul = false, japanese = false },
    { name = "Press Start 2P", file = "PressStart2P-Regular.ttf", latin = true, cyrillic = true, hans = false, hant = false, hangul = false, japanese = false },
    { name = "Kosugi Maru", file = "KosugiMaru-Regular.ttf", latin = false, cyrillic = true, hans = false, hant = false, hangul = false, japanese = true },
    { name = "Sawarabi Mincho", file = "SawarabiMincho-Regular.ttf", latin = true, cyrillic = false, hans = false, hant = false, hangul = false, japanese = true },
    { name = "Do Hyeon", file = "DoHyeon-Regular.ttf", latin = false, cyrillic = false, hans = false, hant = false, hangul = true, japanese = false },
    { name = "Nanum Pen Script", file = "NanumPenScript-Regular.ttf", latin = false, cyrillic = false, hans = false, hant = false, hangul = true, japanese = false },
    { name = "Ma Shan Zheng", file = "MaShanZheng-Regular.ttf", latin = false, cyrillic = false, hans = true, hant = false, hangul = false, japanese = false },
    { name = "ZCOOL XiaoWei", file = "ZCOOLXiaoWei-Regular.ttf", latin = false, cyrillic = false, hans = true, hant = false, hangul = false, japanese = false },
    { name = "Source Han Sans CN", file = "SourceHanSansCN-Regular.otf", latin = true, cyrillic = true, hans = true, hant = true, hangul = false, japanese = true },
    { name = "Source Han Sans TW", file = "SourceHanSansTW-Regular.otf", latin = true, cyrillic = true, hans = false, hant = true, hangul = false, japanese = true },
    { name = "Source Han Serif CN", file = "SourceHanSerifCN-Regular.otf", latin = true, cyrillic = true, hans = true, hant = true, hangul = false, japanese = true },
    { name = "Source Han Serif TW", file = "SourceHanSerifTW-Regular.otf", latin = true, cyrillic = true, hans = false, hant = true, hangul = false, japanese = true },
}

local media = LibStub and LibStub("LibSharedMedia-3.0", true)
for _, font in ipairs(addon.bundledFonts) do
    font.path = "Interface\\AddOns\\StatsPro\\fonts\\" .. font.file
    if media and type(media.Register) == "function" then
        local mask = font.latin ~= false and media.LOCALE_BIT_western or 0
        if font.cyrillic and mask and media.LOCALE_BIT_ruRU then
            mask = mask + media.LOCALE_BIT_ruRU
        end
        if font.hans and media.LOCALE_BIT_zhCN then mask = mask + media.LOCALE_BIT_zhCN end
        if font.hant and media.LOCALE_BIT_zhTW then mask = mask + media.LOCALE_BIT_zhTW end
        if font.hangul and media.LOCALE_BIT_koKR then mask = mask + media.LOCALE_BIT_koKR end
        -- Register preserves a previously registered face with the same name.
        media:Register(media.MediaType.FONT, font.name, font.path, mask)
    end
end
