local ADDON_NAME = ...

-- ===== Settings =====
local STALE_SECONDS = 30                         -- discard DoT data without ticks
local SKULL_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local SKULL_SIZE = 32
-- Damage bar colors (r, g, b, alpha) depend on whether the DoTs kill the enemy:
local BAR_COLOR_NONLETHAL = { 0.55, 0.2, 0.85, 0.9 } -- the enemy survives the DoTs: purple
local BAR_COLOR_LETHAL = { 0, 0, 0, 0.9 }         -- 0 or less life left (the DoTs kill it): black
local BAR_TICK_COLOR = { 1, 1, 1, 0.5 }           -- thin lines, one per tick still to come
local BAR_EDGE_COLOR = { 1, 1, 1, 1 }             -- bright line on the left edge: where the enemy's life will end
local BAR_GLASS_TOP_ALPHA = 0.35                  -- glass effect: white at the top ...
local BAR_GLASS_BOTTOM_ALPHA = 0.35               -- ... black at the bottom
local BAR_MAX_TICKS = 40                          -- tick lines drawn per bar at most
local BAR_INSET = 2                              -- pixels kept free at the top and bottom (health bar border)
local BOLD_FONT = (GameFontNormalLarge:GetFont()) -- default font of your client
local BOLD_SIZE = 20
local TEXT_OFFSET_X = -50                         -- text and skull: negative = left, positive = right of the nameplate center
local TEXT_OFFSET_Y = 4                           -- text and skull: positive = up, negative = down
local CRIT_MULTIPLIER = 1.5                      -- placeholder: adjust to the crit damage multiplier of Forever

local DEFAULTS = {
    showText = true,
    showSkull = true,
    showBar = true,
    includeCrit = false,   -- add expected crit damage to the prediction
    trackOthers = true,    -- also count DoTs cast by other players
    onlyAttacked = false,  -- only show enemies you (or your pet) attacked
    textOffsetX = TEXT_OFFSET_X,   -- text and skull position, adjustable with the sliders
    textOffsetY = TEXT_OFFSET_Y,
    textSize = BOLD_SIZE,          -- font size of the text, adjustable with the sliders
    skullSize = SKULL_SIZE,        -- size of the skull icon
    showTicks = true,      -- tick lines on the damage bar
    showGlass = true,      -- glass effect (gradient) on the damage bar
    showTimeToDeath = true, -- seconds until the DoTs kill the enemy, next to the skull
    colorNonLethal = BAR_COLOR_NONLETHAL, -- colors of the damage bar, chosen with the color fields
    colorLethal = BAR_COLOR_LETHAL,
    tickColor = BAR_TICK_COLOR,
    edgeColor = BAR_EDGE_COLOR,
    minimapAngle = 215,
}

local playerGUID
local optionsPanel
local DOT_INFO = {}        -- by localized spell name
local dots = {}            -- dots[targetGUID][spellName] = { base, tick, ticks, total, last, school, lastCrit, crits }
DT_dots = dots             -- for /dump DT_dots
local attacked = {}        -- attacked[targetGUID] = time you (or your pet) last attacked it
local ATTACKED_SECONDS = 300 -- forget enemies you have not attacked for this long

local function InitDB()
    DotTrackerDB = DotTrackerDB or {}
    for k, v in pairs(DEFAULTS) do
        if DotTrackerDB[k] == nil then
            -- colors are tables: copy them so the saved value never changes the defaults
            DotTrackerDB[k] = type(v) == "table" and { v[1], v[2], v[3], v[4] } or v
        end
    end
end

-- ===== Slash commands =====
local debug = false

local function ToggleOptions()
    if not optionsPanel then return end
    if optionsPanel:IsShown() then optionsPanel:Hide() else optionsPanel:Show() end
end

local function RunTest()
    local guid = UnitGUID("target")
    if not guid then
        print("DotTracker test: please select a target first.")
        return
    end
    local now = GetTime()
    dots[guid] = dots[guid] or {}
    -- normal DoT: 6 ticks total, 2 done, 100 per tick
    dots[guid]["Test DoT (normal)"] = {
        total = 6, ticks = 2, tick = 100, base = 100, last = now, school = 32, lastCrit = false,
    }
    -- DoT whose last tick was a crit: shown tick 150, normal tick 100
    dots[guid]["Test DoT (crit)"] = {
        total = 12, ticks = 3, tick = 150, base = 100, last = now, school = 32, lastCrit = true, crits = 1,
    }
    print("DotTracker test: fake DoTs added to your target (removed after " .. STALE_SECONDS .. "s).")
end

SLASH_DOTTRACKER1 = "/dt"
SlashCmdList["DOTTRACKER"] = function(msg)
    if msg == "debug" then
        debug = not debug
        print("DotTracker debug:", debug)
    elseif msg == "test" then
        RunTest()
    else
        ToggleOptions()
    end
