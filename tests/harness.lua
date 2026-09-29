-- Test harness: loads the addon into a stubbed WoW environment and simulates
-- sessions (login, /reload, crash, tampering, rule violations, UI). Run via
-- `npm test`. Globals ADDON_DIR, TOC_SOURCE and REF_SOURCE
-- are set by run.js.

-- The addon's folder name (what WoW passes as the addon name).
ADDON_NAME = "EarnedSelfFound"

-- Load files in TOC order, exactly like the game.
local FILES, TOC_VERSION = {}, nil
for line in (TOC_SOURCE .. "\n"):gmatch("(.-)\r?\n") do
	if line:match("^## Version:") then
		TOC_VERSION = line:match("^## Version:%s*(.-)%s*$")
	elseif line:match("%.lua$") and not line:match("^#") then
		FILES[#FILES + 1] = line
	end
end

local pass, fail = 0, 0
local function check(cond, name, extra)
	if cond then
		pass = pass + 1
	else
		fail = fail + 1
		print("FAIL: " .. name .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
	end
end

-- Lua 5.1 shims
unpack = table.unpack
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
-- fengari integers are 32-bit, WoW numbers are doubles: emulate WoW's bit
-- library on doubles via 16-bit halves, returning a signed int32 like WoW.
local function halves(n)
	n = n % 4294967296.0
	return math.floor(n / 65536), math.floor(n % 65536)
end
local bitlib = {
	bxor = function(a, b)
		local ah, al = halves(a)
		local bh, bl = halves(b)
		local r = (ah ~ bh) * 65536.0 + (al ~ bl)
		if r >= 2147483648.0 then r = r - 4294967296.0 end
		return r
	end,
}

-- ---------------------------------------------------------------------------
-- World state and stubs
-- ---------------------------------------------------------------------------

local W -- per-boot state

local function Deep(t, seen)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = Deep(v) end
	return out
end

-- Mock frames: uppercase keys auto-create callable child mocks (template
-- children like .Inset/.EditBox, and any method we didn't define).
local Mock = {}
local allMocks
local function NewMock(kind, name)
	local m = setmetatable({ __scripts = {}, __shown = true, __kind = kind, __name = name }, Mock)
	allMocks[#allMocks + 1] = m
	return m
end

local methods = {}
Mock.__index = function(t, k)
	if methods[k] then return methods[k] end
	if type(k) == "string" and k:match("^[A-Z]") then
		local child = NewMock("auto", k)
		rawset(t, k, child)
		return child
	end
	return nil
end
Mock.__call = function() return nil end

function methods:SetScript(k, fn) self.__scripts[k] = fn end
function methods:GetScript(k) return self.__scripts[k] end
function methods:HookScript(k, fn)
	local prev = self.__scripts[k]
	self.__scripts[k] = function(...) if prev then prev(...) end fn(...) end
end
function methods:RegisterEvent(ev)
	W.events[ev] = W.events[ev] or {}
	table.insert(W.events[ev], self)
end
function methods:UnregisterEvent(ev) end
function methods:IsEventRegistered() return true end
function methods:Show()
	if not self.__shown then
		self.__shown = true
		if self.__scripts.OnShow then self.__scripts.OnShow(self) end
	end
end
function methods:Hide()
	if self.__shown then
		self.__shown = false
		if self.__scripts.OnHide then self.__scripts.OnHide(self) end
	end
end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:IsShown() return self.__shown end
function methods:SetText(t) self.__text = t end
function methods:GetText() return self.__text end
function methods:SetChecked(v) self.__checked = v end
function methods:GetChecked() return self.__checked end
function methods:SetID(i) self.__id = i end
function methods:GetID() return self.__id or 0 end
function methods:GetWidth() return 140 end
function methods:GetHeight() return 140 end
function methods:GetCenter() return 100, 100 end
function methods:GetEffectiveScale() return 1 end
function methods:GetFrameLevel() return 1 end
function methods:GetName() return self.__name end
function methods:CreateTexture() return NewMock("Texture") end
function methods:CreateFontString() return NewMock("FontString") end
function methods:SetDataProvider(dp)
	local view = self.__view
	for _, elem in ipairs(dp.list) do
		local row = NewMock("row")
		view.__init(row, elem)
		-- exercise the row's handlers too
		if row.__scripts.OnEnter then row.__scripts.OnEnter(row) end
	end
	self.__count = #dp.list
end
function methods:SetElementInitializer(_, fn) self.__init = fn end

local function Fire(event, ...)
	for _, frame in ipairs(W.events[event] or {}) do
		local fn = frame.__scripts.OnEvent
		if fn then fn(frame, event, ...) end
	end
end

local function Advance(seconds)
	local target = W.clock + seconds
	while true do
		table.sort(W.timers, function(a, b) return a.at < b.at end)
		local t = W.timers[1]
		if not t or t.at > target then break end
		table.remove(W.timers, 1)
		W.clock = t.at
		t.fn()
		if t.every then
			t.at = W.clock + t.every
			table.insert(W.timers, t)
		end
	end
	W.clock = target
end

-- Moves the clock forward without running every tick in between (for
-- multi-day jumps); pending timers shift along with it.
local function Jump(seconds)
	for _, t in ipairs(W.timers) do
		t.at = t.at + seconds
	end
	W.clock = W.clock + seconds
end

local BASE_TIME = 1759000000

local function InstallStubs()
	allMocks = {}
	W.events, W.timers, W.errors, W.chat, W.sent = {}, {}, {}, {}, {}
	W.money = W.money or 0
	W.level = W.level or 1
	W.inbox = {}
	W.trade = { player = {}, target = {}, playerMoney = 0, targetMoney = 0 }

	_G.bit = W.noBit and nil or bitlib
	_G.time = function() return BASE_TIME + math.floor(W.clock) end
	_G.date = os.date
	_G.GetTime = function() return W.clock end
	_G.geterrorhandler = function() return function(e) table.insert(W.errors, tostring(e)); print("ERROR: " .. tostring(e)) end end
	_G.hooksecurefunc = function(a, b, c)
		local tbl, name, fn = a, b, c
		if type(a) == "string" then tbl, name, fn = _G, a, b end
		local orig = tbl[name]
		tbl[name] = function(...)
			local r = { orig(...) }
			fn(...)
			return table.unpack(r)
		end
	end
	_G.CreateFrame = function(kind, name, parent, template)
		local m = NewMock(kind, name)
		if name then _G[name] = m end
		return m
	end
	_G.C_Timer = {
		After = function(sec, fn) table.insert(W.timers, { at = W.clock + sec, fn = fn }) end,
		NewTicker = function(sec, fn) table.insert(W.timers, { at = W.clock + sec, fn = fn, every = sec }) end,
	}
	_G.UIParent = NewMock("Frame", "UIParent")
	_G.Minimap = NewMock("Frame", "Minimap")
	_G.GameTooltip = NewMock("GameTooltip", "GameTooltip")
	_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) table.insert(W.chat, msg) end }
	_G.UISpecialFrames = {}
	_G.tinsert = table.insert
	_G.SlashCmdList = {}
	_G.RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
	_G.LOCALIZED_CLASS_NAMES_MALE = { WARRIOR = "Warrior" }
	_G.UnitName = function(u) if u == "player" then return "Tester" end return "Bob" end
	_G.GetUnitName = function() return "Bob" end
	_G.UnitClass = function() return "Warrior", "WARRIOR" end
	_G.UnitRace = function() return "Human", "Human" end
	_G.UnitLevel = function() return W.level end
	_G.UnitIsPlayer = function() return true end
	_G.UnitIsUnit = function(a, b) return a == b end
	_G.C_AddOns = { GetAddOnMetadata = function(addon, field) if addon == ADDON_NAME and field == "Version" then return W.tocVersion or TOC_VERSION end end }
	_G.GetRealmName = function() return "Test Realm" end
	_G.GetNormalizedRealmName = function() return "TestRealm" end
	_G.GetMoney = function() return W.money end
	_G.RequestTimePlayed = function() W.playedRequested = true end
	_G.GetRealZoneText = function() return "Elwynn Forest" end
	_G.GetZoneText = _G.GetRealZoneText
	_G.IsInGuild = function() return true end
	_G.IsInRaid = function() return false end
	_G.IsInGroup = function() return false end
	_G.C_ChatInfo = {
		SendAddonMessage = function(prefix, msg, channel, target) table.insert(W.sent, { prefix, msg, channel, target }) end,
		RegisterAddonMessagePrefix = function() return true end,
		InChatMessagingLockdown = function() return W.lockdown == true end,
	}
	_G.Enum = {
		PlayerInteractionType = { TradePartner = 1, QuestGiver = 4, Merchant = 5, TaxiNode = 6, Trainer = 7, Banker = 8, GuildBanker = 10, Vendor = 12, MailInfo = 17, Auctioneer = 21 },
		BankType = { Character = 0, Guild = 1, Account = 2 },
		TooltipDataType = { Unit = 2 },
	}
	_G.TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) W.tooltipPost = fn end }
	_G.LOOT_ITEM_SELF = "You receive loot: %s."
	_G.LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
	_G.COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
	_G.ERR_TRADE_COMPLETE = "Trade complete."
	_G.ERR_AUCTION_SOLD_S = "A buyer has been found for your auction of %s."
	_G.C_Item = {
		GetItemInfo = function(link)
			local id = tonumber(tostring(link):match("item:(%d+)"))
			if id and W.items[id] then return "Item" .. id, link, 1, 1, 1, "", "", 1, "", 0, W.items[id] end
		end,
		RequestLoadItemDataByID = function() end,
		DeleteCursorItem = function() end,
	}
	W.items = W.items or { [2589] = 13, [117] = 1, [6948] = 0 }
	_G.C_Container = {
		GetContainerNumSlots = function(bag) return W.bags[bag] and 16 or 0 end,
		GetContainerItemInfo = function(bag, slot)
			local item = W.bags[bag] and W.bags[bag][slot]
			if item then return { hyperlink = item[1], stackCount = item[2], hasNoValue = false, itemID = tonumber(item[1]:match("item:(%d+)")) } end
		end,
		UseContainerItem = function() end,
		PickupContainerItem = function() end,
		SplitContainerItem = function() end,
		ContainerIDToInventoryID = function(bag) return 30 + bag end,
	}
	W.bags = W.bags or { [0] = { [1] = { "|Hitem:2589::|h[Linen Cloth]|h", 5 } } }
	_G.GetInventoryItemLink = function() return nil end
	_G.GetInventoryItemID = function() return nil end
	_G.DeleteCursorItem = function() end
	W.roster = W.roster or {}
	_G.GetNumGuildMembers = function() return #W.roster end
	_G.GetGuildRosterInfo = function(i) local m = W.roster[i]; if m then return m.name, "Member", 1, 10, "Warrior", "Elwynn", "", "", m.online end end
	_G.C_GuildInfo = { GuildRoster = function() end }
	_G.UnitExists = function() return false end
	_G.UnitIsConnected = function() return true end
	_G.UnitXP = function() return W.xp or 0 end
	_G.C_AuctionHouse = {
		PlaceBid = function() end,
		GetAuctionInfoByID = function() return { buyoutAmount = 5000 } end,
		PostItem = function() end,
		PostCommodity = function() end,
		ConfirmCommoditiesPurchase = function() end,
	}
	_G.C_Bank = { WithdrawMoney = function() end, CanViewBank = function() return false end }
	_G.GetInboxHeaderInfo = function(i)
		local m = W.inbox[i]
		if not m then return end
		return nil, nil, m.sender, "subj", m.money or 0, 0, 1, m.items or 1, true, m.returned, false, m.canReply, false
	end
	_G.GetInboxInvoiceInfo = function(i) return W.inbox[i] and W.inbox[i].invoice end
	_G.GetInboxItemLink = function() return "|Hitem:117|h[Tough Jerky]|h" end
	_G.TakeInboxItem = function() end
	_G.TakeInboxMoney = function() end
	_G.AutoLootMailItem = function() end
	_G.SendMail = function() end
	_G.GetSendMailMoney = function() return 0 end
	_G.GetTradePlayerItemInfo = function(i) local it = W.trade.player[i]; if it then return "x", 1, it[2], 1, nil end end
	_G.GetTradePlayerItemLink = function(i) return W.trade.player[i] and W.trade.player[i][1] end
	_G.GetTradeTargetItemInfo = function(i) local it = W.trade.target[i]; if it then return "x", 1, it[2], 1, true, nil end end
	_G.GetTradeTargetItemLink = function(i) return W.trade.target[i] and W.trade.target[i][1] end
	_G.GetPlayerTradeMoney = function() return W.trade.playerMoney end
	_G.GetTargetTradeMoney = function() return W.trade.targetMoney end
	_G.WithdrawGuildBankMoney = function() end
	_G.CursorHasItem = function() return W.cursorHasItem end
	_G.PanelTemplates_SetNumTabs = function() end
	_G.PanelTemplates_SetTab = function(frame, i) frame.selectedTab = i end
	_G.CreateScrollBoxListLinearView = function() return NewMock("view") end
	_G.ScrollUtil = { InitScrollBoxListWithScrollBar = function(box, bar, view) box.__view = view end }
	_G.CreateDataProvider = function(list) return { list = list } end

	-- Encoding: tokens map to deep copies, "base64" is hex (fine for plumbing).
	W.json = W.json or {}
	_G.C_EncodingUtil = {
		SerializeJSON = function(t) local tok = "json#" .. (#W.json + 1); W.json[#W.json + 1] = Deep(t); return tok end,
		DeserializeJSON = function(s) local i = tonumber(s:match("^json#(%d+)$")); return i and Deep(W.json[i]) end,
		CompressString = function(s) return "Z" .. s end,
		DecompressString = function(s) return s:sub(1, 1) == "Z" and s:sub(2) or error("bad") end,
		EncodeBase64 = function(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end,
		DecodeBase64 = function(s) return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)) end,
	}
