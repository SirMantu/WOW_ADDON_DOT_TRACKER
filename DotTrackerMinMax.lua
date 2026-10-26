local ADDON_NAME = ...

-- ===== Settings =====
local STALE_SECONDS = 30                         -- discard DoT data without ticks
local SKULL_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local SKULL_SIZE = 55
-- The damage bar is made of the ticks still to come; every tick has the color of its debuff
-- (DEBUFF_COLORS below, r, g, b, alpha). In simple mode the bar is one plain bar in BAR_COLOR_SIMPLE.
local BAR_COLOR_SIMPLE = { 0.55, 0.2, 0.85, 0.9 }
local BAR_TICK_COLOR = { 1, 1, 1, 0.5 }           -- thin lines, one per tick still to come
local BAR_GLASS_TOP_ALPHA = 0.35                  -- glass effect: white at the top ...
local BAR_GLASS_BOTTOM_ALPHA = 0.35               -- ... black at the bottom
local BAR_MAX_SEGMENTS = 120                      -- ticks drawn per bar at most
local TARGET_FRAME_INSET = 2                      -- pixels kept free at the top and bottom of the bar on the target frame
local BAR_FLASH_SECONDS = 0.1                     -- the part of the bar that a tick removes lights up this long, then it is gone (0 = no flash)
local BAR_FLASH_COLOR = { 1, 1, 1, 1 }            -- color of that flash
local TTD_COLOR = { 1, 0.125, 0.125, 1 }          -- color of the time to death: red, readable on the white skull
local TTD_SIZE_FACTOR = 0.5                      -- font size of the time to death on the skull, relative to the skull size
local BAR_INSET = 2                              -- pixels kept free at the top and bottom (health bar border)
local BOLD_FONT = (GameFontNormalLarge:GetFont()) -- default font of your client
local BOLD_SIZE = 20
local TEXT_OFFSET_X = -94                         -- text and skull: negative = left, positive = right of the nameplate center
local TEXT_OFFSET_Y = -75                           -- text and skull: positive = up, negative = down
local CRIT_MULTIPLIER = 1.5                      -- placeholder: adjust to the crit damage multiplier of Forever

-- One color per debuff, by the English spell name (the same names as in DOT_LOOKUP)
local DEBUFF_COLORS = {
    ["Corruption"]         = { 0.60, 0.20, 0.90, 0.9 },
    ["Curse of Agony"]     = { 0.85, 0.30, 0.70, 0.9 },
    ["Immolate"]           = { 1.00, 0.50, 0.00, 0.9 },
    ["Siphon Life"]        = { 0.20, 0.80, 0.50, 0.9 },
    ["Rend"]               = { 0.85, 0.10, 0.10, 0.9 },
    ["Deep Wounds"]        = { 0.60, 0.05, 0.20, 0.9 },
    ["Garrote"]            = { 0.90, 0.80, 0.20, 0.9 },
    ["Rupture"]            = { 0.90, 0.40, 0.30, 0.9 },
    ["Deadly Poison"]      = { 0.40, 0.90, 0.20, 0.9 },
    ["Serpent Sting"]      = { 0.20, 0.65, 0.20, 0.9 },
    ["Immolation Trap"]    = { 1.00, 0.65, 0.30, 0.9 },
    ["Rake"]               = { 0.90, 0.60, 0.10, 0.9 },
    ["Rip"]                = { 0.95, 0.30, 0.50, 0.9 },
    ["Moonfire"]           = { 0.40, 0.60, 1.00, 0.9 },
    ["Pounce Bleed"]       = { 0.70, 0.50, 0.20, 0.9 },
    ["Shadow Word: Pain"]  = { 0.55, 0.35, 0.95, 0.9 },
    ["Devouring Plague"]   = { 0.45, 0.00, 0.60, 0.9 },
    ["Holy Fire"]          = { 1.00, 0.90, 0.50, 0.9 },
    ["Fireball"]           = { 1.00, 0.35, 0.00, 0.9 },
    ["Pyroblast"]          = { 1.00, 0.20, 0.10, 0.9 },
    ["Flamestrike"]        = { 1.00, 0.75, 0.10, 0.9 },
    ["Flame Shock"]        = { 0.10, 0.70, 0.90, 0.9 },
}

