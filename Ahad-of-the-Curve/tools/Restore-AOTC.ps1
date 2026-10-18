param(
    [string]$GamePath,
    [switch]$SkipBanner,
    [switch]$CompactProgress,
    [int]$TotalStages=7
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-CompactProgress.ps1')
if($CompactProgress){
    & (Join-Path $PSScriptRoot 'Verify-Production-Payload.ps1') 6>$null | Out-Null
}else{
    & (Join-Path $PSScriptRoot 'Verify-Production-Payload.ps1')
}
if(-not $SkipBanner){
    . (Join-Path $PSScriptRoot 'SG-Banner.ps1')
    Show-SGBanner -ProjectRoot $root
}
if(-not $GamePath){$GamePath=Read-Host 'Path to your Skullgirls game directory'}
$GamePath=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"'))
if(-not(Test-Path -LiteralPath (Join-Path $GamePath 'SkullGirls.exe') -PathType Leaf)){
    throw 'No SkullGirls.exe found at the selected location.'
}
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){
    throw 'Close Skullgirls before installing.'
}
$filia=Join-Path $PSScriptRoot 'Restore-Filia-2023-Scene.ps1'
$artbook=Join-Path $PSScriptRoot 'Install-Compendium-Restoration.ps1'
$bigband=Join-Path $PSScriptRoot 'Install-BigBand.ps1'
$double=Join-Path $PSScriptRoot 'Install-Double.ps1'
$beowulf=Join-Path $PSScriptRoot 'Install-Beowulf.ps1'
$parasoul=Join-Path $PSScriptRoot 'Install-Parasoul.ps1'
$egret=Join-Path $PSScriptRoot 'Install-Egret.ps1'
$checkInstalled=Join-Path $PSScriptRoot 'Test-Existing-Restoration.ps1'
$titles=@('FILIA','DIGITAL ART COMPENDIUM','BIG BAND','DOUBLE','BEOWULF','PARASOUL STORY','BLACK EGRETS')

function Invoke-AOTCStage {
    param([int]$Number,[string]$Title,[scriptblock]$Operation)
    if($CompactProgress){
        Show-AOTCStageStart -Index $Number -Total $TotalStages -Title $Title
        & $Operation 6>$null | Out-Null
        Show-AOTCStageDone
    }else{
        Write-Host ''
        Write-Host ("[{0}/7] {1}" -f $Number,$Title) -ForegroundColor Cyan
        & $Operation
        Write-Host ('['+('█'*20)+']') -ForegroundColor Cyan
    }
}

$already=(& $checkInstalled -GamePath $GamePath 6>$null)
if($already){
    foreach($i in 0..6){
        Show-AOTCStageStart -Index ($i+1) -Total $TotalStages -Title $titles[$i]
        Show-AOTCStageDone
    }
    if(-not $SkipBanner){
        Write-Host ''
        Write-Host 'RESTORATION COMPLETE' -ForegroundColor Green
        . (Join-Path $PSScriptRoot 'SG-ESGWarning.ps1')
        Show-AOTCESGWarning
    }
    return
}

if($CompactProgress){
    & $bigband -GamePath $GamePath -ValidateOnly 6>$null | Out-Null
    & $double -GamePath $GamePath -ValidateOnly 6>$null | Out-Null
    & $beowulf -GamePath $GamePath -ValidateOnly 6>$null | Out-Null
    & $parasoul -GamePath $GamePath -ValidateOnly 6>$null | Out-Null
    & $egret -GamePath $GamePath -ValidateOnly 6>$null | Out-Null
    & $artbook -GamePath $GamePath -ValidateOnly 6>$null | Out-Null
}else{
    & $bigband -GamePath $GamePath -ValidateOnly
    & $double -GamePath $GamePath -ValidateOnly
    & $beowulf -GamePath $GamePath -ValidateOnly
    & $parasoul -GamePath $GamePath -ValidateOnly
    & $egret -GamePath $GamePath -ValidateOnly
    & $artbook -GamePath $GamePath -ValidateOnly
}
Invoke-AOTCStage 1 $titles[0] { & $filia -GamePath $GamePath -InternalRun }
Invoke-AOTCStage 2 $titles[1] { & $artbook -GamePath $GamePath }
Invoke-AOTCStage 3 $titles[2] { & $bigband -GamePath $GamePath }
Invoke-AOTCStage 4 $titles[3] { & $double -GamePath $GamePath }
Invoke-AOTCStage 5 $titles[4] { & $beowulf -GamePath $GamePath }
Invoke-AOTCStage 6 $titles[5] { & $parasoul -GamePath $GamePath }
Invoke-AOTCStage 7 $titles[6] { & $egret -GamePath $GamePath }
if(-not $SkipBanner){
    Write-Host ''
    Write-Host 'RESTORATION COMPLETE' -ForegroundColor Green
    . (Join-Path $PSScriptRoot 'SG-ESGWarning.ps1')
    Show-AOTCESGWarning
}