end

-- ===== Fallback display for your target when no nameplate is visible =====
local frame = CreateFrame("Frame", "DotTrackerFrame", UIParent)
frame:SetSize(300, 80)
frame:SetPoint("CENTER", 0, -150)

local fallbackText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
fallbackText:SetFont(BOLD_FONT, BOLD_SIZE, "THICKOUTLINE")
fallbackText:SetPoint("CENTER", TEXT_OFFSET_X, TEXT_OFFSET_Y)

local fallbackSkull = frame:CreateTexture(nil, "OVERLAY")
fallbackSkull:SetTexture(SKULL_TEXTURE)
fallbackSkull:SetSize(SKULL_SIZE, SKULL_SIZE)
fallbackSkull:SetPoint("BOTTOM", fallbackText, "TOP", 0, 2)
fallbackSkull:Hide()

-- seconds until death, to the right of the skull
local fallbackTTD = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
fallbackTTD:SetFont(BOLD_FONT, math.floor(BOLD_SIZE * 0.8), "THICKOUTLINE")
fallbackTTD:SetPoint("LEFT", fallbackSkull, "RIGHT", 4, 0)

-- ===== Text and skull on nameplates =====
local plateWidgets = {}
local function TextOffsets()
    local db = DotTrackerDB
    return (db and db.textOffsetX) or TEXT_OFFSET_X, (db and db.textOffsetY) or TEXT_OFFSET_Y
end

local function Sizes()
    local db = DotTrackerDB
    return (db and db.textSize) or BOLD_SIZE, (db and db.skullSize) or SKULL_SIZE
end

local function GetPlateWidgets(plate)
    local w = plateWidgets[plate]
    if not w then
        local textSize, skullSize = Sizes()
        -- The holder is parented to UIParent, not to the nameplate. Nameplate regions cannot be
        -- measured by addons in this client, so the text can only be anchored to the plate.
        local holder = CreateFrame("Frame", nil, UIParent)
        holder:SetFrameStrata("MEDIUM")
        holder:SetFrameLevel(50)
        local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        fs:SetFont(BOLD_FONT, textSize, "THICKOUTLINE")
        fs:SetPoint("BOTTOM", plate, "TOP", TextOffsets())
        local skull = holder:CreateTexture(nil, "OVERLAY")
        skull:SetTexture(SKULL_TEXTURE)
        skull:SetSize(skullSize, skullSize)
        skull:SetPoint("BOTTOM", fs, "TOP", 0, 2)
        skull:Hide()
        local ttd = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        ttd:SetFont(BOLD_FONT, math.floor(textSize * 0.8), "THICKOUTLINE")
        ttd:SetPoint("LEFT", skull, "RIGHT", 4, 0)
        w = { fs = fs, skull = skull, ttd = ttd }
        plateWidgets[plate] = w
    end
    return w
end

-- Re-anchors and resizes the text and skull on all nameplates and the fallback display
local function ApplyLayout()
    local x, y = TextOffsets()
    local textSize, skullSize = Sizes()
    fallbackText:ClearAllPoints()
    fallbackText:SetPoint("CENTER", x, y)
    fallbackText:SetFont(BOLD_FONT, textSize, "THICKOUTLINE")
    fallbackSkull:SetSize(skullSize, skullSize)
    fallbackTTD:SetFont(BOLD_FONT, math.floor(textSize * 0.8), "THICKOUTLINE")
    for plate, w in pairs(plateWidgets) do
        w.fs:ClearAllPoints()
        w.fs:SetPoint("BOTTOM", plate, "TOP", x, y)
        w.fs:SetFont(BOLD_FONT, textSize, "THICKOUTLINE")
        w.ttd:SetFont(BOLD_FONT, math.floor(textSize * 0.8), "THICKOUTLINE")
        w.skull:SetSize(skullSize, skullSize)
    end
end

-- ===== Damage segment on the health bar =====
-- overlays[healthBar] = { frame, base, glass, ticks = { textures }, edge }
-- The frame lives on UIParent, is anchored to the fill texture of the health bar and clips its
-- children to its own size.
local overlays = {}

-- Color r, g, b, a chosen in the options (key in DotTrackerDB) or the default constant
local function BarColor(key, default)
    local c = DotTrackerDB and DotTrackerDB[key] or default
    return c[1], c[2], c[3], c[4]
end

-- Vertical gradient: topAlpha of white at the top, bottomAlpha of black at the bottom
local function SetGlass(tex, topAlpha, bottomAlpha)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradientAlpha then
        tex:SetGradientAlpha("VERTICAL", 0, 0, 0, bottomAlpha, 1, 1, 1, topAlpha)
    elseif tex.SetGradient and CreateColor then
        tex:SetGradient("VERTICAL", CreateColor(0, 0, 0, bottomAlpha), CreateColor(1, 1, 1, topAlpha))
    end
