## dogfood_tukfs-hash.ps1
##
##	Runs the newest dogfood build of tukfs-hash, on Linux, under PowerShell 7.
##	The pool, its rotation and the fixed name are in design.md, "Build and
##	release".
##
##	History: At bottom of script.

##	Copyright (C) 2026 t00mietum
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Runs the newest dogfood build of tukfs-hash, taking a new one from the synced dogfood dir first.
.DESCRIPTION
Every argument but --no-update goes to tukfs-hash as it came, and its exit code comes back. --no-update runs the newest build already held and copies nothing. What this script has to say goes to stderr, and only on a run that took a new build or changed something. For tukfs-hash's own help, run it with --help.
.EXAMPLE
dogfood_tukfs-hash scan --db ~/tukfs.db --root /home
.EXAMPLE
dogfood_tukfs-hash --no-update --version
#>

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

function Write-Note {
	<#
	.SYNOPSIS
	Writes a line to stderr, led by the launcher's name.
	#>
	[CmdletBinding()]
	[OutputType([void])]
	param(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Message
	)
	[Console]::Error.WriteLine("${LauncherName}: $Message")
}

function Exit-Launcher {
	<#
	.SYNOPSIS
	Writes a line to stderr and exits 1.
	#>
	[CmdletBinding()]
	[OutputType([void])]
	param(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Message
	)
	Write-Note -Message $Message
	exit 1
}

function ConvertFrom-Stamp {
	<#
	.SYNOPSIS
	The stamp as a date, or nothing when it names no real one, such as a 13th month.
	.DESCRIPTION
	A name like that isn't one this script wrote.
	#>
	[CmdletBinding()]
	[OutputType([datetime])]
	param(
		[Parameter(Mandatory)]
		[string]$Stamp
	)
	$when = [datetime]::MinValue
	if ([datetime]::TryParseExact($Stamp, $StampFormat, $Invariant, [Globalization.DateTimeStyles]::None, [ref]$when)) { return $when }
	return $null
}

function Get-SourceBuild {
	<#
	.SYNOPSIS
	The build in the first source dir that has one, or nothing.
	#>
	[CmdletBinding()]
	[OutputType([IO.FileInfo])]
	param()
	foreach ($dir in $SourceDirs) {
		$item = Get-Item -LiteralPath (Join-Path -Path $dir -ChildPath $ProgramName) -ErrorAction SilentlyContinue
		if ($item -is [IO.FileInfo]) { return $item }
	}
	return $null
}

function Get-HeldVersion {
	<#
	.SYNOPSIS
	Every version in the pool, as { File, Name, Stamp }, oldest first.
	.DESCRIPTION
	Only an exact name with a real date counts, so anything else in the dir is left alone. A version copied in this run has no role yet.
	#>
	[CmdletBinding()]
	[OutputType([object[]])]
	param()
	if (-not (Test-Path -LiteralPath $PoolDir)) { return , @() }
	$rx = '^' + [regex]::Escape($ProgramName) + '_(?<stamp>\d{8}-\d{6})(_[a-z]+)?$'
	$found = [Collections.Generic.List[object]]::new()
	foreach ($file in Get-ChildItem -LiteralPath $PoolDir -File) {
		if (-not ($file.Name -cmatch $rx)) { continue }
		$stamp = ConvertFrom-Stamp -Stamp $Matches.stamp
		if ($null -ne $stamp) { $found.Add([PSCustomObject]@{ File = $file; Name = $file.Name; Stamp = $stamp }) }
	}
	return , @($found | Sort-Object -Property Stamp, Name)
}

function Find-HeldTwin {
	<#
	.SYNOPSIS
	A held version with the same bytes as the source build, or nothing.
	.DESCRIPTION
	The sync restamps what it has, so a build already held can look new.
	#>
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param(
		[Parameter(Mandatory)]
		[IO.FileInfo]$Source
	)
	$held = Get-HeldVersion
	$same = @($held | Where-Object -FilterScript { $_.File.Length -eq $Source.Length })
	if ($same.Count -eq 0) { return $null }
	$want = (Get-FileHash -LiteralPath $Source.FullName -Algorithm SHA256).Hash
	for ($i = $same.Count - 1; $i -ge 0; $i--) {
		if ((Get-FileHash -LiteralPath $same[$i].File.FullName -Algorithm SHA256).Hash -eq $want) { return $same[$i] }
	}
	return $null
}

function Copy-NewBuild {
	<#
	.SYNOPSIS
	Copies the source build in when nothing held matches it. True when it took one.
	.DESCRIPTION
	Written to a temp name and renamed, so a copy that dies partway never passes for a version.
	#>
	[CmdletBinding()]
	[OutputType([bool])]
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
		Write-Note -Message "new build $stamp from $($src.DirectoryName)"
		return $true
	} catch {
		Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
		Write-Note -Message "could not copy the new build: $($_.Exception.Message)"
		return $false
	}
}

