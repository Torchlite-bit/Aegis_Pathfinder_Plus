-- ==========================================================
-- QuestShell+ Parser for TurtleGuide
-- Allows TurtleGuide to load guides in QuestShell+ format
-- ==========================================================

-- Type mappings (QuestShell+ uses uppercase type names)
local TYPE_TO_ACTION = {
    ACCEPT = "ACCEPT",
    TURNIN = "TURNIN",
    COMPLETE = "COMPLETE",
    KILL = "KILL",
    RUN = "RUN",
    HEARTH = "HEARTH",
    SETHEARTH = "SETHEARTH",
    SET_HEARTH = "SETHEARTH",  -- QuestShell compatibility
    GRIND = "GRIND",
    FLY = "FLY",
    GETFP = "GETFLIGHTPOINT",
    GETFLIGHTPOINT = "GETFLIGHTPOINT",
    NOTE = "NOTE",
    BUY = "BUY",
    BOAT = "BOAT",
    USE = "USE",
    PET = "PET",
    DIE = "DIE",
    TRAIN = "TRAIN",
    TRAVEL = "RUN",  -- QuestShell compatibility
}

-- Convert QuestShell+ step table to TurtleGuide tag string
local function stepToTagString(step)
    local tags = {}

    -- |QID|
    if step.questId then
        table.insert(tags, string.format("|QID|%d|", step.questId))
    end

    -- |N| (note with coords)
    local noteText = step.note or ""
    if step.coords and step.coords.x and step.coords.y then
        -- Check if coords already in note
        if not string.find(noteText, "%([%d%.]+%s*,%s*[%d%.]+%)") then
            if noteText ~= "" then
                noteText = noteText .. " "
            end
            noteText = noteText .. string.format("(%.2f, %.2f)", step.coords.x, step.coords.y)
        end
    end
    if noteText ~= "" then
        table.insert(tags, string.format("|N|%s|", noteText))
    end

    -- |C| (class)
    if step.class then
        table.insert(tags, string.format("|C|%s|", step.class))
    elseif step.classes and type(step.classes) == "table" then
        table.insert(tags, string.format("|C|%s|", table.concat(step.classes, ", ")))
    end

    -- |R| (race)
    if step.race then
        table.insert(tags, string.format("|R|%s|", step.race))
    elseif step.races and type(step.races) == "table" then
        table.insert(tags, string.format("|R|%s|", table.concat(step.races, ", ")))
    end

    -- |Z| (zone)
    if step.zone then
        table.insert(tags, string.format("|Z|%s|", step.zone))
    end

    -- |O| (optional)
    if step.optional then
        table.insert(tags, "|O|")
    end

    -- |PRE| (prerequisite)
    if step.prereq then
        table.insert(tags, string.format("|PRE|%d|", step.prereq))
    elseif step.prereqs and type(step.prereqs) == "table" then
        for _, p in ipairs(step.prereqs) do
            table.insert(tags, string.format("|PRE|%d|", p))
        end
    end

    -- |LEAD| (lead-in)
    if step.leadin then
        table.insert(tags, string.format("|LEAD|%d|", step.leadin))
    end

    -- |L| (loot)
    if step.loot and step.loot.itemId then
        local lootStr = tostring(step.loot.itemId)
        if step.loot.qty and step.loot.qty > 1 then
            lootStr = lootStr .. " " .. step.loot.qty
        end
        table.insert(tags, string.format("|L|%s|", lootStr))
    end

    -- Trade-skill steps. The quest vocabulary has nothing that expresses
    -- "craft until your skill reaches N", so profession guides carry their own
    -- tags rather than overloading |QID| or |L|.

    -- |SKILL|<profession> <from> <to>| -- completes when the player's skill in
    -- <profession> reaches <to>. <from> is what the step assumes you start at.
    if step.skill and step.skill.profession and step.skill.to then
        table.insert(tags, string.format("|SKILL|%s %d %d|",
            step.skill.profession, step.skill.from or 0, step.skill.to))
    end

    -- |CRAFT|<count> <item>| -- what to make, and how many the route expects.
    if step.craft and step.craft.item then
        table.insert(tags, string.format("|CRAFT|%d %s|",
            step.craft.count or 1, step.craft.item))
    end

    -- |MATS|<qty>x <item>, ...| -- reagents for one craft, for the materials view.
    if step.reagents and type(step.reagents) == "table" then
        local mats = {}
        for i = 1, table.getn(step.reagents) do
            local r = step.reagents[i]
            table.insert(mats, string.format("%dx %s", r.qty or 1, r.item))
        end
        if table.getn(mats) > 0 then
            table.insert(tags, string.format("|MATS|%s|", table.concat(mats, ", ")))
        end
    end

    -- |SRC| -- where the recipe comes from (trainer, vendor, drop).
    if step.source then
        table.insert(tags, string.format("|SRC|%s|", step.source))
    end

    -- |ALT| -- equally viable recipes for this range, if the route's pick is
    -- unavailable or expensive on your server.
    if step.alternatives and type(step.alternatives) == "table" then
        if table.getn(step.alternatives) > 0 then
            table.insert(tags, string.format("|ALT|%s|",
                table.concat(step.alternatives, ", ")))
        end
    end
    return table.concat(tags, " ")
