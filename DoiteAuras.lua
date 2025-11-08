-- DoiteAuras: Simplified WeakAura-style addon for Turtle WoW 1.12 (Lua 5.0)
-- Tracks spells by name + type (Ability/Buff/Debuff) so duplicates with different types allowed
-- Shows movable icons (Abilities & Buff/Debuff when present on player), scrollable list, edit/remove/up/down
-- Default logic = show when usable/off CD for Abilities; Buff/Debuff show when present on player
-- SavedVariables: DoiteAurasDB

if DoiteAurasFrame then return end

-- SavedVariables init (guarded; do NOT clobber existing data)
DoiteAurasDB = DoiteAurasDB or {}
DoiteAurasDB.spells   = DoiteAurasDB.spells   or {}
DoiteAurasDB.cache = DoiteAurasDB.cache or {}
DoiteAuras = DoiteAuras or {}

-- Always return a valid name->texture cache table
local function DA_Cache()
  DoiteAurasDB = DoiteAurasDB or {}
  DoiteAurasDB.cache = DoiteAurasDB.cache or {}
  return DoiteAurasDB.cache
end


-- Persistent store for group layout computed positions
_G["DoiteGroup_Computed"]       = _G["DoiteGroup_Computed"]       or {}
_G["DoiteGroup_LastLayoutTime"] = _G["DoiteGroup_LastLayoutTime"] or 0

-- ========= Spell Texture Cache (abilities) =========
-- Populates DoiteAurasDB.cache[name] = texture from the player's spellbook.
-- Works on Turtle/1.12 via GetSpellName / GetSpellTexture.

local function DoiteAuras_RebuildSpellTextureCache()
    local cache = DA_Cache()
    -- Scan all tabs/slots once and remember textures by NAME (rank-agnostic, matches your displayName use)
    for tab = 1, (GetNumSpellTabs() or 0) do
        local _, _, offset, numSlots = GetSpellTabInfo(tab)
        if numSlots and numSlots > 0 then
            for i = 1, numSlots do
                local idx = offset + i
                local name, rank = GetSpellName(idx, BOOKTYPE_SPELL)
                if not name then break end
                local tex = GetSpellTexture and GetSpellTexture(idx, BOOKTYPE_SPELL)
                if name and tex and cache[name] ~= tex then
                    cache[name] = tex
                end
            end
        end
    end

    -- If we already have configured Ability entries, seed their .iconTexture for immediate use
    if DoiteAurasDB.spells then
        for key, data in pairs(DoiteAurasDB.spells) do
            if data and data.type == "Ability" then
                local nm = data.displayName or data.name
                local t  = nm and cache[nm]
                if t then data.iconTexture = t end
            end
        end
    end
end

-- Event hook: rebuild on login/world and whenever the spellbook changes (talent/build swaps on Turtle fire this)
local _daSpellTex = CreateFrame("Frame")
_daSpellTex:RegisterEvent("PLAYER_ENTERING_WORLD")
_daSpellTex:RegisterEvent("SPELLS_CHANGED")
_daSpellTex:SetScript("OnEvent", function()
    DoiteAuras_RebuildSpellTextureCache()
    -- repaint so brand-new abilities get icons instantly
    if DoiteAuras_RefreshIcons then pcall(DoiteAuras_RefreshIcons) end
end)
-- ==================================================

-- Title-case function with exceptions for small words (keeps first word capitalized)
local function TitleCase(str)
    if not str then return "" end
    str = tostring(str)
    local exceptions = {
        ["of"]=true, ["and"]=true, ["the"]=true, ["for"]=true,
        ["in"]=true, ["on"]=true, ["to"]=true, ["a"]=true,
        ["an"]=true, ["with"]=true, ["by"]=true, ["at"]=true
    }
    local result, first = "", true
    for word in string.gmatch(str, "%S+") do
        -- If the word starts with "(", force-capitalize the first letter after "(".
        local startsParen = (string.sub(word, 1, 1) == "(")
        local leading = startsParen and "(" or ""
        local core = startsParen and string.sub(word, 2) or word

        local lowerCore = string.lower(core or "")
        local c = string.sub(core or "", 1, 1) or ""
        local rest = string.sub(core or "", 2) or ""

        if first then
            -- Always capitalize the very first word
            result = result .. leading .. string.upper(c) .. string.lower(rest) .. " "
            first = false
        else
            if startsParen then
                -- First word inside parentheses: force-capitalize regardless of exceptions
                result = result .. leading .. string.upper(c) .. string.lower(rest) .. " "
            elseif exceptions[lowerCore] then
                -- Normal small-word behavior
                result = result .. lowerCore .. " "
            else
                result = result .. leading .. string.upper(c) .. string.lower(rest) .. " "
            end
        end
    end
    result = string.gsub(result, "%s+$", "")
    return result
end

-- === Duplicate handling helpers ===
local function BaseKeyFor(data_or_name, typ)
  if type(data_or_name) == "table" then
    local d = data_or_name
    local nm = (d.displayName or d.name or "")
    local tp = (d.type or "Ability")
    return nm .. "_" .. tp
  else
    local nm = tostring(data_or_name or "")
    local tp = tostring(typ or "Ability")
    return nm .. "_" .. tp
  end
end

-- Generate a unique storage key for DB & frames.
-- Keeps the very first as <name>_<type>; subsequent siblings append #2, #3, ...
local function GenerateUniqueKey(name, typ)
  local base = BaseKeyFor(name, typ)
  if not DoiteAurasDB.spells[base] then
    return base, base, 1
  end
  local n = 2
  while DoiteAurasDB.spells[base .. "#" .. tostring(n)] do
    n = n + 1
  end
  return (base .. "#" .. tostring(n)), base, n
