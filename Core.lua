-- Self Found - Core
-- Shared namespace, event dispatch, secret-value guards, formatting helpers,
-- and the deterministic serializer + checksum that make saved data
-- tamper-evident.

local ADDON, SF = ...
SelfFound = SF

SF.ADDON = ADDON
-- The version comes from the TOC, which the release packager stamps from the
-- git tag. Running straight from a git checkout shows "dev".
local function ReadVersion()
	local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	local ok, version = pcall(getMetadata, ADDON, "Version")
	if not ok or type(version) ~= "string" or version == "" or version:find("@", 1, true) then
		return "dev"
	end
	return (version:gsub("^v", ""))
end
SF.VERSION = ReadVersion()
SF.PREFIX = "SelfFound"
SF.ICON = "Interface\\Icons\\INV_Shield_05"
-- Display name. The folder, saved variables, message prefix and report
-- format all stay "SelfFound" so data and witnesses carry across versions.
SF.NAME = "Earned"
SF.TITLE = "Earned: Self Found"
SF.WEBSITE = "github.com/sanredz/Earned-Self-Found"

-- ---------------------------------------------------------------------------
-- Error isolation
-- ---------------------------------------------------------------------------

local function Report(err)
	local handler = geterrorhandler and geterrorhandler()
	if handler then
		handler(err)
	end
end

-- Calls fn safely; errors are reported but never propagate to the caller
-- (important inside hooks, where an error would otherwise break Blizzard
-- code running after the hooked function).
function SF.SafeCall(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		Report(err)
	end
	return ok
end

-- ---------------------------------------------------------------------------
-- Events and internal callbacks
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

-- Registers fn for a game event. Several modules may listen to the same
-- event; unknown events on this client are silently skipped.
function SF.On(event, fn)
	local list = eventHandlers[event]
	if not list then
		if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
			return false
		end
		list = {}
		eventHandlers[event] = list
	end
	table.insert(list, fn)
	return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = eventHandlers[event]
	if not list then
		return
	end
	for i = 1, #list do
		SF.SafeCall(list[i], ...)
	end
end)

local callbacks = {}

function SF.Listen(name, fn)
	callbacks[name] = callbacks[name] or {}
	table.insert(callbacks[name], fn)
end

function SF.Fire(name, ...)
	local list = callbacks[name]
	if not list then
		return
	end
	for i = 1, #list do
		SF.SafeCall(list[i], ...)
	end
end

-- Post-hooks a global function (Hook("Name", fn)) or a table method
-- (Hook(tbl, "Name", fn)). Returns false if it doesn't exist here.
function SF.Hook(tbl, name, fn)
	if type(tbl) == "string" then
		name, fn = tbl, name
		if type(_G[name]) ~= "function" then
			return false
		end
		hooksecurefunc(name, function(...)
			SF.SafeCall(fn, ...)
		end)
		return true
	end
	if type(tbl) ~= "table" or type(tbl[name]) ~= "function" then
		return false
	end
	hooksecurefunc(tbl, name, function(...)
		SF.SafeCall(fn, ...)
	end)
	return true
end