end

-- Check if step is eligible for current player (class/race filtering)
local function isStepEligible(step)
    if not step then return false end

    local myclass = UnitClass("player") or ""
    local myrace = UnitRace("player") or ""

    -- Faction filter. Profession guides are registered for "Both" factions but
    -- have to show each player only their own trainers, and matching on race
    -- names is fragile across locales and custom races -- so filter on the
    -- faction directly.
    if step.faction then
        local myfaction = TurtleGuide.myfaction or UnitFactionGroup("player")
        if myfaction and step.faction ~= "Both" and step.faction ~= myfaction then
            return false
        end
    end

    -- Class filter
    if step.class then
        if not string.find(step.class, myclass) then
            return false
        end
    elseif step.classes and type(step.classes) == "table" then
        local found = false
        for i = 1, table.getn(step.classes) do
            if string.find(step.classes[i], myclass) then
                found = true
                break
            end
        end
        if not found then return false end
    end

    -- Race filter
    if step.race then
        if not string.find(step.race, myrace) then
            return false
        end
    elseif step.races and type(step.races) == "table" then
        local found = false
        for i = 1, table.getn(step.races) do
            if string.find(step.races[i], myrace) then
                found = true
                break
            end
        end
        if not found then return false end
    end

    return true
end

-- Parse QuestShell+ guide table into TurtleGuide internal format
-- Returns: actions, quests, tags (same format as string parser)
function TurtleGuide:ParseQuestShellPlus(guideTable)
    if not guideTable or not guideTable.steps then
        return {}, {}, {}
    end

    local actions, quests, tags = {}, {}, {}
    local uniqueid = 1
    local i = 1

    for _, step in ipairs(guideTable.steps) do
        if isStepEligible(step) then
            local stepType = step.type and string.upper(step.type) or "NOTE"
            local action = TYPE_TO_ACTION[stepType]

            if action then
                local quest = step.title or step.note or "Step"
                quest = TurtleGuide.trim(quest)

                quest = quest .. "@" .. uniqueid .. "@"
                uniqueid = uniqueid + 1

                actions[i] = action
                quests[i] = quest
                tags[i] = stepToTagString(step)
                i = i + 1
            end
        end
    end

    return actions, quests, tags
end

-- Check if a guide is in QuestShell+ format (table with steps array)
function TurtleGuide:IsQuestShellPlusFormat(guide)
    if type(guide) == "table" and guide.steps and type(guide.steps) == "table" then
        return true
    end
    return false
end

-- Register a QuestShell+ format guide
-- This allows mixing both formats in the same addon
function TurtleGuide:RegisterQuestShellPlusGuide(key, guideTable)
    if not self.qsplusguides then
        self.qsplusguides = {}
    end
    self.qsplusguides[key] = guideTable

    -- Also register in main guides table as a function that returns parsed content
    -- This maintains compatibility with the existing guide loading system
    local function guideLoader()
        -- Convert table format to string format for compatibility
        local lines = {}
        for _, step in ipairs(guideTable.steps or {}) do
            if isStepEligible(step) then
                local action = "N"
                local stepType = step.type and string.upper(step.type) or "NOTE"

                -- Map type to action letter
                local typeToLetter = {
                    ACCEPT = "A", TURNIN = "T", COMPLETE = "C", KILL = "K",
                    RUN = "R", HEARTH = "H", SETHEARTH = "h", GRIND = "G",
                    FLY = "F", GETFP = "f", GETFLIGHTPOINT = "f", NOTE = "N",
                    BUY = "B", BOAT = "b", USE = "U", PET = "P", DIE = "D",
                    TRAIN = "t", TRAVEL = "R", SET_HEARTH = "h"
                }
                action = typeToLetter[stepType] or "N"

                local title = step.title or step.note or "Step"
                local tagStr = stepToTagString(step)

                table.insert(lines, action .. " " .. title .. " " .. tagStr)
            end
        end
        return table.concat(lines, "\n")
    end

    self:RegisterGuide(key, guideTable.next, guideTable.faction or "Alliance", guideLoader)
end

TurtleGuide:Debug("QuestShell+ Parser loaded")