end

-- Find siblings (same displayName & type)
local function IterSiblings(name, typ)
  local base = BaseKeyFor(name, typ)
  local function iter(_, last)
    for k, d in pairs(DoiteAurasDB.spells) do
      if k ~= last then
        local bk = BaseKeyFor(d)
        if bk == base then
          return k, d
        end
      end
    end
  end
  return iter, nil, nil
end


-- Tooltip for buff/debuff scanning
local daTip = CreateFrame("GameTooltip", "DoiteAurasTooltip", nil, "GameTooltipTemplate")
daTip:SetOwner(UIParent, "ANCHOR_NONE")

local function GetBuffName(unit, index, debuff)
    daTip:ClearLines()
    if debuff then
        daTip:SetUnitDebuff(unit, index)
    else
        daTip:SetUnitBuff(unit, index)
    end
    return DoiteAurasTooltipTextLeft1:GetText()
end

-- Main frame (layout & sizes)
local frame = CreateFrame("Frame", "DoiteAurasFrame", UIParent)
frame:SetWidth(355)
frame:SetHeight(450)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function() this:StartMoving() end)
frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
frame:Hide()
frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 16, edgeSize = 32,
    insets = { left=11, right=12, top=12, bottom=11 }
})
frame:SetBackdropColor(0, 0, 0, 1)
frame:SetBackdropBorderColor(1, 1, 1, 1)
frame:SetFrameStrata("FULLSCREEN_DIALOG")

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -15)
title:SetText("DoiteAuras")

local sep = frame:CreateTexture(nil, "ARTWORK")
sep:SetHeight(1)
sep:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -35)
sep:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -35)
sep:SetTexture(1,1,1)
if sep.SetVertexColor then sep:SetVertexColor(1,1,1,0.25) end

-- Intro text
local intro = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
intro:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -40)
intro:SetText("Enter the EXACT name of the ability, buff or debuff.")

-- Close button
local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function() this:GetParent():Hide() end)

-- Input box + Add
local input = CreateFrame("EditBox", "DoiteAurasInput", frame, "InputBoxTemplate")
input:SetWidth(240)
input:SetHeight(20)
input:SetPoint("TOPLEFT", intro, "TOPLEFT", 5, -15)
input:SetAutoFocus(false)

local addBtn = CreateFrame("Button", "DoiteAurasAddBtn", frame, "UIPanelButtonTemplate")
addBtn:SetWidth(60)
addBtn:SetHeight(20)
addBtn:SetPoint("LEFT", input, "RIGHT", 10, 0)
addBtn:SetText("Add")

-- Type selector checkboxes
local currentType = "Ability"
local abilityCB, buffCB, debuffCB

abilityCB = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
abilityCB:SetWidth(20); abilityCB:SetHeight(20)
abilityCB:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 0, -3)
abilityCB.text = abilityCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
abilityCB.text:SetPoint("LEFT", abilityCB, "RIGHT", 2, 0)
abilityCB.text:SetText("Abilities")

buffCB = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
buffCB:SetWidth(20); buffCB:SetHeight(20)
buffCB:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 65, -3)
buffCB.text = buffCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
buffCB.text:SetPoint("LEFT", buffCB, "RIGHT", 2, 0)
buffCB.text:SetText("Buffs")

debuffCB = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
debuffCB:SetWidth(20); debuffCB:SetHeight(20)
debuffCB:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 120, -3)
debuffCB.text = debuffCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
debuffCB.text:SetPoint("LEFT", debuffCB, "RIGHT", 2, 0)
debuffCB.text:SetText("Debuffs")

-- Disabled "Items" checkbox (coming soon)
local itemsCB = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
itemsCB:SetWidth(20); itemsCB:SetHeight(20)
itemsCB:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 185, -3)
itemsCB:Disable()  -- greys it out
itemsCB.text = itemsCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
itemsCB.text:SetPoint("LEFT", itemsCB, "RIGHT", 2, 0)
itemsCB.text:SetText("|cffA0A0A0Items (Coming soon)|r")

abilityCB:SetScript("OnClick", function()
    abilityCB:SetChecked(true); buffCB:SetChecked(false); debuffCB:SetChecked(false)
    currentType = "Ability"
end)
buffCB:SetScript("OnClick", function()
    abilityCB:SetChecked(false); buffCB:SetChecked(true); debuffCB:SetChecked(false)
    currentType = "Buff"
end)
debuffCB:SetScript("OnClick", function()
    abilityCB:SetChecked(false); buffCB:SetChecked(false); debuffCB:SetChecked(true)
    currentType = "Debuff"
end)

frame:SetScript("OnShow", function()
    abilityCB:SetChecked(true); buffCB:SetChecked(false); debuffCB:SetChecked(false)
    currentType = "Ability"
end)

-- Scrollable container
local listContainer = CreateFrame("Frame", nil, frame)
listContainer:SetWidth(300)
listContainer:SetHeight(260)
listContainer:SetPoint("TOPLEFT", input, "BOTTOMLEFT", -5, -25)
listContainer:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16 })
listContainer:SetBackdropColor(0,0,0,0.7)

local scrollFrame = CreateFrame("ScrollFrame", "DoiteAurasScroll", listContainer, "UIPanelScrollFrameTemplate")
scrollFrame:SetWidth(280)
scrollFrame:SetHeight(250)
scrollFrame:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 15, -5)

