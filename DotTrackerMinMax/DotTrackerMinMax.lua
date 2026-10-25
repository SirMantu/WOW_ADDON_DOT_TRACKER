local ADDON_NAME = ...
print("DotTracker loaded, this Addon will only work if healhbars of enemies are activated.")

-- ===== Settings =====
local STALE_SECONDS = 30                         -- discard DoT data without ticks
local SKULL_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local SKULL_SIZE = 32
local BAR_COLOR = { 0, 0, 0, 0.85 }              -- r, g, b, alpha of the damage segment (black)
local BOLD_FONT = (GameFontNormalLarge:GetFont()) -- default font of your client
local BOLD_SIZE = 20
local CRIT_MULTIPLIER = 1.5                      -- placeholder: adjust to the crit damage multiplier of Forever

local DEFAULTS = {
    showText = true,
    showSkull = true,
    showBar = true,
    includeCrit = false,   -- add expected crit damage to the prediction
    minimapAngle = 215,
}

local playerGUID
local optionsPanel
local DOT_INFO = {}        -- by localized spell name
local dots = {}            -- dots[targetGUID][spellName] = { base, tick, ticks, total, last, school, lastCrit, crits }
DT_dots = dots             -- for /dump DT_dots

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
fallbackText:SetPoint("CENTER")

local fallbackSkull = frame:CreateTexture(nil, "OVERLAY")
fallbackSkull:SetTexture(SKULL_TEXTURE)
fallbackSkull:SetSize(SKULL_SIZE, SKULL_SIZE)
fallbackSkull:SetPoint("BOTTOM", fallbackText, "TOP", 0, 2)
fallbackSkull:Hide()

-- ===== Text and skull on nameplates =====
local plateWidgets = {}
local function GetPlateWidgets(plate)
    local w = plateWidgets[plate]
    if not w then
        local holder = CreateFrame("Frame", nil, plate)
        local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        fs:SetFont(BOLD_FONT, BOLD_SIZE, "THICKOUTLINE")
        fs:SetPoint("BOTTOM", plate, "TOP", 0, 4)
        local skull = holder:CreateTexture(nil, "OVERLAY")
        skull:SetTexture(SKULL_TEXTURE)
        skull:SetSize(SKULL_SIZE, SKULL_SIZE)
        skull:SetPoint("BOTTOM", fs, "TOP", 0, 2)
        skull:Hide()
        w = { fs = fs, skull = skull }
        plateWidgets[plate] = w
    end
    return w
end

-- ===== Damage segment on the health bar =====
local overlays = {}   -- overlays[healthBar] = texture
local function GetOverlay(healthBar)
    local t = overlays[healthBar]
    if not t then
        t = healthBar:CreateTexture(nil, "OVERLAY", nil, 2)
        t:SetColorTexture(BAR_COLOR[1], BAR_COLOR[2], BAR_COLOR[3], BAR_COLOR[4])
        t:Hide()
        overlays[healthBar] = t
    end
    return t
end

local function ShowDamageOnBar(plate, hp, maxHP, total)
    local uf = plate.UnitFrame or plate.unitFrame
    local healthBar = uf and uf.healthBar
    if not healthBar or not hp or not maxHP or maxHP <= 0 or maxHP == 100 then return end
    local fill = healthBar:GetStatusBarTexture()
    if not fill then return end

    local width = healthBar:GetWidth() * math.min(total, hp) / maxHP
    if width < 1 then return end

    local t = GetOverlay(healthBar)
    t:ClearAllPoints()
    t:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
    t:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
    t:SetWidth(width)
    t:Show()
end

-- ===== DoT data =====
local function Register(id, interval, fallbackDuration)
    local name = GetSpellInfo(id)
    if name then
        DOT_INFO[name] = { interval = interval, duration = fallbackDuration }
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
    if DotTrackerDB and DotTrackerDB.includeCrit then
        perTick = perTick * (1 + SpellCritChance(e.school) * (CRIT_MULTIPLIER - 1))
    end
    return perTick
end

-- Returns remaining HP after all DoTs, whether that is lethal, and the total DoT damage
local function Summary(guid, hp)
    local d = dots[guid]
    if not d or not hp then return nil end
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
end

local function Update()
    if not DotTrackerDB then return end
    local db = DotTrackerDB

    for _, w in pairs(plateWidgets) do
        w.fs:SetText("")
        w.skull:Hide()
    end
    for _, t in pairs(overlays) do t:Hide() end
    fallbackText:SetText("")
    fallbackSkull:Hide()

    local targetGUID = UnitGUID("target")
    local targetShown = false

    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
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

    if targetGUID and not targetShown and dots[targetGUID] then
        local remaining, lethal = Summary(targetGUID, UnitHealth("target"))
        if remaining then
            if db.showText then fallbackText:SetText(FormatRemaining(remaining)) end
            if db.showSkull and lethal then fallbackSkull:Show() end
        end
    end
end

-- ===== Combat log =====
local function OnCombatLog()
    local _, subevent, _, sourceGUID, _, _, _, destGUID, _, _, _, _, spellName, _, amount,
          _, school, _, _, _, critical = CombatLogGetCurrentEventInfo()

    if subevent == "UNIT_DIED" then
        dots[destGUID] = nil
        return
    end
    if sourceGUID ~= playerGUID then return end

    local info = DOT_INFO[spellName]
    if not info then return end
    if debug then print("CLEU:", subevent, spellName, amount, "crit:", critical) end

    if subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REMOVED" then
        -- new application or expired: start over
        if dots[destGUID] then dots[destGUID][spellName] = nil end

    elseif subevent == "SPELL_AURA_REFRESH" or subevent == "SPELL_AURA_REFRESHED" then
        -- recast while active: full duration again, keep last known tick damage
        local e = dots[destGUID] and dots[destGUID][spellName]
        if e then
            local duration = AuraDuration(destGUID, spellName) or info.duration
            e.ticks = 0
            e.total = math.max(1, math.floor(duration / info.interval + 0.5))
            e.last = GetTime()
        end

    elseif subevent == "SPELL_PERIODIC_DAMAGE" then
        dots[destGUID] = dots[destGUID] or {}
        local e = dots[destGUID][spellName]
        if not e then
            local duration = AuraDuration(destGUID, spellName) or info.duration
            e = { ticks = 0, total = math.max(1, math.floor(duration / info.interval + 0.5)) }
            dots[destGUID][spellName] = e
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
}

local function BuildOptionsPanel()
    local panel = CreateFrame("Frame", "DotTrackerOptions", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(360, 60 + #OPTIONS * 28)
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
        if arg1 == ADDON_NAME then InitDB() end
        return
    elseif event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        Register(172, 3, 12)     -- Corruption
        Register(980, 2, 24)     -- Curse of Agony
        Register(348, 3, 15)     -- Immolate (DoT part)
        Register(18265, 3, 30)   -- Siphon Life
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