function SF.After(seconds, fn)
	if C_Timer and C_Timer.After then
		C_Timer.After(seconds, function()
			SF.SafeCall(fn)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Secret values (this client restricts some API data in combat/instances)
-- ---------------------------------------------------------------------------

function SF.IsSecret(v)
	if not issecretvalue then
		return false
	end
	local ok, secret = pcall(issecretvalue, v)
	return ok and secret == true
end

-- Returns v, or nil if it's secret (so it can be safely tested/compared).
function SF.Safe(v)
	if SF.IsSecret(v) then
		return nil
	end
	return v
end

local function OnlyIfOk(ok, ...)
	if not ok then
		return nil
	end
	return ...
end

-- Calls an API function and returns its results, or nothing if the call
-- errors. Individual results still need SF.Safe if they may be secret.
function SF.Try(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	return OnlyIfOk(pcall(fn, ...))
end

-- ---------------------------------------------------------------------------
-- Player identity
-- ---------------------------------------------------------------------------

function SF.RealmName()
	local realm = GetNormalizedRealmName and SF.Safe(GetNormalizedRealmName())
	if not realm or realm == "" then
		realm = (SF.Safe(GetRealmName()) or ""):gsub("[%s%-]", "")
	end
	return realm
end

-- "Name" -> "Name-Realm" using our realm when none is given.
function SF.FullName(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	if not name:find("-", 1, true) then
		name = name .. "-" .. SF.RealmName()
	end
	return name
end

function SF.PlayerKey()
	return SF.FullName(SF.Safe(UnitName("player")))
end

function SF.ShortName(fullName)
	if type(fullName) ~= "string" then
		return "?"
	end
	local name, realm = fullName:match("^([^%-]+)%-(.+)$")
	if name and realm == SF.RealmName() then
		return name
	end
	return fullName
end

function SF.ClassColor(classFile)
	local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	if color then
		return color.r, color.g, color.b
	end
	return 0.8, 0.8, 0.8
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

SF.COLOR = {
	CLEAN = { 0.30, 0.92, 0.40 },
	UNVERIFIED = { 1.00, 0.78, 0.10 },
	DISQUALIFIED = { 1.00, 0.28, 0.28 },
	GOLD = { 1.00, 0.82, 0.00 },
	GRAY = { 0.60, 0.60, 0.60 },
	WHITE = { 1.00, 1.00, 1.00 },
}

function SF.Hex(color)
	local function Channel(v)
		return math.floor(v * 255 + 0.5)
	end
	return string.format("ff%02x%02x%02x", Channel(color[1]), Channel(color[2]), Channel(color[3]))
end

function SF.Colorize(text, color)
	return "|c" .. SF.Hex(color) .. tostring(text) .. "|r"
end

function SF.Money(copper)
	copper = math.floor(math.abs(tonumber(copper) or 0))
	if GetMoneyString then
		local ok, text = pcall(GetMoneyString, copper, true)
		if ok and type(text) == "string" then
			return text
		end
	end
	return string.format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

function SF.Duration(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local d = math.floor(seconds / 86400)
	local h = math.floor(seconds % 86400 / 3600)
	local m = math.floor(seconds % 3600 / 60)
	local s = seconds % 60
	if d > 0 then
		return string.format("%dd %dh %dm", d, h, m)
	elseif h > 0 then
		return string.format("%dh %dm", h, m)
	elseif m > 0 then
		return string.format("%dm %ds", m, s)
	end
	return string.format("%ds", s)
end

function SF.Ago(timestamp)
	if not timestamp then
		return "never"
	end
	local seconds = time() - timestamp
	if seconds < 60 then
		return "just now"
	end
	local text = SF.Duration(seconds)
	-- Keep only the two largest units ("3h 12m", not "3h 12m 5s").
	text = text:match("^(%S+ %S+)") or text
	return text .. " ago"
end

function SF.Date(timestamp)
	return date("%Y-%m-%d %H:%M", timestamp or time())
end

function SF.Print(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(SF.Colorize(SF.NAME .. ":", SF.COLOR.GOLD) .. " " .. tostring(msg))
	end
end

-- ---------------------------------------------------------------------------
-- Deterministic serialization
-- ---------------------------------------------------------------------------
-- Tables are written with sorted keys, so the same data always produces the
-- same string regardless of insertion order or how it was reloaded from
-- SavedVariables. Numbers are integers in practice; anything fractional is
-- rounded so a float written back slightly differently can't change the
-- output and falsely fail an integrity check.

local function KeyOrder(a, b)
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return ta < tb
	end
	return a < b
end

local function Write(value, out)
	local t = type(value)
	if t == "table" then
		local keys = {}
		for k in pairs(value) do
			local kt = type(k)
			if kt == "string" or kt == "number" then
				keys[#keys + 1] = k
			end
		end
		table.sort(keys, KeyOrder)
		out[#out + 1] = "{"
		for _, k in ipairs(keys) do
			Write(k, out)
			out[#out + 1] = "="
			Write(value[k], out)
			out[#out + 1] = ";"
		end
		out[#out + 1] = "}"
	elseif t == "number" then
		if value ~= value then
			out[#out + 1] = "nan"
		elseif value == math.floor(value) then
			if value == 0 then
				value = 0
			end
			out[#out + 1] = string.format("%.0f", value)
		else
			out[#out + 1] = string.format("%.2f", value)
		end
	elseif t == "string" then
		out[#out + 1] = string.format("%q", value)
	elseif t == "boolean" then
		out[#out + 1] = value and "T" or "F"
	else
		out[#out + 1] = "~"
	end
end

function SF.Serialize(value)
	local out = {}
	Write(value, out)
	return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Checksum
-- ---------------------------------------------------------------------------
-- Two independent 32-bit FNV-1a lanes, salted with a key, giving a 64-bit
-- hex digest. This is tamper-EVIDENT, not tamper-proof: the key ships with
-- the addon, so anyone reading the source could recompute it. It stops
-- casual edits of the saved file; witnesses are what make a run verifiable.

local HASH_KEY = "SelfFound|v1|9c41e7a2b05d"
local TWO32 = 4294967296
local bxor = bit and bit.bxor

-- Arithmetic xor of two bytes, only used if the bit library is missing.
local function Xor8(a, b)
	local result, place = 0, 1
	for _ = 1, 8 do
		local x, y = a % 2, b % 2
		if x ~= y then
			result = result + place
		end
		a, b, place = (a - x) / 2, (b - y) / 2, place * 2
	end
	return result
end

local function Fnv1a(str, h)
	for i = 1, #str do
		local byte = str:byte(i)
		if bxor then
			h = bxor(h, byte) % TWO32
		else
			local low = h % 256
			h = h - low + Xor8(low, byte)
		end
		-- h * 16777619 mod 2^32, split so every intermediate value stays
		-- exact in a double: 16777619 = 2^24 + 403, and (h * 2^24) mod 2^32
		-- only depends on h's low byte.
		h = ((h % 256) * 16777216 + h * 403) % TWO32
	end
	return h
end

-- Formats a 32-bit value as 8 hex digits without relying on %x, which
-- overflows for values >= 2^31 on some Lua builds.
local function Hex32(n)
	return string.format("%04x%04x", math.floor(n / 65536), n % 65536)
end

function SF.Hash(str)
	str = tostring(str)
	local a = Fnv1a(HASH_KEY .. str, 2166136261)
	local b = Fnv1a(str .. HASH_KEY, 3735928559)
	return Hex32(a) .. Hex32(b)
end