local listContent = CreateFrame("Frame", "DoiteAurasListContent", scrollFrame)
listContent:SetWidth(280)
listContent:SetHeight(250)
scrollFrame:SetScrollChild(listContent)

-- Guide text
local guide = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
guide:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 20)
guide:SetWidth(315)
guide:SetJustifyH("LEFT")
if guide.SetTextColor then guide:SetTextColor(0.7,0.7,0.7) end
guide:SetText("Guide: DoiteAuras shows only what matters—abilities, buffs, debuffs, items, or bars—when you actually need them. Add an icon or bar, pick its type, and define when it appears using simple conditions like cooldown, aura state, combat, or target. Everything updates automatically, remembers textures once seen, and keeps your UI clean and reactive.")

-- storage
local spellButtons, icons = {}, {}

local function GetIconLayout(key)
    if DoiteDB and DoiteDB.icons and DoiteDB.icons[key] then
        return DoiteDB.icons[key]
    end
    return nil
end

-- helper to get data (safe init)
local function GetSpellData(key)
  if not DoiteAurasDB.spells[key] then
    DoiteAurasDB.spells[key] = {}
  end
  return DoiteAurasDB.spells[key]
end

-- Helpers
local function GetOrderedSpells()
    local list = {}
    for key, data in pairs(DoiteAurasDB.spells) do
        table.insert(list, { key = key, data = data, order = data.order or 999 })
    end
    table.sort(list, function(a,b) return a.order < b.order end)
    return list
end

-- Throttle RefreshIcons() to avoid recursive layout overrides
local _lastRefresh = 0
local function _CanRunRefresh()
    local now = GetTime and GetTime() or 0
    if now - _lastRefresh < 0.1 then return false end
    _lastRefresh = now
    return true
end

local function RebuildOrder()
    local ordered = GetOrderedSpells()
    for i=1, table.getn(ordered) do DoiteAurasDB.spells[ordered[i].key].order = i end
end
local function FindSpellBookSlot(spellName)
    for tab=1, GetNumSpellTabs() do
        local _, _, offset, numSlots = GetSpellTabInfo(tab)
        for i=1, numSlots do
            local name = GetSpellName(i+offset, BOOKTYPE_SPELL)
            if name == spellName then return i+offset end
        end
    end
    return nil
end

-- Buff/Debuff check via tooltip
local function FindPlayerBuff(name)
    local i=1
    while true do
        local bname = GetBuffName("player", i, false)
        if not bname then break end
        if bname == name then
            local tex = UnitBuff("player", i)
            return true, tex
        end
        i=i+1
    end
    return false,nil
end

local function FindPlayerDebuff(name)
    local i=1
    while true do
        local dname = GetBuffName("player", i, true)
        if not dname then break end
        if dname == name then
            local tex = UnitDebuff("player", i)
            return true, tex
        end
        i=i+1
    end
    return false,nil
end

-- Create/update icon (fixed: use offsetX/offsetY/iconSize saved fields and create global DoiteIcon_<key> frames)
-- Create or update icon *structure only* (no positioning or texture changes here)
local function CreateOrUpdateIcon(key, layer)
    local globalName = "DoiteIcon_" .. key
    local f = _G[globalName]
    if not f then
        f = CreateFrame("Frame", globalName, UIParent)
        f:SetFrameStrata("MEDIUM")
        -- default size; actual sizing applied in RefreshIcons
        f:SetWidth(36)
        f:SetHeight(36)

        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")

        -- icon texture (created once)
        f.icon = f:CreateTexture(nil, "BACKGROUND")
        f.icon:SetAllPoints(f)

        -- optional count text (created once)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
        fs:SetText("")
        f.count = fs

        -- drag handlers: followers ignore write; leaders update DB
        f:SetScript("OnDragStart", function(self)
            -- Followers should not start moving
            local data = GetSpellData(key)
            if data and data.group and data.group ~= "" and data.group ~= "no" and not data.isLeader then
                return
            end
            self:StartMoving()
        end)

        f:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local point, relTo, relPoint, x, y = self:GetPoint()
            local data = GetSpellData(key)
            -- Followers must never write offsets or trigger refresh
            if data and data.group and data.group ~= "" and data.group ~= "no" and not data.isLeader then
                -- snap back to leader visually will happen on next refresh; do nothing
                return
            end

            -- leaders and ungrouped icons update saved offsets normally
            if data then
                data.offsetX = x or 0
                data.offsetY = y or 0
            end
			
			-- invalidate persisted layout for this icon's group (forces fresh layout)
			if data and data.group and data.group ~= "" and data.group ~= "no" and data.isLeader then
				if _G["DoiteGroup_Computed"] then
					_G["DoiteGroup_Computed"][data.group] = nil
				end
			end

            -- schedule a single refresh (debounced via RefreshIcons() guard)
            if DoiteAuras_RefreshIcons then
                -- small delay to avoid re-entrancy racing (use DA_RunLater if available)
                if DA_RunLater then
                    DA_RunLater(0.05, function() if DoiteAuras_RefreshIcons then pcall(DoiteAuras_RefreshIcons) end end)
                else
                    local fDelay = CreateFrame("Frame")
                    local acc = 0
                    fDelay:SetScript("OnUpdate", function()
                        acc = acc + arg1
                        if acc >= 0.05 then
                            fDelay:SetScript("OnUpdate", nil)
                            if DoiteAuras_RefreshIcons then pcall(DoiteAuras_RefreshIcons) end
                        end
                    end)
                end
            end
        end)
    end

    -- cache locally as before
    icons[key] = f
    if layer then f:SetFrameLevel(layer) end

    return f
end

