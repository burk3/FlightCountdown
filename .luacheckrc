std = "lua51"
max_line_length = false
exclude_files = { ".release/" }

ignore = {
    "212",  -- unused argument (event/script handler signatures)
}

-- Globals this addon defines.
globals = {
    "FlightCountdownDB",
    "FlightCountdownCharDB",
    "SLASH_FLIGHTCOUNTDOWN1",
    "SLASH_FLIGHTCOUNTDOWN2",
    "SlashCmdList",
}

-- WoW API the addon reads. A typo in an API name shows up as an
-- "accessing undefined variable" warning.
read_globals = {
    "BackdropTemplateMixin",
    "C_Map",
    "C_TaxiMap",
    "C_Timer",
    "C_Traits",
    "CreateFrame",
    "DEFAULT_CHAT_FRAME",
    "Enum",
    "FlightMap_FlightPointPinMixin",
    "FlightMapFrame",
    "GameTooltip",
    "GetNumRoutes",
    "GetTaxiMapID",
    "GetTime",
    "hooksecurefunc",
    "NumTaxiNodes",
    "TaxiGetNodeSlot",
    "TaxiNodeGetType",
    "TaxiNodeName",
    "TaxiNodeOnButtonEnter",
    "TaxiNodePosition",
    "TaxiRequestEarlyLanding",
    "time",
    "UIParent",
    "UnitOnTaxi",
    "wipe",
}
