-- DoiteEdit.lua
-- Secondary frame for editing Aura conditions / edit UI
-- Attached to DoiteAuras main frame (DoiteAurasFrame)

if DoiteConditionsFrame then
    DoiteConditionsFrame:Hide()
    DoiteConditionsFrame = nil
end

local condFrame = nil
local currentKey = nil

-- Ensure DB entry exists for a key
local function EnsureDBEntry(key)
    if not DoiteAurasDB.spells[key] then
        DoiteAurasDB.spells[key] = {
            order = 999,
            type = "Ability",
            displayName = key,
            growth = "Horizontal Right",
            numAuras = 5,
            offsetX = 0,
            offsetY = 0,
            iconSize = 40,
            conditions = {}
        }
    end

    local d = DoiteAurasDB.spells[key]

    -- general defaults (don't override existing values)
    if not d.growth then d.growth = "Horizontal Right" end
    if not d.numAuras then d.numAuras = 5 end
    if not d.offsetX then d.offsetX = 0 end
    if not d.offsetY then d.offsetY = 0 end
    if not d.iconSize then d.iconSize = 40 end
    if not d.conditions then d.conditions = {} end

    -- ensure subtables exist for consistent shape
    if not d.conditions.ability then d.conditions.ability = {} end
    if not d.conditions.aura    then d.conditions.aura    = {} end

    -- to two independent booleans: inCombat, outCombat (both true = default/both).
    if d.type == "Ability" then
        if d.conditions.ability.mode   == nil then d.conditions.ability.mode   = "notcd" end
        if d.conditions.ability.inCombat  == nil then d.conditions.ability.inCombat  = true end
        if d.conditions.ability.outCombat == nil then d.conditions.ability.outCombat = true end
				-- multi-select targets (at least one should be true)
		if d.conditions.ability.targetHelp == nil then d.conditions.ability.targetHelp = false end
		if d.conditions.ability.targetHarm == nil then d.conditions.ability.targetHarm = false end
		if d.conditions.ability.targetSelf == nil then d.conditions.ability.targetSelf = false end
		-- legacy cleanup
		d.conditions.ability.target = nil
        if d.conditions.ability.form    == nil then d.conditions.ability.form    = "All"   end
    else -- Buff / Debuff
        if d.conditions.aura.mode   == nil then d.conditions.aura.mode   = "found" end
        if d.conditions.aura.inCombat  == nil then d.conditions.aura.inCombat  = true end
        if d.conditions.aura.outCombat == nil then d.conditions.aura.outCombat = true end
		-- Aura targets: self-exclusive model (default = On player (self))
		if d.conditions.aura.targetSelf == nil then d.conditions.aura.targetSelf = true  end
		if d.conditions.aura.targetHelp == nil then d.conditions.aura.targetHelp = false end
		if d.conditions.aura.targetHarm == nil then d.conditions.aura.targetHarm = false end

		-- legacy cleanup (if still present)
		d.conditions.aura.target = nil
		d.conditions.aura.targetSelf = d.conditions.aura.targetSelf -- keep; old flag name reused
		d.conditions.aura.targetTarget = nil

		
        if d.conditions.aura.form    == nil then d.conditions.aura.form    = "All"   end
    end

    return d
end

-- clear a dropdown so it can be safely re-initialized
local function ClearDropdown(dd)
    if not dd then return end
    if UIDropDownMenu_Initialize then
        pcall(UIDropDownMenu_Initialize, dd, function() end)
    end
    if UIDropDownMenu_ClearAll then
        pcall(UIDropDownMenu_ClearAll, dd)
    end
    dd._initializedForKey = nil
    dd._initializedForType = nil
end

local function BuildGroupLeaders()
    local leaders = {}
    for k, v in pairs(DoiteAurasDB.spells) do
        if v.group and v.isLeader then
            leaders[v.group] = k
        end
    end
    return leaders
end

local function SafeEvaluate()
  if DoiteConditions_RequestEvaluate then
    DoiteConditions_RequestEvaluate()
  elseif DoiteConditions and DoiteConditions.EvaluateAll then
    DoiteConditions:EvaluateAll()
  end
end

-- refresh hooks for main addon
local function SafeRefresh()
    if DoiteAuras_RefreshList then DoiteAuras_RefreshList() end
    if DoiteAuras_RefreshIcons then DoiteAuras_RefreshIcons() end
end

-- Internal: initialize group dropdown contents for current data
local function InitGroupDropdown(dd, data)
    UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
        local info
        local choices = { "No" }
        for i = 1, 10 do table.insert(choices, "Group " .. tostring(i)) end

        for _, choice in ipairs(choices) do
            info = {}
            info.text = choice
            info.value = choice
            local pickedChoice = choice
            info.func = function(button)
                local picked = (button and button.value) or pickedChoice
                if not currentKey then return end
                local d = EnsureDBEntry(currentKey)

                if picked == "No" then
                    d.group = nil
                    d.isLeader = false
                else
                    local leaders = BuildGroupLeaders()
                    d.group = picked
                    if not leaders[picked] then
                        d.isLeader = true
                    else
                        if leaders[picked] ~= currentKey then
                            d.isLeader = false
                        end
                    end
                end

                UIDropDownMenu_SetSelectedValue(dd, picked)
                UIDropDownMenu_SetText(picked, dd)
                CloseDropDownMenus()
                UpdateCondFrameForKey(currentKey)
                SafeRefresh()
				SafeEvaluate()
            end

            if data and ((not data.group and choice == "No") or (data.group == choice)) then
                info.checked = true
            else
                info.checked = false
            end

            UIDropDownMenu_AddButton(info)
        end
    end)
end

-- Internal: initialize growth direction dropdown (leader-only control)
local function InitGrowthDropdown(dd, data)
    UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
        local info
        local directions = { "Horizontal Right", "Horizontal Left", "Vertical Down", "Vertical Up" }
        for _, dir in ipairs(directions) do
            info = {}
            info.text = dir
            info.value = dir
            local pickedDir = dir
            info.func = function(button)
                local picked = (button and button.value) or pickedDir
                if not currentKey then return end
                local d = EnsureDBEntry(currentKey)
                d.growth = picked
                UIDropDownMenu_SetSelectedValue(dd, picked)
                UIDropDownMenu_SetText(picked, dd)
                CloseDropDownMenus()
                SafeRefresh()
				SafeEvaluate()
            end
            info.checked = (data and data.growth == dir)
            UIDropDownMenu_AddButton(info)
        end
    end)
end

-- Internal: initialize numAuras dropdown (leader-only control)
local function InitNumAurasDropdown(dd, data)
    UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
        local info
        for i = 1, 10 do
            info = {}
            info.text = tostring(i)
            info.value = i
            local pickedNum = i
            info.func = function(button)
                local picked = (button and button.value) or pickedNum
                if not currentKey then return end
                local d = EnsureDBEntry(currentKey)
                d.numAuras = picked
                UIDropDownMenu_SetSelectedValue(dd, picked)
                UIDropDownMenu_SetText(tostring(picked), dd)
                CloseDropDownMenus()
                SafeRefresh()
				SafeEvaluate()
            end
            info.checked = (data and data.numAuras == i)
            UIDropDownMenu_AddButton(info)
        end
        info = {}
        info.text = "Unlimited"
        info.value = "Unlimited"
        info.func = function(button)
            local picked = (button and button.value) or "Unlimited"
            if not currentKey then return end
            local d = EnsureDBEntry(currentKey)
            d.numAuras = picked
            UIDropDownMenu_SetSelectedValue(dd, picked)
            UIDropDownMenu_SetText(picked, dd)
            CloseDropDownMenus()
            SafeRefresh()
			SafeEvaluate()
        end
        info.checked = (data and data.numAuras == "Unlimited")
        UIDropDownMenu_AddButton(info)
    end)
end

