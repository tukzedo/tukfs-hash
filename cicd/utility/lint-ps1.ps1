#==============================================================================
## lint-ps1.ps1
##
##	PSScriptAnalyzer over each file given, with the repo's
##	PSScriptAnalyzerSettings.psd1, and a parse of each first. Prints what it
##	finds, and exits 1 when it finds anything.
##
##	Usage:
##		pwsh -NoProfile -File cicd/utility/lint-ps1.ps1 FILE...
##
##	History: At bottom of script.
#==============================================================================

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Lints PowerShell files with the repo's PSScriptAnalyzer settings.
.PARAMETER Path
The files to lint.
.EXAMPLE
pwsh -NoProfile -File cicd/utility/lint-ps1.ps1 utility/dogfood_tukfs-hash.ps1
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory, ValueFromRemainingArguments)]
	[ValidateNotNullOrEmpty()]
	[string[]]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$settings = Join-Path -Path $PSScriptRoot -ChildPath '../../PSScriptAnalyzerSettings.psd1'
$found = 0
foreach ($file in $Path) {
	$errors = $null
	$null = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
	foreach ($e in $errors) {
		Write-Output -InputObject "${file}:$($e.Extent.StartLineNumber): parse error: $($e.Message)"
		$found++
	}
	foreach ($r in @(Invoke-ScriptAnalyzer -Path $file -Settings $settings)) {
		Write-Output -InputObject "${file}:$($r.Line): $($r.RuleName): $($r.Message)"
		$found++
	}
}
if ($found -gt 0) { exit 1 }
exit 0


##	History:
##		- 2026-10-23: Created.
