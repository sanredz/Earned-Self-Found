-- Self Found - Tracker
-- Records what happens during the run: where gold comes from and goes,
-- items looted/destroyed, kills, quests, deaths, levels, net worth, and
-- play time (compared against the server's /played to catch the addon
-- having been disabled).

local ADDON, SF = ...

local GAP_TOLERANCE = 45       -- seconds of unexplained /played drift we ignore
local LATE_START_PLAYED = 300  -- runs started after this much /played are Unverified
local TRACK_INTERVAL = 15

-- ---------------------------------------------------------------------------
-- Which NPC/UI interaction is open. Used to attribute gold changes, and by
-- Rules for warnings. Fed by the modern interaction manager and the classic
-- per-frame events, whichever this client fires.
-- ---------------------------------------------------------------------------

local open, closedAt = {}, {}

function SF.IsOpen(kind, grace)
	if open[kind] then
		return true
	end
	return grace ~= nil and closedAt[kind] ~= nil and GetTime() - closedAt[kind] <= grace
end

local function Open(kind)
	if open[kind] then
		return
	end
	open[kind] = true
	SF.Fire("InteractionOpened", kind)
end

local function Close(kind)
	if not open[kind] then
		return
	end
	open[kind] = nil
	closedAt[kind] = GetTime()
	SF.Fire("InteractionClosed", kind)
end

local INTERACTIONS = {
	TradePartner = { "trade", 1 },
	QuestGiver = { "quest", 4 },
	Merchant = { "merchant", 5 },
	TaxiNode = { "taxi", 6 },
	Trainer = { "trainer", 7 },
	Banker = { "bank", 8 },
	GuildBanker = { "guildbank", 10 },
	Vendor = { "merchant", 12 },
	MailInfo = { "mail", 17 },
	Auctioneer = { "auction", 21 },
}
local interactionKind = {}
for name, info in pairs(INTERACTIONS) do
	local id = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType[name] or info[2]
	interactionKind[id] = info[1]
end

SF.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(interactionType)
	local kind = interactionKind[SF.Safe(interactionType)]
	if kind then
		Open(kind)
	end
end)

SF.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(interactionType)
	local kind = interactionKind[SF.Safe(interactionType)]
	if kind then
		Close(kind)
	end
end)

