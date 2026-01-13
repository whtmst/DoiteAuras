---------------------------------------------------------------
-- DoiteSettings.lua
-- Settings UI for DoiteAuras
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

DoiteSettings = DoiteSettings or {}

local settingsFrame
----------------------------------------
-- Local helpers
----------------------------------------
-- Match "top-most" behavior
local function DS_MakeTopMost(frame)
    if not frame then return end
    frame:SetFrameStrata("TOOLTIP")
end

local function DS_CloseOtherWindows()
    local f

    f = _G["DoiteAurasImportFrame"]
    if f and f.IsShown and f:IsShown() then
        f:Hide()
    end

    f = _G["DoiteAurasExportFrame"]
    if f and f.IsShown and f:IsShown() then
        f:Hide()
    end
end

----------------------------------------
-- Frame
----------------------------------------
local function DS_CreateSettingsFrame()
    if settingsFrame then
        return
    end

    local f = CreateFrame("Frame", "DoiteAurasSettingsFrame", UIParent)
    settingsFrame = f

    -- Size similar to Import frame, same style
    f:SetWidth(250)
    f:SetHeight(350)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        this:StartMoving()
    end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
    end)

    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:SetBackdropColor(0, 0, 0, 1)
    f:SetBackdropBorderColor(1, 1, 1, 1)
    f:SetFrameStrata("TOOLTIP")
    f:Hide()

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -15)
    title:SetText("|cff6FA8DCDoiteSettings|r")

    -- Separator line (same idea as export/import)
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -35)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -35)
    sep:SetTexture(1, 1, 1)
    if sep.SetVertexColor then
        sep:SetVertexColor(1, 1, 1, 0.25)
    end

    -- Close X
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
    close:SetScript("OnClick", function()
        f:Hide()
    end)
	
	-- Coming soon text (center body)
    local coming = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    coming:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -55)
    coming:SetWidth(210)
    coming:SetJustifyH("LEFT")
    coming:SetJustifyV("TOP")
    coming:SetText("Settings coming:\n\n* Padding for icons (screen)\n* Padding between icons (dynamic group)\n* Soon of CD (Range for sliders & Time)\n* Skins on the icon frames maybe\n* Refresh rate for certain rebuilds (like group)")

    -- OnShow: enforce exclusivity + top-most
    f:SetScript("OnShow", function()
        DS_CloseOtherWindows()
        DS_MakeTopMost(f)
    end)

    DS_MakeTopMost(f)
end

-- Public entrypoint called by the Settings button in DoiteAuras.lua
function DoiteAuras_ShowSettings()
    if not settingsFrame then
        DS_CreateSettingsFrame()
    end

    -- If Import/Export are open, close them so only one window is visible
    DS_CloseOtherWindows()

    settingsFrame:Show()
end
----------------------------------------
-- End of frame
----------------------------------------