-- Unified Form/Stance dropdown initializer (works for Ability or Aura)
local function InitFormDropdown(dd, data, condType)
    if not dd then return end
    condType = condType or "ability"

    local thisKey = currentKey
    if not thisKey then
        ClearDropdown(dd)
        return
    end

    if dd._initializedForKey == thisKey and dd._initializedForType == condType then
        return
    end

    -- Determine player class and build options (reordered + Priest added)
    local _, class = UnitClass("player")
    class = class and string.upper(class) or ""

    local forms = {}
    if class == "DRUID" then
        forms = {
            "All",
            "0. No form", "1. Bear", "2. Aquatic", "3. Cat", "4. Travel",
            "5. Moonkin", "6. Tree", "7. Stealth", "8. No Stealth",
            "Multi: 0+5", "Multi: 0+6", "Multi: 1+3", "Multi: 3+7", "Multi: 3+8",
            "Multi: 5+6", "Multi: 0+5+6", "Multi: 1+3+8"
        }
    elseif class == "WARRIOR" then
        forms = { "All", "1. Battle", "2. Defensive", "3. Berserker",
                  "Multi: 1+2", "Multi: 1+3", "Multi: 2+3" }
    elseif class == "ROGUE" then
        forms = { "All", "0. No Stealth", "1. Stealth" }
    elseif class == "PRIEST" then
        forms = { "All", "0. No form", "1. Shadowform" }
    else
        dd:Hide()
        return
    end

    -- make absolutely sure the old menu is cleared before building
    ClearDropdown(dd)

    -- Build/initialize the dropdown
    UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
        for i, form in ipairs(forms) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = form
            info.value = form
            local pickedForm = form -- capture

			info.func = function()
				UIDropDownMenu_SetSelectedValue(dd, this.value)
				UIDropDownMenu_SetText(this.value, dd)

				if condType == "ability" then
					data.conditions.ability = data.conditions.ability or {}
					data.conditions.ability.form = this.value
				elseif condType == "aura" then
					data.conditions.aura = data.conditions.aura or {}
					data.conditions.aura.form = this.value
				end

				SafeRefresh()
				SafeEvaluate()
				UpdateCondFrameForKey(currentKey)
			end

            -- checked state based on the passed `data`
            local savedForm = (data and data.conditions and data.conditions[condType] and data.conditions[condType].form)
            info.checked = (savedForm == form)

            UIDropDownMenu_AddButton(info)
        end
    end)

    -- Restore visible value (saved or default)
    local savedForm = (data and data.conditions and data.conditions[condType] and data.conditions[condType].form) or "All"
    -- pick the ID corresponding to savedForm (fallback to SetText if SetSelectedID isn't available)
    for i, f in ipairs(forms) do
        if f == savedForm then
            UIDropDownMenu_SetSelectedID(dd, i)
            if UIDropDownMenu_SetText then
                UIDropDownMenu_SetText(savedForm, dd)
            else
                local t = _G[dd:GetName() .. "Text"]
                if t and t.SetText then t:SetText(savedForm) end
            end
            break
        end
    end

    dd._initializedForKey = thisKey
    dd._initializedForType = condType
end


----------------------------------------------------------------
-- Exclusive helper functions (moved outside CreateConditionsUI)
----------------------------------------------------------------
local function SetExclusiveAbilityMode(mode)
    if not currentKey then return end
    local d = EnsureDBEntry(currentKey)
    d.conditions = d.conditions or {}
    d.conditions.ability = d.conditions.ability or {}
    d.conditions.ability.mode = mode
    UpdateCondFrameForKey(currentKey)
    SafeRefresh()
	SafeEvaluate()
end

-- independent combat flag toggles (inCombat / outCombat)
local function SetCombatFlag(typeTable, which, enabled)
    if not currentKey then return end
    local d = EnsureDBEntry(currentKey)
    d.conditions = d.conditions or {}
    d.conditions[typeTable] = d.conditions[typeTable] or {}
    if which == "in" then
        d.conditions[typeTable].inCombat = enabled and true or false
    elseif which == "out" then
        d.conditions[typeTable].outCombat = enabled and true or false
    end
    d.conditions[typeTable].combat = nil
    UpdateCondFrameForKey(currentKey)
    SafeRefresh()
	SafeEvaluate()
end

local function SetExclusiveTargetMode(mode)
    if not currentKey then return end
    local d = EnsureDBEntry(currentKey)
    d.conditions = d.conditions or {}
    d.conditions.ability = d.conditions.ability or {}
    d.conditions.ability.target = mode
    UpdateCondFrameForKey(currentKey)
    SafeRefresh()
	SafeEvaluate()
end

local function SetExclusiveAuraFoundMode(mode)
    if not currentKey then return end
    local d = EnsureDBEntry(currentKey)
    d.conditions = d.conditions or {}
    d.conditions.aura = d.conditions.aura or {}
    d.conditions.aura.mode = mode
    UpdateCondFrameForKey(currentKey)
    SafeRefresh()
	SafeEvaluate()
end

local function ClearDropdown(dropdown)
    if not dropdown then return end
    if UIDropDownMenu_Initialize then UIDropDownMenu_Initialize(dropdown, function() end) end
    if UIDropDownMenu_ClearAll then UIDropDownMenu_ClearAll(dropdown) end
    dropdown._initializedForKey = nil
    dropdown._initializedForType = nil
end
----------------------------------------------------------------
-- Conditions UI creation & wiring
----------------------------------------------------------------
local function CreateConditionsUI()
    if not condFrame then return end

    -- helpers
    local function MakeCheck(name, label, x, y)
        local cb = CreateFrame("CheckButton", name, condFrame, "UICheckButtonTemplate")
        cb:SetWidth(20); cb:SetHeight(20)
        cb:SetPoint("TOPLEFT", condFrame, "TOPLEFT", x, y)
        cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cb.text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        cb.text:SetText(label)
        return cb
    end
    local function MakeComparatorDD(name, x, y, width)
        local dd = CreateFrame("Frame", name, condFrame, "UIDropDownMenuTemplate")
        dd:SetPoint("TOPLEFT", condFrame, "TOPLEFT", x, y)
        if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, width or 55, dd) end
        return dd
    end
    local function MakeSmallEdit(name, x, y, width)
        local eb = CreateFrame("EditBox", name, condFrame, "InputBoxTemplate")
        eb:SetWidth(width or 44)
        eb:SetHeight(18)
        eb:SetPoint("TOPLEFT", condFrame, "TOPLEFT", x, y)
        eb:SetAutoFocus(false)
        eb:SetJustifyH("CENTER")
        eb:SetFontObject("GameFontNormalSmall")
        return eb
    end

    -- row positions
    local row1_y, row2_y, row3_y, row4_y, row5_y = -145, -170, -195, -220, -245

    -- ability rows
    if GetNampowerVersion then
        condFrame.cond_ability_usable = MakeCheck("DoiteCond_Ability_Usable", "Usable", 20, row1_y)
    else
        condFrame.cond_ability_usable = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        condFrame.cond_ability_usable:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 24, row1_y + 3)
        condFrame.cond_ability_usable:SetText("(Usable req. Nampower mod)")
        condFrame.cond_ability_usable:SetWidth(80)
    end
    condFrame.cond_ability_notcd  = MakeCheck("DoiteCond_Ability_NotCD", "Not on cooldown", 110, row1_y)
    condFrame.cond_ability_oncd   = MakeCheck("DoiteCond_Ability_OnCD", "On cooldown", 230, row1_y)

    condFrame.cond_ability_incombat   = MakeCheck("DoiteCond_Ability_InCombat", "In combat", 20, row2_y)
    condFrame.cond_ability_outcombat  = MakeCheck("DoiteCond_Ability_OutCombat", "Out of combat", 110, row2_y)

    condFrame.cond_ability_target_help = MakeCheck("DoiteCond_Ability_TargetHelp", "Target (help)", 20, row3_y)
    condFrame.cond_ability_target_harm = MakeCheck("DoiteCond_Ability_TargetHarm", "Target (harm)", 120, row3_y)
    condFrame.cond_ability_target_self = MakeCheck("DoiteCond_Ability_TargetSelf", "Target (self)", 220, row3_y)

    condFrame.cond_ability_glow = MakeCheck("DoiteCond_Ability_Glow", "Glow", 20, row4_y)
    condFrame.cond_ability_power = MakeCheck("DoiteCond_Ability_PowerCB", "Power", 90, row4_y)
    condFrame.cond_ability_power_comp = MakeComparatorDD("DoiteCond_Ability_PowerComp", 155, row4_y+3, 50)
    condFrame.cond_ability_power_val  = MakeSmallEdit("DoiteCond_Ability_PowerVal", 250, row4_y-2, 40)
    condFrame.cond_ability_power_val_enter = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_power_val_enter:SetPoint("LEFT", condFrame.cond_ability_power_val, "RIGHT", 4, 0)
    condFrame.cond_ability_power_val_enter:SetText("(%)")
    condFrame.cond_ability_power_val_enter:Hide()

    condFrame.cond_ability_slider = MakeCheck("DoiteCond_Ability_Slider", "Soon off CD", 90, row5_y)
    condFrame.cond_ability_slider_dir = CreateFrame("Frame", "DoiteCond_Ability_SliderDir", condFrame, "UIDropDownMenuTemplate")
    condFrame.cond_ability_slider_dir:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 170, row5_y+3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 60, condFrame.cond_ability_slider_dir) end

    condFrame.cond_ability_remaining_cb   = MakeCheck("DoiteCond_Ability_RemainingCB", "Remaining", 90, row5_y)
    condFrame.cond_ability_remaining_comp = MakeComparatorDD("DoiteCond_Ability_RemComp", 155, row5_y+3, 50)
    condFrame.cond_ability_remaining_val  = MakeSmallEdit("DoiteCond_Ability_RemVal", 250, row5_y-2, 40)
    condFrame.cond_ability_remaining_val_enter = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_remaining_val_enter:SetPoint("LEFT", condFrame.cond_ability_remaining_val, "RIGHT", 4, 0)
    condFrame.cond_ability_remaining_val_enter:SetText("(sec.)")
    condFrame.cond_ability_remaining_val_enter:Hide()

    condFrame.cond_ability_greyscale = MakeCheck("DoiteCond_Ability_Greyscale", "Grey", 20, row5_y)

    -- === Buff/Debuff rows ===
    condFrame.cond_aura_found   = MakeCheck("DoiteCond_Aura_Found", "Aura found", 20, row1_y)
	condFrame.cond_aura_missing = MakeCheck("DoiteCond_Aura_Missing", "Aura missing", 110, row1_y)
	condFrame.cond_aura_tip = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	condFrame.cond_aura_tip:SetPoint("LEFT", condFrame.cond_aura_missing.text, "RIGHT", 10, 0)
	condFrame.cond_aura_tip:SetText("(to show icon, aura must be applied once)")
	condFrame.cond_aura_tip:SetWidth(120)
	condFrame.cond_aura_tip:Hide()


    condFrame.cond_aura_incombat   = MakeCheck("DoiteCond_Aura_InCombat", "In combat", 20, row2_y)
    condFrame.cond_aura_outcombat  = MakeCheck("DoiteCond_Aura_OutCombat", "Out of combat", 110, row2_y)

	condFrame.cond_aura_target_help = MakeCheck("DoiteCond_Aura_TargetHelp", "Target (help)", 20, row3_y)
	condFrame.cond_aura_target_harm = MakeCheck("DoiteCond_Aura_TargetHarm", "Target (harm)", 120, row3_y)
	condFrame.cond_aura_onself      = MakeCheck("DoiteCond_Aura_OnSelf", "On player (self)", 220, row3_y)

    condFrame.cond_aura_stacks_cb   = MakeCheck("DoiteCond_Aura_StacksCB", "Stacks", 90, row4_y)
    condFrame.cond_aura_stacks_comp = MakeComparatorDD("DoiteCond_Aura_StacksComp", 155, row4_y+3, 50)
    condFrame.cond_aura_stacks_val  = MakeSmallEdit("DoiteCond_Aura_StacksVal", 250, row4_y-2, 40)
    condFrame.cond_aura_stacks_val_enter = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_stacks_val_enter:SetPoint("LEFT", condFrame.cond_aura_stacks_val, "RIGHT", 4, 0)
    condFrame.cond_aura_stacks_val_enter:SetText("(#)")
    condFrame.cond_aura_stacks_val_enter:Hide()

    condFrame.cond_aura_glow = MakeCheck("DoiteCond_Aura_Glow", "Glow", 20, row4_y)
    condFrame.cond_aura_remaining_cb   = MakeCheck("DoiteCond_Aura_RemCB", "Remaining", 90, row5_y)
    condFrame.cond_aura_remaining_comp = MakeComparatorDD("DoiteCond_Aura_RemComp", 155, row5_y+3, 50)
    condFrame.cond_aura_remaining_val  = MakeSmallEdit("DoiteCond_Aura_RemVal", 250, row5_y-2, 40)
    condFrame.cond_aura_remaining_val_enter = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_remaining_val_enter:SetPoint("LEFT", condFrame.cond_aura_remaining_val, "RIGHT", 4, 0)
    condFrame.cond_aura_remaining_val_enter:SetText("(sec.)")
    condFrame.cond_aura_remaining_val_enter:Hide()

    condFrame.cond_aura_greyscale = MakeCheck("DoiteCond_Aura_Greyscale", "Grey", 20, row5_y)

    ----------------------------------------------------------------
    -- 'Form' dropdowns
    ----------------------------------------------------------------
    condFrame.cond_ability_formDD = CreateFrame("Frame", "DoiteCond_Ability_FormDD", condFrame, "UIDropDownMenuTemplate")
    condFrame.cond_ability_formDD:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 200, row2_y+3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 90, condFrame.cond_ability_formDD) end
    condFrame.cond_ability_formDD:Hide()
	ClearDropdown(condFrame.cond_ability_formDD)
	ClearDropdown(condFrame.cond_aura_formDD)

    condFrame.cond_aura_formDD = CreateFrame("Frame", "DoiteCond_Aura_FormDD", condFrame, "UIDropDownMenuTemplate")
    condFrame.cond_aura_formDD:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 200, row2_y+3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 90, condFrame.cond_aura_formDD) end
    condFrame.cond_aura_formDD:Hide()
	ClearDropdown(condFrame.cond_ability_formDD)
	ClearDropdown(condFrame.cond_aura_formDD)

    ----------------------------------------------------------------
    -- Wiring: enforce exclusivity immediately + save to DB
    ----------------------------------------------------------------

    -- Ability row1 scripts (Usable / NotCD / OnCD)
    if GetNampowerVersion then
		condFrame.cond_ability_usable:SetScript("OnClick", function()
			if this:GetChecked() then
				condFrame.cond_ability_notcd:SetChecked(false)
				condFrame.cond_ability_oncd:SetChecked(false)
				SetExclusiveAbilityMode("usable")
			else
				SetExclusiveAbilityMode(nil)
			end
		end)
	end
    condFrame.cond_ability_notcd:SetScript("OnClick", function()
        if this:GetChecked() then
			if GetNampowerVersion then
				condFrame.cond_ability_usable:SetChecked(false)
			end
            condFrame.cond_ability_oncd:SetChecked(false)
            SetExclusiveAbilityMode("notcd")
        else
            SetExclusiveAbilityMode(nil)
        end
    end)
    condFrame.cond_ability_oncd:SetScript("OnClick", function()
        if this:GetChecked() then
			if GetNampowerVersion then
				condFrame.cond_ability_usable:SetChecked(false)
			end
            condFrame.cond_ability_notcd:SetChecked(false)
            SetExclusiveAbilityMode("oncd")
        else
            SetExclusiveAbilityMode(nil)
        end
    end)

    -- Ability combat row 2 - toggles are now independent (not exclusive)
	condFrame.cond_ability_incombat:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end

		if not this:GetChecked() and not condFrame.cond_ability_outcombat:GetChecked() then
			this:SetChecked(true)
			return
		end

		SetCombatFlag("ability", "in", this:GetChecked())
	end)

	condFrame.cond_ability_outcombat:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end

		if not this:GetChecked() and not condFrame.cond_ability_incombat:GetChecked() then
			this:SetChecked(true)
			return
		end

		SetCombatFlag("ability", "out", this:GetChecked())
	end)


	-- Ability target row (multi-select, enforce at least one)
	local function SaveAbilityTargetsFromUI()
		if not currentKey then return end
		local d = EnsureDBEntry(currentKey)
		d.conditions = d.conditions or {}
		d.conditions.ability = d.conditions.ability or {}
		d.conditions.ability.targetHelp = condFrame.cond_ability_target_help:GetChecked() and true or false
		d.conditions.ability.targetHarm = condFrame.cond_ability_target_harm:GetChecked() and true or false
		d.conditions.ability.targetSelf = condFrame.cond_ability_target_self:GetChecked() and true or false
	end

	condFrame.cond_ability_target_help:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		SaveAbilityTargetsFromUI()
		SafeRefresh(); SafeEvaluate()
	end)

	condFrame.cond_ability_target_harm:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		SaveAbilityTargetsFromUI()
		SafeRefresh(); SafeEvaluate()
	end)

	condFrame.cond_ability_target_self:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		SaveAbilityTargetsFromUI()
		SafeRefresh(); SafeEvaluate()
	end)


    -- Aura exclusivity (found / missing)
    condFrame.cond_aura_found:SetScript("OnClick", function()
        if this:GetChecked() then
            condFrame.cond_aura_missing:SetChecked(false)
            SetExclusiveAuraFoundMode("found")
        else
            SetExclusiveAuraFoundMode(nil)
        end
    end)
    condFrame.cond_aura_missing:SetScript("OnClick", function()
        if this:GetChecked() then
            condFrame.cond_aura_found:SetChecked(false)
            SetExclusiveAuraFoundMode("missing")
        else
            SetExclusiveAuraFoundMode(nil)
        end
    end)

    -- Aura combat row 2 - toggles (independent)
	condFrame.cond_aura_incombat:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end

		if not this:GetChecked() and not condFrame.cond_aura_outcombat:GetChecked() then
			this:SetChecked(true)
			return
		end

		SetCombatFlag("aura", "in", this:GetChecked())
	end)

	condFrame.cond_aura_outcombat:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end

		if not this:GetChecked() and not condFrame.cond_aura_incombat:GetChecked() then
			this:SetChecked(true)
			return
		end

		SetCombatFlag("aura", "out", this:GetChecked())
	end)

	-- Aura target row (Self is exclusive; Help/Harm can combine; at least one must be checked)
	local function SaveAuraTargets()
		if not currentKey then return end
		local d = EnsureDBEntry(currentKey)
		d.conditions = d.conditions or {}
		d.conditions.aura = d.conditions.aura or {}
		d.conditions.aura.targetHelp = condFrame.cond_aura_target_help:GetChecked() and true or false
		d.conditions.aura.targetHarm = condFrame.cond_aura_target_harm:GetChecked() and true or false
		d.conditions.aura.targetSelf = condFrame.cond_aura_onself:GetChecked()      and true or false
	end

	local function EnforceAuraExclusivity(changedBox)
		local h  = condFrame.cond_aura_target_help:GetChecked()
		local hm = condFrame.cond_aura_target_harm:GetChecked()
		local s  = condFrame.cond_aura_onself:GetChecked()

		-- Self exclusive: if Self checked, uncheck Help/Harm
		if changedBox == condFrame.cond_aura_onself and s then
			condFrame.cond_aura_target_help:SetChecked(false)
			condFrame.cond_aura_target_harm:SetChecked(false)
		end

		-- If Help/Harm gets checked while Self is on, turn Self off
		if (changedBox == condFrame.cond_aura_target_help and condFrame.cond_aura_target_help:GetChecked())
		   or (changedBox == condFrame.cond_aura_target_harm and condFrame.cond_aura_target_harm:GetChecked()) then
			if condFrame.cond_aura_onself:GetChecked() then
				condFrame.cond_aura_onself:SetChecked(false)
			end
		end

		-- At least one must remain checked
		h  = condFrame.cond_aura_target_help:GetChecked()
		hm = condFrame.cond_aura_target_harm:GetChecked()
		s  = condFrame.cond_aura_onself:GetChecked()
		if (not h) and (not hm) and (not s) then
			-- Re-check the one the user just toggled off
			if changedBox then changedBox:SetChecked(true) end
		end
	end

	condFrame.cond_aura_target_help:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		EnforceAuraExclusivity(this)
		SaveAuraTargets()
		SafeRefresh(); SafeEvaluate()
		UpdateCondFrameForKey(currentKey)
	end)

	condFrame.cond_aura_target_harm:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		EnforceAuraExclusivity(this)
		SaveAuraTargets()
		SafeRefresh(); SafeEvaluate()
		UpdateCondFrameForKey(currentKey)
	end)

	condFrame.cond_aura_onself:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		EnforceAuraExclusivity(this)
		SaveAuraTargets()
		SafeRefresh(); SafeEvaluate()
		UpdateCondFrameForKey(currentKey)
	end)


    -- Aura remaining toggle
    condFrame.cond_aura_remaining_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.remainingEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Aura stacks toggle
    condFrame.cond_aura_stacks_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.stacksEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Aura glow / greyscale
    condFrame.cond_aura_glow:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.glow = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)
    condFrame.cond_aura_greyscale:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.greyscale = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- dropdown initializers
    -- comparator choices for ability power / remaining, aura remaining / stacks
    local function InitComparatorDD(ddframe, commitFunc)
        UIDropDownMenu_Initialize(ddframe, function(frame, level, menuList)
            local info
            local choices = { ">=", "<=", "==" }
            for _, c in ipairs(choices) do
                local picked = c
                info = {}
                info.text = picked
                info.value = picked
                info.func = function(button)
                    local val = (button and button.value) or picked
                    if commitFunc then pcall(commitFunc, val) end
                    UIDropDownMenu_SetSelectedValue(ddframe, val)
                    UIDropDownMenu_SetText(val, ddframe)
                    CloseDropDownMenus()
                end
                -- checked must compare against the dropdown's current selected value
                info.checked = (UIDropDownMenu_GetSelectedValue(ddframe) == picked)
                UIDropDownMenu_AddButton(info)
            end
        end)
    end


    -- slider direction dd
    UIDropDownMenu_Initialize(condFrame.cond_ability_slider_dir, function(frame, level, menuList)
        local info
        local choices = { "left", "right", "center", "up", "down" }
        for _, c in ipairs(choices) do
            local picked = c
            info = {}
            info.text = picked
            info.value = picked
            info.func = function(button)
                local val = (button and button.value) or picked
                if not currentKey then return end
                local d = EnsureDBEntry(currentKey)
                d.conditions = d.conditions or {}
                d.conditions.ability = d.conditions.ability or {}
                d.conditions.ability.sliderDir = val
                UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_slider_dir, val)
                UIDropDownMenu_SetText(val, condFrame.cond_ability_slider_dir)
                CloseDropDownMenus()
                SafeRefresh()
				SafeEvaluate()
            end
            info.checked = (UIDropDownMenu_GetSelectedValue(condFrame.cond_ability_slider_dir) == picked)
            UIDropDownMenu_AddButton(info)
        end
    end)


    -- attach comparator inits with commit functions that write to DB
    InitComparatorDD(condFrame.cond_ability_power_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.powerComp = picked
        SafeRefresh()
		SafeEvaluate()
    end)

    InitComparatorDD(condFrame.cond_ability_remaining_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.remainingComp = picked
        SafeRefresh()
		SafeEvaluate()
    end)

    InitComparatorDD(condFrame.cond_aura_remaining_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.remainingComp = picked
        SafeRefresh()
		SafeEvaluate()
    end)

    InitComparatorDD(condFrame.cond_aura_stacks_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.stacksComp = picked
        SafeRefresh()
		SafeEvaluate()
    end)

    -- editbox commit handlers (enter / focus lost)
    condFrame.cond_ability_power_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        local minv, maxv = -999999, 999999
        if not v then
            local d = EnsureDBEntry(currentKey)
            d.conditions = d.conditions or {}
            d.conditions.ability = d.conditions.ability or {}
            this:SetText(tostring(d.conditions.ability.powerVal or 0))
            return
        end
        if v < minv then v = minv end
        if v > maxv then v = maxv end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.powerVal = v
        SafeRefresh()
		SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local handling_power = false
        condFrame.cond_ability_power_val:SetScript("OnEditFocusLost", function()
            if handling_power then return end
            handling_power = true
            this:GetScript("OnEnterPressed")()
            handling_power = false
        end)
    end

    condFrame.cond_ability_remaining_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions and d.conditions.ability and d.conditions.ability.remainingVal) or 0))
            return
        end
        if v < 0 then v = 0 end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.remainingVal = v
        SafeRefresh()
		SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local handling_ability_remaining = false
        condFrame.cond_ability_remaining_val:SetScript("OnEditFocusLost", function()
            if handling_ability_remaining then return end
            handling_ability_remaining = true
            this:GetScript("OnEnterPressed")()
            handling_ability_remaining = false
        end)
    end

    condFrame.cond_aura_remaining_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions and d.conditions.aura and d.conditions.aura.remainingVal) or 0))
            return
        end
        if v < 0 then v = 0 end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.remainingVal = v
        SafeRefresh()
		SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local handling_aura_remaining = false
        condFrame.cond_aura_remaining_val:SetScript("OnEditFocusLost", function()
            if handling_aura_remaining then return end
            handling_aura_remaining = true
            this:GetScript("OnEnterPressed")()
            handling_aura_remaining = false
        end)
    end

    condFrame.cond_aura_stacks_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions and d.conditions.aura and d.conditions.aura.stacksVal) or 0))
            return
        end
        if v < 0 then v = 0 end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.stacksVal = v
        SafeRefresh()
		SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local handling_aura_stacks = false
        condFrame.cond_aura_stacks_val:SetScript("OnEditFocusLost", function()
            if handling_aura_stacks then return end
            handling_aura_stacks = true
            this:GetScript("OnEnterPressed")()
            handling_aura_stacks = false
        end)
    end

    -- Checkbox / checkbox wiring

    -- Ability power toggle
    condFrame.cond_ability_power:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.powerEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Ability slider toggle
    condFrame.cond_ability_slider:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.slider = this:GetChecked() and true or false
        if d.conditions.ability.slider and not d.conditions.ability.sliderDir then
            d.conditions.ability.sliderDir = "center"
        end
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Ability remaining toggle
    condFrame.cond_ability_remaining_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.remainingEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Ability glow/greyscale (separate checkboxes)
    condFrame.cond_ability_glow:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.glow = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)
    condFrame.cond_ability_greyscale:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.greyscale = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Aura wiring (found/missing exclusives)
    condFrame.cond_aura_found:SetScript("OnClick", function()
        if this:GetChecked() then SetExclusiveAuraFoundMode("found") else SetExclusiveAuraFoundMode(nil) end
    end)
    condFrame.cond_aura_missing:SetScript("OnClick", function()
        if this:GetChecked() then SetExclusiveAuraFoundMode("missing") else SetExclusiveAuraFoundMode(nil) end
    end)

	condFrame.cond_aura_incombat:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		if not this:GetChecked() and not condFrame.cond_aura_outcombat:GetChecked() then
			this:SetChecked(true)
			return
		end
		SetCombatFlag("aura", "in", this:GetChecked())
	end)

	condFrame.cond_aura_outcombat:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		if not this:GetChecked() and not condFrame.cond_aura_incombat:GetChecked() then
			this:SetChecked(true)
			return
		end
		SetCombatFlag("aura", "out", this:GetChecked())
	end)

    -- Aura target row wiring done above

    -- Form dropdowns are initialized/updated from UpdateConditionsUI
    condFrame.cond_ability_formDD:Hide()
	ClearDropdown(condFrame.cond_ability_formDD)
	ClearDropdown(condFrame.cond_aura_formDD)
    condFrame.cond_aura_formDD:Hide()
	ClearDropdown(condFrame.cond_ability_formDD)
	ClearDropdown(condFrame.cond_aura_formDD)

    -- hide all controls by default
    condFrame.cond_ability_usable:Hide()
    condFrame.cond_ability_notcd:Hide()
    condFrame.cond_ability_oncd:Hide()
    condFrame.cond_ability_incombat:Hide()
    condFrame.cond_ability_outcombat:Hide()
    condFrame.cond_ability_target_help:Hide()
    condFrame.cond_ability_target_harm:Hide()
    condFrame.cond_ability_target_self:Hide()
    condFrame.cond_ability_power:Hide()
    condFrame.cond_ability_power_comp:Hide()
    condFrame.cond_ability_power_val:Hide()
    condFrame.cond_ability_power_val_enter:Hide()
    condFrame.cond_ability_glow:Hide()
    condFrame.cond_ability_greyscale:Hide()
    condFrame.cond_ability_slider:Hide()
    condFrame.cond_ability_slider_dir:Hide()
    condFrame.cond_ability_remaining_cb:Hide()
    condFrame.cond_ability_remaining_comp:Hide()
    condFrame.cond_ability_remaining_val:Hide()
    condFrame.cond_ability_remaining_val_enter:Hide()
    condFrame.cond_ability_greyscale:Hide()

    condFrame.cond_aura_found:Hide()
    condFrame.cond_aura_missing:Hide()
    condFrame.cond_aura_incombat:Hide()
    condFrame.cond_aura_outcombat:Hide()
	condFrame.cond_aura_target_help:Hide()
	condFrame.cond_aura_target_harm:Hide()
	condFrame.cond_aura_onself:Hide()
    condFrame.cond_aura_glow:Hide()
    condFrame.cond_aura_greyscale:Hide()
    condFrame.cond_aura_remaining_cb:Hide()
    condFrame.cond_aura_remaining_comp:Hide()
    condFrame.cond_aura_remaining_val:Hide()
    condFrame.cond_aura_remaining_val_enter:Hide()
    condFrame.cond_aura_stacks_cb:Hide()
    condFrame.cond_aura_stacks_comp:Hide()
    condFrame.cond_aura_stacks_val:Hide()
    condFrame.cond_aura_stacks_val_enter:Hide()
    condFrame.cond_aura_greyscale:Hide()
