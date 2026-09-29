-- Test harness: loads the addon into a stubbed WoW environment and simulates
-- sessions (login, /reload, crash, tampering, rule violations, UI). Run via
-- `npm test`. Globals ADDON_DIR, TOC_SOURCE and REF_SOURCE
-- are set by run.js.

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
	_G.C_AddOns = { GetAddOnMetadata = function(addon, field) if addon == "SelfFound" and field == "Version" then return W.tocVersion or TOC_VERSION end end }
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
		InChatMessagingLockdown = function() return false end,
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
			if item then return { hyperlink = item[1], stackCount = item[2], hasNoValue = false } end
		end,
		UseContainerItem = function() end,
		PickupContainerItem = function() end,
		SplitContainerItem = function() end,
		ContainerIDToInventoryID = function(bag) return 30 + bag end,
	}
	W.bags = W.bags or { [0] = { [1] = { "|Hitem:2589::|h[Linen Cloth]|h", 5 } } }
	_G.GetInventoryItemLink = function() return nil end
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
		chunk("SelfFound", SF)
	end
	if opts.coreOnly then return SF end
	W.loadClock = W.clock
	Fire("ADDON_LOADED", "SelfFound")
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
for _, m in ipairs(allMocks) do
	if m.__text == "Verify" and m.__scripts.OnClick then m.__scripts.OnClick(m) end
