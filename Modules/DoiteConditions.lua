---------------------------------------------------------------
-- DoiteConditions.lua
-- Evaluates ability and aura conditions to show/hide/update icons
-- Turtle WoW (1.12) | Lua 5.0
---------------------------------------------------------------

local addonName, _ = "DoiteConditions"
local DoiteConditions = {}
_G["DoiteConditions"] = DoiteConditions
DoiteAurasCacheDB = DoiteAurasCacheDB or {}
local DG = _G["DoiteGlow"]

---------------------------------------------------------------
-- Local helpers
---------------------------------------------------------------

local function SafeGet(tbl, key)
    if not tbl then return nil end
    return tbl[key]
end

local function InCombat()
    return UnitAffectingCombat("player") == 1
end

local function GetPower()
    return UnitMana("player")
end

-- Track temporarily usable spells (like Revenge)
local activeSpells = {}

local function IsSpellTemporarilyActive(name)
    return activeSpells[name] == true
end

---------------------------------------------------------------
-- Ability condition evaluation
---------------------------------------------------------------
local function CheckAbilityConditions(data)
    if not data or not data.conditions or not data.conditions.ability then
        return true -- if no conditions, always show
    end
    local c = data.conditions.ability

    local show = true

    -- === 1. Cooldown / usability ===
    local spellName = data.displayName or data.name
    local spellIndex
    local bookType = BOOKTYPE_SPELL
    local foundInBook = false
    for i = 1, 200 do
        local name = GetSpellName(i, bookType)
        if not name then break end
        if name == spellName then
            spellIndex = i
            foundInBook = true
            break
        end
    end

    if not foundInBook then
        return false
    end

    local function IsOnCooldown(idx)
        if not idx then return false end
        local start, dur, enable = GetSpellCooldown(idx, bookType)
        return (start and start > 0 and dur and dur > 1.5)
    end

    if c.mode == "usable" and spellIndex then
        local usable, noMana = IsSpellUsable(spellName)
        local onCooldown = IsOnCooldown(spellIndex)
        if (usable ~= 1 and not IsSpellTemporarilyActive(spellName)) or onCooldown then
            show = false
        end
    elseif c.mode == "notcd" and spellIndex then
        if IsOnCooldown(spellIndex) then show = false end
    elseif c.mode == "oncd" and spellIndex then
        if not IsOnCooldown(spellIndex) then show = false end
    end

	-- === Combat state ===
	local inCombatFlag  = (c.inCombat == true)
	local outCombatFlag = (c.outCombat == true)

	-- If both are checked, always allowed
	if not (inCombatFlag and outCombatFlag) then
		if inCombatFlag and not InCombat() then show = false end
		if outCombatFlag and InCombat() then show = false end
	end


    -- === 3. Target type ===
    local tgt = c.target or "all"

    if tgt == "self" then
        -- Only show if player has themselves targeted.
        if not UnitExists("target") or not UnitIsUnit("player", "target") then
            show = false
        end
    elseif tgt == "target" then
        -- Require any target.
        if not UnitExists("target") then show = false end
    elseif tgt == "help" then
        -- Require a friendly (helpful) target.
        if not UnitExists("target") or not UnitIsFriend("player", "target") then
            show = false
        end
    elseif tgt == "harm" then
        -- Require a hostile (harmful) target.
        if not UnitExists("target") or not UnitCanAttack("player", "target") or UnitIsFriend("player", "target") then
            show = false
        end
    elseif tgt == "all" then
        -- All targets allowed, skip filtering entirely.
    else
        -- Fallback: unknown value, allow.
    end

    -- === 4. Power threshold ===
    if c.powerEnabled and c.powerComp and c.powerVal then
        local val = GetPower()
        local targetVal = tonumber(c.powerVal) or 0
        local comp = c.powerComp
        if comp == ">=" and not (val >= targetVal) then show = false end
        if comp == "<=" and not (val <= targetVal) then show = false end
        if comp == "==" and not (val == targetVal) then show = false end
    end

    local glow = c.glow and true or false
    local grey = c.greyscale and true or false

    return show, glow, grey
end