local LEGACY_EVENTS = {
	merchant = { "MERCHANT_SHOW", "MERCHANT_CLOSED" },
	mail = { "MAIL_SHOW", "MAIL_CLOSED" },
	auction = { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" },
	trade = { "TRADE_SHOW", "TRADE_CLOSED" },
	trainer = { "TRAINER_SHOW", "TRAINER_CLOSED" },
	taxi = { "TAXIMAP_OPENED", "TAXIMAP_CLOSED" },
	bank = { "BANKFRAME_OPENED", "BANKFRAME_CLOSED" },
	guildbank = { "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED" },
	quest = { "QUEST_COMPLETE", "QUEST_FINISHED" },
	loot = { "LOOT_OPENED", "LOOT_CLOSED" },
}
for kind, events in pairs(LEGACY_EVENTS) do
	SF.On(events[1], function()
		Open(kind)
	end)
	SF.On(events[2], function()
		Close(kind)
	end)
end

-- ---------------------------------------------------------------------------
-- Item values
-- ---------------------------------------------------------------------------

local priceCache = {}

local function ItemID(link)
	return type(link) == "string" and tonumber(link:match("item:(%-?%d+)")) or nil
end

-- Vendor sell price for one unit, or nil if item data isn't loaded yet
-- (a load is requested; GET_ITEM_INFO_RECEIVED fires when it arrives).
function SF.SellPrice(link)
	local id = ItemID(link)
	if id and priceCache[id] then
		return priceCache[id]
	end
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local name, _, _, _, _, _, _, _, _, _, price = SF.Try(getInfo, link)
	if name and type(price) == "number" and not SF.IsSecret(price) then
		if id then
			priceCache[id] = price
		end
		return price
	end
	if id and C_Item and C_Item.RequestLoadItemDataByID then
		SF.Try(C_Item.RequestLoadItemDataByID, id)
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Gold: every change is attributed to whatever was happening at the time
-- ---------------------------------------------------------------------------

local lastMoney
local repairUntil, taxiUntil, questUntil, lootUntil = 0, 0, 0, 0

-- Gold attached to outgoing mail, set by Rules when SendMail is called, so
-- it's counted as "given away" rather than postage.
SF.pendingMailMoney = 0

local function ApplyMoney(delta)
	local now = GetTime()
	local gain = delta > 0
	local amount = math.abs(delta)

	if SF.IsOpen("trade", 3) then
		if gain then
			SF.Add("income", "other", amount)
		else
			SF.Add("spent", "given", amount)
		end
	elseif SF.IsOpen("mail", 2) then
		if gain then
			SF.Add("income", "mail", amount)
		else
			local given = math.min(SF.pendingMailMoney or 0, amount)
			SF.pendingMailMoney = (SF.pendingMailMoney or 0) - given
			if given > 0 then
				SF.Add("spent", "given", given)
			end
			if amount > given then
				SF.Add("spent", "fees", amount - given)
			end
		end
	elseif SF.IsOpen("auction", 2) then
		SF.Add(gain and "income" or "spent", gain and "mail" or "fees", amount)
	elseif SF.IsOpen("merchant", 2) then
		local repairing = now < repairUntil or (InRepairMode and SF.Safe(InRepairMode()))
		if gain then
			SF.Add("income", "vendor", amount)
			SF.Add("items", "soldCount", 1)
		elseif repairing then
			SF.Add("spent", "repair", amount)
		else
			SF.Add("spent", "vendor", amount)
		end
	elseif SF.IsOpen("trainer", 2) then
		SF.Add(gain and "income" or "spent", gain and "other" or "training", amount)
	elseif SF.IsOpen("taxi", 3) or now < taxiUntil then
		SF.Add(gain and "income" or "spent", gain and "other" or "travel", amount)
	elseif SF.IsOpen("guildbank", 2) then
		SF.Add(gain and "income" or "spent", gain and "other" or "given", amount)
	elseif SF.IsOpen("bank", 2) then
		-- Moving gold between you and your bank isn't income or spending.
		return
	elseif SF.IsOpen("quest", 2) or now < questUntil then
		SF.Add(gain and "income" or "spent", gain and "quest" or "other", amount)
	elseif SF.IsOpen("loot") or now < lootUntil then
		SF.Add(gain and "income" or "spent", gain and "loot" or "other", amount)
	else
		SF.Add(gain and "income" or "spent", "other", amount)
	end
end

SF.On("PLAYER_MONEY", function()
	if not SF.run then
		return
	end
	local money = SF.Safe(GetMoney())
	if type(money) ~= "number" then
		return
	end
	if lastMoney then
		local delta = money - lastMoney
		if delta ~= 0 then
			ApplyMoney(delta)
		end
	end
	lastMoney = money
	SF.QueueWorth()
	SF.Changed()
end)

SF.On("CHAT_MSG_MONEY", function()
	lootUntil = GetTime() + 2
end)

SF.On("LOOT_CLOSED", function()
	lootUntil = GetTime() + 2
end)

SF.Hook("RepairAllItems", function()
	repairUntil = GetTime() + 3
end)

SF.Hook("TakeTaxiNode", function()
	taxiUntil = GetTime() + 5
end)

-- ---------------------------------------------------------------------------
-- Chat-message parsing (loot and kills). Patterns are built from the
-- client's own localized format strings.
-- ---------------------------------------------------------------------------

function SF.PatternFromFormat(fmt)
	if type(fmt) ~= "string" or fmt == "" then
		return nil
	end
	-- Extra text (rested bonus etc.) can follow, so the trailing period and
	-- end anchor are dropped.
	fmt = fmt:gsub("%.$", "")
	local pattern = fmt:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
	pattern = pattern:gsub("%%%%%d%%%$s", "(.+)"):gsub("%%%%%d%%%$d", "(%%d+)")
	pattern = pattern:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
	return "^" .. pattern
end

local LOOT_MULTIPLE = SF.PatternFromFormat(LOOT_ITEM_SELF_MULTIPLE)
local LOOT_SINGLE = SF.PatternFromFormat(LOOT_ITEM_SELF)
local KILL_XP = SF.PatternFromFormat(COMBATLOG_XPGAIN_FIRSTPERSON)

local pendingLoot = {}

local function AddLootValue(link, count)
	local price = SF.SellPrice(link)
	if price then
		SF.Add("items", "lootedValue", price * count)
	else
		local id = ItemID(link)
		if id then
			pendingLoot[id] = (pendingLoot[id] or 0) + count
		end
	end
end

SF.On("CHAT_MSG_LOOT", function(message)
	message = SF.Safe(message)
	if type(message) ~= "string" or not SF.run then
		return
	end
	local _, count = nil, nil
	if LOOT_MULTIPLE then
		_, count = message:match(LOOT_MULTIPLE)
	end
	local isLoot = count ~= nil or (LOOT_SINGLE and message:match(LOOT_SINGLE) ~= nil)
	if not isLoot then
		return
	end
	count = tonumber(count) or 1
	local link = message:match("item:[%-%d:]+")
	if not link then
		return
	end
	SF.Add("items", "lootedCount", count)
	AddLootValue(link, count)
	SF.Changed()
end)

SF.On("GET_ITEM_INFO_RECEIVED", function(itemID)
	itemID = SF.Safe(itemID)
	if itemID and pendingLoot[itemID] and SF.run then
		local count = pendingLoot[itemID]
		pendingLoot[itemID] = nil
		AddLootValue("item:" .. itemID, count)
		SF.Changed()
	end
	SF.QueueWorth()
end)

SF.On("CHAT_MSG_COMBAT_XP_GAIN", function(message)
	message = SF.Safe(message)
	if type(message) == "string" and KILL_XP and SF.run and message:match(KILL_XP) then
		SF.Add("stats", "kills", 1)
		SF.Changed()
	end
end)

-- ---------------------------------------------------------------------------
-- Quests, deaths, levels
-- ---------------------------------------------------------------------------

SF.On("QUEST_TURNED_IN", function(questID)
	if not SF.run then
		return
	end
	questUntil = GetTime() + 2
	SF.Add("stats", "quests", 1)
	local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and SF.Safe(SF.Try(C_QuestLog.GetTitleForQuestID, questID))
	SF.Log("quest", "Completed quest: " .. (title or ("#" .. tostring(questID))), true)
	SF.Changed()
end)

local function ZoneName()
	return SF.Safe(GetRealZoneText and GetRealZoneText()) or SF.Safe(GetZoneText()) or "Unknown"
end

SF.On("PLAYER_DEAD", function()
	if not SF.run then
		return
	end
	SF.Add("stats", "deaths", 1)
	SF.Log("death", string.format("Died at level %d in %s", UnitLevel("player") or 0, ZoneName()))
	SF.Changed()
	SF.Fire("Milestone", "death")
end)

SF.On("PLAYER_LEVEL_UP", function(level)
	if not SF.run then
		return
	end
	level = SF.Safe(level) or UnitLevel("player")
	SF.Add("stats", "levelUps", 1)
	SF.Log("level", string.format("Reached level %d after %s played", level, SF.Duration(SF.PlayedNow())))
	SF.Changed()
	SF.Fire("Milestone", "level")
end)

-- ---------------------------------------------------------------------------
-- Destroyed items: remember what's on the cursor, count it if deleted
-- ---------------------------------------------------------------------------

local cursorItem

SF.On("CURSOR_CHANGED", function()
	cursorItem = nil
	if C_Cursor and C_Cursor.GetCursorItem and C_Item then
		local location = SF.Try(C_Cursor.GetCursorItem)
		if location and location.IsValid and SF.Try(location.IsValid, location) then
			cursorItem = {
				link = SF.Safe(SF.Try(C_Item.GetItemLink, location)),
				count = SF.Safe(SF.Try(C_Item.GetStackCount, location)) or 1,
			}
		end
	elseif GetCursorInfo then
		local kind, _, link = GetCursorInfo()
		if kind == "item" then
			cursorItem = { link = SF.Safe(link), count = 1 }
		end
	end
end)

local function OnDelete()
	local item = cursorItem
	cursorItem = nil
	if not item or not item.link or not SF.run then
		return
	end
	local price = SF.SellPrice(item.link) or 0
	SF.Add("items", "destroyedCount", item.count)
	SF.Add("items", "destroyedValue", price * item.count)
	SF.Log("destroy", string.format("Destroyed %s%s", item.link, item.count > 1 and ("x" .. item.count) or ""), true)
	SF.Changed()
end

SF.Hook("DeleteCursorItem", OnDelete)
if C_Item then
	SF.Hook(C_Item, "DeleteCursorItem", OnDelete)
end

-- ---------------------------------------------------------------------------
-- Play time. Each session asks the server for /played and compares it with
-- what we tracked last time; unexplained extra time means the game was
-- played without the addon running.
-- ---------------------------------------------------------------------------

local sampleAt
local awaitingPlayed = false
local mutedFrames = {}

function SF.PlayedNow()
	local played = SF.run and SF.run.played
	if not played then
		return 0
	end
	if sampleAt then
		return (played.server or 0) + (GetTime() - sampleAt)
	end
	return (played.server or 0) + (played.tracked or 0)
end

-- Our /played request would otherwise print to chat; hide it just for
-- our own request by briefly unregistering the chat frames that show it.
local function MuteChatPlayed()
	mutedFrames = {}
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local frame = _G["ChatFrame" .. i]
		if frame and frame.IsEventRegistered and SF.Try(frame.IsEventRegistered, frame, "TIME_PLAYED_MSG") then
			if pcall(frame.UnregisterEvent, frame, "TIME_PLAYED_MSG") then
				table.insert(mutedFrames, frame)
			end
		end
	end
end

local function UnmuteChatPlayed()
	for _, frame in ipairs(mutedFrames) do
		pcall(frame.RegisterEvent, frame, "TIME_PLAYED_MSG")
	end
	mutedFrames = {}
end

local function RequestPlayed()
	if not RequestTimePlayed then
		return
	end
	awaitingPlayed = true
	MuteChatPlayed()
	if not pcall(RequestTimePlayed) then
		awaitingPlayed = false
		UnmuteChatPlayed()
		return
	end
	SF.After(10, function()
		if awaitingPlayed then
			awaitingPlayed = false
			UnmuteChatPlayed()
		end
	end)
end

local function UpdateTracked()
	if sampleAt and SF.run then
		SF.run.played.tracked = math.floor(GetTime() - sampleAt)
		SF.Commit()
	end
end

SF.On("TIME_PLAYED_MSG", function(total)
	total = SF.Safe(total)
	if awaitingPlayed then
		awaitingPlayed = false
		SF.After(0, UnmuteChatPlayed)
	end
	if type(total) ~= "number" or not SF.run then
		return
	end
	local run = SF.run
	local played = run.played
	total = math.floor(total)

	if not sampleAt then
		played.sessions = (played.sessions or 0) + 1
		if played.server then
			local loadTime = GetTime() - (SF.loadedAt or GetTime())
			local from = played.server + (played.tracked or 0)
			local to = total - loadTime
			local gap = to - from
			if gap >= GAP_TOLERANCE then
				SF.AddGap(gap, "the addon didn't see it: a crash, or played without the addon", from, to)
			end
		else
			run.startPlayed = total
			local level = UnitLevel("player") or 1
			if total > LATE_START_PLAYED or level > 1 then
				run.lateStart = { level = level, played = total }
				SF.Log("info", string.format("Installed on an existing character (level %d, %s played), so the run is Unverified", level, SF.Duration(total)))
				SF.Fire("StatusChanged")
			end
		end
	else
		-- Every later /played must match what we've been counting. A jump
		-- means play time we didn't see - e.g. an earlier, faked response
		-- that hid a gap, exposed by the next real one.
		local expected = (played.server or 0) + (GetTime() - sampleAt)
		local drift = total - expected
		if drift >= GAP_TOLERANCE then
			SF.AddGap(drift, "play time didn't match the server's /played", expected, total)
		end
	end

	played.server = total
	played.tracked = 0
	sampleAt = GetTime()
	SF.Changed()
end)

SF.On("PLAYER_ENTERING_WORLD", function(isInitialLogin, isReloadingUi)
	lastMoney = SF.Safe(GetMoney())
	if isInitialLogin or isReloadingUi or not sampleAt then
		SF.After(3, RequestPlayed)
	end
	SF.QueueWorth()
end)

SF.Listen("Ready", function()
	if C_Timer and C_Timer.NewTicker then
		C_Timer.NewTicker(TRACK_INTERVAL, function()
			SF.SafeCall(UpdateTracked)
		end)
	end
end)

SF.Listen("BeforeSave", UpdateTracked)

-- ---------------------------------------------------------------------------
-- Net worth: gold plus vendor value of everything you own
-- ---------------------------------------------------------------------------

local GetNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots

local function SlotItem(bag, slot)
	if C_Container and C_Container.GetContainerItemInfo then
		local info = SF.Try(C_Container.GetContainerItemInfo, bag, slot)
		if type(info) == "table" and not SF.IsSecret(info) then
			return SF.Safe(info.hyperlink), SF.Safe(info.stackCount) or 1, SF.Safe(info.hasNoValue)
		end
		return nil
	end
	if GetContainerItemInfo then
		local _, count, _, _, _, _, link = SF.Try(GetContainerItemInfo, bag, slot)
		return SF.Safe(link), SF.Safe(count) or 1, false
	end
end

local function NumEquippedBags()
	return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
end

local function BagIDs()
	local ids = {}
	for bag = 0, NumEquippedBags() do
		ids[#ids + 1] = bag
	end
	return ids
end

-- Bank container IDs: modern bank tabs if this client has them, otherwise
-- the classic bank slot + bank bags.
function SF.BankBagIDs(kind)
	local ids = {}
	if C_Bank and C_Bank.FetchPurchasedBankTabIDs and Enum and Enum.BankType then
		local bankType = (kind == "account") and Enum.BankType.Account or Enum.BankType.Character
		if bankType ~= nil then
			local list = SF.Try(C_Bank.FetchPurchasedBankTabIDs, bankType)
			if type(list) == "table" then
				for _, id in ipairs(list) do
					ids[#ids + 1] = id
				end
			end
		end
	end
	if kind == "character" and #ids == 0 then
		if BANK_CONTAINER then
			ids[#ids + 1] = BANK_CONTAINER
		end
		local first = NumEquippedBags() + 1
		for i = first, first + (NUM_BANKBAGSLOTS or 0) - 1 do
			ids[#ids + 1] = i
		end
	end
	return ids
end

local function ContainerValue(bagIDs)
	local total, incomplete = 0, false
	for _, bag in ipairs(bagIDs) do
		for slot = 1, SF.Safe(SF.Try(GetNumSlots, bag)) or 0 do
			local link, count, noValue = SlotItem(bag, slot)
			if link and not noValue then
				local price = SF.SellPrice(link)
				if price then
					total = total + price * (count or 1)
				else
					incomplete = true
				end
			end
		end
	end
	return total, incomplete
end

local function LinkValue(link, count)
	if not link then
		return 0, false
	end
	local price = SF.SellPrice(link)
	if not price then
		return 0, true
	end
	return price * (count or 1), false
end

local function EquippedValue()
	local total, incomplete = 0, false
	for slot = 1, 19 do
		local value, missing = LinkValue(SF.Safe(SF.Try(GetInventoryItemLink, "player", slot)))
		total, incomplete = total + value, incomplete or missing
	end
	-- The equipped bags themselves have a vendor value too.
	local toInventory = (C_Container and C_Container.ContainerIDToInventoryID) or ContainerIDToInventoryID
	for bag = 1, NumEquippedBags() do
		local invID = SF.Safe(SF.Try(toInventory, bag))
		if invID then
			local value, missing = LinkValue(SF.Safe(SF.Try(GetInventoryItemLink, "player", invID)))
			total, incomplete = total + value, incomplete or missing
		end
	end
	return total, incomplete
end

local worthQueued, worthRetries = false, 0

function SF.UpdateWorth()
	if not SF.run then
		return
	end
	local w = SF.run.worth
	local money = SF.Safe(GetMoney())
	if type(money) == "number" then
		w.money = money
	end
	local bags, missingBags = ContainerValue(BagIDs())
	local equipped, missingEquipped = EquippedValue()
	w.bags, w.equipped = bags, equipped
	local missing = missingBags or missingEquipped

	if SF.IsOpen("bank") then
		local bank, missingBank = ContainerValue(SF.BankBagIDs("character"))
		w.bank, w.bankAt = bank, time()
		missing = missing or missingBank
		if C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType and Enum.BankType.Character then
			local deposited = SF.Safe(SF.Try(C_Bank.FetchDepositedMoney, Enum.BankType.Character))
			if type(deposited) == "number" then
				w.bankMoney = deposited
			end
		end
	end

	local total = w.money + w.bags + w.equipped + w.bank + w.bankMoney
	if total > (w.peak or 0) then
		w.peak, w.peakAt = total, time()
	end
	SF.Changed()

	-- Some item data may still be loading; try again shortly (bounded).
	if missing and worthRetries < 5 then
		worthRetries = worthRetries + 1
		SF.QueueWorth(2)
	elseif not missing then
		worthRetries = 0
	end
end

function SF.WorthTotal()
	local w = SF.run and SF.run.worth
	if not w then
		return 0
	end
	return w.money + w.bags + w.equipped + w.bank + w.bankMoney
end

function SF.QueueWorth(delay)
	if worthQueued then
		return
	end
	worthQueued = true
	SF.After(delay or 0.5, function()
		worthQueued = false
		SF.UpdateWorth()
	end)
end

for _, event in ipairs({ "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED", "PLAYERBANKSLOTS_CHANGED" }) do
	SF.On(event, function()
		SF.QueueWorth()
	end)
end

SF.Listen("InteractionOpened", function(kind)
	if kind == "bank" then
		SF.QueueWorth(0.3)
	end
end)
