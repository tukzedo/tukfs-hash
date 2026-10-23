#==============================================================================
## dogfood_tukfs-hash.ps1
##
##	Runs the newest dogfood build of tukfs-hash, on Linux, under PowerShell 7.
##
##	The pipeline drops each release build into the synced dogfood dir. This
##	copies it into a local pool of dated versions, points a fixed name at the
##	newest, and runs that with every argument passed through. A copy that's
##	running is never deleted, so a long scan keeps going while a newer build
##	arrives.
##
##	Usage:
##		dogfood_tukfs-hash scan --db FILE --root DIR
##		dogfood_tukfs-hash --no-update --version   ## run what's held, copy nothing
##
##	Where things go: ~/.local/bin/tukfs-hash_versions/, and the fixed name
##	~/.local/bin/tukfs-hash, a link to the newest. Anything at the fixed name
##	that isn't a link into the pool is left alone, and the newest version runs
##	from the pool instead.
##
##	The pool keeps at most 10 versions and at least 5, and between those only
##	as many as fit in 1 GB. Which ones stay is a GFS rotation: the oldest, the
##	newest, the last of each recent hour, day, week, month and year, and the
##	few most recent. Each is named tukfs-hash_<yyyyMMdd-HHmmss>_<role>, from
##	the build's write time in local time. Old versions go one file at a time,
##	matched by that name, and never one that's running.
##
##	Output: tukfs-hash's own stdout and stderr, and its exit code. What this
##	script has to say goes to stderr, and only on a run that took a new build
##	or changed something.
##
##	History: At bottom of script.
#==============================================================================

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Runs the newest dogfood build of tukfs-hash, taking a new one from the synced dogfood dir first.
.DESCRIPTION
Every argument but --no-update goes to tukfs-hash as it came, and its exit code comes back. --no-update runs the newest build already held and copies nothing. For tukfs-hash's own help, run it with --help.
.EXAMPLE
dogfood_tukfs-hash scan --db ~/tukfs.db --root /home
.EXAMPLE
dogfood_tukfs-hash --no-update --version
#>

#==============================================================================
# Configuration
#==============================================================================

$ProgramName = 'tukfs-hash'
$LauncherName = "dogfood_$ProgramName"

## Where the pipeline's dogfood stage puts a build. The first that has one wins.
$SourceDirs = @(
	(Join-Path -Path $HOME -ChildPath 'synced/0-0/common/exec/util/linux/bin')
)

## Local on purpose. Versions churn with every build and don't belong in the
## sync tree.
$InstallDir = Join-Path -Path $HOME -ChildPath '.local/bin'
$PoolDir = Join-Path -Path $InstallDir -ChildPath "${ProgramName}_versions"
$LinkPath = Join-Path -Path $InstallDir -ChildPath $ProgramName

$MaxVersions = 10
$MinVersions = 5
$MaxPoolBytes = 1GB

## GFS roles, before the budget above trims them. A period role goes to the
## last version of a period that has ended.
$KeepFrequent = 5
$KeepHourly = 3
$KeepDaily = 3
$KeepWeekly = 2
$KeepMonthly = 1
$KeepYearly = 1

$StampFormat = 'yyyyMMdd-HHmmss'
## Written and read in one culture, or a culture with another calendar writes
## a year the read takes as a different one.
$Invariant = [Globalization.CultureInfo]::InvariantCulture

#==============================================================================
# Functions
#==============================================================================

function Write-Note {
	[CmdletBinding()]
	param([string]$Message)
	[Console]::Error.WriteLine("${LauncherName}: $Message")
}

function Exit-Launcher {
	[CmdletBinding()]
	param([string]$Message)
	[Console]::Error.WriteLine("${LauncherName}: $Message")
	exit 1
}

## The stamp as a date, or nothing when it names no real one, such as a 13th
## month. A name like that isn't one this script wrote.
function ConvertFrom-Stamp {
	[CmdletBinding()]
	param([string]$Stamp)
	$when = [datetime]::MinValue
	if ([datetime]::TryParseExact($Stamp, $StampFormat, $Invariant, [Globalization.DateTimeStyles]::None, [ref]$when)) { return $when }
	return $null
}