end

local function GetOverlay(healthBar)
    local o = overlays[healthBar]
    if not o then
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetFrameStrata("MEDIUM")
        f:SetFrameLevel(49)
        f:SetClipsChildren(true)
        f:Hide()

        local base = f:CreateTexture(nil, "ARTWORK")
        base:SetAllPoints()

        local glass = f:CreateTexture(nil, "ARTWORK", nil, 1)
        glass:SetAllPoints()
        SetGlass(glass, BAR_GLASS_TOP_ALPHA, BAR_GLASS_BOTTOM_ALPHA)

        local edge = f:CreateTexture(nil, "OVERLAY", nil, 2)
        edge:SetPoint("TOPLEFT", f, "TOPLEFT")
        edge:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT")
        edge:SetWidth(1)

        o = { frame = f, base = base, glass = glass, ticks = {}, edge = edge }
        overlays[healthBar] = o
    end
    return o
end

-- Tick line number i of an overlay (created when needed)
local function GetTickLine(o, i)
    local t = o.ticks[i]
    if not t then
        t = o.frame:CreateTexture(nil, "OVERLAY", nil, 1)
        o.ticks[i] = t
    end
    return t
end

-- ===== DoT data =====
-- Lookup of all Classic DoTs: { spellId (any rank), English fallback name, tick interval, base duration }
-- Durations are the base values of the highest rank WITHOUT talents. Lower ranks and
-- talents (e.g. Improved Corruption, Improved Rend) change the real duration; for your own
-- DoTs the real duration is read from the aura when possible.
-- Combo point DoTs (Rupture, Rip) use a middle value because the combo points are not in the log.
local DOT_LOOKUP = {
    -- Warlock
    { 172,   "Corruption",       3, 12 },
    { 980,   "Curse of Agony",   2, 24 },
    { 348,   "Immolate",         3, 15 },
    { 18265, "Siphon Life",      3, 30 },
    -- Warrior
    { 772,   "Rend",             3, 21 },
    { 12162, "Deep Wounds",      3, 12 },
    -- Rogue
    { 703,   "Garrote",          3, 18 },
    { 1943,  "Rupture",          2, 12 },
    { 2818,  "Deadly Poison",    3, 12 },
    -- Hunter
    { 1978,  "Serpent Sting",    3, 15 },
    { 13795, "Immolation Trap",  3, 15 },
    -- Druid
    { 1822,  "Rake",             3, 9 },
    { 1079,  "Rip",              2, 12 },
    { 8921,  "Moonfire",         3, 12 },
    { 9007,  "Pounce Bleed",     3, 18 },
    -- Priest
    { 589,   "Shadow Word: Pain", 3, 18 },
    { 2944,  "Devouring Plague", 3, 24 },
    { 14914, "Holy Fire",        2, 10 },
    -- Mage
    { 133,   "Fireball",         2, 8 },
    { 11366, "Pyroblast",        3, 12 },
    { 2120,  "Flamestrike",      2, 8 },
    -- Shaman
    { 8050,  "Flame Shock",      3, 12 },
}

local function RegisterAll()
    for _, d in ipairs(DOT_LOOKUP) do
        local name = GetSpellInfo(d[1]) or d[2]
        DOT_INFO[name] = { interval = d[3], duration = d[4] }
    end
end

local function AuraDuration(destGUID, spellName)
    if UnitGUID("target") ~= destGUID then return nil end
    for i = 1, 40 do
        local name, _, _, _, duration = UnitDebuff("target", i, "PLAYER")
        if not name then break end
        if name == spellName and duration and duration > 0 then
            return duration
        end
    end
end

-- The combat log gives the school as a bit mask (Physical=1, Holy=2, Fire=4, Nature=8,
-- Frost=16, Shadow=32, Arcane=64), but GetSpellCritChance expects an index from 1 to 7
-- (Physical=1, Holy=2, Fire=3, Nature=4, Frost=5, Shadow=6, Arcane=7).
-- For multi-school spells the lowest crit chance of the included schools applies.
local function SpellCritChance(mask)
    if not mask or not GetSpellCritChance then return 0 end
    local lowest
    for index = 1, 7 do
        if math.floor(mask / 2 ^ (index - 1)) % 2 == 1 then
            local ok, chance = pcall(GetSpellCritChance, index)
            if ok and chance then
                lowest = lowest and math.min(lowest, chance) or chance
            end
        end
    end
    return (lowest or 0) / 100
end