end

-- Update conditions UI to reflect DB for the currentKey/data
local function UpdateConditionsUI(data)
    if not condFrame then return end
    if not data then return end
    if not data.conditions then data.conditions = {} end
    local c = data.conditions

    -- ABILITY
    if data.type == "Ability" then
        -- show rows
        condFrame.cond_ability_usable:Show()
        condFrame.cond_ability_notcd:Show()
        condFrame.cond_ability_oncd:Show()
        condFrame.cond_ability_incombat:Show()
        condFrame.cond_ability_outcombat:Show()
        condFrame.cond_ability_target_help:Show()
        condFrame.cond_ability_target_harm:Show()
        condFrame.cond_ability_target_self:Show()
        condFrame.cond_ability_power:Show()
        condFrame.cond_ability_glow:Show()
        condFrame.cond_ability_greyscale:Show()
        condFrame.cond_ability_slider:Show()
        condFrame.cond_ability_remaining_cb:Show()

        -- exclusives
        local mode = (c.ability and c.ability.mode) or nil
        condFrame.cond_ability_usable:SetChecked(mode == "usable")
        condFrame.cond_ability_notcd:SetChecked(mode == "notcd")
        condFrame.cond_ability_oncd:SetChecked(mode == "oncd")

        -- combat -> now independent booleans, with fallback to legacy string 'combat'
        local inC, outC
        if c.ability and (c.ability.inCombat ~= nil or c.ability.outCombat ~= nil) then
            inC = c.ability.inCombat and true or false
            outC = c.ability.outCombat and true or false
        else
            -- legacy handling
            local cm = c.ability and c.ability.combat or nil
            if cm == "in" then inC, outC = true, false
            elseif cm == "out" then inC, outC = false, true
            else inC, outC = true, true -- default both
            end
        end
        condFrame.cond_ability_incombat:SetChecked(inC)
        condFrame.cond_ability_outcombat:SetChecked(outC)

		-- multi-select booleans
		local ah = (c.ability and c.ability.targetHelp) == true
		local ar = (c.ability and c.ability.targetHarm) == true
		local as = (c.ability and c.ability.targetSelf) == true
		condFrame.cond_ability_target_help:SetChecked(ah)
		condFrame.cond_ability_target_harm:SetChecked(ar)
		condFrame.cond_ability_target_self:SetChecked(as)


        -- power controls
        local pEnabled = (c.ability and c.ability.powerEnabled) and true or false
        condFrame.cond_ability_power:SetChecked(pEnabled)
        if pEnabled then
            condFrame.cond_ability_power_comp:Show()
            condFrame.cond_ability_power_val:Show()
            condFrame.cond_ability_power_val_enter:Show()
            local comp = (c.ability and c.ability.powerComp) or ""
            UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_power_comp, comp)
            UIDropDownMenu_SetText(comp, condFrame.cond_ability_power_comp)
            condFrame.cond_ability_power_val:SetText(tostring((c.ability and c.ability.powerVal) or 0))
        else
            condFrame.cond_ability_power_comp:Hide()
            condFrame.cond_ability_power_val:Hide()
            condFrame.cond_ability_power_val_enter:Hide()
        end

        -- glow & greyscale states
        condFrame.cond_ability_glow:SetChecked((c.ability and c.ability.glow) or false)
        condFrame.cond_ability_greyscale:SetChecked((c.ability and c.ability.greyscale) or false)

        -- slider vs remaining
        local slidEnabled = (c.ability and c.ability.slider) and true or false
        condFrame.cond_ability_slider:SetChecked(slidEnabled)
        local remEnabled = (c.ability and c.ability.remainingEnabled) and true or false
        condFrame.cond_ability_remaining_cb:SetChecked(remEnabled)

        if mode == "oncd" then
            condFrame.cond_ability_slider:Disable()
            condFrame.cond_ability_slider:Hide()
            condFrame.cond_ability_slider_dir:Hide()
            if remEnabled then
                condFrame.cond_ability_remaining_comp:Show()
                condFrame.cond_ability_remaining_val:Show()
                condFrame.cond_ability_remaining_val_enter:Show()
                local comp = (c.ability and c.ability.remainingComp) or ""
                UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_remaining_comp, comp)
                UIDropDownMenu_SetText(comp, condFrame.cond_ability_remaining_comp)
                condFrame.cond_ability_remaining_val:SetText(tostring((c.ability and c.ability.remainingVal) or 0))
            else
                condFrame.cond_ability_remaining_comp:Hide()
                condFrame.cond_ability_remaining_val:Hide()
                condFrame.cond_ability_remaining_val_enter:Hide()
            end
        else
            condFrame.cond_ability_slider:Enable()
            condFrame.cond_ability_slider:Show()
            if slidEnabled then
                condFrame.cond_ability_slider_dir:Show()
                local dir = (c.ability and c.ability.sliderDir) or "center"
                UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_slider_dir, dir)
                UIDropDownMenu_SetText(dir, condFrame.cond_ability_slider_dir)
            else
                condFrame.cond_ability_slider_dir:Hide()
            end
            condFrame.cond_ability_remaining_cb:SetChecked(false)
            condFrame.cond_ability_remaining_comp:Hide()
            condFrame.cond_ability_remaining_val:Hide()
            condFrame.cond_ability_remaining_val_enter:Hide()
            condFrame.cond_ability_remaining_cb:Hide()
        end

        -- initialize and show/hide Form dropdown based on player class availability
        local choices = (function()
            local _, cls = UnitClass("player")
            cls = cls and string.upper(cls) or ""
            if cls == "WARRIOR" or cls == "ROGUE" or cls == "DRUID" then return true else return false end
        end)()

		-- hide the aura dropdown if it exists
		if condFrame.cond_aura_formDD then
			condFrame.cond_aura_formDD:Hide()
		end

		if choices and condFrame.cond_ability_formDD then
			condFrame.cond_ability_formDD:Show()
			ClearDropdown(condFrame.cond_ability_formDD)
			InitFormDropdown(condFrame.cond_ability_formDD, data, "ability")
			UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_formDD, (c.ability and c.ability.form) or "All")
			UIDropDownMenu_SetText((c.ability and c.ability.form) or "All", condFrame.cond_ability_formDD)
		elseif condFrame.cond_ability_formDD then
			condFrame.cond_ability_formDD:Hide()
			ClearDropdown(condFrame.cond_ability_formDD)
		end

        -- hide aura controls
        condFrame.cond_aura_found:Hide()
        condFrame.cond_aura_missing:Hide()
        condFrame.cond_aura_incombat:Hide()
        condFrame.cond_aura_outcombat:Hide()
		condFrame.cond_aura_target_help:Hide()
		condFrame.cond_aura_target_harm:Hide()
		condFrame.cond_aura_onself:Hide()
        condFrame.cond_aura_glow:Hide()
        condFrame.cond_aura_greyscale:Hide()
        condFrame.cond_aura_remaining_cb:Hide()
        condFrame.cond_aura_remaining_comp:Hide()
        condFrame.cond_aura_remaining_val:Hide()
        condFrame.cond_aura_remaining_val_enter:Hide()
        condFrame.cond_aura_stacks_cb:Hide()
        condFrame.cond_aura_stacks_comp:Hide()
        condFrame.cond_aura_stacks_val:Hide()
        condFrame.cond_aura_stacks_val_enter:Hide()
		condFrame.cond_aura_tip:Hide()

    -- AURA (Buff/Debuff)
    else
        condFrame.cond_aura_found:Show()
        condFrame.cond_aura_missing:Show()
		if condFrame.cond_aura_tip then condFrame.cond_aura_tip:Show() end
        condFrame.cond_aura_incombat:Show()
        condFrame.cond_aura_outcombat:Show()
		condFrame.cond_aura_target_help:Show()
		condFrame.cond_aura_target_harm:Show()
		condFrame.cond_aura_onself:Show()
        condFrame.cond_aura_glow:Show()
        condFrame.cond_aura_greyscale:Show()

        -- mode
        local amode = (c.aura and c.aura.mode) or nil
        condFrame.cond_aura_found:SetChecked(amode == "found")
        condFrame.cond_aura_missing:SetChecked(amode == "missing")

        -- combat flags (independent)
        local aIn, aOut
        if c.aura and (c.aura.inCombat ~= nil or c.aura.outCombat ~= nil) then
            aIn = c.aura.inCombat and true or false
            aOut = c.aura.outCombat and true or false
        else
            local cm = c.aura and c.aura.combat or nil
            if cm == "in" then aIn, aOut = true, false
            elseif cm == "out" then aIn, aOut = false, true
            else aIn, aOut = true, true
            end
        end
        condFrame.cond_aura_incombat:SetChecked(aIn)
        condFrame.cond_aura_outcombat:SetChecked(aOut)

		-- Read (treat nil as false here)
		local th = (c.aura and c.aura.targetHelp) and true or false
		local tm = (c.aura and c.aura.targetHarm) and true or false
		local ts = (c.aura and c.aura.targetSelf) and true or false

		-- Normalize: Self is exclusive vs Help/Harm
		if ts then th, tm = false, false end

		-- If somehow all false (old state), default to Self-only
		if (not th) and (not tm) and (not ts) then
			ts = true
			if c.aura then
				c.aura.targetSelf = true
				c.aura.targetHelp = false
				c.aura.targetHarm = false
			end
		end

		-- Reflect
		condFrame.cond_aura_target_help:SetChecked(th)
		condFrame.cond_aura_target_harm:SetChecked(tm)
		condFrame.cond_aura_onself:SetChecked(ts)

        condFrame.cond_aura_glow:SetChecked((c.aura and c.aura.glow) or false)
        condFrame.cond_aura_greyscale:SetChecked((c.aura and c.aura.greyscale) or false)

        -- initialize and show/hide Form dropdown based on player class availability
        local choices = (function()
            local _, cls = UnitClass("player")
            cls = cls and string.upper(cls) or ""
            if cls == "WARRIOR" or cls == "ROGUE" or cls == "DRUID" then return true else return false end
        end)()
		
		if condFrame.cond_ability_formDD then
			condFrame.cond_ability_formDD:Hide()
		end

		if choices and condFrame.cond_aura_formDD then
			condFrame.cond_aura_formDD:Show()
			ClearDropdown(condFrame.cond_aura_formDD)
			InitFormDropdown(condFrame.cond_aura_formDD, data, "aura")
			UIDropDownMenu_SetSelectedValue(condFrame.cond_aura_formDD, (c.aura and c.aura.form) or "All")
			UIDropDownMenu_SetText((c.aura and c.aura.form) or "All", condFrame.cond_aura_formDD)
		elseif condFrame.cond_aura_formDD then
			condFrame.cond_aura_formDD:Hide()
			ClearDropdown(condFrame.cond_aura_formDD)
		end

		-- Remaining (only valid when aura found AND On player (self))
		local aRemEnabled = (c.aura and c.aura.remainingEnabled) and true or false
		condFrame.cond_aura_remaining_cb:SetChecked(aRemEnabled)

		-- Only show the checkbox itself when mode is "found" AND Self is selected
		if amode == "found" and ts == true then
			condFrame.cond_aura_remaining_cb:Show()
			if aRemEnabled then
				condFrame.cond_aura_remaining_comp:Show()
				condFrame.cond_aura_remaining_val:Show()
				condFrame.cond_aura_remaining_val_enter:Show()
				local comp = (c.aura and c.aura.remainingComp) or ""
				UIDropDownMenu_SetSelectedValue(condFrame.cond_aura_remaining_comp, comp)
				UIDropDownMenu_SetText(comp, condFrame.cond_aura_remaining_comp)
				condFrame.cond_aura_remaining_val:SetText(tostring((c.aura and c.aura.remainingVal) or 0))
			else
				condFrame.cond_aura_remaining_comp:Hide()
				condFrame.cond_aura_remaining_val:Hide()
				condFrame.cond_aura_remaining_val_enter:Hide()
			end
		else
			condFrame.cond_aura_remaining_cb:Hide()
			condFrame.cond_aura_remaining_comp:Hide()
			condFrame.cond_aura_remaining_val:Hide()
			condFrame.cond_aura_remaining_val_enter:Hide()
		end

        -- Stacks (only valid when aura found)
        local aStacksEnabled = (c.aura and c.aura.stacksEnabled) and true or false
        condFrame.cond_aura_stacks_cb:SetChecked(aStacksEnabled)
        if amode == "found" and aStacksEnabled then
            condFrame.cond_aura_stacks_comp:Show()
            condFrame.cond_aura_stacks_val:Show()
            condFrame.cond_aura_stacks_val_enter:Show()
            local comp = (c.aura and c.aura.stacksComp) or ""
            UIDropDownMenu_SetSelectedValue(condFrame.cond_aura_stacks_comp, comp)
            UIDropDownMenu_SetText(comp, condFrame.cond_aura_stacks_comp)
            condFrame.cond_aura_stacks_val:SetText(tostring((c.aura and c.aura.stacksVal) or 0))
        else
            condFrame.cond_aura_stacks_comp:Hide()
            condFrame.cond_aura_stacks_val:Hide()
            condFrame.cond_aura_stacks_val_enter:Hide()
        end

		-- Only Stacks is globally gated by "found".
		-- Remaining is already handled above and must also be "On player (self)".
		if amode == "found" then
			condFrame.cond_aura_stacks_cb:Show()
		else
			condFrame.cond_aura_stacks_cb:Hide()
		end
		-- Do NOT touch cond_aura_remaining_cb here; its visibility was decided above.


        -- Hide all ability controls
        condFrame.cond_ability_usable:Hide()
        condFrame.cond_ability_notcd:Hide()
        condFrame.cond_ability_oncd:Hide()
        condFrame.cond_ability_incombat:Hide()
        condFrame.cond_ability_outcombat:Hide()
        condFrame.cond_ability_target_help:Hide()
        condFrame.cond_ability_target_harm:Hide()
        condFrame.cond_ability_target_self:Hide()
        condFrame.cond_ability_power:Hide()
        condFrame.cond_ability_power_comp:Hide()
        condFrame.cond_ability_power_val:Hide()
        condFrame.cond_ability_power_val_enter:Hide()
        condFrame.cond_ability_glow:Hide()
        condFrame.cond_ability_greyscale:Hide()
        condFrame.cond_ability_slider:Hide()
        condFrame.cond_ability_slider_dir:Hide()
        condFrame.cond_ability_remaining_cb:Hide()
        condFrame.cond_ability_remaining_comp:Hide()
        condFrame.cond_ability_remaining_val:Hide()
        condFrame.cond_ability_remaining_val_enter:Hide()
    end
