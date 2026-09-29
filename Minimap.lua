-- Self Found - Minimap button
-- Round button on the minimap edge (drag to move) with a small status pip.
-- Left-click opens the window, right-click shares your report.

local ADDON, SF = ...

local STATUS_ICON = {
	CLEAN = "Interface\\RaidFrame\\ReadyCheck-Ready",
	UNVERIFIED = "Interface\\RaidFrame\\ReadyCheck-Waiting",
	DISQUALIFIED = "Interface\\RaidFrame\\ReadyCheck-NotReady",
}

local button

local function Radius()
	local width = Minimap and Minimap:GetWidth() or 140
	return width / 2 + 5
end

local function Place()
	local angle = math.rad(SF.settings.minimap.angle or 205)
	local r = Radius()
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function UpdateVisibility()
	if button then
		button:SetShown(not SF.settings.minimap.hide)
	end
end

local function UpdateStatus()
	if button then
		local status = SF.GetStatus()
		button.status:SetTexture(STATUS_ICON[status])
	end
end

local function DragUpdate()
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	cx, cy = cx / scale, cy / scale
	SF.settings.minimap.angle = math.floor(math.deg(math.atan2(cy - my, cx - mx)) % 360)
	Place()
end

local function ShowTooltip(self)
	local status, reason = SF.GetStatus()
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText(SF.TITLE, 1, 0.82, 0)
	local color = SF.COLOR[status] or SF.COLOR.GRAY
	GameTooltip:AddLine(status, color[1], color[2], color[3])
	if SF.run then
		local flagText, flagColor = SF.FlagLine(SF.playerKey, nil, true)
		if flagText then
			GameTooltip:AddLine(flagText, flagColor[1], flagColor[2], flagColor[3], true)
		end
	end
	GameTooltip:AddLine(reason, 0.85, 0.85, 0.85, true)
	if SF.run then
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine("Deaths", tostring(SF.run.stats.deaths), 0.7, 0.7, 0.7, 1, 1, 1)
		GameTooltip:AddDoubleLine("Net worth", SF.Money(SF.WorthTotal()), 0.7, 0.7, 0.7, 1, 1, 1)
		GameTooltip:AddDoubleLine("Played", SF.Duration(SF.PlayedNow()), 0.7, 0.7, 0.7, 1, 1, 1)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Left-click: open   Right-click: share my run", 0.5, 0.5, 0.5)
	GameTooltip:AddLine("Drag to move", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function Create()
	if button or not Minimap then
		return
	end
	button = CreateFrame("Button", "SelfFoundMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetSize(20, 20)
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetPoint("TOPLEFT", 7, -5)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18)
	icon:SetTexture(SF.ICON)
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
	icon:SetPoint("TOPLEFT", 7, -6)
	button.icon = icon

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(50, 50)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT")

	local status = button:CreateTexture(nil, "OVERLAY", nil, 2)
	status:SetSize(12, 12)
	status:SetPoint("BOTTOMRIGHT", -2, 3)
	button.status = status

	button:SetScript("OnMouseDown", function()
		icon:SetPoint("TOPLEFT", 8, -7)
	end)
	button:SetScript("OnMouseUp", function()
		icon:SetPoint("TOPLEFT", 7, -6)
	end)
	button:SetScript("OnClick", function(_, mouseButton)
		if mouseButton == "RightButton" then
			SF.UI.ShowExport()
		else
			SF.UI.Toggle()
		end
	end)
	button:SetScript("OnDragStart", function(self)
		self:LockHighlight()
		self:SetScript("OnUpdate", DragUpdate)
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		self:UnlockHighlight()
		icon:SetPoint("TOPLEFT", 7, -6)
	end)
	button:SetScript("OnEnter", ShowTooltip)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	Place()
	UpdateStatus()
	UpdateVisibility()
end

SF.Listen("Ready", Create)
SF.Listen("StatusChanged", UpdateStatus)
SF.Listen("MinimapSettingChanged", UpdateVisibility)