end

-- SavedVariables round trip: write as Lua source and load it back, exactly
-- like the game. Errors on functions/userdata (e.g. a frame on saved data).
local function WriteLua(v, out, path)
	local t = type(v)
	if t == "table" then
		if getmetatable(v) then error("metatable (frame?) in saved data at " .. path) end
		out[#out + 1] = "{"
		for k, val in pairs(v) do
			out[#out + 1] = "["
			WriteLua(k, out, path)
			out[#out + 1] = "]="
			WriteLua(val, out, path .. "." .. tostring(k))
			out[#out + 1] = ","
		end
		out[#out + 1] = "}"
	elseif t == "number" then
		out[#out + 1] = (math.type(v) == "integer") and tostring(v) or string.format("%.17g", v)
	elseif t == "string" then
		out[#out + 1] = string.format("%q", v)
	elseif t == "boolean" then
		out[#out + 1] = tostring(v)
	else
		error("unsavable " .. t .. " at " .. path)
	end
end

local function SaveVars()
	local db, cdb = {}, {}
	WriteLua(SelfFoundDB, db, "SelfFoundDB")
	WriteLua(SelfFoundCharDB, cdb, "SelfFoundCharDB")
	return { db = table.concat(db), cdb = table.concat(cdb) }
end

local SF

-- Loads the addon fresh (like a /reload or new login).
local function Boot(saved, opts)
	opts = opts or {}
	W = W or { clock = 0 }
	W.noBit = opts.noBit
	InstallStubs()
	SelfFoundDB = saved and load("return " .. saved.db)() or nil
	SelfFoundCharDB = saved and load("return " .. saved.cdb)() or nil
	SF = {}
	for _, file in ipairs(FILES) do
		local chunk = assert(loadfile(ADDON_DIR .. "/" .. file))
		chunk(ADDON_NAME, SF)
	end
	if opts.coreOnly then return SF end
	W.loadClock = W.clock
	Fire("ADDON_LOADED", ADDON_NAME)
	Fire("PLAYER_LOGIN")
	Fire("PLAYER_ENTERING_WORLD", true, false)
	W.playedRequested = false
	Advance(3.5)
	check(W.playedRequested, "requests /played after login")
	if opts.played then
		Fire("TIME_PLAYED_MSG", opts.played, opts.played)
	end
	return SF
end

local function Logout()
	Fire("PLAYER_LOGOUT")
	return SaveVars()
end

-- Worst case for a disconnect: the game saves without PLAYER_LOGOUT firing.
local function Disconnect()
	return SaveVars()
end

-- Track /played ourselves: server total grows with our clock.
local playedBase = 0
local function ServerPlayed() return playedBase + math.floor(W.clock) end

-- ---------------------------------------------------------------------------
-- 1. Checksum vs JS reference, with and without the bit library
-- ---------------------------------------------------------------------------

local REF = load(REF_SOURCE)()
for _, noBit in ipairs({ false, true }) do
	W = { clock = 0 }
	local core = Boot(nil, { noBit = noBit, coreOnly = true })
	for i, r in ipairs(REF) do
		check(core.Hash(r.s) == r.h, "hash matches reference #" .. i .. (noBit and " (no bit lib)" or ""), core.Hash(r.s) .. " vs " .. r.h)
	end
end

-- Version: unpackaged checkouts say "dev", packaged builds show the tag
check(#FILES >= 7, "TOC lists the addon files", #FILES)
check(SF.VERSION == "dev", "unstamped TOC version reads as dev", SF.VERSION)
W.tocVersion = "v1.2.3"
check(Boot(nil, { coreOnly = true }).VERSION == "1.2.3", "packaged version read from TOC (tag's v stripped)")
W.tocVersion = nil

-- ---------------------------------------------------------------------------
-- 2. Serializer determinism
-- ---------------------------------------------------------------------------

do
	local a, b = {}, {}
	a.z = 1; a.a = { 3, 2, 1 }; a[5] = "five"; a.m = 1.005; a.t = true
	b.t = true; b.m = 1.005; b[5] = "five"; b.a = { 3, 2, 1 }; b.z = 1.0
	check(SF.Serialize(a) == SF.Serialize(b), "serialize is order independent", SF.Serialize(a) .. " / " .. SF.Serialize(b))
	check(SF.Serialize({ x = -0.0 }) == SF.Serialize({ x = 0 }), "negative zero normalized")
end

-- ---------------------------------------------------------------------------
-- 3. PatternFromFormat
-- ---------------------------------------------------------------------------

do
	local p = SF.PatternFromFormat("You receive loot: %sx%d.")
	local link, n = ("You receive loot: |cffffffff|Hitem:2589::|h[Linen Cloth]|h|rx3."):match(p)
	check(link == "|cffffffff|Hitem:2589::|h[Linen Cloth]|h|r" and n == "3", "loot multiple pattern", tostring(link) .. " " .. tostring(n))
	local p2 = SF.PatternFromFormat("%1$s dies, you gain %2$d experience.")
	check(("Kobold dies, you gain 45 experience. (+22 Rested bonus)"):match(p2) == "Kobold", "positional pattern + trailing text")
	check(SF.PatternFromFormat(nil) == nil, "nil format")
end

-- ---------------------------------------------------------------------------
-- 4. Fresh character: clean session with income, loot, deaths, UI
-- ---------------------------------------------------------------------------

W = { clock = 0, money = 0, level = 1 }
playedBase = 20
Boot(nil, { played = 20 })
check(SF.GetStatus() == "CLEAN", "new level-1 character is CLEAN", select(2, SF.GetStatus()))
check(SF.LogCount() == 1, "start entry logged")

-- Loot gold
Fire("CHAT_MSG_MONEY", "You loot 25 Copper")
W.money = 25; Fire("PLAYER_MONEY")
-- Vendor sale
Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5)
W.money = 125; Fire("PLAYER_MONEY")
-- Vendor purchase
W.money = 100; Fire("PLAYER_MONEY")
Fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 5)
Advance(10)
-- Quest reward
Fire("QUEST_TURNED_IN", 123, 50, 0)
W.money = 600; Fire("PLAYER_MONEY")
Advance(10)
-- Taxi
Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 6)
W.money = 550; Fire("PLAYER_MONEY")
Fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 6)
Advance(10)
-- Loot items
Fire("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:2589::|h[Linen Cloth]|h|rx3.")
Fire("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:117::|h[Tough Jerky]|h|r.")
Fire("CHAT_MSG_LOOT", "Bob receives loot: |cffffffff|Hitem:117::|h[Tough Jerky]|h|r.")
Fire("CHAT_MSG_COMBAT_XP_GAIN", "Kobold Vermin dies, you gain 45 experience.")
Fire("PLAYER_DEAD")
W.level = 2; Fire("PLAYER_LEVEL_UP", 2)
Advance(1)

local run = SF.run
check(run.income.loot == 25, "loot income", run.income.loot)
check(run.income.vendor == 100, "vendor income", run.income.vendor)
check(run.spent.vendor == 25, "vendor spent", run.spent.vendor)
check(run.income.quest == 500, "quest income", run.income.quest)
check(run.spent.travel == 50, "taxi spent", run.spent.travel)
check(run.items.lootedCount == 4, "looted count (others' loot ignored)", run.items.lootedCount)
check(run.items.lootedValue == 3 * 13 + 1, "looted value", run.items.lootedValue)
check(run.stats.kills == 1 and run.stats.deaths == 1 and run.stats.quests == 1, "kills/deaths/quests")
check(run.worth.money == 550 and run.worth.bags == 5 * 13, "net worth money + bags", run.worth.money .. " " .. run.worth.bags)
check(SF.WorthTotal() == 550 + 65, "worth total")
check(SF.GetStatus() == "CLEAN", "still CLEAN after normal play")

-- Destroy an item
_G.C_Cursor = { GetCursorItem = function() return { IsValid = function() return true end } end }
_G.C_Item.GetItemLink = function() return "|Hitem:2589::|h[Linen Cloth]|h" end
_G.C_Item.GetStackCount = function() return 2 end
Fire("CURSOR_CHANGED")
C_Item.DeleteCursorItem()
check(run.items.destroyedCount == 2 and run.items.destroyedValue == 26, "destroyed item counted", run.items.destroyedCount)

-- QuickTrash-style: pick up and delete in the same instant; CURSOR_CHANGED
-- only arrives afterwards (when the cursor is already empty)
do
	local held
	_G.C_Cursor.GetCursorItem = function() return held end
	_G.C_Item.GetItemLink = function(loc) return loc.link end
	_G.C_Item.GetStackCount = function(loc) return loc.count end
	Fire("CURSOR_CHANGED")                -- cursor empty
	held = { IsValid = function() return true end, link = "|Hitem:117::|h[Tough Jerky]|h", count = 3 }
	C_Container.PickupContainerItem(0, 1) -- picks it up...
	DeleteCursorItem()                    -- ...and deletes it right away
	held = nil
	Fire("CURSOR_CHANGED")                -- the event arrives late
	local last = SF.cdb.log[#SF.cdb.log]
	check(run.items.destroyedCount == 5 and last.k == "destroy" and last.x == 1 and last.m:find("Tough Jerky", 1, true), "same-instant pickup + delete is recorded (routine log entry)", run.items.destroyedCount)
	DeleteCursorItem()
	check(run.items.destroyedCount == 5, "no double counting")
end

-- Mail: own returned mail and AH mail are fine
W.inbox[1] = { sender = "Tester", returned = true, canReply = true }
W.inbox[2] = { sender = "Stormwind Auction House", invoice = "seller" }
TakeInboxItem(1, 1)
TakeInboxItem(2, 1)
check(SF.GetStatus() == "CLEAN", "returned + auction mail don't disqualify")

-- Witness exchange
Fire("CHAT_MSG_ADDON", "SelfFound", "H1|C|5|4000|1|0|0|0|abcd1234|WARRIOR|3", "GUILD", "Bob")
local rec = SelfFoundDB.witness["Bob-TestRealm"]
check(rec and rec.latest and rec.latest.lvl == 5, "heartbeat recorded")
local acked = false
for _, s in ipairs(W.sent) do if s[3] == "WHISPER" and s[4] == "Bob-TestRealm" and s[2]:match("^A1|C|") then acked = true end end
check(acked, "ack whispered back")
Fire("CHAT_MSG_ADDON", "SelfFound", "A1|C|5|4000|1|0|0|0|abcd1234|WARRIOR|3", "WHISPER", "Bob")
check(run.witnessedBy["Bob-TestRealm"] and run.witnessedBy["Bob-TestRealm"].n == 1, "ack makes Bob our witness")
Fire("CHAT_MSG_ADDON", "SelfFound", "garbage", "GUILD", "Eve")
Fire("CHAT_MSG_ADDON", "SelfFound", "H1|X|5", "GUILD", "Eve")
check(SelfFoundDB.witness["Eve-TestRealm"] == nil, "malformed heartbeats ignored")

-- Tooltip line
local tip = NewMock("GameTooltip")
tip.GetUnit = function() return "Bob", "mouseover" end
_G.GameTooltip = tip
W.tooltipPost(tip)
check(tip.AddLine ~= nil, "tooltip post call runs")

-- UI: open, every tab, every hover/click handler, dialogs
SlashCmdList.SELFFOUND("")
check(SelfFoundFrame and SelfFoundFrame:IsShown(), "window opens with /sf")
for i = 1, 4 do SF.UI.SelectTab(i) end
SF.settings.showMinorLog = true
SF.UI.SelectTab(3)
SF.UI.SelectTab(4)
SF.UI.ShowExport()
SF.UI.ShowVerify()
local clicked = 0
for _, m in ipairs(allMocks) do
	if m.__scripts.OnEnter then m.__scripts.OnEnter(m); clicked = clicked + 1 end
	if m.__scripts.OnLeave then m.__scripts.OnLeave(m) end
end
check(clicked > 20, "hover handlers exercised", clicked)
Advance(2)
for _, cmd in ipairs({ "status", "help", "minimap", "minimap", "log", "broadcast" }) do SlashCmdList.SELFFOUND(cmd) end
SelfFound_OnAddonCompartmentEnter(nil, NewMock("Button"))
SelfFound_OnAddonCompartmentClick()
SelfFound_OnAddonCompartmentClick()
check(SelfFoundMinimapButton ~= nil, "minimap button created")
SelfFoundMinimapButton.__scripts.OnEnter(SelfFoundMinimapButton)
SelfFoundMinimapButton.__scripts.OnDragStart(SelfFoundMinimapButton)
_G.GetCursorPosition = function() return 50, 150 end
SelfFoundMinimapButton.__scripts.OnUpdate()
SelfFoundMinimapButton.__scripts.OnDragStop(SelfFoundMinimapButton)
check(SF.settings.minimap.angle == 135, "minimap drag sets angle", SF.settings.minimap.angle)
check(#W.errors == 0, "no errors in UI paths", W.errors[1])

-- Export -> decode -> verify
local exported = SF.ExportReport()
check(exported:find("SF1:", 1, true) ~= nil, "export has verification code")
local report, err = SF.DecodeReport(exported)
check(report and report.char == "Tester-TestRealm" and report.status == "CLEAN", "report round trip", err)
local tampered = exported:gsub("SF1:(%x)", function(c) return "SF1:" .. (c == "0" and "1" or "0") end)
check(SF.DecodeReport(tampered) == nil, "altered checksum rejected")
check(select(2, SF.DecodeReport("hello")) ~= nil, "garbage rejected with message")

-- Verify dialog button end-to-end
for _, m in ipairs(allMocks) do
	if m.__kind == "ScrollFrame" then m.EditBox:SetText(exported) end
end
local function ClickCheck()
	for _, m in ipairs(allMocks) do
		if m.__text == "Check" and m.__scripts.OnClick then m.__scripts.OnClick(m) end
	end
end
local function AnyText(needle)
	for _, m in ipairs(allMocks) do
		if type(m.__text) == "string" and m.__text:find(needle, 1, true) then return true end
	end
	return false
end
ClickCheck()
check(#W.errors == 0 and SelfFoundProfileFrame and SelfFoundProfileFrame:IsShown(), "Check a shared run opens the player's profile", W.errors[1])
check(AnyText("Your shared run") and AnyText("The code is valid"), "the profile shows the shared run's claims")
SelfFoundProfileFrame:Hide()
SF.UI.ShowVerify()
for _, m in ipairs(allMocks) do
	if m.__kind == "ScrollFrame" then m.EditBox:SetText("just some text") end
end
ClickCheck()
check(AnyText("No Earned verification code") and not SelfFoundProfileFrame:IsShown(), "a bad paste shows an error and opens nothing")

-- Verify against witness records: Bob claims CLEAN but we saw him DQ'd
Fire("CHAT_MSG_ADDON", "SelfFound", "H1|D|6|5000|1|1|0|0|abcd1234|WARRIOR|3", "GUILD", "Bob")
local contradictions = SF.VerifyReport({ char = "Bob-TestRealm", status = "CLEAN", level = 6, played = 6000, stats = { deaths = 1 }, violations = {}, gapTotal = 0, integrity = 1, witnesses = {} })
check(#contradictions >= 2, "forged clean report contradicted by witness records", #contradictions)
local c2 = SF.VerifyReport({ char = "Bob-TestRealm", status = "DISQUALIFIED", level = 6, played = 6000, stats = { deaths = 1 }, violations = { {} }, gapTotal = 0, integrity = 1, witnesses = {} })
check(#c2 == 0, "honest report has no contradictions", c2[1])

-- ---------------------------------------------------------------------------
-- 5. Reload: integrity holds, no gap
-- ---------------------------------------------------------------------------

Advance(100)
SelfFoundDB.settings.broadcast = false -- saved by older versions that had an opt-out
local saved = Logout()
local headBefore, countBefore = SF.LogHead(), SF.LogCount()
Advance(5) -- loading screen
Boot(saved, { played = ServerPlayed() })
check(SF.integrity.ok, "integrity ok after reload", SF.integrity.chainOk and "seal" or "chain")

-- Sharing is always on, even if an old save had it switched off
check(SF.settings.broadcast == nil, "old sharing opt-out cleared")
W.sent = {}
Advance(20)
local heartbeat = false
for _, s in ipairs(W.sent) do if s[3] == "GUILD" and s[2]:match("^H1|") then heartbeat = true end end
check(heartbeat, "heartbeat sent after login regardless of old setting")
W.sent = {}
Fire("CHAT_MSG_ADDON", "SelfFound", "H1|C|7|6000|1|0|0|0|abcd1234|WARRIOR|3", "GUILD", "Carl")
check(#W.sent == 1 and W.sent[1][3] == "WHISPER", "acks sent regardless of old setting")
check(SF.GetStatus() == "CLEAN", "still CLEAN after reload", select(2, SF.GetStatus()))
check(SF.LogHead() == headBefore and SF.LogCount() == countBefore, "log preserved")
check(#SF.run.gaps == 0, "no gap on reload")

-- Long session, crash (no logout, nothing saved), relog: gap => UNVERIFIED
Advance(600)
local savedBeforeCrash = Logout()
Advance(3600) -- played an hour; game crashed, nothing saved
Boot(savedBeforeCrash, { played = ServerPlayed() })
check(SF.GetStatus() == "UNVERIFIED", "untracked hour => UNVERIFIED", select(2, SF.GetStatus()))
check(#SF.run.gaps == 1 and SF.run.gaps[1].s >= 3500, "gap recorded", SF.run.gaps[1] and SF.run.gaps[1].s)
check(SF.integrity.ok, "a gap is not tampering")

-- Crash recovery: a witness who saw the addon running until just before the
-- crash recovers the gap.
do
	local gap = SF.run.gaps[1]
	check(gap.from and gap.to and math.abs((gap.to - gap.from) - gap.s) <= 1, "gap records its /played range", tostring(gap.from) .. ".." .. tostring(gap.to))
	check(select(2, SF.GetStatus()):find("witnesses can recover", 1, true) ~= nil, "Unverified reason mentions recovery")

	W.sent = {}
	Advance(20) -- Ready + 15s broadcast
	local recall = false
	for _, s in ipairs(W.sent) do
		if s[3] == "GUILD" and s[2] == string.format("R1|%.0f|%.0f", gap.from, gap.to) then recall = true end
	end
	check(recall, "recall request sent to guild")

	-- Honest witnesses echo the token from the heartbeat they really saw;
	-- tests stand in for "our addon sent that heartbeat before the crash".
	local function Cover(seen, status, violations, who, token)
		status, violations = status or "C", violations or 0
		token = token or SF.Token(seen, status, violations)
		Fire("CHAT_MSG_ADDON", "SelfFound", string.format("C1|%.0f|%.0f|%s|%d|0|0|%s", gap.from, seen, status, violations, token), "WHISPER", who or "Bob")
	end

	-- Forgery: a friend making up a sighting (no real heartbeat behind it)
	Cover(gap.to - 30, "C", 0, "Bob", "deadbeef")
	check(not gap.cov and not (gap.seen and gap.seen["Bob-TestRealm"]), "made-up sighting (wrong token) ignored")
	Fire("CHAT_MSG_ADDON", "SelfFound", string.format("C1|%.0f|%.0f|C|0|0|0", gap.from, gap.to - 30), "WHISPER", "Bob")
	check(not gap.cov, "sighting without a token ignored")
	Cover(gap.to - 30, "D", 1, "Bob", SF.Token(gap.to - 30, "C", 0))
	check(not (gap.seen and gap.seen["Bob-TestRealm"]), "a real clean heartbeat's token can't back a fake DQ claim")
	Cover(gap.to - 200)
	check(SF.GetStatus() == "UNVERIFIED" and not gap.cov, "last sighting too long before the crash: not recovered")
	Cover(gap.from)
	check(not gap.cov, "sighting from before the last save: not recovered")
	Cover(gap.to + 60)
	check(not gap.cov, "sighting after the gap (current session): not recovered")
	Fire("CHAT_MSG_ADDON", "SelfFound", "C1|12345|12300|C|0|0|0", "WHISPER", "Bob")
	check(not gap.cov, "unknown gap ignored")
	local logBefore = SF.LogCount()

	-- Griefing: strangers (never seen in our guild/group) are ignored entirely
	Cover(gap.to - 30, "C", 0, "Stranger")
	check(not gap.cov and not (gap.seen and gap.seen["Stranger-TestRealm"]), "stranger's sighting ignored")
	Fire("CHAT_MSG_ADDON", "SelfFound", "A1|C|60|999999|0|0|0|0|abcd1234|ROGUE|0", "WHISPER", "Stranger")
	check(not SF.run.witnessedBy["Stranger-TestRealm"], "stranger can't pose as our witness")
	Fire("CHAT_MSG_ADDON", "SelfFound", "H1|C|60|999999|0|0|0|0|abcd1234|ROGUE|0", "WHISPER", "Stranger")
	check(not SelfFoundDB.witness["Stranger-TestRealm"], "heartbeats only accepted from guild/group channels")
	Fire("CHAT_MSG_ADDON", "SelfFound", string.format("C1|%.0f|%.0f|C|0|0|0|%s", gap.from, gap.to - 30, SF.Token(gap.to - 30, "C", 0)), "GUILD", "Bob")
	check(not gap.cov, "sightings only accepted as whispers")

	-- (A token-proven DQ sighting is tested in section 9: it's a real DQ.)

	Cover(gap.to - 30)
	check(gap.cov == gap.to - 30 and gap.by == "Bob-TestRealm", "valid sighting recovers the gap")
	check(SF.LogCount() == logBefore + 1, "recovery logged once")

	-- More witnesses add credibility
	Fire("CHAT_MSG_ADDON", "SelfFound", "H1|C|20|7000|0|0|0|0|abcd1234|DRUID|3|1|1.0.0", "GUILD", "Frank")
	Cover(gap.to - 25, "C", 0, "Frank")
	local support = SF.GapWitnesses(gap)
	check(#support == 2, "second witness adds credibility", #support)
	check(SF.LogCount() == logBefore + 1, "extra confirmations don't add log entries")
	local notes = select(2, SF.VerifyReport(SF.BuildReport()))
	local noted = table.concat(notes, " | ")
	check(noted:find("confirmed by 2 witnesses", 1, true) ~= nil, "Verify shows the confirmations", noted)
	check(SF.GetStatus() == "CLEAN", "recovered crash => CLEAN", select(2, SF.GetStatus()))
	check(select(2, SF.GetStatus()):find("1 crash recovered", 1, true) ~= nil, "CLEAN reason mentions the recovered crash")
	check(SF.cdb.log[#SF.cdb.log].k == "recover", "recovery logged")
	check(SF.GapTotal() == gap.s and SF.OpenGapTotal() == 0, "raw gap total kept, open total cleared")
	local r = SF.BuildReport()
	check(r.gapTotal == gap.s and r.gapOpen == 0, "report carries raw and open gap totals")
	local summary = SF.ReportSummary(r)
	check(summary:find("recovered, confirmed by 2 witnesses", 1, true) ~= nil, "report summary shows the recovery", summary)

	W.sent = {}
	Advance(130)
	local again = false
	for _, s in ipairs(W.sent) do if s[2]:match("^R1|") then again = true end end
	check(not again, "no more recall requests once recovered")

	Advance(30)
	local recovered = Logout()
	Boot(recovered, { played = ServerPlayed() })
	check(SF.integrity.ok and SF.GetStatus() == "CLEAN", "recovery survives a reload")
end

-- Heartbeats every 60s
W.sent = {}
Advance(61)
local beats = 0
for _, s in ipairs(W.sent) do if s[2]:match("^H1|") then beats = beats + 1 end end
check(beats >= 1, "heartbeat at least every 60s", beats)

-- Witness side: answering someone else's recall
do
	local function Beat(who, pl, sid)
		Fire("CHAT_MSG_ADDON", "SelfFound", string.format("H1|C|10|%d|0|0|0|0|abcd1234|MAGE|5%s", pl, sid and ("|" .. sid .. "|1.0.0|tk" .. pl) or ""), "GUILD", who)
	end
	Beat("Dana", 5000, 100)
	Advance(60); Beat("Dana", 5060, 100)
	Advance(60); Beat("Dana", 5120, 200) -- crashed and came back quickly: new session id
	local rec = SelfFoundDB.witness["Dana-TestRealm"]
	check(rec.ends and rec.ends[1] and rec.ends[1].pl == 5060, "session end remembered via session id")
	check(rec.latest.ver == "1.0.0", "addon version recorded")

	W.sent = {}
	Fire("CHAT_MSG_ADDON", "SelfFound", "R1|4000|5090", "GUILD", "Dana")
	check(#W.sent == 1 and W.sent[1][3] == "WHISPER" and W.sent[1][4] == "Dana-TestRealm" and W.sent[1][2]:match("^C1|4000|5060|C|") and W.sent[1][2]:match("|tk5060$"),
		"recall answered with last sighting in range, echoing its token", W.sent[1] and W.sent[1][2])
	W.sent = {}
	Fire("CHAT_MSG_ADDON", "SelfFound", "R1|4000|5090", "GUILD", "Dana")
	check(#W.sent == 0, "repeat recall throttled")
	Fire("CHAT_MSG_ADDON", "SelfFound", "R1|9000|9500", "GUILD", "Dana")
	check(#W.sent == 0, "no answer without a sighting in range")
	Fire("CHAT_MSG_ADDON", "SelfFound", "R1|1|2", "GUILD", "Stranger")
	check(#W.sent == 0, "no answer for players never witnessed")
	Fire("CHAT_MSG_ADDON", "SelfFound", "R1|3000|5090", "WHISPER", "Dana")
	check(#W.sent == 0, "recall requests only accepted from guild/group channels")

	-- Verifying a report that names us as a crash witness
	local danaReport = { char = "Dana-TestRealm", status = "CLEAN", level = 10, played = 5200, stats = { deaths = 0 }, violations = {}, gapTotal = 90, integrity = 1, witnesses = {},
		gaps = { { t = time(), s = 90, from = 4000, to = 5090, cov = 5060, seen = { [SF.playerKey] = { pl = 5060, s = "C", v = 0 } } } } }
	local vnotes = table.concat(select(2, SF.VerifyReport(danaReport)), " | ")
	check(vnotes:find("Your own records confirm", 1, true) ~= nil, "Verify confirms our own listed sighting", vnotes)
	danaReport.gaps[1].seen[SF.playerKey].pl = 5080
	vnotes = table.concat(select(2, SF.VerifyReport(danaReport)), " | ")
	check(vnotes:find("can't confirm", 1, true) ~= nil, "Verify flags a sighting attributed to us that we never made", vnotes)

	-- Reply budget: nobody can make us spam whispers
	for i = 1, 30 do
		Fire("CHAT_MSG_ADDON", "SelfFound", "R1|" .. (4000 + i) .. "|5090", "GUILD", "Dana")
	end
	check(#W.sent <= 20, "recall answers capped per minute", #W.sent)

	-- A crash sighting survives many later sessions (every /reload is one)
	-- for the whole recall week...
	Advance(61)
	local pl = 5200
	for i = 1, 15 do
		Advance(120)
		pl = pl + 120
		Beat("Dana", pl, 300 + i)
	end
	W.sent = {}
	Fire("CHAT_MSG_ADDON", "SelfFound", "R1|3999|5090", "GUILD", "Dana")
	check(#W.sent == 1 and W.sent[1][2]:match("^C1|3999|5060|"), "crash sighting kept through 15 later sessions", W.sent[1] and W.sent[1][2])
	-- ...but not forever
	Jump(9 * 86400)
	Beat("Dana", pl + 60, 999)
	local kept = false
	for _, o in ipairs(SelfFoundDB.witness["Dana-TestRealm"].ends) do
		if o.pl == 5060 then kept = true end
	end
	check(not kept, "session endings older than 8 days are pruned")

	-- Older senders without a session id: long silence marks a new session
	Beat("Erin", 100); Advance(10); Beat("Erin", 110); Advance(10); Beat("Erin", 120)
	check(not SelfFoundDB.witness["Erin-TestRealm"].ends, "no session break within a session")
	Advance(400); Beat("Erin", 130)
	check(SelfFoundDB.witness["Erin-TestRealm"].ends[1].pl == 120, "session end remembered via silence")
end

-- ---------------------------------------------------------------------------
-- 6. Tampering
-- ---------------------------------------------------------------------------

Advance(60)
local good = Logout()
local function Tamper(fn)
	local db = load("return " .. good.db)()
	local cdb = load("return " .. good.cdb)()
	fn(db, cdb)
	local a, b = {}, {}
	WriteLua(db, a, "db"); WriteLua(cdb, b, "cdb")
	return { db = table.concat(a), cdb = table.concat(b) }
end

Boot(Tamper(function(_, cdb) cdb.run.stats.deaths = 0 end), { played = ServerPlayed() })
check(SF.GetStatus() == "DISQUALIFIED" and SF.HasViolation("TAMPER") and not SF.integrity.sealOk, "edited stat detected")

Boot(Tamper(function(_, cdb) cdb.log[2].m = "nothing to see" end), { played = ServerPlayed() })
check(SF.HasViolation("TAMPER") and not SF.integrity.chainOk, "edited log entry detected")

Boot(Tamper(function(_, cdb) table.remove(cdb.log) end), { played = ServerPlayed() })
check(SF.HasViolation("TAMPER"), "deleted log entry detected")

Boot(Tamper(function(_, cdb) cdb.run.gaps = {} ; cdb.run.violations = {} end), { played = ServerPlayed() })
check(SF.HasViolation("TAMPER"), "cleared gaps detected")

Boot(Tamper(function(_, cdb) cdb.seal = nil end), { played = ServerPlayed() })
check(SF.HasViolation("TAMPER"), "missing seal detected")

-- Tamper flag survives further reloads (it's itself sealed now)
local afterTamper = Logout()
Boot(afterTamper, { played = ServerPlayed() })
check(SF.integrity.ok and SF.HasViolation("TAMPER"), "TAMPER persists, file consistent afterwards")

-- Clean file again: deleting the whole char file starts a new run; played
-- time shows it isn't a fresh character.
Boot(Tamper(function(db, cdb) for k in pairs(cdb) do cdb[k] = nil end end), { played = ServerPlayed() })
check(SF.GetStatus() == "UNVERIFIED" and SF.run.lateStart, "wiping saved data => late start UNVERIFIED", select(2, SF.GetStatus()))

-- ---------------------------------------------------------------------------
-- 7. Disqualifications
-- ---------------------------------------------------------------------------

local function Fresh()
	W = { clock = 0, money = 0, level = 1 }
	playedBase = 10
	Boot(nil, { played = 10 })
end

-- Empty trade: not a DQ
Fresh()
Fire("TRADE_SHOW")
Fire("TRADE_ACCEPT_UPDATE", 1, 1)
Fire("UI_INFO_MESSAGE", 0, "Trade complete.")
Fire("TRADE_CLOSED")
Advance(1)
check(SF.GetStatus() == "CLEAN", "empty trade doesn't disqualify")

-- Trade window opened and cancelled: not a DQ
Fire("TRADE_SHOW")
W.trade.target[1] = { "|Hitem:2589|h[Linen]|h", 5 }
Fire("TRADE_TARGET_ITEM_CHANGED", 1)
Fire("TRADE_CLOSED")
Advance(1)
check(SF.GetStatus() == "CLEAN", "cancelled trade doesn't disqualify")

-- Completed trade
Fire("TRADE_SHOW")
Fire("TRADE_ACCEPT_UPDATE", 1, 1)
W.sent = {}
Fire("UI_INFO_MESSAGE", 0, "Trade complete.")
local toldWitnesses = false
for _, s in ipairs(W.sent) do if s[2]:match("^H1|D|") then toldWitnesses = true end end
check(toldWitnesses, "violation broadcast to witnesses immediately (no delay)")
Fire("TRADE_CLOSED")
Advance(1)
check(SF.GetStatus() == "DISQUALIFIED" and SF.HasViolation("TRADE") and SF.run.stats.trades == 1, "completed trade disqualifies")
check(#SF.run.violations == 1, "trade counted once")

-- Trade completing via the TRADE_CLOSED fallback only
Fresh()
W.trade.target = {}
W.trade.targetMoney = 100
Fire("TRADE_SHOW")
Fire("TRADE_ACCEPT_UPDATE", 1, 1)
Fire("TRADE_CLOSED")
Advance(1)
check(SF.HasViolation("TRADE"), "trade fallback (both accepted) disqualifies")

-- Auctions
Fresh()
Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 21)
check(SF.run.stats.ahOpened == 1 and SF.GetStatus() == "CLEAN", "opening AH is fine")
C_AuctionHouse.PlaceBid(1, 5000)
check(SF.HasViolation("AUCTION") and SF.run.stats.ahBuyouts == 1, "buyout disqualifies + counted")
C_AuctionHouse.PlaceBid(2, 100)
check(SF.run.stats.ahBids == 1, "bid counted")
C_AuctionHouse.PostItem({})
check(SF.run.stats.ahListed == 1, "listing counted")
Fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Linen Cloth.")
check(SF.run.stats.ahSold == 1, "sold counted")

-- Mail from a player
Fresh()
W.inbox[1] = { sender = "Bob", canReply = true, money = 1000 }
TakeInboxMoney(1)
check(SF.HasViolation("MAIL") and SF.run.stats.mailFromPlayers == 1, "player mail gold disqualifies")

-- Guild bank / Warband bank
Fresh()
WithdrawGuildBankMoney(100)
check(SF.HasViolation("BANK"), "guild bank withdrawal disqualifies")
Fresh()
C_Bank.WithdrawMoney(Enum.BankType.Character, 100)
check(SF.GetStatus() == "CLEAN", "own bank withdrawal is fine")
C_Bank.WithdrawMoney(Enum.BankType.Account, 100)
check(SF.HasViolation("BANK"), "Warband bank gold withdrawal disqualifies")

-- Late start (installed at level 10)
W = { clock = 0, money = 0, level = 10 }
Boot(nil, { played = 50000 })
check(SF.GetStatus() == "UNVERIFIED" and SF.run.lateStart.level == 10, "late install => UNVERIFIED")

-- ---------------------------------------------------------------------------
-- 8. Log trimming keeps the chain verifiable
-- ---------------------------------------------------------------------------

Fresh()
for i = 1, 4200 do SF.Log("info", "entry " .. i, true) end
check(#SF.cdb.log <= 4000 and SF.LogCount() == 4201, "log trimmed, count kept", #SF.cdb.log .. " / " .. SF.LogCount())
local trimmed = Logout()
Boot(trimmed, { played = ServerPlayed() })
check(SF.integrity.ok, "trimmed log verifies after reload")

-- ---------------------------------------------------------------------------
-- 9. Witness Record (witnessed hours), lost DQ, milestones, preview
-- ---------------------------------------------------------------------------

Fresh()
do
	local function Beat(who, pl, lvl, d, s)
		Fire("CHAT_MSG_ADDON", "SelfFound", string.format("H1|%s|%d|%d|%d|0|0|0|abcd1234|MAGE|0|7|1.0.0|tk", s or "C", lvl or 10, pl, d or 0), "GUILD", who)
	end
	local H = 3600

	-- Witness side: the hours of their /played we heard them in, as ranges
	Beat("Hal", 2 * H + 10)
	Beat("Hal", 2 * H + 70)
	Beat("Hal", 3 * H + 5)
	Beat("Hal", 7 * H + 5)
	local hal = SelfFoundDB.witness["Hal-TestRealm"]
	check(#hal.hours == 2 and hal.hours[1][1] == 2 and hal.hours[1][2] == 3 and hal.hours[2][1] == 7 and hal.hours[2][2] == 7, "witnessed hours stored as ranges")
	check(SF.WitnessSummary(hal).hours == 3, "hours counted")
	local u = SF.MergeSpans({ { { 0, 2 }, { 5, 6 } }, { { 2, 4 } }, { { 8, 8 } } })
	check(#u == 2 and u[1][1] == 0 and u[1][2] == 6 and u[2][1] == 8 and SF.SpanHours(u) == 8, "ranges merge")

	-- Answering: summary + the hours
	Beat("Jo", 100)
	W.sent = {}
	Fire("CHAT_MSG_ADDON", "SelfFound", "Q1|Hal-TestRealm", "GUILD", "Jo")
	Advance(3)
	local w1, v1
	for _, m in ipairs(W.sent) do
		if m[2]:match("^W1|Hal") then w1 = m end
		if m[2]:match("^V1|Hal") then v1 = m end
	end
	check(w1 and v1 and v1[2] == "V1|Hal-TestRealm|2-3,7" and v1[4] == "Jo-TestRealm", "answer carries the witnessed hours", v1 and v1[2])

	-- Asking: combine everyone's hours into the Witness Record
	for _, n in ipairs({ "Kim", "Lu", "Mo", "Ned", "Pat" }) do Beat(n, 100) end
	check(SF.AskWitnesses("Hal-TestRealm"), "asked")
	local function Reply(from, n, pl, spans, sawD, silentN)
		Fire("CHAT_MSG_ADDON", "SelfFound", string.format("W1|Hal-TestRealm|%d|%d|%d|C|10|%d|%d|%d|%d|%d|%d|1.0.0",
			n, time() - 9000, time() - 60, pl, sawD or 0, sawD or 0, silentN or 0, (silentN or 0) * 600, silentN and time() - 100 or 0), "WHISPER", from)
		if spans then
			Fire("CHAT_MSG_ADDON", "SelfFound", "V1|Hal-TestRealm|" .. spans, "WHISPER", from)
		end
	end
	Reply("Jo", 600, 10 * H + 5, "0-9")
	Reply("Kim", 300, 10 * H, "0-4")
	Reply("Lu", 200, 10 * H, "8-10")
	local rec = SF.Profile("Hal-TestRealm").record
	check(rec.total == 11 and rec.covered == 11 and rec.pct == 100 and rec.contributors == 4, "hours combined across witnesses", rec.covered .. "/" .. rec.total .. " by " .. rec.contributors)
	check(rec.verdict == "well" and rec.label == "Well witnessed" and #rec.flags == 0, "well witnessed, no flags", rec.label)

	-- Implausible claims and forged hours don't count
	Reply("Mo", 2, 10 * H, "0-50")        -- claims 51 hours from 2 heartbeats
	check(SF.Profile("Hal-TestRealm").record.contributors == 4, "a witness can't claim more hours than it heard heartbeats")
	Fire("CHAT_MSG_ADDON", "SelfFound", "V1|Hal-TestRealm|0-10", "WHISPER", "Stranger")
	Fire("CHAT_MSG_ADDON", "SelfFound", "V1|Hal-TestRealm|0-10", "WHISPER", "Hal")
	check(SF.queries["Hal-TestRealm"].replies["Stranger-TestRealm"] == nil and SF.queries["Hal-TestRealm"].replies["Hal-TestRealm"] == nil, "hours from strangers or the player themselves ignored")
	local kimHours = SF.SpanHours(SF.queries["Hal-TestRealm"].replies["Kim-TestRealm"].spans)
	Fire("CHAT_MSG_ADDON", "SelfFound", "V1|Hal-TestRealm|5-10", "GUILD", "Kim")
	check(SF.SpanHours(SF.queries["Hal-TestRealm"].replies["Kim-TestRealm"].spans) == kimHours, "hours only accepted as whispers")

	-- Ranges extend in both directions (compact storage)
	Beat("Val", 5 * H)
	Beat("Val", 4 * H)
	Beat("Val", 6 * H)
	local val = SelfFoundDB.witness["Val-TestRealm"].hours
	check(#val == 1 and val[1][1] == 4 and val[1][2] == 6, "adjacent hours merge into one range")

	-- Flags: shown with names, never subtracted
	Fire("CHAT_MSG_ADDON", "SelfFound", string.format("F1|Hal-TestRealm|undq|%d|0|1", time() - 50), "GUILD", "Ned")
	Fire("CHAT_MSG_ADDON", "SelfFound", string.format("F1|Hal-TestRealm|noaddon|%d|720|0", time() - 40), "GUILD", "Pat")
	rec = SF.Profile("Hal-TestRealm").record
	local text = {}
	for _, f in ipairs(rec.flags) do text[#text + 1] = f.who .. " " .. f.text end
	check(#rec.flags == 2 and rec.verdict == "well", "flags listed, verdict unchanged", table.concat(text, "; "))
	check(table.concat(text, "; "):find("Ned saw them disqualified", 1, true) and table.concat(text, "; "):find("Pat saw them online without Earned", 1, true), "flag texts name the witness")

	-- One witness alone
	Beat("Solo", 100)
	for i = 1, 5 do Beat("Rex", i * H) end
	rec = SF.Profile("Rex-TestRealm").record
	check(rec.contributors == 1 and rec.verdict ~= "well" and rec.label:find("all from 1 player", 1, true), "one witness alone: never Well witnessed, and labelled", rec.label)
	check(SF.Profile("Nobody-TestRealm").record.verdict == "none", "no records => not witnessed yet")

	-- UI with a record: profile window, bar, all hovers
	SF.UI.ShowProfile("Hal-TestRealm")
	SF.UI.ShowProfile(SF.playerKey)
	for _, m in ipairs(allMocks) do
		if m.__scripts.OnEnter then m.__scripts.OnEnter(m) end
	end
	check(#W.errors == 0, "Witness Record UI runs", W.errors[1])

	-- Tooltips: your own records of them
	local lines = {}
	local tip = NewMock("GameTooltip")
	tip.GetUnit = function() return "Hal", "mouseover" end
	tip.AddLine = function(_, t) lines[#lines + 1] = t end
	local realTooltip, realUnitName = _G.GameTooltip, _G.UnitName
	_G.GameTooltip = tip
	_G.UnitName = function(unit) if unit == "player" then return "Tester" end return "Hal" end
	W.tooltipPost(tip)
	_G.GameTooltip, _G.UnitName = realTooltip, realUnitName
	check(lines[2] and lines[2]:find("You witnessed 3h of their play", 1, true), "tooltip shows your witnessed hours", table.concat(lines, " / "))

	-- Milestones: witnesses tell us they saw our level-up / death
	W.level = 2
	Fire("PLAYER_LEVEL_UP", 2)
	Fire("CHAT_MSG_ADDON", "SelfFound", "M1|L|2", "WHISPER", "Jo")
	Fire("CHAT_MSG_ADDON", "SelfFound", "M1|L|2", "WHISPER", "Jo")
	Fire("CHAT_MSG_ADDON", "SelfFound", "M1|L|2", "WHISPER", "Kim")
	Fire("CHAT_MSG_ADDON", "SelfFound", "M1|L|5", "WHISPER", "Lu")
	Fire("CHAT_MSG_ADDON", "SelfFound", "M1|L|2", "WHISPER", "Stranger")
	Fire("CHAT_MSG_ADDON", "SelfFound", "M1|L|2", "GUILD", "Lu")
	check(#(SF.run.milestones.L2 or {}) == 2 and SF.run.milestones.L5 == nil, "level-up witnessed by Jo and Kim (no duplicates, wrong level or strangers)")
	local levelEntry
	for _, e in ipairs(SF.cdb.log) do if e.key == "L2" then levelEntry = e end end
	check(levelEntry ~= nil, "level-up log entry is linked to its witnesses")
	Fire("PLAYER_DEAD")
	Fire("CHAT_MSG_ADDON", "SelfFound", "M1|D|" .. SF.run.stats.deaths, "WHISPER", "Jo")
	check(#(SF.run.milestones["D" .. SF.run.stats.deaths] or {}) == 1, "death witnessed")
	-- ...and we tell others when we see theirs
	W.sent = {}
	Beat("Hal", 7 * H + 60, 11)
	Beat("Hal", 7 * H + 90, 11, 1)
	local told = {}
	for _, m in ipairs(W.sent) do if m[2]:match("^M1|") then told[#told + 1] = m[2] .. ">" .. m[4] end end
	check(table.concat(told, " ") == "M1|L|11>Hal-TestRealm M1|D|1>Hal-TestRealm", "we tell players we witnessed their level-up and death", table.concat(told, " "))
	SlashCmdList.SELFFOUND("")
	SF.UI.SelectTab(3)
	check(#W.errors == 0, "log with witnessed milestones renders", W.errors[1])

	-- /sf preview: the DQ alert only; nothing saved or shared
	local sealBefore = SF.cdb.seal
	SlashCmdList.SELFFOUND("preview")
	check(SelfFoundAlert and SelfFoundAlert:IsShown() and SF.cdb.seal == sealBefore and #SF.run.violations == 0, "preview shows the alert, changes nothing")
	SlashCmdList.SELFFOUND("preview")

	-- Reports: no self-reported rating any more
	local r = SF.BuildReport()
	check(r.rating == nil and r.witnessedPct == nil and r.disputes == nil, "reports carry no self-reported rating")

	local saved = Logout()
	Boot(saved, { played = ServerPlayed() })
	check(SF.integrity.ok and #SF.run.milestones.L2 == 2 and #SelfFoundDB.witness["Hal-TestRealm"].hours >= 1, "hours and milestones saved")
end

-- Lost disqualification: a witness echoes a token proving our addon
-- broadcast a DQ before the game closed without saving => real DQ.
Fresh()
do
	Advance(100)
	local saved = Logout()
	Advance(3600)
	Boot(saved, { played = ServerPlayed() })
	local gap = SF.run.gaps[1]
	Fire("CHAT_MSG_ADDON", "SelfFound", "H1|C|12|5000|0|0|0|0|abcd1234|ROGUE|3|7|1.0.0|tk", "GUILD", "Carl")
	local seen = gap.to - 30
	Fire("CHAT_MSG_ADDON", "SelfFound", string.format("C1|%.0f|%.0f|D|1|0|0|%s", gap.from, seen, "deadbeef"), "WHISPER", "Carl")
	check(#SF.run.violations == 0, "unproven DQ claim does nothing")
	Fire("CHAT_MSG_ADDON", "SelfFound", string.format("C1|%.0f|%.0f|D|1|0|0|%s", gap.from, seen, SF.Token(seen, "D", 1)), "WHISPER", "Carl")
	check(SF.HasViolation("LOST") and SF.GetStatus() == "DISQUALIFIED" and #SF.run.violations == 1, "token-proven lost DQ becomes a real DQ")
	-- The whole UI with gaps, sightings and violations present
	SlashCmdList.SELFFOUND("")
	for i = 1, 4 do SF.UI.SelectTab(i) end
	SF.UI.ShowProfile(SF.playerKey)
	for _, m in ipairs(allMocks) do
		if m.__scripts.OnEnter then m.__scripts.OnEnter(m) end
	end
	check(#W.errors == 0, "UI runs with gaps, sightings and violations", W.errors[1])
	check(not gap.cov, "and the gap isn't recovered by it")
	Fire("CHAT_MSG_ADDON", "SelfFound", string.format("C1|%.0f|%.0f|D|1|0|0|%s", gap.from, seen, SF.Token(seen, "D", 1)), "WHISPER", "Carl")
	check(#SF.run.violations == 1, "not counted twice")
end

-- ---------------------------------------------------------------------------
-- 9b. Flags: witnesses catch offenses, sign them, and share them
-- ---------------------------------------------------------------------------

Fresh()
do
	local function Beat(who, s, v, pl, lvl)
		Fire("CHAT_MSG_ADDON", "SelfFound", string.format("H1|%s|%d|%d|0|%d|0|0|abcd1234|MAGE|0|7|1.0.0|tk", s, lvl or 20, pl or 50000, v), "GUILD", who)
	end
	local function Flag(from, target, kind, channel, t)
		Fire("CHAT_MSG_ADDON", "SelfFound", string.format("F1|%s|%s|%d|%d|%d", target, kind, t or (time() - 30), kind == "noaddon" and 900 or 0, kind == "undq" and 1 or 0), channel or "GUILD", from)
	end
	local function Sent(pattern)
		local n = 0
		for _, m in ipairs(W.sent) do if m[2]:match(pattern) then n = n + 1 end end
		return n
	end

	-- Ace gets disqualified; his (tampered) addon later claims clean
	W.sent = {}
	Beat("Ace", "C", 0, 50000)
	Beat("Ace", "D", 1, 50060)
	check(SF.FlagSummary("Ace-TestRealm").count == 0, "an admitted DQ is not a flag")
	Beat("Ace", "C", 0, 50120)
	local sum = SF.FlagSummary("Ace-TestRealm")
	check(sum.count == 1 and sum.mine and sum.red, "DISQUALIFIED then claiming clean => we flag them")
	check(Sent("^F1|Ace%-TestRealm|undq|") == 1, "the flag is announced to guild/group")
	Beat("Ace", "C", 0, 50180)
	check(SF.FlagSummary("Ace-TestRealm").count == 1, "one flag per offense, not per heartbeat")
	Beat("Ace", "D", 2, 50240)
	Beat("Ace", "C", 0, 50300)
	check(SF.FlagSummary("Ace-TestRealm").count == 2, "a new, bigger offense is a new flag")
	check(#SF.FlagsFor("Ace-TestRealm", "D") == 0 and #SF.FlagsFor("Ace-TestRealm", "C") == 2, "flags about DQs are hidden while they admit it")

	-- Same name, genuinely new character (played and level both went down)
	Beat("Neo", "D", 1, 90000, 30)
	Beat("Neo", "C", 0, 100, 1)
	check(SF.FlagSummary("Neo-TestRealm").count == 0, "a new character with the same name isn't flagged")
	-- Same character, saved data wiped after a DQ: played continues
	Beat("Wip", "D", 1, 90000, 30)
	Beat("Wip", "C", 0, 90100, 30)
	check(SF.FlagSummary("Wip-TestRealm").count == 1, "wiping saved data after a DQ is flagged")

	-- Receiving flags from other witnesses
	for _, n in ipairs({ "Bea", "Cy", "Dot" }) do Beat(n, "C", 0) end
	Flag("Bea", "Dex-TestRealm", "noaddon")
	check(SF.FlagSummary("Dex-TestRealm").count == 1, "known witness's flag stored")
	check(SF.FlagLine("Dex-TestRealm", "C") == nil, "one reporter alone: not in tooltips")
	Flag("Bea", "Dex-TestRealm", "noaddon")
	check(SF.FlagSummary("Dex-TestRealm").count == 1, "duplicates ignored")
	Flag("Stranger", "Dex-TestRealm", "undq")
	Flag("Dex", "Dex-TestRealm", "undq")
	Flag("Cy", "Dex-TestRealm", "bogus")
	check(SF.FlagSummary("Dex-TestRealm").count == 1, "strangers, self-flags and unknown kinds ignored")
	Flag("Cy", "Dex-TestRealm", "undq")
	local line = SF.FlagLine("Dex-TestRealm", "C")
	check(line and line:find("Flagged by 2 players: Bea, Cy", 1, true), "2+ independent reporters: tooltip warning", line)

	-- A flagged player whose addon never spoke to us (broadcasting switched
	-- off): the tooltip still shows what other witnesses reported
	Flag("Bea", "Ghost-TestRealm", "noaddon")
	Flag("Cy", "Ghost-TestRealm", "noaddon")
	local lines = {}
	local tip = NewMock("GameTooltip")
	tip.GetUnit = function() return "Ghost", "mouseover" end
	tip.AddLine = function(_, t) lines[#lines + 1] = t end
	local realTooltip, realUnitName = _G.GameTooltip, _G.UnitName
	_G.GameTooltip = tip
	_G.UnitName = function(unit) if unit == "player" then return "Tester" end return "Ghost" end
	W.tooltipPost(tip)
	_G.GameTooltip, _G.UnitName = realTooltip, realUnitName
	check(#lines == 2 and lines[1]:find("no status from their addon", 1, true) and lines[2]:find("Flagged by 2 players", 1, true),
		"tooltip shows others' flags even for a player whose addon never spoke", table.concat(lines, " / "))

	-- Flags about me: stored, told, shown
	W.chat = {}
	Flag("Dot", SF.playerKey, "noaddon", "WHISPER")
	check(SF.FlagSummary(SF.playerKey).count == 1 and table.concat(W.chat, " "):find("Dot flagged you", 1, true), "you're told when someone flags you")
	check(SF.FlagLine(SF.playerKey, nil, true) ~= nil, "your own flags show in your UI even with one reporter")

	-- Long silence becomes a flag; short silence doesn't
	W.roster = { { name = "Sil-TestRealm", online = true }, { name = "Brief-TestRealm", online = true } }
	Beat("Sil", "C", 0)
	Beat("Brief", "C", 0)
	Advance(360)                          -- both quiet 6 minutes (we've listened 5+)
	Beat("Brief", "C", 0)                 -- Brief's addon speaks again after ~6m
	Advance(900)                          -- Sil stays quiet 20+ minutes
	Beat("Sil", "C", 0)
	check(SF.FlagSummary("Sil-TestRealm").count == 1 and SF.FlagsFor("Sil-TestRealm")[1].k == "noaddon", "10+ minutes online without Earned => flag")
	check(SF.FlagSummary("Brief-TestRealm").count == 0, "a short silence is only a note, not a flag")

	-- Answering a question hands over our own flags
	W.sent = {}
	Fire("CHAT_MSG_ADDON", "SelfFound", "Q1|Ace-TestRealm", "GUILD", "Bea")
	Advance(3)
	check(Sent("^F1|Ace%-TestRealm|undq|") == 2, "answers include our flags about them")

	-- Checking Dex's shared run: claims + the flags, in one profile
	local dexRun = { char = "Dex-TestRealm", status = "CLEAN", level = 20, played = 50000, stats = { deaths = 0 }, violations = {}, gapTotal = 0, integrity = 1, witnesses = {}, income = {}, generated = time(), addon = "1.0.0" }
	SF.UI.ShowProfile("Dex-TestRealm", false, dexRun)
	local dexFlags = SF.Profile("Dex-TestRealm").record.flags
	check(SelfFoundProfileFrame:IsShown() and #dexFlags == 2, "a checked run shows next to the flags about them", #W.errors == 0 and "" or W.errors[1])

	-- Flags in the profile, with names
	local rec = SF.Profile("Dex-TestRealm").record
	check(#rec.flags == 2 and rec.reporters == 2, "profile lists the flags with names")
	SF.UI.ShowProfile("Ace-TestRealm")
	SF.UI.ShowProfile(SF.playerKey)
	SlashCmdList.SELFFOUND("")
	for i = 1, 4 do SF.UI.SelectTab(i) end
	SlashCmdList.SELFFOUND("status")
	for _, m in ipairs(allMocks) do
		if m.__scripts.OnEnter then m.__scripts.OnEnter(m) end
	end
	check(#W.errors == 0, "UI with flags runs", W.errors[1])

	-- Re-announced when the flagged player is around again (once per session)
	local saved = Logout()
	Boot(saved, { played = ServerPlayed() })
	check(SF.FlagSummary("Ace-TestRealm").count == 2, "flags saved")
	W.sent = {}
	Beat("Ace", "C", 0, 50400)
	check(Sent("^F1|Ace%-TestRealm|") == 2, "our flags re-announced when they're online")
	Beat("Ace", "C", 0, 50460)
	check(Sent("^F1|Ace%-TestRealm|") == 2, "...once per session")
end

-- ---------------------------------------------------------------------------
-- 10. Chat-command (/run) attacks
-- ---------------------------------------------------------------------------

Fresh()
do
	check(_G.SelfFound == nil, "no global handle to the addon's internals")

	-- Get disqualified, relog, then try to erase it from chat
	C_AuctionHouse.PostItem({})
	check(SF.GetStatus() == "DISQUALIFIED", "setup: disqualified")
	Advance(30)
	local saved = Logout()
	check(saved.cdb:find('"key"', 1, true) ~= nil, "secret key is saved with the character")
	Boot(saved, { played = ServerPlayed() })
	check(type(SF.cdb.key) == "string" and SF.cdb.key == SelfFoundCharDB.key, "secret key kept across sessions")

	SelfFoundCharDB.run.violations = {}   -- /run SelfFoundCharDB.run.violations = {}
	SelfFoundCharDB.run.gaps = {}
	SelfFoundCharDB.log = {}
	Advance(30)                           -- the addon's regular saves run in between
	check(SF.GetStatus() == "DISQUALIFIED", "/run edit has no effect in-session")
	saved = Logout()
	Boot(saved, { played = ServerPlayed() })
	check(SF.GetStatus() == "DISQUALIFIED" and SF.integrity.ok, "/run edit has no effect after relog")

	-- /run edit, then disconnect before the addon's next save: the edited
	-- copy gets saved, but it no longer matches the seal
	SelfFoundCharDB.run.violations = {}
	saved = Disconnect()
	Boot(saved, { played = ServerPlayed() })
	check(SF.HasViolation("TAMPER") and SF.GetStatus() == "DISQUALIFIED", "/run edit + disconnect is caught as tampering")

	-- Disconnects (the game may save without PLAYER_LOGOUT)
	Fresh()
	Advance(100)
	C_AuctionHouse.PostItem({})           -- a violation right before the disconnect...
	saved = Disconnect()
	Advance(60)                           -- server keeps the character in the world
	Boot(saved, { played = ServerPlayed() })
	check(SF.HasViolation("AUCTION"), "...is saved even if PLAYER_LOGOUT never fires")

	Fresh()
	Advance(100)
	saved = Disconnect()                  -- last 15s save was up to 10s ago
	Advance(60)                           -- idle linger after the disconnect
	Boot(saved, { played = ServerPlayed() })
	check(SF.GetStatus() == "CLEAN" and #SF.run.gaps == 0 and SF.integrity.ok, "idle time after a disconnect is forgiven", select(2, SF.GetStatus()))
	check(SF.cdb.log[#SF.cdb.log].m:find("idle time after a disconnect", 1, true) ~= nil, "forgiven idle time is logged")

	Advance(100)
	saved = Disconnect()
	Advance(60)
	W.money = W.money + 5000              -- received gold while the addon wasn't looking
	Boot(saved, { played = ServerPlayed() })
	check(SF.GetStatus() == "UNVERIFIED", "short gap with changed gold is not forgiven")

	Fresh()
	Advance(100)
	saved = Disconnect()
	Advance(60)
	W.bags[0][2] = { "|Hitem:117::|h[Tough Jerky]|h", 1 } -- received an item
	Boot(saved, { played = ServerPlayed() })
	check(SF.GetStatus() == "UNVERIFIED", "short gap with changed bags is not forgiven")
	W.bags[0][2] = nil

	Fresh()
	Advance(100)
	saved = Disconnect()
	Advance(400)                          -- too long to be a linger, even if idle
	Boot(saved, { played = ServerPlayed() })
	check(SF.GetStatus() == "UNVERIFIED", "long gap is never forgiven")

	-- Short gaps: below the old 45s tolerance, a changed character still counts
	Fresh()
	Advance(100)
	saved = Logout()
	Advance(25)                           -- a quick session without the addon...
	W.money = W.money + 5000              -- ...taking a pre-arranged trade
	Boot(saved, { played = ServerPlayed() })
	check(SF.GetStatus() == "UNVERIFIED", "25s gap with changed gold counts")
	Fresh()
	Advance(100)
	saved = Logout()
	Advance(25)
	Boot(saved, { played = ServerPlayed() })
	check(SF.GetStatus() == "CLEAN" and #SF.run.gaps == 0, "25s gap with nothing changed is ignored")

	-- Looting right before a disconnect: saved within ~1s, so still forgiven
	Fresh()
	Advance(102)                          -- just after a regular 15s save (ticks at 15, 30, ... 105)
	W.money = W.money + 50
	Fire("PLAYER_MONEY")
	Advance(2)                            -- only the ~1s save-on-change can capture this
	saved = Disconnect()
	Advance(60)
	Boot(saved, { played = ServerPlayed() })
	check(SF.GetStatus() == "CLEAN", "change just before a disconnect doesn't block the grace", select(2, SF.GetStatus()))

	-- Bank watch
	Fresh()
	_G.BANK_CONTAINER = -1
	W.bags[-1] = { [1] = { "|Hitem:2589::|h[Linen Cloth]|h", 10 } }
	local function OpenBank() Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 8); Advance(6) end
	local function CloseBank() Fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 8); Advance(1) end
	OpenBank()
	check(SF.run.bank and SF.run.bank.n == 1, "bank remembered on first visit")
	W.bags[-1][2] = { "|Hitem:117::|h[Tough Jerky]|h", 5 } -- deposit while the addon watches
	Fire("BAG_UPDATE_DELAYED")
	CloseBank()
	Advance(30)
	saved = Logout()
	Boot(saved, { played = ServerPlayed() })
	OpenBank()
	check(SF.GetStatus() == "CLEAN" and #SF.run.unwatched == 0, "own bank changes with the addon running are fine")
	W.bags[-1][1], W.bags[-1][3] = nil, { "|Hitem:2589::|h[Linen Cloth]|h", 10 } -- sorting moved a stack
	Fire("BAG_UPDATE_DELAYED")
	CloseBank()
	Advance(30)
	saved = Logout()
	W.bags[-1][4] = { "|Hitem:6948::|h[Hearthstone]|h", 1 } -- stashed while the addon was off
	Boot(saved, { played = ServerPlayed() })
	check(SF.GetStatus() == "CLEAN", "bank change isn't visible until the bank is opened")
	OpenBank()
	check(SF.GetStatus() == "UNVERIFIED" and select(2, SF.GetStatus()):find("bank changed", 1, true), "bank changed while the addon was off => UNVERIFIED", select(2, SF.GetStatus()))
	CloseBank()
	W.bags[-1] = nil
	_G.BANK_CONTAINER = nil

	-- Faking the first /played response to hide time played without the addon
	Fresh()
	Advance(60)
	saved = Logout()
	local expected = ServerPlayed()
	Advance(3600)                         -- an hour played with the addon disabled
	Boot(saved, {})                       -- the real /played answer is still in flight...
	Fire("TIME_PLAYED_MSG", expected + 4, expected + 4) -- ...and a faked one arrives first
	check(SF.GetStatus() == "CLEAN", "setup: faked /played hid the gap at first")
	Advance(30)
	Fire("TIME_PLAYED_MSG", ServerPlayed(), ServerPlayed()) -- the next real one
	check(SF.GetStatus() == "UNVERIFIED" and SF.OpenGapTotal() >= 3500, "next real /played exposes the hidden time", SF.OpenGapTotal())

	-- ...while ordinary /played checks never create gaps
	Fresh()
	for _ = 1, 5 do
		Advance(600)
		Fire("TIME_PLAYED_MSG", ServerPlayed(), ServerPlayed())
	end
	check(#SF.run.gaps == 0 and SF.GetStatus() == "CLEAN", "normal /played during play doesn't create gaps")
end

-- ---------------------------------------------------------------------------
-- 11. Profiles: silence detection, asking witnesses, the profile window
-- ---------------------------------------------------------------------------

Fresh()
do
	local function Beat(who)
		Fire("CHAT_MSG_ADDON", "SelfFound", "H1|C|12|5000|0|0|0|0|abcd1234|ROGUE|3|7|1.0.0|tk", "GUILD", who)
	end
	local function Online(name, online)
		for _, m in ipairs(W.roster) do
			if m.name == name then m.online = online return end
		end
		table.insert(W.roster, { name = name, online = online })
	end

	-- Silence: Gus runs Earned (known), is online, but his addon goes quiet
	Beat("Gus")
	Online("Gus-TestRealm", true)
	local gus = SelfFoundDB.witness["Gus-TestRealm"]
	Advance(250)
	check(not gus.silentOpen, "no silence judged before we've listened for 5 minutes")
	Advance(200)
	check(gus.silentOpen ~= nil and SF.WitnessSummary(gus).silentNow, "online 5+ minutes without a heartbeat => online without Earned")
	Beat("Gus")
	check(not gus.silentOpen and gus.silentN == 1 and gus.silent[1].t > gus.silent[1].f, "heartbeat ends the silent period (recorded with duration)")

	-- Heartbeats keep coming: never silent
	for _ = 1, 10 do
		Advance(60)
		Beat("Gus")
	end
	check(gus.silentN == 1 and not gus.silentOpen, "regular heartbeats never count as silence")

	-- Silent, then goes offline: period closes where we last saw them
	Advance(400)
	check(gus.silentOpen ~= nil, "silent again")
	Online("Gus-TestRealm", false)
	Advance(60)
	check(not gus.silentOpen and gus.silentN == 2, "going offline closes the period")

	-- Our own messaging lockdown: silence can't be judged
	Online("Gus-TestRealm", true)
	W.lockdown = true
	Advance(600)
	check(not gus.silentOpen, "no silence judged while our messaging is locked down")
	W.lockdown = false
	Beat("Gus")

	-- Players who never ran Earned aren't flagged
	Online("Nobody-TestRealm", true)
	Advance(600)
	check(SelfFoundDB.witness["Nobody-TestRealm"] == nil, "non-Earned players are never flagged")

	-- Tooltip shows what you saw
	local lines = {}
	local tip = NewMock("GameTooltip")
	tip.GetUnit = function() return "Gus", "mouseover" end
	tip.AddLine = function(_, text) lines[#lines + 1] = text end
	local realTooltip, realUnitName = _G.GameTooltip, _G.UnitName
	_G.GameTooltip = tip
	_G.UnitName = function(u) if u == "player" then return "Tester" end return "Gus" end
	W.tooltipPost(tip)
	_G.GameTooltip, _G.UnitName = realTooltip, realUnitName
	check(table.concat(lines, " / "):find("without Earned", 1, true), "tooltip warns about time online without Earned", table.concat(lines, " / "))

	-- Asking witnesses: answering others
	Beat("Carl")
	W.sent = {}
	Fire("CHAT_MSG_ADDON", "SelfFound", "Q1|Gus-TestRealm", "GUILD", "Carl")
	Advance(3) -- replies are spread over a couple of seconds
	local reply
	for _, m in ipairs(W.sent) do if m[2]:match("^W1|") then reply = m end end
	check(reply and reply[3] == "WHISPER" and reply[4] == "Carl-TestRealm" and reply[2]:match("^W1|Gus%-TestRealm|%d+|"), "answers a question about a player we witnessed", reply and reply[2])
	local fields = {}
	for f in ((reply and reply[2] or "") .. "|"):gmatch("(.-)|") do fields[#fields + 1] = f end
	check(tonumber(fields[11]) and tonumber(fields[11]) >= 2 and tonumber(fields[12]) > 0, "reply includes the silent periods", reply and reply[2])
	W.sent = {}
	Fire("CHAT_MSG_ADDON", "SelfFound", "Q1|Gus-TestRealm", "GUILD", "Carl")
	Advance(3)
	check(#W.sent == 0, "repeat questions throttled")
	Fire("CHAT_MSG_ADDON", "SelfFound", "Q1|Nobody-TestRealm", "GUILD", "Dana")
	Advance(3)
	check(#W.sent == 0, "no answer without records")
	Fire("CHAT_MSG_ADDON", "SelfFound", "Q1|Gus-TestRealm", "WHISPER", "Dana")
	Advance(3)
	check(#W.sent == 0, "questions only accepted from guild/group channels")

	-- Asking witnesses: our question and their replies
	check(SF.AskWitnesses("Gus-TestRealm"), "ask sends a question")
	check(W.sent[1] and W.sent[1][2] == "Q1|Gus-TestRealm" and W.sent[1][3] == "GUILD", "question goes to guild")
	check(not SF.AskWitnesses("Gus-TestRealm"), "own questions throttled")
	local function W1(from, target, s, sawD, silentN, channel)
		Fire("CHAT_MSG_ADDON", "SelfFound", string.format("W1|%s|40|%d|%d|%s|12|5000|%d|%d|%d|600|%d|1.0.0", target, time() - 9000, time() - 60, s, sawD, sawD, silentN, time() - 100), channel or "WHISPER", from)
	end
	W1("Carl", "Gus-TestRealm", "C", 0, 0)
	Beat("Dana")
	W1("Dana", "Gus-TestRealm", "D", 1, 1)
	W1("Stranger", "Gus-TestRealm", "C", 0, 0)
	W1("Gus", "Gus-TestRealm", "C", 0, 0)
	W1("Carl", "Else-TestRealm", "C", 0, 0)
	W1("Dana", "Gus-TestRealm", "C", 0, 0, "GUILD")
	local p = SF.Profile("Gus-TestRealm")
	Fire("CHAT_MSG_ADDON", "SelfFound", string.format("F1|Gus-TestRealm|undq|%d|0|1", time() - 50), "WHISPER", "Dana")
	Fire("CHAT_MSG_ADDON", "SelfFound", string.format("F1|Gus-TestRealm|noaddon|%d|900|0", time() - 40), "WHISPER", "Dana")
	p = SF.Profile("Gus-TestRealm")
	local fromDana = 0
	for _, f in ipairs(p.record.flags) do if f.who == "Dana" then fromDana = fromDana + 1 end end
	check(#p.others == 2 and fromDana == 2, "replies counted; Dana's flags listed with her name", #p.record.flags)
	check(p.others[1] and SF.queries["Gus-TestRealm"].replies["Stranger-TestRealm"] == nil, "strangers' replies ignored")
	check(SF.queries["Gus-TestRealm"].replies["Gus-TestRealm"] == nil, "nobody vouches for themselves")
	check(SF.queries["Else-TestRealm"] == nil, "replies to questions we never asked are ignored")
	Advance(200)
	W1("Erin", "Gus-TestRealm", "C", 0, 0)
	check(SF.queries["Gus-TestRealm"].replies["Erin-TestRealm"] == nil, "late replies ignored")

	-- Names
	check(SF.ResolveName("gus") == "Gus-TestRealm" and SF.ResolveName("zed") == "Zed-TestRealm" and SF.ResolveName("tester") == SF.playerKey, "typed names resolve (case-insensitive)")

	-- Profile window, search, clicks, /sf check
	SlashCmdList.SELFFOUND("check gus")
	check(SelfFoundProfileFrame and SelfFoundProfileFrame:IsShown(), "/sf check opens the profile window")
	SF.UI.ShowProfile(SF.playerKey)
	SF.UI.ShowProfile("Zed-TestRealm", true)
	SlashCmdList.SELFFOUND("")
	SF.UI.SelectTab(4)
	local search
	for _, m in ipairs(allMocks) do
		if m.__kind == "EditBox" and m.__scripts.OnTextChanged then search = m end
	end
	check(search ~= nil, "search box exists")
	search:SetText("gu")
	search.__scripts.OnTextChanged(search, true)
	search.__scripts.OnEnterPressed(search)
	check(SelfFoundProfileFrame:IsShown(), "search + Enter opens a profile")
	for _, m in ipairs(allMocks) do
		if m.__scripts.OnEnter then m.__scripts.OnEnter(m) end
		if m.__scripts.OnLeave then m.__scripts.OnLeave(m) end
	end
	for _, m in ipairs(allMocks) do
		if m.__kind == "row" and m.__scripts.OnClick then m.__scripts.OnClick(m) end
	end
	check(#W.errors == 0, "profile UI paths run without errors", W.errors[1])

	-- Survives saving (no frames or functions in saved data)
	local saved = Logout()
	Boot(saved, { played = ServerPlayed() })
	check(SelfFoundDB.witness["Gus-TestRealm"].silentN >= 2 and not SelfFoundDB.witness["Gus-TestRealm"].silentOpen, "silent periods saved (open one closed at logout)")
end

print(string.format("\n%d passed, %d failed, %d errors", pass, fail, #W.errors))
FAILURES = fail + #W.errors
