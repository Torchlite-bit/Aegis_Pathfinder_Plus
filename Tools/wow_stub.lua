--[[
	A minimal stand-in for the WoW 1.12 UI API.

	It exists so the addon's own frame-building code can be executed off-client
	in CI. It is not an emulator: it records what was asked for and enforces the
	parts of the API that are easy to get wrong (anchor points, texture
	coordinates, colour ranges), so a typo or a bad SetPoint surfaces here
	instead of in-game.

	Anything it does not implement is reported as an error rather than silently
	returning nil, which is the whole point -- a silent nil is what makes a
	1.12 UI bug so tedious to chase.
]]

local stub = {}

local VALID_POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true,
	LEFT = true, CENTER = true, RIGHT = true,
	BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local VALID_LAYERS = {
	BACKGROUND = true, BORDER = true, ARTWORK = true,
	OVERLAY = true, HIGHLIGHT = true,
}

stub.errors = {}

local function complain(fmt, ...)
	local msg = string.format(fmt, ...)
	table.insert(stub.errors, msg)
end

local function checkPoint(what, point)
	if point ~= nil and not VALID_POINTS[point] then
		complain("%s: '%s' is not a valid anchor point", what, tostring(point))
	end
end

local function checkColor(what, r, g, b, a)
	for name, v in pairs({ r = r, g = g, b = b, a = a }) do
		if v ~= nil and (type(v) ~= "number" or v < 0 or v > 1) then
			complain("%s: %s=%s out of 0..1", what, name, tostring(v))
		end
	end
end

-- Shared object behaviour ---------------------------------------------------

local function newObject(kind, name, parent)
	local o = {
		__kind = kind, __name = name, __parent = parent,
		__points = {}, __width = nil, __height = nil,
		__shown = true, __scripts = {}, __children = {}, __regions = {},
	}

	function o:SetWidth(w)
		if type(w) ~= "number" then complain("%s:SetWidth(%s) not a number", kind, tostring(w)) end
		self.__width = w
	end
	function o:SetHeight(h)
		if type(h) ~= "number" then complain("%s:SetHeight(%s) not a number", kind, tostring(h)) end
		self.__height = h
	end
	function o:GetWidth() return self.__width or 0 end
	function o:GetHeight() return self.__height or 0 end

	function o:SetPoint(p, rel, relP, x, y)
		checkPoint(kind .. ":SetPoint", p)
		-- SetPoint("LEFT", 10, 0) is the 3-arg form: rel is then a number.
		if type(rel) == "string" then checkPoint(kind .. ":SetPoint relativePoint", rel) end
		if relP ~= nil and type(relP) == "string" then checkPoint(kind .. ":SetPoint", relP) end
		table.insert(self.__points, { p, rel, relP, x, y })
	end
	function o:SetAllPoints(other) table.insert(self.__points, { "ALL", other }) end
	function o:ClearAllPoints() self.__points = {} end
	function o:GetNumPoints() return table.getn(self.__points) end

	function o:Show() self.__shown = true end
	function o:Hide() self.__shown = false end
	function o:IsShown() return self.__shown end
	function o:IsVisible() return self.__shown end
	function o:SetAlpha(a) checkColor(kind .. ":SetAlpha", nil, nil, nil, a) end
	function o:GetParent() return self.__parent end

	return o
end

local function newTexture(name, parent, layer)
	local t = newObject("Texture", name, parent)
	if layer ~= nil and not VALID_LAYERS[layer] then
		complain("CreateTexture: '%s' is not a valid draw layer", tostring(layer))
	end
	t.__layer = layer
	function t:SetTexture(path, g, b, a)
		if type(path) == "number" then return end -- SetTexture(r,g,b) colour form
		if path == nil then                       -- clears the texture; legal
			self.__texture = nil
			return
		end
		if type(path) ~= "string" then
			complain("Texture:SetTexture(%s) is not a path", tostring(path))
			return
		end
		if string.find(path, "%.tga$") or string.find(path, "%.blp$") then
			complain("Texture:SetTexture('%s') must not carry a file extension", path)
		end
		self.__texture = path
	end
	function t:GetTexture() return self.__texture end
	function t:SetTexCoord(l, r, tt, b)
		for _, v in pairs({ l, r, tt, b }) do
			if type(v) ~= "number" then
				complain("Texture:SetTexCoord got %s", tostring(v))
			end
		end
		self.__texcoord = { l, r, tt, b }
	end
	function t:SetVertexColor(r, g, b, a)
		checkColor("Texture:SetVertexColor", r, g, b, a)
		self.__color = { r, g, b, a }
	end
	function t:SetBlendMode() end
	function t:SetRotation() end
	return t
end