-- Damage per remaining tick for one DoT entry (never extrapolates from a crit tick)
local function PerTick(e)
    local perTick = e.base or e.tick or 0
    -- crit chance is only known for your own spells
    if DotTrackerDB and DotTrackerDB.includeCrit and e.mine ~= false then
        perTick = perTick * (1 + SpellCritChance(e.school) * (CRIT_MULTIPLIER - 1))
    end
    return perTick
end

-- Returns remaining HP after all DoTs, whether that is lethal, and the total DoT damage
local function Summary(guid, hp)
    local d = dots[guid]
    if not d or not hp then return nil end
    if DotTrackerDB and DotTrackerDB.onlyAttacked and not attacked[guid] then return nil end
    local total, n = 0, 0
    for _, e in pairs(d) do
        total = total + math.max(e.total - e.ticks, 0) * PerTick(e)
        n = n + 1
    end
    if n == 0 then return nil end
    total = math.floor(total + 0.5)
    return hp - total, (hp > 0 and total >= hp), total
end

-- The ticks still to come, sorted by time: { { t = seconds from now, dmg = damage }, ... }
-- The next tick of a DoT is expected one interval after its last tick.
local function Schedule(guid)
    local d = dots[guid]
    if not d then return nil end
    local now = GetTime()
    local list = {}
    for _, e in pairs(d) do
        local interval = e.interval or 3
        local perTick = PerTick(e)
        for k = 1, math.max(e.total - e.ticks, 0) do
            list[#list + 1] = { t = math.max(e.last + k * interval - now, 0), dmg = perTick }
        end
    end
    table.sort(list, function(a, b) return a.t < b.t end)
    return list
end

-- Seconds until the DoTs have dealt as much damage as the enemy has life, or nil
local function TimeToDeath(guid, hp)
    local list = Schedule(guid)
    if not list or not hp then return nil end
    local sum = 0
    for _, s in ipairs(list) do
        sum = sum + s.dmg
        if sum >= hp - 0.5 then return s.t end
    end
end

local function FormatTimeToDeath(t)
    if not t then return "" end
    return string.format("|cffffffff%d s|r", math.ceil(t))
end

-- Draws the DoT damage on the health bar: color by the life left, glass effect, tick lines
local function ShowDamageOnBar(plate, guid, hp, maxHP, total, remaining)
    local uf = plate.UnitFrame or plate.unitFrame
    local healthBar = uf and uf.healthBar
    if not healthBar or not hp or not maxHP or maxHP <= 0 or maxHP == 100 then return end

    local fill = healthBar:GetStatusBarTexture()
    if not fill then return end

    -- measuring can fail on restricted nameplate regions: skip the bar instead of erroring
    local ok, barWidth = pcall(healthBar.GetWidth, healthBar)
    if not ok or not barWidth then return end
    local width = barWidth * math.min(total, hp) / maxHP
    if width < 1 then return end

    local db = DotTrackerDB
    local o = GetOverlay(healthBar)
    -- Our frame is on UIParent but the nameplate has its own scale. Give the frame the same
    -- effective scale as the health bar, so its width and lines match the bar exactly.
    local okScale, barScale = pcall(healthBar.GetEffectiveScale, healthBar)
    local uiScale = UIParent:GetEffectiveScale()
    if okScale and barScale and uiScale and uiScale > 0 then
        o.frame:SetScale(barScale / uiScale)
    end
    o.frame:ClearAllPoints()
    o.frame:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, -BAR_INSET)
    o.frame:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, BAR_INSET)
    o.frame:SetWidth(width)

    -- two colors: the DoTs kill the enemy (0 or less life left) or it survives
    if remaining <= 0 then
        o.base:SetColorTexture(BarColor("colorLethal", BAR_COLOR_LETHAL))
    else
        o.base:SetColorTexture(BarColor("colorNonLethal", BAR_COLOR_NONLETHAL))
    end
    o.glass:SetShown(db.showGlass)
    o.edge:SetColorTexture(BarColor("edgeColor", BAR_EDGE_COLOR))

    -- one thin line per tick still to come, counted from the right edge of the filled part
    local used = 0
    if db.showTicks then
        local list = Schedule(guid)
        if list then
            local cum, lastX = 0, 0
            for _, s in ipairs(list) do
                cum = cum + s.dmg
                local x = barWidth * cum / maxHP
                if x >= width - 1 or used >= BAR_MAX_TICKS then break end
                if x - lastX >= 2 then
                    used = used + 1
                    local t = GetTickLine(o, used)
                    t:SetColorTexture(BarColor("tickColor", BAR_TICK_COLOR))
                    t:ClearAllPoints()
                    t:SetPoint("TOPRIGHT", o.frame, "TOPRIGHT", -x, 0)
                    t:SetPoint("BOTTOMRIGHT", o.frame, "BOTTOMRIGHT", -x, 0)
                    t:SetWidth(1)
                    t:Show()
                    lastX = x
                end
            end
        end
    end
    for i = used + 1, #o.ticks do o.ticks[i]:Hide() end

    o.frame:Show()
