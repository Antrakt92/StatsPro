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
}

local media = LibStub and LibStub("LibSharedMedia-3.0", true)
for _, font in ipairs(addon.bundledFonts) do
    font.path = "Interface\\AddOns\\StatsPro\\fonts\\" .. font.file
    if media and type(media.Register) == "function" then
        local mask = media.LOCALE_BIT_western
        if font.cyrillic and mask and media.LOCALE_BIT_ruRU then
            mask = mask + media.LOCALE_BIT_ruRU
        end
        -- Register preserves a previously registered face with the same name.
        media:Register(media.MediaType.FONT, font.name, font.path, mask)
    end
end
