-- Self Found - Profile window
-- Check any player (or yourself). Top: what their own addon claims. Middle:
-- the Witness Record - how many of their played hours other people's addons
-- can account for, plus flags - computed here from everyone's records, so a
-- faked addon can't inflate it. Bottom: your own timeline of them, and each
-- witness who answered.

local ADDON, SF = ...

local UI = SF.UI
local K = UI.Kit
local Text, Panel, Button, List = K.Text, K.Panel, K.Button, K.List
local Tooltip, HideTooltip, RowHighlight = K.Tooltip, K.HideTooltip, K.RowHighlight

local ORANGE = { 1, 0.6, 0.2 }
local RED = SF.COLOR.DISQUALIFIED
local GREEN = SF.COLOR.CLEAN

local BAR_WIDTH, BAR_SLOTS = 600, 60

local frame
local current -- "Name-Realm" being shown

local function Plural(n, word)
	return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

-- Timeline entries: { t, text, color, tip }
local function InitTimelineRow(row, e)
	if not row.built then
		row.built = true
		row:SetHeight(20)
		RowHighlight(row)
		row.date = Text(row, "GameFontDisableSmall")
		row.date:SetPoint("LEFT", 4, 0)
		row.date:SetWidth(72)
		row.text = Text(row, "GameFontHighlightSmall")
		row.text:SetPoint("LEFT", row.date, "RIGHT", 4, 0)
		row.text:SetPoint("RIGHT", -4, 0)
		row.text:SetWordWrap(false)
		row:SetScript("OnEnter", function(self)
			if self.entry and self.entry.tip then
				Tooltip(self, SF.Date(self.entry.t), self.entry.tip)
			end
		end)
		row:SetScript("OnLeave", HideTooltip)
	end
	row.entry = e
	row.date:SetText(date("%m/%d %H:%M", e.t or 0))
	row.text:SetText(e.text)
	local c = e.color or SF.COLOR.WHITE
	row.text:SetTextColor(c[1], c[2], c[3])
end

