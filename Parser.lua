local actiontypes = {
	A = "ACCEPT",
	C = "COMPLETE",
	T = "TURNIN",
	K = "KILL",
	R = "RUN",
	H = "HEARTH",
	h = "SETHEARTH",
	G = "GRIND",
	F = "FLY",
	f = "GETFLIGHTPOINT",
	N = "NOTE",
	B = "BUY",
	b = "BOAT",
	U = "USE",
	P = "PET",
	D = "DIE",
	t = "TRAIN",
}


function TurtleGuide:GetObjectiveTag(tag, i)
	i = i or self.current
	if not self.tags then return end
	local tags = self.tags[i]
	if not tags then return end

	if tag == "O" then
		return string.find(tags, "|O|")
	elseif tag == "T" then
		return string.find(tags, "|T|")
	elseif tag == "S" then
		return string.find(tags, "|S|")
	elseif tag == "QID" then
		return self.select(3, string.find(tags, "|QID|(%d+)|"))
	elseif tag == "L" then
		local _, _, lootitem, lootqty = string.find(tags, "|L|(%d+)%s?(%d*)|")
		lootqty = tonumber(lootqty) or 1

		return lootitem, lootqty
	elseif tag == "SKILL" then
		-- |SKILL|<profession> <from> <to>| -- profession names can contain a
		-- space ("First Aid"), so match the two trailing numbers and take
		-- everything before them as the name.
		local _, _, profession, from, to = string.find(tags, "|SKILL|(.-)%s+(%d+)%s+(%d+)|")
		if not profession then return end

		return profession, tonumber(from), tonumber(to)
	elseif tag == "CRAFT" then
		local _, _, count, item = string.find(tags, "|CRAFT|(%d+)%s+([^|]*)|")
		if not count then return end

		return item, tonumber(count)
	end

	return self.select(3, string.find(tags, "|" .. tag .. "|([^|]*)|?"))
end

local function DumpQuestDebug(accepts, turnins, completes)
	for quest in pairs(accepts) do if not turnins[quest] then TurtleGuide:Debug(string.format(
			"Quest has no 'turnin' objective: %s", quest)) end end
	for quest in pairs(turnins) do if not accepts[quest] then TurtleGuide:Debug(string.format(
			"Quest has no 'accept' objective: %s", quest)) end end
	for quest in pairs(completes) do if not accepts[quest] and not turnins[quest] then TurtleGuide:Debug(string.format(
			"Quest has no 'accept' and 'turnin' objectives: %s", quest)) end end
end


local titlematches = { "For", "A", "The", "Or", "In", "Then", "From", "To" }
local function DebugQuestObjective(text, action, quest, accepts, turnins, completes)
	local haserrors

	if (action == "A" and accepts[quest] or action == "T" and turnins[quest] or action == "C" and completes[quest]) and not string.find(text, "|NODEBUG|") then
		TurtleGuide:Debug(string.format("%s %s -- Duplicate objective", action, quest))
		haserrors = true
	end

	if action == "A" then
		accepts[quest] = true
	elseif action == "T" then
		turnins[quest] = true
	elseif action == "C" then
		completes[quest] = true
	end

	if string.find(text, "|NODEBUG|") then return haserrors end

	if action == "A" or action == "C" or action == "T" then
		-- Catch bad Title Case
		for _, word in pairs(titlematches) do
			if string.find(quest, "[^:]%s" .. word .. "%s") or string.find(quest, "[^:]%s" .. word .. "$") or string.find(quest, "[^:]%s" .. word .. "@") then
				TurtleGuide:Debug(string.format("%s %s -- Contains bad title case", action, quest))
				haserrors = true
			end
		end
	end

	local _, _, comment = string.find(text, "(|[NLUC]V?|[^|]+)$") or string.find(text, "(|[NLUC]V?|[^|]+) |[NLUC]V?|")
	if comment then
		TurtleGuide:Debug("Unclosed comment: " .. comment)
		haserrors = true
	end

	return haserrors
end


