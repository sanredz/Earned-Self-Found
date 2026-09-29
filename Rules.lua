-- Self Found - Rules
-- Enforcement. Anything that brings items or gold in from another player
-- disqualifies the run immediately:
--   * completing a trade where anything changes hands
--   * bidding on, buying out, or listing an auction
--   * taking items/gold (incl. COD) from mail another player sent
--   * withdrawing from a guild bank or Warband (account) bank
-- Warnings are shown whenever one of those windows is open.

local ADDON, SF = ...

SF.RULES = {
	"Completing a trade where any item, gold, or enchant changes hands.",
	"Bidding on, buying out, or listing an auction.",
	"Taking items or gold (including COD) from mail sent by another player. Your own returned mail, NPC mail, and auction mail are fine.",
	"Withdrawing items or gold from a guild bank or Warband bank.",
	"Editing the addon's saved data outside the game.",
}
SF.UNVERIFIED_RULES = {
	"Play time the addon didn't see (it was disabled, uninstalled, or the game crashed).",
	"Installing the addon after the character already had play time.",
}

-- ---------------------------------------------------------------------------
-- Disqualification alert
-- ---------------------------------------------------------------------------

local alert

local function CreateAlert()
	alert = CreateFrame("Frame", "SelfFoundAlert", UIParent, "BackdropTemplate")
	alert:SetSize(560, 86)
	alert:SetPoint("TOP", UIParent, "TOP", 0, -140)
	alert:SetFrameStrata("FULLSCREEN_DIALOG")
	alert:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	alert:SetBackdropColor(0.25, 0.02, 0.02, 0.95)
	alert:SetBackdropBorderColor(1, 0.3, 0.3, 1)

	alert.icon = alert:CreateTexture(nil, "ARTWORK")
	alert.icon:SetSize(48, 48)
	alert.icon:SetPoint("LEFT", 18, 0)
	alert.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")

	alert.title = alert:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	alert.title:SetPoint("TOPLEFT", alert.icon, "TOPRIGHT", 14, -2)
	alert.title:SetText(SF.Colorize("DISQUALIFIED", SF.COLOR.DISQUALIFIED))

	alert.text = alert:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	alert.text:SetPoint("TOPLEFT", alert.title, "BOTTOMLEFT", 0, -6)
	alert.text:SetPoint("RIGHT", alert, "RIGHT", -18, 0)
	alert.text:SetJustifyH("LEFT")

	alert:SetScript("OnUpdate", function(self)
		local remaining = (self.hideAt or 0) - GetTime()
		if remaining <= 0 then
			self:Hide()
		elseif remaining < 1 then
			self:SetAlpha(remaining)
		end
	end)
	alert:EnableMouse(true)
	alert:SetScript("OnMouseDown", function(self)
		self:Hide()
	end)
	alert:Hide()
end

SF.Listen("Violation", function(code, text)
	if not alert then
		CreateAlert()
	end
	alert.text:SetText(text)
	alert:SetAlpha(1)
	alert.hideAt = GetTime() + 10
	alert:Show()
	if PlaySound then
		pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959)
	end
	SF.Print(SF.Colorize("DISQUALIFIED", SF.COLOR.DISQUALIFIED) .. " - " .. text)
end)

-- ---------------------------------------------------------------------------
-- Warning banner shown above trade / auction / mail / bank windows
-- ---------------------------------------------------------------------------

local banner

local function CreateBanner()
	banner = CreateFrame("Frame", "SelfFoundWarning", UIParent, "BackdropTemplate")
	banner:SetSize(400, 46)
	banner:SetFrameStrata("DIALOG")
	banner:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	banner:SetBackdropColor(0.30, 0.04, 0.04, 0.92)
	banner:SetBackdropBorderColor(1, 0.35, 0.35, 1)

	banner.icon = banner:CreateTexture(nil, "ARTWORK")
	banner.icon:SetSize(28, 28)
	banner.icon:SetPoint("LEFT", 10, 0)
	banner.icon:SetTexture(SF.ICON)
	banner.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	banner.text:SetPoint("LEFT", banner.icon, "RIGHT", 10, 0)
	banner.text:SetPoint("RIGHT", banner, "RIGHT", -10, 0)
	banner.text:SetJustifyH("LEFT")
	banner:Hide()
