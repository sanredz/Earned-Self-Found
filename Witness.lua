-- Self Found - Witnesses and reports
-- Players running Self Found in the same guild/group periodically exchange
-- short heartbeats (status, level, played time, deaths...). Each side keeps
-- what it saw of the other in its own saved data. A player can forge their
-- own file, but not the records sitting on other people's computers - so a
-- report can be checked against your witness records of that character.

local ADDON, SF = ...

local HISTORY_MAX = 40
local BROADCAST_INTERVAL = 300
local ACK_INTERVAL = 600
local STATUS_WORD = { C = "CLEAN", U = "UNVERIFIED", D = "DISQUALIFIED" }
SF.STATUS_WORD = STATUS_WORD

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

local function Split(text, sep)
	local parts = {}
	for part in (text .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do
		parts[#parts + 1] = part
	end
	return parts
end

-- Status, level, played, deaths, violations, untracked seconds, late start,
-- log head, class, quests.
local function HeartbeatBody()
	local run = SF.run
	local _, _, code = SF.GetStatus()
	return table.concat({
		code,
		UnitLevel("player") or 0,
		math.floor(SF.PlayedNow()),
		run.stats.deaths,
		#run.violations,
		SF.GapTotal(),
		run.lateStart and 1 or 0,
		SF.LogHead():sub(1, 8),
		run.class or "",
		run.stats.quests,
	}, "|")
end

local function ParseBody(parts, offset)
	local n = function(i)
		return tonumber(parts[offset + i]) or 0
	end
	local s = parts[offset + 1]
	if not STATUS_WORD[s] then
		return nil
	end
	return {
		s = s,
		lvl = n(2),
		pl = n(3),
		d = n(4),
		v = n(5),
		g = n(6),
		late = n(7),
		head = parts[offset + 8] or "",
		class = parts[offset + 9] or "",
		q = n(10),
	}
end

local function CanSend()
	if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
		return false
	end
	if C_ChatInfo.InChatMessagingLockdown and SF.Safe(SF.Try(C_ChatInfo.InChatMessagingLockdown)) then
		return false
	end
	return true
end

local function Send(message, channel, target)
	if CanSend() then
		pcall(C_ChatInfo.SendAddonMessage, SF.PREFIX, message, channel, target)
	end
end

local lastBroadcast = -math.huge

function SF.Broadcast(force)
	if not SF.run or not SF.settings or not SF.settings.broadcast then
		return
	end
	local now = GetTime()
	if not force and now - lastBroadcast < 60 then
		return
	end
	lastBroadcast = now
	local message = "H1|" .. HeartbeatBody()
	if IsInGuild and IsInGuild() then
		Send(message, "GUILD")
	end
	local home = LE_PARTY_CATEGORY_HOME
	if IsInRaid and IsInRaid(home) then
		Send(message, "RAID")
	elseif IsInGroup and IsInGroup(home) then
		Send(message, "PARTY")
	end
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

local ackedAt = {}

local function Record(sender, obs)
	local witness = SF.db.witness
	local rec = witness[sender]
	if type(rec) ~= "table" then
		rec = { first = time(), n = 0, history = {} }
		witness[sender] = rec
	end
	rec.n = (rec.n or 0) + 1
	rec.last = time()
	rec.class = obs.class ~= "" and obs.class or rec.class
	obs.t = time()
	obs.class = nil

	-- Keep a history point whenever something meaningful changed, so a
	-- report can be checked against how the run looked at the time.
	local prev = rec.latest
	local changed = not prev or prev.s ~= obs.s or prev.lvl ~= obs.lvl or prev.d ~= obs.d
		or prev.v ~= obs.v or prev.g ~= obs.g or (obs.pl - (prev.pl or 0)) >= 1800
	if changed then
		table.insert(rec.history, obs)
		while #rec.history > HISTORY_MAX do
			table.remove(rec.history, 1)
		end
	end
	rec.latest = obs
	SF.Fire("WitnessChanged")
end

SF.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
	prefix, text, sender = SF.Safe(prefix), SF.Safe(text), SF.Safe(sender)
	if prefix ~= SF.PREFIX or type(text) ~= "string" or type(sender) ~= "string" or not SF.run then
		return
	end
	sender = SF.FullName(sender)
	if not sender or sender == SF.playerKey then
		return
	end
	local parts = Split(text, "|")
	local kind = parts[1]
	if kind ~= "H1" and kind ~= "A1" then
		return
	end
	local obs = ParseBody(parts, 1)
	if obs then
		Record(sender, obs)
	end

	if kind == "A1" then
		-- They recorded our heartbeat: they're now a witness of this run.
		local entry = SF.run.witnessedBy[sender] or { n = 0, first = time() }
		entry.n = entry.n + 1
		entry.last = time()
		SF.run.witnessedBy[sender] = entry
		SF.Changed()
		SF.Fire("WitnessChanged")
	elseif SF.settings.broadcast and (not ackedAt[sender] or time() - ackedAt[sender] > ACK_INTERVAL) then
		-- Acknowledge with our own heartbeat, so both sides witness each other.
		ackedAt[sender] = time()
		Send("A1|" .. HeartbeatBody(), "WHISPER", sender)
	end
end)

SF.Listen("Ready", function()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		pcall(C_ChatInfo.RegisterAddonMessagePrefix, SF.PREFIX)
	end
	SF.After(15, function()
		SF.Broadcast(true)
	end)
	if C_Timer and C_Timer.NewTicker then
		C_Timer.NewTicker(BROADCAST_INTERVAL, function()
			SF.SafeCall(SF.Broadcast, true)
		end)
	end
end)

SF.On("GROUP_ROSTER_UPDATE", function()
	SF.After(5, SF.Broadcast)
end)

SF.Listen("Milestone", function()
	SF.Broadcast(true)
end)

SF.Listen("Violation", function()
	SF.After(1, function()
		SF.Broadcast(true)
	end)
end)

-- ---------------------------------------------------------------------------
-- Tooltip: show the witnessed status of other players (and your own)
-- ---------------------------------------------------------------------------

function SF.StatusText(code)
	local word = STATUS_WORD[code] or code
	return SF.Colorize(word, SF.COLOR[word] or SF.COLOR.GRAY)
end

local function AddTooltipLine(tooltip)
	if tooltip ~= GameTooltip or not SF.settings or not SF.settings.tooltips or not SF.run then
		return
	end
	local _, unit = tooltip:GetUnit()
	unit = SF.Safe(unit)
	if not unit or not SF.Safe(UnitIsPlayer(unit)) then
		return
	end
	local line
	if SF.Safe(UnitIsUnit(unit, "player")) then
		local _, _, code = SF.GetStatus()
		line = "Self Found: " .. SF.StatusText(code)
	else
		local name, realm = UnitName(unit)
		name, realm = SF.Safe(name), SF.Safe(realm)
		if not name then
			return
		end
		local key = name .. "-" .. ((realm and realm ~= "") and realm or SF.RealmName())
		local rec = SF.db.witness[key]
		if rec and rec.latest then
			line = string.format("Self Found: %s  |cffaaaaaalevel %d, seen %s|r", SF.StatusText(rec.latest.s), rec.latest.lvl or 0, SF.Ago(rec.last))
		end
	end
	if line then
		tooltip:AddLine(line)
		tooltip:Show()
	end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
		SF.SafeCall(AddTooltipLine, tooltip)
	end)