local myclass, myrace = UnitClass("player"), UnitRace("player")
local function StepParse(guide)
	local accepts, turnins, completes = {}, {}, {}
	local uniqueid = 1
	local actions, quests, tags = {}, {}, {}
	local i, haserrors = 1, false
	local guidet = TurtleGuide.split("\r\n", guide)

	local seenObjectives = {}
	local lastHearthLocation = nil

	local function matchFilter(filter, myValue)
		if not filter then return true end
		local components = TurtleGuide.split("/", filter)
		local hasMatches = false
		local hasNegations = false

		for _, sp in ipairs(components) do
			if string.sub(sp, 1, 1) == "!" then
				hasNegations = true
				if string.sub(sp, 2) == myValue then return false end
			else
				if sp == myValue then hasMatches = true end
			end
		end

		if hasNegations and not hasMatches then return true end
		return hasMatches
	end

	local function matchDungeonFilter(dungeon)
		if not dungeon then return true end
		local components = TurtleGuide.split("/", dungeon)
		local hasMatches = false
		local hasNegations = false

		for _, sp in ipairs(components) do
			local isNegation = string.sub(sp, 1, 1) == "!"
			local code = isNegation and string.sub(sp, 2) or sp
			code = string.upper(code)

			local isSelected = TurtleGuide.db and TurtleGuide.db.char and TurtleGuide.db.char.Dungeons and
			TurtleGuide.db.char.Dungeons[code]

			if isNegation then
				hasNegations = true
				if isSelected then return false end
			else
				if isSelected then hasMatches = true end
			end
		end

		if hasNegations and not hasMatches then return true end
		return hasMatches
	end

	local function matchPlayStyleFilter(playstyle)
		if not playstyle then return true end
		local setting = TurtleGuide.db and TurtleGuide.db.char and TurtleGuide.db.char.PlayStyle or "SOLO"
		return string.upper(playstyle) == string.upper(setting)
	end

	local function matchAHFilter(ah)
		if not ah then return true end
		return TurtleGuide.db and TurtleGuide.db.char and not not TurtleGuide.db.char.UseAH
	end

	for _, text in pairs(guidet) do
		local _, _, class = string.find(text, "|C|([^|]+)|")
		local _, _, race = string.find(text, "|R|([^|]+)|")
		local _, _, dungeon = string.find(text, "|D|([^|]+)|")
		local _, _, playstyle = string.find(text, "|P|([^|]+)|")
		local hasAH = not not string.find(text, "|AH|", 1, true)
		if text ~= "" and matchFilter(class, myclass) and matchFilter(race, myrace)
			and matchDungeonFilter(dungeon) and matchPlayStyleFilter(playstyle)
			and matchAHFilter(hasAH) then
			local _, _, action, quest, tag = string.find(text, "^(%a) ([^|]*)(.*)")
			if action and actiontypes[action] then
				quest = TurtleGuide.trim(quest)
				
				-- Deduplicate duplicate ACCEPT (A), TURNIN (T), and SETHEARTH (h) objectives
				local cleanQuest = quest
				local qid = nil
				if tag then
					local _, _, qid_val = string.find(tag, "|QID|(%d+)|")
					qid = qid_val
				end
				
				local isDuplicate = false
				if action == "A" or action == "T" then
					local key = action .. ":" .. (qid or cleanQuest)
					if seenObjectives[key] then
						isDuplicate = true
					else
						seenObjectives[key] = true
					end
				elseif action == "h" then
					if cleanQuest == lastHearthLocation then
						isDuplicate = true
					else
						lastHearthLocation = cleanQuest
					end
				end
				
				if not isDuplicate then
					quest = quest .. "@" .. uniqueid .. "@"
					uniqueid = uniqueid + 1
					actions[i], quests[i], tags[i] = actiontypes[action], quest, tag
					i = i + 1
					haserrors = DebugQuestObjective(text, action, quest, accepts, turnins, completes) or haserrors
				end
			end
		end
	end
	DumpQuestDebug(accepts, turnins, completes)
	if haserrors and TurtleGuide:IsDebugging() then TurtleGuide:Print("This guide contains errors") end

	return actions, quests, tags
end