local function newFontString(name, parent, layer)
	local fs = newObject("FontString", name, parent)
	fs.__layer = layer
	function fs:SetFont(path, size, flags)
		if type(path) ~= "string" or type(size) ~= "number" then
			complain("FontString:SetFont(%s, %s) bad arguments", tostring(path), tostring(size))
			return false
		end
		self.__font, self.__size = path, size
		-- Report failure for a font file that is not present, mirroring the
		-- client, so fallback paths actually get exercised in tests.
		if stub.missingFonts and stub.missingFonts[path] then return false end
		return true
	end
	function fs:SetFontObject() end
	function fs:SetText(t) self.__text = t end
	function fs:GetText() return self.__text end
	function fs:SetTextColor(r, g, b, a) checkColor("FontString:SetTextColor", r, g, b, a) end
	function fs:SetJustifyH(v)
		if v ~= "LEFT" and v ~= "RIGHT" and v ~= "CENTER" then
			complain("SetJustifyH('%s')", tostring(v))
		end
	end
	function fs:SetJustifyV() end
	function fs:GetStringWidth() return string.len(self.__text or "") * 6 end
	function fs:SetWordWrap() end
	return fs
end

local function newFrame(frameType, name, parent)
	local f = newObject(frameType or "Frame", name, parent)

	function f:CreateTexture(n, layer)
		local t = newTexture(n, self, layer)
		table.insert(self.__regions, t)
		return t
	end
	function f:CreateFontString(n, layer)
		local fs = newFontString(n, self, layer)
		table.insert(self.__regions, fs)
		return fs
	end
	function f:SetScript(event, fn)
		if type(fn) ~= "function" and fn ~= nil then
			complain("SetScript('%s') given a %s", tostring(event), type(fn))
		end
		self.__scripts[event] = fn
	end
	function f:GetScript(event) return self.__scripts[event] end
	function f:HookScript(event, fn) self.__scripts[event] = fn end
	function f:RegisterEvent() end
	function f:UnregisterEvent() end
	function f:EnableMouse() end
	function f:RegisterForClicks() end
	function f:RegisterForDrag() end
	function f:SetMovable() end
	function f:SetResizable() end
	function f:SetClampedToScreen() end
	function f:SetFrameStrata(s) self.__strata = s end
	function f:SetFrameLevel(l) self.__level = l end
	function f:GetFrameLevel() return self.__level or 1 end
	function f:SetToplevel() end
	function f:StartMoving() end
	function f:StopMovingOrSizing() end
	function f:SetBackdrop(bd) self.__backdrop = bd end
	function f:SetBackdropColor(r, g, b, a) checkColor("SetBackdropColor", r, g, b, a) end
	function f:SetBackdropBorderColor(r, g, b, a) checkColor("SetBackdropBorderColor", r, g, b, a) end
    function f:SetNormalTexture() end
	function f:SetPushedTexture() end
	function f:SetHighlightTexture() end
	function f:SetCheckedTexture() end
	function f:SetDisabledCheckedTexture() end
	function f:GetNormalTexture() return newTexture(nil, self, "ARTWORK") end
	function f:SetThumbTexture() end
	function f:GetThumbTexture() return newTexture(nil, self, "ARTWORK") end
	function f:SetMinMaxValues() end
	function f:SetValue() end
	function f:GetValue() return 0 end
	function f:SetValueStep() end
	function f:SetOrientation() end
	function f:Disable() self.__enabled = false end
	function f:Enable() self.__enabled = true end
	function f:IsEnabled() return self.__enabled ~= false end
	function f:SetChecked(v) self.__checked = v and true or false end
	function f:GetChecked() return self.__checked end
	function f:SetButtonState(s)
		if s ~= "NORMAL" and s ~= "PUSHED" and s ~= "DISABLED" then
			complain("SetButtonState('%s')", tostring(s))
		end
	end
	function f:SetText() end
	function f:SetScale() end
	function f:GetEffectiveScale() return 1 end
	function f:SetHitRectInsets() end
	function f:CreateTitleRegion() return newObject("TitleRegion", nil, self) end

	if parent and parent.__children then table.insert(parent.__children, f) end
	return f
end

-- Globals the addon expects -------------------------------------------------

function stub.install(env)
	env = env or _G
	env.CreateFrame = function(frameType, name, parent, template)
		return newFrame(frameType, name, parent)
	end
	env.UIParent = newFrame("Frame", "UIParent", nil)
	env.UIParent:SetWidth(1024); env.UIParent:SetHeight(768)
	env.QuestWatchFrame = newFrame("Frame", "QuestWatchFrame", env.UIParent)
	env.WorldFrame = newFrame("Frame", "WorldFrame", nil)
	env.GameTooltip = newFrame("GameTooltip", "GameTooltip", env.UIParent)
	env.GameTooltip.SetOwner = function() end
	env.GameTooltip.SetText = function() end
	env.GameTooltip.AddLine = function() end
	env.GameTooltip.Show = function() end
	env.GameTooltip.SetItemByID = function() end
	env.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
	env.GameFontNormal = {}
	env.GameFontNormalSmall = {}
	env.GameFontHighlight = {}
	env.getglobal = function(n) return env[n] end
	env.UnitFactionGroup = function() return "Alliance" end
	env.UnitLevel = function() return 1 end
	env.UnitClass = function() return "Warrior", "WARRIOR" end
	env.UnitRace = function() return "Human", "Human" end
	env.GetLocale = function() return "enUS" end
	env.GetTime = function() return os.clock() end
	env.date = os.date
	return env
end

function stub.reset()
	stub.errors = {}
end

function stub.report()
	return stub.errors
end

return stub