-- Other witnesses' replies: { name, reply, hours }
local function InitOtherRow(row, e)
	if not row.built then
		row.built = true
		row:SetHeight(22)
		RowHighlight(row)
		row.name = Text(row, "GameFontHighlight")
		row.name:SetPoint("LEFT", 6, 0)
		row.name:SetWidth(100)
		row.name:SetWordWrap(false)
		row.hours = Text(row, "GameFontHighlightSmall")
		row.hours:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
		row.hours:SetWidth(40)
		row.status = Text(row, "GameFontHighlightSmall")
		row.status:SetPoint("LEFT", row.hours, "RIGHT", 4, 0)
		row.status:SetWidth(80)
		row.flag = Text(row, "GameFontHighlightSmall")
		row.flag:SetPoint("LEFT", row.status, "RIGHT", 4, 0)
		row.flag:SetPoint("RIGHT", -6, 0)
		row.flag:SetWordWrap(false)
		row:SetScript("OnEnter", function(self)
			local d = self.data
			if not d then
				return
			end
			local r = d.reply
			local lines = {
				string.format("Witnessed %dh of %s's play (heard them %d times)", d.hours, SF.ShortName(current), r.n),
				string.format("First %s, last %s", SF.Date(r.first), SF.Ago(r.last)),
				string.format("Last saw: %s, level %d, %s played", SF.StatusText(r.s), r.lvl, SF.Duration(r.pl)),
			}
			if r.sawD or r.maxV > 0 then
				lines[#lines + 1] = { "Saw them disqualified", RED[1], RED[2], RED[3] }
			end
			if r.silentN > 0 then
				lines[#lines + 1] = { string.format("Saw them online without Earned %s (%s total), last %s", Plural(r.silentN, "time"), SF.Duration(r.silentSecs), SF.Ago(r.lastSilent)), ORANGE[1], ORANGE[2], ORANGE[3] }
			end
			lines[#lines + 1] = { "Click to open " .. SF.ShortName(d.name) .. "'s own profile", 0.6, 0.6, 0.6 }
			Tooltip(self, SF.ShortName(d.name) .. "'s records", lines)
		end)
		row:SetScript("OnLeave", HideTooltip)
		row:SetScript("OnClick", function(self)
			if self.data then
				UI.ShowProfile(self.data.name)
			end
		end)
	end
	row.data = e
	local r = e.reply
	local rec = SF.db.witness[e.name]
	local cr, cg, cb = SF.ClassColor(rec and rec.class)
	row.name:SetText(SF.Colorize(SF.ShortName(e.name), { cr, cg, cb }))
	row.hours:SetText(e.hours .. "h")
	row.status:SetText(SF.StatusText(r.s))
	if r.sawD or r.maxV > 0 then
		row.flag:SetText(SF.Colorize("saw DQ", RED))
	elseif r.silentN > 0 then
		row.flag:SetText(SF.Colorize("no addon: " .. SF.Duration(r.silentSecs), ORANGE))
	else
		row.flag:SetText("")
	end
end

-- ---------------------------------------------------------------------------
-- Content
-- ---------------------------------------------------------------------------

local function Timeline(p)
	local entries = {}
	if p.isSelf then
		for i = #SF.cdb.log, 1, -1 do
			local e = SF.cdb.log[i]
			if not e.x then
				local color = (e.k == "violation" and RED) or ((e.k == "gap") and SF.COLOR.UNVERIFIED) or ((e.k == "recover" or e.k == "start") and GREEN) or nil
				entries[#entries + 1] = { t = e.t, text = e.m, color = color, tip = { e.m } }
			end
			if #entries >= 200 then
				break
			end
		end
		return entries
	end
	local rec = p.rec
	if not rec then
		return entries
	end
	local function AddObs(o)
		if type(o) ~= "table" or not o.t then
			return
		end
		local color = (o.s == "D" and RED) or (o.s == "U" and SF.COLOR.UNVERIFIED) or nil
		entries[#entries + 1] = {
			t = o.t,
			text = string.format("Lvl %d  %s  %s  %s", o.lvl or 0, SF.STATUS_WORD[o.s] or "?", Plural(o.d or 0, "death"), SF.Duration(o.pl)),
			color = color,
			tip = {
				string.format("%s, level %d, %s played", SF.StatusText(o.s), o.lvl or 0, SF.Duration(o.pl)),
				string.format("Deaths %d, violations %d, untracked %s", o.d or 0, o.v or 0, SF.Duration(o.g)),
			},
		}
	end
	for _, o in ipairs(rec.history or {}) do
		AddObs(o)
	end
	for _, o in ipairs(rec.ends or {}) do
		AddObs(o)
	end
	AddObs(rec.latest)
	for _, s in ipairs(rec.silent or {}) do
		entries[#entries + 1] = {
			t = s.f,
			text = "Online without Earned for " .. SF.Duration(s.t - s.f),
			color = ORANGE,
			tip = { "They were online in your guild or group, but their addon sent nothing.", "Until " .. SF.Date(s.t) },
		}
	end
	if rec.silentOpen then
		entries[#entries + 1] = { t = rec.silentOpen, text = "Online without Earned (right now)", color = ORANGE }
	end
	table.sort(entries, function(a, b)
		return a.t > b.t
	end)
	return entries
end

local function MineLines(p)
	local lines = {}
	local function Add(text, color)
		lines[#lines + 1] = color and SF.Colorize(text, color) or text
	end
	if p.isSelf then
		local _, reason = SF.GetStatus()
		Add(reason)
		local recovered = SF.RecoveredGaps()
		if SF.OpenGapTotal() > 0 then
			Add("Untracked play time: " .. SF.Duration(SF.OpenGapTotal()), SF.COLOR.UNVERIFIED)
		end
		if recovered > 0 then
			Add(Plural(recovered, "crash") .. " recovered by witnesses", GREEN)
		end
		return table.concat(lines, "\n")
	end
	local m = p.mine
	if not m then
		return "|cff888888You haven't witnessed this player yourself.|r"
	end
	Add(string.format("You witnessed %dh of their play, hearing them %d times since %s.", m.hours, m.n, SF.Date(m.first)))
	Add(string.format("Last heard %s: %s, level %d.", SF.Ago(m.last), SF.StatusText(m.s), m.lvl))
	if m.silentNow then
		Add("Online without Earned running right now.", ORANGE)
	end
	return table.concat(lines, "\n")
end

-- The record strip: verdict, bar, caption.
local function ShowRecord(p)
	local r = p.record
	local flags = #r.flags
	local verdict = SF.Colorize(r.label, r.color)
	if flags > 0 then
		local red = false
		for _, f in ipairs(r.flags) do
			red = red or f.red
		end
		verdict = verdict .. "  " .. SF.Colorize("· " .. Plural(flags, "flag"), red and RED or ORANGE)
	elseif r.contributors > 0 then
		verdict = verdict .. "  " .. SF.Colorize("· no flags", GREEN)
	end
	frame.verdict:SetText(verdict)

	if r.contributors > 0 then
		frame.caption:SetText(string.format("%d of %d played hours witnessed by %s%s", r.covered, r.total,
			Plural(r.contributors, "player"), p.asked and "" or "  |cff888888(your records only; ask witnesses for the full picture)|r"))
	elseif p.asked then
		frame.caption:SetText("|cff888888No witness has reported hours for them yet.|r")
	else
		frame.caption:SetText(string.format("|cff888888Ask witnesses to see how many of %s played hours other players can account for.|r", p.isSelf and "your" or "their"))
	end

	-- Bar: their /played from start to now, filled where witnessed.
	local slots = math.max(1, math.min(BAR_SLOTS, r.total))
	local width = BAR_WIDTH / slots
	for i = 1, BAR_SLOTS do
		local seg = frame.segments[i]
		if i <= slots then
			local from = math.floor((i - 1) * r.total / slots)
			local to = math.max(from, math.floor(i * r.total / slots) - 1)
			local covered = 0
			for _, s in ipairs(r.union) do
				local a, b = math.max(s[1], from), math.min(s[2], to)
				if b >= a then
					covered = covered + (b - a + 1)
				end
			end
			local fraction = covered / (to - from + 1)
			seg:ClearAllPoints()
			seg:SetPoint("TOPLEFT", frame.bar, "TOPLEFT", (i - 1) * width, 0)
			seg:SetSize(math.max(1, width - 1), 12)
			if fraction > 0 then
				seg:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 0.35 + 0.65 * fraction)
			else
				seg:SetColorTexture(1, 1, 1, 0.08)
			end
			seg:Show()
		else
			seg:Hide()
		end
	end
end

local function OthersLines(p)
	local lines = {}
	for i, f in ipairs(p.record.flags) do
		if i > 4 then
			lines[#lines + 1] = string.format("|cff888888+%d more flags|r", #p.record.flags - 4)
			break
		end
		lines[#lines + 1] = SF.Colorize(f.who .. " " .. f.text .. (f.t and f.t > 0 and (", " .. SF.Ago(f.t)) or ""), f.red and RED or ORANGE)
	end
	if not p.asked then
		lines[#lines + 1] = string.format("Press Ask witnesses: everyone in your guild and group who runs %s replies with what their addon recorded of %s.",
			SF.NAME, p.isSelf and "you" or SF.ShortName(p.name))
	else
		lines[#lines + 1] = string.format("|cff888888Asked %s: %s.|r", SF.Ago(p.asked), #p.others == 0 and "no replies yet" or Plural(#p.others, "witness") .. " replied")
	end
	return table.concat(lines, "\n")
end

local function Refresh()
	if not (frame and frame:IsShown() and current and SF.run) then
		return
	end
	local p = SF.Profile(current)
	if not p then
		return
	end

	-- Header: who, and what their own addon claims.
	local classFile = p.isSelf and SF.run.class or (p.rec and p.rec.class)
	local r, g, b = SF.ClassColor(classFile)
	frame.name:SetText(SF.Colorize(SF.ShortName(p.name), { r, g, b }))
	if p.isSelf then
		local status = SF.GetStatus()
		frame.status:SetText(SF.Colorize(status, K.StatusColor(status)))
		frame.sub:SetText(string.format("Level %d  |  %s played  |  this is you", UnitLevel("player") or 0, SF.Duration(SF.PlayedNow())))
	elseif p.rec and p.rec.latest then
		local l = p.rec.latest
		frame.status:SetText(SF.StatusText(l.s) .. "  |cff888888(their addon's report)|r")
		frame.sub:SetText(string.format("Level %d  |  %s played  |  last heard %s  |  %s %s", l.lvl or 0, SF.Duration(l.pl), SF.Ago(p.rec.last), SF.NAME, l.ver or "?"))
	else
		frame.status:SetText("|cff888888No records of this player yet|r")
		frame.sub:SetText(p.name)
	end

	ShowRecord(p)

	frame.mineTitle:SetText(p.isSelf and "Your run" or "What you've seen")
	frame.mineLines:SetText(MineLines(p))
	frame.timeline:SetList(Timeline(p))

	frame.othersTitle:SetText(p.isSelf and "What others recorded of you" or "Other witnesses")
	frame.othersLines:SetText(OthersLines(p))
	frame.othersList:SetList(p.others)
	frame:SetTitle(p.isSelf and "My profile" or ("Profile: " .. SF.ShortName(p.name)))
end
UI.RefreshProfile = Refresh

local function Build()
	frame = K.Dialog("SelfFoundProfileFrame", "Player profile", 640)
	frame:SetWidth(680)

	local header = Panel(frame.Inset)
	header:SetPoint("TOPLEFT", 4, -4)
	header:SetPoint("TOPRIGHT", -4, -4)
	header:SetHeight(72)
	frame.name = Text(header, "GameFontNormalHuge")
	frame.name:SetPoint("TOPLEFT", 16, -12)
	frame.status = Text(header, "GameFontNormal")
	frame.status:SetPoint("BOTTOMLEFT", frame.name, "BOTTOMRIGHT", 14, 3)
	frame.status:SetPoint("RIGHT", header, "RIGHT", -170, 0)
	frame.status:SetWordWrap(false)
	frame.sub = Text(header, "GameFontHighlightSmall")
	frame.sub:SetPoint("TOPLEFT", frame.name, "BOTTOMLEFT", 0, -8)
	frame.sub:SetPoint("RIGHT", header, "RIGHT", -170, 0)
	frame.sub:SetWordWrap(false)
	frame.ask = Button(header, "Ask witnesses", 140, function()
		if current and not SF.AskWitnesses(current) then
			SF.Print("You just asked - give witnesses a moment to reply.")
		end
	end)
	frame.ask:SetPoint("RIGHT", -14, 0)
	frame.ask:SetScript("OnEnter", function(self)
		Tooltip(self, "Ask witnesses", {
			"Asks everyone in your guild and group who runs " .. SF.NAME .. " what their addons recorded of this player.",
			{ "A player can fake their own addon, but not what other people's addons recorded.", 0.7, 0.7, 0.7 },
		})
	end)
	frame.ask:SetScript("OnLeave", HideTooltip)

	-- Witness Record strip
	local record = Panel(frame.Inset, "Witness record")
	record:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
	record:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
	record:SetHeight(92)
	frame.verdict = Text(record, "GameFontNormalLarge")
	frame.verdict:SetPoint("TOPLEFT", 16, -36)
	frame.bar = CreateFrame("Frame", nil, record)
	frame.bar:SetSize(BAR_WIDTH, 12)
	frame.bar:SetPoint("TOPLEFT", frame.verdict, "BOTTOMLEFT", 0, -8)
	frame.segments = {}
	for i = 1, BAR_SLOTS do
		frame.segments[i] = frame.bar:CreateTexture(nil, "ARTWORK")
	end
	frame.bar:EnableMouse(true)
	frame.bar:SetScript("OnEnter", function(self)
		Tooltip(self, "Witnessed hours", {
			"Their play time from the first hour to now. Filled parts are hours in which at least one other player's addon heard theirs running.",
			{ "Well witnessed: 75%+ of hours, from 3+ witnesses. Partly: 25%+. Flags are shown separately and never subtracted.", 0.7, 0.7, 0.7 },
		})
	end)
	frame.bar:SetScript("OnLeave", HideTooltip)
	frame.caption = Text(record, "GameFontHighlightSmall")
	frame.caption:SetPoint("TOPLEFT", frame.bar, "BOTTOMLEFT", 0, -6)
	frame.caption:SetPoint("RIGHT", record, "RIGHT", -14, 0)
	frame.caption:SetWordWrap(false)

	local mine = Panel(frame.Inset, "What you've seen")
	mine:SetPoint("TOPLEFT", record, "BOTTOMLEFT", 0, -6)
	mine:SetPoint("BOTTOMLEFT", 4, 4)
	mine:SetWidth(330)
	frame.mineTitle = mine.title
	frame.mineLines = Text(mine, "GameFontHighlightSmall")
	frame.mineLines:SetPoint("TOPLEFT", 14, -36)
	frame.mineLines:SetPoint("RIGHT", mine, "RIGHT", -14, 0)
	frame.mineLines:SetJustifyV("TOP")
	frame.mineLines:SetWordWrap(true)
	frame.mineLines:SetSpacing(3)
	local timelineTitle = Text(mine, "GameFontNormalSmall")
	timelineTitle:SetPoint("TOPLEFT", 14, -104)
	timelineTitle:SetText("Timeline")
	frame.timeline = List(mine, 20, InitTimelineRow)
	frame.timeline:ClearAllPoints()
	frame.timeline:SetPoint("TOPLEFT", 8, -120)
	frame.timeline:SetPoint("BOTTOMRIGHT", -24, 8)

	local others = Panel(frame.Inset, "Other witnesses")
	others:SetPoint("TOPLEFT", mine, "TOPRIGHT", 6, 0)
	others:SetPoint("BOTTOMRIGHT", -4, 4)
	frame.othersTitle = others.title
	frame.othersLines = Text(others, "GameFontHighlightSmall")
	frame.othersLines:SetPoint("TOPLEFT", 14, -36)
	frame.othersLines:SetPoint("RIGHT", others, "RIGHT", -14, 0)
	frame.othersLines:SetJustifyV("TOP")
	frame.othersLines:SetWordWrap(true)
	frame.othersLines:SetSpacing(3)
	frame.othersList = List(others, 22, InitOtherRow)
	frame.othersList:ClearAllPoints()
	frame.othersList:SetPoint("TOPLEFT", 8, -120)
	frame.othersList:SetPoint("BOTTOMRIGHT", -24, 8)

	frame:SetScript("OnShow", Refresh)
end

-- Opens the profile of `name` ("Name-Realm", or a short name you know).
-- `ask` = also ask other witnesses right away.
function UI.ShowProfile(name, ask)
	if not SF.run then
		return
	end
	name = SF.ResolveName(name) or SF.FullName(name)
	if not name then
		return
	end
	if not frame then
		Build()
	end
	current = name
	frame:Show()
	if ask then
		SF.AskWitnesses(name)
	end
	Refresh()
end

SF.Listen("ProfileChanged", function(name)
	if name == current then
		Refresh()
	end
end)
SF.Listen("WitnessChanged", Refresh)
SF.Listen("StatusChanged", Refresh)