-- Drain a warm queue ({kind="q"|"i", id=n}) a few entries per tick instead of
-- all at once. A synchronous burst of hundreds of RequestLoad* calls at guide
-- load spikes CPU and, when the QIDs are for another server's content and never
-- resolve, can crash the client's fixed Lua pool. Each LoadGuide bumps
-- warmtoken so a queue from a previous guide stops draining.
local WARM_BATCH = 5      -- requests per tick
local WARM_INTERVAL = 0.1 -- seconds between ticks
function TurtleGuide:WarmCaches(queue)
	self.warmtoken = (self.warmtoken or 0) + 1
	local token = self.warmtoken
	local n = table.getn(queue)
	local idx = 1
	local function drain()
		if token ~= self.warmtoken then return end -- superseded by a newer load
		local processed = 0
		while idx <= n and processed < WARM_BATCH do
			local e = queue[idx]
			idx = idx + 1
			processed = processed + 1
			if e.kind == "q" then
				if not C_QuestLog.IsQuestDataCachedByID(e.id) then
					C_QuestLog.RequestLoadQuestByID(e.id)
				end
			elseif not C_Item.IsItemDataCachedByID(e.id) then
				C_Item.RequestLoadItemDataByID(e.id)
			end
		end
		if idx <= n then C_Timer.After(WARM_INTERVAL, drain) end
	end
	drain()
end

function TurtleGuide:LoadGuide(name, complete)
	if not name then return end
	if complete then
		self.db.char.completion[self.db.char.currentguide] = 1
	elseif self.actions then
		self.db.char.completion[self.db.char.currentguide] = (self.current - 1) / table.getn(self.actions)
	end

	self.db.char.currentguide = self.guides[name] and name or self.guidelist[1]

	self:Debug(string.format("Loading guide: %s", name))
	self.guidechanged = true
	-- Extract zone name from guide name, stripping any path prefix (e.g., "Optimized/")
	local _, _, zonename = string.find(name, "([^/]+) %(.*%)$")
	self.zonename = zonename
	local guideContent = self.guides[self.db.char.currentguide]()
	if type(guideContent) == "table" and guideContent.steps then
		-- QuestShell+ format (Lua table with steps array)
		self.actions, self.quests, self.tags = self:ParseQuestShellPlus(guideContent)
	else
		-- Traditional TurtleGuide format (string)
		self.actions, self.quests, self.tags = StepParse(guideContent)
	end

	-- Per-load loot-requirement cache; keyed by step index, so it must be
	-- dropped whenever the step list is re-parsed
	self.lootreqcache = {}

	-- Collect everything the guide references so later title/name/icon lookups
	-- are cache hits. The RequestLoad* calls are drained on a throttle (see
	-- WarmCaches): firing hundreds synchronously floods the engine's
	-- quest-query subsystem, and on a mismatched server (e.g. a Turtle guide on
	-- a vanilla realm) most QIDs never resolve, so a login-time burst of dead
	-- requests can exhaust the client's fixed Lua pool.
	local requested = {}
	local warmqueue = {}
	local function enqueue(kind, id)
		if not id then return end
		local key = kind .. id
		if requested[key] then return end
		requested[key] = true
		warmqueue[table.getn(warmqueue) + 1] = { kind = kind, id = id }
	end
	for i in ipairs(self.actions) do
		local qid = tonumber((self:GetObjectiveTag("QID", i)))
		enqueue("q", qid)
		enqueue("i", tonumber((self:GetObjectiveTag("L", i))))
		enqueue("i", tonumber((self:GetObjectiveTag("U", i))))

		-- Sanity-check authored |OIDX| tags against the quest's objective
		-- list; skipped silently while the static data is still loading
		local oidx = tonumber((self:GetObjectiveTag("OIDX", i)))
		if qid and oidx then
			local numObjectives = C_QuestLog.GetNumQuestObjectives(qid)
			if numObjectives and oidx > numObjectives then
				self:Debug(string.format("Step %d: |OIDX|%d| out of range - quest %d has %d objectives",
					i, oidx, qid, numObjectives))
			end
		end
	end
	self:WarmCaches(warmqueue)

	if not self.db.char.turnins[name] then self.db.char.turnins[name] = {} end
	self.turnedin = self.db.char.turnins[name]

	-- Step keys restart per guide, so the skipped-turnin warnings reset too
	self.turninskipwarned = {}

	if self.manuallyUnchecked then
		for k in pairs(self.manuallyUnchecked) do
			self.manuallyUnchecked[k] = nil
		end
	end

	-- Smart skip: scan quest log and skip to furthest incomplete step
	self:SmartSkipToStep()