end

----------------------------------------------------------------
-- End Conditions UI section
----------------------------------------------------------------

-- Update frame controls to reflect db for `key`
function UpdateCondFrameForKey(key)
    if not condFrame or not key then return end
    currentKey = key
    local data = EnsureDBEntry(key)

    -- Header: colored by type
    local typeColor = "|cffffffff"
    if data.type == "Ability" then typeColor = "|cff4da6ff"
    elseif data.type == "Buff" then typeColor = "|cff22ff22"
    elseif data.type == "Debuff" then typeColor = "|cffff4d4d" end
    condFrame.header:SetText("Edit: " .. (data.displayName or key) .. " " .. typeColor .. "(" .. (data.type or "") .. ")|r")

    -- Initialize group dropdown contents (pass current data to get 'checked' right)
    if condFrame.groupDD then
        InitGroupDropdown(condFrame.groupDD, data)
        local sel = data.group or "No"
        UIDropDownMenu_SetSelectedValue(condFrame.groupDD, sel)
        UIDropDownMenu_SetText(sel, condFrame.groupDD)
    end

    -- Leader checkbox logic & leader-only controls
    if condFrame.leaderCB then
        if not data.group then
            condFrame.leaderCB:Hide()
            if condFrame.growthDD then condFrame.growthDD:Hide() end
            if condFrame.numAurasLabel then condFrame.numAurasLabel:Hide() end
            if condFrame.numAurasDD then condFrame.numAurasDD:Hide() end
        else
            condFrame.leaderCB:Show()
            local leaders = BuildGroupLeaders()
            local leaderKey = leaders[data.group]
            if not leaderKey then
                data.isLeader = true
                condFrame.leaderCB:SetChecked(true)
                condFrame.leaderCB:Disable()
                if condFrame.growthDD then
                    condFrame.growthDD:Show()
                    InitGrowthDropdown(condFrame.growthDD, data)
                    UIDropDownMenu_SetSelectedValue(condFrame.growthDD, data.growth or "Horizontal Right")
                    UIDropDownMenu_SetText(data.growth or "Horizontal Right", condFrame.growthDD)
                end
                if condFrame.numAurasLabel and condFrame.numAurasDD then
                    condFrame.numAurasLabel:Show()
                    condFrame.numAurasDD:Show()
                    InitNumAurasDropdown(condFrame.numAurasDD, data)
                    UIDropDownMenu_SetSelectedValue(condFrame.numAurasDD, data.numAuras or 5)
                    UIDropDownMenu_SetText(tostring(data.numAuras or 5), condFrame.numAurasDD)
                end
            else
                if leaderKey == key then
                    condFrame.leaderCB:SetChecked(true)
                    condFrame.leaderCB:Disable()
                    if condFrame.growthDD then
                        condFrame.growthDD:Show()
                        InitGrowthDropdown(condFrame.growthDD, data)
                        UIDropDownMenu_SetSelectedValue(condFrame.growthDD, data.growth or "Horizontal Right")
                        UIDropDownMenu_SetText(data.growth or "Horizontal Right", condFrame.growthDD)
                    end
                    if condFrame.numAurasLabel and condFrame.numAurasDD then
                        condFrame.numAurasLabel:Show()
                        condFrame.numAurasDD:Show()
                        InitNumAurasDropdown(condFrame.numAurasDD, data)
                        UIDropDownMenu_SetSelectedValue(condFrame.numAurasDD, data.numAuras or 5)
                        UIDropDownMenu_SetText(tostring(data.numAuras or 5), condFrame.numAurasDD)
                    end
                else
                    condFrame.leaderCB:SetChecked(false)
                    condFrame.leaderCB:Enable()
                    if condFrame.growthDD then condFrame.growthDD:Hide() end
                    if condFrame.numAurasLabel then condFrame.numAurasLabel:Hide() end
                    if condFrame.numAurasDD then condFrame.numAurasDD:Hide() end
                end
            end
        end
    end

    -- Update Conditions UI (always visible area between top and POS & SIZE)
    UpdateConditionsUI(data)

    -- Show/hide Position & Size section (only when no group OR leader)
    if (not data.group) or data.isLeader then
        if condFrame.groupTitle3 then condFrame.groupTitle3:Show() end
        if condFrame.sep3 then condFrame.sep3:Show() end
        if condFrame.sliderX then condFrame.sliderX:Show() end
        if condFrame.sliderY then condFrame.sliderY:Show() end
        if condFrame.sliderSize then condFrame.sliderSize:Show() end
        if condFrame.sliderXBox then condFrame.sliderXBox:Show() end
        if condFrame.sliderYBox then condFrame.sliderYBox:Show() end
        if condFrame.sliderSizeBox then condFrame.sliderSizeBox:Show() end

        -- update slider positions/values (guarded)
        if condFrame.sliderX then condFrame.sliderX:SetValue(data.offsetX or 0) end
        if condFrame.sliderY then condFrame.sliderY:SetValue(data.offsetY or 0) end
        if condFrame.sliderSize then condFrame.sliderSize:SetValue(data.iconSize or 40) end

        -- update numeric editboxes if present
        if condFrame.sliderXBox then condFrame.sliderXBox:SetText(tostring(math.floor((data.offsetX or 0) + 0.5))) end
        if condFrame.sliderYBox then condFrame.sliderYBox:SetText(tostring(math.floor((data.offsetY or 0) + 0.5))) end
        if condFrame.sliderSizeBox then condFrame.sliderSizeBox:SetText(tostring(math.floor((data.iconSize or 40) + 0.5))) end
    else
        if condFrame.groupTitle3 then condFrame.groupTitle3:Hide() end
        if condFrame.sep3 then condFrame.sep3:Hide() end
        if condFrame.sliderX then condFrame.sliderX:Hide() end
        if condFrame.sliderY then condFrame.sliderY:Hide() end
        if condFrame.sliderSize then condFrame.sliderSize:Hide() end
        if condFrame.sliderXBox then condFrame.sliderXBox:Hide() end
        if condFrame.sliderYBox then condFrame.sliderYBox:Hide() end
        if condFrame.sliderSizeBox then condFrame.sliderSizeBox:Hide() end
    end
