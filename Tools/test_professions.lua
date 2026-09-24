--[[
	End-to-end test for the profession guide pipeline.

	Loads the generated guides, runs them through the real QuestShell+ parser,
	and checks that the trade-skill tags survive the round trip into the
	accessors Professions.lua reads them back with. This exercises the actual
	shipped code paths, not a reimplementation of them.

	Run:  lua5.1 Tools/test_professions.lua
]]

package.path = "Tools/?.lua;" .. package.path
local stub = require("wow_stub")
stub.install(_G)

-- Minimum addon surface the parsers touch.
TurtleGuide = {
	guides = {}, guidelist = {}, nextzones = {}, qsplusguides = {},
	myfaction = "Alliance",
	tags = {}, actions = {}, quests = {}, turnedin = {},
	current = 1,
}
function TurtleGuide:Debug() end
function TurtleGuide:Print() end
function TurtleGuide.trim(s)
	return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end
function TurtleGuide.select(index, ...)
	if index == "#" then return table.getn(arg) end
	return arg[index]
end
function TurtleGuide:RegisterGuide(name, nextzone, faction, loader)
	self.guides[name] = loader
	self.nextzones[name] = nextzone
	table.insert(self.guidelist, name)
end
function TurtleGuide:GetObjectiveStatus() return nil end
function TurtleGuide:SetTurnedIn() self.__turnedIn = true end
function TurtleGuide:UpdateStatusFrame() end
function TurtleGuide:RegisterEvent() end

dofile("Parser.lua")
dofile("QuestShellPlusParser.lua")
dofile("Professions.lua")

local failures, checks = {}, 0
local function check(cond, fmt, ...)
	checks = checks + 1
	if not cond then table.insert(failures, string.format(fmt, ...)) end
end

-- Load every generated guide -------------------------------------------------

local AUTHORED = {
	"Alchemy", "Blacksmithing", "Cooking", "Enchanting", "First_Aid",
	"Jewelcrafting", "Leatherworking", "Mining", "Survival", "Tailoring",
}
local TEMPLATES = { "Engineering", "Fishing", "Herbalism", "Skinning" }

for _, name in ipairs(AUTHORED) do
	dofile("Guides/Professions/" .. name .. ".lua")
end
for _, name in ipairs(TEMPLATES) do
	dofile("Guides/Professions/" .. name .. ".lua")
end

check(table.getn(TurtleGuide.guidelist) == 14,
	"expected 14 profession guides registered, got %d",
	table.getn(TurtleGuide.guidelist))

-- Structural checks over every authored guide --------------------------------

for _, key in ipairs(TurtleGuide.guidelist) do
	local guide = TurtleGuide.qsplusguides[key]
	check(guide ~= nil, "%s did not register a QuestShell+ table", key)
	if guide then
		check(guide.faction == "Both", "%s should be faction Both", key)
		check(guide.category == "Profession", "%s should be category Profession", key)
		check(table.getn(guide.steps) > 0, "%s has no steps", key)
	end
end

-- Skill ranges must tile 1..300 without gaps, in every authored guide.
for _, name in ipairs(AUTHORED) do
	local display = string.gsub(name, "_", " ") .. " (1-300)"
	local guide = TurtleGuide.qsplusguides[display]
	check(guide ~= nil, "no guide registered as '%s'", display)
	if guide then
		local cursor, seen = nil, 0
		for _, step in ipairs(guide.steps) do
			if step.skill then
				seen = seen + 1
				if cursor == nil then
					check(step.skill.from == 1, "%s: first range starts at %d, not 1",
						display, step.skill.from)
				else
					check(step.skill.from == cursor,
						"%s: range starts at %d but previous ended at %d",
						display, step.skill.from, cursor)
				end
				check(step.skill.to > step.skill.from,
					"%s: range %d-%d does not advance",
					display, step.skill.from, step.skill.to)
				cursor = step.skill.to
			end
		end
		check(seen > 0, "%s has no skill steps", display)
		check(cursor == 300, "%s: route ends at %s, not 300", display, tostring(cursor))
	end
end

-- Templates must be obviously unauthored, not silently empty.
for _, name in ipairs(TEMPLATES) do
	local guide = TurtleGuide.qsplusguides[name .. " (1-300)"]
	check(guide and guide.template == true,
		"%s should be flagged template = true", name)
	if guide then
		local hasSkill = false
		for _, s in ipairs(guide.steps) do
			if s.skill then hasSkill = true end
		end
		check(not hasSkill, "%s is a template but carries skill steps", name)
	end
end

-- Tag round trip -------------------------------------------------------------

local actions, quests, tags = TurtleGuide:ParseQuestShellPlus(
	TurtleGuide.qsplusguides["Alchemy (1-300)"])
check(table.getn(actions) > 0, "Alchemy produced no parsed steps")

TurtleGuide.actions, TurtleGuide.quests, TurtleGuide.tags = actions, quests, tags

local craftIndex
for i = 1, table.getn(tags) do
	if string.find(tags[i], "|CRAFT|40 Minor Healing Potion|", 1, true) then
		craftIndex = i
		break
	end
end
check(craftIndex ~= nil, "no step emitted |CRAFT|40 Minor Healing Potion|")