end

-- Negative numbers (overkill) are shown in red
local function FormatRemaining(n)
    if n < 0 then
        return string.format("|cffff3030%d|r", n)
    end
    return string.format("|cffffffff%d|r", n)
end

local function Prune()
    local now = GetTime()
    for guid, d in pairs(dots) do
        for name, e in pairs(d) do
            if now - e.last > STALE_SECONDS then d[name] = nil end
        end
        if next(d) == nil then dots[guid] = nil end
    end
    for guid, t in pairs(attacked) do
        if now - t > ATTACKED_SECONDS then attacked[guid] = nil end
    end
end

local function Update()
    if not DotTrackerDB then return end
    local db = DotTrackerDB

    for _, w in pairs(plateWidgets) do
        w.fs:SetText("")
        w.skull:Hide()
        w.ttd:SetText("")
    end
    for _, o in pairs(overlays) do
        o.frame:Hide()
    end
    fallbackText:SetText("")
    fallbackSkull:Hide()
    fallbackTTD:SetText("")

    local targetGUID = UnitGUID("target")
    local targetShown = false

    for i = 1, 40 do
        local unit = "nameplate" .. i
        -- friendly units (e.g. a mind controlled enemy) are not shown; their DoT data is kept
        -- because the DoTs keep ticking and the enemy turns hostile again afterwards
        if UnitExists(unit) and not UnitIsFriend("player", unit) then
            local guid = UnitGUID(unit)
            if guid and dots[guid] then
                local hp, maxHP = UnitHealth(unit), UnitHealthMax(unit)
                local remaining, lethal, total = Summary(guid, hp)
                local plate = C_NamePlate.GetNamePlateForUnit(unit)
                if remaining and plate then
                    local w = GetPlateWidgets(plate)
                    if db.showText then w.fs:SetText(FormatRemaining(remaining)) end
                    if db.showSkull and lethal then w.skull:Show() end
                    if db.showBar then ShowDamageOnBar(plate, guid, hp, maxHP, total, remaining) end
                    if db.showTimeToDeath and lethal then w.ttd:SetText(FormatTimeToDeath(TimeToDeath(guid, hp))) end
                    if guid == targetGUID then targetShown = true end
                end
            end
        end
    end

    if targetGUID and not targetShown and dots[targetGUID] and not UnitIsFriend("player", "target") then
        local remaining, lethal = Summary(targetGUID, UnitHealth("target"))
        if remaining then
            if db.showText then fallbackText:SetText(FormatRemaining(remaining)) end
            if db.showSkull and lethal then fallbackSkull:Show() end
            if db.showTimeToDeath and lethal then
                fallbackTTD:SetText(FormatTimeToDeath(TimeToDeath(targetGUID, UnitHealth("target"))))
            end
        end
    end
end

-- ===== Combat log =====
-- One hint per session, only when a DoT is tracked while enemy nameplates are off
local nameplateHintShown = false
local function HintIfNameplatesOff()
    if nameplateHintShown or GetCVar("nameplateShowEnemies") == "1" then return end
    nameplateHintShown = true
    local key = GetBindingKey("NAMEPLATES")
    print("DotTracker: enemy nameplates are off, so only your target's text is shown. Press "
        .. (key and GetBindingText(key) or "the 'Display Enemy Nameplates' key") .. " to enable them.")
end

