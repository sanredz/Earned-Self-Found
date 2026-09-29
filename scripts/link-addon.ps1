# Links the game's AddOns\EarnedSelfFound folder to this repo (a directory
# junction), so edits here are live in-game after /reload. Run once per machine:
#   powershell -ExecutionPolicy Bypass -File scripts\link-addon.ps1
# An existing real EarnedSelfFound folder is moved to Interface\EarnedSelfFound.bak-<time>
# (saved data lives in WTF\, not here, so nothing is lost). A leftover link from
# the addon's old folder name (AddOns\SelfFound) is removed.

param(
	[string]$AddOns = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$name = "EarnedSelfFound"
$target = Join-Path $AddOns $name

if (-not (Test-Path $AddOns)) {
	throw "AddOns folder not found: $AddOns (pass -AddOns <path>)"
}

# Old folder name: remove it only if it's a link to this repo (never its contents).
$old = Get-Item (Join-Path $AddOns "SelfFound") -ErrorAction SilentlyContinue
if ($old -and ($old.LinkType -eq "Junction" -or $old.LinkType -eq "SymbolicLink") -and ($old.Target -contains $repo)) {
	[System.IO.Directory]::Delete($old.FullName)
	Write-Host "Removed old link $($old.FullName)"
}

$existing = Get-Item $target -ErrorAction SilentlyContinue
if ($existing) {
	if ($existing.LinkType -eq "Junction" -or $existing.LinkType -eq "SymbolicLink") {
		if ($existing.Target -contains $repo) {
			Write-Host "Already linked: $target -> $repo"
			exit 0
		}
		# Remove only the link itself, never the folder it points to.
		[System.IO.Directory]::Delete($target)
	} else {
		# Back up outside AddOns so the game never sees two copies.
		$backup = Join-Path (Split-Path $AddOns) ("$name.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
		Move-Item $target $backup
		Write-Host "Moved existing folder to $backup"
	}
}

New-Item -ItemType Junction -Path $target -Target $repo | Out-Null
Write-Host "Linked $target -> $repo"