## The build in the first source dir that has one, or nothing.
function Get-SourceBuild {
	[CmdletBinding()]
	param()
	foreach ($dir in $SourceDirs) {
		$item = Get-Item -LiteralPath (Join-Path -Path $dir -ChildPath $ProgramName) -ErrorAction SilentlyContinue
		if ($item) { return $item }
	}
	return $null
}

## Every version in the pool, as { File, Name, Stamp }, oldest first. Only an
## exact name with a real date counts, so anything else in the dir is left
## alone. A version copied in this run has no role yet.
function Get-HeldVersion {
	[CmdletBinding()]
	param()
	if (-not (Test-Path -LiteralPath $PoolDir)) { return , @() }
	$rx = '^' + [regex]::Escape($ProgramName) + '_(?<stamp>\d{8}-\d{6})(_[a-z]+)?$'
	$found = @(Get-ChildItem -LiteralPath $PoolDir -File | Where-Object { $_.Name -cmatch $rx } | ForEach-Object {
			$null = $_.Name -cmatch $rx
			$stamp = ConvertFrom-Stamp -Stamp $Matches.stamp
			if ($null -ne $stamp) { [PSCustomObject]@{ File = $_; Name = $_.Name; Stamp = $stamp } }
		})
	return , @($found | Sort-Object -Property Stamp, Name)
}

## A held version with the same bytes as the source build, or nothing. The sync
## restamps what it has, so a build already held can look new.
function Find-HeldTwin {
	[CmdletBinding()]
	param($Source)
	$held = Get-HeldVersion
	$same = @($held | Where-Object { $_.File.Length -eq $Source.Length })
	if ($same.Count -eq 0) { return $null }
	$want = (Get-FileHash -LiteralPath $Source.FullName -Algorithm SHA256).Hash
	for ($i = $same.Count - 1; $i -ge 0; $i--) {
		if ((Get-FileHash -LiteralPath $same[$i].File.FullName -Algorithm SHA256).Hash -eq $want) { return $same[$i] }
	}
	return $null
}

