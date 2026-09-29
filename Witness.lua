-- Self Found - Witnesses and reports
-- Players running Self Found in the same guild/group periodically exchange
-- short heartbeats (status, level, played time, deaths...). Each side keeps
-- what it saw of the other in its own saved data. A player can forge their
-- own file, but not the records sitting on other people's computers - so a
-- report can be checked against your witness records of that character.

local ADDON, SF = ...

local HISTORY_MAX = 40
local BROADCAST_INTERVAL = 60 -- often enough that a witness saw us right before a crash
local ACK_INTERVAL = 600
local RECALL_INTERVAL = 120   -- how often to ask witnesses to recover a gap
local REPLY_INTERVAL = 300    -- per requester and gap
local SESSION_SILENCE = 180   -- fallback session boundary for senders without a session id
local ENDS_MAX = 30           -- last heartbeat of each of a player's recent sessions...
local ENDS_MAX_AGE = 8 * 86400 -- ...kept long enough to answer recalls for a week
local STATUS_WORD = { C = "CLEAN", U = "UNVERIFIED", D = "DISQUALIFIED" }
local ownNames = {} -- other spellings the server used for us this session
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
-- log head, class, quests, session id, addon version, token. Fields may only
-- ever be appended: older versions ignore extra ones.
local function HeartbeatBody()
	local run = SF.run
	local _, _, code = SF.GetStatus(true)
	local played = math.floor(SF.PlayedNow())
	return table.concat({
		code,
		UnitLevel("player") or 0,
		played,
		run.stats.deaths,
		#run.violations,
		SF.GapTotal(),
		run.lateStart and 1 or 0,
		SF.LogHead():sub(1, 8),
		run.class or "",
		run.stats.quests,
		SF.sessionId or 0,
		SF.VERSION,
		SF.Token(played, code, #run.violations),
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
		sid = tonumber(parts[offset + 11]),
		ver = parts[offset + 12],
		tk = parts[offset + 13],
	}
end

local function CanSend()
	if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
		return false
	end
	return not SF.InMessagingLockdown()
end

local function Send(message, channel, target)
	if CanSend() then
		if channel == "WHISPER" then
			target = SF.WhisperTarget(target)
		end
		pcall(C_ChatInfo.SendAddonMessage, SF.PREFIX, message, channel, target)
	end
end
SF.Send = Send

-- True while this client may not send addon messages (e.g. restricted
-- encounters), so silence from others can't be judged either.
function SF.InMessagingLockdown()
	return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and SF.Safe(SF.Try(C_ChatInfo.InChatMessagingLockdown)) == true
end

-- Guild, plus raid or party if grouped.
local function SendToWitnesses(message)
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

SF.SendToWitnesses = SendToWitnesses

local lastBroadcast, lastRecall = -math.huge, -math.huge

-- Asks witnesses what they last saw of us inside untracked gaps
-- ("R1|from|to"); a witness who saw the addon running until just before
-- the gap's end answers with "C1", recovering it.
local function SendRecalls()
	local now = GetTime()
	if now - lastRecall < RECALL_INTERVAL then
		return
	end
	local pending = SF.PendingGaps()
	if #pending == 0 then
		return
	end
	lastRecall = now
	for i = 1, math.min(3, #pending) do
		SendToWitnesses(string.format("R1|%.0f|%.0f", pending[i].from, pending[i].to))
	end
end

function SF.Broadcast(force)
	if not SF.run then
		return
	end
	local now = GetTime()
	if not force and now - lastBroadcast < 60 then
		return
	end
	lastBroadcast = now
	SendToWitnesses("H1|" .. HeartbeatBody())
	SendRecalls()
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

local ackedAt = {}

-- Stored copies of older heartbeats keep only what the timeline, Verify
-- and crash recovery use (saved-data size: records are kept for good).
local function Slim(obs)
	return { s = obs.s, lvl = obs.lvl, pl = obs.pl, d = obs.d, v = obs.v, g = obs.g, t = obs.t, tk = obs.tk }
end

local function Record(sender, obs, viaShared)
	local witness = SF.db.witness
	local rec = witness[sender]
	if type(rec) ~= "table" then
		rec = { first = time(), n = 0, history = {} }
		witness[sender] = rec
	end
	rec.n = (rec.n or 0) + 1
	rec.last = time()
	if viaShared then
		rec.shared = time() -- seen in our guild or group: trusted to whisper us
	end
	rec.class = obs.class ~= "" and obs.class or rec.class
	obs.t = time()
	obs.class = nil

	-- Remember the last heartbeat of each session: if their game crashed,
	-- that's the proof their addon was running until (almost) the end.
	local prev = rec.latest
	if prev then
		local newSession
		if obs.sid and prev.sid then
			newSession = obs.sid ~= prev.sid
		else
			newSession = obs.t - (prev.t or 0) > SESSION_SILENCE
		end
		if newSession then
			rec.ends = rec.ends or {}
			table.insert(rec.ends, Slim(prev))
			-- Every /reload or relog is a session, so keep them by age (the
			-- recall window is 7 days), with a hard cap for saved-data size.
			while #rec.ends > 0 and obs.t - (rec.ends[1].t or 0) > ENDS_MAX_AGE do
				table.remove(rec.ends, 1)
			end
			while #rec.ends > ENDS_MAX do
				table.remove(rec.ends, 1)
			end
		end
	end

	-- Keep a history point whenever something meaningful changed, so a
	-- report can be checked against how the run looked at the time.
	local changed = not prev or prev.s ~= obs.s or prev.lvl ~= obs.lvl or prev.d ~= obs.d
		or prev.v ~= obs.v or prev.g ~= obs.g or (obs.pl - (prev.pl or 0)) >= 1800
	if changed then
		table.insert(rec.history, Slim(obs))
		while #rec.history > HISTORY_MAX do
			table.remove(rec.history, 1)
		end
	end
	rec.latest = obs
	SF.Fire("HeardFrom", sender, rec, prev)
	SF.Fire("WitnessChanged")
end

-- Extra message kinds (other modules): SF.MessageHandlers[kind] =
-- function(sender, parts, channel, known, shared). Each handler must enforce
-- its own channel/known-sender rules (see the anti-griefing note below).
SF.MessageHandlers = {}

-- Someone asks what we last saw of them inside their gap (from, to]. Answer
-- with the latest heartbeat we have in that range, if any.
local repliedAt = {}
local replyBudget, budgetAt = 0, 0
local REPLIES_PER_MINUTE = 20 -- so nobody can make us spam whispers

local function AnswerRecall(sender, from, to)
	local rec = SF.db.witness[sender]
	if not (from and to and type(rec) == "table") then
		return
	end
	local key = sender .. ":" .. from
	if repliedAt[key] and time() - repliedAt[key] < REPLY_INTERVAL then
		return
	end
	if time() - budgetAt >= 60 then
		replyBudget, budgetAt = 0, time()
	end
	if replyBudget >= REPLIES_PER_MINUTE then
		return
	end
	local best
	local function Consider(obs)
		-- Only heartbeats with a token can prove anything to the requester.
		if type(obs) == "table" and obs.tk and obs.pl and obs.pl > from and obs.pl <= to + 5 and (not best or obs.pl > best.pl) then
			best = obs
		end
	end
	Consider(rec.latest)
	for _, obs in ipairs(rec.ends or {}) do
		Consider(obs)
	end
	for _, obs in ipairs(rec.history or {}) do
		Consider(obs)
	end
	if best then
		repliedAt[key] = time()
		replyBudget = replyBudget + 1
		Send(string.format("C1|%.0f|%.0f|%s|%d|%d|%.0f|%s", from, best.pl, best.s, best.v or 0, best.d or 0, best.t or 0, best.tk), "WHISPER", sender)
	end
end

SF.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
	prefix, text, sender = SF.Safe(prefix), SF.Safe(text), SF.Safe(sender)
	if prefix ~= SF.PREFIX or type(text) ~= "string" or type(sender) ~= "string" or not SF.run then
		return
	end
	sender = SF.FullName(sender)
	if not sender or sender == SF.playerKey or ownNames[sender] then
		return
	end
	channel = SF.Safe(channel)
	local shared = channel == "GUILD" or channel == "PARTY" or channel == "RAID"
	local parts = Split(text, "|")
	local kind = parts[1]

	-- Our own heartbeat echoed back under a name we didn't expect (the
	-- server spelling our name differently): only we can make our token.
	if kind == "H1" or kind == "A1" then
		local obs = ParseBody(parts, 1)
		if obs and obs.tk and obs.sid == SF.sessionId and obs.tk == SF.Token(obs.pl, obs.s, obs.v) then
			ownNames[sender] = true
			SF.ForgetSelf(sender)
			return
		end
	end

	-- Anti-griefing: the server guarantees who sent a message, and everyone
	-- can only speak about themselves - except C1, a witness's sighting of
	-- us. Each kind is only accepted on the channel it's really sent on, and
	-- whispers only from players we know from our guild/group (they've sent
	-- a heartbeat there). A stranger whispering fake messages is ignored.
	local rec = SF.db.witness[sender]
	local known = type(rec) == "table" and rec.shared ~= nil

	if kind == "R1" then
		if shared then
			AnswerRecall(sender, tonumber(parts[2]), tonumber(parts[3]))
		end
		return
	elseif kind == "C1" then
		if channel == "WHISPER" and known then
			SF.GapSighting(parts[2], parts[3], parts[4], parts[5], sender, parts[8])
		end
		return
	elseif kind == "H1" then
		if not shared then
			return
		end
	elseif kind == "A1" then
		if channel ~= "WHISPER" or not known then
			return
		end
	else
		local handler = SF.MessageHandlers[kind]
		if handler then
			handler(sender, parts, channel, known, shared)
		end
		return
	end

	local obs = ParseBody(parts, 1)
	if not obs then
		return
	end
	Record(sender, obs, kind == "H1")

	if kind == "A1" then
		-- They recorded our heartbeat: they're now a witness of this run.
		local entry = SF.run.witnessedBy[sender] or { n = 0, first = time() }
		entry.n = entry.n + 1
		entry.last = time()
		SF.run.witnessedBy[sender] = entry
		SF.Changed()
		SF.Fire("WitnessChanged")
	elseif not ackedAt[sender] or time() - ackedAt[sender] > ACK_INTERVAL then
		-- Acknowledge with our own heartbeat, so both sides witness each other.
		ackedAt[sender] = time()
		Send("A1|" .. HeartbeatBody(), "WHISPER", sender)
	end
end)

-- Removes records of ourselves under `name`: our own echoed heartbeats
-- recorded as a witness, acks from ourselves, and flags we raised on
-- ourselves. (Flags others raised about us are kept.)
function SF.ForgetSelf(name)
	local changed = SF.db.witness[name] ~= nil or (SF.run.witnessedBy or {})[name] ~= nil
	SF.db.witness[name] = nil
	if SF.run.witnessedBy then
		SF.run.witnessedBy[name] = nil
	end
	for _, target in ipairs({ name, SF.playerKey }) do
		for id, f in pairs(SF.db.flags and SF.db.flags[target] or {}) do
			if f.by == name or f.by == SF.playerKey then
				SF.db.flags[target][id] = nil
				changed = true
			end
		end
	end
	if changed then
		SF.Changed()
		SF.Fire("WitnessChanged")
	end
end

-- Before 1.0 our key left out the Forever surname ("Name-Realm"): flags we
-- raised under it are moved to our real name, and anything about that old
-- name is about us.
local function MigrateOldKey()
	local first = SF.Safe(SF.Try(UnitName, "player"))
	local old = SF.FullName(first)
	if not old or old == SF.playerKey then
		return
	end
	local flags = SF.db.flags or {}
	for target, list in pairs(flags) do
		local moved = {}
		for id, f in pairs(list) do
			if type(f) == "table" and f.by == old then
				list[id] = nil
				if target ~= old and target ~= SF.playerKey then
					f.by = SF.playerKey
					moved[#moved + 1] = f
				end
			end
		end
		for _, f in ipairs(moved) do
			list[f.by .. "|" .. f.k .. "|" .. math.floor(f.t) .. "|" .. (f.v or 0)] = f
		end
	end
	if flags[old] then
		flags[SF.playerKey] = flags[SF.playerKey] or {}
		for id, f in pairs(flags[old]) do
			flags[SF.playerKey][id] = f
		end
		flags[old] = nil
	end
	SF.ForgetSelf(old)
end

SF.Listen("Ready", function()
	-- Our own heartbeats could come back as someone else's before 1.0.
	MigrateOldKey()
	SF.ForgetSelf(SF.playerKey)
	SF.sessionId = time()
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

-- Immediately, so witnesses know even if the game is closed right after.
SF.Listen("Violation", function()
	SF.Broadcast(true)
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
	-- One fact per line:
	--   Self Found: CLEAN   level 12, seen 5m ago     (their addon's claim)
	--   You witnessed 12h of their play               (your own records)
	--   (!) Flagged by 2 players: Carl, Dana          (shared witness flags)
	local status, detail, otherRec, key
	if SF.Safe(UnitIsUnit(unit, "player")) then
		status = select(3, SF.GetStatus())
		key = SF.playerKey
	else
		key = SF.UnitKey(unit)
		if not key then
			return
		end
		local rec = SF.db.witness[key]
		if rec and rec.latest then
			local l = rec.latest
			otherRec = rec
			status = l.s
			detail = string.format("|cffaaaaaalevel %d, seen %s|r", l.lvl or 0, SF.Ago(rec.last))
		elseif not SF.FlagLine(key) then
			return -- never heard of them, and nobody flagged them
		end
	end

	-- Their status as their own addon reports it; flags below come from
	-- other witnesses and are shown even if their addon never spoke to us
	-- (a cheater who switched broadcasting off entirely).
	if status then
		tooltip:AddLine("Self Found: " .. SF.StatusText(status) .. (detail and ("  " .. detail) or ""))
	else
		tooltip:AddLine("Self Found: |cff888888no status from their addon|r")
	end
	-- What *you* saw of them.
	local summary = otherRec and SF.WitnessSummary and SF.WitnessSummary(otherRec)
	if summary and summary.hours > 0 then
		tooltip:AddLine(string.format("You witnessed %dh of their play", summary.hours), 0.75, 0.75, 0.75)
	end
	if summary and summary.silentNow then
		tooltip:AddLine("Online without Earned running right now", 1, 0.6, 0.2)
	end
	-- Flags witnesses shared (about yourself: shown even if only one).
	local flagText, flagColor = SF.FlagLine(key, status, key == SF.playerKey)
	if flagText then
		tooltip:AddLine(flagText, flagColor[1], flagColor[2], flagColor[3])
	end
	tooltip:Show()
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
	local status, reason = SF.GetStatus(true)
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
		gapOpen = SF.OpenGapTotal(),
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
		string.format("%s - shared run of %s", SF.TITLE, report.char or "?"),
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
		local open = report.gapOpen or report.gapTotal
		lines[#lines + 1] = string.format("Untracked play time: %s", SF.Duration(open))
	end
	for _, g in ipairs(report.gaps or {}) do
		local support = SF.GapWitnesses(g, #report.violations)
		if g.cov then
			lines[#lines + 1] = string.format("  Crash on %s: %s recovered, confirmed by %d witness%s (%s)", SF.Date(g.t), SF.Duration(g.s),
				#support, #support == 1 and "" or "es", table.concat(support, ", "))
		end
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
		return nil, "The verification code doesn't match its checksum - the shared run was altered."
	end
	local report = SF.Try(E.DeserializeJSON, json)
	if type(report) ~= "table" or report.format ~= "SelfFound" then
		return nil, "This doesn't look like an " .. SF.NAME .. " shared run."
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

	-- Crash recoveries, with the witnesses who confirmed them.
	for _, g in ipairs(report.gaps or {}) do
		local support = SF.GapWitnesses(g, #report.violations)
		if g.cov then
			notes[#notes + 1] = string.format("Crash on %s (%s) recovered, confirmed by %d witness%s: %s.", SF.Date(g.t), SF.Duration(g.s),
				#support, #support == 1 and "" or "es", table.concat(support, ", "))
		end
		local mine = g.seen and g.seen[SF.playerKey]
		if mine then
			local confirmed = false
			local function Match(obs)
				if type(obs) == "table" and obs.pl == mine.pl and obs.s == mine.s then
					confirmed = true
				end
			end
			if rec then
				Match(rec.latest)
				for _, obs in ipairs(rec.ends or {}) do
					Match(obs)
				end
				for _, obs in ipairs(rec.history or {}) do
					Match(obs)
				end
			end
			notes[#notes + 1] = confirmed and "Your own records confirm the crash sighting their shared run lists from you."
				or "Their shared run lists a crash sighting from you that your records can't confirm (it may be too old)."
		end
	end

	if not rec or not rec.history or #rec.history == 0 then
		notes[#notes + 1] = "You have no witness records of this character, so only the code could be checked."
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
				contradictions[#contradictions + 1] = "You saw them DISQUALIFIED " .. when .. ", but their shared run says " .. tostring(report.status) .. "."
			end
			if (obs.v or 0) > #report.violations then
				contradictions[#contradictions + 1] = string.format("You saw %d violation(s) %s, their shared run lists %d.", obs.v, when, #report.violations)
			end
			if (obs.d or 0) > reportDeaths then
				contradictions[#contradictions + 1] = string.format("You saw %d death(s) %s, their shared run lists %d.", obs.d, when, reportDeaths)
			end
			if (obs.lvl or 0) > (report.level or 0) then
				contradictions[#contradictions + 1] = string.format("You saw them at level %d %s, their shared run says level %d.", obs.lvl, when, report.level or 0)
			end
			if (obs.g or 0) > (report.gapTotal or 0) + 60 then
				contradictions[#contradictions + 1] = string.format("You saw %s of untracked time %s, their shared run lists %s.", SF.Duration(obs.g), when, SF.Duration(report.gapTotal))
			end
		else
			newer = newer + 1
		end
	end

	if considered > 0 then
		notes[#notes + 1] = string.format("Checked against %d observation(s) you recorded between %s and %s.", considered, SF.Date(rec.first), SF.Date(rec.last))
	end
	if newer > 0 then
		notes[#notes + 1] = string.format("You have %d observation(s) newer than this shared run; ask them for an up-to-date one.", newer)
	end
	return contradictions, notes
end