if craftIndex then
	local profession, from, to = TurtleGuide:GetObjectiveTag("SKILL", craftIndex)
	check(profession == "Alchemy", "SKILL profession round-tripped as '%s'", tostring(profession))
	check(from == 1 and to == 63, "SKILL range round-tripped as %s-%s",
		tostring(from), tostring(to))

	local item, count = TurtleGuide:GetObjectiveTag("CRAFT", craftIndex)
	check(item == "Minor Healing Potion", "CRAFT item round-tripped as '%s'", tostring(item))
	check(count == 40, "CRAFT count round-tripped as %s", tostring(count))

	local src = TurtleGuide:GetObjectiveTag("SRC", craftIndex)
	check(src == "Auto-learned", "SRC round-tripped as '%s'", tostring(src))

	local reagents = TurtleGuide:GetStepReagents(craftIndex)
	check(reagents ~= nil and table.getn(reagents) == 3,
		"expected 3 reagents, got %s", reagents and table.getn(reagents) or "nil")
	if reagents then
		check(reagents[1].item == "Peacebloom", "first reagent is '%s'", reagents[1].item)
		-- 40 crafts x 1 Peacebloom each
		check(reagents[1].need == 40, "Peacebloom need should be 40, got %d", reagents[1].need)
	end
end

-- A profession name containing a space must survive the SKILL tag.
local faActions, faQuests, faTags = TurtleGuide:ParseQuestShellPlus(
	TurtleGuide.qsplusguides["First Aid (1-300)"])
TurtleGuide.actions, TurtleGuide.quests, TurtleGuide.tags =
	faActions, faQuests, faTags
local found
for i = 1, table.getn(faTags) do
	local profession = TurtleGuide:GetObjectiveTag("SKILL", i)
	if profession then found = profession break end
end
check(found == "First Aid",
	"a two-word profession should round-trip intact, got '%s'", tostring(found))

-- Faction filtering ----------------------------------------------------------

local function trainerCountFor(faction)
	TurtleGuide.myfaction = faction
	local a, q, t = TurtleGuide:ParseQuestShellPlus(
		TurtleGuide.qsplusguides["Alchemy (1-300)"])
	local n = 0
	for i = 1, table.getn(q) do
		if string.find(q[i], "Alchemy %(") and a[i] == "TRAIN" then n = n + 1 end
	end
	return n
end

local alliance = trainerCountFor("Alliance")
local horde = trainerCountFor("Horde")
check(alliance > 0, "Alliance sees no Alchemy trainer steps")
check(horde > 0, "Horde sees no Alchemy trainer steps")

TurtleGuide.myfaction = "Alliance"
local a2, q2, t2 = TurtleGuide:ParseQuestShellPlus(
	TurtleGuide.qsplusguides["Alchemy (1-300)"])
local sawHordeTrainer = false
for i = 1, table.getn(q2) do
	-- Whuut is Horde-only (Orgrimmar); an Alliance player must never see him.
	if string.find(q2[i], "Whuut", 1, true) or string.find(t2[i] or "", "Whuut", 1, true) then
		sawHordeTrainer = true
	end
end
check(not sawHordeTrainer, "an Alliance player was shown a Horde-only trainer")

-- Skill tracking -------------------------------------------------------------

local ranks = {}
GetNumSkillLines = function() return table.getn(ranks) end
GetSkillLineInfo = function(i)
	local r = ranks[i]
	return r.name, r.header, false, r.rank
end

ranks = { { name = "Alchemy", header = nil, rank = 40 } }
check(TurtleGuide:GetSkillRank("Alchemy") == 40, "GetSkillRank should read the skill line")
check(TurtleGuide:GetSkillRank("Tailoring") == nil,
	"GetSkillRank should return nil for a profession the player lacks")

-- Mining's skill line is "Mining" while guides may say "Smelting".
ranks = { { name = "Mining", header = nil, rank = 150 } }
check(TurtleGuide:GetSkillRank("Smelting") == 150,
	"Smelting should resolve to the Mining skill line")

-- Headers must never be matched as a skill.
ranks = { { name = "Professions", header = 1, rank = 0 },
          { name = "Cooking", header = nil, rank = 75 } }
check(TurtleGuide:GetSkillRank("Professions") == nil,
	"a skill-list header is not a profession")
check(TurtleGuide:GetSkillRank("Cooking") == 75, "Cooking rank should be found")

-- Auto-completion fires only once the target is reached.
TurtleGuide.actions, TurtleGuide.quests, TurtleGuide.tags = actions, quests, tags
TurtleGuide.current = craftIndex
ranks = { { name = "Alchemy", header = nil, rank = 62 } }
TurtleGuide.__turnedIn = nil
TurtleGuide:CheckSkillObjective()
check(TurtleGuide.__turnedIn == nil,
	"a step must not complete one point short of its target")

ranks = { { name = "Alchemy", header = nil, rank = 63 } }
TurtleGuide:CheckSkillObjective()
check(TurtleGuide.__turnedIn == true, "reaching the target should complete the step")

-- Progress reporting.
ranks = { { name = "Alchemy", header = nil, rank = 32 } }
local ratio = TurtleGuide:GetSkillProgress(craftIndex)
check(ratio > 0.49 and ratio < 0.51, "skill 32 of 1-63 should read ~50%%, got %s",
	tostring(ratio))
ranks = {}
check(TurtleGuide:GetSkillProgress(craftIndex) == nil,
	"progress should be nil when the player lacks the profession")

-- Report ---------------------------------------------------------------------

for _, e in ipairs(stub.report()) do table.insert(failures, "API misuse: " .. e) end

print(string.format("Professions: %d checks across %d guides",
	checks, table.getn(TurtleGuide.guidelist)))
if table.getn(failures) == 0 then
	print("All profession checks passed.")
	os.exit(0)
end
print(string.format("\n%d failure(s):", table.getn(failures)))
for _, f in ipairs(failures) do print("  - " .. f) end
os.exit(1)
