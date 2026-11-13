-- Flight Countdown
-- Shows remaining flight time while on a taxi. Exact times are learned per
-- route the first time you fly it; unknown routes are estimated from the
-- route's distance on the flight map (and that estimate self-calibrates).

local ADDON_NAME = ...
local PREFIX = "|cff33ccffFlight Countdown|r: "

local DB
local DEFAULT_FACTOR = 1.4   -- seconds per flight-map UI unit, refined as you fly
local PENDING_TIMEOUT = 30   -- seconds to wait after clicking a node for takeoff

local flight      -- the flight currently being shown
local pending     -- route chosen on the flight map, waiting for takeoff
local resume      -- in-flight state saved across a /reload or relog
local hookedTooltip = false

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end

local function FormatTime(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    if sec >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor((sec % 3600) / 60), sec % 60)
    end
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function RouteKey(a, b) return a .. " > " .. b end

local function ShortName(name)
    return name and (name:match("^([^,]+)") or name) or "Unknown"
end

local function ContinentID()
    if not (C_Map and C_Map.GetBestMapForUnit) then return 0 end
    local continentType = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
    local id = C_Map.GetBestMapForUnit("player")
    for _ = 1, 10 do
        if not id then break end
        local info = C_Map.GetMapInfo(id)
        if not info then break end
        if info.mapType == continentType or not info.parentMapID or info.parentMapID == 0 then
            return id
        end
        id = info.parentMapID
    end
    return id or 0
end

local function Factor(cont)
    return (DB.factors[cont]) or DEFAULT_FACTOR
end

----------------------------------------------------------------------------
-- Route analysis (only valid while the flight map is open)
----------------------------------------------------------------------------

local function CurrentNodeName()
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then return TaxiNodeName(i) end
    end
end

local function MapSize()
    local m = TaxiRouteMap or TaxiFrame
    local w, h = 1, 1
    if m and m.GetWidth then w, h = m:GetWidth(), m:GetHeight() end
    if not w or w <= 0 then w = 1 end
    if not h or h <= 0 then h = 1 end
    return w, h
end

-- Returns a table describing the route to taxi node `index`, or nil.
local function BuildRoute(index)
    if not index or TaxiNodeGetType(index) ~= "REACHABLE" then return nil end
    local src, dst = CurrentNodeName(), TaxiNodeName(index)
    if not src or not dst then return nil end

    local route = { src = src, dst = dst, cont = ContinentID(), raw = 0 }
    local exact = DB.times[RouteKey(src, dst)]

    local hops = GetNumRoutes(index) or 0
    local w, h = MapSize()
    local factor = Factor(route.cont)
    local prev, sum, allKnown = src, 0, true

    for hop = 1, hops do
        local sx, sy = TaxiGetSrcX(index, hop), TaxiGetSrcY(index, hop)
        local dx, dy = TaxiGetDestX(index, hop), TaxiGetDestY(index, hop)
        local d = 0
        if sx and sy and dx and dy then
            d = math.sqrt(((dx - sx) * w) ^ 2 + ((dy - sy) * h) ^ 2)
        end
        route.raw = route.raw + d

        local nextName
        if hop == hops then
            nextName = dst
        elseif TaxiGetNodeSlot then
            local slot = TaxiGetNodeSlot(index, hop, false)
            nextName = slot and TaxiNodeName(slot)
        end

        local known = prev and nextName and DB.times[RouteKey(prev, nextName)]
        if known then
            sum = sum + known
        else
            sum = sum + d * factor
            allKnown = false
        end
        prev = nextName
    end

    if exact then
        route.est, route.exact = exact, true
    else
        route.est, route.exact = sum, false
        route.fromLegs = allKnown and hops > 1
    end
    route.hops = hops
    return route
end

----------------------------------------------------------------------------
-- Display
----------------------------------------------------------------------------

local frame = CreateFrame("Frame", "FlightCountdownFrame", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
frame:SetSize(240, 50)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(false)
frame:RegisterForDrag("LeftButton")
frame:Hide()
if frame.SetBackdrop then
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.75)
    frame:SetBackdropBorderColor(0.4, 0.6, 0.9, 1)
