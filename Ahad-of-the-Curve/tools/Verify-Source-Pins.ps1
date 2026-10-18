param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
function Read-Manifest([string]$name){
    $p=Join-Path (Join-Path $root 'patches') $name
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing source manifest: $name"}
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Check-Pin([string]$relative,[string]$expected,[long]$length=-1){
    if($relative.StartsWith('/') -or $relative.StartsWith('\') -or
       $relative.Contains(':') -or $relative.Contains([char]0) -or
       @($relative.Replace('\','/').Split('/')) -contains '..'){
        throw "Unsafe production asset name: $relative"
    }
    if($expected -cnotmatch '^[a-f0-9]{64}$'){throw "Invalid SHA-256 source pin for $relative"}
    $path=Join-Path $root ($relative.Replace('/','\'))
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing pinned production asset: $relative"}
    $info=Get-Item -LiteralPath $path
    if(($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Linked production asset: $relative"}
    if($length -ge 0 -and $info.Length -ne $length){
        throw "Source length mismatch: $relative, expected $length, got $($info.Length)"
    }
    $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actual -cne $expected){
        throw "Source pin mismatch: $relative; expected $expected, actual $actual"
    }
}
$big=Read-Manifest 'bigband-2023-intro-v1.json'
Check-Pin 'assets/bigband/BigBandIntro.ini' ([string]$big.oldScript.packagedSHA256).ToLowerInvariant()
$ini=Join-Path $root 'assets\bigband\BigBandIntro.ini'
$raw=[IO.File]::ReadAllBytes($ini)
$encoder=[Text.UTF8Encoding]::new($false,$true)
$text=$encoder.GetString($raw)
if($text.Contains([char]13)){throw 'Packaged Big Band script is not canonical LF.'}
$historicalBytes=$encoder.GetBytes($text.Replace([string][char]10,([string][char]13+[char]10)))
$sha=[Security.Cryptography.SHA256]::Create()
try{
    $sourceHash=([BitConverter]::ToString($sha.ComputeHash($historicalBytes))).Replace('-','').ToLowerInvariant()
}finally{$sha.Dispose()}
if($sourceHash -cne ([string]$big.oldScript.historicalSHA256).ToLowerInvariant()){
    throw 'Big Band canonical file is not equivalent to the historical CRLF source.'
}
for($i=0;$i -lt @($big.artwork).Count;$i++){
    $name='03_'+($i+1)+'.dds'
    Check-Pin ('assets/bigband/'+$name) ([string]$big.artwork[$i].historicalSHA256).ToLowerInvariant() ([long]$big.artwork[$i].bytes)
}
$loader=(Get-Content -LiteralPath (Join-Path $root 'assets\bigband\loader-sha256.txt') -Raw -Encoding UTF8).Trim().ToLowerInvariant()
Check-Pin 'assets/bigband/CoreMessaging.dll' $loader
foreach($entry in @(
    [pscustomobject]@{Name='bigband';Lua='AOTC_BigBand_2023.lua'},
    [pscustomobject]@{Name='double';Lua='AOTC_Double_2023.lua'},
    [pscustomobject]@{Name='beowulf';Lua='AOTC_Beowulf_2023.lua'},
    [pscustomobject]@{Name='parasoul';Lua='AOTC_Parasoul_Historical.lua'}
)){
    $pin=(Get-Content -LiteralPath (Join-Path $root ('assets\'+$entry.Name+'\lua-sha256.txt')) -Raw -Encoding UTF8).Trim().ToLowerInvariant()
    Check-Pin ('assets/'+$entry.Name+'/'+$entry.Lua) $pin
}
$double=Read-Manifest 'double-2023-ending-v1.json'
Check-Pin 'assets/double/End05.dxt1.dds' ([string]$double.historicalSHA256).ToLowerInvariant() ([long]$double.historicalLength)
$beowulf=Read-Manifest 'beowulf-2023-act5-v1.json'
foreach($asset in @($beowulf.artwork)){
    Check-Pin ('assets/beowulf/'+[string]$asset.file) ([string]$asset.historicalSha256).ToLowerInvariant() ([long]$asset.historicalSize)
}
$parasoul=Read-Manifest 'parasoul-historical-cutscenes-test-v1.json'
foreach($asset in @($parasoul.assets)){
    $name=[string]$asset.file
    if([string]$asset.sourceType -ceq 'story'){$local=$name.Replace('/','')}
    elseif($name -ceq 'NPCs/genericsoldier.dds'){$local='GenericSoldier.dds'}
    else{throw "Unexpected Parasoul package asset: $name"}
    Check-Pin ('assets/parasoul/'+$local) ([string]$asset.historicalSha256).ToLowerInvariant() ([long]$asset.historicalSize)
}
$egret=Read-Manifest 'egret-2023-combat-v1.json'
foreach($asset in @($egret.files)){
    Check-Pin ('assets/egret/'+[string]$asset.name) ([string]$asset.sha256).ToLowerInvariant() ([long]$asset.bytes)
}
$soviet=Read-Manifest 'soviet-voice-v1.json'
Check-Pin ('assets/soviet/'+[string]$soviet.modName+'.lua') ([string]$soviet.luaSHA256).ToLowerInvariant()
Check-Pin 'assets/soviet/hitspark_alt3.snd-wav' ([string]$soviet.hybridSHA256).ToLowerInvariant() ([long]$soviet.hybridBytes)
$combo=Read-Manifest 'combo-callouts-v1.json'
Check-Pin 'assets/combo/en_loc.json' ([string]$combo.restoredSHA256).ToLowerInvariant() ([long]$combo.restoredBytes)
$comp=Read-Manifest 'compendium-approved-v1.json'
foreach($asset in @($comp.assets)){
    Check-Pin ('assets/compendium/2023/'+[string]$asset.path) ([string]$asset.historicalSHA256).ToLowerInvariant() ([long]$asset.historicalSize)
}
Write-Host 'Verified all character, story, localization, loader and Compendium source pins.' -ForegroundColor Green