-- Refresh icons (group-aware)
local function RefreshIcons()
    if not _CanRunRefresh() then return end
    local ordered = GetOrderedSpells()
    local total = table.getn(ordered)
    local candidates = {}

    -- Step 1: collect all icon states
    for i = 1, total do
        local key = ordered[i].key
        local data = ordered[i].data
        local typ = data and data.type or "Ability"
        local tex, shouldShow = nil, false

        if typ == "Ability" then
            local slot = FindSpellBookSlot(data.displayName or data.name)
            if slot then
                local start, dur, en = GetSpellCooldown(slot, BOOKTYPE_SPELL)
                if en == 1 and (dur == 0 or dur == nil) then
                    tex = GetSpellTexture(slot, BOOKTYPE_SPELL)
                    shouldShow = true
                end
            end
        elseif typ == "Buff" then
            local found, btex = FindPlayerBuff(data.displayName or data.name)
            if found then shouldShow, tex = true, btex end
        elseif typ == "Debuff" then
            local found, dtex = FindPlayerDebuff(data.displayName or data.name)
            if found then shouldShow, tex = true, dtex end
        end

        table.insert(candidates, {
            key = key,
            data = data,
            show = shouldShow,
            tex  = tex,
            size = data.iconSize or data.size or 36,
        })
    end

    -- Step 2: ensure icons exist first, then apply group layout once
    for _, entry in ipairs(candidates) do
        if not _G["DoiteIcon_" .. entry.key] then
            CreateOrUpdateIcon(entry.key, 36)
        end
    end
    if DoiteGroup and not _G["DoiteGroup_LayoutInProgress"] and DoiteGroup.ApplyGroupLayout then
		pcall(DoiteGroup.ApplyGroupLayout, candidates)
	end
	
	-- Persist the computed layout so future refresh passes keep using it
	do
		local map = _G["DoiteGroup_Computed"]
		local now = (GetTime and GetTime()) or 0
		for _, e in ipairs(candidates) do
			local d = e.data
			if d and d.group and d.group ~= "" and d.group ~= "no" and e._computedPos then
				map[d.group] = map[d.group] or {}
				-- store/replace entry for this key
				local list = map[d.group]
				local found = false
				for i=1, table.getn(list) do
					if list[i].key == e.key then
						list[i] = { key = e.key, _computedPos = {
							x = e._computedPos.x, y = e._computedPos.y, size = e._computedPos.size
						} }
						found = true
						break
					end
				end
				if not found then
					table.insert(list, { key = e.key, _computedPos = {
						x = e._computedPos.x, y = e._computedPos.y, size = e._computedPos.size
					}})
				end
			end
		end
		_G["DoiteGroup_LastLayoutTime"] = now
	end

    -- Step 3: create/update frames and apply positions (single place)
    if _G["DoiteAuras_RefreshInProgress"] then return end
    _G["DoiteAuras_RefreshInProgress"] = true

    for _, entry in ipairs(candidates) do
        local key, data = entry.key, entry.data
        local globalName = "DoiteIcon_" .. key
        local f = _G[globalName]

        if not f then
            f = CreateOrUpdateIcon(key, 36)
        end

        -- ensure drag scripts are correct (followers cannot start dragging)
        f:SetScript("OnDragStart", function(self)
            if data and data.group and data.group ~= "" and data.group ~= "no" and not data.isLeader then return end
            self:StartMoving()
        end)

        -- compute final pos/size (group-aware, sticky)
		local posX, posY, size
		local isGrouped = (data and data.group and data.group ~= "" and data.group ~= "no")
		local isLeader  = (data and data.isLeader == true)

		-- 1) Prefer the freshly computed position (if present on this entry)
		if entry._computedPos then
			posX = entry._computedPos.x
			posY = entry._computedPos.y
			size = entry._computedPos.size

		-- 2) Otherwise prefer the persisted computed layout from the last layout tick
		elseif isGrouped and _G["DoiteGroup_Computed"] and _G["DoiteGroup_Computed"][data.group] then
			local list = _G["DoiteGroup_Computed"][data.group]
			for i=1, table.getn(list) do
				local ge = list[i]
				if ge.key == key and ge._computedPos then
					posX = ge._computedPos.x
					posY = ge._computedPos.y
					size = ge._computedPos.size
					break
				end
			end
		end

		-- 3) If grouped follower and we still don't have a computed pos:
		--    don't snap back to saved offsets; leave point untouched (sticky) until next layout.
		if not posX then
			if isGrouped and not isLeader then
				-- keep current point; just use saved alpha/scale/size for visual consistency
				local currentSize = (data and (data.iconSize or data.size)) or 36
				size = size or currentSize
				-- DO NOT SetPoint here for follower without computed pos (avoid snap-back)
			else
				-- ungrouped or leader: use saved offsets
				posX = (data and (data.offsetX or data.x)) or 0
				posY = (data and (data.offsetY or data.y)) or 0
				size = size or (data and (data.iconSize or data.size)) or 36
			end
		end

        f:SetScale((data and data.scale) or 1)
        f:SetAlpha((data and data.alpha) or 1)
        f:SetWidth(size); f:SetHeight(size)

        -- Do not re-anchor while a slide preview owns the frame for this tick
        if not f._daSliding then
            if posX ~= nil and posY ~= nil then
                f:ClearAllPoints()
                f:SetPoint("CENTER", UIParent, "CENTER", posX, posY)
            else
                -- Grouped follower with no computed position this tick:
                -- DO NOT ClearAllPoints or SetPoint; keep last good layout anchor.
            end
        end

		-- Texture handling (with saved iconTexture fallback)
		local cache = DA_Cache()
		local displayName = (data and (data.displayName or data.name)) or key
		local texToUse = entry.tex
		  or cache[displayName]
		  or (data and data.iconTexture)


		if not texToUse and data and data.type == "Ability" then
		  local slot = FindSpellBookSlot(displayName)
		  if slot then texToUse = GetSpellTexture(slot, BOOKTYPE_SPELL) end
		end

		if texToUse then
		  -- Keep a name-level cache and also stamp it on this entry so it persists
		  cache[displayName] = texToUse
		  if data and not data.iconTexture then
			data.iconTexture = texToUse
		  end
		end

		f.icon:SetTexture(texToUse or "Interface\\Icons\\INV_Misc_QuestionMark")

		-- Visibility: conditions OR slide … but the group limit has final say
		local wantsFromConditions = (f._daShouldShow == true)
		local wantsFromSlide      = (f._daSliding == true)
		local blockedByGroup      = (f._daBlockedByGroup == true)

		local shouldBeVisible = (wantsFromConditions or wantsFromSlide) and (not blockedByGroup)
		if shouldBeVisible then
			f:Show()
		else
			f:Hide()
		end
    end
    _G["DoiteAuras_RefreshInProgress"] = false
