-- StatsPro's Forever stat sources. Composite values require clean inputs.
local _, addon = ...
local F = { rows = { character = {}, offensive = {}, defensive = {}, utility = {} }, defaults = {}, presets = {} }
addon.forever = F
local buildOK, _, _, _, interface = pcall(GetBuildInfo)
F.enabled = buildOK and interface == 16001 and WOW_PROJECT_ID == 18
F.capabilities = { itemLevel = type(GetAverageItemLevel) == "function", repair = true, archon = false }

local function Classify(value)
    if type(issecretvalue) ~= "function" then return nil, "unknown" end
    local ok, secret = pcall(issecretvalue, value)
    if not ok or type(secret) ~= "boolean" then return nil, "unknown" end
    if secret then return value, "secret" end
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        return nil, "unknown"
    end
    return value, "clean"
end

local function Read(name, index, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil, "unknown" end
    local values = { pcall(fn, ...) }
    if not values[1] then return nil, "unknown" end
    return Classify(values[index + 1])
end

local function Scalar(name, index, ...)
    local args = { ... }
    return function() return Read(name, index, unpack(args)) end
end

local function Sum(name, count, ...)
    local args = { ... }
    return function()
        local fn = _G[name]
        if type(fn) ~= "function" then return nil, "unknown" end
        local values = { pcall(fn, unpack(args)) }
        if not values[1] then return nil, "unknown" end
        local total = 0
        for index = 1, count do
            local value, state = Classify(values[index + 1])
            if state ~= "clean" then return nil, "unknown" end
            total = total + value
        end
        return Classify(total)
    end
end

local function Hit(constant, modifier)
    return function()
        local rating = _G[constant]
        if type(rating) ~= "number" then return nil, "unknown" end
        local bonus, bonusState = Read("GetCombatRatingBonus", 1, rating)
        local extra, extraState = Read(modifier, 1)
        if bonusState ~= "clean" or extraState ~= "clean" then return nil, "unknown" end
        return Classify(bonus + extra)
    end
end

local function Nonnegative(reader)
    return function()
        local value, state = reader()
        if state ~= "clean" then return nil, "unknown" end
        -- Match the client's effective AP and defense display after debuffs.
        return math.max(0, value), "clean"
    end
end

local function Scale(reader, factor)
    return function()
        local value, state = reader()
        if state ~= "clean" then return nil, "unknown" end
        return Classify(value * factor)
    end
end

local function Resistance(school)
    return function()
        local enum = _G.Enum
        local index = enum and enum.Damageclass and enum.Damageclass[school]
        if type(index) ~= "number" then return nil, "unknown" end
        return Read("UnitResistance", 3, "player", index)
    end
end

local function Row(group, key, label, reader, kind, color)
    local row = { key = key, label = label, showKey = "show" .. key,
        kind = kind or "number", colorKey = color or "mainStat", Read = reader }
    F.rows[group][#F.rows[group] + 1] = row
    F.defaults[row.showKey] = false
end

for index, name in ipairs({ "Strength", "Agility", "Stamina", "Intellect", "Spirit" }) do
    Row("character", name, name, Scalar("UnitStat", 2, "player", index), "number", name == "Stamina" and "stamina" or "mainStat")
end
Row("offensive", "MeleeCrit", "Melee Crit", Scalar("GetCritChance", 1), "percent", "crit")
Row("offensive", "RangedCrit", "Ranged Crit", Scalar("GetRangedCritChance", 1), "percent", "crit")
Row("offensive", "SpellCrit", "Spell Crit", Scalar("GetSpellCritChance", 1), "percent", "crit")
Row("offensive", "MeleeHit", "Melee Hit", Hit("CR_HIT_MELEE", "GetHitModifier"), "percent")
Row("offensive", "RangedHit", "Ranged Hit", Hit("CR_HIT_RANGED", "GetRangedHitModifier"), "percent")
Row("offensive", "SpellHit", "Spell Hit", Hit("CR_HIT_SPELL", "GetSpellHitModifier"), "percent")
Row("offensive", "MeleeHaste", "Melee Haste", Scalar("GetMeleeHaste", 1), "percent", "haste")
Row("offensive", "RangedHaste", "Ranged Haste", Sum("GetRangedHaste", 2), "percent", "haste")
Row("offensive", "SpellHaste", "Spell Haste", Scalar("UnitSpellHaste", 1, "player"), "percent", "haste")
Row("offensive", "AttackPower", "Attack Power", Nonnegative(Sum("UnitAttackPower", 3, "player")))
Row("offensive", "RangedAttackPower", "Ranged Attack Power", Nonnegative(Sum("UnitRangedAttackPower", 3, "player")))
for school, name in ipairs({ "Holy", "Fire", "Nature", "Frost", "Shadow", "Arcane" }) do
    Row("offensive", "SpellPower" .. name, name .. " Spell Power", Scalar("GetSpellBonusDamage", 1, school + 1))
end
Row("offensive", "HealingPower", "Healing Power", Scalar("GetSpellBonusHealing", 1))
Row("offensive", "SpellPenetration", "Spell Penetration", Scalar("GetSpellPenetration", 1))
Row("offensive", "ArmorPenetration", "Armor Penetration", Scalar("GetArmorPenetration", 1))
for index, name in ipairs({ "Mainhand", "Offhand", "Ranged" }) do
    Row("offensive", name .. "Expertise", name .. " Expertise", Scalar("GetExpertise", index), "percent")
end
Row("defensive", "Armor", "Armor", Scalar("UnitArmor", 2, "player"), "number", "armor")
Row("defensive", "Defense", "Defense", Nonnegative(Sum("UnitDefenseSkill", 2, "player")))
Row("defensive", "Dodge", "Dodge", Scalar("GetDodgeChance", 1), "percent", "dodge")
Row("defensive", "Parry", "Parry", Scalar("GetParryChance", 1), "percent", "parry")
Row("defensive", "Block", "Block", Scalar("GetBlockChance", 1), "percent", "block")
Row("defensive", "BlockValue", "Block Value", Scalar("GetShieldBlock", 1), "number", "block")
for _, name in ipairs({ "Holy", "Fire", "Nature", "Frost", "Shadow", "Arcane" }) do
    Row("defensive", name .. "Resistance", name .. " Resistance", Resistance(name))
end
Row("utility", "ManaRegen", "Mana Regen / sec", Scalar("GetManaRegen", 1))
Row("utility", "CastingManaRegen", "Casting Mana Regen / sec", Scalar("GetManaRegen", 2))
Row("utility", "ManaRegenMP5", "Mana Regen / 5 sec", Scale(Scalar("GetManaRegen", 1), 5))
Row("utility", "CastingManaRegenMP5", "Casting Mana Regen / 5 sec", Scale(Scalar("GetManaRegen", 2), 5))
Row("utility", "MovementSpeed", "Run Speed (yd/sec)", Scalar("GetUnitSpeed", 2, "player"), "number", "speed")

F.defaults.showMainStat = false
F.defaults.showItemLevel = false
F.defaults.showMastery = false
F.defaults.showVersatility = false
F.defaults.showStagger = false
-- These are display choices, not stat weights or inferred talent roles.
local classSchools = {
    MAGE = { "Fire", "Frost", "Arcane" }, WARLOCK = { "Fire", "Shadow" },
    PRIEST = { "Holy", "Shadow" }, DRUID = { "Nature", "Arcane" },
    SHAMAN = { "Fire", "Frost", "Nature" }, PALADIN = { "Holy" },
}
local compactSelections = {
    MAGE = { "Intellect", "Spirit", "SpellCrit" }, WARLOCK = { "Intellect", "Spirit", "SpellCrit" },
    PRIEST = { "Intellect", "Spirit", "SpellCrit" },
    WARRIOR = { "Strength", "Stamina", "AttackPower", "MeleeCrit" },
    ROGUE = { "Agility", "Stamina", "AttackPower", "MeleeCrit" },
    HUNTER = { "Agility", "Stamina", "RangedAttackPower", "RangedCrit" },
    DRUID = { "Agility", "Intellect", "Stamina" },
    SHAMAN = { "Strength", "Intellect", "Stamina" }, PALADIN = { "Strength", "Intellect", "Stamina" },
}
local summaries = {
    compact = "Class essentials; choose a role preset for a hybrid build.",
    physical = "Attack power, crit, hit and haste; ranged stats for Hunters.",
    caster = "Spell crit, hit, haste and your class's spell schools.",
    healer = "Healing power, mana regeneration, spell crit and haste.",
    tank = "Armor, defense and avoidance, plus melee hit and expertise.",
}
local function CurrentClass()
    local fn = _G.UnitClass
    if type(fn) ~= "function" then return nil end
    local ok, _, token = pcall(fn, "player")
    if not ok or type(issecretvalue) ~= "function" then return nil end
    local checked, restricted = pcall(issecretvalue, token)
    if not checked or restricted ~= false or type(token) ~= "string" then return nil end
    return token
end
function F.BuildPresets(class)
    local presets = { order = { "compact", "physical", "caster", "healer", "tank" }, definitions = {} }
    local hunter = class == "HUNTER"
    local agile = hunter or class == "ROGUE" or class == "DRUID"
    local selections = {
        compact = compactSelections[class] or { "Stamina" },
        physical = { agile and "Agility" or "Strength", "Stamina", hunter and "RangedAttackPower" or "AttackPower",
            hunter and "RangedCrit" or "MeleeCrit", hunter and "RangedHit" or "MeleeHit",
            hunter and "RangedHaste" or "MeleeHaste", hunter and "RangedExpertise" or "MainhandExpertise" },
        caster = { "Intellect", "Spirit", "SpellCrit", "SpellHit", "SpellHaste" },
        healer = { "Intellect", "Spirit", "HealingPower", "SpellCrit", "SpellHaste", "ManaRegenMP5", "CastingManaRegenMP5" },
        tank = { class == "DRUID" and "Agility" or "Strength", "Stamina", "Armor", "Defense", "Dodge", "MeleeHit", "MainhandExpertise" },
    }
    if class ~= "DRUID" then selections.tank[#selections.tank + 1] = "Parry" end
    if class == "WARRIOR" or class == "PALADIN" or class == "SHAMAN" then
        selections.tank[#selections.tank + 1] = "Block"
        selections.tank[#selections.tank + 1] = "BlockValue"
    end
    for _, id in ipairs(presets.order) do
        local values = { showOffensive = true, showDefensive = id == "tank", showTertiary = id == "healer", showMainStat = false, showItemLevel = false, showMastery = false, showVersatility = false, showStagger = false }
        for _, rows in pairs(F.rows) do
            for _, row in ipairs(rows) do values[row.showKey] = false end
        end
        for _, key in ipairs(selections[id]) do values["show" .. key] = true end
        if id == "caster" or (id == "compact" and (class == "MAGE" or class == "WARLOCK" or class == "PRIEST")) then
            for _, school in ipairs(classSchools[class] or {}) do values["showSpellPower" .. school] = true end
        end
        presets.definitions[id] = { label = id:sub(1, 1):upper() .. id:sub(2), summary = summaries[id], values = values }
    end
    return presets
end
function F.BuildDefaults(class)
    local values = F.BuildPresets(class).definitions.compact.values
    local defaults = {}
    for key, value in pairs(values) do defaults[key] = value end
    return defaults
end
local initialClass = CurrentClass()
F.presets = F.BuildPresets(initialClass)
F.defaults = F.BuildDefaults(initialClass)

-- An addon palette: the client source supplies no canonical school RGB table.
F.colorDefaults = {
    foreverStrength = { r = 1, g = 0.35, b = 0.3 }, foreverAgility = { r = 0.35, g = 1, b = 0.45 },
    foreverIntellect = { r = 0.35, g = 0.7, b = 1 }, foreverSpirit = { r = 0.8, g = 0.55, b = 1 },
    foreverAttackPower = { r = 1, g = 0.55, b = 0.2 }, foreverHit = { r = 1, g = 0.85, b = 0.35 },
    foreverExpertise = { r = 1, g = 0.5, b = 0.75 }, foreverRegen = { r = 0.35, g = 0.9, b = 0.85 },
    foreverHealing = { r = 0.35, g = 1, b = 0.6 }, foreverSpellPenetration = { r = 0.7, g = 0.6, b = 1 },
    foreverArmorPenetration = { r = 0.95, g = 0.7, b = 0.45 }, foreverDefense = { r = 0.65, g = 0.8, b = 1 },
    foreverHoly = { r = 1, g = 0.9, b = 0.55 }, foreverFire = { r = 1, g = 0.4, b = 0.2 },
    foreverNature = { r = 0.4, g = 0.95, b = 0.35 }, foreverFrost = { r = 0.45, g = 0.85, b = 1 },
    foreverShadow = { r = 0.75, g = 0.45, b = 0.95 }, foreverArcane = { r = 0.95, g = 0.55, b = 1 },
}
for _, school in ipairs({ "Holy", "Fire", "Nature", "Frost", "Shadow", "Arcane" }) do
    local rgb = F.colorDefaults["forever" .. school]
    F.colorDefaults["foreverResistance" .. school] = { r = rgb.r, g = rgb.g, b = rgb.b }
end
for _, rows in pairs(F.rows) do
    for _, row in ipairs(rows) do
        local key = row.key
        if key == "Strength" or key == "Agility" or key == "Intellect" or key == "Spirit" then row.colorKey = "forever" .. key
        elseif key:match("Hit$") then row.colorKey = "foreverHit"
        elseif key:match("Expertise$") then row.colorKey = "foreverExpertise"
        elseif key:match("AttackPower$") then row.colorKey = "foreverAttackPower"
        elseif key:match("ManaRegen") then row.colorKey = "foreverRegen"
        elseif key == "HealingPower" then row.colorKey = "foreverHealing"
        elseif key == "Defense" or key == "ArmorPenetration" or key == "SpellPenetration" then row.colorKey = "forever" .. key
        elseif key:match("^SpellPower") then row.colorKey = "forever" .. key:sub(11)
        elseif key:match("Resistance$") then row.colorKey = "foreverResistance" .. key:gsub("Resistance$", "") end
    end
end

function F.ReadContext()
    if not F.enabled then return nil end
    local ok, guid = pcall(UnitGUID, "player")
    if not ok then return nil end
    if type(issecretvalue) ~= "function" then return nil end
    local classified, restricted = pcall(issecretvalue, guid)
    if not classified or type(restricted) ~= "boolean" or restricted then return nil end
    if type(guid) ~= "string" or guid == "" then return nil end
    return { guid = guid, specID = 1, specName = "Character" }
end

F.labels = {
    ruRU = {
        ["Strength"] = "Сила", ["Agility"] = "Ловкость", ["Stamina"] = "Выносливость",
        ["Intellect"] = "Интеллект", ["Spirit"] = "Дух", ["Melee Crit"] = "Крит ближнего боя",
        ["Ranged Crit"] = "Крит дальнего боя", ["Spell Crit"] = "Крит заклинаний",
        ["Melee Hit"] = "Меткость ближнего боя", ["Ranged Hit"] = "Меткость дальнего боя",
        ["Spell Hit"] = "Меткость заклинаний", ["Melee Haste"] = "Скорость ближнего боя",
        ["Ranged Haste"] = "Скорость дальнего боя", ["Spell Haste"] = "Скорость заклинаний",
        ["Attack Power"] = "Сила атаки", ["Ranged Attack Power"] = "Сила атаки дальнего боя",
        ["Holy Spell Power"] = "Сила светлой магии", ["Fire Spell Power"] = "Сила огня",
        ["Nature Spell Power"] = "Сила природы", ["Frost Spell Power"] = "Сила льда",
        ["Shadow Spell Power"] = "Сила темной магии", ["Arcane Spell Power"] = "Сила тайной магии",
        ["Healing Power"] = "Сила исцеления", ["Spell Penetration"] = "Проникновение заклинаний",
        ["Armor Penetration"] = "Пробивание брони", ["Mainhand Expertise"] = "Мастерство основной руки",
        ["Offhand Expertise"] = "Мастерство второй руки", ["Ranged Expertise"] = "Мастерство дальнего боя",
        ["Armor"] = "Броня", ["Defense"] = "Защита", ["Dodge"] = "Уклонение",
        ["Parry"] = "Парирование", ["Block"] = "Блокирование", ["Block Value"] = "Величина блока",
        ["Holy Resistance"] = "Сопротивление светлой магии", ["Fire Resistance"] = "Сопротивление огню",
        ["Nature Resistance"] = "Сопротивление силам природы", ["Frost Resistance"] = "Сопротивление льду",
        ["Shadow Resistance"] = "Сопротивление темной магии", ["Arcane Resistance"] = "Сопротивление тайной магии",
        ["Mana Regen / sec"] = "Мана в секунду", ["Casting Mana Regen / sec"] = "Мана при произнесении / сек",
        ["Mana Regen / 5 sec"] = "Мана за 5 секунд", ["Casting Mana Regen / 5 sec"] = "Мана при произнесении / 5 сек",
        ["Run Speed (yd/sec)"] = "Скорость бега (ярд/сек)",
    },
}
local vocabularyKeys = "Strength|Agility|Stamina|Intellect|Spirit|Melee|Ranged|Spell|Crit|Hit|Haste|AttackPower|Holy|Fire|Nature|Frost|Shadow|Arcane|SpellPower|HealingPower|SpellPenetration|ArmorPenetration|Mainhand|Offhand|Expertise|Armor|Defense|Dodge|Parry|Block|BlockValue|Resistance|ManaRegen|CastingManaRegen|ManaRegenMP5|CastingManaRegenMP5|RunSpeed|Compact|Physical|Caster|Healer|Tank|Summary|Character"
local vocabulary = {
    enUS = "Strength|Agility|Stamina|Intellect|Spirit|Melee|Ranged|Spell|Crit|Hit|Haste|Attack Power|Holy|Fire|Nature|Frost|Shadow|Arcane|Spell Power|Healing Power|Spell Penetration|Armor Penetration|Mainhand|Offhand|Expertise|Armor|Defense|Dodge|Parry|Block|Block Value|Resistance|Mana Regen / sec|Casting Mana Regen / sec|Mana Regen / 5 sec|Casting Mana Regen / 5 sec|Run Speed (yd/sec)|Compact|Physical|Caster|Healer|Tank|Select individual stats for your build.|Character",
    deDE = "Stärke|Beweglichkeit|Ausdauer|Intelligenz|Willenskraft|Nahkampf|Fernkampf|Zauber|Krit|Trefferchance|Tempo|Angriffskraft|Heilig|Feuer|Natur|Frost|Schatten|Arkan|Zaubermacht|Heilungskraft|Zauberdurchschlag|Rüstungsdurchschlag|Waffenhand|Schildhand|Waffenkunde|Rüstung|Verteidigung|Ausweichen|Parieren|Blocken|Blockwert|Widerstand|Mana / Sek.|Mana beim Wirken / Sek.|Mana / 5 Sek.|Mana beim Wirken / 5 Sek.|Lauftempo (Yard/Sek.)|Kompakt|Physisch|Zauberwirker|Heiler|Tank|Wähle einzelne Werte für deinen Build.|Charakter",
    esES = "Fuerza|Agilidad|Aguante|Intelecto|Espíritu|Cuerpo a cuerpo|A distancia|Hechizos|Crítico|Golpe|Celeridad|Poder de ataque|Sagrado|Fuego|Naturaleza|Escarcha|Sombras|Arcano|Poder con hechizos|Poder de sanación|Penetración de hechizos|Penetración de armadura|Mano derecha|Mano izquierda|Pericia|Armadura|Defensa|Esquivar|Parar|Bloquear|Valor de bloqueo|Resistencia|Maná / s|Maná al lanzar / s|Maná / 5 s|Maná al lanzar / 5 s|Velocidad al correr (yardas/s)|Compacto|Físico|Lanzador|Sanador|Tanque|Selecciona estadísticas para tu configuración.|Personaje",
    frFR = "Force|Agilité|Endurance|Intelligence|Esprit|Mêlée|À distance|Sorts|Critique|Toucher|Hâte|Puissance d’attaque|Sacré|Feu|Nature|Givre|Ombre|Arcane|Puissance des sorts|Puissance des soins|Pénétration des sorts|Pénétration d’armure|Main droite|Main gauche|Expertise|Armure|Défense|Esquive|Parade|Blocage|Valeur de blocage|Résistance|Mana / s|Mana pendant l’incantation / s|Mana / 5 s|Mana pendant l’incantation / 5 s|Vitesse de course (yards/s)|Compact|Physique|Lanceur de sorts|Soigneur|Tank|Choisissez les caractéristiques de votre configuration.|Personnage",
    itIT = "Forza|Agilità|Tempra|Intelletto|Spirito|Mischia|A distanza|Incantesimi|Critico|Impatto|Celerità|Potenza d’attacco|Sacro|Fuoco|Natura|Gelo|Ombra|Arcano|Potenza magica|Potenza di cura|Penetrazione magica|Penetrazione dell’armatura|Mano primaria|Mano secondaria|Perizia|Armatura|Difesa|Schivata|Parata|Blocco|Valore di blocco|Resistenza|Mana / sec|Mana durante il lancio / sec|Mana / 5 sec|Mana durante il lancio / 5 sec|Velocità di corsa (iarde/sec)|Compatto|Fisico|Incantatore|Guaritore|Difensore|Seleziona le statistiche per la tua configurazione.|Personaggio",
    ptBR = "Força|Agilidade|Vigor|Intelecto|Espírito|Corpo a corpo|À distância|Feitiços|Crítico|Acerto|Aceleração|Poder de ataque|Sagrado|Fogo|Natureza|Gelo|Sombra|Arcano|Poder mágico|Poder de cura|Penetração de feitiços|Penetração de armadura|Mão principal|Mão secundária|Aptidão|Armadura|Defesa|Esquiva|Aparo|Bloqueio|Valor de bloqueio|Resistência|Mana / s|Mana ao lançar / s|Mana / 5 s|Mana ao lançar / 5 s|Velocidade de corrida (jardas/s)|Compacto|Físico|Lançador|Curador|Tanque|Selecione os atributos para sua configuração.|Personagem",
    ruRU = "Сила|Ловкость|Выносливость|Интеллект|Дух|Ближний бой|Дальний бой|Заклинания|Крит|Меткость|Скорость|Сила атаки|Свет|Огонь|Природа|Лед|Тьма|Тайная магия|Сила заклинаний|Сила исцеления|Проникновение заклинаний|Пробивание брони|Основная рука|Вторая рука|Мастерство|Броня|Защита|Уклонение|Парирование|Блокирование|Величина блока|Сопротивление|Мана в секунду|Мана при произнесении / сек|Мана за 5 секунд|Мана при произнесении / 5 сек|Скорость бега (ярд/сек)|Компактный|Физический|Заклинатель|Лекарь|Танк|Выбери отдельные характеристики для своего билда.|Персонаж",
    koKR = "힘|민첩성|체력|지능|정신력|근접|원거리|주문|치명타|적중|가속|전투력|신성|화염|자연|냉기|암흑|비전|주문력|치유력|주문 관통력|방어구 관통력|주장비|보조장비|숙련|방어도|방어 숙련|회피|무기 막기|방패 막기|방패 피해 방어량|저항|마나 회복 / 초|시전 중 마나 회복 / 초|마나 회복 / 5초|시전 중 마나 회복 / 5초|달리기 속도 (야드/초)|간략|물리|주문 시전자|치유|방어|자신의 빌드에 맞는 능력치를 선택하세요.|캐릭터",
    zhCN = "力量|敏捷|耐力|智力|精神|近战|远程|法术|爆击|命中|急速|攻击强度|神圣|火焰|自然|冰霜|暗影|奥术|法术强度|治疗强度|法术穿透|护甲穿透|主手|副手|精准|护甲|防御|躲闪|招架|格挡|格挡值|抗性|法力回复 / 秒|施法时法力回复 / 秒|法力回复 / 5秒|施法时法力回复 / 5秒|奔跑速度（码/秒）|精简|物理|施法|治疗|坦克|选择适合当前天赋配置的属性。|角色",
    zhTW = "力量|敏捷|耐力|智力|精神|近戰|遠程|法術|致命一擊|命中|加速|攻擊強度|神聖|火焰|自然|冰霜|暗影|秘法|法術能量|治療能量|法術穿透|護甲穿透|主手|副手|熟練|護甲|防禦|閃躲|招架|格擋|格擋值|抗性|法力恢復 / 秒|施法時法力恢復 / 秒|法力恢復 / 5秒|施法時法力恢復 / 5秒|奔跑速度（碼/秒）|精簡|物理|施法|治療|坦克|選擇適合目前天賦配置的屬性。|角色",
}
vocabulary.enGB = vocabulary.enUS
vocabulary.esMX = vocabulary.esES
local function Parts(text)
    local result = {}
    for part in text:gmatch("[^|]+") do result[#result + 1] = part end
    return result
end
local componentKeys = Parts(vocabularyKeys)
for locale, words in pairs(vocabulary) do
    local components = {}
    for index, word in ipairs(Parts(words)) do components[componentKeys[index]] = word end
    local labels = F.labels[locale] or {}
    F.labels[locale] = labels
    for _, rows in pairs(F.rows) do
        for _, row in ipairs(rows) do
            local key = row.key
            local text = components[key]
            if not text then
                local mode, stat = key:match("^(Melee)(.+)$")
                if not mode then mode, stat = key:match("^(Ranged)(.+)$") end
                if not mode then mode, stat = key:match("^(Spell)(.+)$") end
                if mode and components[stat] then text = components[stat] .. ": " .. components[mode] end
                local school = key:match("^SpellPower(.+)$")
                if school and components[school] then text = components.SpellPower .. ": " .. components[school] end
                local resistance = key:match("^(.+)Resistance$")
                if resistance and components[resistance] then text = components.Resistance .. ": " .. components[resistance] end
                local hand = key:match("^(.+)Expertise$")
                if hand and components[hand] then text = components.Expertise .. ": " .. components[hand] end
                if key == "MovementSpeed" then text = components.RunSpeed end
            end
            labels[row.label] = labels[row.label] or text
        end
    end
    for _, key in ipairs({ "Compact", "Physical", "Caster", "Healer", "Tank", "Character" }) do labels[key] = components[key] end
    labels["Select individual stats for your build."] = components.Summary
end
local utilityLabels = {
    enUS = { "Utility", "Show Utility Stats", "Character stats and gear HUD for WoW Forever. Open Settings to choose a layout and visible stats." },
    deDE = { "Weitere Werte", "Weitere Werte anzeigen", "Charakterwerte und Ausrüstung für WoW Forever. Öffne die Einstellungen, um Layout und sichtbare Werte auszuwählen." },
    esES = { "Utilidad", "Mostrar estadísticas de utilidad", "Panel de estadísticas y equipo para WoW Forever. Abre los ajustes para elegir el diseño y las estadísticas visibles." },
    frFR = { "Utilitaires", "Afficher les caractéristiques utilitaires", "Affichage des caractéristiques et de l’équipement pour WoW Forever. Ouvrez les paramètres pour choisir la disposition et les caractéristiques visibles." },
    itIT = { "Utilità", "Mostra statistiche di utilità", "Pannello di statistiche ed equipaggiamento per WoW Forever. Apri le impostazioni per scegliere la disposizione e le statistiche visibili." },
    ptBR = { "Utilidade", "Mostrar atributos de utilidade", "Painel de atributos e equipamentos para WoW Forever. Abra as configurações para escolher o layout e os atributos visíveis." },
    ruRU = { "Дополнительные", "Показывать дополнительные характеристики", "Характеристики персонажа и экипировка в WoW Forever. Открой настройки, чтобы выбрать расположение и видимые характеристики." },
    koKR = { "유틸리티", "유틸리티 능력치 표시", "WoW Forever의 캐릭터 능력치 및 장비 표시창입니다. 설정에서 배치와 표시할 능력치를 선택하세요." },
    zhCN = { "辅助属性", "显示辅助属性", "WoW Forever角色属性与装备面板。打开设置以选择布局和显示的属性。" },
    zhTW = { "輔助屬性", "顯示輔助屬性", "WoW Forever角色屬性與裝備面板。開啟設定以選擇版面配置和顯示的屬性。" },
}
utilityLabels.enGB = utilityLabels.enUS
utilityLabels.esMX = utilityLabels.esES
for locale, labels in pairs(utilityLabels) do
    F.labels[locale]["Utility"] = labels[1]
    F.labels[locale]["Show Utility Stats"] = labels[2]
    F.labels[locale]["Character stats and gear HUD for WoW Forever. Open Settings to choose a layout and visible stats."] = labels[3]
end
local presetSummaries = {
    enUS = { "Class essentials; choose a role preset for a hybrid build.", "Attack power, crit, hit and haste; ranged stats for Hunters.", "Spell crit, hit, haste and your class's spell schools.", "Healing power, mana regeneration, spell crit and haste.", "Armor, defense and avoidance, plus melee hit and expertise." },
    ruRU = { "Основное для класса; для гибридного билда выбери пресет роли.", "Сила атаки, крит, меткость и скорость; у охотников — дальний бой.", "Крит, меткость, скорость и школы магии твоего класса.", "Сила исцеления, восстановление маны, крит и скорость заклинаний.", "Броня, защита и уклонение от атак, а также меткость и мастерство." },
    deDE = { "Grundwerte deiner Klasse; wähle für Hybrid-Builds eine Rollenvorlage.", "Angriffskraft, Krit, Trefferchance und Tempo; Fernkampfwerte für Jäger.", "Zauberkrit, Trefferchance, Tempo und die Zauberschulen deiner Klasse.", "Heilungskraft, Manaregeneration, Zauberkrit und Tempo.", "Rüstung, Verteidigung und Vermeidung sowie Nahkampftrefferchance und Waffenkunde." },
    esES = { "Estadísticas básicas de tu clase; elige un rol para una configuración híbrida.", "Poder de ataque, crítico, golpe y celeridad; valores a distancia para cazadores.", "Crítico, golpe, celeridad y escuelas de magia de tu clase.", "Poder de sanación, regeneración de maná, crítico y celeridad de hechizos.", "Armadura, defensa y evasión, junto con golpe cuerpo a cuerpo y pericia." },
    frFR = { "L’essentiel de votre classe ; choisissez un rôle pour une configuration hybride.", "Puissance d’attaque, critique, toucher et hâte ; valeurs à distance pour les chasseurs.", "Critique, toucher, hâte des sorts et écoles de magie de votre classe.", "Puissance des soins, régénération du mana, critique et hâte des sorts.", "Armure, défense et évitement, avec toucher en mêlée et expertise." },
    itIT = { "Statistiche essenziali della classe; scegli un ruolo per una configurazione ibrida.", "Potenza d’attacco, critico, impatto e celerità; statistiche a distanza per i Cacciatori.", "Critico, impatto, celerità e scuole magiche della tua classe.", "Potenza di cura, rigenerazione del mana, critico e celerità degli incantesimi.", "Armatura, difesa ed elusione, più impatto in mischia e perizia." },
    ptBR = { "Atributos essenciais da classe; escolha um papel para uma configuração híbrida.", "Poder de ataque, crítico, acerto e aceleração; atributos à distância para Caçadores.", "Crítico, acerto, aceleração e escolas de magia da sua classe.", "Poder de cura, regeneração de mana, crítico e aceleração de feitiços.", "Armadura, defesa e evasão, além de acerto corpo a corpo e aptidão." },
    koKR = { "직업의 기본 능력치입니다. 혼합 빌드는 역할별 구성을 선택하세요.", "전투력, 치명타, 적중, 가속입니다. 사냥꾼은 원거리 능력치를 사용합니다.", "주문 치명타, 적중, 가속과 직업별 마법 계열입니다.", "치유력, 마나 회복, 주문 치명타와 가속입니다.", "방어도, 방어 숙련, 공격 회피와 근접 적중 및 숙련입니다." },
    zhCN = { "职业基础属性；混合流派请选择角色预设。", "攻击强度、爆击、命中与急速；猎人使用远程属性。", "法术爆击、命中、急速与当前职业的法术系别。", "治疗强度、法力回复、法术爆击与急速。", "护甲、防御与免伤属性，以及近战命中和精准。" },
    zhTW = { "職業基礎屬性；混合流派請選擇角色預設。", "攻擊強度、致命一擊、命中與加速；獵人使用遠程屬性。", "法術致命一擊、命中、加速與目前職業的法術系別。", "治療能量、法力恢復、法術致命一擊與加速。", "護甲、防禦與免傷屬性，以及近戰命中和熟練。" },
}
presetSummaries.enGB = presetSummaries.enUS
presetSummaries.esMX = presetSummaries.esES
for locale, translated in pairs(presetSummaries) do
    for index, id in ipairs(F.presets.order) do F.labels[locale][summaries[id]] = translated[index] end
end
local characterProfileLabels = {
    enUS = { "Return to character settings...", "Make this character independent...", "Shared with %d characters", "Every existing and future character uses these settings." },
    ruRU = { "Вернуться к настройкам персонажа...", "Сделать настройки персонажа отдельными...", "Общие для %d персонажей", "Эти настройки используются всеми нынешними и будущими персонажами." },
    deDE = { "Zu Charaktereinstellungen zurückkehren...", "Diesen Charakter unabhängig machen...", "Mit %d Charakteren geteilt", "Alle bestehenden und zukünftigen Charaktere verwenden diese Einstellungen." },
    esES = { "Volver a los ajustes del personaje...", "Usar ajustes independientes para este personaje...", "Compartido con %d personajes", "Todos los personajes actuales y futuros usan estos ajustes." },
    frFR = { "Revenir aux paramètres du personnage...", "Rendre ce personnage indépendant...", "Partagé avec %d personnages", "Tous les personnages actuels et futurs utilisent ces paramètres." },
    itIT = { "Torna alle impostazioni del personaggio...", "Rendi indipendente questo personaggio...", "Condiviso con %d personaggi", "Tutti i personaggi attuali e futuri usano queste impostazioni." },
    ptBR = { "Voltar às configurações do personagem...", "Tornar este personagem independente...", "Compartilhado com %d personagens", "Todos os personagens atuais e futuros usam estas configurações." },
    koKR = { "캐릭터 설정으로 돌아가기...", "이 캐릭터의 설정을 독립시키기...", "캐릭터 %d명과 공유", "현재와 향후 모든 캐릭터가 이 설정을 사용합니다." },
    zhCN = { "返回角色设置...", "让此角色使用独立设置...", "与%d个角色共享", "所有现有和未来的角色都使用这些设置。" },
    zhTW = { "返回角色設定...", "讓此角色使用獨立設定...", "與%d個角色共用", "所有現有和未來的角色都使用這些設定。" },
}
characterProfileLabels.enGB = characterProfileLabels.enUS
characterProfileLabels.esMX = characterProfileLabels.esES
for locale, labels in pairs(characterProfileLabels) do
    for index, key in ipairs(characterProfileLabels.enUS) do F.labels[locale][key] = labels[index] end
end
local nativeLabelGlobals = {
    Strength = "SPELL_STAT1_NAME", Agility = "SPELL_STAT2_NAME", Stamina = "SPELL_STAT3_NAME",
    Intellect = "SPELL_STAT4_NAME", Spirit = "SPELL_STAT5_NAME", Armor = "ARMOR", Defense = "DEFENSE",
    Dodge = "DODGE_CHANCE", Parry = "PARRY_CHANCE", Block = "BLOCK_CHANCE",
    ["Attack Power"] = "STAT_ATTACK_POWER", ["Ranged Attack Power"] = "RANGED_ATTACK_POWER",
    ["Healing Power"] = "BONUS_HEALING", ["Spell Penetration"] = "SPELL_PENETRATION",
    ["Armor Penetration"] = "STAT_ARMOR_PENETRATION",
}
function F.Translate(label, locale)
    if type(GetLocale) == "function" and locale == GetLocale() then
        local key = nativeLabelGlobals[label]
        local text = key and _G[key]
        if type(text) == "string" and text ~= "" then return text end
    end
    local translations = F.labels[locale]
    if translations and translations[label] then return translations[label] end
    return nil
end
