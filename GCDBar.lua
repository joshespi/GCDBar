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
local curColor
local secretWarned = false

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

local function Refresh()
    if not db or not db.locked then return end

    local cd = C_Spell.GetSpellCooldown(GCD_SPELL)
    if not cd then
        Idle()
        return
    end

    if issecretvalue and (issecretvalue(cd.startTime) or issecretvalue(cd.duration)
            or issecretvalue(cd.isEnabled) or issecretvalue(cd.modRate)) then
        if not secretWarned then
            secretWarned = true
            print("|cffffcc00GCDBar:|r GCD values are secret on this patch, bar disabled.")
        end
        bar:Hide()
        return
    end

    if not cd.isEnabled or cd.duration == 0 then
        Idle()
        return
    end

    total = cd.duration / (cd.modRate or 1)
    endTime = cd.startTime + total
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

bar:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        GCDBarDB = GCDBarDB or {}
        db = GCDBarDB
        for _, defaults in ipairs({ layoutDefaults, prefDefaults }) do
            for k, v in pairs(defaults) do
                if db[k] == nil then db[k] = v end
            end
        end
        ApplyLayout()
        SetLocked(db.locked)
        self:UnregisterEvent("ADDON_LOADED")
    else
        Refresh()
    end
end)

local HELP = {
    "/gcd unlock - show bar, drag to move",
    "/gcd lock - lock position",
    "/gcd size <width> <height>",
    "/gcd idle - toggle empty bar while in combat",
    "/gcd reset - default position and size",
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
            print("GCDBar: /gcd size <width> <height>")
            return
        end
        db.width, db.height = w, h
        ApplyLayout()
        Refresh()
    elseif cmd == "idle" then
        db.showIdle = not db.showIdle
        print("GCDBar: idle bar " .. (db.showIdle and "on" or "off"))
        Refresh()
    elseif cmd == "reset" then
        for k, v in pairs(layoutDefaults) do db[k] = v end
        ApplyLayout()
        Refresh()
    else
        for _, line in ipairs(HELP) do print("GCDBar: " .. line) end
    end
end