## Copy the source build in when nothing held matches it. Written to a temp
## name and renamed, so a copy that dies partway never passes for a version.
## True when it took one.
function Copy-NewBuild {
	[CmdletBinding()]
	param()
	$src = Get-SourceBuild
	if (-not $src) { return $false }
	$stamp = $src.LastWriteTime.ToString($StampFormat, $Invariant)
	$held = Get-HeldVersion
	if ($held.Count -gt 0 -and $held[-1].Stamp -ge (ConvertFrom-Stamp -Stamp $stamp)) { return $false }
	if (Find-HeldTwin -Source $src) { return $false }

	$null = New-Item -ItemType Directory -Force -Path $PoolDir
	$dest = Join-Path -Path $PoolDir -ChildPath "${ProgramName}_$stamp"
	$partial = "$dest.partial"
	try {
		Copy-Item -LiteralPath $src.FullName -Destination $partial -Force
		[IO.File]::SetUnixFileMode($partial, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')
		Move-Item -LiteralPath $partial -Destination $dest -Force
		Write-Note "new build $stamp from $($src.DirectoryName)"
		return $true
	} catch {
		Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
		Write-Note "could not copy the new build: $($_.Exception.Message)"
		return $false
	}
}

## Period keys for a date. The week is the ISO one, yyyyww.
function Get-PeriodKey {
	[CmdletBinding()]
	param([datetime]$When)
	return @{
		hour = $When.ToString('yyyyMMddHH', $Invariant)
		day = $When.ToString('yyyyMMdd', $Invariant)
		week = '{0:D4}{1:D2}' -f [Globalization.ISOWeek]::GetYear($When), [Globalization.ISOWeek]::GetWeekOfYear($When)
		month = $When.ToString('yyyyMM', $Invariant)
		year = $When.ToString('yyyy', $Invariant)
	}
}

## Each version's role, by name. A version with none is one nothing keeps. The
## coarser role wins where two apply; oldest and newest win over all of them.
function Get-GfsRole {
	[CmdletBinding()]
	param([object[]]$Versions)
	$periods = @('year', 'month', 'week', 'day', 'hour')
	$current = Get-PeriodKey -When (Get-Date)
	$lastIn = @{}
	foreach ($p in $periods) { $lastIn[$p] = @{} }
	foreach ($v in $Versions) {
		$keys = Get-PeriodKey -When $v.Stamp
		foreach ($p in $periods) {
			if ($keys[$p] -ne $current[$p]) { $lastIn[$p][$keys[$p]] = $v }
		}
	}
	$roles = @{}
	$roles[$Versions[0].Name] = 'oldest'
	$roles[$Versions[-1].Name] = 'newest'
	$quota = @{ year = $KeepYearly; month = $KeepMonthly; week = $KeepWeekly; day = $KeepDaily; hour = $KeepHourly }
	foreach ($p in $periods) {
		$keys = @($lastIn[$p].Keys | Sort-Object)
		for ($i = [Math]::Max(0, $keys.Count - $quota[$p]); $i -lt $keys.Count; $i++) {
			$name = $lastIn[$p][$keys[$i]].Name
			if (-not $roles.ContainsKey($name)) { $roles[$name] = $p }
		}
	}
	for ($i = [Math]::Max(0, $Versions.Count - $KeepFrequent); $i -lt $Versions.Count; $i++) {
		if (-not $roles.ContainsKey($Versions[$i].Name)) { $roles[$Versions[$i].Name] = 'frequent' }
	}
	return $roles
}

## The names that fit the budget. The newest goes in first whatever it weighs,
## since the fixed name points at it, then the oldest, then the rest newest
## first until the count or the bytes run out.
function Select-Budget {
	[CmdletBinding()]
	param([object[]]$Versions, [hashtable]$Roles)
	$keep = [Collections.Generic.HashSet[string]]::new()
	$ranked = @($Versions | Where-Object { $Roles.ContainsKey($_.Name) } | Sort-Object -Property Stamp -Descending)
	if ($ranked.Count -eq 0) { return , $keep }
	$order = @($ranked[0])
	if ($ranked.Count -gt 1) { $order += $ranked[-1] }
	if ($ranked.Count -gt 2) { $order += $ranked[1..($ranked.Count - 2)] }
	$bytes = 0
	foreach ($v in $order) {
		if ($keep.Count -ge $MaxVersions) { break }
		if ($keep.Count -ge $MinVersions -and ($bytes + $v.File.Length) -gt $MaxPoolBytes) { break }
		$null = $keep.Add($v.Name)
		$bytes += $v.File.Length
	}
	return , $keep
}

## The image paths of what's running now. A process that can't be read isn't
## protected by this.
function Get-RunningPath {
	[CmdletBinding()]
	param()
	return @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Path } catch { $null } } | Where-Object { $_ })
}

## Remove what the budget leaves out, unless it's running, then give each kept
## version its role in its name. One file at a time, never a tree.
function Invoke-Rotation {
	[CmdletBinding()]
	param()
	$versions = Get-HeldVersion
	if ($versions.Count -eq 0) { return }
	$roles = Get-GfsRole -Versions $versions
	$keep = Select-Budget -Versions $versions -Roles $roles
	$running = Get-RunningPath
	foreach ($v in $versions) {
		if ($keep.Contains($v.Name)) { continue }
		if ($running -contains $v.File.FullName) {
			Write-Note "$($v.Name) is running, so it stays for now"
			continue
		}
		try {
			Remove-Item -LiteralPath $v.File.FullName -Force -ErrorAction Stop
		} catch {
			Write-Note "could not remove $($v.Name): $($_.Exception.Message)"
		}
	}
	foreach ($v in $versions) {
		if (-not $keep.Contains($v.Name)) { continue }
		$want = "${ProgramName}_$($v.Stamp.ToString($StampFormat, $Invariant))_$($roles[$v.Name])"
		if ($v.Name -ceq $want) { continue }
		$wantPath = Join-Path -Path $PoolDir -ChildPath $want
		if (Test-Path -LiteralPath $wantPath) { continue }
		try { Move-Item -LiteralPath $v.File.FullName -Destination $wantPath -ErrorAction Stop } catch { Write-Note "could not rename $($v.Name): $($_.Exception.Message)" }
	}
}