end

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 10, -8)
title:SetPoint("TOPRIGHT", -10, -8)
title:SetJustifyH("CENTER")
title:SetWordWrap(false)

local bar = CreateFrame("StatusBar", nil, frame)
bar:SetPoint("BOTTOMLEFT", 9, 8)
bar:SetPoint("BOTTOMRIGHT", -9, 8)
bar:SetHeight(16)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
bar:SetMinMaxValues(0, 1)

local barBg = bar:CreateTexture(nil, "BACKGROUND")
barBg:SetAllPoints()
barBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

local timeText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
timeText:SetPoint("CENTER")

frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    DB.point = { point, relPoint, x, y }
end)

local function RestorePosition()
    frame:ClearAllPoints()
    local p = DB.point
    if p then
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
end

local function UpdateDisplay()
    if not flight then
        if not DB.locked then
            title:SetText("Flight Countdown")
            timeText:SetText("Drag to move  -  /fc lock")
            bar:SetStatusBarColor(0.3, 0.3, 0.3)
            bar:SetValue(1)
            frame:Show()
        else
            frame:Hide()
        end
        return
    end

    local elapsed = GetTime() - flight.start
    title:SetText(ShortName(flight.dst))

    if not flight.est or flight.est <= 0 then
        bar:SetStatusBarColor(0.5, 0.5, 0.5)
        bar:SetValue(1)
        timeText:SetText("In flight  " .. FormatTime(elapsed))
    else
        local remaining = flight.est - elapsed
        if flight.exact then
            bar:SetStatusBarColor(0.2, 0.6, 1.0)
        else
            bar:SetStatusBarColor(1.0, 0.7, 0.1)
        end
        bar:SetValue(math.min(1, elapsed / flight.est))
        if remaining > 0 then
            timeText:SetText((flight.exact and "" or "~") .. FormatTime(remaining))
        else
            timeText:SetText("Arriving...  +" .. FormatTime(-remaining))
        end
    end
    frame:Show()
end

local function SetLocked(locked)
    DB.locked = locked
    frame:EnableMouse(not locked)
    UpdateDisplay()
end

----------------------------------------------------------------------------
-- Flight lifecycle
----------------------------------------------------------------------------

local function SaveActive()
    if flight and not flight.test then
        DB.active = {
            src = flight.src, dst = flight.dst, est = flight.est, exact = flight.exact,
            raw = flight.raw, cont = flight.cont, record = flight.record,
            startEpoch = time() - (GetTime() - flight.start),
        }
    else
        DB.active = nil
    end
end

local function StartFlight(route)
    flight = {
        src = route.src, dst = route.dst, est = route.est, exact = route.exact,
        raw = route.raw, cont = route.cont, test = route.test,
        record = route.record ~= false and route.src ~= nil,
        start = route.start or GetTime(),
    }
    SaveActive()
    UpdateDisplay()
end

local function Learn(f, duration)
    if not f.record or not f.src or not f.dst or duration < 5 then return end
    local key = RouteKey(f.src, f.dst)
    local isNew = DB.times[key] == nil
    DB.times[key] = math.floor(duration + 0.5)

    if f.raw and f.raw > 0 and f.cont then
        local sample = duration / f.raw
        local old = DB.factors[f.cont]
        DB.factors[f.cont] = old and (old * 0.7 + sample * 0.3) or sample
    end

    if isNew then
        local note = ""
        if f.est and f.est > 0 then
            note = string.format(" (estimate was %s)", FormatTime(f.est))
        end
        Print(string.format("Learned %s -> %s: %s%s", ShortName(f.src), ShortName(f.dst),
            FormatTime(duration), note))
    end
end

local function EndFlight()
    if not flight then return end
    if not flight.test then
        Learn(flight, GetTime() - flight.start)
    end
    flight = nil
    DB.active = nil
    UpdateDisplay()
end

-- Taxi click: remember the chosen route so we can time it once we take off.
hooksecurefunc("TakeTaxiNode", function(index)
    local ok, route = pcall(BuildRoute, index)
    if ok and route then
        route.t = GetTime()
        pending = route
    end
end)

----------------------------------------------------------------------------
-- Flight map tooltip: show the time when hovering a destination
----------------------------------------------------------------------------

