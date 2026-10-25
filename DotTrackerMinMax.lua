local ADDON_NAME = ...

-- ===== Settings =====
local STALE_SECONDS = 30                         -- discard DoT data without ticks
local SKULL_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local SKULL_SIZE = 32
local BAR_COLOR = { 0, 0, 0, 0.85 }              -- r, g, b, alpha of the damage segment (black)
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
        if DotTrackerDB[k] == nil then DotTrackerDB[k] = v end
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
        w = { fs = fs, skull = skull }
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
    for plate, w in pairs(plateWidgets) do
        w.fs:ClearAllPoints()
        w.fs:SetPoint("BOTTOM", plate, "TOP", x, y)
        w.fs:SetFont(BOLD_FONT, textSize, "THICKOUTLINE")
        w.skull:SetSize(skullSize, skullSize)
    end
end

-- ===== Damage segment on the health bar =====
-- overlays[healthBar] = { tex = texture }
-- The texture lives on our own frame and is anchored to the fill texture of the health bar.
local overlays = {}
local overlayHost = CreateFrame("Frame", nil, UIParent)
overlayHost:SetFrameStrata("MEDIUM")
overlayHost:SetFrameLevel(49)
local function GetOverlay(healthBar)
    local o = overlays[healthBar]
    if not o then
        local t = overlayHost:CreateTexture(nil, "OVERLAY", nil, 2)
        t:SetColorTexture(BAR_COLOR[1], BAR_COLOR[2], BAR_COLOR[3], BAR_COLOR[4])
        t:Hide()
        o = { tex = t }
        overlays[healthBar] = o
    end
    return o
end

local function ShowDamageOnBar(plate, hp, maxHP, total)
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

    local o = GetOverlay(healthBar)
    o.tex:ClearAllPoints()
    o.tex:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
    o.tex:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
    o.tex:SetWidth(width)
    o.tex:Show()
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
    end
    for _, o in pairs(overlays) do
        o.tex:Hide()
    end
    fallbackText:SetText("")
    fallbackSkull:Hide()

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
                    if db.showBar then ShowDamageOnBar(plate, hp, maxHP, total) end
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
            e = { ticks = 0, mine = mine, total = math.max(1, math.floor(duration / info.interval + 0.5)) }
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

local function BuildOptionsPanel()
    local panel = CreateFrame("Frame", "DotTrackerOptions", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(360, 100 + #OPTIONS * 28 + #SLIDERS * 50)
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

    for i, opt in ipairs(OPTIONS) do
        local name = "DotTrackerCheck" .. i
        local cb = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
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

    -- same as /dt test: fake DoTs on your target (removed after STALE_SECONDS)
    local testBtn = CreateFrame("Button", "DotTrackerTestButton", panel, "UIPanelButtonTemplate")
    testBtn:SetSize(200, 24)
    testBtn:SetPoint("BOTTOM", 0, 22)
    testBtn:SetText("Test (fake DoTs on target)")
    testBtn:SetScript("OnClick", RunTest)

    tinsert(UISpecialFrames, "DotTrackerOptions")   -- ESC closes the window
    return panel
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