local DEFAULTS = {
    showText = true,
    useNameplates = true,  -- show text, skull and damage bar on the enemy nameplates (off = only the target display)
    showCurrentLife = true, -- text shows "current life -> life after the DoTs"
    showSkull = true,
    showBar = true,
    includeCrit = false,   -- add expected crit damage to the prediction
    trackOthers = true,    -- also count DoTs cast by other players
    onlyAttacked = false,  -- only show enemies you (or your pet) attacked
    textOffsetX = TEXT_OFFSET_X,   -- text and skull position, adjustable with the sliders
    textOffsetY = TEXT_OFFSET_Y,
    textSize = BOLD_SIZE,          -- font size of the text, adjustable with the sliders
    skullSize = SKULL_SIZE,        -- size of the skull icon
    simpleMode = false,    -- one plain damage bar: no tick lines, glass effect or fade-out
    showTicks = true,      -- tick lines on the damage bar
    showGlass = true,      -- glass effect (gradient) on the damage bar
    showTimeToDeath = true, -- seconds until the DoTs kill the enemy, above the skull
    showTargetFrameBar = false, -- damage bar on the health bar of the game's target frame
    colorSimple = BAR_COLOR_SIMPLE, -- colors of the damage bar, chosen with the color fields
    tickColor = BAR_TICK_COLOR,
    ttdColor = TTD_COLOR,          -- color of the time to death on the skull
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
    -- colors the player has changed, by debuff name (missing = DEBUFF_COLORS)
    DotTrackerDB.debuffColors = DotTrackerDB.debuffColors or {}
    -- the default skull size grew from 32 to 48: move users who still have the old default
    if DotTrackerDB.skullSize == 32 or DotTrackerDB.skullSize == 48 then DotTrackerDB.skullSize = SKULL_SIZE end
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
        total = 6, ticks = 2, tick = 100, base = 100, last = now, school = 32, lastCrit = false, colorKey = "Corruption",
    }
    -- DoT whose last tick was a crit: shown tick 150, normal tick 100
    dots[guid]["Test DoT (crit)"] = {
        total = 12, ticks = 3, tick = 150, base = 100, last = now, school = 32, lastCrit = true, crits = 1, colorKey = "Immolate",
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

local fallbackSkull = frame:CreateTexture(nil, "ARTWORK")
fallbackSkull:SetTexture(SKULL_TEXTURE)
fallbackSkull:SetSize(SKULL_SIZE, SKULL_SIZE)
fallbackSkull:SetPoint("BOTTOM", fallbackText, "TOP", 0, 2)
fallbackSkull:Hide()

-- health bar of the target display, with the same damage bar as on the nameplates
local FALLBACK_BAR_WIDTH, FALLBACK_BAR_HEIGHT = 180, 16
local fallbackBar = CreateFrame("StatusBar", nil, frame)
fallbackBar:SetSize(FALLBACK_BAR_WIDTH, FALLBACK_BAR_HEIGHT)
fallbackBar:SetPoint("TOP", fallbackText, "BOTTOM", 0, -4)
fallbackBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
fallbackBar:SetStatusBarColor(0.1, 0.75, 0.1)
local fallbackBarBackground = fallbackBar:CreateTexture(nil, "BACKGROUND")
fallbackBarBackground:SetAllPoints()
fallbackBarBackground:SetColorTexture(0, 0, 0, 0.6)
fallbackBar:Hide()

-- seconds until death, to the right of the skull
local fallbackTTD = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
fallbackTTD:SetFont(BOLD_FONT, math.floor(SKULL_SIZE * TTD_SIZE_FACTOR), "THICKOUTLINE")
fallbackTTD:SetPoint("CENTER", fallbackSkull, "CENTER", 0, 0)

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
        fs:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", 0, 0)   -- anchored to the plate only while it is shown
        local skull = holder:CreateTexture(nil, "ARTWORK")
        skull:SetTexture(SKULL_TEXTURE)
        skull:SetSize(skullSize, skullSize)
        skull:SetPoint("BOTTOM", fs, "TOP", 0, 2)
        skull:Hide()
        local ttd = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        ttd:SetFont(BOLD_FONT, math.floor(skullSize * TTD_SIZE_FACTOR), "THICKOUTLINE")
        ttd:SetPoint("CENTER", skull, "CENTER", 0, 0)
        w = { fs = fs, skull = skull, ttd = ttd, anchored = false, active = false }
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
    fallbackTTD:SetFont(BOLD_FONT, math.floor(skullSize * TTD_SIZE_FACTOR), "THICKOUTLINE")
    for plate, w in pairs(plateWidgets) do
        if w.anchored then
            w.fs:ClearAllPoints()
            w.fs:SetPoint("BOTTOM", plate, "TOP", x, y)
        end
        w.fs:SetFont(BOLD_FONT, textSize, "THICKOUTLINE")
        w.ttd:SetFont(BOLD_FONT, math.floor(skullSize * TTD_SIZE_FACTOR), "THICKOUTLINE")
        w.skull:SetSize(skullSize, skullSize)
    end
end

-- ===== Damage segment on the health bar =====
-- overlays[healthBar] = { frame, base, glass, segments = { one texture per tick }, ticks = { separator lines }, ghost, ... }
-- The frame lives on UIParent, is anchored to the fill texture of the health bar and clips its
-- children to its own size.
local overlays = {}

-- Color r, g, b, a chosen in the options (key in DotTrackerDB) or the default constant
local function BarColor(key, default)
    local c = DotTrackerDB and DotTrackerDB[key] or default
    return c[1], c[2], c[3], c[4]
end

-- Color r, g, b, a of a debuff: chosen in the options, else the default of DEBUFF_COLORS
local function DebuffColor(key)
    local saved = DotTrackerDB and DotTrackerDB.debuffColors
    local c = (saved and key and saved[key]) or (key and DEBUFF_COLORS[key]) or BAR_COLOR_SIMPLE
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

        local base = f:CreateTexture(nil, "BACKGROUND")   -- below the colored ticks
        base:SetAllPoints()

        local glass = f:CreateTexture(nil, "ARTWORK", nil, 3)   -- above the colored ticks
        glass:SetAllPoints()
        SetGlass(glass, BAR_GLASS_TOP_ALPHA, BAR_GLASS_BOTTOM_ALPHA)

        -- the part of the bar that one tick takes away: it stays for a moment to the right of the bar
        -- (where the life was lost) and fades out. A separate frame, because f clips its children.
        local ghost = CreateFrame("Frame", nil, UIParent)
        ghost:SetFrameStrata("MEDIUM")
        ghost:SetFrameLevel(48)
        local ghostTexture = ghost:CreateTexture(nil, "ARTWORK")
        ghostTexture:SetAllPoints()
        ghost:Hide()

        o = { frame = f, base = base, glass = glass, segments = {}, ticks = {},
              ghost = ghost, ghostTexture = ghostTexture, ghostWidth = 0 }
        ghost.dtOverlay = o
        overlays[healthBar] = o
    end
    return o
end

-- The flash: the part of the bar one tick has taken away. It lights up to the right of the bar
-- (where the life was lost) for BAR_FLASH_SECONDS and is then gone at once, driven by OnUpdate.
local function GhostStep(ghost, elapsed)
    local o = ghost.dtOverlay
    o.ghostTime = o.ghostTime + elapsed
    if o.ghostTime >= BAR_FLASH_SECONDS then
        o.ghostWidth = 0
        ghost:SetScript("OnUpdate", nil)
        ghost:Hide()
    end
end

-- width = width of the lost part in the units of the bar
local function StartGhost(o, width)
    -- ticks in quick succession add up, the flash starts again
    o.ghostWidth = (o.ghost:IsShown() and o.ghostWidth or 0) + width
    o.ghostTime = 0
    o.ghostTexture:SetColorTexture(BAR_FLASH_COLOR[1], BAR_FLASH_COLOR[2], BAR_FLASH_COLOR[3], BAR_FLASH_COLOR[4])
    o.ghost:SetScale(o.frame:GetScale())
    o.ghost:SetFrameStrata(o.frame:GetFrameStrata())
    o.ghost:ClearAllPoints()
    o.ghost:SetPoint("TOPLEFT", o.frame, "TOPRIGHT")
    o.ghost:SetPoint("BOTTOMLEFT", o.frame, "BOTTOMRIGHT")
    o.ghost:SetWidth(o.ghostWidth)
    o.ghost:SetAlpha(1)
    o.ghost:Show()
    o.ghost:SetScript("OnUpdate", GhostStep)
end

local function HideGhost(o)
    o.ghostWidth = 0
    o.ghost:SetScript("OnUpdate", nil)
    o.ghost:Hide()
end

-- Segment number i of an overlay: one tick, in the color of its debuff (created when needed)
local function GetSegment(o, i)
    local t = o.segments[i]
    if not t then
        t = o.frame:CreateTexture(nil, "ARTWORK", nil, 1)
        o.segments[i] = t
    end
    return t
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
        DOT_INFO[name] = { interval = d[3], duration = d[4], colorKey = d[2] }
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
            list[#list + 1] = { t = math.max(e.last + k * interval - now, 0), dmg = perTick, key = e.colorKey }
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
    local c = DotTrackerDB and DotTrackerDB.ttdColor or TTD_COLOR
    return string.format("|cff%02x%02x%02x%d|r", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5),
        math.floor(c[3] * 255 + 0.5), math.ceil(t))
end

-- Draws the DoT damage on the health bar: color by the life left, glass effect, tick lines
local function PlateHealthBar(plate)
    local uf = plate.UnitFrame or plate.unitFrame
    return uf and uf.healthBar
end

-- healthBar is a nameplate health bar or our own bar of the target display; inset = pixels kept
-- free at the top and bottom (defaults to BAR_INSET); the nameplate of your target is drawn above the
-- others, so its bar needs a higher frame strata ("HIGH") to stay visible
local function ShowDamageOnBar(healthBar, guid, hp, maxHP, total, remaining, inset, strata)
    inset = inset or BAR_INSET
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
    o.touched = true
    -- Our frame is on UIParent but the nameplate has its own scale. Give the frame the same
    -- effective scale as the health bar, so its width and lines match the bar exactly.
    local okScale, barScale = pcall(healthBar.GetEffectiveScale, healthBar)
    local uiScale = UIParent:GetEffectiveScale()
    if okScale and barScale and uiScale and uiScale > 0 then
        o.frame:SetScale(barScale / uiScale)
    end
    o.frame:SetFrameStrata(strata or "MEDIUM")
    o.frame:SetFrameLevel(strata == "HIGH" and 100 or 49)
    o.frame:ClearAllPoints()
    o.frame:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, -inset)
    o.frame:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, inset)
    o.frame:SetWidth(width)

    -- simple mode: one plain bar, no glass effect, ticks, colors per debuff or flash
    local simple = db.simpleMode
    o.base:SetColorTexture(BarColor("colorSimple", BAR_COLOR_SIMPLE))
    o.glass:SetShown(db.showGlass and not simple)

    -- The bar is made of the ticks still to come, in the order they land, counted from the right
    -- edge of the filled part. Every tick has the color of its debuff; a thin line separates ticks.
    local usedSegments, usedLines = 0, 0
    if not simple then
        local list = Schedule(guid)
        if list then
            local cum, lastLine = 0, 0
            for _, tick in ipairs(list) do
                local x0 = barWidth * cum / maxHP
                cum = cum + tick.dmg
                local x1 = barWidth * cum / maxHP
                if x0 >= width or usedSegments >= BAR_MAX_SEGMENTS then break end
                usedSegments = usedSegments + 1
                local seg = GetSegment(o, usedSegments)
                seg:SetColorTexture(DebuffColor(tick.key))
                seg:ClearAllPoints()
                seg:SetPoint("TOPRIGHT", o.frame, "TOPRIGHT", -x0, 0)
                seg:SetPoint("BOTTOMRIGHT", o.frame, "BOTTOMRIGHT", -x0, 0)
                seg:SetWidth(math.max(x1 - x0, 0.01))
                seg:Show()
                if db.showTicks and x1 < width - 1 and x1 - lastLine >= 2 then
                    usedLines = usedLines + 1
                    local line = GetTickLine(o, usedLines)
                    line:SetColorTexture(BarColor("tickColor", BAR_TICK_COLOR))
                    line:ClearAllPoints()
                    line:SetPoint("TOPRIGHT", o.frame, "TOPRIGHT", -x1, 0)
                    line:SetPoint("BOTTOMRIGHT", o.frame, "BOTTOMRIGHT", -x1, 0)
                    line:SetWidth(1)
                    line:Show()
                    lastLine = x1
                end
            end
        end
    end
    for i = usedSegments + 1, #o.segments do o.segments[i]:Hide() end
    for i = usedLines + 1, #o.ticks do o.ticks[i]:Hide() end

    o.frame:Show()

    -- a tick has taken life: the part of the bar it removed lights up briefly and is then gone.
    -- (When the bar disappears completely, e.g. because the enemy died, there is no effect.)
    if not simple and BAR_FLASH_SECONDS > 0 and o.prevGuid == guid and o.prevWidth
        and o.prevWidth - width >= 1 then
        StartGhost(o, o.prevWidth - width)
    end
    o.prevGuid, o.prevWidth = guid, width
