local ADDON = ...
local GCD_SPELL = 61304 -- GCD dummy spell, whitelisted (non-secret) in 12.0+
local TEX = "Interface\\Buttons\\WHITE8x8"

local COLOR_GCD   = { 1.0, 0.75, 0.15 }
local COLOR_QUEUE = { 0.2, 0.9, 0.3 }  -- inside spell queue window, press now

local layoutDefaults = {
    point = "CENTER", relPoint = "CENTER", x = 0, y = -140,
    width = 200, height = 8,
}
local prefDefaults = {
    locked = true,
    showIdle = false, -- show empty bar in combat when GCD is ready
}

local db
local endTime, total, queueWindow = 0, 1, 0.4
local gcdSecret = false
local curColor
local secretWarned = false

-- GCD idle tracking: merge busy intervals (GCDs, casts, channels) and sum the gaps
local MIN_FIGHT = 10 -- seconds; shorter fights aren't reported
local combatStart -- nil when out of combat
local winStart, busyUntil, idle = nil, 0, 0

local function Print(msg)
    print("|cffffcc00GCDBar:|r " .. msg)
end

local function AnySecret(...)
    if not issecretvalue then return false end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return true end
    end
    return false
end

local function MarkBusy(s, e)
    if not combatStart then return end
    if not winStart then
        winStart = math.max(s, combatStart)
        busyUntil, idle = winStart, 0
    end
    if s > busyUntil then idle = idle + s - busyUntil end
    if e > busyUntil then busyUntil = e end
end

local function MarkCast()
    if not combatStart then return end
    local _, _, _, s, e = UnitCastingInfo("player")
    if not s then _, _, _, s, e = UnitChannelInfo("player") end
    if not s or AnySecret(s, e) then return end
    MarkBusy(s / 1000, e / 1000)
end

-- cast ended early (interrupt, cancel): drop the predicted remainder,
-- then re-mark any cast that already started (stop/start can arrive out of order)
local function TrimBusy()
    busyUntil = math.min(busyUntil, math.max(GetTime(), endTime))
    MarkCast()
end

-- read the GCD into endTime/total and feed the tracker; true while it is running
local function ReadGCD()
    local cd = C_Spell.GetSpellCooldown(GCD_SPELL)
    gcdSecret = cd and AnySecret(cd.startTime, cd.duration, cd.isEnabled, cd.modRate)
    if gcdSecret and not secretWarned then
        secretWarned = true
        Print("GCD values are secret on this patch, bar disabled.")
    end
    if not cd or gcdSecret or not cd.isEnabled or cd.duration == 0 then
        endTime = 0
        return false
    end
    total = cd.duration / (cd.modRate or 1)
    endTime = cd.startTime + total
    MarkBusy(cd.startTime, endTime)
    return true
end

local function PrintFight(f)
    Print(("%.1f%% GCD idle (%d:%02d)"):format(f.pct, math.floor(f.len / 60), math.floor(f.len % 60)))
end

local function StartFight()
    combatStart, winStart = GetTime(), nil
    MarkCast()
    ReadGCD()
end

local function EndFight()
    combatStart = nil
    if not winStart then return end
    local len = busyUntil - winStart
    if len < MIN_FIGHT then return end
    db.lastFight = { pct = idle / len * 100, len = len }
    PrintFight(db.lastFight)
end

local bar = CreateFrame("StatusBar", "GCDBarFrame", UIParent)
bar:SetStatusBarTexture(TEX)
bar:SetMinMaxValues(0, 1)
bar:SetValue(0)
bar:SetFrameStrata("HIGH")
bar:SetClampedToScreen(true)
bar:SetMovable(true)
bar:Hide()

local bg = bar:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0, 0, 0, 0.6)

local spark = bar:CreateTexture(nil, "OVERLAY")
spark:SetColorTexture(1, 1, 1, 0.9)
spark:SetWidth(2)
spark:SetPoint("CENTER", bar:GetStatusBarTexture(), "RIGHT")

local queueTick = bar:CreateTexture(nil, "OVERLAY")
queueTick:SetColorTexture(1, 1, 1, 0.5)
queueTick:SetWidth(1)

local label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
label:SetPoint("BOTTOM", bar, "TOP", 0, 2)
label:SetText("GCDBar - drag to move, /gcd lock when done")
label:Hide()

local function SetColor(c)
    if c == curColor then return end
    curColor = c
    bar:SetStatusBarColor(c[1], c[2], c[3])
end

local function ApplyLayout()
    bar:ClearAllPoints()
    bar:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    bar:SetSize(db.width, db.height)
    spark:SetHeight(db.height + 4)
    queueTick:SetHeight(db.height)
end

local function Idle()
    bar:SetScript("OnUpdate", nil)
    if not db.locked then return end
    if db.showIdle and UnitAffectingCombat("player") then
        bar:SetValue(0)
        spark:Hide()
        queueTick:Hide()
        bar:Show()
    else
        bar:Hide()
    end
end