---------------------------------------------------------------
-- Aura condition evaluation (with caching)
---------------------------------------------------------------
local function CheckAuraConditions(data)
    if not data or not data.conditions or not data.conditions.aura then
        return true
    end
    local c = data.conditions.aura
    local show = true
    local name = data.displayName or data.name
    if not name then return false end

    -- tooltip helper (vanilla-safe)
    local daTip = CreateFrame("GameTooltip", "DoiteConditionsTooltip", nil, "GameTooltipTemplate")
    daTip:SetOwner(UIParent, "ANCHOR_NONE")

    local function GetBuffName(unit, index, debuff)
        daTip:ClearLines()
        if debuff then daTip:SetUnitDebuff(unit, index)
        else daTip:SetUnitBuff(unit, index) end
        return DoiteConditionsTooltipTextLeft1 and DoiteConditionsTooltipTextLeft1:GetText()
    end

    local function HasAura(unit, auraName)
        for i = 1, 40 do
            local buff = GetBuffName(unit, i, false)
            if not buff then break end
            if buff == auraName then return "buff", i end
        end
        for i = 1, 40 do
            local debuff = GetBuffName(unit, i, true)
            if not debuff then break end
            if debuff == auraName then return "debuff", i end
        end
        return nil
    end

    -- === Target logic (supports c.target string + legacy boolean flags) ===
    local foundType, foundIndex, foundUnit
    local tgt = c.target or "self"

    local checkSelf   = (tgt == "self") or (c.targetSelf == true)
    local checkTarget = (tgt == "target") or (c.targetTarget == true) or (tgt == "both")

    if checkSelf and not checkTarget then
        foundType, foundIndex = HasAura("player", name)
        if foundType then foundUnit = "player" end
    elseif checkTarget and not checkSelf then
        if UnitExists("target") then
            foundType, foundIndex = HasAura("target", name)
            if foundType then foundUnit = "target" end
        end
    elseif checkSelf and checkTarget then
        -- both → prefer player first, then target
        local fPlayer, idxPlayer = HasAura("player", name)
        if fPlayer then
            foundType, foundIndex, foundUnit = fPlayer, idxPlayer, "player"
        else
            if UnitExists("target") then
                local fTarget, idxTarget = HasAura("target", name)
                if fTarget then
                    foundType, foundIndex, foundUnit = fTarget, idxTarget, "target"
                end
            end
        end
    else
        -- fallback: check player
        foundType, foundIndex = HasAura("player", name)
        if foundType then foundUnit = "player" end
    end

    local found = (foundType ~= nil)

    ---------------------------------------------------------------
    -- Cache and retrieve icon textures (use foundUnit if known)
    ---------------------------------------------------------------
    if found and not data.iconTexture then
        local tex
        if foundUnit == "player" then
            if foundType == "buff" then
                tex = UnitBuffTexture and UnitBuffTexture("player", foundIndex)
            elseif foundType == "debuff" then
                tex = UnitDebuffTexture and UnitDebuffTexture("player", foundIndex)
            end
        elseif foundUnit == "target" then
            if foundType == "buff" then
                tex = UnitBuffTexture and UnitBuffTexture("target", foundIndex)
            elseif foundType == "debuff" then
                tex = UnitDebuffTexture and UnitDebuffTexture("target", foundIndex)
            end
        end

        -- fallback: try spellbook texture lookup
        if not tex then
            for i = 1, 200 do
                local sName = GetSpellName(i, BOOKTYPE_SPELL)
                if not sName then break end
                if sName == name then
                    tex = GetSpellTexture(i, BOOKTYPE_SPELL)
                    break
                end
            end
        end

        if tex then
            data.iconTexture = tex
            DoiteAurasCacheDB[name] = tex
            if _G["DoiteIcon_" .. data.key] and _G["DoiteIcon_" .. data.key].icon then
                _G["DoiteIcon_" .. data.key].icon:SetTexture(tex)
            end
        end

    elseif not found then
        local tex = data.iconTexture or DoiteAurasCacheDB[name]
        if tex and _G["DoiteIcon_" .. data.key] and _G["DoiteIcon_" .. data.key].icon then
            _G["DoiteIcon_" .. data.key].icon:SetTexture(tex)
        end
    end

    -- Mode handling (found / missing)
    if c.mode == "found" and not found then show = false end
    if c.mode == "missing" and found then show = false end

    -- Combat state (in/out flags; if both true then always allowed)
    local inCombatFlag  = (c.inCombat == true)
    local outCombatFlag = (c.outCombat == true)
    if not (inCombatFlag and outCombatFlag) then
        if inCombatFlag and not InCombat() then show = false end
        if outCombatFlag and InCombat() then show = false end
    end

    local glow = c.glow and true or false
    local grey = c.greyscale and true or false

    return show, glow, grey
end

---------------------------------------------------------------
-- Main update
---------------------------------------------------------------
function DoiteConditions:EvaluateAll()
    local source = (DoiteDB and DoiteDB.icons) or (DoiteAurasDB and DoiteAurasDB.spells)
    if not source then return end

    for key, data in pairs(source) do
        if data and data.type then
            data.key = key
            if data.type == "Ability" then
                local show, glow, grey = CheckAbilityConditions(data)
                DoiteConditions:ApplyVisuals(key, show, glow, grey)
            elseif data.type == "Buff" or data.type == "Debuff" then
                local show, glow, grey = CheckAuraConditions(data)
                DoiteConditions:ApplyVisuals(key, show, glow, grey)
            end
        end
    end
end

---------------------------------------------------------------
-- Apply visuals to icons
---------------------------------------------------------------
function DoiteConditions:ApplyVisuals(key, show, glow, grey)
    local frame = _G["DoiteIcon_" .. key]
    if not frame then return end

    if show then frame:Show() else frame:Hide() end
    if grey and frame.icon then frame.icon:SetDesaturated(1)
    elseif frame.icon then frame.icon:SetDesaturated(nil) end

        -- === Glow handling ===
	if DG then
		if glow then
			DG.Start(frame)
		else
			DG.Stop(frame)
		end
	else
		DEFAULT_CHAT_FRAME:AddMessage("DG not loaded for " .. (key or "nil"))
	end
end

---------------------------------------------------------------
-- Event handling + smoother updates
---------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("COMBAT_TEXT_UPDATE")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UNIT_MANA")
eventFrame:RegisterEvent("UNIT_ENERGY")
eventFrame:RegisterEvent("UNIT_RAGE")

eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "COMBAT_TEXT_UPDATE" then
        if arg1 == "SPELL_ACTIVE" then activeSpells[arg2] = true
        elseif arg1 == "SPELL_INACTIVE" then activeSpells[arg2] = nil end
    end
    if DoiteConditions and DoiteConditions.EvaluateAll then
        DoiteConditions:EvaluateAll()
    end
end)

---------------------------------------------------------------
-- End of DoiteConditions.lua
---------------------------------------------------------------