end

-- Refresh list
local function RefreshList()
	  for _, v in pairs(spellButtons) do if v.Hide then v:Hide() end end
	  spellButtons = {}
	  local ordered = GetOrderedSpells()
	  local total   = table.getn(ordered)
	  listContent:SetHeight(math.max(160, total * 55))

	  -- NEW: build grouping info: baseKey -> {count, idxByKey}
	  local groupCount = {}
	  local groupIndex = {}
	  for i, entry in ipairs(ordered) do
		local d = entry.data
		local base = BaseKeyFor(d)
		groupCount[base] = (groupCount[base] or 0) + 1
	  end
	  for i, entry in ipairs(ordered) do
		local d = entry.data
		local base = BaseKeyFor(d)
		groupIndex[base] = (groupIndex[base] or 0) + 1
		entry._groupIdx = groupIndex[base]
		entry._groupCnt = groupCount[base]
	  end

	  for i, entry in ipairs(ordered) do
		local key, data = entry.key, entry.data
		local base = BaseKeyFor(data)

		local display = data.displayName or key
		-- NEW: show "(i/N)" only if N > 1
		if entry._groupCnt and entry._groupCnt > 1 then
		  display = string.format("%s (%d/%d)", display, entry._groupIdx, entry._groupCnt)
		end

		local btn = CreateFrame("Frame", nil, listContent)
		btn:SetWidth(260); btn:SetHeight(50)

		btn.fontString = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		btn.fontString:SetPoint("TOPLEFT", btn, "TOPLEFT", 5, -5)
		btn.fontString:SetText(display)

		btn.tag = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		btn.tag:SetPoint("TOPLEFT", btn.fontString, "BOTTOMLEFT", 0, -2)
		if data.type == "Ability" then
		  btn.tag:SetText("|cff4da6ffAbility|r")
		elseif data.type == "Buff" then
		  btn.tag:SetText("|cff22ff22Buff|r")
		elseif data.type == "Debuff" then
		  btn.tag:SetText("|cffff4d4dDebuff|r")
		end
        -- Remove
        btn.removeBtn=CreateFrame("Button",nil,btn,"UIPanelButtonTemplate")
        btn.removeBtn:SetWidth(60); btn.removeBtn:SetHeight(18)
        btn.removeBtn:SetPoint("TOPRIGHT",btn,"TOPRIGHT",-5,-25); btn.removeBtn:SetText("Remove")
        btn.removeBtn:SetScript("OnClick",function()
            DoiteAurasDB.spells[key]=nil; if icons[key] then icons[key]:Hide(); icons[key]=nil end
            if spellButtons[key] and spellButtons[key].Hide then spellButtons[key]:Hide() end
            RebuildOrder(); RefreshList(); RefreshIcons()
            if DoiteConditions_RequestEvaluate then DoiteConditions_RequestEvaluate() end
		end)
        -- Edit
        btn.editBtn=CreateFrame("Button",nil,btn,"UIPanelButtonTemplate")
        btn.editBtn:SetWidth(50); btn.editBtn:SetHeight(18)
        btn.editBtn:SetPoint("RIGHT",btn.removeBtn,"LEFT",-5,0)
		btn.editBtn:SetText("Edit")
		btn.editBtn:SetScript("OnClick", function()
			-- populate input and checkboxes (so UI state matches)
			input:SetText(display)
			currentType = data.type or "Ability"
			if abilityCB then abilityCB:SetChecked(currentType == "Ability") end
			if buffCB    then buffCB:SetChecked(currentType == "Buff") end
			if debuffCB  then debuffCB:SetChecked(currentType == "Debuff") end

			-- open conditions editor for this entry (pass the composite key)
			if DoiteConditions_Show then
				DoiteConditions_Show(key)
			else
				DEFAULT_CHAT_FRAME:AddMessage("|cffff0000DoiteAuras:|r DoiteConditions not loaded.")
			end
		end)

        -- Move buttons
        btn.downBtn=CreateFrame("Button",nil,btn); btn.downBtn:SetWidth(18); btn.downBtn:SetHeight(18)
        btn.downBtn:SetNormalTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollUpButton-Up")
        btn.downBtn:SetPushedTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollUpButton-Down")
        btn.downBtn:SetPoint("RIGHT",btn.editBtn,"LEFT",-5,0)
        btn.downBtn:SetScript("OnClick",function()
            local ord=GetOrderedSpells()
            for j=1,table.getn(ord) do if ord[j].key==key and j>1 then
                local above=ord[j-1].key; local tmp=DoiteAurasDB.spells[key].order
                DoiteAurasDB.spells[key].order=DoiteAurasDB.spells[above].order; DoiteAurasDB.spells[above].order=tmp
                RebuildOrder(); RefreshList(); RefreshIcons(); break end end
            if DoiteConditions_RequestEvaluate then DoiteConditions_RequestEvaluate() end
		end)
        btn.upBtn=CreateFrame("Button",nil,btn); btn.upBtn:SetWidth(18); btn.upBtn:SetHeight(18)
        btn.upBtn:SetNormalTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollDownButton-Up")
        btn.upBtn:SetPushedTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollDownButton-Down")
        btn.upBtn:SetPoint("RIGHT",btn.downBtn,"LEFT",-5,0)
        btn.upBtn:SetScript("OnClick",function()
            local ord=GetOrderedSpells()
            for j=1,table.getn(ord) do if ord[j].key==key and j<table.getn(ord) then
                local below=ord[j+1].key; local tmp=DoiteAurasDB.spells[key].order
                DoiteAurasDB.spells[key].order=DoiteAurasDB.spells[below].order; DoiteAurasDB.spells[below].order=tmp
                RebuildOrder(); RefreshList(); RefreshIcons(); break end end
			if DoiteConditions_RequestEvaluate then DoiteConditions_RequestEvaluate() end
		end)
        btn.sep=btn:CreateTexture(nil,"ARTWORK"); btn.sep:SetHeight(1)
        btn.sep:SetPoint("BOTTOMLEFT",btn,"BOTTOMLEFT",0,-2)
        btn.sep:SetPoint("BOTTOMRIGHT",btn,"BOTTOMRIGHT",0,-2); btn.sep:SetTexture(0.9,0.9,0.9,0.12)
        btn:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -10 - (i - 1) * 55)
    spellButtons[key] = btn
    btn:Show()
  end

  scrollFrame:SetScrollChild(listContent)