end

-- Negative numbers (overkill) are shown in red. With the option "show current life" the text is
-- "current -> after the DoTs".
local function FormatRemaining(n, current)
    local after
    if n < 0 then
        after = string.format("|cffff3030%d|r", n)
    else
        after = string.format("|cffffffff%d|r", n)
    end
    if current and DotTrackerDB and DotTrackerDB.showCurrentLife then
        return string.format("|cffcccccc%d|r |cff999999->|r %s", current, after)
    end
    return after
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
        w.active = false
    end
    for _, o in pairs(overlays) do
        o.touched = false   -- set again by ShowDamageOnBar; bars that are not drawn again fade out
    end
    fallbackText:SetText("")
    fallbackSkull:Hide()
    fallbackTTD:SetText("")
    fallbackBar:Hide()

    local targetGUID = UnitGUID("target")
    local targetShown = false

    for i = 1, (db.useNameplates and 40 or 0) do
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
                    w.active = true
                    if not w.anchored then
                        w.fs:ClearAllPoints()
                        w.fs:SetPoint("BOTTOM", plate, "TOP", TextOffsets())
                        w.anchored = true
                    end
                    if db.showText then w.fs:SetText(FormatRemaining(remaining, hp)) end
                    if db.showSkull and lethal then w.skull:Show() end
                    if db.showBar then
                        ShowDamageOnBar(PlateHealthBar(plate), guid, hp, maxHP, total, remaining,
                            nil, guid == targetGUID and "HIGH" or "MEDIUM")
                    end
                    if db.showTimeToDeath and lethal then w.ttd:SetText(FormatTimeToDeath(TimeToDeath(guid, hp))) end
                    if guid == targetGUID then targetShown = true end
                end
            end
        end
    end

    -- damage bar on the health bar of the game's target frame
    if db.showBar and db.showTargetFrameBar and targetGUID and dots[targetGUID]
        and not UnitIsFriend("player", "target") then
        local bar = TargetFrameHealthBar or (TargetFrame and TargetFrame.healthbar)
        local hp, maxHP = UnitHealth("target"), UnitHealthMax("target")
        local remaining, _, total = Summary(targetGUID, hp)
        if bar and remaining then
            ShowDamageOnBar(bar, targetGUID, hp, maxHP, total, remaining, TARGET_FRAME_INSET, "HIGH")
        end
    end

    if targetGUID and not targetShown and dots[targetGUID] and not UnitIsFriend("player", "target") then
        local hp, maxHP = UnitHealth("target"), UnitHealthMax("target")
        local remaining, lethal, total = Summary(targetGUID, hp)
        if remaining then
            if db.showText then fallbackText:SetText(FormatRemaining(remaining, hp)) end
            if db.showSkull and lethal then fallbackSkull:Show() end
            if db.showTimeToDeath and lethal then
                fallbackTTD:SetText(FormatTimeToDeath(TimeToDeath(targetGUID, hp)))
            end
            -- own health bar with the damage bar, tick lines and glass effect (no border: inset 0)
            if db.showBar and maxHP and maxHP > 0 then
                fallbackBar:SetMinMaxValues(0, maxHP)
                fallbackBar:SetValue(hp)
                fallbackBar:Show()
                ShowDamageOnBar(fallbackBar, targetGUID, hp, maxHP, total, remaining, 0)
            end
        end
    end

    -- Everything that is not shown now is cut loose from the nameplates. Our regions must not stay
    -- anchored to a nameplate that is not in use: when an enemy changes its faction (mind control),
    -- the game rebuilds the nameplate and fails to measure regions that are connected to ours.
    for _, w in pairs(plateWidgets) do
        if not w.active and w.anchored then
            w.fs:ClearAllPoints()
            w.fs:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", 0, 0)
            w.anchored = false
        end
    end
    -- bars that were not drawn again (the enemy died, the DoTs ended): removed at once, without fade
    for _, o in pairs(overlays) do
        if not o.touched then
            o.frame:Hide()
            o.frame:ClearAllPoints()
            HideGhost(o)
            o.ghost:ClearAllPoints()
            o.prevGuid, o.prevWidth = nil, nil
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
            e = { ticks = 0, mine = mine, interval = info.interval, colorKey = info.colorKey, total = math.max(1, math.floor(duration / info.interval + 0.5)) }
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
-- The window has tabs; every entry below belongs to one tab (tab = index in TABS).
-- An entry with a "header" starts a new group with that title.
local TABS = { "Display", "Bar", "Colors", "Debuffs", "Layout", "Tracking" }