end

local BANNERS = {
	trade = { frame = "TradeFrame", text = "Self Found: completing this trade will |cffff5555DISQUALIFY|r this character if anything changes hands." },
	auction = { frame = "AuctionHouseFrame", text = "Self Found: bidding, buying out, or listing an auction will |cffff5555DISQUALIFY|r this character." },
	mail = { frame = "MailFrame", text = "Self Found: taking items or gold mailed by another player will |cffff5555DISQUALIFY|r this character." },
	guildbank = { frame = "GuildBankFrame", text = "Self Found: withdrawing items or gold from the guild bank will |cffff5555DISQUALIFY|r this character." },
}

local function ShowBanner(kind, attempt)
	local info = BANNERS[kind]
	if not info or not SF.settings or not SF.settings.warnings then
		return
	end
	if not banner then
		CreateBanner()
	end
	local anchor = _G[info.frame]
	-- Load-on-demand windows (auction house) may not exist for a frame yet.
	if not anchor and (attempt or 0) < 5 then
		SF.After(0.2, function()
			ShowBanner(kind, (attempt or 0) + 1)
		end)
		return
	end
	banner:ClearAllPoints()
	if anchor then
		banner:SetPoint("BOTTOM", anchor, "TOP", 0, 6)
	else
		banner:SetPoint("TOP", UIParent, "TOP", 0, -100)
	end
	banner.text:SetText(info.text)
	banner.owner = kind
	banner:Show()
end

local function HideBanner(kind)
	if banner and banner.owner == kind then
		banner:Hide()
		banner.owner = nil
	end
end

SF.Listen("InteractionOpened", function(kind)
	if not SF.run then
		return
	end
	if kind == "auction" then
		SF.Add("stats", "ahOpened", 1)
		SF.Log("auction", "Opened the auction house", true)
		SF.Changed()
	elseif kind == "trade" then
		SF.Add("stats", "tradeWindows", 1)
		SF.Changed()
	end
	if BANNERS[kind] then
		ShowBanner(kind)
	elseif kind == "bank" and SF.AccountBankViewable() then
		BANNERS.bank = { frame = "BankFrame", text = "Self Found: taking items or gold from the Warband bank will |cffff5555DISQUALIFY|r this character." }
		ShowBanner("bank")
	end
end)

SF.Listen("InteractionClosed", function(kind)
	HideBanner(kind)
end)

-- ---------------------------------------------------------------------------
-- Trades
-- ---------------------------------------------------------------------------

local MAX_ITEMS = MAX_TRADABLE_ITEMS or 6
local ENCHANT_SLOT = TRADE_ENCHANT_SLOT or 7
local trade

local function ItemLabel(link, count)
	if not link then
		return nil
	end
	if count and count > 1 then
		return link .. "x" .. count
	end
	return link
end

