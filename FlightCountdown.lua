-- Flight Countdown
-- Shows remaining flight time while on a taxi.
--
-- Where times come from, best first:
--   1. A time you've measured for this exact route (learned on landing).
--   2. Per hop: a measured time for that hop, else its flown length in yards
--      (RouteData.lua, generated from the game's own flight path tables)
--      divided by a flight speed that is learned as you fly.
--   3. Per hop, if neither is known: straight-line distance on the flight map
--      times a per-continent factor (also learned).
-- Learned times and speeds are stored without the Frequent Flier perk's speed
-- bonus, so they're shared correctly between characters with and without it.

local ADDON_NAME, ns = ...
local PREFIX = "|cff33ccffFlight Countdown|r: "

local DEFAULT_SPEED = 30.4      -- yards/second without Frequent Flier
local DEFAULT_MAP_FACTOR = 600  -- seconds per flight-map width, rough fallback
local PENDING_TIMEOUT = 30      -- seconds to wait for takeoff after choosing a node
local RESUME_TIMEOUT = 15       -- seconds to wait for UnitOnTaxi after a reload
local YARDS_TOLERANCE = 0.02    -- route length change that invalidates a recorded time

-- Bump when the meaning or shape of saved data changes, and add a step to
-- Migrate() that converts only what changed. Never bump for new RouteData;
-- recorded times carry their route length and are checked against it.
local SCHEMA_VERSION = 2

-- Frequent Flier (Adventure Legacy tree): flight path mounts fly 20% faster.
local FREQUENT_FLIER_TREE = 1188
local FREQUENT_FLIER_NODE = 110300
local FREQUENT_FLIER_MULT = 1.2

local routeYards = ns.routeYards or {}

local DB       -- account-wide: learned times, speed, settings
local CharDB   -- per character: the flight in progress
local ready = false

local flight   -- the flight being shown
local pending  -- route chosen on the flight map, waiting for takeoff
local resume   -- flight restored after /reload or relog, waiting for UnitOnTaxi

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

local function SpeedMultiplier()
    if not (C_Traits and C_Traits.GetConfigIDByTreeID and C_Traits.GetNodeInfo) then return 1 end
    local ok, configID = pcall(C_Traits.GetConfigIDByTreeID, FREQUENT_FLIER_TREE)
    if not ok or not configID then return 1 end
    local ok2, info = pcall(C_Traits.GetNodeInfo, configID, FREQUENT_FLIER_NODE)
    if ok2 and info and (info.activeRank or 0) > 0 then return FREQUENT_FLIER_MULT end
    return 1
end

local function Speed() return DB.speed or DEFAULT_SPEED end
local function MapFactor(cont) return DB.factors[cont] or DEFAULT_MAP_FACTOR end

-- Moves `old` part of the way toward `sample`. A sample outside [lo, hi] times
-- `old` is ignored as bad data, unless that keeps happening: after 3 misses in
-- a row the stored value is assumed to be the wrong one and is replaced.
local MAX_MISSES = 3
local function Blend(old, sample, weight, lo, hi, missKey)
    if not old then
        DB.misses[missKey] = nil
        return sample
    end
    local ratio = sample / old
    if ratio < lo or ratio > hi then
        local misses = (DB.misses[missKey] or 0) + 1
        if misses >= MAX_MISSES then
            DB.misses[missKey] = nil
            return sample
        end
        DB.misses[missKey] = misses
        return old
    end
    DB.misses[missKey] = nil
    return old + (sample - old) * weight
end

-- A recorded time in base seconds, or nil if there is none or if the route's
-- length has changed since it was recorded (the game's flight path moved).
-- Times recorded without a length are trusted; they gain one when re-flown.
local function LearnedTime(key, yards)
    local t = DB.times[key]
    if not t then return nil end
    if t.yards and yards and math.abs(yards - t.yards) > t.yards * YARDS_TOLERANCE then
        return nil
    end
    return t.sec
end

local function Migrate()
    local version = DB.version or 1
    if version < 2 then
        -- v1 times were plain numbers; v2 stores { sec, yards }.
        for key, t in pairs(DB.times) do
            if type(t) == "number" then DB.times[key] = { sec = t } end
        end
        -- The first release measured map distance in other units, so its
        -- fallback factors are meaningless now. Times and speed are kept.
        wipe(DB.factors)
        DB.active = nil  -- moved to per-character storage
    end
    if version < SCHEMA_VERSION then DB.version = SCHEMA_VERSION end
end

----------------------------------------------------------------------------
-- Route analysis (only valid while the flight map is open)
----------------------------------------------------------------------------

local function CurrentNodeName()
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then return TaxiNodeName(i) end
    end
end

local function NodeIDsBySlot()
    local ids = {}
    local mapID = GetTaxiMapID and GetTaxiMapID()
    if mapID and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then
        local ok, nodes = pcall(C_TaxiMap.GetAllTaxiNodes, mapID)
        if ok and nodes then
            for _, node in ipairs(nodes) do
                if node.slotIndex and node.nodeID then ids[node.slotIndex] = node.nodeID end
            end
        end
    end
    return ids
end

-- Describes the route to taxi slot `index`, or returns nil.
-- All times here are "base" times (no Frequent Flier); est is the real one.
local function BuildRoute(index)
    if not index or TaxiNodeGetType(index) ~= "REACHABLE" then return nil end
    local src, dst = CurrentNodeName(), TaxiNodeName(index)
    if not src or not dst then return nil end

    local hops = GetNumRoutes(index) or 0
    if hops < 1 then return nil end

    local route = {
        src = src, dst = dst, cont = ContinentID(), mult = SpeedMultiplier(),
        hops = hops, raw = 0, yards = 0,
    }
    local ids = NodeIDsBySlot()
    local speed, factor = Speed(), MapFactor(route.cont)
    local base, allYards, allLegs, rough = 0, true, true, false

    for hop = 1, hops do
        local a = TaxiGetNodeSlot(index, hop, true)
        local b = TaxiGetNodeSlot(index, hop, false)
        local aName = hop == 1 and src or (a and TaxiNodeName(a))
        local bName = hop == hops and dst or (b and TaxiNodeName(b))

        local raw = 0
        if a and b then
            local ax, ay = TaxiNodePosition(a)
            local bx, by = TaxiNodePosition(b)
            if ax and ay and bx and by then raw = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) end
        end
        route.raw = route.raw + raw

        local idA, idB = ids[a], ids[b]
        local yards = idA and idB and routeYards[idA * 10000 + idB]
        if yards then route.yards = route.yards + yards else allYards = false end

        local leg = aName and bName and LearnedTime(RouteKey(aName, bName), yards)
        if leg then
            base = base + leg
        elseif yards then
            base = base + yards / speed
            allLegs = false
        else
            base = base + raw * factor
            allLegs, rough = false, true
        end
    end
    if not allYards then route.yards = nil end

    local exact = LearnedTime(RouteKey(src, dst), route.yards)
    if exact then
        route.base, route.kind = exact, "exact"
    else
        route.base = base
        route.kind = (allLegs and "legs") or (rough and "rough") or "yards"
    end
    route.est = route.base / route.mult
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

    if flight.early then
        bar:SetStatusBarColor(0.5, 0.5, 0.5)
        bar:SetValue(1)
        timeText:SetText("Landing early...")
    elseif not flight.est or flight.est <= 0 then
        bar:SetStatusBarColor(0.5, 0.5, 0.5)
        bar:SetValue(1)
        timeText:SetText("In flight  " .. FormatTime(elapsed))
    else
        local remaining = flight.est - elapsed
        if flight.kind == "exact" then
            bar:SetStatusBarColor(0.2, 0.6, 1.0)
        else
            bar:SetStatusBarColor(1.0, 0.7, 0.1)
        end
        bar:SetValue(math.min(1, elapsed / flight.est))
        if remaining > 0 then
            timeText:SetText((flight.kind == "exact" and "" or "~") .. FormatTime(remaining))
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

local SAVED_FIELDS = { "src", "dst", "est", "base", "kind", "mult", "hops", "raw", "yards", "cont", "record", "early" }

local function SaveActive()
    if flight and not flight.test then
        local a = {}
        for _, k in ipairs(SAVED_FIELDS) do a[k] = flight[k] end
        a.startEpoch = time() - (GetTime() - flight.start)
        CharDB.active = a
    else
        CharDB.active = nil
    end
end

local function StartFlight(route)
    flight = {}
    for _, k in ipairs(SAVED_FIELDS) do flight[k] = route[k] end
    flight.test = route.test
    flight.record = route.record ~= false and route.src ~= nil and not route.test
    flight.start = route.start or GetTime()
    SaveActive()
    UpdateDisplay()
end

local function Learn(f, duration)
    if not f.record or f.early or not f.src or not f.dst or duration < 5 then return end
    local base = duration * (f.mult or 1)

    -- Speed and map factors run their own sanity checks (see Blend), so they
    -- learn first: if flight speed ever really changes, they adapt, and the
    -- length-based estimates below start agreeing with real times again.
    if f.yards and f.yards > 0 then
        DB.speed = Blend(DB.speed or DEFAULT_SPEED, f.yards / base, 0.25, 0.75, 1.33, "speed")
    end
    if f.raw and f.raw > 0 and f.cont then
        DB.factors[f.cont] = Blend(DB.factors[f.cont], base / f.raw, 0.3, 0.5, 2, f.cont)
    end

    -- A time far from a length-based estimate is probably a bad flight.
    if (f.kind == "yards" or f.kind == "legs") and f.base and f.base > 0 then
        local ratio = base / f.base
        if ratio < 0.6 or ratio > 1.6 then return end
    end

    -- An existing time for the same route length is only replaced by a close
    -- one, or by two disagreeing flights in a row.
    local key = RouteKey(f.src, f.dst)
    local old = LearnedTime(key, f.yards) and DB.times[key]
    if old then
        local ratio = base / old.sec
        if ratio < 0.75 or ratio > 1.33 then
            old.misses = (old.misses or 0) + 1
            if old.misses < 2 then return end
        end
    end
    DB.times[key] = { sec = math.floor(base + 0.5), yards = f.yards or (old and old.yards) }

    if not old then
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
    CharDB.active = nil
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

-- Landing early cuts the flight short; never learn from it.
if type(TaxiRequestEarlyLanding) == "function" then
    hooksecurefunc("TaxiRequestEarlyLanding", function()
        if flight and not flight.test then
            flight.early, flight.record = true, false
            SaveActive()
            UpdateDisplay()
        end
    end)
end

----------------------------------------------------------------------------
-- Flight map tooltips: show the time when hovering a destination
----------------------------------------------------------------------------

local lastTipOwner, lastTipTime

local function AddTooltipLine(owner, slot)
    if not DB or not DB.tooltip then return end
    local now = GetTime()
    if lastTipOwner == owner and lastTipTime == now then return end  -- hooked twice
    lastTipOwner, lastTipTime = owner, now

    local ok, route = pcall(BuildRoute, slot)
    if not ok or not route or not route.est or route.est <= 0 then return end
    local label
    if route.kind == "exact" then
        label = "|cff33ccff" .. FormatTime(route.est) .. "|r"
    elseif route.kind == "rough" then
        label = "|cffffcc33~" .. FormatTime(route.est) .. "|r |cff888888(rough estimate)|r"
    else
        label = "|cffffcc33~" .. FormatTime(route.est) .. "|r |cff888888(estimate)|r"
    end
    GameTooltip:AddLine("Flight time: " .. label, 1, 1, 1)
    GameTooltip:Show()
end

local function OnPinEnter(pin)
    local data = pin and pin.taxiNodeData
    if data and data.slotIndex then AddTooltipLine(pin, data.slotIndex) end
end

local hookedClassic, hookedMixin = false, false

local function HookTooltips()
    -- Classic-style TaxiFrame.
    if not hookedClassic and type(TaxiNodeOnButtonEnter) == "function" then
        hookedClassic = true
        hooksecurefunc("TaxiNodeOnButtonEnter", function(button)
            if button then AddTooltipLine(button, button:GetID()) end
        end)
    end
    -- Retail-style FlightMapFrame (Blizzard_FlightMap, load on demand).
    -- Hooking the mixin covers pins created from now on...
    if not hookedMixin and FlightMap_FlightPointPinMixin then
        hookedMixin = true
        hooksecurefunc(FlightMap_FlightPointPinMixin, "OnMouseEnter", OnPinEnter)
    end
    -- ...and this covers pins that already existed.
    if FlightMapFrame and FlightMapFrame.EnumeratePinsByTemplate then
        for pin in FlightMapFrame:EnumeratePinsByTemplate("FlightMap_FlightPointPinTemplate") do
            if not pin.flightCountdownHooked then
                pin.flightCountdownHooked = true
                hooksecurefunc(pin, "OnMouseEnter", OnPinEnter)
            end
        end
    end
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
    if not ready then return end

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
    if resume and now - resume.seen > RESUME_TIMEOUT then
        resume, CharDB.active = nil, nil
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
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            FlightCountdownDB = FlightCountdownDB or {}
            FlightCountdownCharDB = FlightCountdownCharDB or {}
            DB, CharDB = FlightCountdownDB, FlightCountdownCharDB
            DB.times = DB.times or {}
            DB.factors = DB.factors or {}
            DB.misses = DB.misses or {}
            if DB.locked == nil then DB.locked = true end
            if DB.tooltip == nil then DB.tooltip = true end
            Migrate()
            RestorePosition()
            SetLocked(DB.locked)
        end
        if DB then HookTooltips() end

    elseif event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin = arg1
        HookTooltips()
        local a = CharDB.active
        if a and not flight then
            resume = {}
            for _, k in ipairs(SAVED_FIELDS) do resume[k] = a[k] end
            if isInitialLogin then
                -- Offline time would make the countdown wrong; just count up.
                resume.est, resume.record, resume.start = nil, false, GetTime()
            else
                resume.start = GetTime() - (time() - (a.startEpoch or time()))
            end
            resume.seen = GetTime()
        end
        ready = true

    elseif event == "TAXIMAP_OPENED" then
        HookTooltips()
        C_Timer.After(0, HookTooltips)  -- pins are created as the map shows

    elseif event == "PLAYER_LOGOUT" then
        if CharDB then SaveActive() end
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
        if flight and not flight.test then
            Print("You're on a real flight right now.")
        else
            StartFlight({ dst = "Test Flight, Somewhere", est = 20, kind = "exact", test = true, record = false })
        end
    elseif msg == "tooltip" then
        DB.tooltip = not DB.tooltip
        Print("Flight map tooltip " .. (DB.tooltip and "on." or "off."))
    elseif msg == "forget" then
        wipe(DB.misses)
        wipe(DB.times)
        wipe(DB.factors)
        DB.speed = nil
        Print("Forgot all learned flight times and speeds.")
    else
        local n = 0
        for _ in pairs(DB.times) do n = n + 1 end
        Print(string.format("%d route(s) learned. Flight speed %.1f yd/s%s.", n, Speed(),
            SpeedMultiplier() > 1 and " (+20% Frequent Flier)" or ""))
        Print("/fc unlock | lock | reset | test | tooltip | forget")
    end
end