## True when the fixed name is a link this script made, into the pool.
function Test-OwnLink {
	[CmdletBinding()]
	[OutputType([bool])]
	param($Item)
	if ($null -eq $Item -or $Item.LinkType -ne 'SymbolicLink') { return $false }
	$target = [IO.Path]::GetFullPath("$($Item.Target)", $InstallDir)
	return $target.StartsWith($PoolDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)
}

## Point the fixed name at the newest version. Something else there is left
## alone, and said so on a run that took a new build.
function Update-FixedName {
	[CmdletBinding()]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
	param([switch]$Fresh)
	$versions = Get-HeldVersion
	if ($versions.Count -eq 0) { return }
	$target = $versions[-1].File.FullName
	$cur = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
	if ($cur -and "$($cur.Target)" -ceq $target) { return }
	if ($cur -and -not (Test-OwnLink -Item $cur)) {
		if ($Fresh) { Write-Note "$LinkPath isn't a link into $PoolDir, so it was left alone, and a bare $ProgramName there isn't this build" }
		return
	}
	try {
		if ($cur) { Remove-Item -LiteralPath $LinkPath -Force -ErrorAction Stop }
		$null = New-Item -ItemType SymbolicLink -Path $LinkPath -Target $target -ErrorAction Stop
	} catch {
		Write-Note "could not update ${LinkPath}: $($_.Exception.Message)"
		return
	}
	Write-Note "$LinkPath -> $($versions[-1].Name)"
}

## The fixed name when it names the newest version, else that version itself.
function Get-RunTarget {
	[CmdletBinding()]
	param()
	$versions = Get-HeldVersion
	if ($versions.Count -eq 0) { return $null }
	$newest = $versions[-1].File.FullName
	$cur = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
	if ($cur -and "$($cur.Target)" -ceq $newest) { return $LinkPath }
	return $newest
}

## Started by -File, PowerShell has parsed the arguments as its own before the
## script sees them, so a `-`-led one with a colon became a name and a value.
## The process's own argument list still has them as typed, after this
## script's path. Nothing when no argument there names this script. From
## shcl's dogfood_shcl.ps1.
function Get-FileArgument {
	[CmdletBinding()]
	[OutputType([string[]])]
	param([string]$Self)
	$argv = [Environment]::GetCommandLineArgs()
	$leaf = Split-Path -Path $Self -Leaf
	for ($i = 1; $i -lt $argv.Count; $i++) {
		if ((Split-Path -Path $argv[$i] -Leaf) -ceq $leaf) { return , [string[]]@($argv | Select-Object -Skip ($i + 1)) }
	}
	return $null
}

#==============================================================================
# Main
#==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

## Its own flag is taken out, and everything else goes to tukfs-hash as it
## came, `-h` included, which is why there's no param() block to bind them.
$given = @($args)
if (-not $MyInvocation.Line) {
	$fromFile = Get-FileArgument -Self $PSCommandPath
	if ($null -ne $fromFile) { $given = $fromFile }
}
## The flag goes on the left, since a `$true` there equals any word.
$noUpdate = $false
$passArgs = [Collections.Generic.List[string]]::new()
foreach ($arg in $given) {
	if ('--no-update' -ceq $arg) { $noUpdate = $true } else { $passArgs.Add("$arg") }
}

if (-not $noUpdate) {
	$fresh = Copy-NewBuild
	Invoke-Rotation
	Update-FixedName -Fresh:$fresh
}

$exe = Get-RunTarget
if (-not $exe) { Exit-Launcher "no $ProgramName build held, and none in $($SourceDirs -join ' or ')" }
& $exe @passArgs
exit $LASTEXITCODE


##	History:
##		- 2026-10-23: Created from shcl's dogfood_shcl.ps1, Linux only. The
##		  fixed name is a link, and anything else there is left alone.
