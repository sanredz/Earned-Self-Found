-- Self Found - Ledger
-- Owns the saved run: stats, violations, untracked-time gaps, and an
-- append-only event log where every entry is chained to the previous one
-- by checksum. The whole run is then sealed with a checksum after every
-- change, so editing the saved file outside the game is detected on the
-- next login.

local ADDON, SF = ...

local SCHEMA = 1
local LOG_MAX = 4000
local LOG_TRIM = 1000
local SEP = "\031"

local DEFAULT_SETTINGS = {
	tooltips = true,
	warnings = true,
	showMinorLog = false,
	minimap = { hide = false, angle = 205 },
}

-- Everything that gets counted, so older saves pick up new counters too.
local COUNTER_GROUPS = {
	stats = {
		"deaths", "kills", "quests", "levelUps",
		"trades", "tradeWindows",
		"ahOpened", "ahBids", "ahBuyouts", "ahListed", "ahSold",
		"mailFromPlayers", "mailTaken", "mailSent",
		"bankWithdrawals",
	},
	income = { "loot", "quest", "vendor", "mail", "other" },
	spent = { "vendor", "repair", "training", "travel", "fees", "given", "other" },
	items = { "lootedCount", "lootedValue", "destroyedCount", "destroyedValue", "soldCount" },
	worth = { "money", "bags", "equipped", "bank", "bankMoney", "peak" },
}

local function ApplyDefaults(target, defaults)
	for k, v in pairs(defaults) do
		if type(v) == "table" then
			if type(target[k]) ~= "table" then
				target[k] = {}
			end
			ApplyDefaults(target[k], v)
		elseif target[k] == nil then
			target[k] = v
		end
	end
end

local function EnsureCounters(run)
	for group, keys in pairs(COUNTER_GROUPS) do
		run[group] = run[group] or {}
		for _, key in ipairs(keys) do
			if type(run[group][key]) ~= "number" then
				run[group][key] = 0
			end
		end
	end
	run.violations = run.violations or {}
	run.gaps = run.gaps or {}
	run.unwatched = run.unwatched or {} -- changes the addon found that happened while it wasn't running
	run.played = run.played or { tracked = 0, sessions = 0 }
	run.witnessedBy = run.witnessedBy or {}
	run.milestones = run.milestones or {} -- ["L20"] / ["D3"] = { names of witnesses who were there }
	run.logBase = run.logBase or { h = "genesis", n = 0 }
end

local function NewRun()
	local _, classFile = UnitClass("player")
	local _, raceFile = UnitRace("player")
	local run = {
		schema = SCHEMA,
		char = SF.playerKey,
		class = classFile,
		race = raceFile,
		created = time(),
		startLevel = UnitLevel("player"),
	}
	EnsureCounters(run)
	return run
end

-- ---------------------------------------------------------------------------
-- Log chain and seal
-- ---------------------------------------------------------------------------

local function EntryHash(prev, e)
	return SF.Hash(prev .. SEP .. tostring(e.t) .. SEP .. tostring(e.k) .. SEP .. tostring(e.m) .. SEP .. tostring(e.x or 0))
end

