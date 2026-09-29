-- Self Found - UI
-- Native-style window (portrait frame, bottom tabs, inset panels) with an
-- Overview, a gold Ledger, the event Log, and Witnesses; plus dialogs to
-- share your run and check someone else's.

local ADDON, SF = ...

local UI = {}
SF.UI = UI

local ICON = {
	level = "Interface\\Icons\\Spell_Holy_InnerFire",
	played = "Interface\\Icons\\INV_Misc_PocketWatch_01",
	deaths = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
	kills = "Interface\\Icons\\Ability_DualWield",
	quests = "Interface\\Icons\\INV_Misc_Note_01",
	worth = "Interface\\Icons\\INV_Misc_Coin_02",
	earned = "Interface\\Icons\\INV_Misc_Coin_01",
	looted = "Interface\\Icons\\INV_Misc_Bag_08",
	trades = "Interface\\Icons\\INV_Misc_Bag_10",
	auctions = "Interface\\Icons\\INV_Misc_Coin_05",
	mail = "Interface\\Icons\\INV_Letter_15",
	witnesses = "Interface\\Icons\\Ability_Hunter_EagleEye",
	destroyed = "Interface\\Icons\\Spell_Fire_SoulBurn",
	sold = "Interface\\Icons\\INV_Misc_Coin_04",
	repair = "Interface\\Icons\\Trade_BlackSmithing",
	training = "Interface\\Icons\\INV_Misc_Book_09",
	travel = "Interface\\Icons\\Spell_Nature_Swiftness",
	fees = "Interface\\Icons\\INV_Misc_Note_02",
	given = "Interface\\Icons\\INV_Misc_Bag_07",
	other = "Interface\\Icons\\INV_Misc_QuestionMark",
	bags = "Interface\\Icons\\INV_Misc_Bag_08",
	equipped = "Interface\\Icons\\INV_Chest_Chain_05",
	bank = "Interface\\Icons\\INV_Box_02",
	peak = "Interface\\Icons\\Spell_Holy_HolyBolt",
}

local STATUS_ICON = {
	CLEAN = "Interface\\RaidFrame\\ReadyCheck-Ready",
	UNVERIFIED = "Interface\\RaidFrame\\ReadyCheck-Waiting",
	DISQUALIFIED = "Interface\\RaidFrame\\ReadyCheck-NotReady",
}

local LOG_ICON = {
	start = SF.ICON,
	violation = STATUS_ICON.DISQUALIFIED,
	gap = STATUS_ICON.UNVERIFIED,
	death = ICON.deaths,
	level = ICON.level,
	trade = ICON.trades,
	auction = ICON.auctions,
	mail = ICON.mail,
	quest = ICON.quests,
	destroy = ICON.destroyed,
	info = ICON.fees,
	recover = ICON.witnesses,
}

local LOG_COLOR = {
	violation = SF.COLOR.DISQUALIFIED,
	gap = SF.COLOR.UNVERIFIED,
	recover = SF.COLOR.CLEAN,
	death = { 0.85, 0.55, 0.55 },
	level = SF.COLOR.GOLD,
	start = SF.COLOR.CLEAN,
}

-- ---------------------------------------------------------------------------
-- Small building blocks
-- ---------------------------------------------------------------------------

local function Text(parent, template, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

local function Icon(parent, size, path)
	local tex = parent:CreateTexture(nil, "ARTWORK")
	tex:SetSize(size, size)
	tex:SetTexture(path)
	tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	return tex
end

local function Panel(parent, title)
	local panel = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
	if title then
		panel.title = Text(panel, "GameFontNormal")
		panel.title:SetPoint("TOPLEFT", 12, -9)
		panel.title:SetText(title)
		local line = panel:CreateTexture(nil, "ARTWORK")
		line:SetHeight(1)
		line:SetPoint("TOPLEFT", 10, -27)
		line:SetPoint("TOPRIGHT", -10, -27)
		line:SetColorTexture(1, 0.82, 0, 0.18)
	end
	return panel
end

local function Button(parent, label, width, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width or 130, 24)
	button:SetText(label)
	button:SetScript("OnClick", function()
		SF.SafeCall(onClick)
	end)
	return button
end

local function Checkbox(parent, label, getter, setter)
	local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	check:SetSize(24, 24)
	check.label = Text(check, "GameFontHighlightSmall")
	check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
	check.label:SetText(label)
	check:SetScript("OnShow", function(self)
		self:SetChecked(getter())
	end)
	check:SetScript("OnClick", function(self)
		setter(self:GetChecked() and true or false)
	end)
	return check
end

local function Number(n)
	n = math.floor(tonumber(n) or 0)
	if FormatLargeNumber then
		local ok, text = pcall(FormatLargeNumber, n)
		if ok and text then
			return text
		end
	end
	return tostring(n)
end

local function Tooltip(owner, title, lines)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetText(title, 1, 0.82, 0)
	for _, line in ipairs(lines or {}) do
		if type(line) == "table" then
			GameTooltip:AddLine(line[1], line[2] or 1, line[3] or 1, line[4] or 1, true)
		else
			GameTooltip:AddLine(line, 1, 1, 1, true)
		end
	end
	GameTooltip:Show()
end

local function HideTooltip()
	GameTooltip:Hide()
end

-- A row inside a panel: icon, label on the left, value on the right.
local function StatRow(parent, y, icon, label)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(22)
	row:SetPoint("TOPLEFT", 12, y)
	row:SetPoint("TOPRIGHT", -12, y)
	row.icon = Icon(row, 18, icon)
	row.icon:SetPoint("LEFT", 0, 0)
	row.label = Text(row, "GameFontHighlight")
	row.label:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
	row.label:SetText(label)
	row.value = Text(row, "GameFontHighlight", "RIGHT")
	row.value:SetPoint("RIGHT", 0, 0)
	return row
end

local function Divider(parent, y)
	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetHeight(1)
	line:SetPoint("TOPLEFT", 12, y)
	line:SetPoint("TOPRIGHT", -12, y)
	line:SetColorTexture(1, 1, 1, 0.12)
	return line
end

-- A scrolling list using Blizzard's ScrollBox. `init(row, data)` fills a
-- recycled row (build children once, guarded by row.built).
local function List(parent, rowHeight, init)
	local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
	local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
	box:SetPoint("TOPLEFT", 8, -32)
	box:SetPoint("BOTTOMRIGHT", -24, 8)
	bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 6, 0)
	bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 6, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(rowHeight)
	view:SetElementInitializer("Button", function(row, data)
		SF.SafeCall(init, row, data)
	end)
	ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
	box.SetList = function(self, list)
		local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
		self:SetDataProvider(CreateDataProvider(list), retain)
	end
	return box
end

local function RowHighlight(row)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
end

-- ---------------------------------------------------------------------------
-- Main frame
-- ---------------------------------------------------------------------------

local main
local pages = {}
local TABS = { "Overview", "Ledger", "Log", "Witnesses" }

local function StatusColor(status)
	return SF.COLOR[status] or SF.COLOR.GRAY
end

-- ------------------------------ Overview ---------------------------------