local function OnCombatLog()
    local _, subevent, _, sourceGUID, _, _, _, destGUID, _, _, _, _, spellName, _, amount,
          _, school, _, _, _, critical = CombatLogGetCurrentEventInfo()

    if subevent == "UNIT_DIED" then
        dots[destGUID] = nil
        attacked[destGUID] = nil
        return
    end

    -- remember every enemy you (or your pet) hit or tried to hit
    -- a mind controlled / possessed unit sits in the pet slot but is not a real pet: its attacks
    -- and the attacks on it do not count as "attacked by me"
    local petGUID = UnitGUID("pet")
    if petGUID and (UnitIsCharmed("pet") or UnitIsPossessed("pet")) then petGUID = nil end
    if sourceGUID and destGUID and (sourceGUID == playerGUID or sourceGUID == petGUID)
        and destGUID ~= playerGUID and destGUID ~= UnitGUID("pet")
        and (subevent:find("_DAMAGE$") or subevent:find("_MISSED$") or subevent == "SPELL_AURA_APPLIED") then
        attacked[destGUID] = GetTime()
    end
    local info = DOT_INFO[spellName]
    if not info or not sourceGUID then return end
    local mine = sourceGUID == playerGUID
    if not mine and not (DotTrackerDB and DotTrackerDB.trackOthers) then return end
    if debug then print("CLEU:", subevent, sourceGUID, spellName, amount, "crit:", critical) end

    -- one entry per caster, all of them are summed up in Summary()
    local key = mine and spellName or (sourceGUID .. ":" .. spellName)
    local function Duration()
        return (mine and AuraDuration(destGUID, spellName)) or info.duration
    end

    if subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REMOVED" then
        -- new application or expired: start over
        if dots[destGUID] then dots[destGUID][key] = nil end

    elseif subevent == "SPELL_AURA_REFRESH" or subevent == "SPELL_AURA_REFRESHED" then
        -- recast while active: full duration again, keep last known tick damage
        local e = dots[destGUID] and dots[destGUID][key]
        if e then
            local duration = Duration()
            e.ticks = 0
            e.total = math.max(1, math.floor(duration / info.interval + 0.5))
            e.last = GetTime()
        end

    elseif subevent == "SPELL_PERIODIC_DAMAGE" then
        dots[destGUID] = dots[destGUID] or {}
        local e = dots[destGUID][key]
        if not e then
            local duration = Duration()
            e = { ticks = 0, mine = mine, interval = info.interval, total = math.max(1, math.floor(duration / info.interval + 0.5)) }
            dots[destGUID][key] = e
            if mine or destGUID == UnitGUID("target") then HintIfNameplatesOff() end
        end
        e.ticks = e.ticks + 1
        e.tick = amount
        e.last = GetTime()
        e.school = school
        e.lastCrit = critical and true or false
        if critical then
            e.crits = (e.crits or 0) + 1
            -- do not extrapolate from a crit tick: estimate the normal tick
            -- until a normal tick has been seen
            if not e.base then e.base = amount / CRIT_MULTIPLIER end
        else
            e.base = amount
        end
    end
end

-- ===== Options window =====
local OPTIONS = {
    { key = "showText",    label = "Show remaining HP after all DoTs" },
    { key = "showSkull",   label = "Show skull icon when DoTs are lethal" },
    { key = "showBar",     label = "Show DoT damage on health bar" },
    { key = "showTicks",   label = "Show tick lines on the damage bar" },
    { key = "showGlass",   label = "Glass effect on the damage bar" },
    { key = "showTimeToDeath", label = "Show time to death next to the skull" },
    { key = "includeCrit", label = "Include expected crit damage (DoT crits)" },
    { key = "trackOthers", label = "Track DoTs of other players (summed up)" },
    { key = "onlyAttacked", label = "Track only enemies I attacked" },
}

local SLIDERS = {
    { key = "textOffsetX", label = "Text/skull horizontal offset (left <-> right)", min = -200, max = 200 },
    { key = "textOffsetY", label = "Text/skull vertical offset (down <-> up)",      min = -100, max = 100 },
    { key = "textSize",    label = "Text size",                                     min = 8,    max = 48 },
    { key = "skullSize",   label = "Skull size",                                    min = 8,    max = 96 },
}

local COLORS = {
    { key = "colorNonLethal", default = BAR_COLOR_NONLETHAL, label = "Bar color: enemy survives the DoTs" },
    { key = "colorLethal",    default = BAR_COLOR_LETHAL,    label = "Bar color: DoTs are lethal" },
    { key = "tickColor",   default = BAR_TICK_COLOR,   label = "Tick line color" },
    { key = "edgeColor",   default = BAR_EDGE_COLOR,   label = "Left edge line color" },
}

-- Opens the game's color picker (with opacity) for DotTrackerDB[key]; onChanged runs on every change
local function ChooseColor(key, onChanged)
    local c = DotTrackerDB[key]
    local prev = { c[1], c[2], c[3], c[4] }

    local function Set(r, g, b, a)
        DotTrackerDB[key] = { r, g, b, a }
        onChanged()
    end
    local function Cancel()
        Set(prev[1], prev[2], prev[3], prev[4])
    end

    if ColorPickerFrame.SetupColorPickerAndShow then
        -- newer clients: opacity is the alpha value (1 = opaque)
        local function Changed()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            Set(r, g, b, ColorPickerFrame:GetColorAlpha())
        end
        ColorPickerFrame:SetupColorPickerAndShow({
            r = prev[1], g = prev[2], b = prev[3], opacity = prev[4], hasOpacity = true,
            swatchFunc = Changed, opacityFunc = Changed, cancelFunc = Cancel,
        })
    else
        -- older clients: the opacity slider counts the other way (0 = opaque)
        local function Changed()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            Set(r, g, b, 1 - OpacitySliderFrame:GetValue())
        end
        ColorPickerFrame:Hide()
        ColorPickerFrame.func = Changed
        ColorPickerFrame.opacityFunc = Changed
        ColorPickerFrame.cancelFunc = Cancel
        ColorPickerFrame.hasOpacity = true
        ColorPickerFrame.opacity = 1 - prev[4]
        ColorPickerFrame.previousValues = prev
        ColorPickerFrame:SetColorRGB(prev[1], prev[2], prev[3])
        ColorPickerFrame:Show()
    end
