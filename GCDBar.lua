local ADDON = ...
local GCD_SPELL = 61304 -- GCD dummy spell, whitelisted (non-secret) in 12.0+
local TEX = "Interface\\Buttons\\WHITE8x8"

local COLOR_GCD = { 1.0, 0.75, 0.15 }
-- inside spell queue window, press now
local QUEUE_COLORS = {
    normal     = { 0.2, 0.9, 0.3 },
    colorblind = { 0.2, 0.6, 1.0 },
}
local colorQueue = QUEUE_COLORS.normal

local SIZE_LIMITS = { minW = 20, maxW = 1000, minH = 2, maxH = 100 }

local layoutDefaults = {
    point = "CENTER", relPoint = "CENTER", x = 0, y = -140,
    width = 200, height = 8,
}
local prefDefaults = {
    locked = true,
    showIdle = false,    -- show empty bar in combat when GCD is ready
    report = true,       -- print the idle % in chat after each fight
    reportMin = 10,      -- seconds; shorter fights aren't printed
    alpha = 1,
    colorblind = false,
    combatOnly = false,  -- hide the bar out of combat
    hideVehicle = false,
    hideMounted = false,
}

local db
local endTime, total, queueWindow = 0, 1, 0.4
local gcdSecret = false
local curColor
local secretWarned = false
local settingsCategory

-- GCD idle tracking: merge busy intervals (GCDs, casts, channels) and sum the gaps
local MIN_FIGHT = 10 -- seconds; shorter fights aren't recorded
local HISTORY_MAX = 10
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

local function ReadQueueWindow()
    queueWindow = (tonumber(GetCVar("SpellQueueWindow")) or 400) / 1000
end

local function FormatFight(f)
    return ("%.1f%% GCD idle (%d:%02d)"):format(f.pct, math.floor(f.len / 60), math.floor(f.len % 60))
end

local function PrintStats()
    local history = db.history
    local n = #history
    if n == 0 then
        Print("no fight recorded yet")
        return
    end
    Print("last: " .. FormatFight(history[n]))
    if n < 2 then return end
    local sumIdle, sumLen, best = 0, 0, history[1]
    for _, f in ipairs(history) do
        sumIdle = sumIdle + f.pct * f.len
        sumLen = sumLen + f.len
        if f.pct < best.pct then best = f end
    end
    Print(("average of %d: %.1f%% idle"):format(n, sumIdle / sumLen))
    Print("best: " .. FormatFight(best))
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
    local fight = { pct = idle / len * 100, len = len }
    table.insert(db.history, fight)
    while #db.history > HISTORY_MAX do table.remove(db.history, 1) end
    if db.report and len >= db.reportMin then
        Print(FormatFight(fight))
    end
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

local function ApplyAppearance()
    bar:SetAlpha(db.alpha)
    colorQueue = QUEUE_COLORS[db.colorblind and "colorblind" or "normal"]
    curColor = nil
end

-- true when the user's visibility rules say the bar should stay hidden
local function Suppressed()
    if not db.locked then return false end
    if db.combatOnly and not UnitAffectingCombat("player") then return true end
    if db.hideVehicle and UnitInVehicle("player") then return true end
    if db.hideMounted and IsMounted() then return true end
    return false
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
    SetColor(remaining <= queueWindow and colorQueue or COLOR_GCD)
end

-- draw the bar from the last ReadGCD() state
local function Refresh()
    if not db or not db.locked then return end
    if gcdSecret or Suppressed() then
        bar:SetScript("OnUpdate", nil)
        bar:Hide()
        return
    end
    if endTime <= GetTime() then
        Idle()
        return
    end

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

local function ApplyAll()
    ApplyLayout()
    ApplyAppearance()
    Refresh()
end

-- Settings panel; the slash commands remain the fallback if this API shifts
local function BuildSettings()
    local category = Settings.RegisterVerticalLayoutCategory("GCDBar")

    local function Add(key, name, tooltip, slider)
        local setting = Settings.RegisterAddOnSetting(category, "GCDBar_" .. key, key, db,
            type(prefDefaults[key] ~= nil and prefDefaults[key] or layoutDefaults[key]), name,
            prefDefaults[key] ~= nil and prefDefaults[key] or layoutDefaults[key])
        if slider then
            local opts = Settings.CreateSliderOptions(slider[1], slider[2], slider[3])
            opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
            Settings.CreateSlider(category, setting, opts, tooltip)
        else
            Settings.CreateCheckbox(category, setting, tooltip)
        end
        setting:SetValueChangedCallback(ApplyAll)
    end

    Add("width", "Width", "Bar width in pixels.", { SIZE_LIMITS.minW, SIZE_LIMITS.maxW, 5 })
    Add("height", "Height", "Bar height in pixels.", { SIZE_LIMITS.minH, SIZE_LIMITS.maxH, 1 })
    Add("alpha", "Opacity", "Bar opacity.", { 0.1, 1, 0.05 })
    Add("colorblind", "Color-blind queue color", "Use blue instead of green inside the spell queue window.")
    Add("showIdle", "Show empty bar in combat", "Keep the bar visible in combat while the GCD is ready.")
    Add("combatOnly", "Only show in combat", "Hide the bar out of combat.")
    Add("hideVehicle", "Hide in vehicles", "Hide the bar while you are in a vehicle.")
    Add("hideMounted", "Hide while mounted", "Hide the bar while you are mounted.")
    Add("report", "Print GCD idle % after fights", "Print a line in chat when a fight ends.")
    Add("reportMin", "Minimum fight length to print (sec)",
        "Fights shorter than this are recorded but not printed.", { 10, 300, 5 })

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