local function BuildOverview(page)
	-- Status banner
	local status = Panel(page)
	status:SetPoint("TOPLEFT", 4, -4)
	status:SetPoint("TOPRIGHT", -4, -4)
	status:SetHeight(96)
	status.tint = status:CreateTexture(nil, "BACKGROUND", nil, 2)
	status.tint:SetPoint("TOPLEFT", 3, -3)
	status.tint:SetPoint("BOTTOMRIGHT", -3, 3)
	status.bar = status:CreateTexture(nil, "ARTWORK")
	status.bar:SetPoint("TOPLEFT", 3, -3)
	status.bar:SetPoint("BOTTOMLEFT", 3, 3)
	status.bar:SetWidth(4)
	status.icon = status:CreateTexture(nil, "ARTWORK")
	status.icon:SetSize(54, 54)
	status.icon:SetPoint("LEFT", 20, 0)
	status.word = Text(status, "GameFontNormalHuge")
	status.word:SetPoint("TOPLEFT", status.icon, "TOPRIGHT", 16, -2)
	status.witnessed = Text(status, "GameFontDisable")
	status.witnessed:SetPoint("BOTTOMLEFT", status.word, "BOTTOMRIGHT", 12, 3)
	-- Hovering the banner explains status vs. witnesses.
	status:EnableMouse(true)
	status:SetScript("OnEnter", function(self)
		Tooltip(self, "Status and witnesses", {
			{ "Your status is decided only by your own actions, seen by your own addon.", 1, 1, 1 },
			{ " " },
			{ "Other players' addons witness your run. If one catches something that doesn't fit a clean run, it flags you, with its name on it, and every witness can see it. Flags never change your status.", 0.8, 0.8, 0.8 },
			{ "See My profile in the Witnesses tab for your witnessed hours and any flags.", 0.6, 0.6, 0.6 },
		})
	end)
	status:SetScript("OnLeave", HideTooltip)
	status.reason = Text(status, "GameFontHighlight")
	status.reason:SetPoint("TOPLEFT", status.word, "BOTTOMLEFT", 0, -6)
	status.reason:SetPoint("RIGHT", status, "RIGHT", -200, 0)
	status.reason:SetWordWrap(true)
	status.reason:SetMaxLines(2)
	status.char = Text(status, "GameFontNormalLarge", "RIGHT")
	status.char:SetPoint("TOPRIGHT", -18, -18)
	status.info = Text(status, "GameFontHighlightSmall", "RIGHT")
	status.info:SetPoint("TOPRIGHT", status.char, "BOTTOMRIGHT", 0, -6)
	status.since = Text(status, "GameFontDisableSmall", "RIGHT")
	status.since:SetPoint("TOPRIGHT", status.info, "BOTTOMRIGHT", 0, -4)
	page.status = status

	-- Tiles
	local tiles = Panel(page, "At a glance")
	tiles:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -6)
	tiles:SetPoint("TOPRIGHT", status, "BOTTOMRIGHT", 0, -6)
	tiles:SetHeight(206)
	page.tiles = {}
	local defs = {
		{ "level", "Level", ICON.level },
		{ "played", "Played", ICON.played },
		{ "deaths", "Deaths", ICON.deaths },
		{ "kills", "Kills", ICON.kills },
		{ "quests", "Quests completed", ICON.quests },
		{ "earned", "Gold earned", ICON.earned },
		{ "worth", "Net worth", ICON.worth },
		{ "looted", "Items looted", ICON.looted },
		{ "trades", "Trades", ICON.trades },
		{ "auctions", "Auction actions", ICON.auctions },
		{ "mail", "Mail from players", ICON.mail },
		{ "witnesses", "Witnesses", ICON.witnesses },
	}
	local cols, tileW, tileH, gap = 4, 156, 50, 8
	for i, def in ipairs(defs) do
		local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
		local tile = CreateFrame("Frame", nil, tiles)
		tile:SetSize(tileW, tileH)
		tile:SetPoint("TOPLEFT", 12 + col * (tileW + gap), -36 - row * (tileH + gap))
		local bg = tile:CreateTexture(nil, "BACKGROUND", nil, 3)
		bg:SetAllPoints()
		bg:SetColorTexture(1, 1, 1, 0.045)
		tile.icon = Icon(tile, 36, def[3])
		tile.icon:SetPoint("LEFT", 7, 0)
		tile.value = Text(tile, "GameFontHighlightLarge")
		tile.value:SetPoint("TOPLEFT", tile.icon, "TOPRIGHT", 9, -1)
		tile.value:SetPoint("RIGHT", tile, "RIGHT", -6, 0)
		tile.label = Text(tile, "GameFontNormalSmall")
		tile.label:SetPoint("BOTTOMLEFT", tile.icon, "BOTTOMRIGHT", 9, 1)
		tile.label:SetText(def[2])
		tile:EnableMouse(true)
		tile:SetScript("OnEnter", function(self)
			if self.tip then
				Tooltip(self, def[2], self.tip)
			end
		end)
		tile:SetScript("OnLeave", HideTooltip)
		page.tiles[def[1]] = tile
	end

	-- Integrity + actions
	local footer = Panel(page, "Verification")
	footer:SetPoint("TOPLEFT", tiles, "BOTTOMLEFT", 0, -6)
	footer:SetPoint("BOTTOMRIGHT", -4, 4)
	footer.icon = footer:CreateTexture(nil, "ARTWORK")
	footer.icon:SetSize(18, 18)
	footer.icon:SetPoint("TOPLEFT", 14, -38)
	footer.integrity = Text(footer, "GameFontHighlight")
	footer.integrity:SetPoint("LEFT", footer.icon, "RIGHT", 8, 0)
	footer.integrity:SetPoint("RIGHT", footer, "RIGHT", -14, 0)
	footer.help = Text(footer, "GameFontDisableSmall")
	footer.help:SetPoint("TOPLEFT", footer.icon, "BOTTOMLEFT", 0, -10)
	footer.help:SetPoint("RIGHT", footer, "RIGHT", -14, 0)
	footer.help:SetWordWrap(true)
	footer.help:SetText("Share your run on Discord, Reddit or anywhere. Anyone with " .. SF.NAME .. " can paste it into Check a shared run: it opens your profile and compares your run with what witnesses recorded.")

	local export = Button(footer, "Share my run", 140, function()
		UI.ShowExport()
	end)
	export:SetPoint("BOTTOMLEFT", 12, 12)
	local verify = Button(footer, "Check a shared run", 160, function()
		UI.ShowVerify()
	end)
	verify:SetPoint("LEFT", export, "RIGHT", 8, 0)
	local rules = Button(footer, "Rules", 90, function()
		SF.Print("Disqualifies the run:")
		for _, r in ipairs(SF.RULES) do
			SF.Print(" - " .. r)
		end
	end)
	rules:SetPoint("LEFT", verify, "RIGHT", 8, 0)
	rules:SetScript("OnEnter", function(self)
		local lines = {}
		for _, r in ipairs(SF.RULES) do
			lines[#lines + 1] = { "- " .. r, 1, 0.55, 0.55 }
		end
		lines[#lines + 1] = { " " }
		lines[#lines + 1] = { "Marks the run Unverified:", 1, 0.82, 0 }
		for _, r in ipairs(SF.UNVERIFIED_RULES) do
			lines[#lines + 1] = { "- " .. r, 1, 0.9, 0.6 }
		end
		Tooltip(self, SF.TITLE .. " rules", lines)
	end)
	rules:SetScript("OnLeave", HideTooltip)
	page.footer = footer
end

local function Sum(tbl)
	local total = 0
	for _, v in pairs(tbl) do
		total = total + v
	end
	return total
end

local function RefreshOverview(page)
	local run = SF.run
	local status, reason = SF.GetStatus()
	local color = StatusColor(status)
	local s = page.status
	s.tint:SetColorTexture(color[1], color[2], color[3], 0.10)
	s.bar:SetColorTexture(color[1], color[2], color[3], 0.9)
	s.icon:SetTexture(STATUS_ICON[status])
	s.word:SetText(SF.Colorize(status, color))
	local flagText, flagColor = SF.FlagLine(SF.playerKey, nil, true)
	s.witnessed:SetText(flagText and SF.Colorize(flagText, flagColor) or "")
	s.reason:SetText(reason)
	local className, classFile = UnitClass("player")
	local raceName = UnitRace("player")
	local r, g, b = SF.ClassColor(classFile)
	s.char:SetText(SF.Colorize(SF.ShortName(SF.playerKey), { r, g, b }))
	s.info:SetText(string.format("Level %d %s %s", UnitLevel("player") or 0, raceName or "", className or ""))
	s.since:SetText("Tracking since " .. SF.Date(run.created))

	local t = page.tiles
	local stats, items = run.stats, run.items
	t.level.value:SetText(UnitLevel("player") or 0)
	t.played.value:SetText(SF.Duration(SF.PlayedNow()))
	t.played.tip = { "Total play time on this character.", string.format("Untracked: %s", SF.Duration(SF.OpenGapTotal())) }
	for _, g in ipairs(run.gaps) do
		if g.cov then
			local support = SF.GapWitnesses(g)
			table.insert(t.played.tip, { string.format("Crash %s: %s recovered, confirmed by %d witness%s", SF.Date(g.t), SF.Duration(g.s),
				#support, #support == 1 and "" or "es"), 0.3, 0.92, 0.4 })
		end
	end
	t.deaths.value:SetText(Number(stats.deaths))
	t.kills.value:SetText(Number(stats.kills))
	t.kills.tip = { "Enemies killed that gave you experience." }
	t.quests.value:SetText(Number(stats.quests))
	local earned = Sum(run.income)
	t.earned.value:SetText(SF.Money(earned))
	t.earned.tip = { "All gold that came in, from every source. See the Ledger tab for the breakdown." }
	t.worth.value:SetText(SF.Money(SF.WorthTotal()))
	t.worth.tip = { "Gold plus the vendor value of everything you own (bags, equipped, and your bank as of your last visit).", "Peak: " .. SF.Money(run.worth.peak or 0) }
	t.looted.value:SetText(Number(items.lootedCount))
	t.looted.tip = { "Items you looted.", "Vendor value: " .. SF.Money(items.lootedValue) }
	t.trades.value:SetText(Number(stats.trades))
	t.trades.tip = { "Completed trades where something changed hands.", string.format("Trade windows opened: %d", stats.tradeWindows) }
	t.auctions.value:SetText(Number(stats.ahBids + stats.ahBuyouts + stats.ahListed))
	t.auctions.tip = {
		string.format("Auction house opened: %d", stats.ahOpened),
		string.format("Bids: %d   Buyouts: %d", stats.ahBids, stats.ahBuyouts),
		string.format("Listed: %d   Sold: %d", stats.ahListed, stats.ahSold),
	}
	t.mail.value:SetText(Number(stats.mailFromPlayers))
	t.mail.tip = { "Items or gold taken from mail another player sent.", string.format("Mail sent: %d", stats.mailSent) }
	t.witnesses.value:SetText(Number(witnessCount))
	t.witnesses.tip = {
		"Other players running " .. SF.NAME .. " whose addon recorded your progress.",
		{ "Open My profile in the Witnesses tab to see how many of your played hours they can account for.", 0.7, 0.7, 0.7 },
	}

	for _, tile in pairs(t) do
		local danger = (tile == t.trades and stats.trades > 0) or (tile == t.auctions and (stats.ahBids + stats.ahBuyouts + stats.ahListed) > 0)
			or (tile == t.mail and stats.mailFromPlayers > 0)
		if danger then
			tile.value:SetTextColor(1, 0.35, 0.35)
		else
			tile.value:SetTextColor(1, 1, 1)
		end
	end

	local f = page.footer
	if SF.integrity.ok then
		f.icon:SetTexture(STATUS_ICON.CLEAN)
		f.integrity:SetText(string.format("Log integrity verified: %s entries, checksum %s", Number(SF.LogCount()), SF.LogHead():sub(1, 8)))
	else
		f.icon:SetTexture(STATUS_ICON.DISQUALIFIED)
		f.integrity:SetText(SF.Colorize("Integrity check failed: saved data was edited outside the game.", SF.COLOR.DISQUALIFIED))
	end
end

-- ------------------------------- Ledger ----------------------------------

local INCOME_ROWS = {
	{ "loot", "Looted gold", ICON.earned },
	{ "quest", "Quest rewards", ICON.quests },
	{ "vendor", "Vendor sales", ICON.sold },
	{ "mail", "Mail & auctions", ICON.mail },
	{ "other", "Other", ICON.other },
}

local SPENT_ROWS = {
	{ "vendor", "Vendor purchases", ICON.given },
	{ "repair", "Repairs", ICON.repair },
	{ "training", "Training", ICON.training },
	{ "travel", "Flights", ICON.travel },
	{ "fees", "Postage & fees", ICON.fees },
	{ "given", "Given away", ICON.trades },
	{ "other", "Other", ICON.other },
}

local function BuildLedger(page)
	local width = 337

	local income = Panel(page, "Gold earned")
	income:SetPoint("TOPLEFT", 4, -4)
	income:SetSize(width, 238)
	page.income = {}
	for i, def in ipairs(INCOME_ROWS) do
		page.income[def[1]] = StatRow(income, -34 - (i - 1) * 25, def[3], def[2])
	end
	Divider(income, -34 - #INCOME_ROWS * 25)
	page.incomeTotal = StatRow(income, -40 - #INCOME_ROWS * 25, ICON.earned, "Total")
	page.incomeTotal.label:SetFontObject("GameFontNormal")

	local spent = Panel(page, "Gold spent")
	spent:SetPoint("TOPRIGHT", -4, -4)
	spent:SetSize(width, 238)
	page.spent = {}
	for i, def in ipairs(SPENT_ROWS) do
		page.spent[def[1]] = StatRow(spent, -34 - (i - 1) * 24, def[3], def[2])
	end
	Divider(spent, -34 - #SPENT_ROWS * 24)
	page.spentTotal = StatRow(spent, -38 - #SPENT_ROWS * 24, ICON.other, "Total")
	page.spentTotal.label:SetFontObject("GameFontNormal")
	page.spentTotal.icon:SetTexture(ICON.given)

	local worth = Panel(page, "Net worth (vendor value)")
	worth:SetPoint("TOPLEFT", income, "BOTTOMLEFT", 0, -6)
	worth:SetPoint("BOTTOMLEFT", 4, 4)
	worth:SetWidth(width)
	page.worth = {
		money = StatRow(worth, -34, ICON.earned, "Gold on hand"),
		bags = StatRow(worth, -58, ICON.bags, "Bags"),
		equipped = StatRow(worth, -82, ICON.equipped, "Equipped"),
		bank = StatRow(worth, -106, ICON.bank, "Bank"),
	}
	Divider(worth, -132)
	page.worth.total = StatRow(worth, -138, ICON.worth, "Total")
	page.worth.total.label:SetFontObject("GameFontNormal")
	page.worth.peak = StatRow(worth, -162, ICON.peak, "Peak")
	page.worth.bank:EnableMouse(true)
	page.worth.bank:SetScript("OnEnter", function(self)
		Tooltip(self, "Bank", { "Bank contents can only be read while the bank is open, so this is as of your last visit." })
	end)
	page.worth.bank:SetScript("OnLeave", HideTooltip)

	local items = Panel(page, "Items")
	items:SetPoint("TOPRIGHT", spent, "BOTTOMRIGHT", 0, -6)
	items:SetPoint("BOTTOMRIGHT", -4, 4)
	items:SetWidth(width)
	page.items = {
		looted = StatRow(items, -34, ICON.looted, "Looted"),
		sold = StatRow(items, -58, ICON.sold, "Sold to vendors"),
		destroyed = StatRow(items, -82, ICON.destroyed, "Destroyed"),
	}
	local note = Text(items, "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", 14, -114)
	note:SetPoint("RIGHT", items, "RIGHT", -14, 0)
	note:SetWordWrap(true)
	note:SetText("Item values are vendor prices. Anything destroyed or given away no longer counts toward your net worth; selling it turns its value into gold.")
end

local function RefreshLedger(page)
	local run = SF.run
	for key, row in pairs(page.income) do
		row.value:SetText(SF.Money(run.income[key] or 0))
	end
	page.incomeTotal.value:SetText(SF.Money(Sum(run.income)))
	for key, row in pairs(page.spent) do
		row.value:SetText(SF.Money(run.spent[key] or 0))
	end
	page.spentTotal.value:SetText(SF.Money(Sum(run.spent)))

	local w = run.worth
	page.worth.money.value:SetText(SF.Money(w.money))
	page.worth.bags.value:SetText(SF.Money(w.bags))
	page.worth.equipped.value:SetText(SF.Money(w.equipped))
	if w.bankAt then
		page.worth.bank.value:SetText(SF.Money(w.bank + w.bankMoney))
		page.worth.bank.label:SetText("Bank  |cff888888(" .. SF.Ago(w.bankAt) .. ")|r")
	else
		page.worth.bank.value:SetText("|cff888888visit a banker|r")
	end
	page.worth.total.value:SetText(SF.Money(SF.WorthTotal()))
	page.worth.peak.value:SetText(SF.Money(w.peak or 0))

	local items = run.items
	page.items.looted.value:SetText(string.format("%s  |cffaaaaaa(%s)|r", Number(items.lootedCount), SF.Money(items.lootedValue)))
	page.items.sold.value:SetText(string.format("%s  |cffaaaaaa(%s)|r", Number(items.soldCount), SF.Money(run.income.vendor)))
	page.items.destroyed.value:SetText(string.format("%s  |cffaaaaaa(%s)|r", Number(items.destroyedCount), SF.Money(items.destroyedValue)))
end

-- -------------------------------- Log ------------------------------------

local function InitLogRow(row, e)
	if not row.built then
		row.built = true
		row:SetHeight(22)
		RowHighlight(row)
		row.time = Text(row, "GameFontDisableSmall")
		row.time:SetPoint("LEFT", 4, 0)
		row.time:SetWidth(96)
		row.icon = Icon(row, 16)
		row.icon:SetPoint("LEFT", row.time, "RIGHT", 4, 0)
		row.text = Text(row, "GameFontHighlightSmall")
		row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
		row.text:SetPoint("RIGHT", -4, 0)
		row.text:SetWordWrap(false)
		row:SetScript("OnEnter", function(self)
			local entry = self.entry
			if entry then
				local lines = { entry.m }
				local seenBy = entry.key and SF.run.milestones[entry.key]
				if seenBy and #seenBy > 0 then
					local names = {}
					for _, name in ipairs(seenBy) do
						names[#names + 1] = SF.ShortName(name)
					end
					lines[#lines + 1] = { "Witnessed by " .. table.concat(names, ", "), 0.3, 0.92, 0.4 }
				end
				lines[#lines + 1] = { "Checksum " .. tostring(entry.h), 0.5, 0.5, 0.5 }
				Tooltip(self, SF.Date(entry.t), lines)
			end
		end)
		row:SetScript("OnLeave", HideTooltip)
	end
	row.entry = e
	row.time:SetText(date("%m/%d %H:%M", e.t))
	row.icon:SetTexture(LOG_ICON[e.k] or ICON.fees)
	local color = LOG_COLOR[e.k] or (e.x and SF.COLOR.GRAY) or SF.COLOR.WHITE
	-- "Who was there" for level-ups and deaths.
	local seenBy = e.key and SF.run.milestones[e.key]
	row.text:SetText(e.m .. (seenBy and #seenBy > 0 and string.format("  |cff4deb66witnessed by %d|r", #seenBy) or ""))
	row.text:SetTextColor(color[1], color[2], color[3])
end

local function BuildLog(page)
	local check = Checkbox(page, "Show routine events (quests, mail, destroyed items...)", function()
		return SF.settings.showMinorLog
	end, function(value)
		SF.settings.showMinorLog = value
		UI.Refresh()
	end)
	check:SetPoint("TOPLEFT", 8, -6)
	page.count = Text(page, "GameFontDisableSmall", "RIGHT")
	page.count:SetPoint("TOPRIGHT", -12, -12)

	local panel = Panel(page, "Event log")
	panel:SetPoint("TOPLEFT", 4, -34)
	panel:SetPoint("BOTTOMRIGHT", -4, 4)
	page.list = List(panel, 22, InitLogRow)
end

local function RefreshLog(page)
	local list = {}
	local showMinor = SF.settings.showMinorLog
	local log = SF.cdb.log
	for i = #log, 1, -1 do
		local e = log[i]
		if showMinor or not e.x then
			list[#list + 1] = e
		end
	end
	page.list:SetList(list)
	page.count:SetText(string.format("%s entries", Number(SF.LogCount())))
end

-- ------------------------------ Witnesses --------------------------------

local function InitWitnessedRow(row, data)
	if not row.built then
		row.built = true
		row:SetHeight(24)
		RowHighlight(row)
		row.name = Text(row, "GameFontHighlight")
		row.name:SetPoint("LEFT", 6, 0)
		row.name:SetWidth(110)
		row.name:SetWordWrap(false)
		row.status = Text(row, "GameFontHighlightSmall")
		row.status:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
		row.status:SetWidth(80)
		row.level = Text(row, "GameFontHighlightSmall")
		row.level:SetPoint("LEFT", row.status, "RIGHT", 4, 0)
		row.level:SetWidth(40)
		row.hours = Text(row, "GameFontHighlightSmall")
		row.hours:SetPoint("LEFT", row.level, "RIGHT", 4, 0)
		row.hours:SetWidth(45)
		row.flag = Text(row, "GameFontHighlightSmall")
		row.flag:SetPoint("LEFT", row.hours, "RIGHT", 4, 0)
		row.flag:SetWidth(75)
		row.flag:SetWordWrap(false)
		row.flag:SetTextColor(1, 0.6, 0.2)
		row.seen = Text(row, "GameFontDisableSmall", "RIGHT")
		row.seen:SetPoint("RIGHT", -6, 0)
		row:SetScript("OnClick", function(self)
			if self.data then
				UI.ShowProfile(self.data.name)
			end
		end)
		row:SetScript("OnEnter", function(self)
			local d = self.data
			if not d then
				return
			end
			local l = d.rec.latest or {}
			Tooltip(self, d.name .. "  |cff888888(click for profile)|r", {
				"Status: " .. SF.StatusText(l.s or "?") .. "  |cff888888(their addon's report)|r",
				string.format("You witnessed %dh of their play", SF.SpanHours(d.rec.hours)),
				string.format("Level %d, %s played", l.lvl or 0, SF.Duration(l.pl)),
				string.format("Deaths %d, violations %d, untracked %s", l.d or 0, l.v or 0, SF.Duration(l.g)),
				{ string.format("Seen %d times; first %s, last %s", d.rec.n or 0, SF.Date(d.rec.first), SF.Ago(d.rec.last)), 0.6, 0.6, 0.6 },
				{ "Addon version: " .. (l.ver and l.ver ~= "" and l.ver or "unknown (older than 1.0.0)"), 0.6, 0.6, 0.6 },
			})
		end)
		row:SetScript("OnLeave", HideTooltip)
	end
	row.data = data
	local l = data.rec.latest or {}
	local r, g, b = SF.ClassColor(data.rec.class)
	row.name:SetText(SF.Colorize(SF.ShortName(data.name), { r, g, b }))
	row.status:SetText(SF.StatusText(l.s or "?"))
	row.level:SetText("Lvl " .. (l.lvl or "?"))
	local summary = SF.WitnessSummary(data.rec)
	row.hours:SetText(summary and summary.hours .. "h" or "")
	local flags = SF.FlagSummary(data.name, l.s)
	if flags.count > 0 then
		row.flag:SetText(SF.Colorize(string.format("%d flag%s", flags.count, flags.count == 1 and "" or "s"), flags.red and SF.COLOR.DISQUALIFIED or { 1, 0.6, 0.2 }))
	elseif summary and summary.silentNow then
		row.flag:SetText("no addon now")
	else
		row.flag:SetText("")
	end
	row.seen:SetText(SF.Ago(data.rec.last))
end

local function InitWitnessRow(row, data)
	if not row.built then
		row.built = true
		row:SetHeight(24)
		RowHighlight(row)
		row.name = Text(row, "GameFontHighlight")
		row.name:SetPoint("LEFT", 6, 0)
		row.name:SetPoint("RIGHT", -60, 0)
		row.name:SetWordWrap(false)
		row.count = Text(row, "GameFontDisableSmall", "RIGHT")
		row.count:SetPoint("RIGHT", -6, 0)
		row:SetScript("OnClick", function(self)
			if self.data then
				UI.ShowProfile(self.data.name)
			end
		end)
		row:SetScript("OnEnter", function(self)
			local d = self.data
			if d then
				Tooltip(self, d.name .. "  |cff888888(click for profile)|r", { string.format("Recorded your run %d times.", d.n), "Last: " .. SF.Ago(d.last) })
			end
		end)
		row:SetScript("OnLeave", HideTooltip)
	end
	row.data = data
	row.name:SetText(SF.ShortName(data.name))
	row.count:SetText("x" .. data.n)
end

local RefreshWitnesses -- defined below; the search box refreshes the lists

local WITNESS_HELP = {
	{ "Everyone running " .. SF.NAME .. " in your guild or group automatically tells each other's addons how their run is going, every minute. Each addon keeps what it saw.", 1, 1, 1 },
	{ " " },
	{ "Players you've witnessed: players your addon has recorded.", 0.8, 0.8, 0.8 },
	{ "Your witnesses: players whose addon has recorded you.", 0.8, 0.8, 0.8 },
	{ " " },
	{ "Why it matters: your own saved data lives on your computer, but these records live on other people's computers, so they can't be faked or erased. Click any player (or search) to see everything recorded about them, and ask other witnesses what they saw.", 0.8, 0.8, 0.8 },
	{ " " },
	{ " " },
	{ "Flags: if your addon catches someone breaking the pattern of a clean run (their addon said DISQUALIFIED and later claims fewer violations, or they're online without " .. SF.NAME .. " for 10+ minutes), it flags them with your name, and every witness learns it. Tooltips show flags once 2+ players reported them. Flags never change anyone's status.", 0.8, 0.8, 0.8 },
	{ " " },
	{ "Witnesses also recover crashes.", 0.6, 0.6, 0.6 },
}

-- Search box with a suggestion dropdown: find any player you know (or type
-- any name) and open their profile.
local function BuildPlayerSearch(parent, onChanged)
	local box = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
	box:SetSize(220, 20)
	box:SetAutoFocus(false)
	if box.Instructions then
		box.Instructions:SetText("Check a player...")
	end

	local drop = CreateFrame("Frame", nil, box, "BackdropTemplate")
	drop:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -2)
	drop:SetWidth(250)
	drop:SetFrameStrata("DIALOG")
	if drop.SetBackdrop then
		drop:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		drop:SetBackdropColor(0.08, 0.08, 0.08, 0.96)
	end
	drop:Hide()
	drop.buttons = {}
	local MAX = 8

	local function Open(name)
		box:SetText("")
		box:ClearFocus()
		drop:Hide()
		if name then
			UI.ShowProfile(name)
		end
	end

	for i = 1, MAX do
		local b = CreateFrame("Button", nil, drop)
		b:SetHeight(20)
		b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 20)
		b:SetPoint("RIGHT", -6, 0)
		RowHighlight(b)
		b.text = Text(b, "GameFontHighlightSmall")
		b.text:SetPoint("LEFT", 4, 0)
		b.text:SetPoint("RIGHT", -60, 0)
		b.text:SetWordWrap(false)
		b.info = Text(b, "GameFontDisableSmall", "RIGHT")
		b.info:SetPoint("RIGHT", -4, 0)
		b:SetScript("OnClick", function(self)
			Open(self.target)
		end)
		drop.buttons[i] = b
	end

	local function Suggest()
		local text = (box:GetText() or ""):match("^%s*(.-)%s*$")
		drop.first = nil
		if text == "" then
			drop:Hide()
			return
		end
		local needle = text:lower()
		local shown = 0
		for _, entry in ipairs(SF.KnownPlayers()) do
			if shown >= MAX - 1 then
				break
			end
			if SF.ShortName(entry.name):lower():find(needle, 1, true) then
				shown = shown + 1
				local b = drop.buttons[shown]
				local rec = SF.db.witness[entry.name]
				local r, g, bl = SF.ClassColor(rec and rec.class)
				b.target = entry.name
				b.text:SetText(SF.Colorize(SF.ShortName(entry.name), { r, g, bl }))
				b.info:SetText(rec and rec.latest and SF.StatusText(rec.latest.s) or "|cff888888witness|r")
				b:Show()
				drop.first = drop.first or entry.name
			end
		end
		-- Any name can be checked, even one you've never seen.
		local typed = SF.ResolveName(text)
		if typed and not (drop.first and SF.ShortName(drop.first):lower() == needle) then
			shown = shown + 1
			local b = drop.buttons[shown]
			b.target = typed
			b.text:SetText(string.format("Check |cffffd100%s|r", SF.ShortName(typed)))
			b.info:SetText("")
			b:Show()
			drop.first = drop.first or typed
		end
		for i = shown + 1, MAX do
			drop.buttons[i]:Hide()
		end
		drop:SetHeight(12 + shown * 20)
		drop:SetShown(shown > 0)
	end

	box:HookScript("OnTextChanged", function(self)
		Suggest()
		if onChanged then
			onChanged((self:GetText() or ""):match("^%s*(.-)%s*$"):lower())
		end
	end)
	box:HookScript("OnEnterPressed", function()
		Open(drop.first)
	end)
	box:HookScript("OnEditFocusLost", function()
		-- Let a click on a suggestion land first.
		SF.After(0.2, function()
			drop:Hide()
		end)
	end)
	box:HookScript("OnEditFocusGained", Suggest)
	return box
end

local function BuildWitnesses(page)
	local settings = CreateFrame("Frame", nil, page)
	settings:SetPoint("TOPLEFT", 4, -2)
	settings:SetPoint("TOPRIGHT", -4, -2)
	settings:SetHeight(58)

	-- Row 1: find players, your own profile, help; your rating on the right.
	page.search = BuildPlayerSearch(settings, function(filter)
		page.filter = filter
		RefreshWitnesses(page)
	end)
	page.search:SetPoint("TOPLEFT", 12, -6)
	local me = Button(settings, "My profile", 100, function()
		UI.ShowProfile(SF.playerKey)
	end)
	me:SetHeight(22)
	me:SetPoint("LEFT", page.search, "RIGHT", 10, 0)
	me:SetScript("OnEnter", function(self)
		Tooltip(self, "My profile", { "See your run the way others can check it, and ask your witnesses what their addons recorded of you." })
	end)
	me:SetScript("OnLeave", HideTooltip)
	local help = CreateFrame("Button", nil, settings)
	help:SetSize(20, 20)
	help:SetPoint("LEFT", me, "RIGHT", 6, 0)
	help:SetNormalTexture("Interface\\FriendsFrame\\InformationIcon")
	help:SetHighlightTexture("Interface\\FriendsFrame\\InformationIcon", "ADD")
	help:SetScript("OnEnter", function(self)
		Tooltip(self, "How witnesses work", WITNESS_HELP)
	end)
	help:SetScript("OnLeave", HideTooltip)

	page.witnessedBy = Text(settings, "GameFontNormal", "RIGHT")
	page.witnessedBy:SetPoint("TOPRIGHT", -10, -9)

	-- Row 2: settings (progress is always shared: a run that could go quiet
	-- while breaking a rule would make witnessing meaningless), broadcast.
	local tooltips = Checkbox(settings, "Status in player tooltips", function()
		return SF.settings.tooltips
	end, function(v)
		SF.settings.tooltips = v
	end)
	tooltips:SetPoint("TOPLEFT", 4, -32)
	local warnings = Checkbox(settings, "Warn at trade, auction and mail windows", function()
		return SF.settings.warnings
	end, function(v)
		SF.settings.warnings = v
	end)
	warnings:SetPoint("TOPLEFT", 200, -32)
	local now = Button(settings, "Broadcast now", 120, function()
		SF.Broadcast(true)
		SF.Print("Sent your progress to guild and group members running " .. SF.NAME .. ".")
	end)
	now:SetHeight(22)
	now:SetPoint("TOPRIGHT", -8, -34)
	now:SetScript("OnEnter", function(self)
		Tooltip(self, "Broadcast now", { "Your progress is shared automatically every minute with guild and group members running " .. SF.NAME .. ".", "Use this to share it right away, e.g. after joining a group." })
	end)
	now:SetScript("OnLeave", HideTooltip)

	local seen = Panel(page, "Players you've witnessed")
	seen:SetPoint("TOPLEFT", 4, -62)
	seen:SetPoint("BOTTOMLEFT", 4, 4)
	seen:SetWidth(444)
	page.seenPanel = seen
	page.seenList = List(seen, 24, InitWitnessedRow)

	local mine = Panel(page, "Your witnesses")
	mine:SetPoint("TOPLEFT", seen, "TOPRIGHT", 6, 0)
	mine:SetPoint("BOTTOMRIGHT", -4, 4)
	page.minePanel = mine
	page.mineList = List(mine, 24, InitWitnessRow)

	page.empty = Text(seen, "GameFontDisableSmall", "CENTER")
	page.empty:SetPoint("CENTER", 0, -10)
	page.empty:SetWidth(360)
	page.empty:SetWordWrap(true)
	page.empty:SetText("No one yet. When guild or group members also run " .. SF.NAME .. ", you'll automatically record each other's progress here.")
end

function RefreshWitnesses(page)
	local filter = page.filter ~= "" and page.filter or nil
	local function Matches(name)
		return not filter or SF.ShortName(name):lower():find(filter, 1, true) ~= nil
	end
	local seen, total = {}, 0
	for name, rec in pairs(SF.db.witness) do
		if type(rec) == "table" and rec.latest then
			total = total + 1
			if Matches(name) then
				seen[#seen + 1] = { name = name, rec = rec }
			end
		end
	end
	table.sort(seen, function(a, b)
		return (a.rec.last or 0) > (b.rec.last or 0)
	end)
	page.seenList:SetList(seen)
	page.seenPanel.title:SetText(string.format("Players you've witnessed (%d)", total))
	page.empty:SetShown(total == 0)

	local mine = {}
	for _, w in ipairs(SF.WitnessList()) do
		if Matches(w.name) then
			mine[#mine + 1] = w
		end
	end
	page.mineList:SetList(mine)
	page.minePanel.title:SetText(string.format("Your witnesses (%d)", #SF.WitnessList()))

	local flagText, flagColor = SF.FlagLine(SF.playerKey, nil, true)
	page.witnessedBy:SetText(flagText and SF.Colorize(flagText, flagColor) or SF.Colorize("No flags on you", SF.COLOR.GRAY))
end

-- ------------------------------ Frame ------------------------------------

local BUILDERS = { BuildOverview, BuildLedger, BuildLog, BuildWitnesses }
local REFRESHERS = { RefreshOverview, RefreshLedger, RefreshLog, RefreshWitnesses }

local function RefreshHeader()
	local status = SF.GetStatus()
	main.headerStatus:SetText(SF.Colorize(status, StatusColor(status)))
	main.headerIcon:SetTexture(STATUS_ICON[status])
end

function UI.Refresh()
	if not main or not main:IsShown() or not SF.run then
		return
	end
	RefreshHeader()
	local index = main.selectedTab or 1
	SF.SafeCall(REFRESHERS[index], pages[index])
end

local refreshQueued = false
local function QueueRefresh()
	if refreshQueued or not main or not main:IsShown() then
		return
	end
	refreshQueued = true
	SF.After(0.25, function()
		refreshQueued = false
		UI.Refresh()
	end)
end

function UI.SelectTab(index)
	main.selectedTab = index
	if PanelTemplates_SetTab then
		PanelTemplates_SetTab(main, index)
	end
	for i, page in ipairs(pages) do
		page:SetShown(i == index)
	end
	UI.Refresh()
end

local function CreateMain()
	main = CreateFrame("Frame", "SelfFoundFrame", UIParent, "ButtonFrameTemplate")
	main:SetSize(700, 560)
	main:SetPoint("CENTER")
	main:SetFrameStrata("HIGH")
	main:SetToplevel(true)
	main:SetClampedToScreen(true)
	main:SetMovable(true)
	main:EnableMouse(true)
	main:RegisterForDrag("LeftButton")
	main:SetScript("OnDragStart", main.StartMoving)
	main:SetScript("OnDragStop", main.StopMovingOrSizing)
	if main.SetTitle then
		main:SetTitle(SF.TITLE)
	end
	if main.SetPortraitToAsset then
		main:SetPortraitToAsset(SF.ICON)
	end
	if ButtonFrameTemplate_HideButtonBar then
		ButtonFrameTemplate_HideButtonBar(main)
	end
	tinsert(UISpecialFrames, "SelfFoundFrame")

	-- Header strip under the title bar: character + status at a glance.
	main.headerText = Text(main, "GameFontHighlight")
	main.headerText:SetPoint("TOPLEFT", 66, -34)
	main.headerIcon = main:CreateTexture(nil, "ARTWORK")
	main.headerIcon:SetSize(16, 16)
	main.headerIcon:SetPoint("TOPRIGHT", -14, -33)
	main.headerStatus = Text(main, "GameFontNormal", "RIGHT")
	main.headerStatus:SetPoint("RIGHT", main.headerIcon, "LEFT", -6, 0)
	main.headerText:SetText(SF.run and SF.ShortName(SF.run.char) or "")

	-- Version and official source, beside the tabs.
	main.about = Text(main, "GameFontDisableSmall", "RIGHT")
	main.about:SetPoint("TOPRIGHT", main, "BOTTOMRIGHT", -10, -8)
	main.about:SetText(string.format("%s  |  %s", SF.VERSION == "dev" and "dev build" or ("v" .. SF.VERSION), SF.WEBSITE))

	for i, builder in ipairs(BUILDERS) do
		local page = CreateFrame("Frame", nil, main.Inset)
		page:SetPoint("TOPLEFT", 2, -2)
		page:SetPoint("BOTTOMRIGHT", -2, 2)
		page:Hide()
		builder(page)
		pages[i] = page
	end

	for i, name in ipairs(TABS) do
		local tab = CreateFrame("Button", "SelfFoundFrameTab" .. i, main, "PanelTabButtonTemplate")
		tab:SetID(i)
		tab:SetText(name)
		tab:SetScript("OnClick", function(self)
			UI.SelectTab(self:GetID())
			if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then
				PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
			end
		end)
		if i == 1 then
			tab:SetPoint("TOPLEFT", main, "BOTTOMLEFT", 12, 2)
		else
			tab:SetPoint("TOPLEFT", _G["SelfFoundFrameTab" .. (i - 1)], "TOPRIGHT", 3, 0)
		end
		if PanelTemplates_TabResize then
			pcall(PanelTemplates_TabResize, tab, 15)
		end
	end
	if PanelTemplates_SetNumTabs then
		PanelTemplates_SetNumTabs(main, #TABS)
	end

	main:SetScript("OnShow", function()
		if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN then
			PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
		end
		UI.Refresh()
	end)
	-- Keep the play time counting while the Overview is open.
	local elapsedSince = 0
	main:SetScript("OnUpdate", function(_, elapsed)
		elapsedSince = elapsedSince + elapsed
		if elapsedSince >= 1 and main.selectedTab == 1 and SF.run then
			elapsedSince = 0
			pages[1].tiles.played.value:SetText(SF.Duration(SF.PlayedNow()))
		end
	end)
	main:SetScript("OnHide", function()
		if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_CLOSE then
			PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
		end
	end)
	main:Hide()
	UI.SelectTab(1)
end

function UI.Toggle()
	if not SF.run then
		SF.Print("Still loading, try again in a moment.")
		return
	end
	if not main then
		CreateMain()
	end
	main:SetShown(not main:IsShown())
end

function UI.Open(tab)
	if not SF.run then
		return
	end
	if not main then
		CreateMain()
	end
	main:Show()
	if tab then
		UI.SelectTab(tab)
	end
end

for _, name in ipairs({ "StatsChanged", "StatusChanged", "LogChanged", "WitnessChanged" }) do
	SF.Listen(name, QueueRefresh)
end

-- ---------------------------------------------------------------------------
-- Share my run / Check a shared run
-- ---------------------------------------------------------------------------

local function Dialog(name, title, height)
	local frame = CreateFrame("Frame", name, UIParent, "ButtonFrameTemplate")
	frame:SetSize(560, height)
	frame:SetPoint("CENTER", 0, 20)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	if frame.SetTitle then
		frame:SetTitle(title)
	end
	if frame.SetPortraitToAsset then
		frame:SetPortraitToAsset(SF.ICON)
	end
	if ButtonFrameTemplate_HideButtonBar then
		ButtonFrameTemplate_HideButtonBar(frame)
	end
	tinsert(UISpecialFrames, name)
	return frame
end

local function TextArea(parent, width, height)
	local scroll = CreateFrame("ScrollFrame", nil, parent, "InputScrollFrameTemplate")
	scroll:SetSize(width, height)
	scroll.EditBox:SetWidth(width - 18)
	scroll.EditBox:SetFontObject("ChatFontNormal")
	if scroll.CharCount then
		scroll.CharCount:Hide()
	end
	if scroll.EditBox.Instructions then
		scroll.EditBox.Instructions:SetText("")
	end
	return scroll
end

-- Shared widget helpers for other UI files (ProfileUI.lua).
UI.Kit = {
	Text = Text, Icon = Icon, Panel = Panel, Button = Button, List = List,
	Tooltip = Tooltip, HideTooltip = HideTooltip, RowHighlight = RowHighlight,
	Number = Number, Dialog = Dialog, StatusColor = StatusColor,
}

local exportFrame

function UI.ShowExport()
	if not SF.run then
		return
	end
	if not exportFrame then
		exportFrame = Dialog("SelfFoundExportFrame", "Share my run", 460)
		local hint = Text(exportFrame, "GameFontHighlightSmall")
		hint:SetPoint("TOPLEFT", 66, -32)
		hint:SetPoint("RIGHT", exportFrame, "RIGHT", -16, 0)
		hint:SetWordWrap(true)
		hint:SetText("Press Ctrl+C to copy, then paste it anywhere. Anyone with " .. SF.NAME .. " can check it with Check a shared run.")
		exportFrame.area = TextArea(exportFrame.Inset, 516, 330)
		exportFrame.area:SetPoint("TOPLEFT", 12, -10)
		local edit = exportFrame.area.EditBox
		edit:HookScript("OnTextChanged", function(self, userInput)
			if userInput and exportFrame.text then
				self:SetText(exportFrame.text)
				self:HighlightText()
			end
		end)
		local select = Button(exportFrame.Inset, "Select all", 120, function()
			edit:SetFocus()
			edit:HighlightText()
		end)
		select:SetPoint("BOTTOMRIGHT", -10, 8)
	end
	exportFrame.text = SF.ExportReport()
	local edit = exportFrame.area.EditBox
	edit:SetText(exportFrame.text)
	exportFrame:Show()
	edit:SetFocus()
	edit:HighlightText()
end

local verifyFrame

-- Paste someone's shared run: if it's genuine, their profile opens with the
-- run's claims shown next to your records and the witnesses' evidence.
function UI.ShowVerify()
	if not SF.run then
		return
	end
	if not verifyFrame then
		verifyFrame = Dialog("SelfFoundVerifyFrame", "Check a shared run", 330)
		local hint = Text(verifyFrame, "GameFontHighlightSmall")
		hint:SetPoint("TOPLEFT", 66, -32)
		hint:SetPoint("RIGHT", verifyFrame, "RIGHT", -16, 0)
		hint:SetWordWrap(true)
		hint:SetText("Paste a run someone shared. Their profile opens with it, next to your records, their witness record and any flags.")
		verifyFrame.area = TextArea(verifyFrame.Inset, 516, 150)
		verifyFrame.area:SetPoint("TOPLEFT", 12, -10)
		local check = Button(verifyFrame.Inset, "Check", 120, function()
			local report, err = SF.DecodeReport(verifyFrame.area.EditBox:GetText())
			if not report then
				verifyFrame.result:SetText("|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t " .. SF.Colorize(err, SF.COLOR.DISQUALIFIED))
				return
			end
			verifyFrame.result:SetText("")
			verifyFrame.area.EditBox:SetText("")
			verifyFrame:Hide()
			UI.ShowProfile(report.char, true, report)
		end)
		check:SetPoint("TOPLEFT", verifyFrame.area, "BOTTOMLEFT", -4, -10)
		local clear = Button(verifyFrame.Inset, "Clear", 90, function()
			verifyFrame.area.EditBox:SetText("")
			verifyFrame.result:SetText("")
		end)
		clear:SetPoint("LEFT", check, "RIGHT", 8, 0)
		verifyFrame.result = Text(verifyFrame.Inset, "GameFontHighlight")
		verifyFrame.result:SetPoint("TOPLEFT", check, "BOTTOMLEFT", 4, -12)
		verifyFrame.result:SetPoint("RIGHT", verifyFrame.Inset, "RIGHT", -14, 0)
		verifyFrame.result:SetWordWrap(true)
	end
	verifyFrame:Show()
	verifyFrame.area.EditBox:SetFocus()
end

-- ---------------------------------------------------------------------------
-- Slash commands, addon compartment, login message
-- ---------------------------------------------------------------------------

SLASH_SELFFOUND1 = "/selffound"
SLASH_SELFFOUND2 = "/sf"
SlashCmdList.SELFFOUND = function(msg)
	local raw = (msg or ""):match("^%s*(.-)%s*$")
	msg = raw:lower()
	if msg == "" then
		UI.Toggle()
	elseif msg == "check" or msg:match("^check ") then
		local name = SF.ResolveName(raw:match("^%S+%s+(.+)$") or "")
		UI.ShowProfile(name or SF.playerKey)
	elseif msg == "status" then
		local status, reason = SF.GetStatus()
		SF.Print(SF.Colorize(status, StatusColor(status)) .. " - " .. reason)
		local flagText = SF.FlagLine(SF.playerKey, nil, true)
		if flagText then
			SF.Print(flagText .. " (see /sf check)")
		end
	elseif msg == "share" or msg == "export" then
		UI.ShowExport()
	elseif msg == "verify" then
		UI.ShowVerify()
	elseif msg == "log" then
		UI.Open(3)
	elseif msg == "minimap" then
		SF.settings.minimap.hide = not SF.settings.minimap.hide
		SF.Fire("MinimapSettingChanged")
		SF.Print("Minimap button " .. (SF.settings.minimap.hide and "hidden" or "shown") .. ".")
	elseif msg == "broadcast" then
		SF.Broadcast(true)
		SF.Print("Sent your progress to guild and group members running " .. SF.NAME .. ".")
	elseif msg == "preview" then
		-- Display-only samples (for screenshots/testing): never saved, never
		-- sent to other players, gone after /reload.
		if SF.preview then
			SF.preview = nil
			SF.Print("Preview off.")
		else
			SF.preview = {}
			SF.ShowAlert("Preview: Completed a trade with Someone (received 1 copper)")
			SF.Print("Preview: this is the disqualification alert. Nothing was saved or shared.")
		end
		SF.Fire("StatusChanged")
	else
		SF.Print(string.format("%s %s - official download: %s", SF.TITLE, SF.VERSION, SF.WEBSITE))
		SF.Print("/sf - open the window")
		SF.Print("/sf status - print your run status")
		SF.Print("/sf check <name> - check a player: what you and other witnesses saw")
		SF.Print("/sf share - share my run   /sf verify - check a shared run")
		SF.Print("/sf minimap - show/hide the minimap button")
		SF.Print("/sf preview - preview the disqualification alert (nothing is saved)")
	end
end

function SelfFound_OnAddonCompartmentClick()
	UI.Toggle()
end

function SelfFound_OnAddonCompartmentEnter(_, button)
	local owner = button or (AddonCompartmentFrame) or UIParent
	local status, reason = SF.GetStatus()
	Tooltip(owner, SF.TITLE, {
		SF.Colorize(status, StatusColor(status)),
		{ reason, 0.8, 0.8, 0.8 },
		{ "Click to open", 0.6, 0.6, 0.6 },
	})
end

function SelfFound_OnAddonCompartmentLeave()
	HideTooltip()
end

SF.Listen("Ready", function()
	local status, reason = SF.GetStatus()
	SF.Print(string.format("tracking %s - %s. Type /sf to open.", SF.ShortName(SF.run.char), SF.Colorize(status, StatusColor(status))))
	if status == "DISQUALIFIED" and not SF.integrity.ok then
		SF.Print(SF.Colorize(reason, SF.COLOR.DISQUALIFIED))
	end
end)