end

-- Add button
addBtn:SetScript("OnClick", function()
  local name = input:GetText(); if not name or name == "" then return end
  name = TitleCase(name)
  local t = currentType

  -- Ability validation stays
  if t == "Ability" and not FindSpellBookSlot(name) then
    (DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cffff0000DoiteAuras:|r Spell not found in spellbook.")
    return
  end

  -- NEW: generate unique key; baseKey groups duplicates by name+type
  local key, baseKey, instanceIdx = GenerateUniqueKey(name, t)

  -- Order = append at end
  local nextOrder = table.getn(GetOrderedSpells()) + 1

  -- Create the DB entry (defaults filled later by EnsureDBEntry/DoiteEdit)
  DoiteAurasDB.spells[key] = {
    order = nextOrder,
    type  = t,
    displayName = name,
    baseKey = baseKey,  -- helpful but not required (we still compute BaseKeyFor on the fly)
    uid = instanceIdx,  -- 1 for the first, 2,3,... for next siblings
  }

  -- Auto-prime texture when we can:
  -- 1) Abilities: spellbook texture
  if t == "Ability" then
    local slot = FindSpellBookSlot(name)
    if slot then
	  local tex = GetSpellTexture(slot, BOOKTYPE_SPELL)
	  if tex then
		local cache = DA_Cache()
		cache[name] = tex
		DoiteAurasDB.spells[key].iconTexture = tex
	  end
	end
  end

  -- 2) If we’ve ever seen this name before (ability or aura), reuse known texture
  if not DoiteAurasDB.spells[key].iconTexture then
    local cached = DA_Cache()[name]
	if cached then
	  DoiteAurasDB.spells[key].iconTexture = cached
	else
      -- 3) Fallback: copy iconTexture from any sibling that already has one
      for sk, sd in IterSiblings(name, t) do
        if sd and sd.iconTexture then
          DoiteAurasDB.spells[key].iconTexture = sd.iconTexture
          break
        end
      end
    end
  end

  if EnsureDBEntry then pcall(EnsureDBEntry, key) end
  input:SetText("")
  RebuildOrder(); RefreshList(); RefreshIcons()
  scrollFrame:SetVerticalScroll(math.max(0, listContent:GetHeight() - scrollFrame:GetHeight()))
  if DoiteConditions_RequestEvaluate then DoiteConditions_RequestEvaluate() end
end)

-- =========================
-- Minimap Button (DoiteAuras)
-- =========================
local function DA_GetVersion()
  local v = (GetAddOnMetadata and GetAddOnMetadata("DoiteAuras", "Version")) or (DoiteAuras_Version) or "?"
  return v or "?"
end

local function _DA_MiniSV()
  DoiteAurasDB.minimap = DoiteAurasDB.minimap or {}
  if DoiteAurasDB.minimap.angle == nil then DoiteAurasDB.minimap.angle = 45 end -- default angle
  return DoiteAurasDB.minimap
end