end

local function BuildOptionsPanel()
    local panel = CreateFrame("Frame", "DotTrackerOptions", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    -- top: 45 + checkboxes, sliders (25 + 50 each), color rows (28 each), bottom: two button rows (76) + margin
    panel:SetSize(360, 180 + #OPTIONS * 28 + #SLIDERS * 50 + #COLORS * 28)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("DotTracker Options")

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local checks, sliders = {}, {}   -- by option key, refreshed by "Reset all"

    for i, opt in ipairs(OPTIONS) do
        local name = "DotTrackerCheck" .. i
        local cb = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
        checks[opt.key] = cb
        cb:SetPoint("TOPLEFT", 24, -45 - (i - 1) * 28)
        _G[name .. "Text"]:SetText(opt.label)
        cb:SetChecked(DotTrackerDB[opt.key])
        cb:SetScript("OnClick", function(self)
            DotTrackerDB[opt.key] = self:GetChecked() and true or false
            Update()
        end)
    end

    for i, s in ipairs(SLIDERS) do
        local name = "DotTrackerSlider" .. i
        local sl = CreateFrame("Slider", name, panel, "OptionsSliderTemplate")
        sliders[s.key] = sl
        sl:SetPoint("TOPLEFT", 30, -45 - #OPTIONS * 28 - 25 - (i - 1) * 50)
        sl:SetWidth(300)
        sl:SetMinMaxValues(s.min, s.max)
        sl:SetValueStep(1)
        if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
        _G[name .. "Low"]:SetText(s.min)
        _G[name .. "High"]:SetText(s.max)
        local function SetLabel(v) _G[name .. "Text"]:SetText(s.label .. ": " .. v) end
        sl:SetValue(DotTrackerDB[s.key])
        SetLabel(DotTrackerDB[s.key])
        sl:SetScript("OnValueChanged", function(self, value)
            value = math.floor(value + 0.5)
            DotTrackerDB[s.key] = value
            SetLabel(value)
            ApplyLayout()
        end)
    end

    -- color fields for the damage bar (click opens the color picker with opacity)
    local swatchTextures = {}
    local function RefreshSwatches()
        for i, c in ipairs(COLORS) do
            local v = DotTrackerDB[c.key]
            swatchTextures[i]:SetColorTexture(v[1], v[2], v[3], 1)
        end
    end
    for i, c in ipairs(COLORS) do
        local sw = CreateFrame("Button", nil, panel)
        sw:SetSize(22, 22)
        sw:SetPoint("TOPLEFT", 30, -45 - #OPTIONS * 28 - 25 - #SLIDERS * 50 - 5 - (i - 1) * 28)
        local border = sw:CreateTexture(nil, "BACKGROUND")
        border:SetAllPoints()
        border:SetColorTexture(1, 1, 1, 1)
        local tex = sw:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("TOPLEFT", 2, -2)
        tex:SetPoint("BOTTOMRIGHT", -2, 2)
        swatchTextures[i] = tex
        local label = sw:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", sw, "RIGHT", 8, 0)
        label:SetText(c.label)
        sw:SetScript("OnClick", function()
            ChooseColor(c.key, function() RefreshSwatches(); Update() end)
        end)
    end
    RefreshSwatches()

    local resetBtn = CreateFrame("Button", "DotTrackerResetColorsButton", panel, "UIPanelButtonTemplate")
    resetBtn:SetSize(150, 24)
    resetBtn:SetPoint("BOTTOMRIGHT", -24, 22)
    resetBtn:SetText("Reset colors")
    resetBtn:SetScript("OnClick", function()
        for _, c in ipairs(COLORS) do
            DotTrackerDB[c.key] = { c.default[1], c.default[2], c.default[3], c.default[4] }
        end
        RefreshSwatches()
        Update()
    end)

    -- same as /dt test: fake DoTs on your target (removed after STALE_SECONDS)
    local testBtn = CreateFrame("Button", "DotTrackerTestButton", panel, "UIPanelButtonTemplate")
    testBtn:SetSize(170, 24)
    testBtn:SetPoint("BOTTOMLEFT", 24, 22)
    testBtn:SetText("Test (fake DoTs)")
    testBtn:SetScript("OnClick", RunTest)

    -- resets every setting (checkboxes, sliders, colors) to the defaults; the minimap button stays where it is
    local function ResetAll()
        for k, v in pairs(DEFAULTS) do
            if k ~= "minimapAngle" then
                DotTrackerDB[k] = type(v) == "table" and { v[1], v[2], v[3], v[4] } or v
            end
        end
        for key, cb in pairs(checks) do cb:SetChecked(DotTrackerDB[key]) end
        for key, sl in pairs(sliders) do sl:SetValue(DotTrackerDB[key]) end
        RefreshSwatches()
        ApplyLayout()
        Update()
    end

    -- needs two clicks within 4 seconds, so a single misclick cannot wipe the settings
    local resetAllBtn = CreateFrame("Button", "DotTrackerResetAllButton", panel, "UIPanelButtonTemplate")
    resetAllBtn:SetSize(200, 24)
    resetAllBtn:SetPoint("BOTTOM", 0, 52)
    resetAllBtn:SetText("Reset all settings")
    local armed = false
    resetAllBtn:SetScript("OnClick", function(self)
        if not armed then
            armed = true
            self:SetText("Click again to confirm")
            C_Timer.After(4, function()
                armed = false
                self:SetText("Reset all settings")
            end)
            return
        end
        armed = false
        self:SetText("Reset all settings")
        ResetAll()
    end)

    tinsert(UISpecialFrames, "DotTrackerOptions")   -- ESC closes the window
    return panel
end

-- ===== Entry in the game menu (Escape -> Options -> AddOns) =====
local function BuildAddonInfoPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end

    local panel = CreateFrame("Frame")
    panel.name = "DotTrackerMinMax"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("DotTrackerMinMax")

    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local version = getMeta and getMeta(ADDON_NAME, "Version") or "?"

    local info = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    info:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    info:SetJustifyH("LEFT")
    info:SetText("Shows the remaining health of an enemy after all damage over time effects.\n"
        .. "Version: " .. version .. "\n"
        .. "Author: Manuel Metzger\n\n"
        .. "|cffffd100Slash commands:|r\n"
        .. "|cffffffff/dt|r  -  open or close the options window\n"
        .. "|cffffffff/dt test|r  -  add fake DoTs to your target for " .. STALE_SECONDS .. " seconds (preview)\n"
        .. "|cffffffff/dt debug|r  -  print the combat log events the addon reacts to (toggle, for bug reports)")

    -- links cannot be clicked in the game: show them in read-only boxes the player can copy
    local function AddLink(label, url, anchor)
        local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
        fs:SetText(label)
        local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        box:SetSize(380, 20)
        box:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 6, -4)
        box:SetAutoFocus(false)
        box:SetFontObject("GameFontHighlight")
        box:SetText(url)
        box:SetCursorPosition(0)
        -- read only: put the text back when edited, select everything on click for Ctrl+C
        box:SetScript("OnTextChanged", function(self, userInput)
            if userInput then self:SetText(url); self:HighlightText() end
        end)
        box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        return box
    end
    local github = AddLink("GitHub (source code, bug reports) - click, then Ctrl+C to copy:",
        "https://github.com/SirMantu/WOW_ADDON_DOT_TRACKER", info)
    local curse = AddLink("CurseForge (download):",
        "https://www.curseforge.com/wow/addons/dottracker-minmax", github)

    local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btn:SetSize(160, 24)
    btn:SetPoint("TOPLEFT", curse, "BOTTOMLEFT", -6, -20)
    btn:SetText("Open options")
    btn:SetScript("OnClick", function()
        if HideUIPanel and SettingsPanel then HideUIPanel(SettingsPanel) end
        ToggleOptions()
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
end

-- ===== Minimap button (draggable around the minimap) =====
local function BuildMinimapButton()
    local btn = CreateFrame("Button", "DotTrackerMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bone_HumanSkull_01")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    local function UpdatePosition()
        local angle = math.rad(DotTrackerDB.minimapAngle or 215)
        local radius = (Minimap:GetWidth() / 2) + 5
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
    end

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            DotTrackerDB.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            UpdatePosition()
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnClick", ToggleOptions)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("DotTracker")
        GameTooltip:AddLine("Click: open options", 1, 1, 1)
        GameTooltip:AddLine("Drag: move button", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()
end

-- ===== Events =====
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UNIT_HEALTH")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then InitDB(); ApplyLayout() end
        return
    elseif event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        RegisterAll()
        optionsPanel = BuildOptionsPanel()
        BuildAddonInfoPanel()
        BuildMinimapButton()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLog()
    end
    Update()
end)

local elapsedSum = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    elapsedSum = elapsedSum + elapsed
    if elapsedSum > 0.2 then
        elapsedSum = 0
        Prune()
        Update()
    end
end)