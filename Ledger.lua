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
	broadcast = true,
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
	run.played = run.played or { tracked = 0, sessions = 0 }
	run.witnessedBy = run.witnessedBy or {}
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
function SF.Log(kind, text, minor)
	local log = SF.cdb.log
	local entry = { t = time(), k = kind, m = tostring(text), x = minor and 1 or nil }
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
	SF.Fire("Violation", code, text)
	SF.Fire("StatusChanged")
end

function SF.AddGap(seconds, detail)
	seconds = math.floor(seconds)
	table.insert(SF.run.gaps, { t = time(), s = seconds })
	SF.Log("gap", string.format("%s of play time wasn't tracked%s", SF.Duration(seconds), detail and (" (" .. detail .. ")") or ""))
	SF.Fire("StatusChanged")
end

function SF.GapTotal()
	local total = 0
	for _, g in ipairs(SF.run.gaps) do
		total = total + (g.s or 0)
	end
	return total
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
function SF.GetStatus()
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
	local gapTotal = SF.GapTotal()
	if gapTotal > 0 then
		reasons[#reasons + 1] = string.format("%s of play time wasn't tracked", SF.Duration(gapTotal))
	end
	if #reasons > 0 then
		return "UNVERIFIED", table.concat(reasons, ". "), "U"
	end
	return "CLEAN", "No trades, auctions, or player mail, and all play time accounted for.", "C"
end

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

SF.integrity = { ok = true }

local function LoadRun()
	local cdb = SF.cdb
	cdb.log = cdb.log or {}

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
	SF.cdb = SelfFoundCharDB
	SF.db.settings = SF.db.settings or {}
	ApplyDefaults(SF.db.settings, DEFAULT_SETTINGS)
	SF.db.witness = SF.db.witness or {}
	SF.settings = SF.db.settings
	SF.loadedAt = GetTime()
end)

SF.On("PLAYER_LOGIN", function()
	SF.playerKey = SF.PlayerKey()
	LoadRun()
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
end)