function Get-PeriodKey {
	<#
	.SYNOPSIS
	Period keys for a date. The week is the ISO one, yyyyww.
	#>
	[CmdletBinding()]
	[OutputType([hashtable])]
	param(
		[Parameter(Mandatory)]
		[datetime]$When
	)
	return @{
		hour = $When.ToString('yyyyMMddHH', $Invariant)
		day = $When.ToString('yyyyMMdd', $Invariant)
		week = '{0:D4}{1:D2}' -f [Globalization.ISOWeek]::GetYear($When), [Globalization.ISOWeek]::GetWeekOfYear($When)
		month = $When.ToString('yyyyMM', $Invariant)
		year = $When.ToString('yyyy', $Invariant)
	}
}

function Get-GfsRole {
	<#
	.SYNOPSIS
	Each version's role, by name. A version with none is one nothing keeps.
	.DESCRIPTION
	The coarser role wins where two apply; oldest and newest win over all of them.
	#>
	[CmdletBinding()]
	[OutputType([hashtable])]
	param(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object[]]$Versions
	)
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

function Select-Budget {
	<#
	.SYNOPSIS
	The names that fit the budget.
	.DESCRIPTION
	The newest goes in first whatever it weighs, since the fixed name points at it, then the oldest, then those with a GFS role, then those without, each newest first. A version with no role still stays while the pool is under the count and the bytes.
	#>
	[CmdletBinding()]
	[OutputType([Collections.Generic.HashSet[string]])]
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[object[]]$Versions,
		[Parameter(Mandatory)]
		[hashtable]$Roles
	)
	$keep = [Collections.Generic.HashSet[string]]::new()
	$ranked = @($Versions | Sort-Object -Property Stamp, Name -Descending)
	if ($ranked.Count -eq 0) { return Write-Output -NoEnumerate -InputObject $keep }
	$order = [Collections.Generic.List[object]]::new()
	$order.Add($ranked[0])
	if ($ranked.Count -gt 1) { $order.Add($ranked[-1]) }
	if ($ranked.Count -gt 2) {
		$middle = @($ranked[1..($ranked.Count - 2)])
		$order.AddRange(@($middle | Where-Object -FilterScript { $Roles.ContainsKey($_.Name) }))
		$order.AddRange(@($middle | Where-Object -FilterScript { -not $Roles.ContainsKey($_.Name) }))
	}
	$bytes = 0
	foreach ($v in $order) {
		if ($keep.Count -ge $MaxVersions) { break }
		if ($keep.Count -ge $MinVersions -and ($bytes + $v.File.Length) -gt $MaxPoolBytes) { break }
		$null = $keep.Add($v.Name)
		$bytes += $v.File.Length
	}
	return Write-Output -NoEnumerate -InputObject $keep
}

function Resolve-RealPath {
	<#
	.SYNOPSIS
	The path with every link on the way resolved, the way /proc shows what a process runs.
	.DESCRIPTION
	Nothing when part of it isn't there, or past 100 links.
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Path,
		[ValidateRange(0, 101)]
		[int]$Depth = 0
	)
	if ($Depth -gt 100) { return $null }
	$full = [IO.Path]::GetFullPath($Path)
	if ($full -eq '/') { return '/' }
	$parent = Resolve-RealPath -Path ([IO.Path]::GetDirectoryName($full)) -Depth ($Depth + 1)
	if ($null -eq $parent) { return $null }
	$at = Join-Path -Path $parent -ChildPath ([IO.Path]::GetFileName($full))
	$item = Get-Item -LiteralPath $at -Force -ErrorAction SilentlyContinue
	if ($null -eq $item) { return $null }
	if ($item.LinkType -ne 'SymbolicLink') { return $at }
	return Resolve-RealPath -Path ([IO.Path]::GetFullPath("$($item.Target)", $parent)) -Depth ($Depth + 1)
}

function Get-RunningPath {
	<#
	.SYNOPSIS
	The image paths of what's running now.
	.DESCRIPTION
	A process that can't be read isn't protected by this.
	#>
	[CmdletBinding()]
	[OutputType([Collections.Generic.HashSet[string]])]
	param()
	$paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
		$image = try { $proc.Path } catch { $null }
		if ($image) { $null = $paths.Add($image) }
	}
	return Write-Output -NoEnumerate -InputObject $paths
}

