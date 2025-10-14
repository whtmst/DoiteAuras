---------------------------------------------------------------
-- DoiteGroup.lua
-- Handles icon size, position, and grouping for Doite icons
-- Turtle WoW (1.12) | Lua 5.0
---------------------------------------------------------------

local addonName, _ = "DoiteGroup"
local DoiteGroup = {}
_G["DoiteGroup"] = DoiteGroup

---------------------------------------------------------------
-- Group Layout Handling
---------------------------------------------------------------
local function ApplyGroupLayout()
    if not DoiteAurasDB or not DoiteAurasDB.spells then return end
    local groups = {}
    for key, data in pairs(DoiteAurasDB.spells) do
        if data.group then
            groups[data.group] = groups[data.group] or { leader = nil, members = {} }
            if data.isLeader then groups[data.group].leader = key end
            table.insert(groups[data.group].members, key)
        end
    end

    for gName, info in pairs(groups) do
        local leaderKey = info.leader
        if leaderKey and _G["DoiteIcon_" .. leaderKey] then
            local leaderFrame = _G["DoiteIcon_" .. leaderKey]
            local leaderData = DoiteAurasDB.spells[leaderKey]
            local growth = leaderData.growth or "Horizontal Right"
            local numShown = 0
            local spacing = (leaderData.iconSize or 40) + 4

            for _, memberKey in ipairs(info.members) do
                local memberFrame = _G["DoiteIcon_" .. memberKey]
                if memberFrame and memberKey ~= leaderKey then
                    memberFrame:ClearAllPoints()
                    if growth == "Horizontal Right" then
                        memberFrame:SetPoint("LEFT", leaderFrame, "RIGHT", spacing * numShown, 0)
                    elseif growth == "Horizontal Left" then
                        memberFrame:SetPoint("RIGHT", leaderFrame, "LEFT", -spacing * numShown, 0)
                    elseif growth == "Vertical Down" then
                        memberFrame:SetPoint("TOP", leaderFrame, "BOTTOM", 0, -spacing * numShown)
                    elseif growth == "Vertical Up" then
                        memberFrame:SetPoint("BOTTOM", leaderFrame, "TOP", 0, spacing * numShown)
                    end
                    numShown = numShown + 1
                end
            end
        end
    end
end

local oldEvaluateAll = DoiteConditions.EvaluateAll
function DoiteConditions:EvaluateAll()
    oldEvaluateAll(self)
    ApplyGroupLayout()
end

---------------------------------------------------------------
-- End of DoiteGroup.lua
---------------------------------------------------------------