local function SnapshotTrade()
	if not trade then
		return
	end
	local give, receive = {}, {}
	for i = 1, MAX_ITEMS do
		local _, _, playerCount = SF.Try(GetTradePlayerItemInfo, i)
		local playerLink = SF.Safe(SF.Try(GetTradePlayerItemLink, i))
		if playerLink then
			give[#give + 1] = ItemLabel(playerLink, SF.Safe(playerCount))
		end
		local _, _, targetCount = SF.Try(GetTradeTargetItemInfo, i)
		local targetLink = SF.Safe(SF.Try(GetTradeTargetItemLink, i))
		if targetLink then
			receive[#receive + 1] = ItemLabel(targetLink, SF.Safe(targetCount))
		end
	end
	-- An enchant the other player applies to your item (in your "will not
	-- be traded" slot) is also receiving help.
	local _, _, _, _, enchantment = SF.Try(GetTradePlayerItemInfo, ENCHANT_SLOT)
	enchantment = SF.Safe(enchantment)
	if type(enchantment) == "string" and enchantment ~= "" then
		receive[#receive + 1] = "enchant: " .. enchantment
	end
	-- GetTradeTargetItemInfo returns name, texture, count, quality,
	-- isUsable, enchantment - one position later than the player version.
	local _, _, _, _, _, targetEnchant = SF.Try(GetTradeTargetItemInfo, ENCHANT_SLOT)
	targetEnchant = SF.Safe(targetEnchant)
	if type(targetEnchant) == "string" and targetEnchant ~= "" then
		give[#give + 1] = "enchant: " .. targetEnchant
	end
	trade.give = give
	trade.receive = receive
	trade.giveMoney = SF.Safe(SF.Try(GetPlayerTradeMoney)) or 0
	trade.receiveMoney = SF.Safe(SF.Try(GetTargetTradeMoney)) or 0
end

local function Describe(items, money)
	local parts = {}
	for _, item in ipairs(items or {}) do
		parts[#parts + 1] = item
	end
	if money and money > 0 then
		parts[#parts + 1] = SF.Money(money)
	end
	if #parts == 0 then
		return "nothing"
	end
	return table.concat(parts, ", ")
end

local function CompleteTrade(t)
	if not t or t.completed or not SF.run then
		return
	end
	t.completed = true
	local received = #t.receive > 0 or t.receiveMoney > 0
	local gave = #t.give > 0 or t.giveMoney > 0
	local summary = string.format("Trade with %s: gave %s; received %s", t.partner,
		Describe(t.give, t.giveMoney), Describe(t.receive, t.receiveMoney))

	if received or gave then
		SF.Add("stats", "trades", 1)
		SF.Log("trade", summary)
		SF.Violation("TRADE", string.format("Completed a trade with %s (received %s)", t.partner, Describe(t.receive, t.receiveMoney)))
	else
		SF.Log("trade", "Trade with " .. t.partner .. " completed with nothing exchanged", true)
	end
	SF.Changed()
end

SF.On("TRADE_SHOW", function()
	local partner = SF.Safe(GetUnitName and GetUnitName("NPC", true)) or SF.Safe(UnitName("NPC")) or "another player"
	trade = { partner = partner, give = {}, receive = {}, giveMoney = 0, receiveMoney = 0 }
	SnapshotTrade()
end)

for _, event in ipairs({ "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED", "TRADE_MONEY_CHANGED", "PLAYER_TRADE_MONEY", "TRADE_UPDATE" }) do
	SF.On(event, SnapshotTrade)
end

SF.On("TRADE_ACCEPT_UPDATE", function(playerAccepted, targetAccepted)
	if not trade then
		return
	end
	SnapshotTrade()
	trade.bothAccepted = SF.Safe(playerAccepted) == 1 and SF.Safe(targetAccepted) == 1
end)

SF.On("UI_INFO_MESSAGE", function(_, message)
	message = SF.Safe(message)
	if trade and ERR_TRADE_COMPLETE and message == ERR_TRADE_COMPLETE then
		CompleteTrade(trade)
	end
end)

SF.On("TRADE_CLOSED", function()
	-- Fallback if this client never sent the "Trade complete" message: both
	-- sides had accepted the final contents when the window closed.
	local closing = trade
	SF.After(0.5, function()
		if closing and closing.bothAccepted then
			CompleteTrade(closing)
		end
		if trade == closing then
			trade = nil
		end
	end)
end)

-- ---------------------------------------------------------------------------
-- Auction house
-- ---------------------------------------------------------------------------

local function ItemLocationLink(location)
	if not location or not C_Item then
		return nil
	end
	return SF.Safe(SF.Try(C_Item.GetItemLink, location))
end

if C_AuctionHouse then
	SF.Hook(C_AuctionHouse, "PlaceBid", function(auctionID, bidAmount)
		local isBuyout = false
		local info = SF.Try(C_AuctionHouse.GetAuctionInfoByID, auctionID)
		if type(info) == "table" and not SF.IsSecret(info) then
			local buyout = SF.Safe(info.buyoutAmount)
			isBuyout = buyout ~= nil and buyout == SF.Safe(bidAmount)
		end
		SF.Add("stats", isBuyout and "ahBuyouts" or "ahBids", 1)
		SF.Violation("AUCTION", string.format("%s an auction for %s", isBuyout and "Bought out" or "Bid on", SF.Money(SF.Safe(bidAmount) or 0)))
	end)

	SF.Hook(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, quantity)
		SF.Add("stats", "ahBuyouts", 1)
		local count = SF.Safe(quantity) or 1
		local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
		local _, link = SF.Try(getInfo, SF.Safe(itemID))
		link = SF.Safe(link) or ("item #" .. tostring(SF.Safe(itemID) or "?"))
		SF.Violation("AUCTION", string.format("Bought %s%s from the auction house", link, count > 1 and ("x" .. count) or ""))
	end)

	SF.Hook(C_AuctionHouse, "PostItem", function(location)
		SF.Add("stats", "ahListed", 1)
		SF.Violation("AUCTION", "Listed " .. (ItemLocationLink(location) or "an item") .. " on the auction house")
	end)

	SF.Hook(C_AuctionHouse, "PostCommodity", function(location, _, quantity)
		SF.Add("stats", "ahListed", 1)
		local count = SF.Safe(quantity) or 1
		local link = ItemLocationLink(location) or "an item"
		SF.Violation("AUCTION", string.format("Listed %s%s on the auction house", link, count > 1 and ("x" .. count) or ""))
	end)
end

-- Classic-style auction API, in case this client uses it anywhere.
SF.Hook("PlaceAuctionBid", function(_, _, bid)
	SF.Add("stats", "ahBids", 1)
	SF.Violation("AUCTION", "Bid on an auction for " .. SF.Money(SF.Safe(bid) or 0))
end)
SF.Hook("PostAuction", function()
	SF.Add("stats", "ahListed", 1)
	SF.Violation("AUCTION", "Listed an item on the auction house")
end)

local AUCTION_SOLD = SF.PatternFromFormat and SF.PatternFromFormat(ERR_AUCTION_SOLD_S)

SF.On("CHAT_MSG_SYSTEM", function(message)
	message = SF.Safe(message)
	if type(message) == "string" and AUCTION_SOLD and message:match(AUCTION_SOLD) and SF.run then
		SF.Add("stats", "ahSold", 1)
		SF.Log("auction", message)
		SF.Changed()
	end
end)

-- ---------------------------------------------------------------------------
-- Mail
-- ---------------------------------------------------------------------------

-- "player" is the only category that counts as outside help.
local function MailSource(index)
	local _, _, sender, _, money, cod, _, itemCount, _, wasReturned, _, canReply, isGM = SF.Try(GetInboxHeaderInfo, index)
	local invoiceType = GetInboxInvoiceInfo and SF.Safe(SF.Try(GetInboxInvoiceInfo, index))
	local category
	if SF.Safe(wasReturned) then
		category = "returned"
	elseif invoiceType then
		category = "auction"
	elseif SF.Safe(isGM) then
		category = "gm"
	elseif SF.Safe(canReply) then
		category = "player"
	else
		category = "npc"
	end
	return category, SF.Safe(sender) or "someone", SF.Safe(money) or 0, SF.Safe(cod) or 0, SF.Safe(itemCount) or 0
end

local function OnTakeMail(index, what)
	if not SF.run then
		return
	end
	local category, sender = MailSource(index)
	SF.Add("stats", "mailTaken", 1)
	if category == "player" then
		SF.Add("stats", "mailFromPlayers", 1)
		SF.Violation("MAIL", string.format("Took %s from mail sent by %s", what, sender))
	else
		local labels = { returned = "your own returned mail", auction = "auction house mail", gm = "GM mail", npc = "mail from " .. sender }
		SF.Log("mail", string.format("Took %s from %s", what, labels[category]), true)
	end
	SF.Changed()
end

SF.Hook("TakeInboxItem", function(index, attachment)
	local link = SF.Safe(SF.Try(GetInboxItemLink, index, attachment))
	OnTakeMail(index, link or "an item")
end)

SF.Hook("TakeInboxMoney", function(index)
	local _, _, money = MailSource(index)
	OnTakeMail(index, money > 0 and SF.Money(money) or "gold")
end)

SF.Hook("AutoLootMailItem", function(index)
	local _, _, money, _, itemCount = MailSource(index)
	local parts = {}
	if itemCount > 0 then
		parts[#parts + 1] = itemCount == 1 and "an item" or (itemCount .. " items")
	end
	if money > 0 then
		parts[#parts + 1] = SF.Money(money)
	end
	OnTakeMail(index, #parts > 0 and table.concat(parts, " and ") or "attachments")
end)

SF.Hook("SendMail", function(recipient)
	if not SF.run then
		return
	end
	SF.pendingMailMoney = SF.Safe(SF.Try(GetSendMailMoney)) or 0
	SF.Add("stats", "mailSent", 1)
	SF.Log("mail", "Sent mail to " .. tostring(SF.Safe(recipient) or "?"), true)
	SF.Changed()
end)

-- ---------------------------------------------------------------------------
-- Guild bank and Warband (account) bank
-- ---------------------------------------------------------------------------

local function BankViolation(what)
	SF.Add("stats", "bankWithdrawals", 1)
	SF.Violation("BANK", what)
end

SF.Hook("WithdrawGuildBankMoney", function(amount)
	BankViolation("Withdrew " .. SF.Money(SF.Safe(amount) or 0) .. " from the guild bank")
end)

SF.Hook("AutoStoreGuildBankItem", function(tab, slot)
	local link = SF.Safe(SF.Try(GetGuildBankItemLink, tab, slot))
	BankViolation("Withdrew " .. (link or "an item") .. " from the guild bank")
end)

-- Picking up a guild bank item leaves it on the cursor (or swaps it for the
-- one you were holding) - either way you took it. Depositing into an empty
-- slot leaves the cursor empty and isn't flagged.
SF.Hook("PickupGuildBankItem", function(tab, slot)
	if CursorHasItem and CursorHasItem() then
		local link = SF.Safe(SF.Try(GetGuildBankItemLink, tab, slot))
		BankViolation("Took " .. (link or "an item") .. " from the guild bank")
	end
end)

function SF.AccountBankViewable()
	if not (C_Bank and C_Bank.CanViewBank and Enum and Enum.BankType and Enum.BankType.Account) then
		return false
	end
	return SF.Safe(SF.Try(C_Bank.CanViewBank, Enum.BankType.Account)) == true
end

local function IsAccountBankBag(bag)
	if not SF.IsOpen("bank") then
		return false
	end
	for _, id in ipairs(SF.BankBagIDs("account")) do
		if id == bag then
			return true
		end
	end
	return false
end

local function AccountBankTake(bag, slot, requireCursor)
	bag = SF.Safe(bag)
	if not bag or not IsAccountBankBag(bag) then
		return
	end
	-- Placing an item INTO a slot also goes through PickupContainerItem; that
	-- leaves the cursor empty, so only flag when something ended up on it.
	if requireCursor and not (CursorHasItem and CursorHasItem()) then
		return
	end
	local info = C_Container and SF.Try(C_Container.GetContainerItemInfo, bag, slot)
	local link = type(info) == "table" and not SF.IsSecret(info) and SF.Safe(info.hyperlink)
	BankViolation("Took " .. (link or "an item") .. " from the Warband bank")
end

if C_Container then
	-- Right-clicking a Warband bank item moves it straight into your bags.
	SF.Hook(C_Container, "UseContainerItem", function(bag, slot)
		AccountBankTake(bag, slot, false)
	end)
	SF.Hook(C_Container, "PickupContainerItem", function(bag, slot)
		AccountBankTake(bag, slot, true)
	end)
	SF.Hook(C_Container, "SplitContainerItem", function(bag, slot)
		AccountBankTake(bag, slot, true)
	end)
end

if C_Bank then
	SF.Hook(C_Bank, "WithdrawMoney", function(bankType, amount)
		bankType = SF.Safe(bankType)
		if Enum and Enum.BankType and bankType ~= nil and bankType ~= Enum.BankType.Character then
			local where = bankType == Enum.BankType.Guild and "the guild bank" or "the Warband bank"
			BankViolation("Withdrew " .. SF.Money(SF.Safe(amount) or 0) .. " from " .. where)
		end
	end)
end