end

-- show/hide entry point
function DoiteConditions_Show(key)
    -- toggle: if same key and shown -> hide
    if condFrame and condFrame:IsShown() and currentKey == key then
        condFrame:Hide()
        currentKey = nil
        return
    end

    -- create the frame if needed
    if not condFrame then
        condFrame = CreateFrame("Frame", "DoiteConditionsFrame", UIParent)
        condFrame:SetWidth(355)
        condFrame:SetHeight(450)
        if DoiteAurasFrame and DoiteAurasFrame:GetName() then
            condFrame:SetPoint("TOPLEFT", DoiteAurasFrame, "TOPRIGHT", 5, 0)
        else
            condFrame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
        end

        condFrame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 16, edgeSize = 32,
            insets = { left=11, right=12, top=12, bottom=11 }
        })
        condFrame:SetBackdropColor(0,0,0,1)
        condFrame:SetBackdropBorderColor(1,1,1,1)
        condFrame:SetFrameStrata("FULLSCREEN_DIALOG")

        condFrame.header = condFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        condFrame.header:SetPoint("TOP", condFrame, "TOP", 0, -15)
        condFrame.header:SetText("Edit:")

        condFrame.groupTitle = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        condFrame.groupTitle:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 20, -40)
        condFrame.groupTitle:SetText("|cff6FA8DCGROUP & LEADER|r")

        local sep = condFrame:CreateTexture(nil, "ARTWORK")
        sep:SetHeight(1)
        sep:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 16, -55)
        sep:SetPoint("TOPRIGHT", condFrame, "TOPRIGHT", -16, -55)
        sep:SetTexture(1,1,1)
        if sep.SetVertexColor then sep:SetVertexColor(1,1,1,0.25) end

        condFrame.groupLabel = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        condFrame.groupLabel:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 20, -68)
        condFrame.groupLabel:SetText("Group this Aura?")

        condFrame.groupDD = CreateFrame("Frame", "DoiteConditions_GroupDD", condFrame, "UIDropDownMenuTemplate")
        condFrame.groupDD:SetPoint("LEFT", condFrame.groupLabel, "RIGHT", -10, -2)
        if UIDropDownMenu_SetWidth then
            pcall(UIDropDownMenu_SetWidth, 75, condFrame.groupDD)
        end

        condFrame.leaderCB = CreateFrame("CheckButton", nil, condFrame, "UICheckButtonTemplate")
        condFrame.leaderCB:SetWidth(20); condFrame.leaderCB:SetHeight(20)
        condFrame.leaderCB:SetPoint("Left", condFrame.groupDD, "Right", -10, 0)
        condFrame.leaderCB.text = condFrame.leaderCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        condFrame.leaderCB.text:SetPoint("LEFT", condFrame.leaderCB, "RIGHT", 2, 0)
        condFrame.leaderCB.text:SetText("Aura group leader")
        condFrame.leaderCB:Hide()

        condFrame.growthDD = CreateFrame("Frame", "DoiteConditions_GrowthDD", condFrame, "UIDropDownMenuTemplate")
        condFrame.growthDD:SetPoint("BOTTOMLEFT", condFrame.groupLabel, "BOTTOMLEFT", -18, -43)
        if UIDropDownMenu_SetWidth then
            pcall(UIDropDownMenu_SetWidth, 110, condFrame.growthDD)
        end
        condFrame.growthDD:Hide()

        -- Number of Auras label + dropdown
        condFrame.numAurasLabel = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        condFrame.numAurasLabel:SetPoint("LEFT", condFrame.growthDD, "RIGHT", -5, 2)
        condFrame.numAurasLabel:SetText("Number of Auras")
        condFrame.numAurasLabel:Hide()

        condFrame.numAurasDD = CreateFrame("Frame", "DoiteConditions_NumAurasDD", condFrame, "UIDropDownMenuTemplate")
        condFrame.numAurasDD:SetPoint("LEFT", condFrame.numAurasLabel, "RIGHT", -10, -2)
        if UIDropDownMenu_SetWidth then
            pcall(UIDropDownMenu_SetWidth, 75, condFrame.numAurasDD)
        end
        condFrame.numAurasDD:Hide()

        -- leaderCB click behavior
        condFrame.leaderCB:SetScript("OnClick", function(self)
            local cb = self or (condFrame and condFrame.leaderCB)
            if not currentKey then
                if cb then cb:SetChecked(false) end
                return
            end
            local data = DoiteAurasDB.spells[currentKey]
            if not data or not data.group then
                if cb then
                    cb:SetChecked(false)
                    cb:Hide()
                end
                return
            end

            if cb and cb:GetChecked() then
                local leaders = BuildGroupLeaders()
                local prev = leaders[data.group]
                if prev and prev ~= currentKey and DoiteAurasDB.spells[prev] then
                    DoiteAurasDB.spells[prev].isLeader = false
                end
                data.isLeader = true
                cb:SetChecked(true)
                cb:Disable()

                if condFrame.growthDD then
                    condFrame.growthDD:Show()
                    InitGrowthDropdown(condFrame.growthDD, data)
                    UIDropDownMenu_SetSelectedValue(condFrame.growthDD, data.growth or "Horizontal Right")
                    UIDropDownMenu_SetText(data.growth or "Horizontal Right", condFrame.growthDD)
                end
                if condFrame.numAurasLabel and condFrame.numAurasDD then
                    condFrame.numAurasLabel:Show()
                    condFrame.numAurasDD:Show()
                    InitNumAurasDropdown(condFrame.numAurasDD, data)
                    UIDropDownMenu_SetSelectedValue(condFrame.numAurasDD, data.numAuras or 5)
                    UIDropDownMenu_SetText(tostring(data.numAuras or 5), condFrame.numAurasDD)
                end
            end

            SafeRefresh()
			SafeEvaluate()
            UpdateCondFrameForKey(currentKey)
        end)

        condFrame.groupTitle2 = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        condFrame.groupTitle2:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 20, -125)
        condFrame.groupTitle2:SetText("|cff6FA8DCCONDITIONS & RULES|r")

        local sep2 = condFrame:CreateTexture(nil, "ARTWORK")
        sep2:SetHeight(1)
        sep2:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 16, -140)
        sep2:SetPoint("TOPRIGHT", condFrame, "TOPRIGHT", -16, -140)
        sep2:SetTexture(1,1,1)
        if sep2.SetVertexColor then sep2:SetVertexColor(1,1,1,0.25) end

        -- Create the Conditions UI section (self-contained)
        CreateConditionsUI()

        condFrame.groupTitle3 = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        condFrame.groupTitle3:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 20, -360)
        condFrame.groupTitle3:SetText("|cff6FA8DCPOSITION & SIZE|r")

        condFrame.sep3 = condFrame:CreateTexture(nil, "ARTWORK")
        condFrame.sep3:SetHeight(1)
        condFrame.sep3:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 16, -375)
        condFrame.sep3:SetPoint("TOPRIGHT", condFrame, "TOPRIGHT", -16, -275)
        condFrame.sep3:SetTexture(1,1,1)
        if condFrame.sep3.SetVertexColor then condFrame.sep3:SetVertexColor(1,1,1,0.25) end

        -- Sliders helper (makes a slider + small EditBox beneath it)
        local function MakeSlider(name, text, x, y, width, minVal, maxVal, step)
            local s = CreateFrame("Slider", name, condFrame, "OptionsSliderTemplate")
            s:SetWidth(width)
            s:SetHeight(16)
            s:SetMinMaxValues(minVal, maxVal)
            s:SetValueStep(step)
            s:SetPoint("TOPLEFT", condFrame, "TOPLEFT", x, y)

            local txt = _G[s:GetName() .. 'Text']
            local low = _G[s:GetName() .. 'Low']
            local high = _G[s:GetName() .. 'High']
            if txt then txt:SetText(text); txt:SetFontObject("GameFontNormalSmall") end
            if low then low:SetText(tostring(minVal)); low:SetFontObject("GameFontNormalSmall") end
            if high then high:SetText(tostring(maxVal)); high:SetFontObject("GameFontNormalSmall") end

            -- tiny EditBox below slider
            local eb = CreateFrame("EditBox", name .. "_EditBox", condFrame, "InputBoxTemplate")
            eb:SetWidth(30); eb:SetHeight(18)
            eb:SetPoint("TOP", s, "BOTTOM", 3, -2)
            eb:SetAutoFocus(false)
            eb:SetText("0")
            eb:SetJustifyH("CENTER")
            eb:SetFontObject("GameFontNormalSmall")
            eb.slider = s
            eb._updating = false

            -- slider -> editbox (robust, avoids recursion)
            s:SetScript("OnValueChanged", function(self, value)
                local frame = self or s
                local v = tonumber(value)
                if not v and frame and frame.GetValue then
                    v = frame:GetValue()
                end
                if not v then return end
                v = math.floor(v + 0.5)
                if eb and eb.SetText and not eb._updating then
                    eb._updating = true
                    eb:SetText(tostring(v))
                    eb._updating = false
                end
                if frame and frame.updateFunc then frame.updateFunc(v) end
            end)

            -- editbox commit helper (clamp + set slider)
            local function CommitEditBox(box)
                if not box or not box.slider then return end
                local sref = box.slider
                local txt = box:GetText()
                local val = tonumber(txt)
                if not val then
                    -- revert to slider's current rounded value
                    local cur = math.floor((sref:GetValue() or 0) + 0.5)
                    box:SetText(tostring(cur))
                else
                    if val < minVal then val = minVal end
                    if val > maxVal then val = maxVal end
                    -- set value on slider; OnValueChanged will handle DB update via updateFunc
                    box._updating = true
                    sref:SetValue(val)
                    box._updating = false
                end
            end

            -- editbox -> slider while typing (userInput true) and on finalize (enter/lost focus)
            eb:SetScript("OnTextChanged", function(self, userInput)
                if not userInput then return end
                if self._updating then return end
                local txt = self:GetText()
                local num = tonumber(txt)
                if num then
                    if num < minVal then num = minVal end
                    if num > maxVal then num = maxVal end
                    self._updating = true
                    self.slider:SetValue(num)
                    self._updating = false
                end
            end)

            eb:SetScript("OnEnterPressed", function(self)
                CommitEditBox(self)
                if self and self.ClearFocus then self:ClearFocus() end
            end)

            eb:SetScript("OnEditFocusLost", function(self)
                CommitEditBox(self)
            end)

            return s, eb
        end

        -- slider widths (leave left margin + spacing)
        local totalAvailable = condFrame:GetWidth() - 60
        local sliderWidth = math.floor((totalAvailable - 20) / 3)
        if sliderWidth < 100 then sliderWidth = 100 end

        local baseX = 20
        local baseY = -395
        local gap = 8

        condFrame.sliderX, condFrame.sliderXBox = MakeSlider("DoiteConditions_SliderX", "Horizontal Position", baseX, baseY, sliderWidth, -500, 500, 1)
        condFrame.sliderY, condFrame.sliderYBox = MakeSlider("DoiteConditions_SliderY", "Vertical Position", baseX + sliderWidth + gap, baseY, sliderWidth, -500, 500, 1)
        condFrame.sliderSize, condFrame.sliderSizeBox = MakeSlider("DoiteConditions_SliderSize", "Icon Size", baseX + 2*(sliderWidth + gap), baseY, sliderWidth, 10, 100, 1)

        -- update functions that the slider will call when changed
        condFrame.sliderX.updateFunc = function(value)
            if not currentKey then return end
            local d = EnsureDBEntry(currentKey)
            d.offsetX = value
            SafeRefresh()
			SafeEvaluate()
        end
        condFrame.sliderY.updateFunc = function(value)
            if not currentKey then return end
            local d = EnsureDBEntry(currentKey)
            d.offsetY = value
            SafeRefresh()
			SafeEvaluate()
        end
        condFrame.sliderSize.updateFunc = function(value)
            if not currentKey then return end
            local d = EnsureDBEntry(currentKey)
            d.iconSize = value
            SafeRefresh()
			SafeEvaluate()
        end

        -- Initially hidden position section
        if condFrame.groupTitle3 then condFrame.groupTitle3:Hide() end
        if condFrame.sep3 then condFrame.sep3:Hide() end
        if condFrame.sliderX then condFrame.sliderX:Hide() end
        if condFrame.sliderY then condFrame.sliderY:Hide() end
        if condFrame.sliderSize then condFrame.sliderSize:Hide() end
        if condFrame.sliderXBox then condFrame.sliderXBox:Hide() end
        if condFrame.sliderYBox then condFrame.sliderYBox:Hide() end
        if condFrame.sliderSizeBox then condFrame.sliderSizeBox:Hide() end

        -- When the main DoiteAuras frame hides, hide the cond frame too
        if DoiteAurasFrame then
            local oldHide = DoiteAurasFrame:GetScript("OnHide")
            DoiteAurasFrame:SetScript("OnHide", function(self)
                if condFrame then condFrame:Hide() end
                if oldHide then oldHide(self) end
            end)
        end
    end

    condFrame:Show()
    UpdateCondFrameForKey(key)
end