local OPTIONS = {
    -- Display: what is shown next to the enemy
    { tab = 1, key = "useNameplates",   header = "Where", label = "Show on the enemy nameplates (off = target display only)" },
    { tab = 1, key = "showText",        header = "Text above the enemy", label = "Show remaining HP after all DoTs" },
    { tab = 1, key = "showCurrentLife", label = "Also show current life (current -> after DoTs)" },
    { tab = 1, key = "showSkull",       header = "Skull", label = "Show skull icon when DoTs are lethal" },
    { tab = 1, key = "showTimeToDeath", label = "Show time to death on the skull" },
    -- Bar: the damage bar on the health bars
    { tab = 2, key = "showBar",         header = "Damage bar", label = "Show DoT damage on health bar" },
    { tab = 2, key = "showTargetFrameBar", label = "Also show the damage bar on the target frame" },
    { tab = 2, key = "simpleMode",      header = "Look", label = "Simple mode (one plain bar: no colors per debuff, ticks, glass, flash)" },
    { tab = 2, key = "showTicks",       label = "Show lines between the ticks" },
    { tab = 2, key = "showGlass",       label = "Glass effect on the damage bar" },
    -- Tracking: which DoTs and enemies count
    { tab = 6, key = "trackOthers",     header = "Which DoTs count", label = "Track DoTs of other players (summed up)" },
    { tab = 6, key = "includeCrit",     label = "Include expected crit damage (DoT crits)" },
    { tab = 6, key = "onlyAttacked",    header = "Which enemies are shown", label = "Track only enemies I attacked" },
}

