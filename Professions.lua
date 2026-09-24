--[[
	Professions.lua -- trade-skill tracking for profession guides.

	Quest guides advance on quest events. Profession guides cannot: there is no
	"quest" to accept or turn in, only a skill number that climbs while you
	craft. This module watches that number and completes a step when its
	|SKILL| target is reached, which is the profession equivalent of the
	arrival detection that advances travel steps.

	Tags consumed here (emitted by QuestShellPlusParser and documented in
	docs/GUIDE_AUTHORING.md):

	  |SKILL|<profession> <from> <to>|   advance when skill reaches <to>
	  |CRAFT|<count> <item>|             what to make, and roughly how many
	  |MATS|<qty>x <item>, ...|          reagents for a single craft
]]

local TurtleGuide = TurtleGuide

-- Skill names as GetSkillLineInfo reports them. Mining is the awkward one:
-- the skill line is "Mining" but the craft window is "Smelting", and guides
-- may name either.
local SKILL_ALIASES = {
	["smelting"] = "mining",
}

--- Current rank in a profession, or nil if the player does not have it.
function TurtleGuide:GetSkillRank(profession)
	if not profession then return nil end

	local wanted = string.lower(profession)
	wanted = SKILL_ALIASES[wanted] or wanted

	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank = GetSkillLineInfo(i)
		if name and not isHeader then
			local have = string.lower(name)
			have = SKILL_ALIASES[have] or have
			if have == wanted then
				return rank
			end
		end
	end

	return nil
end

--- Progress through the step's skill range, as a 0..1 ratio.
-- Returns nil when the step is not a skill step or the player lacks the
-- profession, so callers can tell "no progress" from "not applicable".
function TurtleGuide:GetSkillProgress(i)
	local profession, from, to = self:GetObjectiveTag("SKILL", i)
	if not profession or not to then return nil end

	local rank = self:GetSkillRank(profession)
	if not rank then return nil end

	from = from or 0
	if to <= from then return 1, rank, to end

	local ratio = (rank - from) / (to - from)
	if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end

	return ratio, rank, to
end

--- Complete the current step if its skill target has been reached.
-- Called on every skill change rather than polling.
function TurtleGuide:CheckSkillObjective()
	local i = self.current
	if not i then return end
	if self:GetObjectiveStatus(i) then return end

	local profession, _, to = self:GetObjectiveTag("SKILL", i)
	if not profession or not to then return end

	local rank = self:GetSkillRank(profession)
	if not rank or rank < to then return end

	self:Debug(string.format("Skill objective met: %s %d/%d", profession, rank, to))
	self:SetTurnedIn()
end

--- True when a step can complete itself from skill events, which the UI shows
-- differently from a step the player has to tick by hand.
function TurtleGuide:IsSkillObjective(i)
	local profession = self:GetObjectiveTag("SKILL", i)
	return profession ~= nil
end

--- Reagents a step needs, as { item = name, need = n, have = n }.
-- `have` is nil when the item cannot be counted (the bag scan works on item
-- IDs; guide reagents are names), so the UI can show a need-only list rather
-- than a wrong count.
function TurtleGuide:GetStepReagents(i)
	local mats = self:GetObjectiveTag("MATS", i)
	if not mats then return nil end

	local _, count = self:GetObjectiveTag("CRAFT", i)
	count = count or 1

	local out = {}
	for qty, item in string.gfind(mats, "(%d+)x ([^,]+)") do
		table.insert(out, {
			item = self.trim(item),
			perCraft = tonumber(qty),
			need = tonumber(qty) * count,
		})
	end

	if table.getn(out) == 0 then return nil end

	return out
end

--- Every reagent the remaining steps of the current guide still call for.
-- This is the addon's answer to the reference document's shopping list, but
-- computed from where the player actually is rather than from step one.
function TurtleGuide:GetRemainingMaterials()
	if not self.actions then return nil end

	local totals, order = {}, {}
	for i = self.current or 1, table.getn(self.actions) do
		if not self:GetObjectiveStatus(i) then
			local reagents = self:GetStepReagents(i)
			if reagents then
				for _, r in ipairs(reagents) do
					if not totals[r.item] then
						totals[r.item] = 0
						table.insert(order, r.item)
					end
					totals[r.item] = totals[r.item] + r.need
				end
			end
		end
	end

	if table.getn(order) == 0 then return nil end

	local list = {}
	for _, item in ipairs(order) do
		table.insert(list, { item = item, need = totals[item] })
	end

	return list
end

--[[ Events ]]

function TurtleGuide:RegisterProfessionEvents()
	-- CHAT_MSG_SKILL fires on every skill-up. SKILL_LINES_CHANGED covers
	-- learning a profession and training the next rank, which move the skill
	-- cap without a skill-up message.
	self:RegisterEvent("CHAT_MSG_SKILL", "OnSkillChanged")
	self:RegisterEvent("SKILL_LINES_CHANGED", "OnSkillChanged")
end

function TurtleGuide:OnSkillChanged()
	self:CheckSkillObjective()
	self:UpdateStatusFrame()
end
