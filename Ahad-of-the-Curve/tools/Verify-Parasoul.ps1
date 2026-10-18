param(
    [Parameter(Mandatory=$true)][string]$GamePath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-GfsLibrary.ps1')
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){throw 'SkullGirls.exe not found.'}
$manifest=Get-Content -LiteralPath (Join-Path $root 'patches\parasoul-historical-cutscenes-test-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$manifest.id -cne 'parasoul-historical-cutscenes-test-v1' -or
    @($manifest.assets).Count -ne 6){throw 'Unexpected Parasoul production manifest.'}
$records=@(Get-ChildItem -LiteralPath (Join-Path $game 'Restoration Backups') -Directory -Filter 'AOTC-Parasoul-Production-*' -ErrorAction Stop |
    Where-Object {(Test-Path -LiteralPath (Join-Path $_.FullName 'installed-files.json') -PathType Leaf) -and
        -not(Test-Path -LiteralPath (Join-Path $_.FullName 'UNINSTALLED.txt'))})
if($records.Count -ne 1){throw "Expected one active Parasoul production record, found $($records.Count)."}
$parsed=ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $records[0].FullName 'installed-files.json') -Raw -Encoding UTF8)
$rows=New-Object 'System.Collections.Generic.List[object]'
foreach($x in $parsed){$rows.Add($x)}
if($rows.Count -ne 8){throw 'Parasoul production ledger must contain eight files.'}
$expected=New-Object 'System.Collections.Generic.List[string]'
$expected.Add((Join-Path $game 'mods\AOTC_Parasoul_Historical.lua'))
foreach($name in @('Intro02.dxt1.dds','Intro07.dxt1.dds','Intro08.dxt1.dds',
    'End08.dxt1.dds','End10.dxt1.dds','GenericSoldier.dds','TargetPath.txt')){
    $expected.Add((Join-Path $game ('mods\AOTC_Parasoul_Historical\'+$name)))
}
$results=New-Object 'System.Collections.Generic.List[object]'
function Check([string]$area,[string]$item,[bool]$pass,[string]$detail){
    $status=if($pass){'PASS'}else{'FAIL'}
    $results.Add([pscustomobject]@{Area=$area;Item=$item;Result=$status;Detail=$detail})
    Write-Host ("[{0}] {1}: {2}" -f $status,$area,$item) -ForegroundColor $(if($pass){'Green'}else{'Red'})
}
Write-Host 'PARASOUL CUMULATIVE PRODUCTION VERIFICATION (READ ONLY)' -ForegroundColor Cyan
foreach($path in $expected){
    $match=@($rows | Where-Object {([string]$_.target) -ieq $path})
    if($match.Count -ne 1){Check 'Production ledger' $path $false 'Missing or duplicate';continue}
    $hash=([string]$match[0].sha256).ToLowerInvariant()
    $good=$hash -match '^[a-f0-9]{64}$' -and (Test-Path -LiteralPath $path -PathType Leaf)
    if($good){$good=(Get-SGHash $path) -ceq $hash}
    Check 'Production file' $path $good 'SHA-256 matches installer ledger'
}
$config=Join-Path $game 'mods\AOTC_Parasoul_Historical\TargetPath.txt'
if(-not(Test-Path -LiteralPath $config -PathType Leaf)){
    Check 'Soldier GFS target' 'TargetPath.txt' $false 'Missing target mapping'
    $soldierPath=''
}else{
    $soldierPath=(Get-Content -LiteralPath $config -Raw -Encoding ASCII).Trim()
    Check 'Soldier GFS target' $soldierPath ($soldierPath -ceq 'story_art/THs/NPCs/genericsoldier.dds') 'Approved story portrait mapping'
}
$source=Join-Path $game 'data01\story_art.gfs'
$derived=Join-Path $game 'data02\story_art.gfs'
if(-not(Test-Path -LiteralPath $source -PathType Leaf)){
    Check 'Original GFS' 'data01/story_art.gfs' $false 'Original archive missing'
}elseif(-not(Test-Path -LiteralPath $derived -PathType Leaf)){
    Check 'SkullLoader GFS' 'data02/story_art.gfs' $false 'Launch via Steam before verifying'
}else{
    $a=Get-SGIndex $source
    $b=Get-SGIndex $derived
    $input=[IO.File]::OpenRead($source)
    $output=[IO.File]::OpenRead($derived)
    try{
        foreach($asset in @($manifest.assets)){
            $name=[string]$asset.file
            if([string]$asset.sourceType -ceq 'story'){$key=([string]$manifest.modernPrefix)+$name}
            else{$key=$soldierPath}
            $old=([string]$asset.historicalSha256).ToLowerInvariant()
            if(-not $key -or -not $a.ContainsKey($key)){
                Check 'Modern data01' $name $false 'Archive entry missing'
            }else{
                $bytes=Read-SGEntry $input $a[$key]
                if([string]$asset.sourceType -ceq 'story'){
                    $ok=(Get-SGByteHash $bytes) -ceq ([string]$asset.currentSha256).ToLowerInvariant() -and
                        $bytes.Length -eq [long]$asset.currentSize
                }else{
                    $ok=(Get-SGByteHash $bytes) -cne $old
                }
                Check 'Modern data01' $key $ok 'Modern texture retained'
            }
            if(-not $key -or -not $b.ContainsKey($key)){
                Check 'Restored data02' $name $false 'Archive entry missing'
            }else{
                $bytes=Read-SGEntry $output $b[$key]
                Check 'Restored data02' $key ((Get-SGByteHash $bytes) -ceq $old -and
                    $bytes.Length -eq [long]$asset.historicalSize) 'Historical DDS restored'
            }
        }
    }finally{$input.Dispose();$output.Dispose()}
}
$report=Join-Path $records[0].FullName 'parasoul-production-validation.csv'
$results | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8
$fail=@($results | Where-Object {$_.Result -eq 'FAIL'})
Write-Host ''
if($fail.Count -eq 0){
    Write-Host 'SUCCESS: Six Parasoul textures restored in data02; modern data01 entries unchanged.' -ForegroundColor Green
}else{
    Write-Host ("NOT VERIFIED: {0} failures." -f $fail.Count) -ForegroundColor Yellow
}
Write-Host "Report: $report"
if($fail.Count -gt 0){exit 1}