local SLIDERS = {
    { tab = 5, key = "textOffsetX", header = "Position of text and skull", label = "Horizontal offset (left <-> right)", min = -200, max = 200 },
    { tab = 5, key = "textOffsetY", label = "Vertical offset (down <-> up)", min = -100, max = 100 },
    { tab = 5, key = "textSize",    header = "Size", label = "Text size", min = 8, max = 48 },
    { tab = 5, key = "skullSize",   label = "Skull size", min = 8, max = 96 },
}

local COLORS = {
    { tab = 3, key = "colorSimple",    default = BAR_COLOR_SIMPLE,    header = "Damage bar colors", label = "Bar color in simple mode" },
    { tab = 3, key = "tickColor",      default = BAR_TICK_COLOR,      label = "Tick line color" },
    { tab = 3, key = "ttdColor",       default = TTD_COLOR,           header = "Skull", label = "Time to death color" },
}

-- Opens the game's color picker (with opacity) for tbl[key] (default: DotTrackerDB[key]);
-- onChanged runs on every change
local function ChooseColor(key, onChanged, tbl)
    tbl = tbl or DotTrackerDB
    local c = tbl[key]
    local prev = { c[1], c[2], c[3], c[4] }

    local function Set(r, g, b, a)
        tbl[key] = { r, g, b, a }
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
    panel:SetSize(440, 410)
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

    -- one page per tab; the widgets are placed from top to bottom with a cursor per page
    local pages, tabButtons, cursor = {}, {}, {}

    local function ShowTab(n)
        for i, page in ipairs(pages) do
            page:SetShown(i == n)
            if i == n then tabButtons[i]:LockHighlight() else tabButtons[i]:UnlockHighlight() end
        end
    end

    for i, name in ipairs(TABS) do
        local page = CreateFrame("Frame", nil, panel)
        page:SetPoint("TOPLEFT", 16, -78)
        page:SetPoint("BOTTOMRIGHT", -16, 60)
        pages[i] = page
        cursor[i] = 4

        local tab = CreateFrame("Button", "DotTrackerTab" .. i, panel, "UIPanelButtonTemplate")
        tab:SetSize(66, 22)
        tab:SetPoint("TOPLEFT", 20 + (i - 1) * 68, -48)
        tab:SetText(name)
        tab:SetScript("OnClick", function() ShowTab(i) end)
        tabButtons[i] = tab
    end

    local function AddHeader(entry)
        if not entry.header then return end
        local fs = pages[entry.tab]:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        fs:SetPoint("TOPLEFT", 4, -cursor[entry.tab])
        fs:SetText(entry.header)
        cursor[entry.tab] = cursor[entry.tab] + 22
    end

    local checks, sliders = {}, {}   -- by option key, refreshed by "Reset all"

    for i, opt in ipairs(OPTIONS) do
        AddHeader(opt)
        local name = "DotTrackerCheck" .. i
        local cb = CreateFrame("CheckButton", name, pages[opt.tab], "UICheckButtonTemplate")
        checks[opt.key] = cb
        cb:SetPoint("TOPLEFT", 8, -cursor[opt.tab])
        cursor[opt.tab] = cursor[opt.tab] + 26
        _G[name .. "Text"]:SetText(opt.label)
        cb:SetChecked(DotTrackerDB[opt.key])
        cb:SetScript("OnClick", function(self)
            DotTrackerDB[opt.key] = self:GetChecked() and true or false
            Update()
        end)
    end

    for i, s in ipairs(SLIDERS) do
        AddHeader(s)
        local name = "DotTrackerSlider" .. i
        local sl = CreateFrame("Slider", name, pages[s.tab], "OptionsSliderTemplate")
        sliders[s.key] = sl
        sl:SetPoint("TOPLEFT", 14, -cursor[s.tab] - 16)
        cursor[s.tab] = cursor[s.tab] + 48
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

    -- color fields (click opens the color picker with opacity)
    local swatchTextures = {}
    local debuffSwatches = {}   -- { texture, color key } for the Debuffs tab
    local function RefreshSwatches()
        for i, c in ipairs(COLORS) do
            local v = DotTrackerDB[c.key]
            swatchTextures[i]:SetColorTexture(v[1], v[2], v[3], 1)
        end
        for _, d in ipairs(debuffSwatches) do
            local r, g, b = DebuffColor(d[2])
            d[1]:SetColorTexture(r, g, b, 1)
        end
    end
    for i, c in ipairs(COLORS) do
        AddHeader(c)
        local sw = CreateFrame("Button", nil, pages[c.tab])
        sw:SetSize(22, 22)
        sw:SetPoint("TOPLEFT", 12, -cursor[c.tab])
        cursor[c.tab] = cursor[c.tab] + 28
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

    -- Debuffs tab: one color field per debuff, in two columns (the color of its ticks in the bar)
    local debuffTab = 4
    AddHeader({ tab = debuffTab, header = "Color of the ticks of each debuff" })
    local rows = math.ceil(#DOT_LOOKUP / 2)
    for i, d in ipairs(DOT_LOOKUP) do
        local colorKey = d[2]
        local column, row = math.floor((i - 1) / rows), (i - 1) % rows
        local sw = CreateFrame("Button", nil, pages[debuffTab])
        sw:SetSize(18, 18)
        sw:SetPoint("TOPLEFT", 12 + column * 200, -cursor[debuffTab] - row * 22)
        local border = sw:CreateTexture(nil, "BACKGROUND")
        border:SetAllPoints()
        border:SetColorTexture(1, 1, 1, 1)
        local tex = sw:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("TOPLEFT", 2, -2)
        tex:SetPoint("BOTTOMRIGHT", -2, 2)
        debuffSwatches[#debuffSwatches + 1] = { tex, colorKey }
        local label = sw:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        label:SetPoint("LEFT", sw, "RIGHT", 6, 0)
        label:SetText((GetSpellInfo(d[1])) or colorKey)
        sw:SetScript("OnClick", function()
            local saved = DotTrackerDB.debuffColors
            if not saved[colorKey] then
                local c = DEBUFF_COLORS[colorKey] or BAR_COLOR_SIMPLE
                saved[colorKey] = { c[1], c[2], c[3], c[4] }
            end
            ChooseColor(colorKey, function() RefreshSwatches(); Update() end, saved)
        end)
    end
    RefreshSwatches()

    -- "Reset colors" sits on the Colors tab, below the color fields
    local colorsTab = COLORS[1].tab
    local resetBtn = CreateFrame("Button", "DotTrackerResetColorsButton", pages[colorsTab], "UIPanelButtonTemplate")
    resetBtn:SetSize(150, 24)
    resetBtn:SetPoint("TOPLEFT", 8, -cursor[colorsTab] - 8)
    resetBtn:SetText("Reset colors")
    resetBtn:SetScript("OnClick", function()
        for _, c in ipairs(COLORS) do
            DotTrackerDB[c.key] = { c.default[1], c.default[2], c.default[3], c.default[4] }
        end
        DotTrackerDB.debuffColors = {}   -- back to DEBUFF_COLORS
        RefreshSwatches()
        Update()
    end)

    -- same as /dt test: fake DoTs on your target (removed after STALE_SECONDS)
    local testBtn = CreateFrame("Button", "DotTrackerTestButton", panel, "UIPanelButtonTemplate")
    testBtn:SetSize(165, 24)
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
        DotTrackerDB.debuffColors = {}   -- back to DEBUFF_COLORS
        for key, cb in pairs(checks) do cb:SetChecked(DotTrackerDB[key]) end
        for key, sl in pairs(sliders) do sl:SetValue(DotTrackerDB[key]) end
        RefreshSwatches()
        ApplyLayout()
        Update()
    end

    -- needs two clicks within 4 seconds, so a single misclick cannot wipe the settings
    local resetAllBtn = CreateFrame("Button", "DotTrackerResetAllButton", panel, "UIPanelButtonTemplate")
    resetAllBtn:SetSize(165, 24)
    resetAllBtn:SetPoint("BOTTOMRIGHT", -24, 22)
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

    ShowTab(1)
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
frame:RegisterEvent("UNIT_FACTION")   -- mind control starts/ends: cut loose from the nameplate at once

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