param(
    [Parameter(Mandatory=$true)][string]$GamePath,
    [switch]$ValidateOnly
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$manifestPath=Join-Path $root 'patches\compendium-approved-v1.json'
$assetRoot=Join-Path $root 'assets\compendium\2023'

function Hash-File([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Resolve-AssetPath([string]$root,[string]$relative) {
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or
        $relative.StartsWith('\') -or $relative.Contains(':') -or
        $relative.Contains([char]0)) { throw "Invalid art filename: $relative" }
    foreach($part in $relative.Replace('\','/').Split('/')) {
        if (-not $part -or $part -eq '.' -or $part -eq '..') {
            throw "Unsafe art filename: $relative"
        }
    }
    $base=[IO.Path]::GetFullPath($root).TrimEnd('\','/')+'\'
    $full=[IO.Path]::GetFullPath((Join-Path $base $relative.Replace('/','\')))
    if (-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) {
        throw "File escapes artwork directory: $relative"
    }
    return $full
}
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"'))
if (-not (Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)) {
    throw 'Skullgirls executable not found at selected game path.'
}
if (Get-Process -Name SkullGirls -ErrorAction SilentlyContinue) {
    throw 'Close Skullgirls before installing the art compendium.'
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'Production compendium manifest is missing.'
}
$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$manifest.schema -ne 1 -or $manifest.targetFolder -cne 'Digital Art Compendium') {
    throw 'Unknown art compendium manifest format.'
}
$artFolder=Join-Path $game 'Digital Art Compendium'
if (-not (Test-Path -LiteralPath $artFolder -PathType Container)) {
    throw 'The current Digital Art Compendium is not installed. Install the Deluxe/Compendium DLC through Steam first.'
}
$approved=@($manifest.assets)
if ($approved.Count -ne 56) { throw 'Expected 56 approved compendium illustrations.' }
$excluded=@($manifest.excludeModernPaths)
$names=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($item in $approved) {
    $rel=[string]$item.path
    if (-not $names.Add($rel)) { throw "Duplicate artwork path: $rel" }
    if ($excluded -icontains $rel) { throw "Protected modern artwork is in restoration manifest: $rel" }
}
$needs=New-Object 'System.Collections.Generic.List[object]'
$unchanged=0
foreach($item in $approved) {
    $rel=[string]$item.path
    $src=Resolve-AssetPath $assetRoot $rel
    $dest=Resolve-AssetPath $artFolder $rel
    $expectedHash=([string]$item.historicalSHA256).ToLowerInvariant()
    $expectedLength=[long]$item.historicalSize
    if ($expectedHash -notmatch '^[0-9a-f]{64}$' -or $expectedLength -le 0) {
        throw "Invalid restoration checksum: $rel"
    }
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        throw "Required original artwork is missing from this production package: $rel"
    }
    $sourceInfo=Get-Item -LiteralPath $src
    if ($sourceInfo.Length -ne $expectedLength -or (Hash-File $src) -cne $expectedHash) {
        throw "Original bundled image failed SHA256 or length verification: $rel"
    }
    $currentExists=Test-Path -LiteralPath $dest -PathType Leaf
    if ($currentExists) {
        $currentHash=Hash-File $dest
        if ($currentHash -ceq $expectedHash) {
            $unchanged++
            continue
        }
        if ([string]$item.status -cne 'Modified' -or
            $currentHash -cne ([string]$item.currentSHA256).ToLowerInvariant()) {
            throw "Different or unexpected modern artwork: $rel. Refusing to overwrite it."
        }
    } elseif ([string]$item.status -cne 'Removed') {
        throw "The modern artwork is unexpectedly missing: $rel. Check the installed compendium version."
    }
    $needs.Add([pscustomobject]@{Path=$rel;Source=$src;Target=$dest;
        HistoricalHash=$expectedHash;HadOriginal=$currentExists;Temp=$null;Backup=$null;
        MovedOriginal=$false;Installed=$false})
}
if ($ValidateOnly) { return }
if ($needs.Count -eq 0) {
    Write-Host 'Digital Art Compendium: all 56 selected originals are already installed.' -ForegroundColor Green
    return
}

$job=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$backupRoot=Join-Path $game ('Restoration Backups\Compendium-'+$job)
$processed=New-Object 'System.Collections.Generic.List[object]'
try {
    foreach($op in $needs) {
        $parent=Split-Path -Parent $op.Target
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $op.Temp=$op.Target+'.aotc-'+[guid]::NewGuid().ToString('N')+'.tmp'
        Copy-Item -LiteralPath $op.Source -Destination $op.Temp -ErrorAction Stop
        if ((Hash-File $op.Temp) -cne $op.HistoricalHash) {
            throw "Staged image failed checksum verification: $($op.Path)"
        }
        $op.Backup=Resolve-AssetPath $backupRoot $op.Path
    }

    foreach($op in $needs) {
        if ($op.HadOriginal) {
            $manifestEntry=@($approved | Where-Object { $_.path -ceq $op.Path })[0]
            if (-not (Test-Path -LiteralPath $op.Target -PathType Leaf) -or
                (Hash-File $op.Target) -cne ([string]$manifestEntry.currentSHA256).ToLowerInvariant()) {
                throw "The installed image changed during staging: $($op.Path)"
            }
        } elseif (Test-Path -LiteralPath $op.Target) {
            throw "Previously absent image appeared during staging: $($op.Path)"
        }
    }

    foreach($op in $needs) {
        $processed.Add($op)
        if ($op.HadOriginal) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $op.Backup) -Force | Out-Null
            [IO.File]::Move($op.Target,$op.Backup)
            $op.MovedOriginal=$true
        }
        [IO.File]::Move($op.Temp,$op.Target)
        $op.Installed=$true
    }
} catch {
    $failure=$_
    for($i=$processed.Count-1;$i -ge 0;$i--) {
        $op=$processed[$i]
        if ($op.Installed -and (Test-Path -LiteralPath $op.Target -PathType Leaf)) {
            Remove-Item -LiteralPath $op.Target -Force
        }
        if ($op.MovedOriginal -and (Test-Path -LiteralPath $op.Backup -PathType Leaf)) {
            [IO.File]::Move($op.Backup,$op.Target)
        }
    }
    throw $failure
} finally {
    foreach($op in $needs) {
        if ($op.Temp -and (Test-Path -LiteralPath $op.Temp -PathType Leaf)) {
            Remove-Item -LiteralPath $op.Temp -Force
        }
    }
}
Write-Host ("Digital Art Compendium: restored {0} images ({1} already restored)." -f $needs.Count,$unchanged) -ForegroundColor Green
Write-Host "Backups of modified modern images: $backupRoot"