end

-- Get quest prerequisites from pfQuest database (if available)
-- Returns table of prerequisite QIDs, or nil if not found
function TurtleGuide:GetQuestPrerequisites(qid)
	if not qid then return nil end
	qid = tonumber(qid)
	if not qid then return nil end

	-- Check if pfQuest database is available
	if not pfDB or not pfDB["quests"] or not pfDB["quests"]["data"] then
		return nil
	end

	local questData = pfDB["quests"]["data"][qid]
	if questData and questData["pre"] then
		return questData["pre"]
	end
	return nil
end

-- Check if a quest is possible for the player's race and class
function TurtleGuide:IsQuestPossible(qid, visited)
	if not qid then return true end
	qid = tonumber(qid)
	if not qid then return true end

	visited = visited or {}
	if visited[qid] then return true end
	visited[qid] = true

	local questOverrides = {
		-- Tauren starting area / Rites of the Earthmother chain (Tauren only)
		[752] = { race = 32 }, -- A Humble Task
		[753] = { race = 32 }, -- A Humble Task
		[755] = { race = 32 }, -- Rites of the Earthmother
		[757] = { race = 32 }, -- Rite of Strength
		[763] = { race = 32 }, -- The Rite of Vision
		[767] = { race = 32 }, -- The Rite of Vision
		[771] = { race = 32 }, -- The Rite of Vision
		[772] = { race = 32 }, -- The Rite of Vision
		[773] = { race = 32 }, -- Rite of Wisdom
	}

	local requiredRace, requiredClass
	local override = questOverrides[qid]
	if override then
		requiredRace = override.race
		requiredClass = override.class
	elseif pfDB and pfDB["quests"] and pfDB["quests"]["data"] then
		local questData = pfDB["quests"]["data"][qid]
		if questData then
			requiredRace = questData["race"]
			requiredClass = questData["class"]
		end
	end

	-- Check race restriction
	if requiredRace and requiredRace ~= 0 then
		local raceMap = {
			["Human"] = 1,
			["Orc"] = 2,
			["Dwarf"] = 4,
			["NightElf"] = 8,
			["Undead"] = 16,
			["Tauren"] = 32,
			["Gnome"] = 64,
			["Troll"] = 128,
			["HighElf"] = 256,
			["Goblin"] = 512,
		}
		local _, myRaceFile = UnitRace("player")
		local myRaceMask = raceMap[myRaceFile]
		if myRaceMask then
			if math.mod(math.floor(requiredRace / myRaceMask), 2) == 0 then
				return false
			end
		end
	end

	-- Check class restriction
	if requiredClass and requiredClass ~= 0 then
		local classMap = {
			["WARRIOR"] = 1,
			["PALADIN"] = 2,
			["HUNTER"] = 4,
			["ROGUE"] = 8,
			["PRIEST"] = 16,
			["SHAMAN"] = 64,
			["MAGE"] = 128,
			["WARLOCK"] = 256,
			["DRUID"] = 1024,
		}
		local _, myClassFile = UnitClass("player")
		local myClassMask = classMap[myClassFile]
		if myClassMask then
			if math.mod(math.floor(requiredClass / myClassMask), 2) == 0 then
				return false
			end
		end
	end

	-- Recursively check prerequisites (only if not overridden)
	if not override then
		local prereqs = self:GetQuestPrerequisites(qid)
		if prereqs then
			for _, prereqQid in ipairs(prereqs) do
				if not self:IsQuestPossible(prereqQid, visited) then
					return false
				end
			end
		end
	end

	return true
end

-- Recursively mark all prerequisites of a quest as completed
-- Returns count of newly marked quests
function TurtleGuide:MarkPrerequisitesCompleted(qid, visited)
	if not qid then return 0 end
	visited = visited or {}

	-- Prevent infinite loops
	if visited[qid] then return 0 end
	visited[qid] = true

	local prereqs = self:GetQuestPrerequisites(qid)
	if not prereqs then return 0 end

	local count = 0
	for _, prereqQid in ipairs(prereqs) do
		-- Mark this prerequisite as completed
		if not self.db.char.completedquestsbyid[prereqQid] then
			self.db.char.completedquestsbyid[prereqQid] = true
			self:Debug("Inferred completed (pfQuest prereq): QID " .. prereqQid)
			count = count + 1
		end
		-- Recursively mark its prerequisites
		count = count + self:MarkPrerequisitesCompleted(prereqQid, visited)
	end
	return count