local function _DA_PlaceMini(btn)
  local ang = ((_DA_MiniSV().angle or 45) * math.pi / 180)
  local x = math.cos(ang) * 80
  local y = math.sin(ang) * 80
  btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function DA_CreateMinimapButton()
  if _G["DoiteAurasMinimapButton"] then return end

  local btn = CreateFrame("Button", "DoiteAurasMinimapButton", Minimap)
  btn:SetFrameStrata("MEDIUM")
  btn:SetWidth(31); btn:SetHeight(31)

  -- Ring overlay
  local overlay = btn:CreateTexture(nil, "OVERLAY")
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetWidth(54); overlay:SetHeight(54)
  overlay:SetPoint("TOPLEFT", 0, 0)

  -- Icon (your DA tga)
  local icon = btn:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\AddOns\\DoiteAuras\\Textures\\doiteauras-icon")
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  icon:SetWidth(20); icon:SetHeight(20)
  icon:SetPoint("TOPLEFT", 6, -5)

  local hlt = btn:CreateTexture(nil, "HIGHLIGHT")
  hlt:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  hlt:SetBlendMode("ADD")
  hlt:SetAllPoints(btn)

  btn:RegisterForDrag("LeftButton", "RightButton")
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  -- drag to move along the minimap ring
  btn:SetScript("OnDragStart", function()
    btn:SetScript("OnUpdate", function()
      local x, y = GetCursorPosition()
      local mx, my = Minimap:GetCenter()
      local scale = Minimap:GetEffectiveScale()
      local ang = math.deg(math.atan2(y/scale - my, x/scale - mx))
      _DA_MiniSV().angle = ang
      _DA_PlaceMini(btn)
    end)
  end)
  btn:SetScript("OnDragStop", function() btn:SetScript("OnUpdate", nil) end)

  -- click: opens/close DoiteAuras
  btn:SetScript("OnClick", function()
    if DoiteAurasFrame and DoiteAurasFrame:IsShown() then
      DoiteAurasFrame:Hide()
    else
	-- center-on-open logic (keeps your Step #1 behavior)
    if DoiteAurasFrame then
     DoiteAurasFrame:ClearAllPoints()
     DoiteAurasFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
     DoiteAurasFrame:Show()
		end
	end
  end)

  -- tooltip
  btn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
    GameTooltip:AddLine("DOITEAURAS", 0.435, 0.659, 0.863) -- #6FA8DC
    GameTooltip:AddLine("Click to open DoiteAuras", 1, 1, 1)
    GameTooltip:AddLine("Version: " .. tostring(DA_GetVersion()), 0.9, 0.9, 0.9)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function()
    if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end
  end)

  -- initial placement
  _DA_PlaceMini(btn)
end

-- create/show on load
local _daMiniInit = CreateFrame("Frame")
_daMiniInit:RegisterEvent("ADDON_LOADED")
_daMiniInit:SetScript("OnEvent", function()
  if event ~= "ADDON_LOADED" or arg1 ~= "DoiteAuras" then return end
  DA_CreateMinimapButton()
end)

-- Slash
SLASH_DOITEAURAS1="/da"
SLASH_DOITEAURAS2="/doiteauras"
SLASH_DOITEAURAS3="/doiteaura"
SLASH_DOITEAURAS4="/doite"
SlashCmdList["DOITEAURAS"] = function()
  if frame:IsShown() then
    frame:Hide()
  else
    -- Always (re)center on open
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:Show()
    RefreshList()
  end
end

-- =========================
-- Version WHO (/daversionwho)
-- =========================
local DA_PREFIX = "DOITEAURAS"

local function DA_GetVersion_Safe()
  -- Reuse your existing DA_GetVersion() if present (minimap section defines it)
  if type(DA_GetVersion) == "function" then
    return DA_GetVersion() or "?"
  end
  local v = (GetAddOnMetadata and GetAddOnMetadata("DoiteAuras", "Version")) or (DoiteAuras_Version) or "?"
  return v or "?"
end

-- Broadcast helpers
local function DA_BroadcastVersion(channel)
  if not SendAddonMessage then return end
  SendAddonMessage(DA_PREFIX, "DA_VER:" .. tostring(DA_GetVersion_Safe()), channel)
end

local function DA_BroadcastVersionAll()
  if not SendAddonMessage then return end
  if UnitInRaid and UnitInRaid("player") then
    SendAddonMessage(DA_PREFIX, "DA_VER:" .. tostring(DA_GetVersion_Safe()), "RAID")
  elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
    SendAddonMessage(DA_PREFIX, "DA_VER:" .. tostring(DA_GetVersion_Safe()), "PARTY")
  elseif IsInGuild and IsInGuild() then
    SendAddonMessage(DA_PREFIX, "DA_VER:" .. tostring(DA_GetVersion_Safe()), "GUILD")
  end
end

-- Version compare helpers
local function DA_ParseVersion(v)
  local a,b,c = string.match(tostring(v or ""), "^(%d+)%.(%d+)%.?(%d*)$")
  return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end
local function DA_IsNewer(v1, v2)
  local a1,b1,c1 = DA_ParseVersion(v1)
  local a2,b2,c2 = DA_ParseVersion(v2)
  if a1 ~= a2 then return a1 > a2 end
  if b1 ~= b2 then return b1 > b2 end
  return c1 > c2
end
local _daVerNotifiedOnce = false
local _daVerLastEcho = 0

-- /daversionwho: ask others to report their version
SLASH_DAVERSIONWHO1 = "/daversionwho"
SlashCmdList["DAVERSIONWHO"] = function()
  local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
  if cf then cf:AddMessage("|cff6FA8DCDoiteAuras:|r version WHO sent. Listening for replies...") end
  local sent = false
  if UnitInRaid and UnitInRaid("player") then
    SendAddonMessage(DA_PREFIX, "DA_WHO", "RAID");  sent = true
  elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
    SendAddonMessage(DA_PREFIX, "DA_WHO", "PARTY"); sent = true
  elseif IsInGuild and IsInGuild() then
    SendAddonMessage(DA_PREFIX, "DA_WHO", "GUILD"); sent = true
  end
  if not sent and cf then
    cf:AddMessage("|cff6FA8DCDoiteAuras:|r No channels available (raid/party/guild).")
  end