end

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------

local function Copy(tbl)
	local out = {}
	for k, v in pairs(tbl or {}) do
		out[k] = type(v) == "table" and Copy(v) or v
	end
	return out
end

function SF.WitnessList()
	local list = {}
	for name, entry in pairs(SF.run.witnessedBy) do
		list[#list + 1] = { name = name, n = entry.n or 0, first = entry.first, last = entry.last }
	end
	table.sort(list, function(a, b)
		return a.n > b.n
	end)
	return list
end

function SF.BuildReport()
	local run = SF.run
	local status, reason = SF.GetStatus()
	local witnesses = {}
	for i, w in ipairs(SF.WitnessList()) do
		if i > 25 then
			break
		end
		witnesses[#witnesses + 1] = { name = w.name, n = w.n, last = w.last }
	end
	return {
		format = "SelfFound",
		v = 1,
		addon = SF.VERSION,
		generated = time(),
		char = run.char,
		class = run.class,
		race = run.race,
		level = UnitLevel("player") or 0,
		status = status,
		reason = reason,
		played = math.floor(SF.PlayedNow()),
		created = run.created,
		startLevel = run.startLevel,
		startPlayed = run.startPlayed,
		late = run.lateStart and 1 or 0,
		stats = Copy(run.stats),
		income = Copy(run.income),
		spent = Copy(run.spent),
		items = Copy(run.items),
		worth = SF.WorthTotal(),
		peak = run.worth.peak or 0,
		violations = Copy(run.violations),
		gaps = Copy(run.gaps),
		gapTotal = SF.GapTotal(),
		logCount = SF.LogCount(),
		logHead = SF.LogHead(),
		integrity = SF.integrity.ok and 1 or 0,
		witnesses = witnesses,
	}
end

local function Sum(tbl)
	local total = 0
	for _, v in pairs(tbl or {}) do
		total = total + (tonumber(v) or 0)
	end
	return total
end

-- A readable summary to paste anywhere, followed by the verification code.
function SF.ReportSummary(report)
	local lines = {
		string.format("%s report: %s", SF.TITLE, report.char or "?"),
		string.format("Status: %s", report.status or "?"),
		string.format("Level %d %s %s, %s played", report.level or 0, report.race or "", report.class or "", SF.Duration(report.played)),
		string.format("Deaths %d, kills %d, quests %d", report.stats.deaths or 0, report.stats.kills or 0, report.stats.quests or 0),
		string.format("Gold earned %s, net worth %s (peak %s)", SF.PlainMoney(Sum(report.income)), SF.PlainMoney(report.worth), SF.PlainMoney(report.peak)),
		string.format("Trades %d, auctions %d, player mail %d", report.stats.trades or 0,
			(report.stats.ahBids or 0) + (report.stats.ahBuyouts or 0) + (report.stats.ahListed or 0), report.stats.mailFromPlayers or 0),
	}
	if #report.violations > 0 then
		lines[#lines + 1] = "Violations:"
		for _, v in ipairs(report.violations) do
			lines[#lines + 1] = string.format("  %s  %s", SF.Date(v.t), v.m)
		end
	end
	if (report.gapTotal or 0) > 0 then
		lines[#lines + 1] = string.format("Untracked play time: %s", SF.Duration(report.gapTotal))
	end
	local names = {}
	for i, w in ipairs(report.witnesses or {}) do
		if i > 8 then
			break
		end
		names[#names + 1] = w.name
	end
	lines[#lines + 1] = string.format("Witnessed by %d player(s)%s", #(report.witnesses or {}), #names > 0 and (": " .. table.concat(names, ", ")) or "")
	lines[#lines + 1] = string.format("Generated %s with " .. SF.NAME .. " %s", SF.Date(report.generated), report.addon or "?")
	return table.concat(lines, "\n")
end

-- Money without texture codes, for plain-text reports.
function SF.PlainMoney(copper)
	copper = math.floor(math.abs(tonumber(copper) or 0))
	return string.format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local function Encoding()
	local E = C_EncodingUtil
	if E and E.SerializeJSON and E.DeserializeJSON and E.CompressString and E.DecompressString and E.EncodeBase64 and E.DecodeBase64 then
		return E
	end
end

-- Returns the full export text: summary + verification code.
function SF.ExportReport()
	local report = SF.BuildReport()
	local summary = SF.ReportSummary(report)
	local E = Encoding()
	if not E then
		return summary .. "\n\n(This client can't produce a verification code.)"
	end
	local json = SF.Try(E.SerializeJSON, report)
	local compressed = json and SF.Try(E.CompressString, json)
	local encoded = compressed and SF.Try(E.EncodeBase64, compressed)
	if not encoded then
		return summary .. "\n\n(Couldn't produce a verification code.)"
	end
	local wrapped = {}
	for i = 1, #encoded, 64 do
		wrapped[#wrapped + 1] = encoded:sub(i, i + 63)
	end
	return summary .. "\n\nSF1:" .. SF.Hash(json) .. ":\n" .. table.concat(wrapped, "\n")
end

-- Parses pasted text. Returns the report table, or nil and an error.
function SF.DecodeReport(text)
	local E = Encoding()
	if not E then
		return nil, "This client can't read verification codes."
	end
	local checksum, payload = tostring(text):match("SF1:(%x+):(.*)$")
	if not checksum then
		return nil, "No " .. SF.NAME .. " verification code (starting with SF1:) was found in the text."
	end
	payload = payload:gsub("[^%w%+/=]", "")
	local compressed = SF.Try(E.DecodeBase64, payload)
	local json = compressed and SF.Try(E.DecompressString, compressed)
	if type(json) ~= "string" then
		return nil, "The verification code is damaged or incomplete (make sure you copied all of it)."
	end
	if SF.Hash(json) ~= checksum then
		return nil, "The verification code doesn't match its checksum - the report was altered."
	end
	local report = SF.Try(E.DeserializeJSON, json)
	if type(report) ~= "table" or report.format ~= "SelfFound" then
		return nil, "This doesn't look like an " .. SF.NAME .. " report."
	end
	report.stats = report.stats or {}
	report.violations = report.violations or {}
	report.gaps = report.gaps or {}
	report.witnesses = report.witnesses or {}
	return report
end

-- Cross-checks a report against what you personally witnessed of that
-- character. Returns lists of contradictions and informational notes.
function SF.VerifyReport(report)
	local contradictions, notes = {}, {}
	local rec = SF.db.witness[report.char or ""]
	if report.integrity == 0 then
		contradictions[#contradictions + 1] = "The addon itself detected that their saved data was edited outside the game."
	end
	if not rec or not rec.history or #rec.history == 0 then
		notes[#notes + 1] = "You have no witness records of this character, so only the checksum could be checked. Ask one of their witnesses to verify it."
		return contradictions, notes
	end

	local considered, newer = 0, 0
	local reportPlayed = (report.played or 0) + 120
	local reportDeaths = report.stats.deaths or 0
	for _, obs in ipairs(rec.history) do
		if (obs.pl or 0) <= reportPlayed then
			considered = considered + 1
			local when = string.format("at %s played (%s)", SF.Duration(obs.pl), SF.Date(obs.t))
			if obs.s == "D" and report.status ~= "DISQUALIFIED" then
				contradictions[#contradictions + 1] = "You saw them DISQUALIFIED " .. when .. ", but the report says " .. tostring(report.status) .. "."
			end
			if (obs.v or 0) > #report.violations then
				contradictions[#contradictions + 1] = string.format("You saw %d violation(s) %s, the report lists %d.", obs.v, when, #report.violations)
			end
			if (obs.d or 0) > reportDeaths then
				contradictions[#contradictions + 1] = string.format("You saw %d death(s) %s, the report lists %d.", obs.d, when, reportDeaths)
			end
			if (obs.lvl or 0) > (report.level or 0) then
				contradictions[#contradictions + 1] = string.format("You saw them at level %d %s, the report says level %d.", obs.lvl, when, report.level or 0)
			end
			if (obs.g or 0) > (report.gapTotal or 0) + 60 then
				contradictions[#contradictions + 1] = string.format("You saw %s of untracked time %s, the report lists %s.", SF.Duration(obs.g), when, SF.Duration(report.gapTotal))
			end
		else
			newer = newer + 1
		end
	end

	if considered > 0 then
		notes[#notes + 1] = string.format("Checked against %d observation(s) you recorded between %s and %s.", considered, SF.Date(rec.first), SF.Date(rec.last))
	end
	if newer > 0 then
		notes[#notes + 1] = string.format("You have %d observation(s) newer than this report; ask them for an up-to-date one.", newer)
	end
	return contradictions, notes
end