end
check(#W.errors == 0, "verify button runs", W.errors[1])

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

	-- A witness proving our addon broadcast a DQ before the crash (valid
	-- token): recorded under their name as a dispute, not enforced
	Cover(gap.to - 30, "D", 1, "Carl")
	check(not gap.cov and SF.GetStatus() == "UNVERIFIED" and #SF.run.violations == 0, "proven DQ sighting blocks recovery, doesn't disqualify")
	check(gap.seen["Carl-TestRealm"] and gap.seen["Carl-TestRealm"].s == "D", "the claim is recorded under the witness's name")
	check(SF.LogCount() == logBefore, "witness claims never go into your log")
	local _, dispute = SF.GapWitnesses(gap)
	check(#dispute == 1 and dispute[1] == "Carl-TestRealm", "claim counted as a dispute")
	check(select(4, SF.WitnessRating()) == 1 and SF.RatingText(0, 1):find("(1 disputed)", 1, true), "dispute shown beside the witness rating")

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
	check(noted:find("confirmed by 2 witnesses", 1, true) and noted:find("1 witness claims a violation", 1, true), "Verify shows confirmations and claims", noted)
	check(SF.GetStatus() == "CLEAN", "recovered crash => CLEAN", select(2, SF.GetStatus()))
	check(select(2, SF.GetStatus()):find("1 crash recovered", 1, true) ~= nil, "CLEAN reason mentions the recovered crash")
	check(SF.cdb.log[#SF.cdb.log].k == "recover", "recovery logged")
	check(SF.GapTotal() == gap.s and SF.OpenGapTotal() == 0, "raw gap total kept, open total cleared")
	local r = SF.BuildReport()
	check(r.gapTotal == gap.s and r.gapOpen == 0, "report carries raw and open gap totals")
	local summary = SF.ReportSummary(r)
	check(summary:find("recovered, confirmed by 2 witnesses", 1, true) ~= nil and summary:find("1 witness claims a violation", 1, true) ~= nil, "report summary shows recovery and claims", summary)

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
		Fire("CHAT_MSG_ADDON", "SelfFound", string.format("H1|C|10|%d|0|0|0|0|abcd1234|MAGE|5%s", pl, sid and ("|" .. sid .. "|1.0.0|1|20|0|tk" .. pl) or ""), "GUILD", who)
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
-- 9. Witness rating
-- ---------------------------------------------------------------------------

Fresh()
do
	local function Body(rt, wp, dp)
		return string.format("C|5|100|0|0|0|0|abcd1234|MAGE|0|1|1.0.0%s", rt and string.format("|%d|%d|%d", rt, wp, dp) or "")
	end
	local function Known(name, ...) Fire("CHAT_MSG_ADDON", "SelfFound", "H1|" .. Body(...), "GUILD", name) end
	local function Ack(name) Fire("CHAT_MSG_ADDON", "SelfFound", "A1|" .. Body(), "WHISPER", name) end

	local tier, pct = SF.WitnessRating()
	check(tier == 0 and pct == 0, "new run is Unwitnessed")

	local names = { "Wa", "Wb", "Wc", "Wd", "We" }
	for _, n in ipairs(names) do Known(n) end
	for _ = 1, 8 do
		for _, n in ipairs(names) do Ack(n) end
		Advance(900)
	end
	tier, pct = SF.WitnessRating()
	check(tier == 3 and pct >= 75, "fully witnessed by 5 players => Heavily witnessed", tier .. " " .. pct)

	Ack("Stranger")
	check(select(3, SF.WitnessRating()) == 5, "strangers can't count as witnesses")

	Advance(900 * 8) -- solo play
	tier, pct = SF.WitnessRating()
	check(tier == 2 and pct >= 40 and pct < 75, "half witnessed => Well witnessed", tier .. " " .. pct)
	Advance(900 * 14)
	tier, pct = SF.WitnessRating()
	check(tier == 1 and pct >= 10 and pct < 40, "mostly solo => Lightly witnessed", tier .. " " .. pct)

	-- Heartbeats carry tier, witnessed %, disputes (fields 13-15)
	W.sent = {}
	SF.Broadcast(true)
	local fields
	for _, s in ipairs(W.sent) do
		if s[2]:match("^H1|") then fields = {} for f in (s[2] .. "|"):gmatch("(.-)|") do fields[#fields + 1] = f end end
	end
	check(fields and tonumber(fields[14]) == tier and tonumber(fields[15]) == pct and tonumber(fields[16]) == 0, "heartbeat carries the rating", fields and table.concat(fields, ","))

	-- Other players' ratings: recorded and shown in tooltips
	Known("Rated", 2, 55, 1)
	local rec = SelfFoundDB.witness["Rated-TestRealm"]
	check(rec.latest.rt == 2 and rec.latest.wp == 55 and rec.latest.dp == 1, "others' rating recorded")
	local lines = {}
	local tip = NewMock("GameTooltip")
	tip.GetUnit = function() return "Rated", "mouseover" end
	tip.AddLine = function(_, text) lines[#lines + 1] = text end
	local realTooltip, realUnitName = _G.GameTooltip, _G.UnitName
	_G.GameTooltip = tip
	_G.UnitName = function(u) if u == "player" then return "Tester" end return "Rated" end
	W.tooltipPost(tip)
	_G.GameTooltip, _G.UnitName = realTooltip, realUnitName
	check(#lines == 3 and lines[1]:find("CLEAN", 1, true) and lines[1]:find("level 5", 1, true) and lines[2] == "Well witnessed" and lines[3] == "1 dispute",
		"tooltip: status, rating and disputes on separate lines", table.concat(lines, " / "))

	-- Own tooltip, no disputes: two lines
	lines = {}
	tip.GetUnit = function() return "Tester", "player" end
	_G.GameTooltip = tip
	W.tooltipPost(tip)
	_G.GameTooltip = realTooltip
	check(#lines == 2 and lines[2] == "Lightly witnessed", "own tooltip: status and rating, no dispute line", table.concat(lines, " / "))

	-- Reports and Verify
	local r = SF.BuildReport()
	check(r.rating == tier and r.witnessedPct == pct and r.disputes == 0, "report carries the rating")
	check(SF.ReportSummary(r):find("Witness rating: Lightly witnessed", 1, true) ~= nil, "report summary shows the rating")
	check(table.concat(select(2, SF.VerifyReport(r)), " "):find("Witness rating: Lightly witnessed", 1, true) ~= nil, "Verify shows the rating")

	-- /sf preview: display-only sample dispute + alert, never shared or saved
	local sealBefore = SF.cdb.seal
	SlashCmdList.SELFFOUND("preview")
	check(select(4, SF.WitnessRating()) == 1, "preview shows a sample dispute")
	check(select(4, SF.WitnessRating(true)) == 0 and SF.BuildReport().disputes == 0, "preview dispute never reaches reports")
	W.sent = {}
	SF.Broadcast(true)
	local previewLeak = false
	for _, s in ipairs(W.sent) do
		if s[2]:match("^H1|") then
			local f = {}
			for x in (s[2] .. "|"):gmatch("(.-)|") do f[#f + 1] = x end
			if f[16] ~= "0" then previewLeak = true end -- body field 15 = disputes
		end
	end
	check(not previewLeak, "preview dispute never sent in heartbeats")
	check(SF.cdb.seal == sealBefore and SF.GetStatus() ~= "DISQUALIFIED" and #SF.run.violations == 0, "preview changes no saved data")
	check(SelfFoundAlert and SelfFoundAlert:IsShown(), "preview shows the DQ alert")
	SlashCmdList.SELFFOUND("preview")
	check(SF.preview == nil and select(4, SF.WitnessRating()) == 0, "preview toggles off")

	-- Sealed and persisted
	local saved = Logout()
	Boot(saved, { played = ServerPlayed() })
	check(SF.integrity.ok and SF.run.coverage.n == 8, "coverage survives a reload", SF.run.coverage.n)

	-- UI paths with a rating present
	SlashCmdList.SELFFOUND("")
	for i = 1, 4 do SF.UI.SelectTab(i) end
	SlashCmdList.SELFFOUND("status")
	for _, m in ipairs(allMocks) do
		if m.__scripts.OnEnter then m.__scripts.OnEnter(m) end
	end
	check(#W.errors == 0, "rating UI paths run without errors", W.errors[1])

	-- One friend witnessing everything isn't enough for a high rating
	Fresh()
	Known("Buddy")
	for _ = 1, 8 do Ack("Buddy"); Advance(900) end
	tier, pct = SF.WitnessRating()
	check(tier == 1 and pct >= 75, "fully witnessed by a single player => only Lightly witnessed", tier .. " " .. pct)
	for _, n in ipairs({ "Pa", "Pb" }) do Known(n); Ack(n) end
	check(SF.WitnessRating() == 2, "three witnesses => Well witnessed")
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
	check(SelfFoundCharDB.key == nil and type(SF.cdb.key) == "string", "secret key not reachable from chat during play")

	-- TEMPORARY /sf preview clean: display only, never shared
	SlashCmdList.SELFFOUND("preview clean")
	check(SF.GetStatus() == "CLEAN" and SF.WitnessRating() == 3, "clean preview shows CLEAN + Heavily witnessed")
	check(SF.GetStatus(true) == "DISQUALIFIED" and SF.BuildReport().status == "DISQUALIFIED" and SF.BuildReport().rating == 0, "clean preview never reaches reports")
	W.sent = {}
	SF.Broadcast(true)
	check(W.sent[1] and W.sent[1][2]:match("^H1|D|"), "clean preview never reaches heartbeats")
	SlashCmdList.SELFFOUND("")
	for i = 1, 4 do SF.UI.SelectTab(i) end
	check(#W.errors == 0, "clean preview UI runs", W.errors[1])
	SlashCmdList.SELFFOUND("preview clean")
	check(SF.preview == nil and SF.GetStatus() == "DISQUALIFIED", "clean preview toggles off")

	SelfFoundCharDB.run.violations = {}   -- /run SelfFoundCharDB.run.violations = {}
	SelfFoundCharDB.run.gaps = {}
	SelfFoundCharDB.log = {}
	Advance(30)                           -- the addon's regular saves run in between
	check(SF.GetStatus() == "DISQUALIFIED", "/run edit has no effect in-session")
	saved = Logout()
	Boot(saved, { played = ServerPlayed() })
	check(SF.GetStatus() == "DISQUALIFIED" and SF.integrity.ok, "/run edit has no effect after relog")

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

print(string.format("\n%d passed, %d failed, %d errors", pass, fail, #W.errors))
FAILURES = fail + #W.errors