end

-- Small delayed runner (Vanilla/Turtle: use arg1 in OnUpdate)
local function DA_RunLater(delay, func)
  local f = CreateFrame("Frame")
  local acc = 0
  f:SetScript("OnUpdate", function()
    acc = acc + arg1
    if acc >= delay then
      f:SetScript("OnUpdate", nil)
      if type(func) == "function" then pcall(func) end
    end
  end)
end

-- Version event listener (compare, notify, echo replies)
local _daVer = CreateFrame("Frame")
_daVer:RegisterEvent("CHAT_MSG_ADDON")
_daVer:SetScript("OnEvent", function()
  if event ~= "CHAT_MSG_ADDON" then return end
  local prefix, text, channel, sender = arg1, arg2, arg3, arg4
  if prefix ~= DA_PREFIX or type(text) ~= "string" then return end

  local mine = tostring(DA_GetVersion_Safe())
  local cf   = (DEFAULT_CHAT_FRAME or ChatFrame1)

  if text == "DA_WHO" then
    -- someone asked; tell them our version back on the same channel
    if channel and SendAddonMessage then
      SendAddonMessage(DA_PREFIX, "DA_ME:" .. mine, channel)
    end
    return
  end

  if string.sub(text, 1, 6) == "DA_ME:" then
    local other = string.sub(text, 7)
    -- show who has what (your existing behavior)
    if cf then
      cf:AddMessage(string.format("|cff6FA8DCDoiteAuras:|r %s has %s (you: %s)", tostring(sender or "?"), tostring(other or "?"), tostring(mine)))
    end
    -- notify once if theirs is newer than mine
    if (not _daVerNotifiedOnce) and DA_IsNewer(other, mine) then
      _daVerNotifiedOnce = true
      DA_RunLater(8, function()
        if cf then
          cf:AddMessage(string.format("|cff6FA8DCDoiteAuras:|r A newer version is available (yours: %s, latest seen: %s). Consider updating.", tostring(mine), tostring(other)))
        end
      end)
    end
    return
  end

  if string.sub(text, 1, 7) == "DA_VER:" then
    local other = string.sub(text, 8)
    -- notify once if theirs is newer than mine
    if (not _daVerNotifiedOnce) and DA_IsNewer(other, mine) then
      _daVerNotifiedOnce = true
      DA_RunLater(8, function()
        if cf then
          cf:AddMessage(string.format("|cff6FA8DCDoiteAuras:|r A newer version is available (yours: %s, latest seen: %s). Consider updating.", tostring(mine), tostring(other)))
        end
      end)
    end
    -- echo mine back (rate-limited) so others see my version too
    if channel and SendAddonMessage then
      local now = (GetTime and GetTime()) or 0
      if now - _daVerLastEcho > 10 then
        _daVerLastEcho = now
        SendAddonMessage(DA_PREFIX, "DA_VER:" .. mine, channel)
      end
    end
    return
  end
end)


-- Loaded message + delayed version broadcast(s)
local _daRaidAnnounced = false

local _daLoad = CreateFrame("Frame")
_daLoad:RegisterEvent("ADDON_LOADED")
_daLoad:RegisterEvent("PLAYER_ENTERING_WORLD")
_daLoad:RegisterEvent("RAID_ROSTER_UPDATE")

_daLoad:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" and arg1 == "DoiteAuras" then
    -- 1s after load: print “loaded” line with version
    DA_RunLater(1, function()
      local v  = tostring(DA_GetVersion_Safe())
      local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
      if cf then
        cf:AddMessage("|cff6FA8DCDoiteAuras|r v"..v.." loaded. Use |cffffff00/da|r (or minimap icon).")
      end
    end)

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- 10s after entering world: broadcast my version to an available channel
    DA_RunLater(10, function()
      DA_BroadcastVersionAll()
    end)

  elseif event == "RAID_ROSTER_UPDATE" then
    -- first time you are in a raid: announce on RAID after ~3s
    if not _daRaidAnnounced and UnitInRaid and UnitInRaid("player") then
      _daRaidAnnounced = true
      DA_RunLater(3, function()
        if SendAddonMessage then
          SendAddonMessage("DOITEAURAS", "DA_VER:"..tostring(DA_GetVersion_Safe()), "RAID")
        end
      end)
    end
  end
end)

-- Update icons frequently
local updateFrame = CreateFrame("Frame")
updateFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
updateFrame:SetScript("OnEvent", function()
  if event == "PLAYER_ENTERING_WORLD" then RefreshIcons() end
end)

RebuildOrder(); RefreshList(); RefreshIcons()

DoiteAuras_RefreshList  = RefreshList
DoiteAuras_RefreshIcons = RefreshIcons

function DoiteAuras.GetAllCandidates()
    local list = {}
    for key, data in pairs(DoiteAurasDB.spells or {}) do
                local f = _G["DoiteIcon_" .. key]
        -- Intent-based visibility: conditions OR active slide
        local wants = false
        if f then
            wants = (f._daShouldShow == true) or (f._daSliding == true)
        end
        table.insert(list, {
            key  = key,
            data = data,
            show = wants,
            tex  = (f and f.icon and f.icon:GetTexture()) or nil,
            size = data.iconSize or data.size or 36,
        })
    end
    return list
end

-- Ensure an icon frame exists for a given key (no visibility changes)
function DoiteAuras_TouchIcon(key)
  if not key then return end
  local name = "DoiteIcon_"..key
  if _G[name] then return end
  if CreateOrUpdateIcon then CreateOrUpdateIcon(key, 36) end
end