function SF.LogHead()
	local log = SF.cdb.log
	local last = log[#log]
	return last and last.h or SF.run.logBase.h
end

function SF.LogCount()
	return SF.run.logBase.n + #SF.cdb.log
end

local function ComputeSeal()
	return SF.Hash(SF.Serialize(SF.run) .. SEP .. SF.LogHead() .. SEP .. SF.LogCount())
end

-- Reseals after every change. Done synchronously so the file on disk is
-- always consistent, whenever the game happens to write it.
function SF.Commit()
	if SF.run and SF.cdb then
		SF.cdb.seal = ComputeSeal()
	end
end

local function VerifyChain()
	local prev = SF.run.logBase.h
	for i, e in ipairs(SF.cdb.log) do
		if type(e) ~= "table" or EntryHash(prev, e) ~= e.h then
			return false, i
		end
		prev = e.h
	end
	return true
end

-- Appends an event to the chained log. `minor` entries (routine things like
-- destroyed items) are hidden from the log view by default.
-- `key` links milestone entries (level-ups "L20", deaths "D3") to the
-- witnesses who saw them (run.milestones); it isn't part of the checksum.
function SF.Log(kind, text, minor, key)
	local log = SF.cdb.log
	local entry = { t = time(), k = kind, m = tostring(text), x = minor and 1 or nil, key = key }
	entry.h = EntryHash(SF.LogHead(), entry)
	log[#log + 1] = entry

	-- Keep the saved file bounded. Trimmed entries are folded into logBase,
	-- which is itself sealed, so trimming can't be used to hide anything.
	if #log > LOG_MAX then
		local keep = {}
		for i = LOG_TRIM + 1, #log do
			keep[#keep + 1] = log[i]
		end
		SF.run.logBase = { h = log[LOG_TRIM].h, n = SF.run.logBase.n + LOG_TRIM }
		SF.cdb.log = keep
	end

	SF.Commit()
	SF.Fire("LogChanged", entry)
	return entry
end

-- ---------------------------------------------------------------------------
-- Rule outcomes
-- ---------------------------------------------------------------------------

function SF.HasViolation(code)
	for _, v in ipairs(SF.run.violations) do
		if v.c == code then
			return true
		end
	end
	return false
end

function SF.Violation(code, text)
	if not SF.run then
		return
	end
	table.insert(SF.run.violations, { t = time(), c = code, m = text })
	SF.Log("violation", text)
	SF.Publish() -- saved right away, even if the game disconnects next
	SF.Fire("Violation", code, text)
	SF.Fire("StatusChanged")
end

-- Untracked play time. `from`/`to` are the /played values where the gap
-- starts (last save) and ends (this login); they let a witness who saw the
-- addon running until just before `to` recover it (a crash, not cheating).
function SF.AddGap(seconds, detail, from, to)
	seconds = math.floor(seconds)
	table.insert(SF.run.gaps, { t = time(), s = seconds, from = from and math.floor(from), to = to and math.floor(to) })
	SF.Log("gap", string.format("%s of play time wasn't tracked%s", SF.Duration(seconds), detail and (" (" .. detail .. ")") or ""))
	SF.Fire("StatusChanged")
end

-- All untracked time ever, recovered or not. Only ever grows, which is what
-- witnesses record and Verify compares.
function SF.GapTotal()
	local total = 0
	for _, g in ipairs(SF.run.gaps) do
		total = total + (g.s or 0)
	end
	return total
end

-- Untracked time that no witness has recovered: this is what makes a run
-- Unverified.
function SF.OpenGapTotal()
	local total = 0
	for _, g in ipairs(SF.run.gaps) do
		if not g.cov then
			total = total + (g.s or 0)
		end
	end
	return total
end

function SF.RecoveredGaps()
	local count, total = 0, 0
	for _, g in ipairs(SF.run.gaps) do
		if g.cov then
			count, total = count + 1, total + (g.s or 0)
		end
	end
	return count, total
end

local RECOVERY_WINDOW = 7 * 86400 -- keep asking witnesses for this long

-- Gaps that witnesses could still recover (newest first).
function SF.PendingGaps()
	local list = {}
	for i = #SF.run.gaps, 1, -1 do
		local g = SF.run.gaps[i]
		if not g.cov and g.from and g.to and time() - (g.t or 0) <= RECOVERY_WINDOW then
			list[#list + 1] = g
		end
	end
	return list
end

-- The last heartbeat a witness saw must be after the last save (the addon
-- was running in the lost session) and at most this many seconds of
-- /played before the gap's end (it kept running until the crash).
SF.COVER_SLACK = 90

SF.MIN_COVER = 1  -- witnesses needed to recover a gap; more add credibility
local SEEN_MAX = 10  -- sightings kept per gap

-- Principle: other players can never disqualify you or make you Unverified.
-- Only your own addon's observations change your status. Witnesses can help
-- (consistent sightings recover a crash), and they can hand back your OWN
-- addon's words: a token-proven sighting of a disqualification your addon
-- broadcast before the game closed without saving (see GapSighting).

-- Witnesses whose sighting recovers the gap (sorted by name). `violations` =
-- how many the run has (defaults to ours; pass a report's count when
-- checking someone else).
function SF.GapWitnesses(g, violations)
	violations = violations or #SF.run.violations
	local support = {}
	for name, o in pairs(g.seen or {}) do
		if o.s ~= "D" and (tonumber(o.v) or 0) <= violations and g.to and tonumber(o.pl) and g.to - o.pl <= SF.COVER_SLACK then
			support[#support + 1] = name
		end
	end
	table.sort(support)
	return support
end

-- A witness reports the latest /played it saw from us inside the gap that
-- starts at `from`, echoing that heartbeat's token. Only sightings of
-- heartbeats we really sent (valid token) count; anything else - a friend
-- or troll making one up - is ignored entirely. Returns true if the gap is
-- (now) recovered.
function SF.GapSighting(from, seen, status, violations, witness, token)
	from, seen, violations = tonumber(from), tonumber(seen), tonumber(violations) or 0
	if not (SF.run and from and seen and type(witness) == "string" and SF.STATUS_WORD and SF.STATUS_WORD[status]) then
		return false
	end
	if token ~= SF.Token(seen, status, violations) then
		return false
	end
	for _, g in ipairs(SF.run.gaps) do
		if g.from == from and g.to then
			if seen <= g.from or seen > g.to + 5 then
				return false
			end
			g.seen = g.seen or {}
			local prev = g.seen[witness]
			if prev and prev.pl >= seen and prev.s == status then
				return g.cov ~= nil
			end
			if not prev then
				local count = 0
				for _ in pairs(g.seen) do
					count = count + 1
				end
				if count >= SEEN_MAX then
					return g.cov ~= nil
				end
			end
			g.seen[witness] = { pl = seen, s = status, v = violations, t = time() }

			-- The token proves OUR addon broadcast this many violations before
			-- the game closed without saving: they're real, just lost.
			if violations > #SF.run.violations then
				while #SF.run.violations < violations do
					SF.Violation("LOST", string.format("Disqualified before the game closed without saving (%s's addon still had your broadcast)", SF.ShortName(witness)))
				end
				SF.Changed()
				return false
			end

			local support = SF.GapWitnesses(g)
			if not g.cov and #support >= SF.MIN_COVER then
				g.cov, g.by, g.ct = seen, support[1], time()
				SF.Log("recover", string.format("Recovered %s of untracked play time after a crash, confirmed by %s", SF.Duration(g.s), SF.ShortName(witness)))
				SF.Fire("StatusChanged")
			end
			SF.Changed()
			return g.cov ~= nil
		end
	end
	return false
end

function SF.Add(group, key, amount)
	local tbl = SF.run and SF.run[group]
	if not tbl then
		return
	end
	tbl[key] = (tbl[key] or 0) + (amount or 1)
end

-- Call after a batch of SF.Add/field updates: reseals and refreshes the UI.
function SF.Changed()
	SF.Commit()
	SF.Fire("StatsChanged")
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

-- Returns status ("CLEAN" / "UNVERIFIED" / "DISQUALIFIED"), a one-line
-- reason, and a short code used in witness heartbeats.
-- `real` = true for anything shared or exported (heartbeats, reports): it
-- ignores /sf preview's display-only samples.
function SF.GetStatus(real)
	local run = SF.run
	if not run then
		return "UNVERIFIED", "Loading...", "U"
	end
	if #run.violations > 0 then
		local first = run.violations[1]
		local reason = first.m
		if #run.violations > 1 then
			reason = reason .. string.format(" (+%d more)", #run.violations - 1)
		end
		return "DISQUALIFIED", reason, "D"
	end
	local reasons = {}
	if run.lateStart then
		reasons[#reasons + 1] = string.format("Tracking started at level %d with %s already played", run.lateStart.level or 0, SF.Duration(run.lateStart.played))
	end
	if #run.unwatched > 0 then
		reasons[#reasons + 1] = "Your bank changed while the addon wasn't running"
	end
	local open = SF.OpenGapTotal()
	if open > 0 then
		local text = string.format("%s of play time wasn't tracked", SF.Duration(open))
		if #SF.PendingGaps() > 0 and not run.lateStart then
			text = text .. ". If the game crashed, guild or group witnesses can recover it"
		end
		reasons[#reasons + 1] = text
	end
	if #reasons > 0 then
		return "UNVERIFIED", table.concat(reasons, ". ") .. ".", "U"
	end
	local recovered = SF.RecoveredGaps()
	if recovered > 0 then
		return "CLEAN", string.format("No trades, auctions, or player mail. All play time accounted for (%d crash%s recovered by witnesses).",
			recovered, recovered == 1 and "" or "es"), "C"
	end
	return "CLEAN", "No trades, auctions, or player mail, and all play time accounted for.", "C"
end

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

SF.integrity = { ok = true }

-- A per-run secret that never leaves this computer. Heartbeats carry
-- tokens derived from it, so witnesses can prove a sighting of us is real
-- (see SF.Token) without anyone else being able to forge one.
local function NewKey()
	local seed = table.concat({
		tostring(time()), tostring(GetTime()),
		tostring(math.random(0, 2147483646)), tostring(math.random(0, 2147483646)),
		tostring(debugprofilestop and debugprofilestop() or 0),
		tostring(UnitGUID and UnitGUID("player") or ""), tostring({}),
	}, "|")
	return SF.Hash("k1" .. seed) .. SF.Hash("k2" .. seed)
end

-- Token binding one heartbeat's /played, status and violation count to our
-- secret key. A witness echoing it back proves we really broadcast exactly
-- that; without the key it can't be forged.
function SF.Token(played, status, violations)
	return SF.Hash(SF.cdb.key .. SEP .. string.format("%.0f", tonumber(played) or 0) .. SEP .. tostring(status) .. SEP .. string.format("%.0f", tonumber(violations) or 0)):sub(1, 8)
end

local function LoadRun()
	local cdb = SF.cdb
	cdb.log = cdb.log or {}
	if type(cdb.key) ~= "string" or #cdb.key < 16 then
		cdb.key = NewKey()
	end

	if type(cdb.run) ~= "table" then
		cdb.run = NewRun()
		cdb.log = {}
		SF.run = cdb.run
		SF.isNewRun = true
		local _, raceName = UnitRace("player")
		local className = UnitClass("player")
		SF.Log("start", string.format("Tracking started: level %d %s %s", SF.run.startLevel or 1, raceName or "", className or ""))
		return
	end

	SF.run = cdb.run

	-- Verify before touching anything, so our own defaults/migrations can't
	-- launder an edited file.
	local chainOk, badIndex = VerifyChain()
	local sealOk = type(cdb.seal) == "string" and cdb.seal == ComputeSeal()
	SF.integrity = { ok = chainOk and sealOk, chainOk = chainOk, sealOk = sealOk, badIndex = badIndex }

	EnsureCounters(SF.run)
	SF.run.schema = SCHEMA
	SF.run.char = SF.playerKey -- older versions left out the Forever surname

	if not SF.integrity.ok and not SF.HasViolation("TAMPER") then
		SF.Violation("TAMPER", "Saved data was changed outside the game (integrity check failed)")
	end
	SF.Commit()
end

SF.On("ADDON_LOADED", function(name)
	if name ~= ADDON then
		return
	end
	SelfFoundDB = type(SelfFoundDB) == "table" and SelfFoundDB or {}
	SelfFoundCharDB = type(SelfFoundCharDB) == "table" and SelfFoundCharDB or {}
	SF.db = SelfFoundDB
	-- Work on a PRIVATE copy of the run. The saved-variable global is
	-- reachable from chat (/run), so it only ever receives copies of our
	-- data (SF.Publish); edits to it are overwritten or break the seal.
	SF.cdb = SF.Copy(SelfFoundCharDB)
	SF.db.settings = SF.db.settings or {}
	ApplyDefaults(SF.db.settings, DEFAULT_SETTINGS)
	SF.db.settings.broadcast = nil -- removed option; sharing is always on
	SF.db.witness = SF.db.witness or {}
	SF.settings = SF.db.settings
	SF.loadedAt = GetTime()
end)

-- Writes a fresh, sealed copy of our private data to the saved-variable
-- global. Done at login, every 15s (Tracker), on violations and at logout,
-- so whatever the game saves - including on a disconnect that might skip
-- PLAYER_LOGOUT - is at most seconds old. A /run edit of the global is
-- overwritten by the next publish, or, if it gets saved first, no longer
-- matches the seal and is caught as tampering on the next login.
function SF.Publish()
	if SF.run and SF.cdb then
		SelfFoundCharDB = SF.Copy(SF.cdb)
	end
end

SF.On("PLAYER_LOGIN", function()
	SF.playerKey = SF.PlayerKey()
	LoadRun()
	SF.Publish()
	SF.ready = true
	SF.Fire("Ready")
	SF.Fire("StatusChanged")
end)

SF.On("PLAYER_LOGOUT", function()
	if not SF.ready then
		return
	end
	SF.Fire("BeforeSave")
	SF.Commit()
	SF.Publish()
end)
