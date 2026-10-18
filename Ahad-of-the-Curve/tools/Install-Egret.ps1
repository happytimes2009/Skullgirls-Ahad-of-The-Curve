param(
    [Parameter(Mandatory=$true)][string]$GamePath,
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-GfsLibrary.ps1')
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){
    throw 'SkullGirls.exe missing. Nothing changed.'
}
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){
    throw 'Close Skullgirls before installing.'
}
$manifest=Get-Content -LiteralPath (Join-Path $root 'patches\egret-2023-combat-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$manifest.id -cne 'aotc-egret-65-v1' -or
   [int]$manifest.restoredComponents -ne 65 -or
   @($manifest.files).Count -ne 3 -or
   @($manifest.modernEntries).Count -ne 2){
    throw 'Unexpected Egret production manifest.'
}
$bundle=Join-Path $root 'assets\egret'
$modDir=Join-Path $game 'mods'
$expectedFiles=@(
    'AOTC_BlackEgret_Combat_Test.lua',
    'parasoul.art','parasoul.foit'
)
$expectedTargets=@(
    'mods/AOTC_BlackEgret_Combat_Test.lua',
    'mods/AOTC_BlackEgret_Combat_Test/parasoul.art',
    'mods/AOTC_BlackEgret_Combat_Test/parasoul.foit'
)
$parts=New-Object 'System.Collections.Generic.List[object]'
for($i=0;$i -lt 3;$i++){
    $file=$manifest.files[$i]
    if([string]$file.name -cne $expectedFiles[$i] -or
       [string]$file.target -cne $expectedTargets[$i]){
        throw 'Unexpected Egret production filename or destination.'
    }
    $sha=([string]$file.sha256).ToLowerInvariant()
    if($sha -notmatch '^[a-f0-9]{64}$' -or [long]$file.bytes -lt 1){
        throw 'Invalid Egret file pin.'
    }
    $src=Join-Path $bundle ([string]$file.name)
    if(-not(Test-Path -LiteralPath $src -PathType Leaf) -or
       (Get-SGHash $src) -cne $sha -or
       (Get-Item -LiteralPath $src).Length -ne [long]$file.bytes){
        throw "Missing/mismatched bundled Egret asset: $src. Release not self-contained."
    }
    $parts.Add([pscustomobject]@{
        Source=$src;Hash=$sha;Length=[long]$file.bytes;
        Target=(Join-Path $game ($expectedTargets[$i].Replace('/','\')))
    })
}
function Check-ModernEntry([object]$item){
    $archive=Join-Path $game ('data01\'+[string]$item.archive)
    if(-not(Test-Path -LiteralPath $archive -PathType Leaf)){
        throw "Modern original GFS missing: $archive"
    }
    $idx=Get-SGIndex $archive
    $entryName=[string]$item.entry
    if(-not $idx.ContainsKey($entryName)){
        throw "Modern Egret source GFS entry missing: $entryName"
    }
    $entry=$idx[$entryName]
    if([long]$entry.Size -ne [long]$item.bytes){throw "Unsupported modern $entryName size"}
    $stream=[IO.File]::OpenRead($archive)
    $hash=[Security.Cryptography.SHA256]::Create()
    try{
        [void]$stream.Seek([long]$entry.Offset,[IO.SeekOrigin]::Begin)
        [long]$remain=[long]$entry.Size
        [byte[]]$block=[byte[]]::new(1048576)
        while($remain -gt 0){
            $n=$stream.Read($block,0,[int][Math]::Min($remain,[long]$block.Length))
            if($n -le 0){throw "Truncated archive entry: $entryName"}
            [void]$hash.TransformBlock($block,0,$n,$block,0)
            $remain-=$n
        }
        [void]$hash.TransformFinalBlock([byte[]]::new(0),0,0)
        $actual=([BitConverter]::ToString($hash.Hash)).Replace('-','').ToLowerInvariant()
        if($actual -cne ([string]$item.sha256).ToLowerInvariant()){
            throw "Unsupported current Skullgirls ART/FOIT version: $entryName"
        }
    }finally{$hash.Dispose();$stream.Dispose()}
}
foreach($entry in @($manifest.modernEntries)){Check-ModernEntry $entry}
$big=Join-Path $game 'mods\AOTC_BigBand_2023.lua'
$loader=Join-Path $game 'CoreMessaging.dll'
$loaderPin=Join-Path $root 'assets\bigband\loader-sha256.txt'
$loaderSource=Join-Path $root 'assets\bigband\CoreMessaging.dll'
$bigSource=Join-Path $root 'assets\bigband\AOTC_BigBand_2023.lua'
if(-not(Test-Path -LiteralPath $loaderPin -PathType Leaf) -or
   -not(Test-Path -LiteralPath $loaderSource -PathType Leaf) -or
   -not(Test-Path -LiteralPath $bigSource -PathType Leaf)){
    throw 'Cumulative release missing Big Band/SkullLoader dependency.'
}
$loaderHash=(Get-Content -LiteralPath $loaderPin -Raw).Trim().ToLowerInvariant()
if($loaderHash -notmatch '^[a-f0-9]{64}$' -or (Get-SGHash $loaderSource) -cne $loaderHash){
    throw 'Bundled loader failed SHA-256 verification.'
}
$bigPresent=Test-Path -LiteralPath $big -PathType Leaf
$loaderPresent=Test-Path -LiteralPath $loader -PathType Leaf
if($bigPresent -ne $loaderPresent){throw 'Partial shared SkullLoader installation.'}
if($bigPresent -and (Get-SGHash $big) -cne (Get-SGHash $bigSource)){
    throw 'Installed Big Band Lua does not match production.'
}
if($loaderPresent -and (Get-SGHash $loader) -cne $loaderHash){
    throw 'Installed CoreMessaging.dll does not match bundled production.'
}
foreach($extra in @('d3d9.dll','dbghelp.dll')){
    if(Test-Path -LiteralPath (Join-Path $game $extra)){throw "Conflicting loader: $extra"}
}
if(Test-Path -LiteralPath $modDir -PathType Container){
    $allowed=@('AOTC_BigBand_2023.lua','AOTC_Double_2023.lua',
       'AOTC_Beowulf_2023.lua','AOTC_Parasoul_Historical.lua',
       'AOTC_BlackEgret_Combat_Test.lua')
    $foreign=@(Get-ChildItem -LiteralPath $modDir -File -Filter '*.lua' |
       Where-Object {$allowed -notcontains $_.Name})
    if($foreign.Count){throw "Unrecognized SkullLoader Lua: $($foreign[0].Name)"}
}
$existing=@($parts | Where-Object {Test-Path -LiteralPath $_.Target -PathType Leaf})
if($existing.Count -ne 0 -and $existing.Count -ne 3){
    throw 'Partial or mixed Egret experiment found; remove it using its own manager.'
}
$backups=Join-Path $game 'Restoration Backups'
$ledgerCount=0
if(Test-Path -LiteralPath $backups -PathType Container){
    foreach($dir in @(Get-ChildItem -LiteralPath $backups -Directory -Filter 'AOTC-Egret-Production-*')){
        $ledger=Join-Path $dir.FullName 'installed-files.json'
        if(-not(Test-Path -LiteralPath $ledger -PathType Leaf) -or
           (Test-Path -LiteralPath (Join-Path $dir.FullName 'UNINSTALLED.txt'))){continue}
        $rows=@(ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ledger -Raw -Encoding UTF8))
        if($rows.Count -ne 3){continue}
        $match=$true
        foreach($part in $parts){
            if(@($rows | Where-Object {
                ([string]$_.target) -ieq $part.Target -and
                ([string]$_.sha256).ToLowerInvariant() -ceq $part.Hash
            }).Count -ne 1){$match=$false;break}
        }
        if($match){$ledgerCount++}
    }
}
if($existing.Count -eq 3){
    foreach($part in $parts){
        if((Get-SGHash $part.Target) -cne $part.Hash){
            throw "Nonproduction Egret test or altered file present: $($part.Target)"
        }
    }
    if($ledgerCount -ne 1){
        throw 'Egret files present without exactly one production ledger; isolated test must be rolled back before cumulative AOTC.'
    }
}elseif($ledgerCount -ne 0){
    throw 'Existing active Egret production ledger without expected files.'
}
if($ValidateOnly){Write-Host '65-frame Egret production preflight passed.' -ForegroundColor Cyan;return}
if($existing.Count -eq 3){Write-Host '65-frame Egret production already installed and verified.' -ForegroundColor Green;return}
if(-not $bigPresent -or -not $loaderPresent){
    throw 'Shared SkullLoader must be installed by the cumulative Big Band stage first.'
}
$stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$record=Join-Path $backups ('AOTC-Egret-Production-'+$stamp)
$copied=New-Object 'System.Collections.Generic.List[object]'
try{
    [void](New-Item -ItemType Directory -Path $record -ErrorAction Stop)
    foreach($part in $parts){
        if(Test-Path -LiteralPath $part.Target){throw "Existing Egret target: $($part.Target)"}
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $part.Target) -Force)
        Copy-Item -LiteralPath $part.Source -Destination $part.Target -ErrorAction Stop
        $copied.Add($part)
        if((Get-SGHash $part.Target) -cne $part.Hash){
            throw "Copied Egret ART/FOIT did not match SHA-256: $($part.Target)"
        }
    }
    $installed=@($parts | ForEach-Object {
        [pscustomobject]@{target=$_.Target;sha256=$_.Hash}
    })
    ConvertTo-Json -InputObject $installed -Depth 4 |
        Set-Content -LiteralPath (Join-Path $record 'installed-files.json') -Encoding UTF8
}catch{
    $errorObject=$_
    foreach($part in $copied){
        if((Test-Path -LiteralPath $part.Target -PathType Leaf) -and
           (Get-SGHash $part.Target) -ceq $part.Hash){
            Remove-Item -LiteralPath $part.Target -Force
        }
    }
    throw $errorObject
}
Write-Host 'Black Egret combat armbands: 65 verified components installed.' -ForegroundColor Green
Write-Host ('Egret production ledger: '+$record)
Write-Host 'On game launch SkullLoader should generate the derived character ART/FOIT under data02.'
