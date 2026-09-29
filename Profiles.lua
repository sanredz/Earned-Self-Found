-- Self Found - Profiles
-- Everything needed to check another player (or yourself):
--   * Silence detection: a player known to run Earned who is online in your
--     guild or group, but whose addon hasn't sent a heartbeat for 5 minutes,
--     is recorded as "online without Earned" - a disabled addon can't warn
--     anyone itself, so its silence is the signal.
--   * Summaries of what you've witnessed of a player.
--   * Asking other witnesses: "Q1|name" goes to guild/group, and every
--     Earned user who has records of that player whispers back a summary
--     ("W1"). A player who faked their own addon still can't fake what other
--     people's addons recorded about them.
-- Like all witness data, this is information shown with names and counts;
-- it never changes anyone's status.

local ADDON, SF = ...

local SILENT_AFTER = 300     -- seconds online without a heartbeat before it counts
local CHECK_INTERVAL = 60
local SILENT_KEEP = 20       -- periods kept per player
local QUERY_REPLY_INTERVAL = 60
local QUERY_REPLIES_PER_MINUTE = 20
local QUERY_OWN_INTERVAL = 30
local QUERY_WINDOW = 120     -- replies accepted this long after asking

-- ---------------------------------------------------------------------------
-- Who is online right now (guild roster + group)
-- ---------------------------------------------------------------------------

local function OnlinePlayers()
	local online = {}
	if IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo then
		for i = 1, SF.Safe(SF.Try(GetNumGuildMembers)) or 0 do
			local name, _, _, _, _, _, _, _, isOnline = SF.Try(GetGuildRosterInfo, i)
			name, isOnline = SF.Safe(name), SF.Safe(isOnline)
			if type(name) == "string" and isOnline then
				online[SF.FullName(name)] = true
			end
		end
	end
	local raid = IsInRaid and IsInRaid()
	for i = 1, raid and 40 or 4 do
		local unit = (raid and "raid" or "party") .. i
		if UnitExists and SF.Safe(UnitExists(unit)) and SF.Safe(UnitIsConnected(unit)) then
			local name, realm = UnitName(unit)
			name, realm = SF.Safe(name), SF.Safe(realm)
			if name then
				online[SF.FullName(realm and realm ~= "" and (name .. "-" .. realm) or name)] = true
			end
		end
	end
	return online
end

-- ---------------------------------------------------------------------------
-- Flags: offenses a witness caught with its own eyes, shared with everyone.
--   undq    - their addon said DISQUALIFIED (or had more violations) before,
--             and now claims fewer: violations never disappear legitimately,
--             so their record was edited, tampered with or wiped.
--   noaddon - online in your guild/group for 10+ minutes with their addon
--             silent (off, removed, or blocked).
-- The evidence lives with the witnesses, never with the accused (whose
-- addon may be the tampered one). A flag is signed by the witness who saw
-- it; others only accept it straight from that witness, and it's
-- re-announced whenever the flagged player is online or asked about, so
-- players who weren't there learn it too. Flags never change anyone's
-- status: they're evidence with names attached.
-- ---------------------------------------------------------------------------

local FLAG_SILENT = 600       -- silence long enough to become a shared flag
local FLAGS_MAX = 40          -- kept per player
local TOOLTIP_REPORTERS = 2   -- independent reporters needed to show in tooltips

SF.FLAG_KINDS = { undq = true, noaddon = true }

function SF.FlagText(f)
	if f.k == "undq" then
		return string.format("saw them disqualified (%d violation%s), later claiming fewer", f.v or 1, (f.v or 1) == 1 and "" or "s")
	end
	return string.format("saw them online without Earned for %s", SF.Duration(f.s))
end

local announced = {} -- [target] = our flags about them were announced this session

local function SendFlag(target, f, channel, whisperTo)
	local message = string.format("F1|%s|%s|%.0f|%.0f|%d", target, f.k, f.t, f.s or 0, f.v or 0)
	if channel then
		SF.Send(message, channel, whisperTo)
	else
		SF.SendToWitnesses(message)
	end
end