local function HookTooltip()
    if hookedTooltip or type(TaxiNodeOnButtonEnter) ~= "function" then return end
    hookedTooltip = true
    hooksecurefunc("TaxiNodeOnButtonEnter", function(button)
        if not DB.tooltip then return end
        local ok, route = pcall(BuildRoute, button and button:GetID())
        if not ok or not route or not route.est or route.est <= 0 then return end
        local label
        if route.exact then
            label = "|cff33ccff" .. FormatTime(route.est) .. "|r"
        elseif route.fromLegs then
            label = "|cffffcc33~" .. FormatTime(route.est) .. "|r |cff888888(from known legs)|r"
        else
            label = "|cffffcc33~" .. FormatTime(route.est) .. "|r |cff888888(estimate)|r"
        end
        GameTooltip:AddLine("Flight time: " .. label, 1, 1, 1)
        GameTooltip:Show()
    end)
end

----------------------------------------------------------------------------
-- Polling + events
----------------------------------------------------------------------------

local accum = 0

local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, elapsed)
    accum = accum + elapsed
    if accum < 0.1 then return end
    accum = 0
    if not DB then return end

    local now = GetTime()
    local onTaxi = UnitOnTaxi("player")

    if onTaxi and (not flight or flight.test) then
        if pending and now - pending.t < PENDING_TIMEOUT then
            StartFlight(pending)
        elseif resume then
            StartFlight(resume)
        else
            StartFlight({ dst = "In flight", record = false })
        end
        pending, resume = nil, nil
    elseif not onTaxi and flight and not flight.test then
        EndFlight()
    end

    if pending and now - pending.t >= PENDING_TIMEOUT then pending = nil end
    if resume and now - resume.seen > 15 then
        resume, DB.active = nil, nil
    end

    if flight then
        if flight.test and now - flight.start > flight.est + 3 then
            flight = nil
        end
        UpdateDisplay()
    end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("TAXIMAP_OPENED")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        FlightCountdownDB = FlightCountdownDB or {}
        DB = FlightCountdownDB
        DB.times = DB.times or {}
        DB.factors = DB.factors or {}
        if DB.locked == nil then DB.locked = true end
        if DB.tooltip == nil then DB.tooltip = true end
        RestorePosition()
        SetLocked(DB.locked)
        HookTooltip()

    elseif event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin = arg1
        HookTooltip()
        if DB and DB.active and not flight then
            local a = DB.active
            resume = {
                src = a.src, dst = a.dst, est = a.est, exact = a.exact, raw = a.raw,
                cont = a.cont,
                -- After a full relog, time spent offline would skew the timing.
                record = (a.record and not isInitialLogin) and true or false,
                start = GetTime() - (time() - (a.startEpoch or time())),
                seen = GetTime(),
            }
        end

    elseif event == "TAXIMAP_OPENED" then
        HookTooltip()

    elseif event == "PLAYER_LOGOUT" then
        SaveActive()
    end
end)

----------------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------------

SLASH_FLIGHTCOUNTDOWN1 = "/fc"
SLASH_FLIGHTCOUNTDOWN2 = "/flightcountdown"
SlashCmdList.FLIGHTCOUNTDOWN = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "unlock" or msg == "move" then
        SetLocked(false)
        Print("Unlocked. Drag the bar, then type /fc lock.")
    elseif msg == "lock" then
        SetLocked(true)
        Print("Locked.")
    elseif msg == "reset" then
        DB.point = nil
        RestorePosition()
        Print("Position reset.")
    elseif msg == "test" then
        StartFlight({ dst = "Test Flight, Somewhere", est = 20, exact = true, test = true, record = false })
    elseif msg == "tooltip" then
        DB.tooltip = not DB.tooltip
        Print("Flight map tooltip " .. (DB.tooltip and "on." or "off."))
    elseif msg == "forget" then
        wipe(DB.times)
        wipe(DB.factors)
        Print("Forgot all learned flight times.")
    else
        local n = 0
        for _ in pairs(DB.times) do n = n + 1 end
        Print(string.format("%d route(s) learned.", n))
        Print("/fc unlock | lock | reset | test | tooltip | forget")
    end
end