bar:SetScript("OnDragStart", function(self) self:StartMoving() end)
bar:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SavePosition()
end)

bar:RegisterEvent("ADDON_LOADED")
bar:RegisterEvent("PLAYER_ENTERING_WORLD")
bar:RegisterEvent("SPELL_UPDATE_COOLDOWN")
bar:RegisterEvent("PLAYER_REGEN_DISABLED")
bar:RegisterEvent("PLAYER_REGEN_ENABLED")
bar:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
bar:RegisterEvent("CVAR_UPDATE")

local CAST_EVENTS = {
    UNIT_SPELLCAST_START = MarkCast, UNIT_SPELLCAST_DELAYED = MarkCast,
    UNIT_SPELLCAST_CHANNEL_START = MarkCast, UNIT_SPELLCAST_CHANNEL_UPDATE = MarkCast,
    UNIT_SPELLCAST_EMPOWER_START = MarkCast, UNIT_SPELLCAST_EMPOWER_UPDATE = MarkCast,
    UNIT_SPELLCAST_STOP = TrimBusy, UNIT_SPELLCAST_INTERRUPTED = TrimBusy,
    UNIT_SPELLCAST_CHANNEL_STOP = TrimBusy, UNIT_SPELLCAST_EMPOWER_STOP = TrimBusy,
}
for event in pairs(CAST_EVENTS) do bar:RegisterUnitEvent(event, "player") end
bar:RegisterUnitEvent("UNIT_ENTERED_VEHICLE", "player")
bar:RegisterUnitEvent("UNIT_EXITED_VEHICLE", "player")

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
        db.history = db.history or {}
        if db.lastFight then -- pre-1.1 saved data
            if #db.history == 0 then table.insert(db.history, db.lastFight) end
            db.lastFight = nil
        end
        self:UnregisterEvent("ADDON_LOADED")
        ReadQueueWindow()
        if UnitAffectingCombat("player") then -- /reload mid-fight
            StartFight()
        else
            ReadGCD()
        end
        ApplyLayout()
        ApplyAppearance()
        SetLocked(db.locked)
        pcall(BuildSettings)
        return
    end
    if not db then return end
    if event == "CVAR_UPDATE" then
        if arg1 ~= "SpellQueueWindow" then return end
        ReadQueueWindow()
        return
    elseif event == "PLAYER_REGEN_DISABLED" then
        StartFight()
    elseif event == "PLAYER_REGEN_ENABLED" then
        EndFight()
    elseif event == "SPELL_UPDATE_COOLDOWN" or event == "PLAYER_ENTERING_WORLD" then
        ReadGCD()
    end
    Refresh()
end)

local HELP = {
    "/gcd unlock - show bar, drag to move",
    "/gcd lock - lock position",
    "/gcd size <width> <height>",
    "/gcd alpha <0.1-1>",
    "/gcd colorblind - toggle blue queue color",
    "/gcd idle - toggle empty bar while in combat",
    "/gcd hide <combat|vehicle|mounted> - toggle a visibility rule",
    "/gcd report [on|off|<seconds>] - chat report after fights",
    "/gcd reset - default position and size",
    "/gcd stats [reset] - GCD idle % of recent fights",
    "/gcd options - open the settings panel",
}

local HIDE_RULES = { combat = "combatOnly", vehicle = "hideVehicle", mounted = "hideMounted" }

local function OnOff(v) return v and "on" or "off" end

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
        db.width = math.max(SIZE_LIMITS.minW, math.min(SIZE_LIMITS.maxW, w))
        db.height = math.max(SIZE_LIMITS.minH, math.min(SIZE_LIMITS.maxH, h))
        Print(("size %d x %d"):format(db.width, db.height))
        ApplyAll()
    elseif cmd == "alpha" then
        local v = tonumber(a)
        if not v then
            Print("/gcd alpha <0.1-1>")
            return
        end
        db.alpha = math.max(0.1, math.min(1, v))
        Print(("alpha %.2f"):format(db.alpha))
        ApplyAll()
    elseif cmd == "colorblind" then
        db.colorblind = not db.colorblind
        Print("color-blind queue color " .. OnOff(db.colorblind))
        ApplyAll()
    elseif cmd == "idle" then
        db.showIdle = not db.showIdle
        Print("idle bar " .. OnOff(db.showIdle))
        Refresh()
    elseif cmd == "hide" then
        local key = HIDE_RULES[a]
        if not key then
            Print("/gcd hide <combat|vehicle|mounted>")
            return
        end
        db[key] = not db[key]
        Print(("hide rule '%s' %s"):format(a, OnOff(db[key])))
        Refresh()
    elseif cmd == "report" then
        if a == "on" or a == "off" then
            db.report = a == "on"
        elseif tonumber(a) then
            db.reportMin = math.max(MIN_FIGHT, tonumber(a))
            db.report = true
        else
            db.report = not db.report
        end
        Print(("fight report %s (fights of %d sec or more)"):format(OnOff(db.report), db.reportMin))
    elseif cmd == "stats" then
        if a == "reset" then
            wipe(db.history)
            Print("stats cleared")
        else
            PrintStats()
        end
    elseif cmd == "reset" then
        for k, v in pairs(layoutDefaults) do db[k] = v end
        Print("position and size reset")
        ApplyAll()
    elseif cmd == "options" or cmd == "config" then
        if settingsCategory then
            Settings.OpenToCategory(settingsCategory:GetID())
        else
            Print("settings panel unavailable, use the slash commands")
        end
    else
        local ver = C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"
        Print(ver:find("^@") and "dev" or "v" .. (ver:gsub("^v", "")))
        for _, line in ipairs(HELP) do Print(line) end
    end
end