-- bar drains from full to empty; empty = GCD ready
local function OnUpdate(self)
    local remaining = endTime - GetTime()
    if remaining <= 0 then
        Idle()
        return
    end
    self:SetValue(remaining / total)
    SetColor(remaining <= queueWindow and COLOR_QUEUE or COLOR_GCD)
end

-- draw the bar from the last ReadGCD() state
local function Refresh()
    if not db or not db.locked then return end
    if gcdSecret then
        bar:Hide()
        return
    end
    if endTime <= GetTime() then
        Idle()
        return
    end

    queueWindow = (tonumber(GetCVar("SpellQueueWindow")) or 400) / 1000

    local qPct = math.min(queueWindow / total, 1)
    queueTick:SetPoint("CENTER", bar, "LEFT", bar:GetWidth() * qPct, 0)
    queueTick:Show()
    spark:Show()

    bar:Show()
    bar:SetScript("OnUpdate", OnUpdate)
    OnUpdate(bar)
end

local function SavePosition()
    local point, _, relPoint, x, y = bar:GetPoint()
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function SetLocked(locked)
    db.locked = locked
    bar:EnableMouse(not locked)
    bar:SetScript("OnUpdate", nil)
    if locked then
        bar:RegisterForDrag()
        label:Hide()
        Refresh()
    else
        bar:RegisterForDrag("LeftButton")
        SetColor(COLOR_GCD)
        bar:SetValue(1)
        spark:Hide()
        queueTick:Hide()
        label:Show()
        bar:Show()
    end
end

bar:SetScript("OnDragStart", function(self) self:StartMoving() end)
bar:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SavePosition()
end)

bar:RegisterEvent("ADDON_LOADED")
bar:RegisterEvent("SPELL_UPDATE_COOLDOWN")
bar:RegisterEvent("PLAYER_REGEN_DISABLED")
bar:RegisterEvent("PLAYER_REGEN_ENABLED")

local CAST_EVENTS = {
    UNIT_SPELLCAST_START = MarkCast, UNIT_SPELLCAST_DELAYED = MarkCast,
    UNIT_SPELLCAST_CHANNEL_START = MarkCast, UNIT_SPELLCAST_CHANNEL_UPDATE = MarkCast,
    UNIT_SPELLCAST_EMPOWER_START = MarkCast, UNIT_SPELLCAST_EMPOWER_UPDATE = MarkCast,
    UNIT_SPELLCAST_STOP = TrimBusy, UNIT_SPELLCAST_INTERRUPTED = TrimBusy,
    UNIT_SPELLCAST_CHANNEL_STOP = TrimBusy, UNIT_SPELLCAST_EMPOWER_STOP = TrimBusy,
}
for event in pairs(CAST_EVENTS) do bar:RegisterUnitEvent(event, "player") end

bar:SetScript("OnEvent", function(self, event, arg1)
    if CAST_EVENTS[event] then
        CAST_EVENTS[event]()
        return
    end
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        GCDBarDB = GCDBarDB or {}
        db = GCDBarDB
        for _, defaults in ipairs({ layoutDefaults, prefDefaults }) do
            for k, v in pairs(defaults) do
                if db[k] == nil then db[k] = v end
            end
        end
        self:UnregisterEvent("ADDON_LOADED")
        if UnitAffectingCombat("player") then -- /reload mid-fight
            StartFight()
        else
            ReadGCD()
        end
        ApplyLayout()
        SetLocked(db.locked)
        return
    elseif event == "PLAYER_REGEN_DISABLED" then
        StartFight()
    elseif event == "PLAYER_REGEN_ENABLED" then
        EndFight()
    else
        ReadGCD()
    end
    Refresh()
end)

local HELP = {
    "/gcd unlock - show bar, drag to move",
    "/gcd lock - lock position",
    "/gcd size <width> <height>",
    "/gcd idle - toggle empty bar while in combat",
    "/gcd reset - default position and size",
    "/gcd stats - GCD idle % of the last fight",
}

SLASH_GCDBAR1 = "/gcd"
SLASH_GCDBAR2 = "/gcdbar"
SlashCmdList.GCDBAR = function(msg)
    local cmd, a, b = strtrim(msg or ""):lower():match("^(%S*)%s*(%S*)%s*(%S*)")
    if cmd == "unlock" then
        SetLocked(false)
    elseif cmd == "lock" then
        SetLocked(true)
    elseif cmd == "size" then
        local w, h = tonumber(a), tonumber(b)
        if not w or not h or w <= 0 or h <= 0 then
            Print("/gcd size <width> <height>")
            return
        end
        db.width, db.height = w, h
        ApplyLayout()
        Refresh()
    elseif cmd == "idle" then
        db.showIdle = not db.showIdle
        Print("idle bar " .. (db.showIdle and "on" or "off"))
        Refresh()
    elseif cmd == "stats" then
        if db.lastFight then
            PrintFight(db.lastFight)
        else
            Print("no fight recorded yet")
        end
    elseif cmd == "reset" then
        for k, v in pairs(layoutDefaults) do db[k] = v end
        ApplyLayout()
        Refresh()
    else
        Print("v" .. (C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"))
        for _, line in ipairs(HELP) do Print(line) end
    end
end