end

-- Check if a quest's prerequisites are met
-- Returns: met (bool), unmetQids (table of unmet prerequisite QIDs)
function TurtleGuide:ArePrerequisitesMet(qid)
	if not qid then return true, {} end
	qid = tonumber(qid)
	if not qid then return true, {} end

	local prereqs = self:GetQuestPrerequisites(qid)
	if not prereqs then return true, {} end

	local unmet = {}
	for _, prereqQid in ipairs(prereqs) do
		-- Check if prerequisite is completed (by QID or in quest log)
		local isComplete = self.db.char.completedquestsbyid[prereqQid]
		if not isComplete then
			-- Also check if it's in the quest log (accepted but not turned in yet)
			-- That means the player is working on it, which is fine
			local inLog = self:IsQuestInLogByQid(prereqQid)
			if not inLog then
				table.insert(unmet, prereqQid)
			end
		end
	end

	return table.getn(unmet) == 0, unmet
end

-- Check if a quest (by QID) is in the player's quest log
function TurtleGuide:IsQuestInLogByQid(qid)
	qid = tonumber(qid)
	if not qid then return false end
	return C_QuestLog.IsOnQuest(qid)
end

-- Get quest name by QID
function TurtleGuide:GetQuestNameByQid(qid)
	qid = tonumber(qid)
	if not qid then return nil end

	-- Server-authoritative quest cache first: guaranteed to match the titles
	-- the quest log uses (warmed for all guide QIDs at load)
	local title = C_QuestLog.GetTitleForQuestID(qid)
	if title then return title end

	-- Fall back to pfQuest localized quest names
	if pfDB and pfDB["quests"] and pfDB["quests"]["loc"] then
		local locData = pfDB["quests"]["loc"][qid]
		if locData then
			-- pfQuest stores quest data as table with "T" (title) field
			if type(locData) == "table" then
				return locData["T"]
			end
			return locData
		end
	end

	return nil
end

-- Find the guide step index for a given QID
-- Returns step index or nil if not found
function TurtleGuide:FindGuideStepByQid(qid)
	if not qid or not self.quests or not self.actions then return nil end
	qid = tostring(qid)

	for i, quest in ipairs(self.quests) do
		local stepQid = self:GetObjectiveTag("QID", i)
		if stepQid == qid then
			return i
		end
	end
	return nil
end

-- Get unmet prerequisites for current objective, with guide step info
-- Returns table: { {qid=123, name="Quest Name", guideStep=5}, ... }
function TurtleGuide:GetUnmetPrerequisites(stepIndex)
	stepIndex = stepIndex or self.current
	if not stepIndex then return {} end

	local qid = self:GetObjectiveTag("QID", stepIndex)
	if not qid then return {} end

	local met, unmetQids = self:ArePrerequisitesMet(qid)
	if met then return {} end

	local result = {}
	for _, prereqQid in ipairs(unmetQids) do
		local info = {
			qid = prereqQid,
			name = self:GetQuestNameByQid(prereqQid) or ("QID " .. prereqQid),
			guideStep = self:FindGuideStepByQid(prereqQid)
		}
		table.insert(result, info)
	end
	return result
end

