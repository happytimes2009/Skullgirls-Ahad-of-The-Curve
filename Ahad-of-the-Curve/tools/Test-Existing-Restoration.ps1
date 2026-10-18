param([Parameter(Mandatory=$true)][string]$GamePath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-GfsLibrary.ps1')
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
$backups=Join-Path $game 'Restoration Backups'
if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){throw 'SkullGirls.exe not found.'}

function File-Hash([string]$path){
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Safe-GameFile([string]$relative){
    if([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains(':') -or
       $relative.StartsWith('/') -or $relative.StartsWith('\') -or
       $relative.Contains([char]0)){throw "Unsafe installation path: $relative"}
    $pieces=$relative.Replace('\','/').Split('/')
    if($pieces -contains '.' -or $pieces -contains '..' -or $pieces -contains ''){
        throw "Unsafe installation path: $relative"
    }
    $rootPath=$game.TrimEnd('\','/')+'\'
    $absolute=[IO.Path]::GetFullPath((Join-Path $game ($relative.Replace('/','\'))))
    if(-not $absolute.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase)){
        throw "Installation path outside Skullgirls: $relative"
    }
    return $absolute
}
function Add-Expected([string]$relative,[string]$hash,[string]$section){
    $expectedHash=$hash.ToLowerInvariant()
    if($expectedHash -notmatch '^[a-f0-9]{64}$'){throw "Unpinned $section file: $relative"}
    $target=Safe-GameFile $relative
    if($expect.ContainsKey($target)){throw "Duplicate expected restoration file: $target"}
    $expect[$target]=[pscustomobject]@{Relative=$relative;SHA256=$expectedHash;Section=$section}
}
function Check-Active-Ledger([string]$section,[int]$count,[string]$pattern){
    $sectionParts=@($expect.GetEnumerator()|Where-Object{$_.Value.Section -ceq $section})
    if($sectionParts.Count -ne $count){throw "Unexpected $section file count."}
    $good=0
    foreach($candidate in @(Get-ChildItem -LiteralPath $backups -Directory -Filter $pattern -ErrorAction Stop)){
        $ledger=Join-Path $candidate.FullName 'installed-files.json'
        if(-not(Test-Path -LiteralPath $ledger -PathType Leaf) -or
           (Test-Path -LiteralPath (Join-Path $candidate.FullName 'UNINSTALLED.txt'))){continue}
        $parsed=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ledger -Raw -Encoding UTF8)
        $entries=@($parsed|ForEach-Object{$_})
        if($entries.Count -ne $count){continue}
        $ok=$true
        foreach($part in $sectionParts){
            $hits=@($entries|Where-Object{
                ([string]$_.target) -ieq $part.Key -and
                ([string]$_.sha256).ToLowerInvariant() -ceq $part.Value.SHA256
            })
            if($hits.Count -ne 1){$ok=$false;break}
        }
        if($ok){$good++}
    }
    if($good -ne 1){
        throw ("Found {0} matching active {1} installation ledgers; expected one. Refusing to claim the game is fully restored." -f $good,$section)
    }
}
function Read-Entry([string]$archive,[string]$entry){
    $idx=Get-SGIndex $archive
    if(-not $idx.ContainsKey($entry)){throw "Missing restored archive entry: $entry"}
    $fs=[IO.File]::OpenRead($archive)
    try{return ,(Read-SGEntry $fs $idx[$entry])}finally{$fs.Dispose()}
}
function Filia-View([byte[]]$bytes){
    if($bytes.Length -lt 128 -or [Text.Encoding]::ASCII.GetString($bytes,0,4) -cne 'CSGG'){
        throw 'Unexpected Filia cutscene container.'
    }
    $s=[Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $at=$s.IndexOf('Filia_Legacy_Intro',[StringComparison]::Ordinal)
    if($at -lt 12 -or $s.IndexOf('Filia_Legacy_Intro',$at+1,[StringComparison]::Ordinal) -ge 0){
        throw 'Filia intro view is absent or ambiguous.'
    }
    $start=$at-12
    if([Text.Encoding]::ASCII.GetString($bytes,$start,4) -cne 'WVGG'){
        throw 'Filia view signature mismatch.'
    }
    [long]$length=[BitConverter]::ToUInt32($bytes,$start+4)
    if($length -lt 10000 -or $start+$length -gt $bytes.Length){throw 'Invalid Filia view length.'}
    $result=New-Object byte[] ([int]$length)
    [Array]::Copy($bytes,$start,$result,0,[int]$length)
    return ,$result
}

if(-not(Test-Path -LiteralPath (Join-Path $game 'mods\AOTC_BigBand_2023.lua') -PathType Leaf) -or
   -not(Test-Path -LiteralPath (Join-Path $game 'mods\AOTC_Parasoul_Historical.lua') -PathType Leaf) -or
   -not(Test-Path -LiteralPath (Join-Path $game 'mods\AOTC_BlackEgret_Combat_Test.lua') -PathType Leaf)){
    return $false
}

$big=Get-Content -LiteralPath (Join-Path $root 'patches\bigband-2023-intro-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$double=Get-Content -LiteralPath (Join-Path $root 'patches\double-2023-ending-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$beowulf=Get-Content -LiteralPath (Join-Path $root 'patches\beowulf-2023-act5-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$parasoul=Get-Content -LiteralPath (Join-Path $root 'patches\parasoul-historical-cutscenes-test-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$egret=Get-Content -LiteralPath (Join-Path $root 'patches\egret-2023-combat-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$filia=Get-Content -LiteralPath (Join-Path $root 'patches\filia-storyart-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$compendium=Get-Content -LiteralPath (Join-Path $root 'patches\compendium-approved-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(@($big.artwork).Count -ne 2 -or @($beowulf.artwork).Count -ne 5 -or
   @($parasoul.assets).Count -ne 6 -or @($filia.images).Count -ne 4 -or
   @($compendium.assets).Count -ne 56 -or @($egret.files).Count -ne 3){throw 'Production restoration manifest counts have changed.'}

$expect=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
$bigRoot='assets\bigband'
Add-Expected 'mods/AOTC_BigBand_2023.lua' ((Get-Content -LiteralPath (Join-Path $root "$bigRoot\lua-sha256.txt") -Raw).Trim()) 'BigBand'
Add-Expected 'mods/AOTC_BigBand_2023/BigBandIntro.ini' ([string]$big.oldScript.packagedSHA256) 'BigBand'
foreach($asset in @($big.artwork)){
    $short=([string]$asset.source).Replace('\','/').Split('/')[-1]
    Add-Expected ('mods/AOTC_BigBand_2023/'+$short) ([string]$asset.historicalSHA256) 'BigBand'
}
Add-Expected 'CoreMessaging.dll' ((Get-Content -LiteralPath (Join-Path $root "$bigRoot\loader-sha256.txt") -Raw).Trim()) 'BigBand'
Add-Expected 'mods/AOTC_Double_2023.lua' ((Get-Content -LiteralPath (Join-Path $root 'assets\double\lua-sha256.txt') -Raw).Trim()) 'Double'
Add-Expected 'mods/AOTC_Double_2023/End05.dxt1.dds' ([string]$double.historicalSHA256) 'Double'
Add-Expected 'mods/AOTC_Beowulf_2023.lua' ((Get-Content -LiteralPath (Join-Path $root 'assets\beowulf\lua-sha256.txt') -Raw).Trim()) 'Beowulf'
foreach($asset in @($beowulf.artwork)){
    Add-Expected ('mods/AOTC_Beowulf_2023/'+[string]$asset.file) ([string]$asset.historicalSha256) 'Beowulf'
}
Add-Expected 'mods/AOTC_Parasoul_Historical.lua' ((Get-Content -LiteralPath (Join-Path $root 'assets\parasoul\lua-sha256.txt') -Raw).Trim()) 'Parasoul'
foreach($asset in @($parasoul.assets)){
    $local=if([string]$asset.sourceType -ceq 'story'){([string]$asset.file).Replace('/','')}else{'GenericSoldier.dds'}
    Add-Expected ('mods/AOTC_Parasoul_Historical/'+$local) ([string]$asset.historicalSha256) 'Parasoul'
}
Add-Expected 'mods/AOTC_Parasoul_Historical/TargetPath.txt' (File-Hash (Join-Path $root 'assets\parasoul\TargetPath.txt')) 'Parasoul'
foreach($asset in @($egret.files)){
    Add-Expected ([string]$asset.target) ([string]$asset.sha256) 'Egret'
}
if($expect.Count -ne 24){throw 'Expected 24 cumulative SkullLoader files.'}

foreach($item in $expect.GetEnumerator()){
    if(-not(Test-Path -LiteralPath $item.Key -PathType Leaf)){return $false}
    if((File-Hash $item.Key) -cne $item.Value.SHA256){
        throw "An installed AOTC file was changed: $($item.Key). No changes made."
    }
}
foreach($proxy in @('d3d9.dll','dbghelp.dll')){
    if(Test-Path -LiteralPath (Join-Path $game $proxy)){throw "Unrecognized loader proxy: $proxy"}
}
$modsDir=Join-Path $game 'mods'
foreach($item in @(Get-ChildItem -LiteralPath $modsDir -File -Recurse -Force -ErrorAction Stop)){
    if(-not $expect.ContainsKey($item.FullName)){throw "Unrecognized additional SkullLoader mod: $($item.FullName)"}
}
if(-not(Test-Path -LiteralPath $backups -PathType Container)){
    throw 'Installed mod files have no Restoration Backups directory.'
}
Check-Active-Ledger 'BigBand' 5 'AOTC-BigBand-Production-*'
Check-Active-Ledger 'Double' 2 'AOTC-Double-Production-*'
Check-Active-Ledger 'Beowulf' 6 'AOTC-Beowulf-Production-*'
Check-Active-Ledger 'Parasoul' 8 'AOTC-Parasoul-Production-*'
Check-Active-Ledger 'Egret' 3 'AOTC-Egret-Production-*'

$story=Join-Path $game 'data01\story_art.gfs'
$ui=Join-Path $game 'data01\ui-win.gfs'
if(-not(Test-Path -LiteralPath $story -PathType Leaf) -or
   -not(Test-Path -LiteralPath $ui -PathType Leaf)){return $false}
$storyIndex=Get-SGIndex $story
$fs=[IO.File]::OpenRead($story)
try{
    foreach($img in @($filia.images|Where-Object{$_.to})){
        $name=[string]$img.to
        if(-not $storyIndex.ContainsKey($name)){return $false}
        [byte[]]$bytes=Read-SGEntry $fs $storyIndex[$name]
        if($bytes.Length -ne [long]$img.size -or
           (Get-SGByteHash $bytes) -cne ([string]$img.sha256).ToLowerInvariant()){return $false}
    }
}finally{$fs.Dispose()}
$oldGbs=Join-Path $root 'assets\game\filia\cutscene\april-2023\CutsceneCommon.gbs'
if(-not(Test-Path -LiteralPath $oldGbs -PathType Leaf)){throw 'Historical Filia cutscene is missing from the production package.'}
[byte[]]$historical=Filia-View ([IO.File]::ReadAllBytes($oldGbs))
[byte[]]$installed=Filia-View (Read-Entry $ui 'ui/Win/CutsceneCommon.gbs')
if((Get-SGByteHash $historical) -cne (Get-SGByteHash $installed)){return $false}

$art=Join-Path $game 'Digital Art Compendium'
foreach($asset in @($compendium.assets)){
    $rel=[string]$asset.path
    $pieces=$rel.Replace('\','/').Split('/')
    if($rel.StartsWith('/') -or $rel.StartsWith('\') -or
       $rel.Contains(':') -or $pieces -contains '.' -or
       $pieces -contains '..' -or $pieces -contains ''){throw "Unsafe Compendium item: $rel"}
    $target=Join-Path $art $rel.Replace('/','\')
    if(-not(Test-Path -LiteralPath $target -PathType Leaf)){return $false}
    if((File-Hash $target) -cne ([string]$asset.historicalSHA256).ToLowerInvariant()){return $false}
}
return $true