function Invoke-Rotation {
	<#
	.SYNOPSIS
	Removes what the budget leaves out, unless it's running, then gives each kept version its role in its name.
	.DESCRIPTION
	One file at a time, never a tree.
	#>
	[CmdletBinding()]
	[OutputType([void])]
	param()
	$versions = Get-HeldVersion
	if ($versions.Count -eq 0) { return }
	$roles = Get-GfsRole -Versions $versions
	$keep = Select-Budget -Versions $versions -Roles $roles
	$running = Get-RunningPath
	## A running one shows by its real path, which isn't the pool's when a
	## link is on the way, such as a linked home.
	$realPool = Resolve-RealPath -Path $PoolDir
	foreach ($v in $versions) {
		if ($keep.Contains($v.Name)) { continue }
		$realFile = if ($realPool) { Join-Path -Path $realPool -ChildPath $v.Name } else { $v.File.FullName }
		if ($running.Contains($v.File.FullName) -or $running.Contains($realFile)) {
			Write-Note -Message "$($v.Name) is running, so it stays for now"
			continue
		}
		try {
			Remove-Item -LiteralPath $v.File.FullName -Force -ErrorAction Stop
		} catch {
			Write-Note -Message "could not remove $($v.Name): $($_.Exception.Message)"
		}
	}
	foreach ($v in $versions) {
		if (-not $keep.Contains($v.Name)) { continue }
		$role = if ($roles.ContainsKey($v.Name)) { $roles[$v.Name] } else { 'spare' }
		$want = "${ProgramName}_$($v.Stamp.ToString($StampFormat, $Invariant))_$role"
		if ($v.Name -ceq $want) { continue }
		$wantPath = Join-Path -Path $PoolDir -ChildPath $want
		if (Test-Path -LiteralPath $wantPath) { continue }
		try { Move-Item -LiteralPath $v.File.FullName -Destination $wantPath -ErrorAction Stop } catch { Write-Note -Message "could not rename $($v.Name): $($_.Exception.Message)" }
	}
}

function Test-OwnLink {
	<#
	.SYNOPSIS
	True when the fixed name is a link this script made, into the pool.
	#>
	[CmdletBinding()]
	[OutputType([bool])]
	param(
		[Parameter(Mandatory)]
		[AllowNull()]
		[IO.FileSystemInfo]$Item
	)
	if ($null -eq $Item -or $Item.LinkType -ne 'SymbolicLink') { return $false }
	$target = [IO.Path]::GetFullPath("$($Item.Target)", $InstallDir)
	return $target.StartsWith($PoolDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)
}

function Update-FixedName {
	<#
	.SYNOPSIS
	Points the fixed name at the newest version.
	.DESCRIPTION
	Something else there is left alone, and said so on a run that took a new build.
	.PARAMETER Fresh
	This run took a new build.
	#>
	[CmdletBinding()]
	[OutputType([void])]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only touches its own link, and the launcher has no -WhatIf to pass on.')]
	param([switch]$Fresh)
	$versions = Get-HeldVersion
	if ($versions.Count -eq 0) { return }
	$target = $versions[-1].File.FullName
	$cur = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
	if ($cur -and "$($cur.Target)" -ceq $target) { return }
	if ($cur -and -not (Test-OwnLink -Item $cur)) {
		if ($Fresh) { Write-Note -Message "$LinkPath isn't a link into $PoolDir, so it was left alone, and a bare $ProgramName there isn't this build" }
		return
	}
	try {
		if ($cur) { Remove-Item -LiteralPath $LinkPath -Force -ErrorAction Stop }
		$null = New-Item -ItemType SymbolicLink -Path $LinkPath -Target $target -ErrorAction Stop
	} catch {
		Write-Note -Message "could not update ${LinkPath}: $($_.Exception.Message)"
		return
	}
	Write-Note -Message "$LinkPath -> $($versions[-1].Name)"
}

function Get-RunTarget {
	<#
	.SYNOPSIS
	The fixed name when it names the newest version, else that version itself.
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param()
	$versions = Get-HeldVersion
	if ($versions.Count -eq 0) { return $null }
	$newest = $versions[-1].File.FullName
	$cur = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
	if ($cur -and "$($cur.Target)" -ceq $newest) { return $LinkPath }
	return $newest
}

function Get-FileArgument {
	<#
	.SYNOPSIS
	This script's arguments as typed, from the process's own argument list.
	.DESCRIPTION
	Started by -File, PowerShell has parsed the arguments as its own before the script sees them, so a `-`-led one with a colon became a name and a value. The process's argument list still has them as typed, after this script's path. Nothing when no argument there names this script. From shcl's dogfood_shcl.ps1.
	.PARAMETER Self
	This script's path.
	#>
	[CmdletBinding()]
	[OutputType([string[]])]
	param(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Self
	)
	$argv = [Environment]::GetCommandLineArgs()
	$leaf = Split-Path -Path $Self -Leaf
	for ($i = 1; $i -lt $argv.Count; $i++) {
		if ((Split-Path -Path $argv[$i] -Leaf) -ceq $leaf) { return Write-Output -NoEnumerate -InputObject ([string[]]@($argv | Select-Object -Skip ($i + 1))) }
	}
	return $null
}

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
if (-not $exe) { Exit-Launcher -Message "no $ProgramName build held, and none in $($SourceDirs -join ' or ')" }
& $exe @passArgs
exit $LASTEXITCODE


##	History:
##		- 2026-10-23: Created from shcl's dogfood_shcl.ps1, Linux only. The
##		  fixed name is a link, and anything else there is left alone.
##		- 2026-10-23: A version with no GFS role is kept while the pool is
##		  under 10 and 1 GB, and a running one is found through a linked home.
##		- 2026-10-28: Plain ASCII header, typed parameters and help on each
##		  function. The pool policy moved to design.md.