-- Smart guide switching: scan quest log and skip completed content
function TurtleGuide:SmartSkipToStep()
	if not self.actions or not self.quests then return end

	-- Name-keyed maps serve steps without a |QID| tag; QID-keyed maps are
	-- authoritative for tagged steps and immune to duplicate quest names
	local completedQuests = {}
	local inProgressQuests = {}
	local completedQuestIDs = {}
	local inProgressQuestIDs = {}

	-- Scan quest log
	for i = 1, GetNumQuestLogEntries() do
		local title, _, _, isHeader, _, isComplete = GetQuestLogTitle(i)
		if not isHeader and title then
			local questID = C_QuestLog.GetQuestIDForLogIndex(i)
			title = string.gsub(title, "%[[0-9%+%-]+]%s", "")
			if isComplete == 1 then
				completedQuests[title] = true
				if questID then completedQuestIDs[questID] = true end
			else
				inProgressQuests[title] = true
				if questID then inProgressQuestIDs[questID] = true end
			end
		end
	end

	-- Database Self-Healing:
	-- If a quest is in the player's quest log, it cannot be fully turned in / completed.
	-- Clear any stale/corrupted completed flags for this quest and all its candidates in the guide.
	for i, quest in ipairs(self.quests) do
		local cleanQuest = string.gsub(quest, "@.*@", "")
		cleanQuest = string.gsub(cleanQuest, TurtleGuide.Locale.PART_GSUB, "")
		local qidNum = tonumber((self:GetObjectiveTag("QID", i)))
		local inLog
		if qidNum then
			inLog = completedQuestIDs[qidNum] or inProgressQuestIDs[qidNum]
		else
			inLog = completedQuests[cleanQuest] or inProgressQuests[cleanQuest]
		end
		if inLog then
			-- Do not clear QID if it is confirmed completed in pfQuest history
			if qidNum and not (pfQuest_history and (pfQuest_history[qidNum] or pfQuest_history[tostring(qidNum)])) then
				self.db.char.completedquestsbyid[qidNum] = nil
			end
			self.db.char.completedquests[cleanQuest] = nil
		end
	end

	-- QUEST CHAIN INFERENCE via pfQuest database:
	-- For each quest in the guide that's in the player's log, look up its
	-- prerequisites in pfQuest and mark them as completed.
	if pfDB and pfDB["quests"] and pfDB["quests"]["data"] then
		for i, quest in ipairs(self.quests) do
			local action = self.actions[i]
			local qid = self:GetObjectiveTag("QID", i)
			if qid and (action == "ACCEPT" or action == "COMPLETE" or action == "TURNIN") then
				local cleanQuest = string.gsub(quest, "@.*@", "")
				cleanQuest = string.gsub(cleanQuest, TurtleGuide.Locale.PART_GSUB, "")
				local qidInLog = inProgressQuestIDs[tonumber(qid)] or completedQuestIDs[tonumber(qid)]
				-- If quest is in log, mark its prerequisites as completed
				if qidInLog then
					local qidNum = tonumber(qid)
					local canInfer = true
					local prereqs = self:GetQuestPrerequisites(qidNum)
					if prereqs then
						for _, preQid in ipairs(prereqs) do
							if not self.db.char.completedquestsbyid[preQid] then
								-- Check if the prerequisite has the same name
								local preQuestData = pfDB["quests"]["data"][preQid]
								if preQuestData then
									local preQuestName = pfDB.quests.loc and pfDB.quests.loc[preQid] and
									pfDB.quests.loc[preQid]["T"] or nil
									if preQuestName then
										local cleanPreQuest = string.gsub(preQuestName, "%[[0-9%+%-]+]%s", "")
										cleanPreQuest = string.gsub(cleanPreQuest, TurtleGuide.Locale.PART_GSUB, "")
										if cleanPreQuest == cleanQuest then
											canInfer = false
											break
										end
									end
								end
							end
						end
					end

					if canInfer then
						self:MarkPrerequisitesCompleted(qidNum)
					end
				end
			end
		end
	end

	-- Pre-mark completed quests by QID (from pfQuest inference) or impossible quests
	for i, quest in ipairs(self.quests) do
		local action = self.actions[i]
		local qid = self:GetObjectiveTag("QID", i)
		if qid then
			local qidNum = tonumber(qid)
			if (qidNum and self.db.char.completedquestsbyid[qidNum]) or not self:IsQuestPossible(qidNum) then
				if action == "TURNIN" or action == "ACCEPT" or action == "COMPLETE" or action == "RUN" then
					self.turnedin[quest] = true
				end
			end
		end
	end

	-- Pre-mark locally-tracked completed quests (by name)
	for i, quest in ipairs(self.quests) do
		local action = self.actions[i]
		local qid = self:GetObjectiveTag("QID", i)
		if not qid then
			local cleanQuest = string.gsub(quest, "@.*@", "")
			cleanQuest = string.gsub(cleanQuest, TurtleGuide.Locale.PART_GSUB, "")
			if self.db.char.completedquests[cleanQuest] then
				if action == "TURNIN" or action == "ACCEPT" or action == "COMPLETE" or action == "RUN" then
					self.turnedin[quest] = true
				end
			end
		end
	end

	-- Find the furthest step that has incomplete work
	local furthestStep = 1
	for i, quest in ipairs(self.quests) do
		local action = self.actions[i]
		local cleanQuest = string.gsub(quest, "@.*@", "")
		cleanQuest = string.gsub(cleanQuest, TurtleGuide.Locale.PART_GSUB, "")
		local qidNum = tonumber((self:GetObjectiveTag("QID", i)))
		local isCompleted = (qidNum and self.db.char.completedquestsbyid[qidNum]) or
		(not qidNum and self.db.char.completedquests[cleanQuest])

		-- Quest log state, QID-keyed when the step is tagged
		local logInProgress, logComplete
		if qidNum then
			logInProgress = inProgressQuestIDs[qidNum]
			logComplete = completedQuestIDs[qidNum]
		else
			logInProgress = inProgressQuests[cleanQuest]
			logComplete = completedQuests[cleanQuest]
		end

		if action == "ACCEPT" then
			-- If quest is in log or completed, mark as done
			if logInProgress or logComplete or isCompleted then
				self.turnedin[quest] = true
			end
		elseif action == "TURNIN" then
			-- If quest is complete and in log, we need to turn it in
			if logComplete and not self.turnedin[quest] then
				furthestStep = i
				break
			elseif isCompleted then
				self.turnedin[quest] = true
			end
		elseif action == "COMPLETE" then
			-- If quest is in progress but not complete, this is our step
			if logInProgress and not logComplete and not isCompleted then
				furthestStep = i
				break
			elseif logComplete or isCompleted then
				self.turnedin[quest] = true
			end
		elseif action == "RUN" then
			-- Run/Travel steps with QID: auto-complete if linked quest is done
			if qidNum and self.db.char.completedquestsbyid[qidNum] then
				self.turnedin[quest] = true
			end
		elseif action == "TRAIN" then
			if self:IsTrainingCompleted(cleanQuest) then
				self.turnedin[quest] = true
			end
		end

		-- Track last incomplete step
		local stepTurnedIn = self.turnedin[quest]
		if not stepTurnedIn and action == "TURNIN" then
			if not logInProgress and not logComplete and not isCompleted then
				stepTurnedIn = true
			end
		end

		if not stepTurnedIn then
			furthestStep = i
		end
	end

	if furthestStep > 1 then
		self:Debug(string.format(TurtleGuide.Locale["Skipping to step %d (completed content detected)"], furthestStep))
	end

	-- Set initial current position
	self.current = furthestStep
