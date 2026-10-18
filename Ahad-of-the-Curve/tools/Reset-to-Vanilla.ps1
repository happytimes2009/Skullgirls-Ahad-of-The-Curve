param(
    [string]$GamePath,
    [switch]$DryRun,
    [switch]$SkipBanner,
    [switch]$ConfirmedByReset
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-GfsLibrary.ps1')
. (Join-Path $PSScriptRoot 'SG-Banner.ps1')
if(-not $SkipBanner){Show-SGBanner -ProjectRoot $root}

if (-not $GamePath) { $GamePath = Read-Host 'Path to your Skullgirls game directory' }
$game = [IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
if (-not (Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)) {
    throw 'SkullGirls.exe not found. No changes made.'
}
if (Get-Process -Name SkullGirls -ErrorAction SilentlyContinue) {
    throw 'Close Skullgirls before resetting. No changes made.'
}
$backups = Join-Path $game 'Restoration Backups'
if (-not (Test-Path -LiteralPath $backups -PathType Container)) {
    throw 'No AOTC backup directory found. Use Steam Verify Integrity to restore original game archives.'
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class AotcVanillaCompare {
    public static bool FilePart(FileStream a, long ao, FileStream b, long bo, long count) {
        if (count < 0 || ao < 0 || bo < 0 || ao > a.Length - count || bo > b.Length - count) return false;
        a.Position=ao; b.Position=bo;
        byte[] ab=new byte[1048576], bb=new byte[1048576];
        while(count > 0) {
            int n=(int)Math.Min(count,(long)ab.Length);
            int ar=a.Read(ab,0,n), br=b.Read(bb,0,n);
            if(ar!=n || br!=n) return false;
            for(int i=0;i<n;i++) if(ab[i]!=bb[i]) return false;
            count-=n;
        }
        return true;
    }
    public static bool Bytes(byte[] a, int ao, byte[] b, int bo, int length) {
        if(length<0 || ao<0 || bo<0 || ao>a.Length-length || bo>b.Length-length) return false;
        for(int i=0;i<length;i++) if(a[ao+i]!=b[bo+i]) return false;
        return true;
    }
}
'@ -ErrorAction Stop

function Hash([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Path-For([string]$base,[string]$relative) {
    if([string]::IsNullOrWhiteSpace($relative) -or
        $relative.StartsWith('/') -or $relative.StartsWith('\') -or
        $relative.Contains(':') -or $relative.Contains([char]0)) {
        throw "Unsafe relative filename: $relative"
    }
    $parts=$relative.Replace('\','/').Split('/')
    foreach($part in $parts) {
        if(-not $part -or $part -eq '.' -or $part -eq '..') { throw "Unsafe filename: $relative" }
    }
    $prefix=[IO.Path]::GetFullPath($base).TrimEnd('\','/')+'\'
    $full=[IO.Path]::GetFullPath((Join-Path $base ($relative.Replace('/','\'))))
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Path outside game: $relative" }
    return $full
}
function View([byte[]]$bytes) {
    if($bytes.Length -lt 128 -or [Text.Encoding]::ASCII.GetString($bytes,0,4) -cne 'CSGG' -or
        [BitConverter]::ToUInt32($bytes,4) -ne $bytes.Length) {
        throw 'Unexpected Filia GBS header.'
    }
    $text=[Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $at=$text.IndexOf('Filia_Legacy_Intro',[StringComparison]::Ordinal)
    if($at -lt 12 -or $text.IndexOf('Filia_Legacy_Intro',$at+1,[StringComparison]::Ordinal) -ge 0) {
        throw 'Filia view missing or ambiguous.'
    }
    $start=$at-12
    if([Text.Encoding]::ASCII.GetString($bytes,$start,4) -cne 'WVGG') { throw 'Unexpected Filia view type.' }
    $length=[int][BitConverter]::ToUInt32($bytes,$start+4)
    if($length -lt 10000 -or $start+$length -gt $bytes.Length) { throw 'Unexpected Filia view size.' }
    return [pscustomobject]@{Start=$start;Length=$length}
}
function Entry-Bytes([string]$archive,[string]$entry) {
    $index=Get-SGIndex $archive
    if(-not $index.ContainsKey($entry)) { throw "Missing archive entry: $entry" }
    $stream=[IO.File]::OpenRead($archive)
    try { return ,(Read-SGEntry $stream $index[$entry]) }
    finally { $stream.Dispose() }
}
function Find-Original([string]$file,[string]$sha) {
    $found=@(Get-ChildItem -LiteralPath $backups -Directory -ErrorAction Stop |
        Where-Object { $_.Name -match '^Filia-' } |
        Sort-Object LastWriteTimeUtc |
        ForEach-Object { Join-Path $_.FullName $file } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    foreach($candidate in $found) {
        if((Hash $candidate) -ceq $sha) { return $candidate }
    }
    throw "No verified vanilla backup for $file. Do not overwrite unknown archives. Use Steam Verify Integrity, then retry."
}
function Compare-Filia-Textures([string]$current,[string]$vanilla,[object]$manifest) {
    $ci=Get-SGIndex $current
    $vi=Get-SGIndex $vanilla
    if($ci.Count -ne $vi.Count) { throw 'Filia story archive entry count changed.' }
    $skip=New-Object 'System.Collections.Generic.List[object]'
    $a=[IO.File]::OpenRead($current)
    $b=[IO.File]::OpenRead($vanilla)
    try {
        foreach($item in @($manifest.images | Where-Object { $_.to })) {
            $name=[string]$item.to
            if(-not $ci.ContainsKey($name) -or -not $vi.ContainsKey($name)) { throw "Missing Filia asset: $name" }
            $entry=$ci[$name]; $baseEntry=$vi[$name]
            if($entry.Offset -ne $baseEntry.Offset -or $entry.Size -ne $baseEntry.Size) {
                throw "Filia asset layout changed: $name"
            }
            [byte[]]$old=Read-SGEntry $a $entry
            [byte[]]$modern=Read-SGEntry $b $baseEntry
            if((Get-SGByteHash $old) -cne ([string]$item.sha256).ToLowerInvariant() -or
               (Get-SGByteHash $modern) -cne ([string]$item.expectedCurrentSha256).ToLowerInvariant()) {
                throw "Unknown Filia texture change: $name"
            }
            $skip.Add([pscustomobject]@{Offset=[long]$entry.Offset;Length=[long]$entry.Size})
        }
        if($a.Length -ne $b.Length){throw 'Filia story archive length changed.'}
        [long]$start=0
        foreach($item in @($skip | Sort-Object Offset)) {
            if(-not [AotcVanillaCompare]::FilePart($a,$start,$b,$start,([long]$item.Offset-$start))) {
                throw 'Unrecognized non-Filia story-art differences. No changes made.'
            }
            $start=[long]$item.Offset+[long]$item.Length
        }
        if(-not [AotcVanillaCompare]::FilePart($a,$start,$b,$start,($a.Length-$start))) {
            throw 'Unrecognized story-art differences after Filia images.'
        }
    } finally { $a.Dispose(); $b.Dispose() }
}
function Compare-Filia-UI([string]$current,[string]$vanilla) {
    $ci=Get-SGIndex $current
    $vi=Get-SGIndex $vanilla
    if($ci.Count -ne $vi.Count) { throw 'Filia UI archive entry count changed.' }
    $scene='ui/Win/CutsceneCommon.gbs'
    if(-not $ci.ContainsKey($scene) -or -not $vi.ContainsKey($scene)) { throw 'Missing Filia UI scene.' }
    $a=[IO.File]::OpenRead($current)
    $b=[IO.File]::OpenRead($vanilla)
    try {
        foreach($key in @($vi.Keys)) {
            if(-not $ci.ContainsKey($key)) { throw "Unknown UI archive layout: $key" }
            if($key -ceq $scene){continue}
            $i=$ci[$key]; $j=$vi[$key]
            if($i.Size -ne $j.Size -or
                -not [AotcVanillaCompare]::FilePart($a,[long]$i.Offset,$b,[long]$j.Offset,[long]$j.Size)) {
                throw "Unrecognized UI archive modifications: $key"
            }
        }
        [byte[]]$actual=Read-SGEntry $a $ci[$scene]
        [byte[]]$base=Read-SGEntry $b $vi[$scene]
        $av=View $actual
        $bv=View $base
        if($actual.Length -ne $base.Length+96 -or $av.Start -ne $bv.Start -or
            $av.Length -ne 30256 -or $bv.Length -ne 30160 -or
            [BitConverter]::ToUInt32($actual,52) -ne ([BitConverter]::ToUInt32($base,52)+96)) {
            throw 'Filia view does not match the supported AOTC installation.'
        }
        $checks=@(
            @([int]0,[int]4), @([int]8,[int]44),
            @([int]56,[int]($av.Start-56))
        )
        foreach($part in $checks) {
            if(-not [AotcVanillaCompare]::Bytes($actual,$part[0],$base,$part[0],$part[1])) {
                throw 'Unexpected non-Filia GBS header changes.'
            }
        }
        $historical=Join-Path $root 'assets\game\filia\cutscene\april-2023\CutsceneCommon.gbs'
        if(-not(Test-Path -LiteralPath $historical -PathType Leaf)){throw 'Historical Filia source missing from production.'}
        [byte[]]$oldGbs=[IO.File]::ReadAllBytes($historical)
        $hv=View $oldGbs
        if($hv.Length -ne $av.Length -or
            -not [AotcVanillaCompare]::Bytes($actual,$av.Start,$oldGbs,$hv.Start,$av.Length)) {
            throw 'Installed Filia view differs from the approved original.'
        }
        $suffixLen=$base.Length-($bv.Start+$bv.Length)
        if(-not [AotcVanillaCompare]::Bytes($actual,($av.Start+$av.Length),
            $base,($bv.Start+$bv.Length),$suffixLen)) {
            throw 'Unexpected changes in other cutscene views.'
        }
    } finally {$a.Dispose();$b.Dispose()}
}
$job=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$resetFolder=Join-Path $backups ('Vanilla-Reset-'+$job)
$stage=Join-Path $game ('.aotc-vanilla-stage-'+$job)
$ops=New-Object 'System.Collections.Generic.List[object]'
function Plan-Move([string]$target,[string]$relative) {
    $backup=Path-For $resetFolder $relative
    $info=Get-Item -LiteralPath $target -ErrorAction Stop
    $ops.Add([pscustomobject]@{Mode='Move';Target=$target;Backup=$backup;Source=$null;Stage=$null;
        Size=0;
        State='NotStarted';Length=$info.Length;Modified=$info.LastWriteTimeUtc})
}
function Plan-Replace([string]$target,[string]$source,[string]$relative) {
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Missing verified backup: $source"}
    $backup=Path-For $resetFolder ('Changed/'+$relative)
    $staged=Path-For $stage $relative
    $info=Get-Item -LiteralPath $target -ErrorAction Stop
    $ops.Add([pscustomobject]@{Mode='Replace';Target=$target;Backup=$backup;Source=$source;Stage=$staged;
        Size=$info.Length;State='NotStarted';Length=$info.Length;Modified=$info.LastWriteTimeUtc})
}

$filiaManifest=Get-Content -LiteralPath (Join-Path $root 'patches\filia-storyart-v1.json') -Raw | ConvertFrom-Json
$ui=Join-Path $game 'data01\ui-win.gfs'
$story=Join-Path $game 'data01\story_art.gfs'
$uiHash='7b96719c880bf8cdf4dc3f98f15adaf26a63aacf8ced48ca7f61229951d64a6c'
$storyHash=([string]$filiaManifest.modern.sha256).ToLowerInvariant()
if(-not(Test-Path -LiteralPath $ui -PathType Leaf) -or -not(Test-Path -LiteralPath $story -PathType Leaf)) {
    throw 'Missing installed UI or story-art GFS archive.'
}
Write-Host 'Checking original Filia archive backups and currently installed textures...'
if((Hash $ui) -cne $uiHash){
    $uiOriginal=Find-Original 'ui-win.gfs' $uiHash
    Compare-Filia-UI $ui $uiOriginal
    Plan-Replace $ui $uiOriginal 'data01/ui-win.gfs'
}
if((Hash $story) -cne $storyHash){
    $storyOriginal=Find-Original 'story_art.gfs' $storyHash
    Compare-Filia-Textures $story $storyOriginal $filiaManifest
    Plan-Replace $story $storyOriginal 'data01/story_art.gfs'
}

$gallery=Join-Path $game 'censored art\Filia'
foreach($img in @($filiaManifest.images)){
    $galleryImage=Join-Path $gallery ([string]$img.name)
    if(Test-Path -LiteralPath $galleryImage -PathType Leaf){
        if((Hash $galleryImage) -cne ([string]$img.sha256).ToLowerInvariant()){
            throw "An AOTC gallery filename has personal changes. Refusing to remove it: $galleryImage"
        }
        Plan-Move $galleryImage ('RemovedFiliaGallery/'+([string]$img.name))
    }
}

$compManifest=Get-Content -LiteralPath (Join-Path $root 'patches\compendium-approved-v1.json') -Raw | ConvertFrom-Json
if(@($compManifest.assets).Count -ne 56) { throw 'Unexpected Compendium manifest.' }
$comp=Join-Path $game 'Digital Art Compendium'
if(-not(Test-Path -LiteralPath $comp -PathType Container)){throw 'Digital Art Compendium DLC is missing.'}
$compBackups=@(Get-ChildItem -LiteralPath $backups -Directory -Filter 'Compendium-*' |
    Sort-Object LastWriteTimeUtc -Descending)
Write-Host 'Checking 56 Compendium illustrations and their original backups...'
foreach($item in @($compManifest.assets)){
    $rel=[string]$item.path
    if(@($compManifest.excludeModernPaths) -icontains $rel){throw "Protected modern illustration listed in approved manifest: $rel"}
    $target=Path-For $comp $rel
    $present=Test-Path -LiteralPath $target -PathType Leaf
    $oldHash=([string]$item.historicalSHA256).ToLowerInvariant()
    if([string]$item.status -ceq 'Removed'){
        if($present){
            if((Hash $target) -cne $oldHash){throw "Unknown historical-only artwork: $rel"}
            Plan-Move $target ('RemovedCompendium/'+$rel)
        }
        continue
    }
    if([string]$item.status -cne 'Modified'){throw "Unexpected Compendium status: $rel"}
    $modernHash=([string]$item.currentSHA256).ToLowerInvariant()
    if(-not $present){throw "Modified Compendium illustration missing: $rel"}
    $currentHash=Hash $target
    if($currentHash -ceq $modernHash){continue}
    if($currentHash -cne $oldHash){throw "Unknown installed Compendium image: $rel"}
    $original=$null
    foreach($folder in $compBackups){
        $candidate=Path-For $folder.FullName $rel
        if((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Hash $candidate) -ceq $modernHash){
            $original=$candidate;break
        }
    }
    if(-not $original){throw "Original Compendium artwork backup missing: $rel"}
    Plan-Replace $target $original ('Digital Art Compendium/'+$rel)
}

$bigManifest=Get-Content -LiteralPath (Join-Path $root 'patches\bigband-2023-intro-v1.json') -Raw | ConvertFrom-Json
$big=Join-Path $root 'assets\bigband'
$luaHash=(Get-Content -LiteralPath (Join-Path $big 'lua-sha256.txt') -Raw).Trim().ToLowerInvariant()
$loaderHash=(Get-Content -LiteralPath (Join-Path $big 'loader-sha256.txt') -Raw).Trim().ToLowerInvariant()
$modParts=@(
    [pscustomobject]@{Rel='mods/AOTC_BigBand_2023.lua';Hash=$luaHash},
    [pscustomobject]@{Rel='mods/AOTC_BigBand_2023/BigBandIntro.ini';Hash=([string]$bigManifest.oldScript.historicalSHA256).ToLowerInvariant()},
    [pscustomobject]@{Rel='mods/AOTC_BigBand_2023/03_1.dds';Hash=([string]$bigManifest.artwork[0].historicalSHA256).ToLowerInvariant()},
    [pscustomobject]@{Rel='mods/AOTC_BigBand_2023/03_2.dds';Hash=([string]$bigManifest.artwork[1].historicalSHA256).ToLowerInvariant()},
    [pscustomobject]@{Rel='CoreMessaging.dll';Hash=$loaderHash}
)
foreach($p in $modParts){if($p.Hash -notmatch '^[0-9a-f]{64}$'){throw 'Unexpected pinned Big Band hash.'}}
$existing=@($modParts | Where-Object { Test-Path -LiteralPath (Path-For $game $_.Rel) -PathType Leaf })
if($existing.Count -ne 0 -and $existing.Count -ne 5) {
    throw 'Partial Big Band mod installation. Refusing automatic reset.'
}
if($existing.Count -eq 5){
    foreach($p in $modParts){
        $path=Path-For $game $p.Rel
        if((Hash $path) -cne $p.Hash){throw "Unexpected Big Band mod or loader modification: $path"}
    }
    $records=@(Get-ChildItem -LiteralPath $backups -Directory -Filter 'AOTC-BigBand-Production-*' |
        Sort-Object LastWriteTimeUtc -Descending)
    $record=$null
    foreach($candidate in $records){
        $ledger=Join-Path $candidate.FullName 'installed-files.json'
        if(-not(Test-Path -LiteralPath $ledger -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $candidate.FullName 'UNINSTALLED.txt'))) {continue}
        $parsed=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ledger -Raw)
        $entries=@($parsed | ForEach-Object {$_})
        if($entries.Count -ne 5){continue}
        $valid=$true
        foreach($p in $modParts) {
            $target=Path-For $game $p.Rel
            $matching=@($entries | Where-Object { ([string]$_.target) -ieq $target -and
                ([string]$_.sha256).ToLowerInvariant() -ceq $p.Hash })
            if($matching.Count -ne 1){$valid=$false;break}
        }
        if($valid){$record=$candidate.FullName;break}
    }
    if(-not $record){throw 'No matching active AOTC Big Band installation ledger. No changes made.'}
    foreach($p in $modParts){Plan-Move (Path-For $game $p.Rel) ('RemovedBigBand/'+$p.Rel)}
}
$doubleManifest=Get-Content -LiteralPath (Join-Path $root 'patches\double-2023-ending-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$doubleBundle=Join-Path $root 'assets\double'
$doubleLuaHash=(Get-Content -LiteralPath (Join-Path $doubleBundle 'lua-sha256.txt') -Raw).Trim().ToLowerInvariant()
$doubleParts=@(
    [pscustomobject]@{Rel='mods/AOTC_Double_2023.lua';Hash=$doubleLuaHash},
    [pscustomobject]@{Rel='mods/AOTC_Double_2023/End05.dxt1.dds';Hash=([string]$doubleManifest.historicalSHA256).ToLowerInvariant()}
)
foreach($p in $doubleParts){
    if($p.Hash -notmatch '^[0-9a-f]{64}$'){throw 'Unexpected pinned Double production hash.'}
}
$doubleExisting=@($doubleParts | Where-Object { Test-Path -LiteralPath (Path-For $game $_.Rel) -PathType Leaf })
if($doubleExisting.Count -ne 0 -and $doubleExisting.Count -ne 2){
    throw 'Partial Double production mod installation. Nothing changed.'
}
$doubleRecord=$null
if($doubleExisting.Count -eq 2){
    if($existing.Count -ne 5){
        throw 'Double mod installed without the cumulative Big Band loader. If this is the isolated trial, use tools/Remove-Double-SkullLoader-Test.ps1 first.'
    }
    foreach($p in $doubleParts){
        $target=Path-For $game $p.Rel
        if((Hash $target) -cne $p.Hash){throw "Unexpected Double mod changes: $target"}
    }
    $candidates=@(Get-ChildItem -LiteralPath $backups -Directory -Filter 'AOTC-Double-Production-*' |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach($candidate in $candidates){
        $ledger=Join-Path $candidate.FullName 'installed-files.json'
        if(-not(Test-Path -LiteralPath $ledger -PathType Leaf) -or
           (Test-Path -LiteralPath (Join-Path $candidate.FullName 'UNINSTALLED.txt'))){continue}
        $parsed=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ledger -Raw -Encoding UTF8)
        $rows=@($parsed | ForEach-Object {$_})
        if($rows.Count -ne 2){continue}
        $matches=$true
        foreach($p in $doubleParts){
            $name=Path-For $game $p.Rel
            $found=@($rows|Where-Object {([string]$_.target) -ieq $name -and
                ([string]$_.sha256).ToLowerInvariant() -ceq $p.Hash})
            if($found.Count -ne 1){$matches=$false;break}
        }
        if($matches){$doubleRecord=$candidate.FullName;break}
    }
    if(-not $doubleRecord){throw 'No matching active Double production installation ledger. Nothing changed.'}
    foreach($p in $doubleParts){Plan-Move (Path-For $game $p.Rel) ('RemovedDouble/'+$p.Rel)}
}
. (Join-Path $PSScriptRoot 'Plan-Beowulf-Vanilla.ps1')
. (Join-Path $PSScriptRoot 'Plan-Parasoul-Vanilla.ps1')
. (Join-Path $PSScriptRoot 'Plan-Egret-Vanilla.ps1')
$mods=Join-Path $game 'mods'
if(Test-Path -LiteralPath $mods -PathType Container){
    $known=New-Object 'System.Collections.Generic.List[string]'
    foreach($part in $modParts){
        if($part.Rel.StartsWith('mods/')){
            $known.Add((Path-For $game $part.Rel))
        }
    }
    foreach($part in $doubleParts){
        if($part.Rel.StartsWith('mods/')){
            $known.Add((Path-For $game $part.Rel))
        }
    }
    foreach($part in $beowulfParts){
        if($part.Rel.StartsWith('mods/')){
            $known.Add((Path-For $game $part.Rel))
        }
    }
    foreach($part in $parasoulParts){
        if($part.Rel.StartsWith('mods/')){
            $known.Add((Path-For $game $part.Rel))
        }
    }
    foreach($part in $egretParts){
        if($part.Rel.StartsWith('mods/')){
            $known.Add((Path-For $game $part.Rel))
        }
    }
    if($known.Count -ne 23){
        throw "Expected 23 approved SkullLoader mod files, found $($known.Count). No changes made."
    }
    $other=@(Get-ChildItem -LiteralPath $mods -Recurse -File -Force |
        Where-Object { $known -notcontains $_.FullName })
    if($other.Count -gt 0){throw "Unrecognized additional mods are installed: $($other[0].FullName)"}
}
foreach($proxy in @('d3d9.dll','dbghelp.dll')){
    if(Test-Path -LiteralPath (Join-Path $game $proxy)){throw "Other DLL mod loader exists: $proxy"}
}
$loaderData=Join-Path $game 'data02'
if(Test-Path -LiteralPath $loaderData -PathType Container) {
    $ops.Add([pscustomobject]@{Mode='Directory';Target=$loaderData;Backup=(Path-For $resetFolder 'LoaderState/data02');
        Source=$null;Stage=$null;Size=0;State='NotStarted';Length=0;Modified=$null})
}
$loaderSave=Join-Path $game 'saves_CC.json'
if(Test-Path -LiteralPath $loaderSave -PathType Leaf){
    Plan-Move $loaderSave 'LoaderState/saves_CC.json'
}

Write-Host ''
Write-Host "Vanilla reset preflight passed. Planned operations: $($ops.Count)"
foreach($op in $ops) {
    Write-Host ("  {0}: {1}" -f $op.Mode,$op.Target)
}
Write-Host 'Steam DLC, normal game saves, Salmon files and unrelated folders will not be touched.'
Write-Host 'Original AOTC installation backups will be retained.'
if($DryRun){Write-Host 'DRY RUN: Nothing changed.' -ForegroundColor Green;return}
if($ops.Count -eq 0){Write-Host 'No AOTC modifications detected. Already vanilla.' -ForegroundColor Green;return}
if(-not $ConfirmedByReset){
    $answer=Read-Host 'Type RESET to move modified files to a dated backup and restore vanilla originals'
    if($answer -cne 'RESET'){Write-Host 'Cancelled. No changes made.';return}
}
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){throw 'Close Skullgirls before continuing.'}

Write-Host 'Staging original files before touching the game...'
$resetSucceeded=$false
try {
    foreach($op in $ops){
        if($op.Mode -eq 'Replace'){
            New-Item -ItemType Directory -Path (Split-Path -Parent $op.Stage) -Force | Out-Null
            Copy-Item -LiteralPath $op.Source -Destination $op.Stage -ErrorAction Stop
            if((Hash $op.Stage) -cne (Hash $op.Source)){throw "Backup stage checksum mismatch: $($op.Source)"}
        }
    }
    if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){throw 'Close Skullgirls before resetting.'}
    foreach($op in $ops){
        if($op.Mode -ne 'Directory'){
            $info=Get-Item -LiteralPath $op.Target -ErrorAction Stop
            if($info.Length -ne $op.Length -or $info.LastWriteTimeUtc -ne $op.Modified) {
                throw "Game file changed during staging: $($op.Target)"
            }
        }
    }
    $completed=New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach($op in $ops) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $op.Backup) -Force | Out-Null
            if(Test-Path -LiteralPath $op.Backup){throw "Reset destination already exists: $($op.Backup)"}
            if($op.Mode -eq 'Directory'){
                [IO.Directory]::Move($op.Target,$op.Backup)
            } else {
                [IO.File]::Move($op.Target,$op.Backup)
            }
            $op.State='Moved'
            $completed.Add($op)
            if($op.Mode -eq 'Replace'){
                [IO.File]::Move($op.Stage,$op.Target)
                $op.State='Replaced'
            }
        }
        $summary=@($ops | ForEach-Object {
            [pscustomobject]@{mode=$_.Mode;gamePath=$_.Target;preservedPath=$_.Backup}
        })
        New-Item -ItemType Directory -Path $resetFolder -Force | Out-Null
        ConvertTo-Json -InputObject $summary -Depth 4 | Set-Content -LiteralPath (Join-Path $resetFolder 'reset-record.json') -Encoding UTF8
        if($existing.Count -eq 5) {
            [IO.File]::WriteAllText((Join-Path $record 'UNINSTALLED.txt'),
                'AOTC reset to vanilla at '+(Get-Date -Format 'o'),[Text.Encoding]::UTF8)
        }
        if($doubleExisting.Count -eq 2) {
            [IO.File]::WriteAllText((Join-Path $doubleRecord 'UNINSTALLED.txt'),
                'AOTC cumulative reset to vanilla at '+(Get-Date -Format 'o'),[Text.Encoding]::UTF8)
        }
        if($beowulfExisting.Count -eq 6){
            [IO.File]::WriteAllText((Join-Path $beowulfRecord 'UNINSTALLED.txt'),
                'AOTC cumulative reset to vanilla at '+(Get-Date -Format 'o'),[Text.Encoding]::UTF8)
        }
        if($parasoulExisting.Count -eq 8){
            [IO.File]::WriteAllText((Join-Path $parasoulRecord 'UNINSTALLED.txt'),
                'AOTC cumulative reset to vanilla at '+(Get-Date -Format 'o'),[Text.Encoding]::UTF8)
        }
        if($egretExisting.Count -eq 3){
            [IO.File]::WriteAllText((Join-Path $egretRecord 'UNINSTALLED.txt'),
                'AOTC cumulative reset to vanilla at '+(Get-Date -Format 'o'),[Text.Encoding]::UTF8)
        }
        $resetSucceeded=$true
    } catch {
        $failure=$_
        for($i=$completed.Count-1;$i -ge 0;$i--){
            $op=$completed[$i]
            try {
                if($op.State -eq 'Replaced'){
                    [IO.File]::Move($op.Target,$op.Stage)
                }
                if($op.Mode -eq 'Directory'){
                    [IO.Directory]::Move($op.Backup,$op.Target)
                } else {
                    [IO.File]::Move($op.Backup,$op.Target)
                }
            } catch {
                Write-Host "MANUAL RECOVERY NEEDED for $($op.Target): $_" -ForegroundColor Red
            }
        }
        throw $failure
    }
} finally {
    if($resetSucceeded -and (Test-Path -LiteralPath $stage -PathType Container)) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
Write-Host ''
Write-Host 'Vanilla reset complete.' -ForegroundColor Green
Write-Host "Preserved modified files and loader state: $resetFolder"
Write-Host 'Filia, Big Band, Double, Beowulf, Parasoul, Black Egrets and Compendium reset. Normal save files preserved.'
Write-Host 'Launch through Steam to test vanilla. Rerun Restore.cmd to reinstall AOTC.'