-- Stores a flag about `target`. Our own flags are announced right away.
-- Returns true if it was new.
function SF.AddFlag(target, f)
	SF.db.flags = SF.db.flags or {}
	local list = SF.db.flags[target] or {}
	local id = f.by .. "|" .. f.k .. "|" .. math.floor(f.t) .. "|" .. (f.v or 0)
	if list[id] then
		return false
	end
	list[id] = f
	-- Keep the newest FLAGS_MAX.
	local count, oldest, oldestId = 0, nil, nil
	for key, flag in pairs(list) do
		count = count + 1
		if not oldest or flag.t < oldest then
			oldest, oldestId = flag.t, key
		end
	end
	if count > FLAGS_MAX then
		list[oldestId] = nil
	end
	SF.db.flags[target] = list
	if f.by == SF.playerKey then
		SendFlag(target, f)
		announced[target] = true -- counts as this session's announcement
	end
	SF.Fire("WitnessChanged")
	SF.Fire("ProfileChanged", target)
	return true
end

-- Flags about `target`, newest first. With `claimedStatus` = "D", undq
-- flags are left out (no contradiction: they admit it).
function SF.FlagsFor(target, claimedStatus)
	local list = {}
	for _, f in pairs(SF.db.flags and SF.db.flags[target] or {}) do
		if not (f.k == "undq" and claimedStatus == "D") then
			list[#list + 1] = f
		end
	end
	table.sort(list, function(a, b)
		return a.t > b.t
	end)
	return list
end

-- { count, reporters = {names}, red, mine, show } - `show` = worth a
-- tooltip warning: 2+ independent reporters, or one of them is you.
function SF.FlagSummary(target, claimedStatus)
	local flags = SF.FlagsFor(target, claimedStatus)
	local seen, reporters, red, mine = {}, {}, false, false
	for _, f in ipairs(flags) do
		if not seen[f.by] then
			seen[f.by] = true
			reporters[#reporters + 1] = f.by
		end
		red = red or f.k == "undq"
		mine = mine or f.by == SF.playerKey
	end
	table.sort(reporters)
	return {
		count = #flags, reporters = reporters, red = red, mine = mine,
		show = #reporters >= TOOLTIP_REPORTERS or mine,
	}
end

local ALERT_ICON = "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:0|t"

-- "(!) Flagged by 2 players: Carl, Dana", with its color - or nil if
-- there's nothing worth showing (`force` = show even a single reporter,
-- e.g. flags about yourself).
function SF.FlagLine(target, claimedStatus, force)
	local sum = SF.FlagSummary(target, claimedStatus)
	if sum.count == 0 or not (sum.show or force) then
		return nil
	end
	local names = {}
	for i, name in ipairs(sum.reporters) do
		if i > 3 then
			names[#names + 1] = "..."
			break
		end
		names[#names + 1] = name == SF.playerKey and "you" or SF.ShortName(name)
	end
	local text = string.format("%s Flagged by %d player%s: %s", ALERT_ICON, #sum.reporters, #sum.reporters == 1 and "" or "s", table.concat(names, ", "))
	return text, sum.red and SF.COLOR.DISQUALIFIED or { 1, 0.6, 0.2 }
end

-- F1|target|kind|time|seconds|violations: only straight from the witness
-- who saw it (known player), on guild/group channels or as a whisper
-- (answering a question). Nobody flags themselves.
SF.MessageHandlers.F1 = function(sender, parts, channel, known, shared)
	local target, kind, t = SF.FullName(parts[2]), parts[3], tonumber(parts[4])
	if not known or not (shared or channel == "WHISPER") or not target or target == sender or not SF.FLAG_KINDS[kind] or not t then
		return
	end
	local f = { by = sender, k = kind, t = t, s = tonumber(parts[5]) or 0, v = tonumber(parts[6]) or 0 }
	if SF.AddFlag(target, f) and target == SF.playerKey then
		SF.Print(SF.Colorize(string.format("%s flagged you: %s (%s).", SF.ShortName(sender), SF.FlagText(f):gsub("them", "you"), SF.Date(t)), { 1, 0.6, 0.2 }))
	end
end

-- Re-announce our own flags about someone when they're around (once per
-- session each, see `announced`), so witnesses who weren't there learn them.

local function AnnounceFlags(target, channel, whisperTo)
	for _, f in pairs(SF.db.flags and SF.db.flags[target] or {}) do
		if f.by == SF.playerKey then
			SendFlag(target, f, channel, whisperTo)
		end
	end
end
SF.AnnounceFlags = AnnounceFlags

-- "Their record got better": violations never disappear legitimately.
local function CheckRecord(sender, rec, prev)
	local obs = rec.latest
	-- A different character with the same name (deleted and remade): played
	-- time and level both went down. Start their record over.
	if prev and (obs.pl or 0) + 60 < (prev.pl or 0) and (obs.lvl or 0) < (prev.lvl or 0) then
		rec.maxV, rec.sawD, rec.hours, rec.undqV = 0, false, {}, nil
		return
	end
	if rec.maxV == nil then
		rec.maxV, rec.sawD = prev and prev.v or 0, prev and prev.s == "D" or false
	end
	local maxV = rec.maxV
	if rec.sawD and maxV < 1 then
		maxV = 1
	end
	local fewer = (obs.v or 0) < maxV or (rec.sawD and obs.s ~= "D")
	if fewer and maxV > (rec.undqV or 0) then
		rec.undqV = maxV
		SF.AddFlag(sender, { by = SF.playerKey, k = "undq", t = time(), v = maxV })
	end
	rec.maxV = math.max(rec.maxV, obs.v or 0)
	rec.sawD = rec.sawD or obs.s == "D"
end

SF.Listen("HeardFrom", function(sender, rec, prev)
	CheckRecord(sender, rec, prev)
	if not announced[sender] and SF.db.flags and SF.db.flags[sender] then
		announced[sender] = true
		AnnounceFlags(sender)
	end
end)

-- ---------------------------------------------------------------------------
-- Silence detection
-- ---------------------------------------------------------------------------

local onlineSince = {}

local function CloseSilent(name, rec, endTime)
	if not rec.silentOpen then
		return
	end
	local from, to = rec.silentOpen, endTime or rec.silentSeen or rec.silentOpen
	rec.silentOpen, rec.silentSeen = nil, nil
	if to <= from then
		return
	end
	rec.silent = rec.silent or {}
	table.insert(rec.silent, { f = from, t = to })
	while #rec.silent > SILENT_KEEP do
		table.remove(rec.silent, 1)
	end
	rec.silentN = (rec.silentN or 0) + 1
	rec.silentSecs = (rec.silentSecs or 0) + (to - from)
	if to - from >= FLAG_SILENT then
		SF.AddFlag(name, { by = SF.playerKey, k = "noaddon", t = from, s = to - from })
	end
	SF.Fire("WitnessChanged")
end

function SF.CheckSilence()
	if not (SF.run and SF.db and SF.sessionId) then
		return
	end
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		pcall(C_GuildInfo.GuildRoster) -- ask for a fresh roster for next time
	end
	local now = time()
	local online = OnlinePlayers()
	-- We can only judge silence after listening for a while ourselves, and
	-- not while our own addon messaging is restricted.
	local listening = now - SF.sessionId >= SILENT_AFTER and not SF.InMessagingLockdown()

	for name in pairs(onlineSince) do
		if not online[name] then
			onlineSince[name] = nil
			local rec = SF.db.witness[name]
			if type(rec) == "table" then
				CloseSilent(name, rec)
			end
		end
	end
	for name in pairs(online) do
		onlineSince[name] = onlineSince[name] or now
		local rec = SF.db.witness[name]
		if name ~= SF.playerKey and type(rec) == "table" and rec.shared then
			local quietSince = math.max(rec.last or 0, onlineSince[name], SF.sessionId)
			if listening and now - quietSince >= SILENT_AFTER then
				if not rec.silentOpen then
					rec.silentOpen = quietSince
					SF.Fire("WitnessChanged")
				end
				rec.silentSeen = now
			end
		end
	end
end

-- Their addon spoke again: the silence is over.
SF.Listen("HeardFrom", function(sender, rec)
	CloseSilent(sender, rec, time())
end)

local FORGET_AFTER = 365 * 86400 -- records of players not heard from in a year

SF.Listen("Ready", function()
	local now = time()
	for name, rec in pairs(SF.db.witness) do
		if type(rec) ~= "table" or (rec.last and now - rec.last > FORGET_AFTER) then
			SF.db.witness[name] = nil
			if SF.db.flags then
				SF.db.flags[name] = nil
			end
		elseif rec.silentOpen then
			-- Left open by our last session (e.g. we crashed): ends where we
			-- last saw them.
			CloseSilent(name, rec)
		end
	end
	if C_Timer and C_Timer.NewTicker then
		C_Timer.NewTicker(CHECK_INTERVAL, function()
			SF.SafeCall(SF.CheckSilence)
		end)
	end
end)

SF.Listen("BeforeSave", function()
	for name, rec in pairs(SF.db.witness) do
		if type(rec) == "table" and rec.silentOpen then
			CloseSilent(name, rec)
		end
	end
end)

-- ---------------------------------------------------------------------------
-- Witnessed hours: which hours of a player's /played you heard their addon
-- in. Stored as sorted ranges { {a, b}, ... } (hours a..b inclusive), so a
-- long session costs one entry. Combining everyone's ranges tells how much
-- of a player's play time other people's addons can account for.
-- ---------------------------------------------------------------------------

local HOUR = 3600
local SPANS_MAX = 150

-- Adds hour h to a sorted range list. Returns true if it was new.
local function AddHour(spans, h)
	for i, s in ipairs(spans) do
		if h >= s[1] and h <= s[2] then
			return false
		elseif h == s[2] + 1 then
			s[2] = h
			local nxt = spans[i + 1]
			if nxt and nxt[1] == h + 1 then
				s[2] = nxt[2]
				table.remove(spans, i + 1)
			end
			return true
		elseif h == s[1] - 1 then
			s[1] = h
			return true
		elseif h < s[1] then
			table.insert(spans, i, { h, h })
			return true
		end
	end
	spans[#spans + 1] = { h, h }
	while #spans > SPANS_MAX do
		table.remove(spans, 1) -- oldest hours go first
	end
	return true
end

-- Adds range a..b to a sorted range list.
local function AddRange(spans, a, b)
	for h = a, math.min(b, a + 2000) do
		AddHour(spans, h)
	end
end

function SF.SpanHours(spans, limit)
	local total = 0
	for _, s in ipairs(spans or {}) do
		local b = limit and math.min(s[2], limit - 1) or s[2]
		if b >= s[1] then
			total = total + (b - s[1] + 1)
		end
	end
	return total
end

-- Union of several range lists.
function SF.MergeSpans(lists)
	local all = {}
	for _, spans in ipairs(lists) do
		for _, s in ipairs(spans) do
			all[#all + 1] = { s[1], s[2] }
		end
	end
	table.sort(all, function(x, y)
		return x[1] < y[1]
	end)
	local out = {}
	for _, s in ipairs(all) do
		local last = out[#out]
		if last and s[1] <= last[2] + 1 then
			last[2] = math.max(last[2], s[2])
		else
			out[#out + 1] = { s[1], s[2] }
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Milestones: "who was there". A witness who hears a level-up or a new death
-- in consecutive heartbeats tells that player; their log shows who saw it.
-- ---------------------------------------------------------------------------

local toldMilestone = {}

local function TellMilestone(sender, kind, value)
	local key = sender .. ":" .. kind .. value
	if toldMilestone[key] then
		return
	end
	toldMilestone[key] = true
	SF.Send("M1|" .. kind .. "|" .. value, "WHISPER", sender)
end

SF.Listen("HeardFrom", function(sender, rec, prev)
	local obs = rec.latest
	if obs.pl and obs.pl > 0 then
		rec.hours = rec.hours or {}
		AddHour(rec.hours, math.floor(obs.pl / HOUR))
	end
	-- Only if we were listening just before, i.e. we were really there.
	if prev and obs.t - (prev.t or 0) <= 300 then
		if (obs.lvl or 0) > (prev.lvl or 0) then
			TellMilestone(sender, "L", obs.lvl)
		end
		if (obs.d or 0) > (prev.d or 0) then
			TellMilestone(sender, "D", obs.d)
		end
	end
end)

-- M1: a witness saw our milestone. Whisper from a known witness, and only
-- for a milestone we actually have right now.
SF.MessageHandlers.M1 = function(sender, parts, channel, known)
	local kind, value = parts[2], tonumber(parts[3])
	if channel ~= "WHISPER" or not known or not value or not SF.run then
		return
	end
	local current = (kind == "L" and UnitLevel("player")) or (kind == "D" and SF.run.stats.deaths) or nil
	if current ~= value then
		return
	end
	local key = kind .. value
	local list = SF.run.milestones[key] or {}
	for _, name in ipairs(list) do
		if name == sender then
			return
		end
	end
	if #list < 20 then
		list[#list + 1] = sender
		SF.run.milestones[key] = list
		SF.Changed()
		SF.Fire("LogChanged")
	end
end

-- ---------------------------------------------------------------------------
-- What you've witnessed of a player
-- ---------------------------------------------------------------------------

local function EachObservation(rec, fn)
	if rec.latest then
		fn(rec.latest)
	end
	for _, o in ipairs(rec.history or {}) do
		fn(o)
	end
	for _, o in ipairs(rec.ends or {}) do
		fn(o)
	end
end

-- Compact summary of a witness record (also what we tell others).
function SF.WitnessSummary(rec)
	if type(rec) ~= "table" or not rec.latest then
		return nil
	end
	local maxV, sawD = 0, false
	EachObservation(rec, function(o)
		maxV = math.max(maxV, o.v or 0)
		sawD = sawD or o.s == "D"
	end)
	local silentN, silentSecs = rec.silentN or 0, rec.silentSecs or 0
	if rec.silentOpen then
		silentN = silentN + 1
		silentSecs = silentSecs + math.max(0, (rec.silentSeen or time()) - rec.silentOpen)
	end
	local lastSilent = rec.silentOpen and time() or (rec.silent and rec.silent[#rec.silent] and rec.silent[#rec.silent].t)
	local l = rec.latest
	return {
		n = rec.n or 0, first = rec.first, last = rec.last,
		s = l.s, lvl = l.lvl or 0, pl = l.pl or 0, ver = l.ver,
		maxV = maxV, sawD = sawD,
		silentN = silentN, silentSecs = silentSecs, lastSilent = lastSilent,
		silentNow = rec.silentOpen ~= nil,
		spans = rec.hours or {}, hours = SF.SpanHours(rec.hours),
	}
end

-- ---------------------------------------------------------------------------
-- Asking other witnesses
-- ---------------------------------------------------------------------------

SF.queries = {} -- [name] = { at, replies = { [witness] = summary } }

local askedAt = {}

-- Asks guild and group what their addons recorded of `name`.
function SF.AskWitnesses(name)
	name = SF.FullName(name)
	if not name then
		return false
	end
	local now = time()
	if askedAt[name] and now - askedAt[name] < QUERY_OWN_INTERVAL then
		return false
	end
	askedAt[name] = now
	SF.queries[name] = { at = now, replies = SF.queries[name] and SF.queries[name].replies or {} }
	SF.SendToWitnesses("Q1|" .. name)
	SF.Fire("ProfileChanged", name)
	return true
end

local answeredAt, budget, budgetAt = {}, 0, 0

-- W1|target|n|first|last|status|level|played|maxViolations|sawD|silentN|silentSecs|lastSilent|version
local function Answer(requester, target)
	local summary = SF.WitnessSummary(SF.db.witness[target])
	if not summary then
		return
	end
	local key = requester .. ">" .. target
	local now = time()
	if answeredAt[key] and now - answeredAt[key] < QUERY_REPLY_INTERVAL then
		return
	end
	if now - budgetAt >= 60 then
		budget, budgetAt = 0, now
	end
	if budget >= QUERY_REPLIES_PER_MINUTE then
		return
	end
	answeredAt[key] = now
	budget = budget + 1
	SF.Send(string.format("W1|%s|%d|%.0f|%.0f|%s|%d|%.0f|%d|%d|%d|%.0f|%.0f|%s", target, summary.n, summary.first or 0, summary.last or 0,
		summary.s or "?", summary.lvl, summary.pl, summary.maxV, summary.sawD and 1 or 0, summary.silentN, summary.silentSecs,
		summary.lastSilent or 0, summary.ver or ""), "WHISPER", requester)
	-- V1|target|a-b,c,d-e...: the hours we witnessed, split to fit messages.
	local chunk, length = {}, 0
	local function Flush()
		if #chunk > 0 then
			SF.Send("V1|" .. target .. "|" .. table.concat(chunk, ","), "WHISPER", requester)
			chunk, length = {}, 0
		end
	end
	for _, s in ipairs(summary.spans) do
		local part = s[1] == s[2] and tostring(s[1]) or (s[1] .. "-" .. s[2])
		if length + #part + 1 > 200 then
			Flush()
		end
		chunk[#chunk + 1] = part
		length = length + #part + 1
	end
	Flush()
	AnnounceFlags(target, "WHISPER", requester)
end

-- Q1: only from guild/group channels. We answer about anyone we have
-- records of (including the asker themselves). Replies are spread over a
-- couple of seconds so a big guild doesn't answer all at once.
SF.MessageHandlers.Q1 = function(sender, parts, channel, known, shared)
	local target = SF.FullName(parts[2])
	if shared and target and SF.db.witness[target] then
		SF.After(math.random() * 2, function()
			Answer(sender, target)
		end)
	end
end

-- W1: only as whispers from known witnesses, only for questions we asked
-- recently, and never from the player being asked about (nobody vouches for
-- themselves).
SF.MessageHandlers.W1 = function(sender, parts, channel, known, shared)
	local target = SF.FullName(parts[2])
	local query = target and SF.queries[target]
	if channel ~= "WHISPER" or not known or not query or sender == target or time() - query.at > QUERY_WINDOW then
		return
	end
	local n = function(i)
		return tonumber(parts[i]) or 0
	end
	if not SF.STATUS_WORD[parts[6]] then
		return
	end
	query.replies[sender] = {
		n = n(3), first = n(4), last = n(5), s = parts[6], lvl = n(7), pl = n(8),
		maxV = n(9), sawD = n(10) == 1, silentN = n(11), silentSecs = n(12), lastSilent = n(13),
		ver = parts[14], at = time(), spans = {},
	}
	SF.Fire("ProfileChanged", target)
end

-- V1: the witnessed hours that go with a W1 reply (same rules as W1).
SF.MessageHandlers.V1 = function(sender, parts, channel, known)
	local target = SF.FullName(parts[2])
	local query = target and SF.queries[target]
	local reply = query and query.replies[sender]
	if channel ~= "WHISPER" or not known or not reply or sender == target or time() - query.at > QUERY_WINDOW then
		return
	end
	for part in (parts[3] or ""):gmatch("[^,]+") do
		local a, b = part:match("^(%d+)%-(%d+)$")
		a, b = tonumber(a or part), tonumber(b or a or part)
		if a and b and b >= a and #reply.spans < SPANS_MAX then
			AddRange(reply.spans, a, b)
		end
	end
	SF.Fire("ProfileChanged", target)
end

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------

-- Every name you know: players you've witnessed and your own witnesses.
function SF.KnownPlayers()
	local seen, list = {}, {}
	local function Add(name, last)
		if type(name) == "string" and not seen[name] then
			seen[name] = true
			list[#list + 1] = { name = name, last = last or 0 }
		end
	end
	for name, rec in pairs(SF.db.witness) do
		if type(rec) == "table" and rec.latest then
			Add(name, rec.last)
		end
	end
	for name, entry in pairs(SF.run and SF.run.witnessedBy or {}) do
		Add(name, entry.last)
	end
	table.sort(list, function(a, b)
		return a.last > b.last
	end)
	return list
end

-- Turns typed text into a "Name-Realm" key: a player you know if one
-- matches (case-insensitive), otherwise the name as WoW would write it.
function SF.ResolveName(text)
	text = type(text) == "string" and text:match("^%s*(.-)%s*$") or ""
	if text == "" or text:find("[%s|]") then
		return nil
	end
	local lower = text:lower()
	if SF.playerKey and (SF.playerKey:lower() == lower or SF.ShortName(SF.playerKey):lower() == lower) then
		return SF.playerKey
	end
	for _, entry in ipairs(SF.KnownPlayers()) do
		if entry.name:lower() == lower or SF.ShortName(entry.name):lower() == lower then
			return entry.name
		end
	end
	local name, realm = text:match("^([^%-]+)%-?(.*)$")
	name = name:sub(1, 1):upper() .. name:sub(2):lower()
	return SF.FullName(realm ~= "" and (name .. "-" .. realm) or name)
end


-- ---------------------------------------------------------------------------
-- The Witness Record: what other people's addons can account for. Always
-- computed by the person checking, from their own records plus the replies
-- they got - never from what the player's own addon claims.
-- ---------------------------------------------------------------------------

local VERDICTS = {
	well = { "Well witnessed", { 0.30, 0.92, 0.40 } },
	partly = { "Partly witnessed", { 1, 1, 1 } },
	barely = { "Barely witnessed", { 0.6, 0.6, 0.6 } },
	none = { "Not witnessed yet", { 0.6, 0.6, 0.6 } },
}

-- sources: { { name, spans, n, sawD, maxV, silentN, silentSecs, lastSilent } }
local function BuildRecord(target, claimedStatus, maxPlayed, sources)
	local total = math.floor((maxPlayed or 0) / HOUR) + 1
	local lists, contributors, flags = {}, 0, {}
	for _, src in ipairs(sources) do
		local hours = SF.SpanHours(src.spans, total)
		-- A witness can't have heard more hours than heartbeats it received.
		if hours > 0 and hours <= math.max(1, src.n or 0) then
			lists[#lists + 1] = src.spans
			contributors = contributors + 1
		end
	end
	local reporters = {}
	for _, f in ipairs(SF.FlagsFor(target, claimedStatus)) do
		flags[#flags + 1] = { who = f.by == SF.playerKey and "You" or SF.ShortName(f.by), text = SF.FlagText(f), red = f.k == "undq", t = f.t }
		reporters[f.by] = true
	end
	local reporterCount = 0
	for _ in pairs(reporters) do
		reporterCount = reporterCount + 1
	end
	local union = SF.MergeSpans(lists)
	local covered = SF.SpanHours(union, total)
	local pct = math.floor(100 * covered / total)
	local verdict = (contributors == 0 and "none") or (pct >= 75 and contributors >= 3 and "well") or (pct >= 25 and "partly") or "barely"
	local label = VERDICTS[verdict][1]
	if contributors == 1 and pct >= 25 then
		label = label .. " (all from 1 player)"
	end
	return {
		total = total, covered = covered, pct = pct, contributors = contributors,
		union = union, flags = flags, reporters = reporterCount, verdict = verdict, label = label, color = VERDICTS[verdict][2],
	}
end

-- Everything known about a player, for the profile window.
function SF.Profile(name)
	name = SF.FullName(name)
	if not name then
		return nil
	end
	local isSelf = name == SF.playerKey
	local rec = SF.db.witness[name]
	local mine = SF.WitnessSummary(rec)
	local query = SF.queries[name]

	local sources, others, maxPlayed = {}, {}, 0
	if mine then
		maxPlayed = mine.pl
		table.insert(sources, { name = "You", spans = mine.spans, n = mine.n, sawD = mine.sawD, maxV = mine.maxV,
			silentN = mine.silentN, silentSecs = mine.silentSecs, lastSilent = mine.lastSilent })
	end
	for witness, reply in pairs(query and query.replies or {}) do
		others[#others + 1] = { name = witness, reply = reply, hours = SF.SpanHours(reply.spans) }
		maxPlayed = math.max(maxPlayed, reply.pl or 0)
		table.insert(sources, { name = SF.ShortName(witness), spans = reply.spans, n = reply.n, sawD = reply.sawD, maxV = reply.maxV,
			silentN = reply.silentN, silentSecs = reply.silentSecs, lastSilent = reply.lastSilent })
	end
	table.sort(others, function(a, b)
		return a.hours > b.hours
	end)

	local claimed
	if isSelf then
		maxPlayed = SF.PlayedNow()
		claimed = select(3, SF.GetStatus())
	elseif rec and rec.latest then
		claimed = rec.latest.s
	end

	return {
		name = name,
		isSelf = isSelf,
		rec = type(rec) == "table" and rec or nil,
		mine = mine,
		asked = query and query.at,
		others = others,
		record = BuildRecord(name, claimed, maxPlayed, sources),
		witnessOfMe = SF.run and SF.run.witnessedBy[name],
	}
end