end

function TurtleGuide:DebugGuideSequence(dumpquests)
	local accepts, turnins, completes = {}, {}, {}
	local function DebugParse(guide)
		local uniqueid, haserrors = 1
		local guidet = TurtleGuide.split("\n", guide)
		for _, text in pairs(guidet) do
			if text ~= "" then
				local _, _, action, quest, tag = string.find(text, "^(%a) ([^|]*)(.*)")
				if action and not actiontypes[action] then TurtleGuide:Debug("Unknown action: " .. text) end
				if quest then
					quest = TurtleGuide.trim(quest)
					quest = quest .. "@" .. uniqueid .. "@"
					uniqueid = uniqueid + 1
					haserrors = DebugQuestObjective(text, action, quest, accepts, turnins, completes) or haserrors
				end
			end
		end

		return haserrors
	end

	self:Debug("------ Begin Full Debug ------")

	local name, lastzone = self.db.char.currentguide
	repeat
		if not self.guides[name] then
			self:Debug(string.format("Cannot find guide %q", name))
			name, lastzone = nil, name
		elseif DebugParse(self.guides[name]()) then
			self:Debug(string.format("Errors in guide: %s", name))
			self:Debug("---------------------------")
		end
		name, lastzone = self.nextzones[name], name
	until not name

	if dumpquests then
		self:Debug("------ Quest Continuity Debug ------")
		DumpQuestDebug(accepts, turnins, completes)
	end
	self:Debug("Last zone loaded:", lastzone)
	self:Debug("------ End Full Debug ------")
end
